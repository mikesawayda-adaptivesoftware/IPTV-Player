import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/player/stream_tuning.dart';
import '../../core/player/stream_watchdog.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/channel.dart';
import '../../data/services/storage_service.dart';
import '../../providers/playlist_provider.dart';

// BufferMode moved to core/player/stream_tuning.dart so the tuning layer can
// use it without depending on the UI. Re-exported here because the settings
// screen imports it from this file.
export '../../core/player/stream_tuning.dart' show BufferMode;

/// Provider for buffer settings
final bufferModeProvider = StateProvider<BufferMode>((ref) {
  final storage = StorageService();
  final savedMode = storage.getSetting<int>('buffer_mode', defaultValue: 1);
  return BufferMode.values[savedMode ?? 1];
});

final autoReconnectProvider = StateProvider<bool>((ref) {
  final storage = StorageService();
  return storage.getSetting<bool>('auto_reconnect', defaultValue: true) ?? true;
});

class EnhancedVideoPlayer extends ConsumerStatefulWidget {
  final Channel channel;
  final bool isLive;
  final VoidCallback? onClose;
  final VoidCallback? onMinimize;

  const EnhancedVideoPlayer({
    super.key,
    required this.channel,
    this.isLive = true,
    this.onClose,
    this.onMinimize,
  });

  @override
  ConsumerState<EnhancedVideoPlayer> createState() => _EnhancedVideoPlayerState();
}

class _EnhancedVideoPlayerState extends ConsumerState<EnhancedVideoPlayer> {
  // Nullable, and rebuilt from scratch by the watchdog's recreate step - a
  // wedged libmpv instance cannot be recovered any other way.
  Player? _player;
  VideoController? _controller;
  final List<StreamSubscription> _subscriptions = [];

  late StreamWatchdog _watchdog;
  WatchdogStatus _watchdogStatus =
      const WatchdogStatus(phase: WatchdogPhase.healthy, message: '');

  late Channel _currentChannel;

  /// Mutable because the watchdog may fall back to the provider's other stream
  /// format when the original will not play.
  late String _streamUrl;

  bool _isFullscreen = false;
  bool _showControls = true;
  bool _isLoading = true;
  bool _isBuffering = false;
  String? _errorMessage;
  Timer? _hideTimer;

  double _bufferHealth = 0.0;

  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _currentChannel = widget.channel;
    _streamUrl = widget.channel.streamUrl;

