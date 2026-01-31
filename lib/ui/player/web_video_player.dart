import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';

class WebVideoPlayer extends StatefulWidget {
  final String streamUrl;
  final String title;
  final String? subtitle;
  final bool isLive;

  const WebVideoPlayer({
    super.key,
    required this.streamUrl,
    required this.title,
    this.subtitle,
    this.isLive = true,
  });

  @override
  State<WebVideoPlayer> createState() => _WebVideoPlayerState();
}

class _WebVideoPlayerState extends State<WebVideoPlayer> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isLoading = true;
  bool _showControls = true;
  bool _hasError = false;
  String? _errorMessage;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
      _errorMessage = null;
    });

    try {
      // Try to convert .ts URL to HLS format if possible
      String url = widget.streamUrl;
      
      // Some Xtream servers support m3u8 output - try that first
      if (url.endsWith('.ts')) {
        // Try m3u8 variant
        url = url.replaceAll('.ts', '.m3u8');
      }

      _controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: {
          'User-Agent': 'IPTV Player/1.0',
        },
      );

      await _controller!.initialize();
      
      setState(() {
        _isInitialized = true;
        _isLoading = false;
      });

      _controller!.play();
      _controller!.addListener(_videoListener);
      _startHideTimer();
    } catch (e) {
      // If m3u8 failed, try original URL
      if (widget.streamUrl != _controller?.dataSource) {
        try {
          _controller?.dispose();
          _controller = VideoPlayerController.networkUrl(
            Uri.parse(widget.streamUrl),
            httpHeaders: {
              'User-Agent': 'IPTV Player/1.0',
            },
          );
          
          await _controller!.initialize();
          
          setState(() {
            _isInitialized = true;
            _isLoading = false;
          });

          _controller!.play();
          _controller!.addListener(_videoListener);
          _startHideTimer();
          return;
        } catch (e2) {
          // Both failed
        }
      }
      
      setState(() {
        _hasError = true;
        _isLoading = false;
        _errorMessage = 'This stream format may not be supported in web browsers.\n\nFor full playback support, run the app on macOS, Windows, or Android.';
      });
    }
  }

  void _videoListener() {
    if (_controller?.value.hasError == true) {
      setState(() {
        _hasError = true;
        _errorMessage = _controller?.value.errorDescription ?? 'Playback error';
      });
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _showControlsTemporarily() {
    setState(() => _showControls = true);
    _startHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_videoListener);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _showControlsTemporarily,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video
            if (_isInitialized && _controller != null)
              Center(
                child: AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio,
                  child: VideoPlayer(_controller!),
                ),
              ),

            // Loading
            if (_isLoading)
              const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: AppTheme.primaryColor),
                    SizedBox(height: 16),
                    Text(
                      'Loading stream...',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),

            // Error
            if (_hasError)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: AppTheme.errorColor,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Playback Error',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _errorMessage ?? 'Unable to play stream',
                        style: const TextStyle(color: Colors.white70),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ElevatedButton.icon(
                            onPressed: _initializePlayer,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                          ),
                          const SizedBox(width: 16),
                          OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white54),
                            ),
                            child: const Text('Go Back'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

            // Controls overlay
            if (_showControls && !_hasError)
              _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withOpacity(0.7),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withOpacity(0.7),
            ],
            stops: const [0.0, 0.2, 0.8, 1.0],
          ),
        ),
        child: Column(
          children: [
            // Top bar
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
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
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 14,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (widget.isLive)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
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
              ),
            ),

            // Center play/pause
            Expanded(
              child: Center(
                child: IconButton(
                  iconSize: 64,
                  icon: Icon(
                    (_controller?.value.isPlaying ?? false)
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    if (_controller?.value.isPlaying ?? false) {
                      _controller?.pause();
                    } else {
                      _controller?.play();
                    }
                    setState(() {});
                    _showControlsTemporarily();
                  },
                ),
              ),
            ),

            // Bottom bar
            if (_isInitialized && !widget.isLive)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text(
                      _controller?.value.position.formatted ?? '00:00',
                      style: const TextStyle(color: Colors.white),
                    ),
                    Expanded(
                      child: Slider(
                        value: _controller?.value.position.inSeconds.toDouble() ?? 0,
                        max: _controller?.value.duration.inSeconds.toDouble() ?? 1,
                        onChanged: (value) {
                          _controller?.seekTo(Duration(seconds: value.toInt()));
                          _showControlsTemporarily();
                        },
                        activeColor: AppTheme.primaryColor,
                        inactiveColor: Colors.white24,
                      ),
                    ),
                    Text(
                      _controller?.value.duration.formatted ?? '00:00',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

