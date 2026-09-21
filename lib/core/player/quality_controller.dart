import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'stream_quality.dart';
import 'stream_tuning.dart';
import 'stream_watchdog.dart';

/// Opens [option] on the host's player.
///
/// The host is responsible for applying the option's tuning *before* the open
/// (see [StreamTuning.apply]) and for calling
/// [StreamWatchdog.noteStreamOpened] afterwards, passing [userInitiated]
/// straight through so a deliberate quality change is not mistaken for part of
/// an in-flight recovery.
///
/// Must await all the way through the open before returning; see
/// [StreamWatchdog.onDegradeQuality] for what breaks otherwise.
typedef QualityApply = Future<void> Function(
  QualityOption option, {
  required bool userInitiated,
});

/// Owns the quality ladder for one playback surface: which option is playing,
/// when to step down, when it is safe to step back up.
///
/// The watchdog deliberately knows nothing about any of this. It asks the host
/// two questions - "is a lower quality available?" and "please drop one" - and
/// this is what answers them.
class QualityController {
  /// Sustained healthy playback required before quality is restored.
  ///
  /// Much longer than the watchdog's own 15-tick ladder rewind. "The stream
  /// stopped freezing" and "the connection can carry the full bitrate again"
  /// are different claims, and restoring on the first of them just re-enters
  /// the congestion that caused the degrade.
  static const Duration defaultRestoreAfter = Duration(minutes: 3);

  /// Longest the restore window can grow to after failed attempts.
  static const Duration maxRestoreAfter = Duration(minutes: 30);

  /// A degrade this soon after a restore means the restore was premature.
  static const Duration restoreProbation = Duration(minutes: 2);

  /// How long to let a new stream settle before judging whether the bitrate
  /// actually dropped.
  static const Duration verifyShrinkAfter = Duration(seconds: 10);

  /// Poll interval for the restore clock. Low frequency on purpose - this is
  /// not a detector, it only watches a clock.
  static const Duration pollInterval = Duration(seconds: 5);

  final Player? Function() playerRef;
  final StreamWatchdog? Function() watchdogRef;
  final QualityApply onApply;

  /// Whether the automatic path may act at all. Reads the user's setting.
  final bool Function() autoEnabled;

  /// Notifies the host that [current], [canDegrade] or [isDegraded] changed.
  final void Function()? onChanged;

  final Duration restoreAfter;

  QualityController({
    required this.playerRef,
    required this.watchdogRef,
    required this.onApply,
    required this.autoEnabled,
    this.onChanged,
    this.restoreAfter = defaultRestoreAfter,
  });

  List<QualityOption> _options = const [];
  int _index = 0;

  /// Index the user picked by hand, if any.
  ///
  /// Acts as a ceiling on quality: automatic restore never climbs back above a
  /// deliberate choice. Automatic degradation below it is still allowed - the
  /// alternative is freezing to honour a preference.
  int? _manualIndex;

  /// Options that were tried and turned out not to be any smaller. Labels lie
  /// often enough - "ESPN SD" is frequently the same feed renamed - that
  /// without this the ladder can spend every rung switching between streams of
  /// identical bitrate.
  final Set<String> _useless = {};

  Timer? _poll;
  Timer? _verify;
  DateTime? _healthySince;
  DateTime? _lastRestoreAt;
  Duration _currentRestoreAfter = defaultRestoreAfter;
  bool _busy = false;
  bool _disposed = false;

  List<QualityOption> get options => _options;

  QualityOption? get current =>
      _index >= 0 && _index < _options.length ? _options[_index] : null;

  bool get isDegraded => _index > 0;

  /// Whether the automatic path has somewhere lower to go.
  ///
  /// This is what the watchdog's `canDegradeQuality` returns, so it must be
  /// total - it is called from inside a timer callback where a throw would be
  /// lost.
  bool get canDegrade => _nextAutoIndex() != null;

  /// Whether quality can be raised again.
  bool get canRestore => _index > (_manualIndex ?? 0);

  /// Replaces the ladder, as on a channel change.
  ///
  /// Resets the manual choice and the session's useless-option list along with
  /// it: both were about the previous channel.
  void setOptions(List<QualityOption> options) {
    _options = options;
    _index = 0;
    _manualIndex = null;
    _useless.clear();
    _healthySince = null;
    _lastRestoreAt = null;
    _currentRestoreAfter = restoreAfter;
    _verify?.cancel();
    onChanged?.call();
  }

  void start() {
    if (_disposed) return;
    _poll?.cancel();
    _poll = Timer.periodic(pollInterval, (_) => _pollRestore());
  }

  void stop() {
    _poll?.cancel();
    _poll = null;
  }

  void dispose() {
    _disposed = true;
    stop();
    _verify?.cancel();
  }