    // Go immersive the moment the player opens: hide the phone's status bar and
    // navigation buttons so video is truly full-screen. Restored in dispose.
    // No-op on desktop. immersiveSticky keeps the bars hidden but lets a user
    // swipe from an edge to reveal them briefly.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _watchdog = StreamWatchdog(
      playerRef: () => _player,
      urlRef: () => _streamUrl,
      enabled: () => ref.read(autoReconnectProvider),
      isLive: widget.isLive,
      onRecreate: _recreatePlayer,
      onOpen: _openUrl,
      onUrlChanged: (url) => _streamUrl = url,
      onStatus: _onWatchdogStatus,
    );

    _bootstrap();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(channelStateProvider.notifier).markAsWatched(_currentChannel);
    });
  }

  Future<void> _bootstrap() async {
    await _createPlayer();
    await _openUrl(_streamUrl);
    _watchdog.start();
    _startHideTimer();
  }

  // ==========================================================================
  // Player lifecycle
  // ==========================================================================

  Future<void> _createPlayer() async {
    try {
      final player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 64 * 1024 * 1024,
        ),
      );

      final controller = VideoController(
        player,
        configuration: const VideoControllerConfiguration(
          // Software rendering - works around GPU texture crashes seen on Linux.
          enableHardwareAcceleration: false,
        ),
      );

      // Publish to the widget tree FIRST. The VideoController only finishes
      // initialising once a Video widget mounts, and setProperty waits on that
      // - tuning before the first build deadlocks until every property times
      // out, which made each recovery ~30s slower.
      _player = player;
      _controller = controller;
      _attachListeners(player);
      if (mounted) setState(() {});

      // Still before open(): the FFmpeg demuxer options are read at open time.
      await StreamTuning.apply(
        player,
        mode: ref.read(bufferModeProvider),
        isLive: widget.isLive,
      );
    } catch (e, stackTrace) {
      print('Error creating player: $e');
      print('Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to initialize player: $e';
          _isLoading = false;
        });
      }
    }
  }

  void _attachListeners(Player player) {
    void listen<T>(Stream<T> stream, void Function(T) onData) {
      _subscriptions.add(stream.listen(onData));
    }

    listen(player.stream.playing, (_) {
      if (mounted) setState(() {});
    });

    listen(player.stream.buffering, (buffering) {
      if (!mounted) return;
      setState(() {
        _isBuffering = buffering;
        _isLoading = buffering && player.state.position == Duration.zero;
      });
    });

    listen(player.stream.buffer, (_) => _updateBufferHealth());

    listen(player.stream.error, (error) {
      if (!mounted || error.isEmpty) return;
      _handlePlaybackError(error);
    });
  }

  Future<void> _cancelSubscriptions() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  /// Tears the player down completely and builds a new one. This is the
  /// recovery step that actually clears a wedged libmpv/FFmpeg state, which no
  /// amount of re-opening the same stream will fix.
  Future<void> _recreatePlayer(String url) async {
    final old = _player;

    await _cancelSubscriptions();

    // Drop the Video widget before disposing, so it never holds a controller
    // whose player is going away.
    _player = null;
    _controller = null;
    if (mounted) setState(() => _isLoading = true);
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      await old?.dispose();
    } catch (e) {
      print('Error disposing player during recreate: $e');
    }

    await _createPlayer();
    await _openUrl(url);
  }

  Future<void> _openUrl(String url) async {
    final player = _player;
    if (player == null) return;

    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      print('Opening stream: ${_currentChannel.name}');
      await player.open(Media(url));
      _watchdog.noteStreamOpened();
    } catch (e) {
      // Exception text from mpv/Dio routinely embeds the full stream URL.
      print('Error opening stream: ${StreamTuning.redactUrl(e.toString())}');
      _handlePlaybackError(e.toString());
    }
  }

  void _handlePlaybackError(String rawError) {
    // mpv error text embeds the failing URL, credentials and all - both the log
    // line and the on-screen message have to be redacted.
    final error = StreamTuning.redactUrl(rawError);

    if (ref.read(autoReconnectProvider)) {
      // Hand it to the watchdog rather than surfacing a dead end. Errors that
      // arrive without a stall (a failed open, say) would otherwise never be
      // noticed by the sampler.
      print('Playback error: $error - handing to watchdog');
      _watchdog.forceRecovery(userInitiated: false);
      return;
    }

    if (mounted) {
      setState(() {
        _errorMessage = error;
        _isLoading = false;
        _isBuffering = false;
      });
    }
  }

  void _onWatchdogStatus(WatchdogStatus status) {
    if (!mounted) return;
    setState(() {
      _watchdogStatus = status;
      if (status.phase == WatchdogPhase.healthy) {
        _errorMessage = null;
        _isLoading = false;
      }
    });
  }

  void _updateBufferHealth() {
    final player = _player;
    if (player == null || !mounted) return;

    final health = StreamTuning.bufferHealth(
      player.state.buffer,
      player.state.position,
      ref.read(bufferModeProvider).seconds,
    );

    if ((health - _bufferHealth).abs() > 0.01) {
      setState(() => _bufferHealth = health);
    }
  }

  @override
  void dispose() {
    // Hand the system bars back to the rest of the app on the way out.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _hideTimer?.cancel();
    _watchdog.dispose();
    _cancelSubscriptions();
    _player?.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ==========================================================================
  // Channel / controls
  // ==========================================================================

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_player?.state.playing ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _showControlsTemporarily() {
    setState(() => _showControls = true);
    _startHideTimer();
  }

  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);

    // The player is immersive for its whole lifetime (see initState), so the
    // toggle only locks orientation: on = force landscape, off = allow rotation.
    // Re-assert immersive here too, in case the system bars crept back after an
    // app switch or a transient swipe-reveal.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (_isFullscreen) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  Future<void> _switchChannel(Channel newChannel) async {
    setState(() {
      _currentChannel = newChannel;
      _streamUrl = newChannel.streamUrl;
      _isLoading = true;
      _errorMessage = null;
      _bufferHealth = 0.0;
      _watchdogStatus =
          const WatchdogStatus(phase: WatchdogPhase.healthy, message: '');
    });

    ref.read(channelStateProvider.notifier).markAsWatched(newChannel);
    await _openUrl(newChannel.streamUrl);
  }

  void _nextChannel() {
    final next =
        ref.read(channelStateProvider.notifier).getNextChannel(_currentChannel);
    if (next != null) _switchChannel(next);
  }

  void _previousChannel() {
    final previous = ref
        .read(channelStateProvider.notifier)
        .getPreviousChannel(_currentChannel);
    if (previous != null) _switchChannel(previous);
  }

  /// Manual reconnect - the R key and the on-screen banner. Restores the
  /// channel's original URL in case the watchdog had fallen back to an
  /// alternate format that turned out to be worse.
  void _manualReconnect() {
    _streamUrl = _currentChannel.streamUrl;
    setState(() => _errorMessage = null);
    _watchdog.forceRecovery();
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final player = _player;
    _showControlsTemporarily();

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        player?.playOrPause();
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.channelUp:
        _previousChannel();
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.channelDown:
        _nextChannel();
      case LogicalKeyboardKey.arrowLeft:
        if (!widget.isLive && player != null) {
          player.seek(player.state.position - const Duration(seconds: 10));
        }
      case LogicalKeyboardKey.arrowRight:
        if (!widget.isLive && player != null) {
          player.seek(player.state.position + const Duration(seconds: 10));
        }
      case LogicalKeyboardKey.keyM:
        if (player != null) {
          player.setVolume(player.state.volume > 0 ? 0 : 100);
        }
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
      case LogicalKeyboardKey.keyR:
        _manualReconnect();
      case LogicalKeyboardKey.escape:
        if (_isFullscreen) {
          _toggleFullscreen();
        } else {
          widget.onClose?.call();
        }
    }
  }

  // ==========================================================================
  // Build
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    // Cache sizing applies live, so a buffer-mode change takes effect on the
    // running stream rather than waiting for the next channel change.
    ref.listen<BufferMode>(bufferModeProvider, (_, mode) {
      final player = _player;
      if (player != null) {
        StreamTuning.apply(player, mode: mode, isLive: widget.isLive);
      }
    });

    final controller = _controller;

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _showControlsTemporarily,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (controller != null)
                Center(
                  child: Video(
                    controller: controller,
                    controls: NoVideoControls,
                  ),
                )
              else
                const ColoredBox(color: Colors.black),

              if (_isLoading) _buildLoadingOverlay(),

              if (_isBuffering && !_isLoading) _buildBufferingIndicator(),

              // Recovery banner - shown whenever the watchdog is not happy and
              // we are not already covered by the loading overlay.
              if (!_watchdogStatus.isHealthy && !_isLoading)
                _buildWatchdogBanner(),

              if (_errorMessage != null) _buildErrorView(),

              if (_showControls && _errorMessage == null) _buildControls(),

              if (_showControls && _errorMessage == null && widget.isLive)
                _buildBufferHealthIndicator(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    final bufferMode = ref.watch(bufferModeProvider);
    final recovering = _watchdogStatus.isRecovering;

    return Container(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppTheme.primaryColor),
            const SizedBox(height: 16),
            Text(
              recovering ? _watchdogStatus.message : 'Buffering...',
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              'Buffer mode: ${bufferMode.label}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBufferingIndicator() {
    return const Positioned(
      top: 100,
      left: 0,
      right: 0,
      child: Center(
        child: _Pill(
          color: Colors.black54,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  color: AppTheme.primaryColor,
                  strokeWidth: 2,
                ),
              ),
              SizedBox(width: 8),
              Text(
                'Buffering...',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Status banner for everything the watchdog is doing. Deliberately
  /// non-blocking: recovery continues on its own, and tapping only short-cuts
  /// the wait rather than being the thing that makes recovery happen.
  Widget _buildWatchdogBanner() {
    final status = _watchdogStatus;
    final autoReconnect = ref.watch(autoReconnectProvider);

    final Color color;
    final IconData icon;
    final String label;

    switch (status.phase) {
      case WatchdogPhase.degraded:
        color = AppTheme.warningColor;
        icon = Icons.warning_amber;
        label = autoReconnect
            ? status.message
            : 'Stream frozen - auto reconnect is off. Tap to reconnect';
      case WatchdogPhase.recovering:
      case WatchdogPhase.verifying:
        color = AppTheme.primaryColor;
        icon = Icons.autorenew;
        label = status.message;
      case WatchdogPhase.backingOff:
        color = AppTheme.errorColor;
        icon = Icons.cloud_off;
        label = status.message;
      case WatchdogPhase.healthy:
        return const SizedBox.shrink();
    }

    return Positioned(
      top: 100,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: _manualReconnect,
          child: _Pill(
            color: color.withValues(alpha: 0.9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 16),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (status.isRecovering) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBufferHealthIndicator() {
    final Color healthColor;
    if (_bufferHealth > 0.7) {
      healthColor = AppTheme.successColor;
    } else if (_bufferHealth > 0.3) {
      healthColor = AppTheme.warningColor;
    } else {
      healthColor = AppTheme.errorColor;
    }

    return Positioned(
      top: 80,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _bufferHealth > 0.5
                  ? Icons.signal_cellular_alt
                  : Icons.signal_cellular_alt_2_bar,
              color: healthColor,
              size: 14,
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 40,
              height: 4,
              child: LinearProgressIndicator(
                value: _bufferHealth,
                backgroundColor: Colors.white24,
                valueColor: AlwaysStoppedAnimation(healthColor),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '${(_bufferHealth * 100).toInt()}%',
              style: TextStyle(color: healthColor, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: AppTheme.errorColor, size: 48),
          const SizedBox(height: 16),
          Text(
            'Playback Error',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(color: Colors.white),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: AppTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Turn on Auto Reconnect in Settings to recover from this '
              'automatically.',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _manualReconnect,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              const SizedBox(width: 16),
              OutlinedButton(
                onPressed: _nextChannel,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54),
                ),
                child: const Text('Try Next Channel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final epgNotifier = ref.read(epgStateProvider.notifier);
    final currentProgram = _currentChannel.epgChannelId != null
        ? epgNotifier.getCurrentProgram(_currentChannel.epgChannelId!)
        : null;

    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
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
            _buildTopBar(currentProgram?.title),
            Expanded(child: _buildCenterControls()),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(String? programTitle) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: widget.onClose ?? () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentChannel.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (programTitle != null)
                    Text(
                      programTitle,
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
            if (widget.onMinimize != null) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.picture_in_picture_alt,
                    color: Colors.white),
                onPressed: widget.onMinimize,
                tooltip: 'Mini player',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCenterControls() {
    final player = _player;

    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, color: Colors.white, size: 36),
            onPressed: _previousChannel,
            tooltip: 'Previous channel (↑)',
          ),
          const SizedBox(width: 24),
          if (!widget.isLive)
            IconButton(
              icon: const Icon(Icons.replay_10, color: Colors.white, size: 36),
              onPressed: player == null
                  ? null
                  : () => player
                      .seek(player.state.position - const Duration(seconds: 10)),
            ),
          const SizedBox(width: 16),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              iconSize: 64,
              icon: Icon(
                (player?.state.playing ?? false)
                    ? Icons.pause
                    : Icons.play_arrow,
                color: Colors.white,
              ),
              onPressed: player == null ? null : () => player.playOrPause(),
            ),
          ),
          const SizedBox(width: 16),
          if (!widget.isLive)
            IconButton(
              icon: const Icon(Icons.forward_10, color: Colors.white, size: 36),
              onPressed: player == null
                  ? null
                  : () => player
                      .seek(player.state.position + const Duration(seconds: 10)),
            ),
          const SizedBox(width: 24),
          IconButton(
            icon: const Icon(Icons.skip_next, color: Colors.white, size: 36),
            onPressed: _nextChannel,
            tooltip: 'Next channel (↓)',
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    final player = _player;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              (player?.state.volume ?? 0) == 0
                  ? Icons.volume_off
                  : Icons.volume_up,
              color: Colors.white,
            ),
            onPressed: player == null
                ? null
                : () => player.setVolume(player.state.volume > 0 ? 0 : 100),
          ),
          const Spacer(),
          Text(
            'Space: Play/Pause • ↑↓: Channel • M: Mute • R: Reconnect • F: Fullscreen',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 11,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              color: Colors.white,
            ),
            onPressed: _toggleFullscreen,
          ),
        ],
      ),
    );
  }
}

/// Rounded translucent container used by the buffering and watchdog banners.
class _Pill extends StatelessWidget {
  final Color color;
  final Widget child;

  const _Pill({required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}

Widget NoVideoControls(VideoState state) => const SizedBox.shrink();
