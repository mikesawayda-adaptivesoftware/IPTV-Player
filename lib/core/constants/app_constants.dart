class AppConstants {
  AppConstants._();

  // App info
  static const String appName = 'IPTV Player';
  static const String appVersion = '1.0.0';

  // Hive box names
  static const String favoritesChannelsBox = 'favorites_channels';
  static const String favoritesVodBox = 'favorites_vod';
  static const String historyChannelsBox = 'history_channels';
  static const String historyVodBox = 'history_vod';
  static const String playlistSourcesBox = 'playlist_sources';
  static const String settingsBox = 'settings';

  // Settings keys
  static const String settingLastPlaylistId = 'last_playlist_id';
  static const String settingAutoPlay = 'auto_play';
  static const String settingDefaultVolume = 'default_volume';
  static const String settingEpgUpdateInterval = 'epg_update_interval';
  static const String settingBufferMode = 'buffer_mode';
  static const String settingAutoReconnect = 'auto_reconnect';

  // Cache durations
  static const Duration epgCacheDuration = Duration(hours: 12);
  static const Duration channelListCacheDuration = Duration(hours: 1);
  
  // UI constants
  static const int maxHistoryItems = 50;
  static const int maxSearchResults = 100;
  static const double channelCardHeight = 80.0;
  static const double vodCardWidth = 150.0;
  static const double vodCardHeight = 225.0;
}

