import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/player/stream_tuning.dart';
import '../../core/player/stream_watchdog.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/channel.dart';
import '../player/enhanced_video_player.dart';

// Mini player state provider
final miniPlayerProvider = StateNotifierProvider<MiniPlayerNotifier, MiniPlayerState>((ref) {
  return MiniPlayerNotifier(ref);
});

class MiniPlayerState {
  final Channel? channel;
  final Player? player;
  final VideoController? controller;
  final bool isVisible;
  final bool isExpanded;

  const MiniPlayerState({
    this.channel,
    this.player,
    this.controller,
    this.isVisible = false,
    this.isExpanded = false,
  });

  MiniPlayerState copyWith({
    Channel? channel,
    Player? player,
    VideoController? controller,
    bool? isVisible,
    bool? isExpanded,
  }) {
    return MiniPlayerState(
      channel: channel ?? this.channel,
      player: player ?? this.player,
      controller: controller ?? this.controller,
      isVisible: isVisible ?? this.isVisible,
      isExpanded: isExpanded ?? this.isExpanded,
    );
  }
}

class MiniPlayerNotifier extends StateNotifier<MiniPlayerState> {
  final Ref _ref;

  StreamWatchdog? _watchdog;
  String? _url;

  MiniPlayerNotifier(this._ref) : super(const MiniPlayerState());

  Future<void> play(Channel channel) async {
    _watchdog?.dispose();
    _watchdog = null;

    _url = channel.streamUrl;
    await _createPlayer(channel, _url!);

    // The mini player is by definition unattended - it sits in the corner while
    // the user does something else - so it needs recovery at least as much as
    // the full-screen player does.
    _watchdog = StreamWatchdog(
      playerRef: () => state.player,
      urlRef: () => _url ?? '',
      enabled: () => _ref.read(autoReconnectProvider),
      onRecreate: (url) => _createPlayer(state.channel ?? channel, url),
      onUrlChanged: (url) => _url = url,
    )..start();
  }

  Future<void> _createPlayer(Channel channel, String url) async {
    final old = state.player;
    if (old != null) {
      try {
        await old.dispose();
      } catch (e) {
        print('Error disposing mini player: $e');
      }
    }

    final player = Player();
    final controller = VideoController(player);

    // Publish before tuning - setProperty waits on VideoController
    // initialisation, which needs the Video widget mounted.
    state = MiniPlayerState(
      channel: channel,
      player: player,
      controller: controller,
      isVisible: true,
      isExpanded: state.isExpanded,
    );

    await StreamTuning.apply(
      player,
      mode: _ref.read(bufferModeProvider),
      isLive: true,
    );

    await player.open(Media(url));
    _watchdog?.noteStreamOpened();
  }

  void expand() {
    state = state.copyWith(isExpanded: true);
  }

  void minimize() {
    state = state.copyWith(isExpanded: false);
  }

  void hide() {
    _watchdog?.dispose();
    _watchdog = null;
    _url = null;
    state.player?.dispose();
    state = const MiniPlayerState();
  }

  void togglePlayPause() {
    state.player?.playOrPause();
  }

  @override
  void dispose() {
    _watchdog?.dispose();
    state.player?.dispose();
    super.dispose();
  }
}

class MiniPlayerWidget extends ConsumerWidget {
  const MiniPlayerWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final miniPlayer = ref.watch(miniPlayerProvider);
    
    if (!miniPlayer.isVisible || miniPlayer.channel == null) {
      return const SizedBox.shrink();
    }

    if (miniPlayer.isExpanded) {
      return _buildExpandedPlayer(context, ref, miniPlayer);
    }

    return _buildMiniPlayer(context, ref, miniPlayer);
  }

  Widget _buildMiniPlayer(BuildContext context, WidgetRef ref, MiniPlayerState state) {
    return Positioned(
      right: 16,
      bottom: 16,
      child: GestureDetector(
        onTap: () => ref.read(miniPlayerProvider.notifier).expand(),
        child: Container(
          width: 320,
          height: 180,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Video
                if (state.controller != null)
                  Video(
                    controller: state.controller!,
                    controls: NoVideoControls,
                  ),
                
                // Overlay
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.7),
                      ],
                    ),
                  ),
                ),
                
                // Controls
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: Row(
                    children: [
                      // Channel name
                      Expanded(
                        child: Text(
                          state.channel!.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w500,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      
                      // Play/Pause
                      IconButton(
                        icon: Icon(
                          state.player?.state.playing ?? false
                              ? Icons.pause
                              : Icons.play_arrow,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () => ref.read(miniPlayerProvider.notifier).togglePlayPause(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      
                      const SizedBox(width: 8),
                      
                      // Expand
                      IconButton(
                        icon: const Icon(Icons.fullscreen, color: Colors.white, size: 20),
                        onPressed: () => ref.read(miniPlayerProvider.notifier).expand(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      
                      const SizedBox(width: 8),
                      
                      // Close
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 20),
                        onPressed: () => ref.read(miniPlayerProvider.notifier).hide(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
                
                // Live badge
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.errorColor,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'LIVE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedPlayer(BuildContext context, WidgetRef ref, MiniPlayerState state) {
    return Positioned.fill(
      child: EnhancedVideoPlayer(
        channel: state.channel!,
        isLive: true,
        onClose: () => ref.read(miniPlayerProvider.notifier).hide(),
        onMinimize: () => ref.read(miniPlayerProvider.notifier).minimize(),
      ),
    );
  }
}

Widget NoVideoControls(VideoState state) => const SizedBox.shrink();

