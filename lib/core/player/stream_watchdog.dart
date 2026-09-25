import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'stream_tuning.dart';

/// What the watchdog is doing right now, for display in the player UI.
enum WatchdogPhase {
  /// Playback is advancing normally.
  healthy,

  /// A stall signal has been seen but has not yet crossed the freeze
  /// threshold. Worth warning about; not yet worth acting on.
  degraded,

  /// A recovery step is being performed.
  recovering,

  /// A recovery step was performed and we are waiting to see whether it took.
  verifying,

  /// The ladder was exhausted; backing off before starting it over. Recovery is
  /// still in progress - this is never a terminal state.
  backingOff,
}

/// Why the watchdog believes playback is frozen. Different causes deserve
/// different first moves, and this is also the most useful thing to log.
enum FreezeCause {
  /// Neither the playhead nor the demuxer cache is advancing - no data is
  /// arriving. Almost always the network or the provider.
  starved,

  /// Data is still arriving but the playhead is not moving - the decoder or
  /// renderer is wedged. Reopening the stream will not help; the player itself
  /// has to be rebuilt.
  wedged,

  /// mpv has been parked waiting for its cache to refill for far longer than
  /// the configured buffer target.
  stuckBuffering,

  /// The stream was opened but never produced a first frame.
  neverStarted,
}

/// One rung of the recovery ladder, cheapest first.
enum RecoveryStep {
  /// Toggle pause. Clears a surprising number of transient renderer stalls and
  /// costs nothing.
  nudge,

  /// Re-open the same URL on the existing player.
  reopen,

  /// Stop, let the demuxer tear down, then re-open. Clears a poisoned cache
  /// that a plain re-open would inherit.
  hardReopen,

  /// Dispose the player entirely and build a new one. This is the step that
  /// fixes a wedged libmpv/FFmpeg state, which no amount of re-opening will.
  recreate,

  /// Re-open against the provider's other stream format (.ts <-> .m3u8).
  alternateUrl,

  /// Ask the host to drop to a lower-quality version of the stream.
  ///
  /// Last resort, and the only rung whose effect outlives the recovery: every
  /// other step leaves the user exactly where they started, whereas this one
  /// changes what they are watching until something restores it. The primary
  /// trigger for degrading is not this rung but the congestion detector - see
  /// [StreamWatchdog.onCongested].
  degradeQuality,
}

class WatchdogStatus {
  final WatchdogPhase phase;
  final FreezeCause? cause;
  final RecoveryStep? step;

  /// How many times the full ladder has been exhausted. 0 during the first
  /// pass through.
  final int cycle;

  final String message;

  const WatchdogStatus({
    required this.phase,
    required this.message,
    this.cause,
    this.step,
    this.cycle = 0,
  });

  bool get isHealthy => phase == WatchdogPhase.healthy;
  bool get isRecovering =>
      phase == WatchdogPhase.recovering ||
      phase == WatchdogPhase.verifying ||
      phase == WatchdogPhase.backingOff;
}

/// Detects frozen playback and recovers from it without user interaction.
///
/// ## Why this does not use player events
///
/// The obvious way to detect a freeze is to listen to the position stream and
/// notice it stop changing. That does not work: when a stream truly freezes,
/// libmpv stops emitting position events altogether, so the listener that was
/// supposed to notice the stall is itself starved. Detection has to be driven
/// by an independent clock that keeps ticking regardless of what the player is
/// doing, which is what [_timer] is.
///
/// ## Why it never gives up
///
/// A recovery system that disables itself after N attempts hands the problem
/// back to the user, which defeats the point. When the ladder is exhausted this
/// backs off and starts over, indefinitely, so a provider outage that resolves
/// itself five minutes later resumes on its own. [WatchdogPhase] has no
/// terminal failure state by design.
class StreamWatchdog {
  /// How often health is sampled. Also the unit for every threshold below.
  static const Duration tickInterval = Duration(seconds: 1);

  /// No data arriving for this long while playing.
  static const int starveThresholdTicks = 6;

  /// Data arriving but playhead stuck for this long.
  static const int wedgeThresholdTicks = 5;

  /// Parked waiting on cache for this long.
  static const int stuckBufferingThresholdTicks = 12;

