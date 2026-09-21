import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/player/stream_tuning.dart';
import 'package:iptv_player/core/player/stream_watchdog.dart';

/// Builds a watchdog with no real player attached. Every recovery step is a
/// no-op against a null player, which is exactly what these tests want - the
/// subject here is the ladder's decision-making, not media_kit.
StreamWatchdog buildWatchdog({
  String url = 'http://example.com/live/u/p/1.ts',
  bool canRecreate = true,
  bool autoReconnect = true,
  required List<RecoveryStep> performed,
  List<WatchdogStatus>? statuses,
  bool Function()? canDegradeQuality,
  Future<void> Function()? onDegradeQuality,
}) {
  var currentUrl = url;
  return StreamWatchdog(
    playerRef: () => null,
    urlRef: () => currentUrl,
    enabled: () => autoReconnect,
    verifyWindow: Duration.zero,
    backOffStep: Duration.zero,
    maxBackOff: Duration.zero,
    onRecreate: canRecreate ? (_) async => performed.add(RecoveryStep.recreate) : null,
    canDegradeQuality: canDegradeQuality,
    onDegradeQuality: onDegradeQuality,
    onUrlChanged: (value) => currentUrl = value,
    onStatus: (status) {
      statuses?.add(status);
      if (status.phase == WatchdogPhase.recovering && status.step != null) {
        performed.add(status.step!);
      }
    },
  );
}

