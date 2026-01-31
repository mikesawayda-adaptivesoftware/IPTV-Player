import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/models/category.dart';
import '../data/models/channel.dart';
import '../data/models/epg_program.dart';
import '../data/models/playlist_source.dart';
import '../data/models/vod_item.dart';
import '../data/services/epg_service.dart';
import '../data/services/m3u_parser.dart';
import '../data/services/storage_service.dart';
import '../data/services/xtream_service.dart';

// Service providers
final m3uParserProvider = Provider<M3UParser>((ref) => M3UParser());
final xtreamServiceProvider = Provider<XtreamService>((ref) => XtreamService());
final epgServiceProvider = Provider<EPGService>((ref) => EPGService());
final playlistStorageProvider = Provider<StorageService>((ref) => StorageService());

// Playlist sources provider
final playlistSourcesProvider = StateNotifierProvider<PlaylistSourcesNotifier, List<PlaylistSource>>((ref) {
  final storage = ref.watch(playlistStorageProvider);
  return PlaylistSourcesNotifier(storage);
});

class PlaylistSourcesNotifier extends StateNotifier<List<PlaylistSource>> {
  final StorageService _storage;
  final Uuid _uuid = const Uuid();

  PlaylistSourcesNotifier(this._storage) : super([]) {
    _loadSources();
  }

  void _loadSources() {
    state = _storage.getPlaylistSources();
  }

  Future<void> addM3UPlaylist(String name, String url, {String? epgUrl}) async {
    final source = PlaylistSource.m3u(
      id: _uuid.v4(),
      name: name,
      url: url,
      epgUrl: epgUrl,
    );
    await _storage.savePlaylistSource(source);
    _loadSources();
  }

  Future<void> addXtreamPlaylist(
    String name,
    String serverUrl,
    String username,
    String password,
  ) async {
    final source = PlaylistSource.xtream(
      id: _uuid.v4(),
      name: name,
      serverUrl: serverUrl,
      username: username,
      password: password,
    );
    await _storage.savePlaylistSource(source);
    _loadSources();
  }

  Future<void> deletePlaylist(String id) async {
    await _storage.deletePlaylistSource(id);
    _loadSources();
  }

  Future<void> setActive(String id) async {
    await _storage.setActivePlaylistSource(id);
    _loadSources();
  }
}

// Active playlist provider
final activePlaylistProvider = Provider<PlaylistSource?>((ref) {
  final sources = ref.watch(playlistSourcesProvider);
  try {
    return sources.firstWhere((s) => s.isActive);
  } catch (e) {
    return sources.isNotEmpty ? sources.first : null;
  }
});

// Channel state
class ChannelState {
  final List<Channel> channels;
  final List<Category> categories;
  final String? selectedCategoryId;
  final bool isLoading;
  final String? error;

  const ChannelState({
    this.channels = const [],
    this.categories = const [],
    this.selectedCategoryId,
    this.isLoading = false,
    this.error,
  });