  /// Steps down one rung. Wired to both the watchdog's congestion detector and
  /// its last-resort ladder rung.
  Future<void> degrade() async {
    if (_disposed || _busy) return;
    final next = _nextAutoIndex();
    if (next == null) return;

    // A degrade hard on the heels of a restore means the restore was wrong.
    // Back the window off so the next attempt is not made as eagerly - and so
    // a marginal connection settles at a quality it can hold rather than
    // oscillating.
    final restoredAt = _lastRestoreAt;
    if (restoredAt != null &&
        DateTime.now().difference(restoredAt) < restoreProbation) {
      _currentRestoreAfter = Duration(
        milliseconds: (_currentRestoreAfter.inMilliseconds * 2)
            .clamp(restoreAfter.inMilliseconds, maxRestoreAfter.inMilliseconds),
      );
      print('[quality] restore was premature; next attempt after '
          '${_currentRestoreAfter.inSeconds}s');
    }

    await _moveTo(next, userInitiated: false);
  }

  /// Applies a choice the user made explicitly.
  ///
  /// Unlike [degrade] this honours [QualityOption.autoSelectable] not at all -
  /// audio-only is a perfectly reasonable thing to ask for, it just is not
  /// something to inflict on someone unasked.
  Future<void> selectManual(QualityOption option) async {
    if (_disposed) return;
    final index = _options.indexOf(option);
    if (index < 0) return;
    _manualIndex = index;
    // Re-trying something explicitly clears the assumption that it is useless.
    _useless.remove(_keyOf(option));
    await _moveTo(index, userInitiated: true);
  }

  /// Steps one rung back up, no further than the user's own choice.
  Future<void> restore({bool userInitiated = false}) async {
    if (_disposed || _busy || !canRestore) return;

    var target = _index - 1;
    final floor = _manualIndex ?? 0;
    if (target < floor) target = floor;

    _lastRestoreAt = DateTime.now();
    await _moveTo(target, userInitiated: userInitiated);
  }

  /// Puts quality back to the source and forgets the manual choice.
  ///
  /// This is what the player's manual-reconnect path uses: `R` means "start
  /// over from a clean slate", which includes undoing a degrade.
  Future<void> reset() async {
    if (_disposed) return;
    _manualIndex = null;
    _currentRestoreAfter = restoreAfter;
    if (_index != 0) {
      await _moveTo(0, userInitiated: true);
    }
  }

  Future<void> _moveTo(int index, {required bool userInitiated}) async {
    final option = index < _options.length ? _options[index] : null;
    if (option == null) return;

    _busy = true;
    final before = await _readVideoBitrate();
    try {
      print('[quality] ${userInitiated ? 'user' : 'auto'} '
          '-> ${option.label} (${option.kind.name})');
      _index = index;
      _healthySince = null;
      onChanged?.call();
      await onApply(option, userInitiated: userInitiated);
    } catch (e) {
      print('[quality] could not switch to ${option.label}: $e');
    } finally {
      _busy = false;
    }

    // Only worth checking on the way down, and only for a switch that was
    // supposed to change the stream rather than how it is decoded.
    if (!userInitiated && option.kind == QualityKind.sibling) {
      _scheduleShrinkCheck(option, before);
    }
  }

  /// Marks [option] useless if the bitrate did not actually fall.
  void _scheduleShrinkCheck(QualityOption option, double? before) {
    if (before == null || before <= 0) return;
    _verify?.cancel();
    _verify = Timer(verifyShrinkAfter, () async {
      if (_disposed) return;
      final after = await _readVideoBitrate();
      if (after == null || after <= 0) return;
      // 10% of slack, because reported bitrate wanders with scene complexity.
      if (after >= before * 0.9) {
        print('[quality] ${option.label} is no smaller '
            '(${before.round()} -> ${after.round()} bps); not using it again');
        _useless.add(_keyOf(option));
        onChanged?.call();
      }
    });
  }

  Future<double?> _readVideoBitrate() async {
    final player = playerRef();
    if (player == null) return null;
    return StreamTuning.readDouble(player, 'video-bitrate');
  }

  /// Next rung the automatic path is allowed to take, or null at the floor.
  int? _nextAutoIndex() {
    for (var i = _index + 1; i < _options.length; i++) {
      final option = _options[i];
      if (!option.autoSelectable) continue;
      if (_useless.contains(_keyOf(option))) continue;
      return i;
    }
    return null;
  }

  static String _keyOf(QualityOption option) =>
      '${option.kind.name}:${option.url}';

  /// Restores quality after a long enough stretch of healthy playback.
  ///
  /// Polls the watchdog's status rather than subscribing to it. Status
  /// emissions are deduplicated, a manual degrade produces no transition at
  /// all, and on a marginal connection the phase flickers between healthy and
  /// degraded every few seconds - so an edge-triggered timer would be reset
  /// constantly and never fire.
  Future<void> _pollRestore() async {
    if (_disposed || _busy) return;
    if (!autoEnabled() || !canRestore) {
      _healthySince = null;
      return;
    }

    final status = watchdogRef()?.status;
    final player = playerRef();
    final healthy =
        status != null && status.isHealthy && (player?.state.playing ?? false);

    if (!healthy) {
      _healthySince = null;
      return;
    }

    final since = _healthySince ??= DateTime.now();
    if (DateTime.now().difference(since) < _currentRestoreAfter) return;

    _healthySince = null;
    print('[quality] healthy for ${_currentRestoreAfter.inSeconds}s; '
        'trying a higher quality');
    await restore();
  }
}
