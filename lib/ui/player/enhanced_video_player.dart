import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/constants/app_constants.dart';
import '../../core/player/quality_controller.dart';
import '../../core/player/stream_quality.dart';
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
export '../../core/player/stream_quality.dart' show QualityPolicy;

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

/// Whether the player may lower quality on its own when the connection cannot
/// keep up. Same shape as [bufferModeProvider]: read straight from Hive here,
/// written at the settings call site.
final qualityPolicyProvider = StateProvider<QualityPolicy>((ref) {
  final storage = StorageService();
  final saved = storage.getSetting<int>(
    AppConstants.settingQualityPolicy,
    defaultValue: 0,
  );
  return QualityPolicy.values[saved ?? 0];
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
  late QualityController _quality;
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

  /// Diagnostic overlay, toggled with `I`. Off by default, and its sampler only
  /// runs while it is on - it reads eight mpv properties a second, which is not
  /// something to do behind the user's back.
  bool _showStats = false;
  Timer? _statsTimer;
  _StreamStats? _stats;

  /// Settled measurement per quality played this session, so two qualities can
  /// be compared side by side rather than remembered. Keyed by option label.
  final Map<String, _StreamStats> _qualitySamples = {};

  /// Recent video-bitrate readings. Instantaneous bitrate swings with scene
  /// complexity, so a single reading cannot meaningfully be compared with
  /// another - the overlay reports the mean of these.
  final List<double> _bitrateWindow = [];

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

    // Constructed before the watchdog because the watchdog's quality callbacks
    // point at it; its own watchdogRef is a closure, so the cycle is fine.
    _quality = QualityController(
      playerRef: () => _player,
      watchdogRef: () => _watchdog,
      onApply: _applyQuality,
      autoEnabled: _autoQualityEnabled,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );

    _watchdog = StreamWatchdog(
      playerRef: () => _player,
      urlRef: () => _streamUrl,
      enabled: () => ref.read(autoReconnectProvider),
      isLive: widget.isLive,
      onRecreate: _recreatePlayer,
      onOpen: _openUrl,
      onUrlChanged: (url) => _streamUrl = url,
      canDegradeQuality: () => _autoQualityEnabled() && _quality.canDegrade,
      onDegradeQuality: _quality.degrade,
      // The primary trigger. Congestion is detected while the stream is still
      // playing, so quality drops in about ten seconds rather than after the
      // whole repair ladder has failed.
      onCongested: _quality.degrade,
      onStatus: _onWatchdogStatus,
    );

    _bootstrap();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(channelStateProvider.notifier).markAsWatched(_currentChannel);
    });
  }

  Future<void> _bootstrap() async {
    await _createPlayer();
    _refreshQualityOptions();
    await _openUrl(_streamUrl);
    _watchdog.start();
    _quality.start();
    _startHideTimer();
  }

  /// Whether the automatic quality path may act.
  ///
  /// Auto-reconnect off means "do not change playback behind my back", which
  /// covers this too.
  bool _autoQualityEnabled() {
    return ref.read(qualityPolicyProvider) == QualityPolicy.auto &&
        ref.read(autoReconnectProvider);
  }

  /// Rebuilds the quality ladder for whatever channel is now current.
  void _refreshQualityOptions() {
    _quality.setOptions(
      ref.read(channelStateProvider).qualityIndex.optionsFor(
            channelId: _currentChannel.id,
            sourceLabel: _currentChannel.name,
            currentUrl: _currentChannel.streamUrl,
          ),
    );
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
      await _applyTuning(player);
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

  /// The one place mpv tuning is applied, so buffer mode and quality can never
  /// overwrite one another.
  ///
  /// The buffer-mode listener in [build] used to call [StreamTuning.apply]
  /// directly with only the mode, which meant changing buffer mode while in
  /// audio-only silently switched video back on and put the bandwidth straight
  /// back.
  Future<void> _applyTuning(Player player, {BufferMode? mode}) {
    final option = _quality.current;
    return StreamTuning.apply(
      player,
      mode: mode ?? ref.read(bufferModeProvider),
      isLive: widget.isLive,
      hlsBitrate: option?.hlsBitrate ?? 'max',
      videoDisabled: option?.videoDisabled ?? false,
    );
  }

  /// [QualityApply] for [QualityController].
  Future<void> _applyQuality(
    QualityOption option, {
    required bool userInitiated,
  }) async {
    final player = _player;
    if (player == null) return;

    // `hls-bitrate` and `vid` are read when the stream is opened, so the tuning
    // has to be re-applied before the open, not after it.
    await _applyTuning(player);
    _resetStatsWindow();
    await _openUrl(option.url, userInitiated: userInitiated);
  }

  void _attachListeners(Player player) {
    void listen<T>(Stream<T> stream, void Function(T) onData) {
      _subscriptions.add(stream.listen(onData));
    }

    listen(player.stream.playing, (_) {
      if (mounted) setState(() {});
    });

    // The mute icon reads player.state.volume, which is a snapshot - setVolume
    // alone rebuilds nothing, so the icon only caught up when an unrelated
    // setState fired (a tap, or the controls auto-hiding). Volume is a stream
    // for the same reason `playing` is.
    listen(player.stream.volume, (_) {
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

  Future<void> _openUrl(String url, {bool userInitiated = false}) async {
    final player = _player;
    if (player == null) return;

    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      // _currentChannel stays the channel the user chose even while a lower
      // quality is playing, so log the quality alongside it - otherwise a
      // sibling switch prints the source's name and looks like nothing
      // happened. Never log the URL itself; it carries the subscription
      // credentials.
      final quality = _quality.current;
      final via = quality == null || quality.isSource ? '' : ' [${quality.label}]';
      print('Opening stream: ${_currentChannel.name}$via');
      await player.open(Media(url));
      // Whatever is actually playing, including a quality sibling or an
      // alternate container, so the watchdog reads the right URL.
      _streamUrl = url;
      _watchdog.noteStreamOpened(userInitiated: userInitiated);
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
    _statsTimer?.cancel();
    _quality.dispose();
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

  /// Shared by the `M` key and the bottom-bar button.
  ///
  /// Deliberately does not setState: the volume listener in [_attachListeners]
  /// does that, so the icon stays correct even when something other than this
  /// changes the volume.
  void _toggleMute() {
    final player = _player;
    if (player == null) return;
    player.setVolume(player.state.volume > 0 ? 0 : 100);
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
    _refreshQualityOptions();
    _resetStatsWindow();
    _qualitySamples.clear();
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

  /// Manual reconnect - the R key and the on-screen banner. A clean slate:
  /// restores the channel's original URL in case the watchdog had fallen back
  /// to an alternate format that turned out to be worse, and undoes any
  /// quality degradation.
  Future<void> _manualReconnect() async {
    _streamUrl = _currentChannel.streamUrl;
    setState(() => _errorMessage = null);

    // Resetting quality re-opens the stream itself, so only fall through to the
    // recovery ladder when there was no degradation to undo.
    if (_quality.isDegraded) {
      await _quality.reset();
      return;
    }
    await _watchdog.forceRecovery();
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
        _toggleMute();
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
      case LogicalKeyboardKey.keyI:
        _toggleStats();
      case LogicalKeyboardKey.keyQ:
        _showQualityPicker();
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
        _applyTuning(player, mode: mode);
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

              // Video is off, so say so. A black frame with sound still playing
              // is indistinguishable from the freeze this was meant to fix.
              if (_quality.current?.videoDisabled ?? false)
                _buildAudioOnlyPanel(),

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

              // Shown whether or not the controls are up: it is the explanation
              // for why the picture got worse, plus the way back.
              if (_quality.isDegraded && _errorMessage == null)
                _buildQualityBadge(),

              if (_showStats) _buildStatsOverlay(),
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

  // ==========================================================================
  // Diagnostics overlay
  // ==========================================================================

  void _toggleStats() {
    setState(() => _showStats = !_showStats);
    _statsTimer?.cancel();
    if (!_showStats) return;

    _sampleStats();
    _statsTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _sampleStats());
  }

  Future<void> _sampleStats() async {
    final player = _player;
    if (player == null || !mounted) return;

    // Concurrently: each read carries its own timeout, and eight in series
    // would not fit the one-second interval on a struggling stream.
    final numbers = await Future.wait([
      StreamTuning.readDouble(player, 'video-params/w'),
      StreamTuning.readDouble(player, 'video-params/h'),
      StreamTuning.readDouble(player, 'video-bitrate'),
      StreamTuning.readDouble(player, 'audio-bitrate'),
      StreamTuning.readDouble(player, 'cache-speed'),
      StreamTuning.readDouble(player, 'demuxer-cache-time'),
      StreamTuning.readDouble(player, 'container-fps'),
    ]);
    final codec = await StreamTuning.readProperty(player, 'video-format');

    if (!mounted) return;

    final videoBitrate = numbers[2];
    if (videoBitrate != null && videoBitrate > 0) {
      _bitrateWindow.add(videoBitrate);
      if (_bitrateWindow.length > 12) _bitrateWindow.removeAt(0);
    }

    final stats = _StreamStats(
      width: numbers[0]?.round(),
      height: numbers[1]?.round(),
      videoBitrate: _bitrateWindow.isEmpty
          ? null
          : _bitrateWindow.reduce((a, b) => a + b) / _bitrateWindow.length,
      audioBitrate: numbers[3],
      cacheSpeed: numbers[4],
      cacheTime: numbers[5],
      fps: numbers[6],
      codec: codec,
      samples: _bitrateWindow.length,
    );

    setState(() {
      _stats = stats;
      // Recorded only once the average has settled, or the comparison table
      // fills with numbers from the first second of playback.
      final label = _quality.current?.label;
      if (label != null && stats.samples >= 8 && stats.width != null) {
        _qualitySamples[label] = stats;
      }
    });
  }

  /// A new stream invalidates both the running average and the resolution.
  void _resetStatsWindow() {
    _bitrateWindow.clear();
    _stats = null;
  }

  // ==========================================================================
  // Quality
  // ==========================================================================

  /// Badge shown while playing anything other than the source, with the way
  /// back. A downgrade nobody can see or undo is a support ticket.
  Widget _buildQualityBadge() {
    final option = _quality.current;
    if (option == null) return const SizedBox.shrink();

    return Positioned(
      top: 108,
      right: 16,
      child: GestureDetector(
        onTap: _showQualityPicker,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: AppTheme.warningColor, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_qualityIcon(option), color: AppTheme.warningColor, size: 13),
              const SizedBox(width: 5),
              Text(
                option.label,
                style: const TextStyle(
                  color: AppTheme.warningColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAudioOnlyPanel() {
    return Container(
      color: AppTheme.backgroundColor,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.graphic_eq, size: 56, color: AppTheme.primaryColor),
            const SizedBox(height: 16),
            const Text(
              'Audio only',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _currentChannel.name,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: () => _quality.reset(),
              icon: const Icon(Icons.videocam_outlined, size: 18),
              label: const Text('Turn video back on'),
            ),
          ],
        ),
      ),
    );
  }

  IconData _qualityIcon(QualityOption option) => switch (option.kind) {
        QualityKind.source => Icons.high_quality_outlined,
        QualityKind.sibling => Icons.sd_outlined,
        QualityKind.hlsCap => Icons.network_check,
        QualityKind.audioOnly => Icons.graphic_eq,
      };

  String _qualityDescription(QualityOption option) => switch (option.kind) {
        QualityKind.source => 'The channel as listed',
        QualityKind.sibling => 'A lower-bitrate version of this channel',
        QualityKind.hlsCap => 'Asks the provider for its smallest rendition',
        // Deliberately not overstated. On a muxed transport stream - which most
        // Xtream live channels are - the whole stream still has to be
        // downloaded; only the decoding stops.
        QualityKind.audioOnly =>
          'Stops decoding video. Saves power, but usually not data',
      };

  Future<void> _showQualityPicker() async {
    _showControlsTemporarily();

    final options = _quality.options;
    if (options.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No other quality is available for this channel'),
        ));
      }
      return;
    }

    final current = _quality.current;
    final chosen = await showModalBottomSheet<QualityOption>(
      context: context,
      backgroundColor: AppTheme.surfaceColor,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.tune, size: 18, color: AppTheme.textSecondary),
                  SizedBox(width: 8),
                  Text(
                    'Stream quality',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final option in options)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        _qualityIcon(option),
                        size: 20,
                        color: option == current
                            ? AppTheme.primaryColor
                            : AppTheme.textSecondary,
                      ),
                      title: Text(option.label),
                      subtitle: Text(
                        _qualityDescription(option),
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: option == current
                          ? const Icon(
                              Icons.check,
                              size: 18,
                              color: AppTheme.primaryColor,
                            )
                          : null,
                      onTap: () => Navigator.of(sheetContext).pop(option),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (chosen != null && chosen != current) {
      await _quality.selectManual(chosen);
    }
  }

  Widget _buildStatsOverlay() {
    final stats = _stats;
    final quality = _quality.current;

    // Ordered by measured pixel count, so if the labels lie the table says so.
    final compared = _qualitySamples.entries.toList()
      ..sort((a, b) => b.value.pixels.compareTo(a.value.pixels));

    return Positioned(
      left: 12,
      top: 72,
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.accentColor, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.analytics_outlined,
                    size: 13, color: AppTheme.accentColor),
                const SizedBox(width: 6),
                const Text(
                  'STREAM STATS',
                  style: TextStyle(
                    color: AppTheme.accentColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: _toggleStats,
                  child: const Icon(Icons.close, size: 13, color: Colors.white54),
                ),
              ],
            ),
            const SizedBox(height: 8),

            _statLine('playing', quality?.label ?? _currentChannel.name),
            _statLine('kind', quality?.kind.name ?? 'source'),
            const Divider(height: 12, color: Colors.white12),

            _statLine('resolution', stats?.resolution ?? '-'),
            _statLine(
              'video bitrate',
              _StreamStats.mbps(stats?.videoBitrate),
              // Below eight samples the mean is still moving, so say so rather
              // than let it be compared against a settled figure.
              provisional: (stats?.samples ?? 0) < 8,
            ),
            _statLine('audio bitrate', _StreamStats.mbps(stats?.audioBitrate)),
            _statLine('codec / fps',
                '${stats?.codec ?? '-'}  ${stats?.fps?.toStringAsFixed(0) ?? '-'}fps'),
            const Divider(height: 12, color: Colors.white12),

            _statLine('arriving', _StreamStats.mbpsFromBytes(stats?.cacheSpeed)),
            _statLine('demuxer cache',
                '${stats?.cacheTime?.toStringAsFixed(1) ?? '-'}s'),
            _statLine('buffer health', '${(_bufferHealth * 100).toInt()}%'),
            _statLine(
                'watchdog',
                _watchdogStatus.isHealthy
                    ? 'healthy'
                    : _watchdogStatus.phase.name),

            if (compared.length > 1) ...[
              const Divider(height: 14, color: Colors.white12),
              const Text(
                'MEASURED THIS SESSION',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 6),
              for (final entry in compared)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.key,
                          style: TextStyle(
                            color: entry.key == quality?.label
                                ? AppTheme.accentColor
                                : Colors.white70,
                            fontSize: 10,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${entry.value.resolution}  '
                        '${_StreamStats.mbps(entry.value.videoBitrate)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statLine(String label, String value, {bool provisional = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ),
          Expanded(
            child: Text(
              provisional && value != '-' ? '$value  (settling)' : value,
              style: TextStyle(
                color: provisional ? Colors.white54 : Colors.white,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
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
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(
                Icons.analytics_outlined,
                color: _showStats ? AppTheme.accentColor : Colors.white,
              ),
              onPressed: _toggleStats,
              tooltip: 'Stream stats (I)',
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
            onPressed: player == null ? null : _toggleMute,
          ),
          const Spacer(),
          Text(
            'Space: Play/Pause • ↑↓: Channel • M: Mute • Q: Quality • '
            'I: Stats • R: Reconnect • F: Fullscreen',
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

/// One sample of what libmpv reports about the stream actually playing.
///
/// These are measurements, not labels. A provider calling a channel `4K` says
/// nothing; `video-params/w` is the truth.
class _StreamStats {
  final int? width;
  final int? height;

  /// Mean of the recent `video-bitrate` readings, in bits per second.
  final double? videoBitrate;
  final double? audioBitrate;

  /// `cache-speed`, in *bytes* per second - mpv's unit.
  final double? cacheSpeed;
  final double? cacheTime;
  final double? fps;
  final String? codec;

  /// How many bitrate readings the mean is over, so a number that has not
  /// settled yet can be shown as provisional.
  final int samples;

  const _StreamStats({
    this.width,
    this.height,
    this.videoBitrate,
    this.audioBitrate,
    this.cacheSpeed,
    this.cacheTime,
    this.fps,
    this.codec,
    this.samples = 0,
  });

  String get resolution =>
      width == null || height == null ? '-' : '$width x $height';

  /// Pixel count, for ordering the comparison table by real size rather than
  /// by what the provider called it.
  int get pixels => (width ?? 0) * (height ?? 0);

  static String mbps(double? bitsPerSecond) {
    if (bitsPerSecond == null || bitsPerSecond <= 0) return '-';
    return '${(bitsPerSecond / 1000000).toStringAsFixed(2)} Mbps';
  }

  /// Bytes per second rendered as bits, so throughput and bitrate are
  /// directly comparable on screen.
  static String mbpsFromBytes(double? bytesPerSecond) =>
      mbps(bytesPerSecond == null ? null : bytesPerSecond * 8);
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