  /// Opened but no first frame after this long.
  static const int startupThresholdTicks = 20;

  /// Consecutive healthy seconds required to declare the stream recovered and
  /// rewind the ladder back to its cheapest step.
  static const int healthyResetTicks = 15;

  /// Default grace period after a recovery step before another may be
  /// attempted. Has to comfortably exceed the time it takes a healthy stream to
  /// reopen and produce its first frame, or the ladder races ahead of a
  /// recovery that was actually working.
  static const Duration defaultVerifyWindow = Duration(seconds: 12);

  /// Rebuffer episodes inside [congestionWindowTicks] that mean the connection
  /// cannot sustain the current bitrate.
  ///
  /// Counting episode *starts* rather than stalled seconds is what separates
  /// this from the freeze detector: three one-second stalls in a minute is
  /// congestion, while one forty-second stall is a freeze.
  static const int congestionEpisodeThreshold = 3;

  /// Rolling window the episode count is measured over.
  static const int congestionWindowTicks = 45;

  /// Ladder order. Cheap and non-disruptive first, so a transient hiccup is
  /// fixed without the user noticing a reload.
  static const List<RecoveryStep> ladder = [
    RecoveryStep.nudge,
    RecoveryStep.reopen,
    RecoveryStep.hardReopen,
    RecoveryStep.recreate,
    RecoveryStep.alternateUrl,
    RecoveryStep.degradeQuality,
  ];

  /// Returns the player to watch. Called fresh on every access rather than
  /// held, because [RecoveryStep.recreate] replaces the instance.
  final Player? Function() playerRef;

  /// Current stream URL.
  final String Function() urlRef;

  /// Disposes and rebuilds the player, then opens [url] on the new instance.
  /// When null, [RecoveryStep.recreate] is skipped.
  final Future<void> Function(String url)? onRecreate;

  /// Opens [url] on the existing player. Defaults to `player.open(Media(url))`.
  final Future<void> Function(String url)? onOpen;

  /// Called when [RecoveryStep.alternateUrl] switches formats, so the host can
  /// persist the working URL.
  final void Function(String url)? onUrlChanged;

  /// Whether a lower-quality version of the current stream is available.
  ///
  /// Unlike the other availability checks this is dynamic state that the rung
  /// itself consumes - running a degrade is what eventually makes this return
  /// false. Returning false is how the host says "already at the floor", which
  /// makes the rung skip rather than no-op. It must be total; a throw is caught
  /// and treated as false.
  final bool Function()? canDegradeQuality;

  /// Drops one step down the quality ladder and re-opens.
  ///
  /// MUST await all the way through its `open()` before returning. Every host
  /// calls [noteStreamOpened] straight after opening, which is only safe while
  /// `_recovering` is set - and it is only set for the duration of this call.
  /// An implementation that returns after `setState` and lets a rebuild drive
  /// the open reintroduces the ladder-rewind bug that `onRecreate` documents.
  final Future<void> Function()? onDegradeQuality;

  /// Called when the stream is stuttering rather than frozen - repeated short
  /// rebuffers while data is still arriving.
  ///
  /// Separate from the ladder by design: see [_noteCongestion]. Usually wired
  /// to the same handler as [onDegradeQuality].
  final Future<void> Function()? onCongested;

  final void Function(WatchdogStatus status)? onStatus;

  /// Whether automatic recovery is permitted. Detection and reporting continue
  /// either way, so the UI can still warn the user when this is off.
  final bool Function() enabled;

  /// What to tell the user when auto-recovery is off and the stream is frozen.
  ///
  /// Injected because the gesture differs by device - "tap" means nothing with
  /// a remote - and this layer has no business knowing about form factors.
  final String reconnectHint;

  final bool isLive;

  /// Overridable so tests can walk the ladder without waiting on wall-clock
  /// time. Production callers should leave this at the default.
  final Duration verifyWindow;

  /// Base delay after the ladder is exhausted; multiplied by the cycle count
  /// and clamped to [maxBackOff]. Also overridable for tests.
  final Duration backOffStep;
  final Duration maxBackOff;

