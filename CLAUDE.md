# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

Cross-platform IPTV player in Flutter. Plays live TV and VOD from **M3U playlists** and
**Xtream Codes** providers. ~8,400 lines of Dart.

**Targets:** Windows, macOS, Linux, Android phone, and Android TV / Google TV. There is
**no `ios/` and no `web/` directory** — despite `lib/ui/player/web_video_player.dart` and the
`video_player_web` dependency existing, web is not a buildable target. The README's platform
table used to claim TV support before any existed; it is accurate now, but check it against
this file rather than the reverse.

**One APK serves phone and TV.** No product flavors, no second source tree. `kIsTv` is
latched in `main()` before `runApp` from a MethodChannel (`UiModeManager`, OR'd with the
leanback feature and the absence of a touchscreen), and every layout, theme and input
difference branches on it. See "Android TV" below.

## Commands

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # regenerate *.g.dart Hive adapters
flutter analyze
flutter run -d windows          # or macos / linux / android
flutter build apk --split-per-abi
```

**`flutter analyze` exits 1 on a clean tree.** Infos are fatal by default and this repo
carries ~89 pre-existing ones, so never chain it with `&&` — `flutter analyze && flutter test`
silently skips the tests. Separate the commands with `;`, or gate on
`flutter analyze --no-fatal-infos --no-fatal-warnings`, which is the only form that exits 0
(the lone warning is the pre-existing unused `_selectedChannelId`). Judge a change by whether
the count moved, not by the exit code.

Also note `flutter test` and `flutter analyze` each run an implicit `pub get`, which rewrites
`pubspec.lock` against the local SDK. If it turns up dirty and you did not intend a dependency
change, `git checkout pubspec.lock`.

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
| `bufferModeProvider`, `autoReconnectProvider`, `qualityPolicyProvider` | in `ui/player/enhanced_video_player.dart` | |

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
Quality degradation lives in the same directory but reaches only the live player, the
mini player, and (manually) multi-view tiles — see "Quality degradation" below.

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

**Design rule: the ladder is for repair, not for quality.** `degradeQuality` is its last
rung, but the *primary* trigger for lowering quality is the congestion detector, not this
ladder — reaching the last rung takes roughly a minute of broken video, and another minute
per step after that. See "Quality degradation".

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

### Android TV

One APK, no flavors. `kIsTv` (`core/platform/tv_platform.dart`) is resolved once in `main()`
before `runApp` — before, because it selects the theme and every layout branch, so resolving
it later would re-layout the first frame. Exposed as `context.isTv` and as `isTvProvider`;
both read the same latched global so they cannot disagree. A three-state override in Settings
forces it either way, which is how the TV layout gets exercised on a desktop.

**`context.isDesktop` excludes TV explicitly.** A 1080p TV reports roughly 960×540 logical
pixels at density 2.0, clearing the `> 900` threshold by 60dp — so before this it silently
inherited the whole desktop layout. That one exclusion is what routes TV to its own branches
in `home_screen`, `live_tv_screen` and `vod_screen`.

Things that are the way they are for a reason:

- **The player's key handler is a `Focus` with `canRequestFocus: false`.** It was a
  `KeyboardListener` with `autofocus: true`, which made a full-screen node the scope's
  `focusedChild` — and directional traversal filters candidates to those *beyond* the focused
  node's edge, so with a full-screen rect the candidate set was empty in all four directions
  and focus could never reach any control, on a remote or a desktop keyboard. As a
  non-focusable interceptor it still receives every key by bubbling up the ancestor chain,
  while the real `focusedChild` is a button traversal can move away from. Do not give this
  node focus again.
- **Claimed keys are consumed on both edges.** Anything returning `handled` on key-down must
  also consume its key-up, or the up is redispatched to the Android activity — and Back fires
  on `ACTION_UP`, so the activity pops out from under the app. `_claimedKeys` exists so the
  set is stated once; `_swallowSelectUp` latches the one case where the claim is conditional.
- **Up/Down always change channel**, even with the controls hidden. Left/Right/Select wake the
  controls first. Channel surfing is the most-used interaction and must not cost two presses.
- **Select needs no key mapping.** Flutter's default shortcuts already bind
  `LogicalKeyboardKey.select` (D-pad centre, Android keycode 23) to `ActivateIntent` on
  Android, so any focusable widget activates from the remote's OK button.
- **Controls stay mounted while hidden.** `_buildControls` fades itself with
  `AnimatedOpacity`; the old `if (_showControls && …)` guard meant that animation never ran
  in its fade-out direction and, worse for a remote, the focused button left the tree when
  the hide timer fired. `IgnorePointer` covers the pointer case.
- **`TvFocusable`** (`ui/widgets/tv_focusable.dart`) is for hand-rolled `GestureDetector`
  controls, which create no focus node and are invisible to a remote. Material widgets built
  on `InkWell` — `ListTile`, `IconButton`, `FilterChip` — already traverse and do not need it.
  It uses `foregroundDecoration` for the ring so focusing something cannot reflow the layout.
- **A VOD card is one focus node.** It used to be three (outer detector, full-bleed `InkWell`,
  favourite button). Traversal prefers the smallest vertical distance, and the next row's
  heart icon sits higher than its card's centre — so D-pad *down* landed on a heart every
  time, never a card. The favourite is `ExcludeFocus`d on TV rather than removed.
- **The expanded mini player is not a route**, so Back was popping HomeScreen and exiting the
  app mid-playback. A `PopScope` in that subtree intercepts it and minimises instead. The
  shell is also `ExcludeFocus`d while it is up, or the rail and channel list stay traversable
  behind the video.
- **`IndexedStack` needs `ExcludeFocus` on its inactive children.** It keeps every child laid
  out with a real focus rect and only skips painting, so without that the D-pad wanders into
  Settings while Live TV is on screen.
- **Overscan is injected into `MediaQuery`**, not applied as a `Padding` — a Padding would
  letterbox the video. Existing `SafeArea`s then work for free. The player's `Stack` is
  deliberately full-bleed, so its absolutely-positioned overlays add `_overlayInset`
  themselves.
- **The EPG uses two one-dimensional panes on TV**, not the desktop grid. Two-axis traversal
  over virtualised content dead-ends past the `ListView` cache extent, and the grid is
  1 + N unsynchronised scrollers rather than a real grid. The channel pane raises
  `cacheExtent` because an unmounted focused node teleports focus to the top of the scope.
- **Hidden on TV:** multi-view and its FAB (four players will not run on a box, and the FAB
  floats focusable over the video), "Add M3U File" (`ACTION_GET_CONTENT` has no resolver on
  most TVs), and the fullscreen toggle.

### Branding

The app's display name is **Definitely Not Cable**. Four places carry it:
`android:label`, `MaterialApp.title`, `AppConstants.appName` and the Settings
About card.

**`StreamTuning.userAgent` is deliberately still `IPTV Player/1.0` and must stay
that way.** It is sent to providers on every request, some of which filter on
User-Agent, so a rename that reached the wire could lose access to a working
subscription for nothing. Same for the two strings in `web_video_player.dart`
and the one in `dev_harness.dart`.

`tool/make_icons.py` generates every icon asset - five legacy launcher sizes,
five adaptive foreground/background pairs, and the 320x180 TV banner - so the
branding is editable rather than a pile of binaries. Run it from the repo root.
Everything is drawn at 4x and downsampled, because Pillow's primitives are not
anti-aliased. The constraint that shapes the design is legibility at 48px
(mdpi), which rules out text and thin strokes; the banner is the only asset
big enough to carry the name.

Adaptive icons (`mipmap-anydpi-v26/ic_launcher.xml`) are used from API 26 on and
the launcher masks the foreground to a circle, squircle or rounded square - so
the foreground art stays inside the 66dp safe circle of its 108dp canvas. The
legacy PNGs are still required for API 24-25, which minSdk 24 includes.

`AppTheme.tvTheme` is `darkTheme.copyWith(...)`. The load-bearing part is `focusColor`:
Material's dark default focus highlight is white at ~10% opacity, invisible across a room,
which would make every screen unusable regardless of whether traversal worked.

### Quality degradation

`stream_quality.dart` + `quality_controller.dart`. The point is to trade picture for
continuity when the pipe is too narrow, rather than reconnecting forever to a bitrate the
connection cannot carry.

Three mechanisms, and their real value differs enormously:

- **Sibling channels** — providers list the same channel at several bitrates as separate
  playlist entries (`ESPN FHD` / `ESPN HD` / `ESPN SD`). The only mechanism that genuinely
  reduces bytes on the wire, so it is the primary one.
- **HLS variant cap** (`hls-bitrate=min`) — works only when the provider serves a real
  master playlist, which many Xtream panels do not. Read at open time, so it costs a reopen,
  and it is a two-position switch (`min`/`max`), not a ladder — FFmpeg exposes no variant
  list to compute steps from.
- **Audio only** (`vid=no`) — **saves no bandwidth on a muxed MPEG-TS.** The demuxer still
  reads the whole transport stream to keep audio current and discards the video packets; only
  decode work is saved. Never auto-selected, both for that reason and because a black frame
  with sound is indistinguishable from the freeze it would be fixing. When it *is* selected,
  the player shows an explicit "Audio only" panel instead of black.

**The grouping heuristics are deliberately biased toward false negatives.** Switching someone
to the wrong channel is far worse than missing a sibling. Every rule below was either put
there or corrected by measuring against a real 53,000-channel subscription — do not relax one
without re-running that measurement (see "Measuring the heuristics"):

- The **normalised base name is part of every group key**, on both the tvg-id and the name
  path. So a bad `tvg-id` *partitions* rather than poisons: this playlist uses `TS` as a
  placeholder id on 444 unrelated channels and `01TV.fr` on 18, and even credible ids put
  `BUNDESLIGA 2` with `BUNDESLIGA 3` and `beIN SPORTS 2` with its FRANCE feed. An earlier
  version rejected any group whose names disagreed, which also threw away the good half —
  `US: TNT HD` / `US: TNT SD` / `US: TNT WEST 4K` share an id, and the HD/SD pair is real.
- **tvg-id is not reliable enough to lead.** Only 14.8% of this playlist has a non-empty one.
  What it still buys over the name path is that it does not require the same category or the
  same tier-word position.
- **Bouquet labels are never tier candidates.** 154 channels here are prefixed `4K:` or `8K:`
  — the provider is called "World 8K" — and read as tiers, every one outranked the real HD
  variant of whatever followed. The label stays *in* the base name, though: `|US| ESPN` and
  `|AR| ESPN` are different languages and must not group.
- **Timeshift channels are never siblings.** `ITV 2+1` is an hour behind `ITV 2`; switching
  someone mid-programme is worse than the stutter. 78 channels here carry a `+1`/`+24`.
- **Superscript tiers are folded to ASCII first.** `SKY SPORTS NEWS ᴴᴰ`, `LA 1 ᵁᴴᴰ ³⁸⁴⁰ᴾ` and
  `MBC 5 ᴴᴰ` are everywhere in real playlists and a `[A-Za-z0-9]+` tokeniser cannot see them.
- `HEVC`/`RAW`/`BACKUP`/`ALT` are not tiers and are excluded from ranking; `360` is not in the
  tier table because `CNN 360` and `Sky Sport 360` are channel names.
- A group still needs two distinct known tiers, distinct URLs, and at most
  `maxQualityGroupSize` members.

`test/stream_quality_test.dart` is a table of real adversarial playlist names — add to it
rather than loosening a rule.

### The on-screen stats overlay

`I` in the live player (or the chart icon in the top bar) opens a diagnostic overlay reading
libmpv directly: measured resolution, mean video bitrate, audio bitrate, codec/fps,
`cache-speed` as "arriving", demuxer cache, buffer health and watchdog phase. It is the only
place the app shows what a stream *actually* is rather than what the provider called it.

Two details that matter:

- Its sampler only runs while the overlay is open — eight property reads a second is not
  something to do unasked — and it is cancelled in `dispose`.
- Video bitrate is reported as a mean over the last 12 readings, because the instantaneous
  value swings with scene complexity and two instantaneous readings cannot be compared. Below
  eight samples the overlay marks it `(settling)`.

It also keeps a per-quality table of settled measurements for the current channel, ordered by
measured pixel count rather than by label — which is how you tell whether a provider's `4K`
entry is really 4K. That table is session-only and clears on a channel change.

### Measuring the heuristics

`tool/quality_report.dart` prints what the grouping actually finds in a real playlist, and the
near-misses it refused. The rules are conservative enough that the only meaningful question is
whether they still find anything, and that cannot be answered from unit tests.

```bash
curl -s '<xtream base>/player_api.php?username=U&password=P&action=get_live_streams' > /tmp/live.json
```

```bash
dart run tool/quality_report.dart /tmp/live.json
```

It synthesises stream URLs from `stream_id` rather than building them for real, so it cannot
print a subscription credential. It also mirrors the vetting rules and cross-checks its own
count against `QualityIndex.groupCount` — a `MISMATCH` line means the mirror has drifted from
the library and the report below it is lying.

For reference, on a 53,198-channel subscription it finds 874 ladders covering 2,077 channels,
mostly pairs and triples, with none of the cross-country, timeshift or codec false positives
the earlier rules produced.

**The trigger is a congestion detector, not the recovery ladder.** It rides the watchdog's
existing 1s tick and counts rebuffer *episodes* (`paused-for-cache` false→true transitions)
in a rolling window: three one-second stalls in 45s is congestion, one 40s stall is a freeze
the ladder already owns. Before acting it checks `cache-speed > 0` — on a provider outage
that reads zero, the sibling from the same provider would be dead too, and degrading would
cost picture for nothing. It fires `onCongested` directly and **never touches
`_ladderIndex`**; the ladder stays orthogonal.

Two things the controller must keep doing:

- **Verify the bitrate actually dropped.** Labels lie — "ESPN SD" is frequently the same
  feed renamed. `video-bitrate` is sampled before and after; an option that did not shrink is
  blacklisted for the session, or the ladder spends every rung switching between identical
  streams.
- **Poll `watchdog.status` for the restore clock, do not subscribe.** `_emit` deduplicates
  statuses, a manual degrade produces no transition at all, and on a marginal connection the
  phase flickers healthy↔degraded every few seconds — an edge-triggered timer would be reset
  constantly and never fire. A degrade soon after a restore doubles the next restore window.

`QualityController.onApply` must await all the way through its `open()`, for the same reason
`onRecreate` must: `noteStreamOpened()` is only safe to call while `_recovering` is set. A
*manual* quality change passes `userInitiated: true` through to `noteStreamOpened`, which is
what stops the ladder escalating against a stream the user has already replaced.

`StreamTuning.apply` carries the quality parameters rather than a separate `applyQuality`,
because `apply` is the only path that re-applies mpv properties after a `recreate`. Each host
funnels both buffer mode and quality through a single `_applyTuning`, so the buffer-mode
`ref.listen` cannot silently re-enable video while audio-only is active.

Note some providers disable the `get.php` M3U export entirely — one returns a bare HTTP
`884` for it regardless of User-Agent while `player_api.php` answers normally. Add such a
provider as an **Xtream** source, not an M3U URL.

Multi-view is **manual only**: four independent controllers on one uplink would all degrade
and reopen at the same moment, and each reopen re-buffers, worsening the congestion that
triggered it. Automatic degradation there needs cross-slot coordination. The VOD player gets
nothing — it is handed a bare URL with no `Channel`, so there is nothing to look siblings up
by.

### Testing freeze recovery

Unit tests cover the ladder's decision-making with no player attached. To exercise the
real thing:

```bash
# 1. serve an endless realtime-paced MPEG-TS that freezes 25s in, for 70s
python tool/stall_proxy.py --upstream <any HLS url> --script relay:25,stall:70,relay:150 --port 8923

# 2. point the diagnostic harness at it
flutter run -d windows -t lib/dev_harness.dart     --dart-define=URL=http://127.0.0.1:8923/ --dart-define=SECONDS=220
```

For congestion rather than a freeze, use the `throttle:<seconds>@<kbps>` phase, which is
the only one that produces a stream that is *slow* rather than stopped:

```bash
python tool/stall_proxy.py --upstream <any HLS url> --script relay:20,throttle:120@400,relay:120 --port 8923
```

The harness logs `in=` (`cache-speed`) against `need=` (`video-bitrate`) plus running
`rebuffers=` and `degrades=` counts — exactly the detector's inputs and output. Confirm it
fires during `throttle` and not during `relay`. It wires a stand-in for `QualityController`
with three notional rungs: without `onCongested` wired the detector returns early and can
never be observed at all, so do not remove that stub when editing the harness.

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
  `Q` stream quality, `I` stream stats, `R` manual reconnect, `Esc` exit. Multi-view adds `1`–`4` for audio
  slot. `R` is a clean slate: it undoes both the alternate-format fallback and any quality
  degradation. The cheat-sheet strings in `enhanced_video_player.dart` and
  `settings_screen.dart` have to be kept in sync with the switch by hand.