  ChannelState copyWith({
    List<Channel>? channels,
    List<Category>? categories,
    String? selectedCategoryId,
    bool? isLoading,
    String? error,
  }) {
    return ChannelState(
      channels: channels ?? this.channels,
      categories: categories ?? this.categories,
      selectedCategoryId: selectedCategoryId ?? this.selectedCategoryId,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  List<Channel> get filteredChannels {
    if (selectedCategoryId == null || selectedCategoryId == 'all') {
      return channels;
    }
    if (selectedCategoryId == 'favorites') {
      return channels.where((c) => c.isFavorite).toList();
    }
    if (selectedCategoryId == 'recent') {
      return recentChannels;
    }
    return channels.where((c) => c.categoryId == selectedCategoryId || c.groupTitle == selectedCategoryId).toList();
  }
  
  List<Channel> get recentChannels {
    final recent = channels.where((c) => c.lastWatched != null).toList();
    recent.sort((a, b) => (b.lastWatched ?? DateTime(1970)).compareTo(a.lastWatched ?? DateTime(1970)));
    return recent.take(20).toList();
  }
}

// Channels provider
final channelStateProvider = StateNotifierProvider<ChannelStateNotifier, ChannelState>((ref) {
  return ChannelStateNotifier(
    ref.watch(m3uParserProvider),
    ref.watch(xtreamServiceProvider),
    ref.watch(playlistStorageProvider),
  );
});

class ChannelStateNotifier extends StateNotifier<ChannelState> {
  final M3UParser _m3uParser;
  final XtreamService _xtreamService;
  final StorageService _storage;

  ChannelStateNotifier(this._m3uParser, this._xtreamService, this._storage)
      : super(const ChannelState());

  Future<void> loadChannels(PlaylistSource source) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      List<Channel> channels;
      List<Category> categories = [];

      if (source.type == PlaylistType.m3u) {
        // Load from M3U
        if (source.url.startsWith('http')) {
          channels = await _m3uParser.parseFromUrl(source.url);
        } else {
          channels = await _m3uParser.parseFromFile(source.url);
        }

        // Extract categories from group titles
        final groups = _m3uParser.extractGroups(channels);
        categories = [
          Category.all(count: channels.length),
          Category.favorites(),
          Category.recent(),
          ...groups.map((g) => Category(id: g, name: g)),
        ];
      } else {
        // Load from Xtream
        _xtreamService.setSource(source);
        await _xtreamService.authenticate();

        final liveCategories = await _xtreamService.getLiveCategories();
        channels = await _xtreamService.getLiveStreams();
        
        categories = [
          Category.all(count: channels.length),
          Category.favorites(),
          Category.recent(),
          ...liveCategories,
        ];
      }

      // Apply favorite status from storage
      final favoriteIds = _storage.getFavoriteChannels().map((c) => c.id).toSet();
      channels = channels.map((c) => c.copyWith(isFavorite: favoriteIds.contains(c.id))).toList();

      // Update favorites count
      final favCount = channels.where((c) => c.isFavorite).length;
      categories = categories.map((cat) {
        if (cat.id == 'favorites') {
          return cat.copyWith(channelCount: favCount);
        }
        return cat;
      }).toList();

      state = state.copyWith(
        channels: channels,
        categories: categories,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  void selectCategory(String? categoryId) {
    state = state.copyWith(selectedCategoryId: categoryId);
  }

  Future<void> toggleFavorite(Channel channel) async {
    final isFavorite = await _storage.toggleChannelFavorite(channel);
    
    final updatedChannels = state.channels.map((c) {
      if (c.id == channel.id) {
        return c.copyWith(isFavorite: isFavorite);
      }
      return c;
    }).toList();

    // Update favorites count in categories
    final favCount = updatedChannels.where((c) => c.isFavorite).length;
    final updatedCategories = state.categories.map((cat) {
      if (cat.id == 'favorites') {
        return cat.copyWith(channelCount: favCount);
      }
      return cat;
    }).toList();

    state = state.copyWith(channels: updatedChannels, categories: updatedCategories);
  }

  Future<void> markAsWatched(Channel channel) async {
    await _storage.addChannelToHistory(channel);
    
    final updatedChannels = state.channels.map((c) {
      if (c.id == channel.id) {
        return c.copyWith(lastWatched: DateTime.now());
      }
      return c;
    }).toList();

    // Update recent count in categories
    final recentCount = updatedChannels.where((c) => c.lastWatched != null).take(20).length;
    final updatedCategories = state.categories.map((cat) {
      if (cat.id == 'recent') {
        return cat.copyWith(channelCount: recentCount);
      }
      return cat;
    }).toList();

    state = state.copyWith(channels: updatedChannels, categories: updatedCategories);
  }

  /// Get channel by index for channel surfing
  Channel? getChannelByIndex(int index) {
    final channels = state.filteredChannels;
    if (index >= 0 && index < channels.length) {
      return channels[index];
    }
    return null;
  }

  /// Get current channel index
  int getChannelIndex(Channel channel) {
    return state.filteredChannels.indexWhere((c) => c.id == channel.id);
  }

  /// Get next channel
  Channel? getNextChannel(Channel current) {
    final index = getChannelIndex(current);
    if (index == -1) return null;
    final nextIndex = (index + 1) % state.filteredChannels.length;
    return state.filteredChannels[nextIndex];
  }

  /// Get previous channel
  Channel? getPreviousChannel(Channel current) {
    final index = getChannelIndex(current);
    if (index == -1) return null;
    final prevIndex = (index - 1 + state.filteredChannels.length) % state.filteredChannels.length;
    return state.filteredChannels[prevIndex];
  }

  List<Channel> searchChannels(String query) {
    if (query.isEmpty) return state.filteredChannels;
    final lowerQuery = query.toLowerCase();
    return state.filteredChannels
        .where((c) => c.name.toLowerCase().contains(lowerQuery))
        .toList();
  }
}

// VOD state
class VODState {
  final List<VODItem> items;
  final List<Category> categories;
  final String? selectedCategoryId;
  final bool isLoading;
  final String? error;

  const VODState({
    this.items = const [],
    this.categories = const [],
    this.selectedCategoryId,
    this.isLoading = false,
    this.error,
  });

  VODState copyWith({
    List<VODItem>? items,
    List<Category>? categories,
    String? selectedCategoryId,
    bool? isLoading,
    String? error,
  }) {
    return VODState(
      items: items ?? this.items,
      categories: categories ?? this.categories,
      selectedCategoryId: selectedCategoryId ?? this.selectedCategoryId,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  List<VODItem> get filteredItems {
    if (selectedCategoryId == null || selectedCategoryId == 'all') {
      return items;
    }
    if (selectedCategoryId == 'favorites') {
      return items.where((i) => i.isFavorite).toList();
    }
    return items.where((i) => i.categoryId == selectedCategoryId).toList();
  }
}

// VOD provider
final vodStateProvider = StateNotifierProvider<VODStateNotifier, VODState>((ref) {
  return VODStateNotifier(
    ref.watch(xtreamServiceProvider),
    ref.watch(playlistStorageProvider),
  );
});

class VODStateNotifier extends StateNotifier<VODState> {
  final XtreamService _xtreamService;
  final StorageService _storage;

  VODStateNotifier(this._xtreamService, this._storage) : super(const VODState());

  Future<void> loadVOD(PlaylistSource source) async {
    if (source.type != PlaylistType.xtream) {
      state = state.copyWith(error: 'VOD is only available for Xtream sources');
      return;
    }

    state = state.copyWith(isLoading: true, error: null);

    try {
      _xtreamService.setSource(source);
      
      final categories = await _xtreamService.getVodCategories();
      final items = await _xtreamService.getVodStreams();

      // Apply favorite status from storage
      final favoriteIds = _storage.getFavoriteVodItems().map((v) => v.id).toSet();
      final updatedItems = items.map((v) => v.copyWith(isFavorite: favoriteIds.contains(v.id))).toList();

      state = state.copyWith(
        items: updatedItems,
        categories: [
          Category.all(count: items.length),
          ...categories,
        ],
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  void selectCategory(String? categoryId) {
    state = state.copyWith(selectedCategoryId: categoryId);
  }

  Future<void> toggleFavorite(VODItem item) async {
    final isFavorite = await _storage.toggleVodFavorite(item);
    
    final updatedItems = state.items.map((v) {
      if (v.id == item.id) {
        return v.copyWith(isFavorite: isFavorite);
      }
      return v;
    }).toList();

    state = state.copyWith(items: updatedItems);
  }

  List<VODItem> searchVOD(String query) {
    if (query.isEmpty) return state.filteredItems;
    final lowerQuery = query.toLowerCase();
    return state.filteredItems
        .where((v) => v.name.toLowerCase().contains(lowerQuery))
        .toList();
  }
}

// EPG state provider
final epgStateProvider = StateNotifierProvider<EPGStateNotifier, Map<String, List<EPGProgram>>>((ref) {
  return EPGStateNotifier(ref.watch(epgServiceProvider));
});

class EPGStateNotifier extends StateNotifier<Map<String, List<EPGProgram>>> {
  final EPGService _epgService;

  EPGStateNotifier(this._epgService) : super({});

  Future<void> loadEPG(String? epgUrl) async {
    if (epgUrl == null || epgUrl.isEmpty) return;

    try {
      final epgData = await _epgService.fetchEpgFromUrl(epgUrl);
      state = epgData;
    } catch (e) {
      // EPG loading failed, but don't block the app
      print('EPG loading failed: $e');
    }
  }

  EPGProgram? getCurrentProgram(String channelId) {
    return _epgService.getCurrentProgram(channelId);
  }

  EPGProgram? getNextProgram(String channelId) {
    return _epgService.getNextProgram(channelId);
  }

  List<EPGProgram> getChannelPrograms(String channelId) {
    return _epgService.getChannelEpg(channelId);
  }
}

