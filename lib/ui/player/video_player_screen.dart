import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/player/stream_tuning.dart';
import '../../core/player/stream_watchdog.dart';
import '../../core/theme/app_theme.dart';
import 'enhanced_video_player.dart' show autoReconnectProvider, bufferModeProvider;
import 'video_player_controls.dart';
import 'web_video_player.dart';

class VideoPlayerScreen extends ConsumerStatefulWidget {
  final String streamUrl;
  final String title;
  final String? subtitle;
  final String? logoUrl;
  final bool isLive;

  const VideoPlayerScreen({
    super.key,
    required this.streamUrl,
    required this.title,
    this.subtitle,
    this.logoUrl,
    this.isLive = true,
  });

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  bool _isFullscreen = false;
  bool _showControls = true;
  bool _isLoading = true;
  String? _errorMessage;

  StreamWatchdog? _watchdog;
  String _streamUrl = '';

  /// Where the viewer actually is. Recovery for VOD has to resume from here -
  /// restarting a two-hour film from zero would be worse than the freeze it is
  /// fixing.
  Duration _resumePosition = Duration.zero;

  @override
  void initState() {
    super.initState();
    _streamUrl = widget.streamUrl;

    // Immersive for the whole player lifetime - hide the phone's status bar and
    // nav buttons so video is truly full-screen. Restored in dispose. No-op on
    // desktop.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    if (!kIsWeb) {
      _initializePlayer();
    }
  }

  Future<void> _initializePlayer() async {
    _player = Player();
    _controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        // Software rendering on Linux only; see
        // StreamTuning.enableHardwareAcceleration. This was unconditional,
        // which made 1080p unplayable on low-power Android devices.
        enableHardwareAcceleration: StreamTuning.enableHardwareAcceleration,
      ),
    );

    await StreamTuning.apply(
      _player,
      mode: ref.read(bufferModeProvider),
      isLive: widget.isLive,
    );

    // Listen to player state changes
    _player.stream.playing.listen((playing) {
      if (mounted) setState(() {});
    });

    _player.stream.buffering.listen((buffering) {
      if (mounted) {
        setState(() {
          _isLoading = buffering;
        });
      }
    });

    _player.stream.position.listen((position) {
      if (position > Duration.zero) _resumePosition = position;
    });

    _player.stream.error.listen((error) {
      if (!mounted || error.isEmpty) return;
      if (ref.read(autoReconnectProvider)) {
        _watchdog?.forceRecovery(userInitiated: false);
      } else {
        setState(() {
          _errorMessage = StreamTuning.redactUrl(error);
          _isLoading = false;
        });
      }
    });

    // The recreate step is not offered here: _player is a `late final` field
    // that the rest of this screen reads directly, so it cannot be swapped out.
    // Reopen, hard reopen and the alternate-format fallback all still apply,
    // and for seekable VOD the nudge step is a seek, which flushes the decoder
    // and covers most of what recreate would have.
    //
    // Nor is the quality step: this screen is handed a bare stream URL for a
    // VODItem, with no Channel identity, so there is nothing to look siblings
    // up by. Omitting onDegradeQuality is what makes that rung report itself
    // unavailable and be skipped.
    _watchdog = StreamWatchdog(
      playerRef: () => _player,
      urlRef: () => _streamUrl,
      enabled: () => ref.read(autoReconnectProvider),
      isLive: widget.isLive,
      onOpen: _openAndResume,
      onUrlChanged: (url) => _streamUrl = url,
      onStatus: (status) {
        if (!mounted) return;
        setState(() {
          if (status.phase == WatchdogPhase.healthy) _errorMessage = null;
        });
      },
    );

    try {
      await _openAndResume(_streamUrl);
      _watchdog!.start();
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Failed to open stream: ${StreamTuning.redactUrl(e.toString())}';
          _isLoading = false;
        });
      }
    }
  }

  /// Opens [url] and, for VOD, seeks back to where the viewer was.
  Future<void> _openAndResume(String url) async {
    await _player.open(Media(url));
    _watchdog?.noteStreamOpened();

    if (!widget.isLive && _resumePosition > Duration.zero) {
      // The seek has to wait for the demuxer to report a duration, otherwise it
      // is silently dropped and playback restarts from the beginning.
      try {
        await _player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 10));
        await _player.seek(_resumePosition);
      } catch (e) {
        print('Could not restore VOD position: $e');
      }
    }
  }

  @override
  void dispose() {
    // Restore the system bars for the rest of the app.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _watchdog?.dispose();
    if (!kIsWeb) {
      _player.dispose();
    }
    super.dispose();
  }

  void _toggleFullscreen() {
    setState(() {
      _isFullscreen = !_isFullscreen;
    });

    // Player stays immersive throughout (see initState); the toggle only locks
    // orientation. Re-assert immersive in case the bars crept back.
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

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Use web video player for web platform
    if (kIsWeb) {
      return WebVideoPlayer(
        streamUrl: widget.streamUrl,
        title: widget.title,
        subtitle: widget.subtitle,
        isLive: widget.isLive,
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        // Plain GestureDetector on purpose: a whole-screen focusable node
        // would swallow directional traversal, the same trap the live player's
        // Focus interceptor exists to avoid. VOD is not reachable on TV today
        // (no Channel identity, so no quality siblings), so there is no remote
        // equivalent to add here.
        child: GestureDetector(
          onTap: _toggleControls,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Video Player
              Center(
                child: Video(
                  controller: _controller,
                  controls: NoVideoControls,
                ),
              ),

              // Loading indicator
              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator(
                    color: AppTheme.primaryColor,
                  ),
                ),

              // Error message
              if (_errorMessage != null)
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: AppTheme.errorColor,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Playback Error',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          _errorMessage!,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            _errorMessage = null;
                            _isLoading = true;
                          });
                          _player.open(Media(widget.streamUrl));
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                ),

              // Custom controls overlay
              if (_showControls && _errorMessage == null)
                VideoPlayerControls(
                  player: _player,
                  title: widget.title,
                  subtitle: widget.subtitle,
                  isLive: widget.isLive,
                  isFullscreen: _isFullscreen,
                  onToggleFullscreen: _toggleFullscreen,
                  onClose: () => Navigator.of(context).pop(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Empty controls widget for media_kit (we use our custom controls)
Widget NoVideoControls(VideoState state) {
  return const SizedBox.shrink();
}

