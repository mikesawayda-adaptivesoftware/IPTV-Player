import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';

class VideoPlayerControls extends StatefulWidget {
  final Player player;
  final String title;
  final String? subtitle;
  final bool isLive;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onClose;

  const VideoPlayerControls({
    super.key,
    required this.player,
    required this.title,
    this.subtitle,
    this.isLive = true,
    this.isFullscreen = false,
    required this.onToggleFullscreen,
    required this.onClose,
  });

  @override
  State<VideoPlayerControls> createState() => _VideoPlayerControlsState();
}

class _VideoPlayerControlsState extends State<VideoPlayerControls> {
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  bool _isMuted = false;
  bool _showVolumeSlider = false;
  Timer? _hideTimer;
  bool _visible = true;

  late final List<StreamSubscription> _subscriptions;

  @override
  void initState() {
    super.initState();
    _subscriptions = [
      widget.player.stream.playing.listen((playing) {
        if (mounted) setState(() => _isPlaying = playing);
      }),
      widget.player.stream.position.listen((position) {
        if (mounted) setState(() => _position = position);
      }),
      widget.player.stream.duration.listen((duration) {
        if (mounted) setState(() => _duration = duration);
      }),
      widget.player.stream.volume.listen((volume) {
        if (mounted) setState(() => _volume = volume / 100);
      }),
    ];
    _startHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _isPlaying) {
        setState(() => _visible = false);
      }
    });
  }

  void _showControls() {
    setState(() => _visible = true);
    _startHideTimer();
  }

  void _togglePlayPause() {
    widget.player.playOrPause();
    _showControls();
  }

  void _seekRelative(Duration offset) {
    final newPosition = _position + offset;
    if (newPosition.inSeconds >= 0 && newPosition <= _duration) {
      widget.player.seek(newPosition);
    }
    _showControls();
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

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (_) => _showControls(),
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
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
              _buildTopBar(),
              
              // Center controls
              Expanded(
                child: _buildCenterControls(),
              ),
              
              // Bottom bar with progress and controls
              _buildBottomBar(),
            ],
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
                      color: Colors.white.withOpacity(0.7),
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
        ],
      ),
    );
  }

  Widget _buildCenterControls() {
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Seek backward (only for VOD)
          if (!widget.isLive)
            IconButton(
              icon: const Icon(Icons.replay_10, color: Colors.white, size: 36),
              onPressed: () => _seekRelative(const Duration(seconds: -10)),
            ),
          
          const SizedBox(width: 32),
          
          // Play/Pause
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              iconSize: 64,
              icon: Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
              onPressed: _togglePlayPause,
            ),
          ),
          
          const SizedBox(width: 32),
          
          // Seek forward (only for VOD)
          if (!widget.isLive)
            IconButton(
              icon: const Icon(Icons.forward_10, color: Colors.white, size: 36),
              onPressed: () => _seekRelative(const Duration(seconds: 10)),
            ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Progress bar (only for VOD)
          if (!widget.isLive && _duration.inSeconds > 0) ...[
            Row(
              children: [
                Text(
                  _position.formatted,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                Expanded(
                  child: Slider(
                    value: _position.inSeconds.toDouble(),
                    max: _duration.inSeconds.toDouble(),
                    onChanged: (value) {
                      widget.player.seek(Duration(seconds: value.toInt()));
                      _showControls();
                    },
                    activeColor: AppTheme.primaryColor,
                    inactiveColor: Colors.white24,
                  ),
                ),
                Text(
                  _duration.formatted,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          
          // Control buttons
          Row(
            children: [
              // Volume controls
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
                      onPressed: _toggleMute,
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: _showVolumeSlider ? 100 : 0,
                      child: _showVolumeSlider
                          ? Slider(
                              value: _isMuted ? 0 : _volume,
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
              
              // Fullscreen toggle
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