  StreamWatchdog({
    required this.playerRef,
    required this.urlRef,
    required this.enabled,
    this.isLive = true,
    this.onRecreate,
    this.onOpen,
    this.onUrlChanged,
    this.canDegradeQuality,
    this.onDegradeQuality,
    this.onCongested,
    this.onStatus,
    this.reconnectHint = 'Stream frozen - tap to reconnect',
    this.verifyWindow = defaultVerifyWindow,
    this.backOffStep = const Duration(seconds: 5),
    this.maxBackOff = const Duration(seconds: 30),
  });

  Timer? _timer;
  bool _disposed = false;
  bool _recovering = false;

  Duration? _lastPosition;
  double? _lastCacheTime;
  Duration? _lastBufferFallback;

  int _positionStalledTicks = 0;
  int _cacheStalledTicks = 0;
  int _pausedForCacheTicks = 0;
  int _sinceOpenTicks = 0;
  int _healthyTicks = 0;

  int _tickCount = 0;
  bool _wasPausedForCache = false;

  /// Tick numbers at which a rebuffer episode began, pruned to the window.
  final List<int> _rebufferTicks = [];

  int _ladderIndex = 0;
  int _cycle = 0;
  bool _sawFirstFrame = false;
  DateTime? _suppressUntil;

  WatchdogStatus _status = const WatchdogStatus(
    phase: WatchdogPhase.healthy,
    message: '',
  );

  WatchdogStatus get status => _status;

  void start() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer.periodic(tickInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    stop();
  }

  /// Call whenever a new stream is opened - a channel change, a manual retry,
  /// or a recovery step re-opening the stream.
  ///
  /// A host-initiated open (new channel) clears everything: the next hiccup
  /// should start again from the cheapest rung. An open performed *by* a
  /// recovery step must not, or the ladder rewinds itself every time it reaches
  /// [RecoveryStep.recreate] and can never climb to the later rungs - observed
  /// live, cycling nudge/reopen/hardReopen/recreate forever and never reaching
  /// the alternate-format fallback.
  ///
  /// [userInitiated] forces the rewind even mid-recovery. A quality change the
  /// user picked themselves is not part of the recovery that happens to be in
  /// flight, and without this its open is swallowed by the guard below and the
  /// ladder keeps escalating against a stream the user just replaced.
  void noteStreamOpened({bool userInitiated = false}) {
    _lastPosition = null;
    _lastCacheTime = null;
    _lastBufferFallback = null;
    _positionStalledTicks = 0;
    _cacheStalledTicks = 0;
    _pausedForCacheTicks = 0;
    _sinceOpenTicks = 0;
    _healthyTicks = 0;
    _sawFirstFrame = false;
    _wasPausedForCache = false;
    _rebufferTicks.clear();

    if (_recovering && !userInitiated) return;

    _ladderIndex = 0;
    _cycle = 0;
    _suppressUntil = null;
    _emit(const WatchdogStatus(phase: WatchdogPhase.healthy, message: ''));
  }

  /// Forces recovery to begin now, from the cheapest useful rung.
  ///
  /// [userInitiated] recovery clears the back-off window and rewinds the cycle
  /// count, because an explicit request should never be swallowed by a wait the
  /// user cannot see. Recovery triggered by a player error must leave the
  /// window intact, or a stream erroring in a tight loop would hammer the
  /// ladder faster than any step can be judged.
  Future<void> forceRecovery({bool userInitiated = true}) async {
    if (!userInitiated &&
        _suppressUntil != null &&
        DateTime.now().isBefore(_suppressUntil!)) {
      return;
    }
    if (userInitiated) {
      _ladderIndex = 1; // skip the nudge; the user already knows it is broken
      _cycle = 0;
      _suppressUntil = null;
    }
    await _escalate(FreezeCause.starved);
  }