void main() {
  group('StreamTuning.alternateUrl', () {
    test('swaps a raw TS stream for its HLS equivalent', () {
      expect(
        StreamTuning.alternateUrl('http://host:8080/live/user/pass/1234.ts'),
        'http://host:8080/live/user/pass/1234.m3u8',
      );
    });

    test('swaps an HLS playlist back to raw TS', () {
      expect(
        StreamTuning.alternateUrl('http://host/live/user/pass/1234.m3u8'),
        'http://host/live/user/pass/1234.ts',
      );
    });

    test('preserves the query string', () {
      expect(
        StreamTuning.alternateUrl('http://host/s/1.ts?token=abc'),
        'http://host/s/1.m3u8?token=abc',
      );
    });

    test('returns null when there is no alternative to offer', () {
      expect(StreamTuning.alternateUrl('http://host/stream'), isNull);
      expect(StreamTuning.alternateUrl('http://host/movie.mkv'), isNull);
    });
  });

  group('StreamTuning.redactUrl', () {
    test('strips the credentials Xtream embeds in the stream path', () {
      expect(
        StreamTuning.redactUrl('http://host:8080/live/joe/hunter2/1234.ts'),
        'http://host:8080/live/***/***/1234.ts',
      );
      expect(
        StreamTuning.redactUrl('http://host/movie/joe/hunter2/9.mp4'),
        'http://host/movie/***/***/9.mp4',
      );
    });

    test('strips credential query parameters', () {
      expect(
        StreamTuning.redactUrl(
            'http://host/player_api.php?username=joe&password=hunter2'),
        'http://host/player_api.php?username=***&password=***',
      );
    });

    test('redacts URLs embedded in longer text, such as error messages', () {
      final redacted = StreamTuning.redactUrl(
          'Failed to open http://host/live/joe/hunter2/1.ts: timed out');
      expect(redacted, contains('/live/***/***/1.ts'));
      expect(redacted, isNot(contains('hunter2')));
    });

    test('leaves credential-free URLs alone', () {
      expect(
        StreamTuning.redactUrl('http://host/playlist.m3u8'),
        'http://host/playlist.m3u8',
      );
    });
  });

  group('StreamTuning.bufferHealth', () {
    // state.buffer is an absolute media timestamp, so health has to be derived
    // from the gap to the playhead. Measured on a real stream, buffer and
    // position both sat around 225s with ~0.4s between them - dividing buffer
    // by the target pinned the old meter at 100% forever.
    test('measures readahead, not the absolute buffer timestamp', () {
      expect(
        StreamTuning.bufferHealth(
          const Duration(seconds: 225),
          const Duration(milliseconds: 225123),
          10,
        ),
        closeTo(0.0, 0.05),
      );
    });

    test('reports a full buffer when readahead meets the target', () {
      expect(
        StreamTuning.bufferHealth(
          const Duration(seconds: 40),
          const Duration(seconds: 30),
          10,
        ),
        1.0,
      );
    });

    test('reports half a buffer at half the target', () {
      expect(
        StreamTuning.bufferHealth(
          const Duration(seconds: 35),
          const Duration(seconds: 30),
          10,
        ),
        closeTo(0.5, 0.001),
      );
    });

    test('clamps rather than going negative when the playhead is ahead', () {
      expect(
        StreamTuning.bufferHealth(
          const Duration(seconds: 10),
          const Duration(seconds: 30),
          10,
        ),
        0.0,
      );
    });
  });

  group('recovery ladder', () {
    test('escalates through the ladder one step at a time', () async {
      final performed = <RecoveryStep>[];
      final watchdog = buildWatchdog(performed: performed);

      // The first call is user-initiated, which deliberately skips the nudge.
      await watchdog.forceRecovery();
      for (var i = 0; i < 3; i++) {
        await watchdog.forceRecovery(userInitiated: false);
      }

      expect(performed, [
        RecoveryStep.reopen,
        RecoveryStep.hardReopen,
        RecoveryStep.recreate,
        RecoveryStep.alternateUrl,
      ]);

      watchdog.dispose();
    });

    test('skips recreate when the host cannot rebuild the player', () async {
      final performed = <RecoveryStep>[];
      final watchdog = buildWatchdog(performed: performed, canRecreate: false);

      await watchdog.forceRecovery();
      await watchdog.forceRecovery(userInitiated: false);
      await watchdog.forceRecovery(userInitiated: false);

      expect(performed, isNot(contains(RecoveryStep.recreate)));
      expect(performed, contains(RecoveryStep.alternateUrl));

      watchdog.dispose();
    });

    test('skips the alternate-format step when no alternative exists', () async {
      final performed = <RecoveryStep>[];
      final watchdog = buildWatchdog(
        url: 'http://host/live/stream',
        performed: performed,
      );

      for (var i = 0; i < 6; i++) {
        await watchdog.forceRecovery(userInitiated: false);
      }

      expect(performed, isNot(contains(RecoveryStep.alternateUrl)));

      watchdog.dispose();
    });

    // The point of the whole watchdog. A recovery system that latches off after
    // N attempts leaves the user staring at a frozen frame until they press a
    // button, which is the behaviour this replaced.
    test('never reaches a terminal state - it backs off and starts over',
        () async {
      final statuses = <WatchdogStatus>[];
      final performed = <RecoveryStep>[];
      final watchdog = buildWatchdog(performed: performed, statuses: statuses);

      // Run well past the length of the ladder.
      for (var i = 0; i < 20; i++) {
        await watchdog.forceRecovery(userInitiated: false);
      }

      expect(
        statuses.any((s) => s.phase == WatchdogPhase.backingOff),
        isTrue,
        reason: 'exhausting the ladder should back off',
      );

      // Having backed off, it must resume attempting recovery rather than
      // stopping.
      final afterBackOff = statuses
          .skipWhile((s) => s.phase != WatchdogPhase.backingOff)
          .where((s) => s.phase == WatchdogPhase.recovering);
      expect(
        afterBackOff,
        isNotEmpty,
        reason: 'recovery must continue after backing off',
      );

      // It must keep cycling, not back off once and stop.
      final cycles = statuses
          .where((s) => s.phase == WatchdogPhase.backingOff)
          .map((s) => s.cycle)
          .toList();
      expect(cycles.length, greaterThan(1));
      expect(cycles, orderedEquals(List.generate(cycles.length, (i) => i + 1)));

      watchdog.dispose();
    });

    test('drops quality as the last rung when a lower one exists', () async {
      final performed = <RecoveryStep>[];
      final watchdog = buildWatchdog(
        performed: performed,
        canDegradeQuality: () => true,
        onDegradeQuality: () async {},
      );

      for (var i = 0; i < 6; i++) {
        await watchdog.forceRecovery(userInitiated: false);
      }

      expect(performed, contains(RecoveryStep.degradeQuality));
      expect(
        performed.indexOf(RecoveryStep.degradeQuality),
        greaterThan(performed.indexOf(RecoveryStep.alternateUrl)),
        reason: 'quality is the last resort, after the repair steps',
      );

      watchdog.dispose();
    });

    test('skips the quality step when already at the lowest available',
        () async {
      final performed = <RecoveryStep>[];
      final watchdog = buildWatchdog(
        performed: performed,
        canDegradeQuality: () => false,
        onDegradeQuality: () async {},
      );

      for (var i = 0; i < 8; i++) {
        await watchdog.forceRecovery(userInitiated: false);
      }

      expect(performed, isNot(contains(RecoveryStep.degradeQuality)));

      watchdog.dispose();
    });

    // The never-latch-off invariant, re-checked for the rung that can run out.
    // Unlike every other step, `degradeQuality` becomes permanently unavailable
    // once the bottom of the quality ladder is reached - so this is the case
    // where a "gave up" state would most plausibly creep back in.
    test('keeps cycling after quality bottoms out', () async {
      final statuses = <WatchdogStatus>[];
      final performed = <RecoveryStep>[];

      // Attempts are counted off the status stream, not off onDegradeQuality:
      // these tests run with no player attached, so _perform returns before any
      // step body executes. Two steps of headroom, then the floor.
      int attempts() => statuses
          .where((s) =>
              s.phase == WatchdogPhase.recovering &&
              s.step == RecoveryStep.degradeQuality)
          .length;

      final watchdog = buildWatchdog(
        performed: performed,
        statuses: statuses,
        canDegradeQuality: () => attempts() < 2,
        onDegradeQuality: () async {},
      );

      for (var i = 0; i < 30; i++) {
        await watchdog.forceRecovery(userInitiated: false);
      }

      expect(attempts(), 2, reason: 'the quality ladder should be exhausted');

      final cycles = statuses
          .where((s) => s.phase == WatchdogPhase.backingOff)
          .map((s) => s.cycle)
          .toList();
      expect(cycles.length, greaterThan(1));
      expect(cycles, orderedEquals(List.generate(cycles.length, (i) => i + 1)));

      watchdog.dispose();
    });

    // canDegradeQuality is host code reading provider state, so it can throw
    // from a disposed widget. The availability check runs inside an unawaited
    // timer callback; an escaping exception there would silently drop the
    // escalation instead of falling through to the next rung.
    test('treats a throwing availability check as unavailable', () async {
      final statuses = <WatchdogStatus>[];
      final performed = <RecoveryStep>[];
      final watchdog = buildWatchdog(
        performed: performed,
        statuses: statuses,
        canDegradeQuality: () => throw StateError('disposed'),
        onDegradeQuality: () async {},
      );

      for (var i = 0; i < 12; i++) {
        await watchdog.forceRecovery(userInitiated: false);
      }

      expect(performed, isNot(contains(RecoveryStep.degradeQuality)));
      expect(
        statuses.where((s) => s.phase == WatchdogPhase.backingOff),
        isNotEmpty,
        reason: 'a throwing check must not stall the ladder',
      );

      watchdog.dispose();
    });

    // A quality change the user picked is not part of whatever recovery happens
    // to be in flight. Without the userInitiated escape hatch its open is
    // swallowed by the _recovering guard and the ladder carries on escalating
    // against a stream the user has already replaced.
    test('a user-initiated open rewinds the ladder even mid-recovery',
        () async {
      final performed = <RecoveryStep>[];
      late StreamWatchdog watchdog;
      var rewound = false;

      watchdog = StreamWatchdog(
        playerRef: () => null,
        urlRef: () => 'http://example.com/live/u/p/1.ts',
        enabled: () => true,
        verifyWindow: Duration.zero,
        backOffStep: Duration.zero,
        maxBackOff: Duration.zero,
        onStatus: (status) {
          if (status.phase != WatchdogPhase.recovering ||
              status.step == null) {
            return;
          }
          performed.add(status.step!);
          // This callback runs from inside the escalation, so _recovering is
          // set - which is exactly the state the userInitiated flag exists to
          // punch through. Stands in for the user picking a different quality
          // while the watchdog happens to be mid-recovery.
          if (!rewound && status.step == RecoveryStep.hardReopen) {
            rewound = true;
            watchdog.noteStreamOpened(userInitiated: true);
          }
        },
      );

      // nudge, reopen, hardReopen - the last of which rewinds.
      for (var i = 0; i < 3; i++) {
        await watchdog.forceRecovery(userInitiated: false);
      }
      expect(rewound, isTrue);
      performed.clear();

      await watchdog.forceRecovery(userInitiated: false);
      expect(performed.first, RecoveryStep.nudge);

      watchdog.dispose();
    });

    test('reports recovery progress for the UI to display', () async {
      final statuses = <WatchdogStatus>[];
      final watchdog =
          buildWatchdog(performed: [], statuses: statuses);

      await watchdog.forceRecovery();

      expect(statuses.first.phase, WatchdogPhase.recovering);
      expect(statuses.first.message, isNotEmpty);
      expect(statuses.last.isRecovering, isTrue);

      watchdog.dispose();
    });

    test('noteStreamOpened rewinds the ladder to its cheapest step', () async {
      final performed = <RecoveryStep>[];
      final watchdog = buildWatchdog(performed: performed);

      await watchdog.forceRecovery(userInitiated: false);
      await watchdog.forceRecovery(userInitiated: false);
      performed.clear();

      // A channel change should not inherit the previous stream's escalation.
      watchdog.noteStreamOpened();
      await watchdog.forceRecovery(userInitiated: false);

      expect(performed.first, RecoveryStep.nudge);

      watchdog.dispose();
    });

    // Observed live: recreate re-opens the stream, the host reports the open,
    // and the ladder rewound to nudge - so it cycled the first four rungs
    // forever and never reached the alternate-format fallback.
    test('a recovery-driven reopen does not rewind the ladder', () async {
      final performed = <RecoveryStep>[];
      late StreamWatchdog watchdog;
      watchdog = StreamWatchdog(
        playerRef: () => null,
        urlRef: () => 'http://host/live/u/p/1.ts',
        enabled: () => true,
        verifyWindow: Duration.zero,
        backOffStep: Duration.zero,
        maxBackOff: Duration.zero,
        // Mimic a host that reports every recovery-driven open, as all four
        // real call sites do.
        onRecreate: (_) async {
          performed.add(RecoveryStep.recreate);
          watchdog.noteStreamOpened();
        },
        onStatus: (status) {
          if (status.phase == WatchdogPhase.recovering && status.step != null) {
            performed.add(status.step!);
          }
        },
      );

      for (var i = 0; i < 5; i++) {
        await watchdog.forceRecovery(userInitiated: false);
      }

      expect(
        performed,
        contains(RecoveryStep.alternateUrl),
        reason: 'ladder must keep climbing past recreate',
      );

      watchdog.dispose();
    });

    test('does not act while auto reconnect is disabled', () async {
      final performed = <RecoveryStep>[];
      final watchdog = buildWatchdog(
        performed: performed,
        autoReconnect: false,
      );

      watchdog.start();
      await Future.delayed(const Duration(milliseconds: 50));

      expect(performed, isEmpty);

      watchdog.dispose();
    });
  });
}
