# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

Cross-platform IPTV player in Flutter. Plays live TV and VOD from **M3U playlists** and
**Xtream Codes** providers. ~8,400 lines of Dart.

**Targets:** Windows, macOS, Linux, Android. There is **no `ios/` and no `web/` directory** —
despite `lib/ui/player/web_video_player.dart` and the `video_player_web` dependency existing,
web is not a buildable target. Don't trust the README's platform table.

## Commands

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # regenerate *.g.dart Hive adapters
flutter analyze
flutter run -d windows          # or macos / linux / android
flutter build apk --split-per-abi
```

`deploy.sh` is a commit-and-push helper with an interactive build menu. It force-sets the git
remote and pushes to `main`. Don't invoke it as part of normal work.

`run_software_rendering.sh` forces llvmpipe on Linux — a workaround for GPU driver crashes.

## Architecture

Layered, with hand-written Riverpod providers. `riverpod_generator` is in dev_dependencies but
**no `@riverpod` annotations exist** — every provider is declared manually. Follow that
convention; don't introduce codegen for a single provider.

```
lib/
├── main.dart            Hive init, adapter registration, box opening, MediaKit.ensureInitialized
├── app.dart             MaterialApp, dark theme only
├── core/
│   ├── constants/       Xtream endpoint names, Hive box names, settings keys
│   ├── theme/           AppTheme — indigo/purple on near-black, all static consts
│   └── utils/           String/DateTime/Duration/BuildContext extensions
├── data/
│   ├── models/          Equatable + Hive (@HiveType). Channel, VODItem, PlaylistSource,
│   │                    Category, EPGProgram, ServerInfo
│   └── services/        XtreamService (Dio), M3UParser, EPGService (XMLTV), StorageService (Hive)
├── providers/
│   ├── playlist_provider.dart   The real hub — sources, channels, VOD, EPG state
│   └── player_provider.dart     DEAD CODE — nothing references it
└── ui/
    ├── screens/         home (shell), live_tv, vod, epg, multi_view, settings
    ├── widgets/         category_sidebar, mini_player, search_bar, loading, error
    └── player/          three separate player implementations (see below)
