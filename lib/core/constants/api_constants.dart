class ApiConstants {
  ApiConstants._();

  // Xtream Codes API endpoints
  static const String playerApi = 'player_api.php';
  static const String getLiveCategories = 'get_live_categories';
  static const String getLiveStreams = 'get_live_streams';
  static const String getVodCategories = 'get_vod_categories';
  static const String getVodStreams = 'get_vod_streams';
  static const String getSeriesCategories = 'get_series_categories';
  static const String getSeries = 'get_series';
  static const String getSeriesInfo = 'get_series_info';
  static const String getVodInfo = 'get_vod_info';
  static const String getShortEpg = 'get_short_epg';
  static const String getSimpleDataTable = 'get_simple_data_table';
  static const String xmltvApi = 'xmltv.php';

  // Stream URL formats
  static const String liveStreamFormat = '/live/{username}/{password}/{streamId}.ts';
  static const String vodStreamFormat = '/movie/{username}/{password}/{streamId}.{extension}';
  static const String seriesStreamFormat = '/series/{username}/{password}/{streamId}.{extension}';
  
  // Timeouts
  static const Duration connectionTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 60);
}

