# Handoff — IPTV Player

_Last updated: 2026-09-13. Snapshot for whoever picks this up next._

For architecture, conventions, and the traps that will bite you, read
[`CLAUDE.md`](CLAUDE.md) first — this document is **status and next steps only** and does
not repeat it.

---

## TL;DR

- The headline work this session was **automatic stream freeze recovery** — the player now
  detects a frozen live stream and recovers on its own, with no user interaction. This is
  the thing to protect; see the design rule below.
- Everything is committed and pushed to `main` (`HEAD` = `9036e29` at time of writing).
- `flutter analyze`: **0 errors**, 1 pre-existing warning. `flutter test`: **20 passing.**
- **Windows and Android both build and run.** macOS and Linux were not touched this session.
  iOS and web are not buildable targets (no `ios/`, no `web/`).

---

## What changed this session (3 commits)

| Commit | Summary |
|---|---|
| `0f4502d` | **Automatic stream freeze detection & recovery.** New `lib/core/player/` (`stream_tuning.dart`, `stream_watchdog.dart`), wired into all four playback surfaces. Adds the freeze-injector (`tool/stall_proxy.py`) and diagnostic harness (`lib/dev_harness.dart`), 20 unit tests, and immersive fullscreen on the players. |
| `5884509` | **`file_picker` 6 → 12.** The old version used Flutter's removed v1 Android embedding and broke the APK build outright. Also carries the toolchain churn from the Flutter upgrade. |
| `9036e29` | **Mobile layout fix.** `SafeArea` in the home shell so tab headers stop rendering under the phone's status bar. |

The freeze-recovery design is documented in `CLAUDE.md` under "Stream resilience." The one
rule that must survive: **recovery never latches off** — it escalates a ladder and then
backs off and retries forever. There is no terminal "gave up" state, and a unit test guards
this. The previous implementation stopped after 3 attempts and left the user staring at a
frozen frame; do not reintroduce that.

---

## Verified vs NOT verified

Be honest with yourself about this line — it is the most useful thing in this doc.

### Verified (seen working, not assumed)
- **Windows app** builds under Flutter 3.47.2 and launches clean (no exceptions at startup).
- **Freeze recovery against real libmpv (Windows).** An injected 70-second freeze (socket
  held open, no bytes) was detected and recovered automatically ~5 s after the stream
  returned. mpv accepts every tuned property including the FFmpeg `reconnect=*` options.
- **Android APK builds and runs on real hardware** — a live ESPN stream played on the
  user's phone, which confirms the media_kit/libmpv engine (and therefore the resilience
  layer) runs on Android.
- **20 unit tests pass**, `flutter analyze` has 0 errors.

### NOT verified (do not claim these work)
- **Freeze recovery on Android hardware.** Same engine as Windows, but the stall-proxy test
  was never run against a device. High confidence, zero direct evidence.
- **The mobile UI fixes on-device** (SafeArea + immersive fullscreen). Code is pushed and an
  APK is built, but not yet confirmed on the phone. **First thing to check on next install.**
- **macOS and Linux builds** — not attempted this session.
- **Xtream series/episodes** — never wired to the UI (pre-existing; see `CLAUDE.md`).
- **Any interactive flow driven end-to-end** — adding a playlist, channel switching,
  multi-view, the on-screen recovery banners — verified only by analysis/build, not by
  actually clicking through the running app.

---

## Environment (important — the project moved)

- **Flutter was upgraded 3.32.4 → 3.47.2 this session.** This was necessary: the old SDK
  did not recognise Visual Studio 2026 and could not build for Windows at all, and it was
  14 months stale. The project analyzes clean on the new SDK.
- **Windows builds require Visual Studio 2026 (major 18)** to be matched by Flutter ≥ 3.47,
  which maps `18 => 'Visual Studio 18 2026'`. On an older Flutter the Windows build fails
  with a "could not find Visual Studio" CMake error.
- **Android build prerequisites** (already satisfied on this machine, needed on a fresh one):
  SDK platform `android-36` installed and SDK licenses accepted
  (`sdkmanager "platforms;android-36"` and `flutter doctor --android-licenses`).
- `flutter analyze` / `flutter build` will re-resolve `pubspec.lock` and may shift
  transitive versions; direct dependencies are pinned in `pubspec.yaml`.

---

## Build & run

```bash
flutter pub get
flutter analyze                       # expect 0 errors
flutter test                          # expect 20 passing
flutter run -d windows                # verified working
flutter build apk --split-per-abi     # verified working; arm64 is the phone target
```

Built APKs land in `build/app/outputs/flutter-apk/`. **`app-arm64-v8a-release.apk` is the
one for a modern phone.** These are **debug-signed** with `applicationId =
com.example.iptv_player` — fine for sideloading to your own device, **not** shippable to the
Play Store or to other people.

Install to a USB-connected phone (USB debugging on):

```bash
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

To exercise freeze recovery for real, see "Testing freeze recovery" in `CLAUDE.md`
(`tool/stall_proxy.py` + `lib/dev_harness.dart`).

---

## Outstanding work, roughly prioritised

**Do before trusting the new build**
1. Install the current APK on the phone and confirm the two UI fixes: headers clear the
   status bar, and the status bar + nav buttons hide while a video is playing.
2. Run the stall-proxy freeze test against the phone to confirm recovery works on Android,
   not just Windows.

**Do before distributing to anyone else**
3. Generate a real Android signing key and set a unique `applicationId` (both are TODO in
   `android/app/build.gradle.kts`).
4. Bump Gradle / AGP / Kotlin. Flutter 3.47 warns these versions "will soon be dropped";
   a future upgrade will turn the warnings into hard build errors. Do it in its own session
   with a verify build — it can introduce its own breakage.

**Pre-existing issues (not introduced this session; see `CLAUDE.md` for detail)**
5. **M3U channel IDs are not stable** (`_uuid.v4()` per parse), so M3U favorites/history
   orphan on every playlist reload. Xtream is unaffected.
6. **Xtream credentials are stored in plaintext** in Hive and embedded in stream URLs.
7. **Series/episodes are not wired to the UI** — the service methods exist but nothing calls
   them; VOD is movies only.
8. Hardware acceleration is force-disabled in both media_kit players (Linux GPU-crash
   workaround) — costs performance on Windows/Android. Verbose mpv logging is on in the
   shipped path.

**Cleanup (optional)**
9. `lib/dev_harness.dart` and `tool/stall_proxy.py` are test scaffolding. Keep them for
   regression testing, or delete once the resilience work is considered settled — the
   harness header says as much.

---

## Repo facts

- Remote: `github.com/mikesawayda-adaptivesoftware/IPTV-Player`, branch `main`.
- `deploy.sh` force-sets the remote and pushes to `main` — **do not** run it as part of
  normal work; use plain `git`.
- No CI is configured. `flutter analyze` + `flutter test` are the gate; run them before
  every push.
