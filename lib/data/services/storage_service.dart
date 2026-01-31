import 'package:hive/hive.dart';

import '../../core/constants/app_constants.dart';
import '../models/channel.dart';
import '../models/playlist_source.dart';
import '../models/vod_item.dart';

class StorageService {
  // Lazy getters for Hive boxes
  Box<Channel> get _favoritesChannelsBox => 
      Hive.box<Channel>(AppConstants.favoritesChannelsBox);
  
  Box<VODItem> get _favoritesVodBox => 
      Hive.box<VODItem>(AppConstants.favoritesVodBox);
  
  Box<Channel> get _historyChannelsBox => 
      Hive.box<Channel>(AppConstants.historyChannelsBox);
  
  Box<VODItem> get _historyVodBox => 
      Hive.box<VODItem>(AppConstants.historyVodBox);
  
  Box<PlaylistSource> get _playlistSourcesBox => 
      Hive.box<PlaylistSource>(AppConstants.playlistSourcesBox);
  
  Box get _settingsBox => 
      Hive.box(AppConstants.settingsBox);

  // ============ Playlist Sources ============
  
  /// Get all playlist sources
  List<PlaylistSource> getPlaylistSources() {
    return _playlistSourcesBox.values.toList();
  }

  /// Get a specific playlist source
  PlaylistSource? getPlaylistSource(String id) {
    return _playlistSourcesBox.get(id);
  }

  /// Add or update a playlist source
  Future<void> savePlaylistSource(PlaylistSource source) async {
    await _playlistSourcesBox.put(source.id, source);
  }

  /// Delete a playlist source
  Future<void> deletePlaylistSource(String id) async {
    await _playlistSourcesBox.delete(id);
  }

  /// Get the active playlist source
  PlaylistSource? getActivePlaylistSource() {
    try {
      return _playlistSourcesBox.values.firstWhere((s) => s.isActive);
    } catch (e) {
      return _playlistSourcesBox.values.isNotEmpty 
          ? _playlistSourcesBox.values.first 
          : null;
    }
  }

  /// Set a playlist source as active
  Future<void> setActivePlaylistSource(String id) async {
    for (final source in _playlistSourcesBox.values) {
      if (source.isActive && source.id != id) {
        await _playlistSourcesBox.put(
          source.id,
          source.copyWith(isActive: false),
        );
      }
    }
    
    final targetSource = _playlistSourcesBox.get(id);
    if (targetSource != null) {
      await _playlistSourcesBox.put(
        id,
        targetSource.copyWith(isActive: true),
      );
    }
  }

  // ============ Favorites - Channels ============
  
  /// Get all favorite channels
  List<Channel> getFavoriteChannels() {
    return _favoritesChannelsBox.values.toList();
  }

  /// Check if a channel is a favorite
  bool isChannelFavorite(String channelId) {
    return _favoritesChannelsBox.containsKey(channelId);
  }

  /// Add a channel to favorites
  Future<void> addChannelToFavorites(Channel channel) async {
    await _favoritesChannelsBox.put(
      channel.id,
      channel.copyWith(isFavorite: true),
    );
  }

  /// Remove a channel from favorites
  Future<void> removeChannelFromFavorites(String channelId) async {
    await _favoritesChannelsBox.delete(channelId);
  }

  /// Toggle channel favorite status
  Future<bool> toggleChannelFavorite(Channel channel) async {
    if (isChannelFavorite(channel.id)) {
      await removeChannelFromFavorites(channel.id);
      return false;
    } else {
      await addChannelToFavorites(channel);
      return true;
    }
  }

  // ============ Favorites - VOD ============
  
  /// Get all favorite VOD items
  List<VODItem> getFavoriteVodItems() {
    return _favoritesVodBox.values.toList();
  }

  /// Check if a VOD item is a favorite
  bool isVodFavorite(String vodId) {
    return _favoritesVodBox.containsKey(vodId);
  }

  /// Add a VOD item to favorites
  Future<void> addVodToFavorites(VODItem vodItem) async {
    await _favoritesVodBox.put(
      vodItem.id,
      vodItem.copyWith(isFavorite: true),
    );
  }

  /// Remove a VOD item from favorites
  Future<void> removeVodFromFavorites(String vodId) async {
    await _favoritesVodBox.delete(vodId);
  }