  Future<void> _tick() async {
    if (_disposed || _recovering) return;

    final player = playerRef();
    if (player == null) return;

    final playing = player.state.playing;
    if (!playing) {
      // Paused by the user, or genuinely stopped. Either way there is nothing
      // to detect - a paused stream is supposed to have a stationary playhead.
      _resetStallCounters();
      return;
    }

    _sinceOpenTicks++;
    _tickCount++;

    final position = player.state.position;
    final cacheTime = await StreamTuning.readDouble(player, 'demuxer-cache-time');
    final pausedForCache =
        await StreamTuning.readFlag(player, 'paused-for-cache') ?? false;

    final positionAdvanced = _lastPosition == null || position != _lastPosition;
    // Fall back to the demuxer cache *duration* when mpv will not report an
    // absolute cache time, so detection still works on backends that lack it.
    final cacheAdvanced = cacheTime == null
        ? player.state.buffer > Duration.zero &&
            player.state.buffer != _lastBufferFallback
        : _lastCacheTime == null || cacheTime != _lastCacheTime;

    _lastPosition = position;
    _lastCacheTime = cacheTime;
    _lastBufferFallback = player.state.buffer;

    if (position > Duration.zero) _sawFirstFrame = true;

    _positionStalledTicks = positionAdvanced ? 0 : _positionStalledTicks + 1;
    _cacheStalledTicks = cacheAdvanced ? 0 : _cacheStalledTicks + 1;
    _pausedForCacheTicks = pausedForCache ? _pausedForCacheTicks + 1 : 0;

    // Checked before the healthy-path return below, because congestion looks
    // like healthy playback punctuated by short stalls - evaluating it only
    // during a stall would miss the pattern entirely.
    if (await _noteCongestion(player, pausedForCache)) return;

    if (positionAdvanced && !pausedForCache) {
      _healthyTicks++;
      if (_healthyTicks >= healthyResetTicks && _ladderIndex > 0) {
        // Sustained good playback - forget that anything was ever wrong so the
        // next unrelated hiccup starts again from the cheapest step.
        print('[watchdog] stream healthy again; ladder reset');
        _ladderIndex = 0;
        _cycle = 0;
      }
      if (_healthyTicks >= 3) {
        _emit(const WatchdogStatus(phase: WatchdogPhase.healthy, message: ''));
      }
      return;
    }

    _healthyTicks = 0;

    final cause = _diagnose();
    if (cause == null) {
      if (_positionStalledTicks >= 2 || _pausedForCacheTicks >= 3) {
        _emit(const WatchdogStatus(
          phase: WatchdogPhase.degraded,
          message: 'Stream unstable',
        ));
      }
      return;
    }

    if (_suppressUntil != null && DateTime.now().isBefore(_suppressUntil!)) {
      // A recovery step is still being given a chance to take effect.
      _emit(WatchdogStatus(
        phase: WatchdogPhase.verifying,
        cause: cause,
        step: _ladderIndex > 0 ? ladder[_ladderIndex - 1] : null,
        cycle: _cycle,
        message: 'Reconnecting...',
      ));
      return;
    }

    if (!enabled()) {
      _emit(WatchdogStatus(
        phase: WatchdogPhase.degraded,
        cause: cause,
        message: reconnectHint,
      ));
      return;
    }

    await _escalate(cause);
  }

  /// Tracks rebuffering and asks the host to lower quality when the stream is
  /// stuttering rather than frozen. Returns whether it acted.
  ///
  /// This is a second trigger, independent of the recovery ladder, and the
  /// primary way quality actually drops. The ladder answers "the stream is
  /// broken, repair it" - every rung assumes the endpoint or the pipeline is at
  /// fault. Repeated short rebuffers are a different hypothesis, that the pipe
  /// is too narrow for this bitrate, and it is testable long before anything
  /// freezes. Left to the ladder alone, quality would not move until nudge,
  /// reopen, hardReopen, recreate and alternateUrl had each been tried and
  /// given a verification window - roughly a minute of broken video, and
  /// another minute for every step after that.
  ///
  /// Deliberately does not touch `_ladderIndex`. The ladder stays a repair
  /// ladder; quality is orthogonal to it.
  Future<bool> _noteCongestion(Player player, bool pausedForCache) async {
    if (pausedForCache && !_wasPausedForCache) {
      _rebufferTicks.add(_tickCount);
    }
    _wasPausedForCache = pausedForCache;
    _rebufferTicks
        .removeWhere((tick) => _tickCount - tick > congestionWindowTicks);

    if (onCongested == null) return false;
    if (_rebufferTicks.length < congestionEpisodeThreshold) return false;
    if (!enabled()) return false;
    if (_suppressUntil != null && DateTime.now().isBefore(_suppressUntil!)) {
      return false;
    }
    if (!_canDegradeSafely()) return false;

    // Data has to actually be arriving for "too narrow" to be the right
    // diagnosis. A cache-speed of zero means the stream is down rather than
    // slow, and a lower-bitrate sibling from the same provider would be down
    // too - so degrading would cost the user quality and fix nothing. Read
    // here rather than every tick because this point is reached rarely.
    final cacheSpeed = await StreamTuning.readDouble(player, 'cache-speed');
    if (cacheSpeed != null && cacheSpeed <= 0) return false;

    print('[watchdog] congestion detected '
        '(${_rebufferTicks.length} rebuffers in ${congestionWindowTicks}s) '
        '- lowering quality');

    _rebufferTicks.clear();

    // Held for the whole handler so the host's noteStreamOpened() does not
    // rewind the ladder, exactly as an escalation does.
    _recovering = true;
    try {
      _emit(const WatchdogStatus(
        phase: WatchdogPhase.recovering,
        step: RecoveryStep.degradeQuality,
        message: 'Lowering quality...',
      ));
      await onCongested!();
    } catch (e) {
      print('[watchdog] congestion handler threw: $e');
    } finally {
      _recovering = false;
    }

    _resetStallCounters();
    _suppressUntil = DateTime.now().add(verifyWindow);
    return true;
  }