```

### State

`playlist_provider.dart` owns nearly everything:

| Provider | Type | Notes |
|---|---|---|
| `playlistSourcesProvider` | `StateNotifier<List<PlaylistSource>>` | reads through to Hive |
| `activePlaylistProvider` | `Provider<PlaylistSource?>` | duplicates `StorageService.getActivePlaylistSource` |
| `channelStateProvider` | `StateNotifier<ChannelState>` | live channels + categories + filter |
| `vodStateProvider` | `StateNotifier<VODState>` | Xtream only; errors out for M3U |
| `epgStateProvider` | `StateNotifier<Map<String, List<EPGProgram>>>` | XMLTV only |
| `miniPlayerProvider` | in `ui/widgets/mini_player.dart` | owns its own `Player` |
| `bufferModeProvider`, `autoReconnectProvider` | in `ui/player/enhanced_video_player.dart` | |

Note: providers live next to their UI in two cases (mini player, buffer settings). That's
existing convention, not an accident to "fix".

**`copyWith` on state classes deliberately does NOT preserve `error`** — it's `error: error`,
not `error ?? this.error`, so any `copyWith` clears the error. This is intentional. Preserve it.

### Players — there are three

| File | Used by | Engine |
|---|---|---|
| `player/enhanced_video_player.dart` (932 ln) | **Live TV**, mini-player expand | media_kit, with recovery logic |
| `player/video_player_screen.dart` | **VOD** | media_kit, delegates to web player on `kIsWeb` |
| `player/web_video_player.dart` | web only — unreachable, no `web/` dir | `video_player` package |

`video_player_controls.dart` is only used by `video_player_screen.dart`.

`NoVideoControls` is defined as a top-level function **three separate times**
(enhanced_video_player, multi_view_screen, mini_player). If you touch any of them, consider
consolidating rather than adding a fourth.

Multi-view runs **four independent `Player` instances** in a 2×2 grid, all muted except the
active audio slot (keys 1–4).

### Stream resilience — read this before touching any player

Freeze handling lives in `lib/core/player/` and is wired into **all four** playback
surfaces: the live player, the VOD player, every multi-view tile, and the mini player.

**`stream_tuning.dart`** — the *prevention* layer. mpv/FFmpeg properties applied to every
`Player` before its first `open()` (demuxer options are read at open time, so ordering
matters). The two that carry the most weight:

- `stream-lavf-o=reconnect=1,reconnect_streamed=1,...` — FFmpeg re-dials a dropped HTTP
  connection itself, so most provider hiccups never become application-visible freezes.
- `network-timeout` — without it a stalled socket read hangs forever, which is exactly the
  "frozen, no error, nothing happens" case. Bounding it turns a silent hang into an error.

Also owns `BufferMode` (moved out of the UI so the tuning layer doesn't depend on it) and
`alternateUrl`, the `.ts` ↔ `.m3u8` fallback.

**`stream_watchdog.dart`** — the *detection and recovery* layer.

Detection runs on its own `Timer.periodic`, **not** on player event streams. This is
deliberate and important: when a stream truly freezes, libmpv stops emitting position
events, so any detector built on those events is starved exactly when it is needed. It
samples position, `demuxer-cache-time` and `paused-for-cache`, and distinguishes
`FreezeCause.starved` (no data arriving) from `FreezeCause.wedged` (data arriving,
playhead stuck) — the latter skips ahead to rebuilding the player, because re-opening a
stream cannot fix a wedged decoder.

Recovery is an escalating ladder, cheapest first:
`nudge → reopen → hardReopen → recreate → alternateUrl`, each followed by a verification
window before the next rung is allowed. Sustained healthy playback rewinds the ladder.

**Design rule: recovery must never latch off.** When the ladder is exhausted it backs off
and starts over, indefinitely. `WatchdogPhase` has no terminal failure state by design, and
`test/stream_watchdog_test.dart` guards this. The previous implementation stopped after
three attempts and left the user pressing `R` on a frozen frame; do not reintroduce that.
Any change adding a "gave up" state is a regression.

**Verified against real libmpv**, not just unit tests (see "Testing freeze recovery"):
mpv accepts every tuned property including the FFmpeg `reconnect=*` options; the
detection signals read real values during playback (they read null *before* a file is
loaded, which is fine); and an injected 70s freeze was detected and recovered from
automatically ~5s after the stream returned.

Two ordering rules learned the hard way, both of which cost ~30s per recovery when wrong:

- **Publish the player and its `VideoController` to the widget tree BEFORE calling
  `StreamTuning.apply`.** `setProperty` awaits video-controller initialisation, and the
  controller cannot initialise until a `Video` widget mounts. Tuning first deadlocks
  until every property times out. Tuning must still happen before `open()`.
- **`noteStreamOpened()` must not rewind the ladder during recovery.** It checks
  `_recovering` for exactly this reason — otherwise `recreate` re-opens the stream, the
  host reports the open, escalation resets, and the ladder cycles the first four rungs
  forever without ever reaching the alternate-format fallback.

Two host-specific notes:
- `onRecreate` is optional. `video_player_screen.dart` passes null because its `_player` is
  a `late final` field the whole screen reads directly; the ladder skips unavailable steps.
- For VOD, `onOpen` must restore the playback position (see `_openAndResume`), or recovery
  restarts the film from zero — worse than the freeze it is fixing.

`media_kit` exports `NativePlayer`, so arbitrary mpv properties are reachable:

```dart
final native = player.platform as NativePlayer;
await native.setProperty('cache-secs', '20');
final v = await native.getProperty('demuxer-cache-time');
```

Guard every such call — `platform` is `PlatformPlayer?` and is a `WebPlayer` on web.

### Testing freeze recovery

Unit tests cover the ladder's decision-making with no player attached. To exercise the
real thing:

```bash
# 1. serve an endless realtime-paced MPEG-TS that freezes 25s in, for 70s
python tool/stall_proxy.py --upstream <any HLS url> --script relay:25,stall:70,relay:150 --port 8923