  /// Toggle VOD favorite status
  Future<bool> toggleVodFavorite(VODItem vodItem) async {
    if (isVodFavorite(vodItem.id)) {
      await removeVodFromFavorites(vodItem.id);
      return false;
    } else {
      await addVodToFavorites(vodItem);
      return true;
    }
  }

  // ============ History - Channels ============
  
  /// Get channel watch history
  List<Channel> getChannelHistory() {
    final channels = _historyChannelsBox.values.toList();
    channels.sort((a, b) => 
      (b.lastWatched ?? DateTime(1970)).compareTo(a.lastWatched ?? DateTime(1970))
    );
    return channels;
  }

  /// Add a channel to watch history
  Future<void> addChannelToHistory(Channel channel) async {
    final updatedChannel = channel.copyWith(
      lastWatched: DateTime.now(),
      isFavorite: isChannelFavorite(channel.id),
    );
    
    await _historyChannelsBox.put(channel.id, updatedChannel);
    
    // Trim history if too large
    await _trimHistory(_historyChannelsBox, AppConstants.maxHistoryItems);
  }

  /// Clear channel history
  Future<void> clearChannelHistory() async {
    await _historyChannelsBox.clear();
  }

  // ============ History - VOD ============
  
  /// Get VOD watch history
  List<VODItem> getVodHistory() {
    final items = _historyVodBox.values.toList();
    items.sort((a, b) => 
      (b.lastWatched ?? DateTime(1970)).compareTo(a.lastWatched ?? DateTime(1970))
    );
    return items;
  }

  /// Add a VOD item to watch history
  Future<void> addVodToHistory(VODItem vodItem, {Duration? progress}) async {
    final updatedItem = vodItem.copyWith(
      lastWatched: DateTime.now(),
      watchProgress: progress,
      isFavorite: isVodFavorite(vodItem.id),
    );
    
    await _historyVodBox.put(vodItem.id, updatedItem);
    
    // Trim history if too large
    await _trimHistory(_historyVodBox, AppConstants.maxHistoryItems);
  }

  /// Update VOD watch progress
  Future<void> updateVodProgress(String vodId, Duration progress) async {
    final item = _historyVodBox.get(vodId);
    if (item != null) {
      await _historyVodBox.put(
        vodId,
        item.copyWith(watchProgress: progress),
      );
    }
  }

  /// Clear VOD history
  Future<void> clearVodHistory() async {
    await _historyVodBox.clear();
  }

  // ============ Settings ============
  
  /// Get a setting value
  T? getSetting<T>(String key, {T? defaultValue}) {
    return _settingsBox.get(key, defaultValue: defaultValue) as T?;
  }

  /// Save a setting value
  Future<void> saveSetting<T>(String key, T value) async {
    await _settingsBox.put(key, value);
  }

  /// Delete a setting
  Future<void> deleteSetting(String key) async {
    await _settingsBox.delete(key);
  }

  /// Get last used playlist ID
  String? getLastPlaylistId() {
    return getSetting<String>(AppConstants.settingLastPlaylistId);
  }

  /// Set last used playlist ID
  Future<void> setLastPlaylistId(String id) async {
    await saveSetting(AppConstants.settingLastPlaylistId, id);
  }

  /// Get auto-play setting
  bool getAutoPlay() {
    return getSetting<bool>(AppConstants.settingAutoPlay, defaultValue: true) ?? true;
  }

  /// Set auto-play setting
  Future<void> setAutoPlay(bool value) async {
    await saveSetting(AppConstants.settingAutoPlay, value);
  }

  /// Get default volume setting
  double getDefaultVolume() {
    return getSetting<double>(AppConstants.settingDefaultVolume, defaultValue: 1.0) ?? 1.0;
  }

  /// Set default volume setting
  Future<void> setDefaultVolume(double value) async {
    await saveSetting(AppConstants.settingDefaultVolume, value);
  }

  // ============ Utility Methods ============
  
  /// Trim a history box to max items
  Future<void> _trimHistory<T>(Box<T> box, int maxItems) async {
    if (box.length > maxItems) {
      final keysToDelete = box.keys.take(box.length - maxItems).toList();
      await box.deleteAll(keysToDelete);
    }
  }

  /// Clear all data
  Future<void> clearAllData() async {
    await _favoritesChannelsBox.clear();
    await _favoritesVodBox.clear();
    await _historyChannelsBox.clear();
    await _historyVodBox.clear();
    await _playlistSourcesBox.clear();
    await _settingsBox.clear();
  }
}

