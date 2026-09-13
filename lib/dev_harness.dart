/// Headless-ish diagnostic harness for the stream resilience layer.
///
/// Exists because the things worth verifying - whether this machine's libmpv
/// actually accepts the tuning, whether the watchdog's property reads return
/// real values, and whether the recovery ladder recovers from a real freeze -
/// cannot be checked by static analysis or by unit tests that have no libmpv.
///
///     flutter run -d windows -t lib/dev_harness.dart \
///         --dart-define=URL=http://127.0.0.1:8899/
///
/// Pair it with tool/stall_proxy.py to induce a freeze on a schedule.
/// Delete this file once the resilience work is settled.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'core/player/stream_tuning.dart';
import 'core/player/stream_watchdog.dart';

const String kUrl = String.fromEnvironment('URL');
const int kRunSeconds = int.fromEnvironment('SECONDS', defaultValue: 150);

void log(String message) => debugPrint('[harness] $message');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const _HarnessApp());
}

class _HarnessApp extends StatefulWidget {
  const _HarnessApp();

  @override
  State<_HarnessApp> createState() => _HarnessAppState();
}

class _HarnessAppState extends State<_HarnessApp> {
  Player? _player;
  VideoController? _controller;
  StreamWatchdog? _watchdog;
  String _url = kUrl;
  int _elapsed = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (kUrl.isEmpty) {
      log('FAIL: pass --dart-define=URL=<stream url>');
      return;
    }

    log('=' * 68);
    log('stream resilience harness');
    log('url: ${StreamTuning.redactUrl(kUrl)}');
    log('=' * 68);

    await _createPlayer();
    await _verifyTuning();

    _watchdog = StreamWatchdog(
      playerRef: () => _player,
      urlRef: () => _url,
      enabled: () => true,
      onRecreate: _recreate,
      onUrlChanged: (url) => _url = url,
      onStatus: (s) => log('WATCHDOG  ${s.phase.name.toUpperCase()}'
          '${s.cause != null ? ' cause=${s.cause!.name}' : ''}'
          '${s.step != null ? ' step=${s.step!.name}' : ''}'
          '  "${s.message}"'),
    );

    log('--- opening stream ---');
    await _player!.open(Media(_url));
    _watchdog!
      ..noteStreamOpened()
      ..start();

    _sample();
  }

  Future<void> _createPlayer() async {
    final player = Player(
      configuration: const PlayerConfiguration(bufferSize: 64 * 1024 * 1024),
    );
    _controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: false,
      ),
    );
    player.stream.error.listen((e) {
      if (e.isNotEmpty) log('PLAYER ERROR: ${StreamTuning.redactUrl(e)}');
    });

    _player = player;
    if (mounted) setState(() {});

    final tuneStart = DateTime.now();
    await StreamTuning.apply(player, mode: BufferMode.normal, isLive: true);
    log('tuning applied in ${DateTime.now().difference(tuneStart).inMilliseconds}ms');
  }

  Future<void> _recreate(String url) async {
    log('--- recreating player ---');
    final old = _player;
    _player = null;
    _controller = null;
    if (mounted) setState(() {});
    await Future.delayed(const Duration(milliseconds: 100));
    await old?.dispose();
    await _createPlayer();
    await _player!.open(Media(url));
    _watchdog!.noteStreamOpened();
  }

  /// Reads every tuned property back out of libmpv. Silence from
  /// StreamTuning.apply only means no exception was thrown - reading the value
  /// back is what actually proves mpv accepted it.
  Future<void> _verifyTuning() async {
    log('--- verifying mpv accepted the tuning ---');
    const expected = {
      'network-timeout': '10',
      'cache': 'yes',
      'cache-secs': '10',
      'demuxer-readahead-secs': '10',
      'demuxer-max-bytes': '67108864',
      'cache-pause': 'yes',
      'keep-open': 'no',
      'framedrop': 'vo',
      'stream-lavf-o': null, // just prove it is non-empty
      'user-agent': 'IPTV Player/1.0',
    };

    var failures = 0;
    for (final entry in expected.entries) {
      final actual = await StreamTuning.readProperty(_player!, entry.key);
      final ok = actual != null &&
          (entry.value == null || actual == entry.value);
      if (!ok) failures++;
      log('  ${ok ? "OK  " : "FAIL"} ${entry.key.padRight(24)} = '
          '${actual ?? "<unreadable>"}'
          '${entry.value != null && actual != entry.value ? "  (wanted ${entry.value})" : ""}');
    }
    log(failures == 0
        ? '  all tuning properties accepted'
        : '  $failures properties NOT applied - tuning is partly inert');

    // The watchdog's detection signals. If these read null, the starved-vs-
    // wedged distinction silently degrades on this platform.
    log('--- watchdog signal availability ---');
    for (final property in [
      'demuxer-cache-time',
      'paused-for-cache',
      'core-idle',
    ]) {
      final value = await StreamTuning.readProperty(_player!, property);
      log('  ${value != null ? "OK  " : "NULL"} $property = ${value ?? "<null>"}');
    }
  }

  void _sample() {
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      _elapsed++;
      if (_elapsed > kRunSeconds) {
        log('=' * 68);
        log('done after ${kRunSeconds}s');
        timer.cancel();
        return;
      }

      final player = _player;
      if (player == null) {
        log('t=${_elapsed}s  <player rebuilding>');
        return;
      }

      final cache = await StreamTuning.readProperty(player, 'demuxer-cache-time');
      final pausedForCache =
          await StreamTuning.readProperty(player, 'paused-for-cache');

      log('t=${_elapsed.toString().padLeft(3)}s  '
          'pos=${player.state.position.inMilliseconds.toString().padLeft(7)}ms  '
          'buf=${player.state.buffer.inSeconds.toString().padLeft(3)}s  '
          'cacheTime=${(cache ?? "-").padLeft(8)}  '
          'playing=${player.state.playing}  '
          'buffering=${player.state.buffering}  '
          'pausedForCache=${pausedForCache ?? "-"}');

      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _watchdog?.dispose();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (controller != null) Video(controller: controller),
            Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  't=${_elapsed}s  ${_watchdog?.status.phase.name ?? "-"}\n'
                  '${_watchdog?.status.message ?? ""}',
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
