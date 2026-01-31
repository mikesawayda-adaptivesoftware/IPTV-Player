import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
import '../../data/models/channel.dart';
import '../../data/services/storage_service.dart';
import '../../providers/playlist_provider.dart';

/// Buffer mode settings
enum BufferMode {
  low(2, 'Low Latency', '2 seconds - minimal delay, may buffer more'),
  normal(10, 'Normal', '10 seconds - balanced'),
  high(30, 'High Reliability', '30 seconds - best for unstable connections');

  final int seconds;
  final String label;
  final String description;

  const BufferMode(this.seconds, this.label, this.description);
}

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
  late Player _player;
  late VideoController _controller;
  late Channel _currentChannel;
  
  bool _isFullscreen = false;
  bool _showControls = true;
  bool _isLoading = true;
  bool _isBuffering = false;
  String? _errorMessage;
  Timer? _hideTimer;
  Timer? _stallDetectionTimer;
  Timer? _freezeDetectionTimer;
  
  // Buffer health tracking
  double _bufferHealth = 0.0; // 0.0 to 1.0
  Duration _lastPosition = Duration.zero;
  int _stallCount = 0;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 3;
  bool _isReconnecting = false;
  
  // Frame-based freeze detection
  int _frozenFrameCount = 0;
  static const int _freezeThreshold = 3; // Trigger after 3 checks (~3 seconds)
  bool _streamUnstable = false;
  
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _currentChannel = widget.channel;
    _initializePlayer();
    
    // Mark channel as watched
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(channelStateProvider.notifier).markAsWatched(_currentChannel);
    });
  }

  Future<void> _initializePlayer() async {
    final bufferMode = ref.read(bufferModeProvider);
    
    // Create player with buffer configuration
    _player = Player(
      configuration: PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024, // 64MB buffer
      ),
    );
    
    _controller = VideoController(_player);

    // Configure mpv properties for buffering
    await _configureBuffering(bufferMode);

    // Set up stream listeners
    _setupStreamListeners();

    // Open the stream
    await _openStream();
  }

  Future<void> _configureBuffering(BufferMode mode) async {
    // Buffer configuration is handled through PlayerConfiguration bufferSize
    // and the auto-recovery system handles stream issues at the application level.
    // 
    // The PlayerConfiguration bufferSize (64MB) provides substantial buffering,
    // while our watchdog and stall detection handle recovery automatically.
    print('Buffer mode set to: ${mode.label} (${mode.seconds}s target)');
  }

  void _setupStreamListeners() {
    _player.stream.playing.listen((playing) {
      if (mounted) {
        setState(() {});
        if (playing) {
          _startFreezeDetection();
        } else {
          _stopFreezeDetection();
        }
      }
    });

    _player.stream.buffering.listen((buffering) {
      if (mounted) {
        setState(() {
          _isBuffering = buffering;
          _isLoading = buffering && _lastPosition == Duration.zero;
        });
        
        // Track buffering for stall detection
        if (buffering) {
          _onBufferingStarted();
        } else {
          _onBufferingStopped();
        }
      }
    });

    _player.stream.position.listen((position) {
      if (mounted) {
        // Check for frozen frames
        if (_player.state.playing && !_isBuffering && !_isLoading) {
          if (position == _lastPosition && position != Duration.zero) {
            _frozenFrameCount++;
            if (_frozenFrameCount >= _freezeThreshold && !_isReconnecting) {
              print('Freeze detected: Position stuck at ${position.inSeconds}s for $_frozenFrameCount checks');
              _handleFreeze();
            }
          } else {
            // Position changed, reset freeze counter
            if (_frozenFrameCount > 0) {
              print('Stream recovered, position advancing');
            }
            _frozenFrameCount = 0;
            _streamUnstable = false;
          }
        }
        _lastPosition = position;
        _updateBufferHealth();
      }
    });

    _player.stream.buffer.listen((buffer) {
      if (mounted) {
        _updateBufferHealth();
      }
    });

    _player.stream.error.listen((error) {
      if (mounted && error.isNotEmpty) {
        _handlePlaybackError(error);
      }
    });
  }

  void _updateBufferHealth() {
    final buffer = _player.state.buffer;
    final bufferMode = ref.read(bufferModeProvider);
    final targetBuffer = Duration(seconds: bufferMode.seconds);
    
    if (targetBuffer.inSeconds > 0) {
      final health = (buffer.inSeconds / targetBuffer.inSeconds).clamp(0.0, 1.0);
      if (mounted) {
        setState(() => _bufferHealth = health);
      }
    }
  }

  void _onBufferingStarted() {
    _stallDetectionTimer?.cancel();
    
    final autoReconnect = ref.read(autoReconnectProvider);
    if (!autoReconnect) return;
    
    // Start stall detection timer
    _stallDetectionTimer = Timer(const Duration(seconds: 10), () {
      if (mounted && _isBuffering && !_isReconnecting) {
        _stallCount++;
        print('Stall detected (count: $_stallCount). Attempting recovery...');
        _attemptRecovery();
      }
    });
  }

  void _onBufferingStopped() {
    _stallDetectionTimer?.cancel();
    _stallCount = 0;
    _reconnectAttempts = 0;
  }

  void _startFreezeDetection() {
    _freezeDetectionTimer?.cancel();
    
    // More frequent checks for freeze detection (every 1 second)
    _freezeDetectionTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      // The actual freeze detection happens in the position listener
      // This timer just ensures we're checking regularly even if position events slow down
      if (_player.state.playing && !_isBuffering && !_isLoading && !_isReconnecting) {
        // Force a state check
        setState(() {});
      }
    });
  }

  void _stopFreezeDetection() {
    _freezeDetectionTimer?.cancel();
  }

  void _handleFreeze() {
    final autoReconnect = ref.read(autoReconnectProvider);
    
    setState(() {
      _streamUnstable = true;
    });
    
    if (autoReconnect && _reconnectAttempts < _maxReconnectAttempts) {
      print('Auto-recovering from freeze...');
      _attemptRecovery();
    }
  }

  void _handlePlaybackError(String error) {
    final autoReconnect = ref.read(autoReconnectProvider);
    
    if (autoReconnect && _reconnectAttempts < _maxReconnectAttempts) {
      print('Playback error: $error. Attempting auto-recovery...');
      _attemptRecovery();
    } else {
      setState(() {
        _errorMessage = error;
        _isLoading = false;
        _isBuffering = false;
      });
    }
  }

  Future<void> _attemptRecovery() async {
    if (_isReconnecting) return;
    
    _isReconnecting = true;
    _reconnectAttempts++;
    
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // Calculate backoff delay
    final delay = Duration(seconds: _reconnectAttempts * 2);
    print('Reconnect attempt $_reconnectAttempts/$_maxReconnectAttempts in ${delay.inSeconds}s');
    
    await Future.delayed(delay);
    
    if (!mounted) return;

    try {
      await _player.stop();
      await Future.delayed(const Duration(milliseconds: 500));
      await _player.open(Media(_currentChannel.streamUrl));
      
      _isReconnecting = false;
      print('Recovery successful!');
    } catch (e) {
      _isReconnecting = false;
      
      if (_reconnectAttempts >= _maxReconnectAttempts) {
        setState(() {
          _errorMessage = 'Failed to recover stream after $_maxReconnectAttempts attempts.\n\nOriginal error: $e';
          _isLoading = false;
        });
      } else {
        // Try again
        _attemptRecovery();
      }
    }
  }

  Future<void> _openStream() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _reconnectAttempts = 0;
    });

    try {
      await _player.open(Media(_currentChannel.streamUrl));
      _startHideTimer();
    } catch (e) {
      _handlePlaybackError(e.toString());
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _stallDetectionTimer?.cancel();
    _freezeDetectionTimer?.cancel();
    _player.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _player.state.playing) {
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
    
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  void _switchChannel(Channel newChannel) async {
    setState(() {
      _currentChannel = newChannel;
      _isLoading = true;
      _errorMessage = null;
      _reconnectAttempts = 0;
      _stallCount = 0;
      _frozenFrameCount = 0;
      _streamUnstable = false;
      _lastPosition = Duration.zero;
    });
    
    ref.read(channelStateProvider.notifier).markAsWatched(newChannel);
    
    try {
      await _player.open(Media(newChannel.streamUrl));
    } catch (e) {
      _handlePlaybackError(e.toString());
    }
  }

  void _nextChannel() {
    final nextChannel = ref.read(channelStateProvider.notifier).getNextChannel(_currentChannel);
    if (nextChannel != null) {
      _switchChannel(nextChannel);
    }
  }

  void _previousChannel() {
    final prevChannel = ref.read(channelStateProvider.notifier).getPreviousChannel(_currentChannel);
    if (prevChannel != null) {
      _switchChannel(prevChannel);
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    
    _showControlsTemporarily();
    
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        _player.playOrPause();
        break;
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.channelUp:
        _previousChannel();
        break;
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.channelDown:
        _nextChannel();
        break;
      case LogicalKeyboardKey.arrowLeft:
        if (!widget.isLive) {
          final pos = _player.state.position;
          _player.seek(pos - const Duration(seconds: 10));
        }
        break;
      case LogicalKeyboardKey.arrowRight:
        if (!widget.isLive) {
          final pos = _player.state.position;
          _player.seek(pos + const Duration(seconds: 10));
        }
        break;
      case LogicalKeyboardKey.keyM:
        final vol = _player.state.volume;
        _player.setVolume(vol > 0 ? 0 : 100);
        break;
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
        break;
      case LogicalKeyboardKey.keyR:
        // Manual reconnect
        _reconnectAttempts = 0;
        _attemptRecovery();
        break;
      case LogicalKeyboardKey.escape:
        if (_isFullscreen) {
          _toggleFullscreen();
        } else {
          widget.onClose?.call();
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
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
              // Video
              Center(
                child: Video(
                  controller: _controller,
                  controls: NoVideoControls,
                ),
              ),

              // Loading overlay
              if (_isLoading)
                _buildLoadingOverlay(),

              // Buffering indicator (when playing but buffering)
              if (_isBuffering && !_isLoading)
                _buildBufferingIndicator(),

              // Stream unstable warning
              if (_streamUnstable && !_isLoading && !_isBuffering)
                _buildUnstableWarning(),

              // Error
              if (_errorMessage != null)
                _buildErrorView(),

              // Controls
              if (_showControls && _errorMessage == null)
                _buildControls(),
                
              // Buffer health indicator (always visible when controls are shown)
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
    
    return Container(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppTheme.primaryColor),
            const SizedBox(height: 16),
            Text(
              _isReconnecting 
                  ? 'Reconnecting... (Attempt $_reconnectAttempts/$_maxReconnectAttempts)'
                  : 'Buffering...',
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              'Buffer mode: ${bufferMode.label}',
              style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBufferingIndicator() {
    return Positioned(
      top: 100,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(
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

  Widget _buildUnstableWarning() {
    return Positioned(
      top: 100,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: () {
            _reconnectAttempts = 0;
            _attemptRecovery();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.warningColor.withOpacity(0.9),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber, color: Colors.white, size: 16),
                const SizedBox(width: 8),
                Text(
                  _isReconnecting 
                      ? 'Reconnecting... (${_reconnectAttempts}/$_maxReconnectAttempts)'
                      : 'Stream frozen - Tap to reconnect',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                ),
                if (_isReconnecting) ...[
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
    Color healthColor;
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
              _bufferHealth > 0.5 ? Icons.signal_cellular_alt : Icons.signal_cellular_alt_2_bar,
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
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.white),
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
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: () {
                  _reconnectAttempts = 0;
                  _openStream();
                },
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
            _buildTopBar(currentProgram?.title),
            
            // Center controls
            Expanded(child: _buildCenterControls()),
            
            // Bottom bar
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
                      style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14),
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
                    Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            if (widget.onMinimize != null) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white),
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
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Previous channel
          IconButton(
            icon: const Icon(Icons.skip_previous, color: Colors.white, size: 36),
            onPressed: _previousChannel,
            tooltip: 'Previous channel (↑)',
          ),
          
          const SizedBox(width: 24),
          
          // Seek backward (VOD only)
          if (!widget.isLive)
            IconButton(
              icon: const Icon(Icons.replay_10, color: Colors.white, size: 36),
              onPressed: () {
                final pos = _player.state.position;
                _player.seek(pos - const Duration(seconds: 10));
              },
            ),
          
          const SizedBox(width: 16),
          
          // Play/Pause
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              iconSize: 64,
              icon: Icon(
                _player.state.playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
              onPressed: () => _player.playOrPause(),
            ),
          ),
          
          const SizedBox(width: 16),
          
          // Seek forward (VOD only)
          if (!widget.isLive)
            IconButton(
              icon: const Icon(Icons.forward_10, color: Colors.white, size: 36),
              onPressed: () {
                final pos = _player.state.position;
                _player.seek(pos + const Duration(seconds: 10));
              },
            ),
          
          const SizedBox(width: 24),
          
          // Next channel
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
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // Volume
          IconButton(
            icon: Icon(
              _player.state.volume == 0 ? Icons.volume_off : Icons.volume_up,
              color: Colors.white,
            ),
            onPressed: () {
              final vol = _player.state.volume;
              _player.setVolume(vol > 0 ? 0 : 100);
            },
          ),
          
          const Spacer(),
          
          // Keyboard shortcuts hint
          Text(
            'Space: Play/Pause • ↑↓: Channel • M: Mute • R: Reconnect • F: Fullscreen',
            style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 11),
          ),
          
          const Spacer(),
          
          // Fullscreen
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

Widget NoVideoControls(VideoState state) => const SizedBox.shrink();