# 2. point the diagnostic harness at it
flutter run -d windows -t lib/dev_harness.dart     --dart-define=URL=http://127.0.0.1:8923/ --dart-define=SECONDS=220
```

`stall:` stops delivering bytes while holding the socket open — the freeze that used to
hang forever with no error. The harness reads every tuned property back out of libmpv
(proving mpv accepted it rather than silently ignoring it) and logs a per-second sample of
position, cache time and `paused-for-cache` alongside watchdog transitions.

Gotchas: kill stale proxies before re-testing — Python's `HTTPServer` sets
`SO_REUSEADDR`, so a second bind to the same port succeeds silently and an old instance
can serve your traffic and invalidate the run (`netstat -ano | grep LISTENING | grep :<port>`
to check). And `player.state.buffer` is an **absolute media timestamp**, not remaining
duration — use `StreamTuning.bufferHealth` rather than dividing it by anything.

## Data model gotchas

**M3U channel IDs are not stable.** `M3UParser._parseChannel` assigns `id: _uuid.v4()` on every
parse. Favorites and history are keyed by that ID in Hive, so **M3U favorites orphan on every
playlist reload**. Xtream is unaffected (uses `stream_id`). Fixing this means deriving a
deterministic ID (e.g. hash of `tvg-id` + name + URL) — and migrating existing Hive entries.

**Credentials are plaintext.** Xtream username/password live unencrypted in the
`playlist_sources` Hive box and are embedded in every stream URL. Several `print` calls log
those URLs (`'Opening stream: $url'`). Don't add more, and don't put stream URLs in any output
that could be shared.

**Hive type IDs are committed:** `Channel`=0, `VODItem`=1, `PlaylistType`=2, `PlaylistSource`=3.
Never renumber. Only append new `@HiveField` indices; never reuse or reorder them.

## Built but never wired up

These exist and work but nothing calls them — check here before writing new code:

- `XtreamService.getSeries`, `getSeriesInfo`, `getVodInfo`, `getShortEpg`, `getAllEpg`
- `VODItem.fromXtreamEpisode`
- All of `providers/player_provider.dart`

Consequence: **series/episodes are not available in the UI** — VOD is movies only, contrary to
the README. EPG comes solely from XMLTV, never from the Xtream EPG endpoints.

## Known rough edges

- Hardware acceleration is force-disabled (`enableHardwareAcceleration: false`) in both
  media_kit players — a Linux GPU-crash workaround that also costs performance on
  Windows/Android.
- `MPVLogLevel.v` (verbose) is on in the shipped live player path.
- ~80 lint infos, mostly deprecated `withOpacity` and missing `const`. `flutter analyze`
  reports **no errors**; the single warning is a pre-existing unused `_selectedChannelId`
  field in `epg_screen.dart`. Don't add new errors or warnings.
- `test/` covers the recovery ladder and URL fallback only. There are no widget tests —
  the stock `widget_test.dart` template was removed rather than left broken.
- Android release builds are signed with **debug keys** and `applicationId` is still
  `com.example.iptv_player`. Both are marked TODO in `android/app/build.gradle.kts`.
- Android ships `usesCleartextTraffic="true"` plus a permissive network security config —
  required in practice, since many IPTV providers are plain HTTP.

## Conventions

- Lints: `flutter_lints` plus `prefer_const_constructors`, `prefer_single_quotes`.
  `avoid_print` is deliberately **off** — `print` is the existing debug logging mechanism.
- Dark theme only. Pull colors from `AppTheme` constants, never hardcode.
- Desktop/mobile split is `context.isDesktop` (width > 900) from `core/utils/extensions.dart`.
- Player keyboard shortcuts: `Space` play/pause, `↑↓` channel, `M` mute, `F` fullscreen,
  `R` manual reconnect, `Esc` exit. Multi-view adds `1`–`4` for audio slot.
