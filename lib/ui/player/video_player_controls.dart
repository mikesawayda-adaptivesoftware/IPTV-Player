import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/platform/tv_platform.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
import 'seek_bar.dart';

/// The VOD player's overlay: title bar, transport buttons and the seek bar.
///
/// Owns its own visibility and input handling, and stays mounted while hidden
/// (it fades with [AnimatedOpacity]) so the focused control never leaves the
/// tree under a remote. While hidden, focus is parked on the seek bar, so
/// Left/Right on a D-pad seek straight away without a press to wake the UI.
class VideoPlayerControls extends StatefulWidget {
  final Player player;
  final String title;
  final String? subtitle;
  final bool isLive;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onClose;

  /// Shows a Cast button when set.
  final VoidCallback? onCast;

  const VideoPlayerControls({
    super.key,
    required this.player,
    required this.title,
    this.subtitle,
    this.isLive = true,
    this.isFullscreen = false,
    required this.onToggleFullscreen,
    required this.onClose,
    this.onCast,
  });

  @override
  State<VideoPlayerControls> createState() => _VideoPlayerControlsState();
}

class _VideoPlayerControlsState extends State<VideoPlayerControls> {
  late bool _isPlaying;
  late Duration _position;
  late Duration _duration;
  late Duration _buffered;
  double _volume = 1.0;
  bool _isMuted = false;
  bool _showVolumeSlider = false;
  Timer? _hideTimer;
  bool _visible = true;

  /// Where a seek in progress is headed. Shown in place of the playhead while
  /// set, so a held D-pad or a drag moves the bar without issuing a seek per
  /// key repeat or per pointer move against a network stream.
  Duration? _pendingSeek;
  Timer? _commitTimer;
  int _heldSteps = 0;

  final FocusNode _seekFocus = FocusNode(debugLabel: 'vod-seek-bar');
  final FocusNode _playFocus = FocusNode(debugLabel: 'vod-play-pause');

  /// Key-ups to consume because their key-down was spent waking the controls.
  /// Back fires on ACTION_UP on Android, so an unmatched up is not harmless.
  final Set<LogicalKeyboardKey> _swallowUps = {};

  late final List<StreamSubscription> _subscriptions;

  bool get _canSeek => !widget.isLive && _duration > Duration.zero;