  /// [canDegradeQuality], guarded. It is host code reading provider state and
  /// can throw from a disposed widget; a throw here would otherwise propagate
  /// out of an unawaited timer callback and silently lose the escalation.
  bool _canDegradeSafely() {
    try {
      return canDegradeQuality?.call() ?? false;
    } catch (e) {
      print('[watchdog] canDegradeQuality threw: $e');
      return false;
    }
  }

  /// Maps the stall counters onto a freeze cause, or null if nothing has
  /// crossed its threshold yet.
  FreezeCause? _diagnose() {
    if (!_sawFirstFrame && _sinceOpenTicks >= startupThresholdTicks) {
      return FreezeCause.neverStarted;
    }
    if (_pausedForCacheTicks >= stuckBufferingThresholdTicks) {
      return FreezeCause.stuckBuffering;
    }
    if (_positionStalledTicks >= starveThresholdTicks &&
        _cacheStalledTicks >= starveThresholdTicks) {
      return FreezeCause.starved;
    }
    if (_positionStalledTicks >= wedgeThresholdTicks && _cacheStalledTicks == 0) {
      return FreezeCause.wedged;
    }
    return null;
  }

  Future<void> _escalate(FreezeCause cause) async {
    if (_recovering || _disposed) return;
    _recovering = true;

    try {
      // A wedged decoder cannot be fixed by re-opening a stream, so skip
      // straight to rebuilding the player rather than burning two rungs on
      // steps that are known not to apply.
      if (cause == FreezeCause.wedged &&
          _ladderIndex < ladder.indexOf(RecoveryStep.recreate) &&
          onRecreate != null) {
        _ladderIndex = ladder.indexOf(RecoveryStep.recreate);
      }

      if (_ladderIndex >= ladder.length) {
        await _backOff();
        return;
      }

      final step = ladder[_ladderIndex];
      _ladderIndex++;

      if (!_isAvailable(step)) {
        print('[watchdog] skipping unavailable step $step');
        _recovering = false;
        await _escalate(cause);
        return;
      }

      print('[watchdog] freeze detected ($cause) - applying $step '
          '(cycle $_cycle)');

      _emit(WatchdogStatus(
        phase: WatchdogPhase.recovering,
        cause: cause,
        step: step,
        cycle: _cycle,
        message: _messageFor(step),
      ));

      try {
        await _perform(step);
      } catch (e) {
        print('[watchdog] step $step threw: $e');
      }

      // Reset the stall counters so the verification window is judged on fresh
      // samples rather than the ones that triggered this escalation.
      _resetStallCounters();
      _suppressUntil = DateTime.now().add(verifyWindow);

      _emit(WatchdogStatus(
        phase: WatchdogPhase.verifying,
        cause: cause,
        step: step,
        cycle: _cycle,
        message: 'Reconnecting...',
      ));
    } finally {
      _recovering = false;
    }
  }

