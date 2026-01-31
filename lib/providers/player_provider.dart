import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../data/models/channel.dart';
import '../data/models/vod_item.dart';
import '../data/services/storage_service.dart';

// Storage service provider
final storageServiceProvider = Provider<StorageService>((ref) {
  return StorageService();
});

// Current playing channel provider
final currentChannelProvider = StateProvider<Channel?>((ref) => null);

// Current playing VOD provider
final currentVodProvider = StateProvider<VODItem?>((ref) => null);

// Player state
class PlayerState {
  final bool isPlaying;
  final bool isBuffering;
  final Duration position;
  final Duration duration;
  final double volume;
  final String? error;

  const PlayerState({
    this.isPlaying = false,
    this.isBuffering = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 1.0,
    this.error,
  });

  PlayerState copyWith({
    bool? isPlaying,
    bool? isBuffering,
    Duration? position,
    Duration? duration,
    double? volume,
    String? error,
  }) {
    return PlayerState(
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      error: error,
    );
  }
}

// Player state notifier
class PlayerStateNotifier extends StateNotifier<PlayerState> {
  Player? _player;

  PlayerStateNotifier() : super(const PlayerState());

  Player createPlayer() {
    _player?.dispose();
    _player = Player();
    
    _player!.stream.playing.listen((playing) {
      state = state.copyWith(isPlaying: playing);
    });
    
    _player!.stream.buffering.listen((buffering) {
      state = state.copyWith(isBuffering: buffering);
    });
    
    _player!.stream.position.listen((position) {
      state = state.copyWith(position: position);
    });
    
    _player!.stream.duration.listen((duration) {
      state = state.copyWith(duration: duration);
    });
    
    _player!.stream.volume.listen((volume) {
      state = state.copyWith(volume: volume / 100);
    });
    
    _player!.stream.error.listen((error) {
      if (error.isNotEmpty) {
        state = state.copyWith(error: error);
      }
    });
    
    return _player!;
  }

  Future<void> play(String url) async {
    state = state.copyWith(error: null, isBuffering: true);
    try {
      await _player?.open(Media(url));
    } catch (e) {
      state = state.copyWith(error: e.toString(), isBuffering: false);
    }
  }

  void pause() => _player?.pause();
  void resume() => _player?.play();
  void togglePlayPause() => _player?.playOrPause();
  void seek(Duration position) => _player?.seek(position);
  void setVolume(double volume) => _player?.setVolume(volume * 100);
  void stop() => _player?.stop();

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }
}

final playerStateProvider = StateNotifierProvider<PlayerStateNotifier, PlayerState>((ref) {
  return PlayerStateNotifier();
});