  @override
  void initState() {
    super.initState();
    // Seed from the player's current state. The streams are broadcast and do
    // not replay, so a controls widget built after the file loaded used to sit
    // at a zero duration forever - which hid the seek bar entirely.
    final state = widget.player.state;
    _isPlaying = state.playing;
    _position = state.position;
    _duration = state.duration;
    _buffered = state.buffer;
    _volume = state.volume / 100;

    _subscriptions = [
      widget.player.stream.playing.listen((playing) {
        if (!mounted) return;
        setState(() => _isPlaying = playing);
        if (playing) {
          _startHideTimer();
        } else {
          _showControls();
        }
      }),
      widget.player.stream.position.listen((position) {
        if (mounted) setState(() => _position = position);
      }),
      widget.player.stream.duration.listen((duration) {
        if (!mounted) return;
        final first = _duration <= Duration.zero && duration > Duration.zero;
        setState(() => _duration = duration);
        // The bar only exists once the length is known. Hand it focus then,
        // unless the user has already moved somewhere else.
        if (first && !widget.isLive && (_playFocus.hasFocus || _nothingFocused)) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _seekFocus.requestFocus());
        }
      }),
      widget.player.stream.buffer.listen((buffer) {
        if (mounted) setState(() => _buffered = buffer);
      }),
      widget.player.stream.volume.listen((volume) {
        if (mounted) setState(() => _volume = volume / 100);
      }),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (_canSeek ? _seekFocus : _playFocus).requestFocus();
    });
    _startHideTimer();
  }

  bool get _nothingFocused {
    final primary = FocusManager.instance.primaryFocus;
    return primary == null || primary is FocusScopeNode;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _commitTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _seekFocus.dispose();
    _playFocus.dispose();
    super.dispose();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !_isPlaying || _pendingSeek != null) return;
      setState(() => _visible = false);
      // Park focus on the seek bar so the next Left/Right seeks immediately.
      if (_canSeek) _seekFocus.requestFocus();
    });
  }

  void _showControls() {
    if (!_visible) setState(() => _visible = true);
    _startHideTimer();
  }

  void _toggleVisible() {
    if (_visible) {
      _hideTimer?.cancel();
      setState(() => _visible = false);
    } else {
      _showControls();
    }
  }

  void _togglePlayPause() {
    widget.player.playOrPause();
    _showControls();
  }

  // ==========================================================================
  // Seeking
  // ==========================================================================

  Duration _clamp(Duration d) {
    if (d < Duration.zero) return Duration.zero;
    if (d > _duration) return _duration;
    return d;
  }

  /// One D-pad step. Holding the key speeds up, so crossing a two-hour film
  /// does not take seven hundred presses.
  void _step(int direction, {bool repeat = false}) {
    if (!_canSeek) return;
    _heldSteps = repeat ? _heldSteps + 1 : 0;
    final seconds = _heldSteps < 5
        ? 10
        : _heldSteps < 15
            ? 30
            : 60;
    final from = _pendingSeek ?? _position;
    setState(() {
      _pendingSeek = _clamp(from + Duration(seconds: seconds * direction));
    });
    _showControls();
    // Taps in quick succession accumulate into one seek.
    _commitTimer?.cancel();
    _commitTimer = Timer(const Duration(milliseconds: 600), _commitSeek);
  }

  void _scrubTo(Duration target) {
    _commitTimer?.cancel();
    setState(() => _pendingSeek = _clamp(target));
    _showControls();
  }

  void _scrubEnd(Duration target) {
    setState(() => _pendingSeek = _clamp(target));
    _commitSeek();
  }

  Future<void> _commitSeek() async {
    _commitTimer?.cancel();
    final target = _pendingSeek;
    if (target == null) return;
    try {
      await widget.player.seek(target);
    } catch (e) {
      print('Seek failed: $e');
    }
    if (!mounted || _pendingSeek != target) return;
    setState(() {
      _position = target;
      _pendingSeek = null;
    });
    _startHideTimer();
  }

  // ==========================================================================
  // Keys
  // ==========================================================================

  static final Set<LogicalKeyboardKey> _directional = {
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
  };

  /// Keys this overlay acts on, consumed on both edges so the up never reaches
  /// the platform unmatched.
  Set<LogicalKeyboardKey> get _claimedKeys => {
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.mediaPlayPause,
        LogicalKeyboardKey.mediaPlay,
        LogicalKeyboardKey.mediaPause,
        LogicalKeyboardKey.mediaStop,
        if (!widget.isLive) LogicalKeyboardKey.mediaFastForward,
        if (!widget.isLive) LogicalKeyboardKey.mediaRewind,
        LogicalKeyboardKey.keyM,
        if (!kIsTv) LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.escape,
      };

  /// A non-focusable interceptor: it sees every key by bubbling from whatever
  /// control has focus, without becoming a full-screen focus target that
  /// would break directional traversal (see the live player's equivalent).
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;

    if (event is KeyUpEvent) {
      if (_swallowUps.remove(key)) return KeyEventResult.handled;
      return _claimedKeys.contains(key)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (_claimedKeys.contains(key)) {
      switch (key) {
        case LogicalKeyboardKey.mediaFastForward:
          _step(1, repeat: event is KeyRepeatEvent);
        case LogicalKeyboardKey.mediaRewind:
          _step(-1, repeat: event is KeyRepeatEvent);
        case _ when event is KeyRepeatEvent:
          break;
        case LogicalKeyboardKey.space:
        case LogicalKeyboardKey.mediaPlayPause:
          _togglePlayPause();
        case LogicalKeyboardKey.mediaPlay:
          widget.player.play();
          _showControls();
        case LogicalKeyboardKey.mediaPause:
        case LogicalKeyboardKey.mediaStop:
          widget.player.pause();
          _showControls();
        case LogicalKeyboardKey.keyM:
          _toggleMute();
        case LogicalKeyboardKey.keyF:
          widget.onToggleFullscreen();
        case LogicalKeyboardKey.escape:
          widget.onClose();
      }
      return KeyEventResult.handled;
    }

    if (!_visible && _directional.contains(key) && event is KeyDownEvent) {
      // Left/Right normally never get here: focus is parked on the seek bar
      // while hidden and it handles them. If something else held focus, seek
      // anyway rather than moving focus around an invisible UI.
      if (_canSeek &&
          (key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowRight)) {
        _seekFocus.requestFocus();
        _step(key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
      } else {
        // Up/Down/Select only wake the controls - Select on a button nobody
        // can see would activate something at random.
        _showControls();
      }
      _swallowUps.add(key);
      return KeyEventResult.handled;
    }

    // Any other activity keeps the controls up while the user is navigating.
    if (_visible) _startHideTimer();
    return KeyEventResult.ignored;
  }

  void _setVolume(double value) {
    widget.player.setVolume(value * 100);
    if (value > 0) _isMuted = false;
    _showControls();
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      widget.player.setVolume(_isMuted ? 0 : _volume * 100);
    });
    _showControls();
  }

  // ==========================================================================
  // Build
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKey,
      // The whole-screen tap target. Opaque so a tap lands even while the
      // overlay is hidden and ignoring pointers; buttons inside still win
      // their own taps because they are deeper in the arena.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleVisible,
        child: MouseRegion(
          onHover: (_) => _showControls(),
          child: AnimatedOpacity(
            opacity: _visible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: IgnorePointer(
              ignoring: !_visible,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.7),
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.7),
                    ],
                    stops: const [0.0, 0.2, 0.8, 1.0],
                  ),
                ),
                child: Column(
                  children: [
                    _buildTopBar(),
                    Expanded(child: _buildCenterControls()),
                    _buildBottomBar(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: 'Back',
            onPressed: widget.onClose,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (widget.subtitle != null)
                  Text(
                    widget.subtitle!,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (widget.onCast != null)
            IconButton(
              icon: const Icon(Icons.cast, color: Colors.white),
              tooltip: 'Cast to a Chromecast',
              onPressed: widget.onCast,
            ),
          if (widget.isLive)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.errorColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, color: Colors.white, size: 8),
                  SizedBox(width: 4),
                  Text(
                    'LIVE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCenterControls() {
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (!widget.isLive)
            IconButton(
              icon: const Icon(Icons.replay_10, color: Colors.white, size: 36),
              tooltip: 'Back 10 seconds',
              onPressed: _canSeek ? () => _step(-1) : null,
            ),
          const SizedBox(width: 32),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              focusNode: _playFocus,
              iconSize: 64,
              tooltip: _isPlaying ? 'Pause' : 'Play',
              icon: Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
              onPressed: _togglePlayPause,
            ),
          ),
          const SizedBox(width: 32),
          if (!widget.isLive)
            IconButton(
              icon: const Icon(Icons.forward_10, color: Colors.white, size: 36),
              tooltip: 'Forward 10 seconds',
              onPressed: _canSeek ? () => _step(1) : null,
            ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    final shown = _pendingSeek ?? _position;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (_canSeek) ...[
            Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    shown.formatted,
                    style: TextStyle(
                      color: _pendingSeek != null
                          ? AppTheme.primaryColor
                          : Colors.white,
                      fontSize: 13,
                      fontWeight: _pendingSeek != null
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ),
                Expanded(
                  child: SeekBar(
                    focusNode: _seekFocus,
                    position: shown,
                    duration: _duration,
                    buffered: _buffered,
                    onStep: (direction, repeat) =>
                        _step(direction, repeat: repeat),
                    onActivate: _togglePlayPause,
                    onScrubUpdate: _scrubTo,
                    onScrubEnd: _scrubEnd,
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Text(
                    _duration.formatted,
                    textAlign: TextAlign.right,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              MouseRegion(
                onEnter: (_) => setState(() => _showVolumeSlider = true),
                onExit: (_) => setState(() => _showVolumeSlider = false),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _isMuted || _volume == 0
                            ? Icons.volume_off
                            : _volume < 0.5
                                ? Icons.volume_down
                                : Icons.volume_up,
                        color: Colors.white,
                      ),
                      tooltip: _isMuted ? 'Unmute' : 'Mute',
                      onPressed: _toggleMute,
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: _showVolumeSlider ? 100 : 0,
                      child: _showVolumeSlider
                          ? Slider(
                              value: _isMuted ? 0 : _volume.clamp(0.0, 1.0),
                              onChanged: _setVolume,
                              activeColor: AppTheme.primaryColor,
                              inactiveColor: Colors.white24,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              // Hidden on TV, as in the live player: there is no window to
              // leave, and a dead stop in the traversal order costs a press.
              if (!kIsTv)
                IconButton(
                  icon: Icon(
                    widget.isFullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    color: Colors.white,
                  ),
                  onPressed: widget.onToggleFullscreen,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