  /// Whether [step] can do anything right now.
  ///
  /// A switch *expression* with no default on purpose: a new rung that nobody
  /// teaches this method about should be a compile error, not a step that
  /// silently reports itself available and then throws on a null callback.
  bool _isAvailable(RecoveryStep step) {
    try {
      return switch (step) {
        RecoveryStep.nudge => true,
        RecoveryStep.reopen => true,
        RecoveryStep.hardReopen => true,
        RecoveryStep.recreate => onRecreate != null,
        RecoveryStep.alternateUrl =>
          StreamTuning.alternateUrl(urlRef()) != null,
        RecoveryStep.degradeQuality =>
          onDegradeQuality != null && _canDegradeSafely(),
      };
    } catch (e) {
      print('[watchdog] availability check for $step threw: $e');
      return false;
    }
  }

  Future<void> _perform(RecoveryStep step) async {
    final player = playerRef();
    if (player == null) return;
    final url = urlRef();

    switch (step) {
      case RecoveryStep.nudge:
        if (isLive) {
          await player.pause();
          await Future.delayed(const Duration(milliseconds: 300));
          await player.play();
        } else {
          // Seeking to the current position forces mpv to flush and re-prime
          // the demuxer and decoder, which clears a wedged pipeline without
          // losing the viewer's place. Not available for live streams.
          await player.seek(player.state.position);
          await player.play();
        }

      case RecoveryStep.reopen:
        await _open(url);

      case RecoveryStep.hardReopen:
        await player.stop();
        await Future.delayed(const Duration(milliseconds: 600));
        await _open(url);

      case RecoveryStep.recreate:
        await onRecreate!(url);

      case RecoveryStep.alternateUrl:
        final alternate = StreamTuning.alternateUrl(url);
        if (alternate == null) return;
        print('[watchdog] trying alternate stream format: '
            '${StreamTuning.redactUrl(alternate)}');
        onUrlChanged?.call(alternate);
        if (onRecreate != null) {
          await onRecreate!(alternate);
        } else {
          await _open(alternate);
        }

      case RecoveryStep.degradeQuality:
        await onDegradeQuality!();
    }
  }

  Future<void> _open(String url) async {
    if (onOpen != null) {
      await onOpen!(url);
      return;
    }
    await playerRef()?.open(Media(url));
  }

  /// Ladder exhausted. Wait, then run it again - minus the nudge, which is only
  /// ever useful as a first response.
  Future<void> _backOff() async {
    _cycle++;
    final delay = Duration(
      milliseconds: (backOffStep.inMilliseconds * _cycle)
          .clamp(backOffStep.inMilliseconds, maxBackOff.inMilliseconds),
    );
    print('[watchdog] ladder exhausted (cycle $_cycle); '
        'retrying in ${delay.inSeconds}s');

    _emit(WatchdogStatus(
      phase: WatchdogPhase.backingOff,
      cycle: _cycle,
      message: 'Stream unavailable - retrying in ${delay.inSeconds}s',
    ));

    _ladderIndex = ladder.indexOf(RecoveryStep.reopen);
    _resetStallCounters();
    _suppressUntil = DateTime.now().add(delay);
  }

  void _resetStallCounters() {
    _wasPausedForCache = false;
    _rebufferTicks.clear();
    _positionStalledTicks = 0;
    _cacheStalledTicks = 0;
    _pausedForCacheTicks = 0;
    _sinceOpenTicks = 0;
    _lastPosition = null;
    _lastCacheTime = null;
  }

  String _messageFor(RecoveryStep step) => switch (step) {
        RecoveryStep.nudge => 'Resyncing stream...',
        RecoveryStep.reopen => 'Reconnecting...',
        RecoveryStep.hardReopen => 'Reconnecting...',
        RecoveryStep.recreate => 'Restarting player...',
        RecoveryStep.alternateUrl => 'Trying alternate stream...',
        RecoveryStep.degradeQuality => 'Lowering quality...',
      };

  void _emit(WatchdogStatus status) {
    if (_disposed) return;
    if (status.phase == _status.phase &&
        status.message == _status.message &&
        status.step == _status.step) {
      return;
    }
    _status = status;
    onStatus?.call(status);
  }
}
