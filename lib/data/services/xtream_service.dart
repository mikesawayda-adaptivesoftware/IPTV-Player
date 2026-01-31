import 'package:dio/dio.dart';

import '../../core/constants/api_constants.dart';
import '../models/category.dart';
import '../models/channel.dart';
import '../models/epg_program.dart';
import '../models/playlist_source.dart';
import '../models/server_info.dart';
import '../models/vod_item.dart';

class XtreamService {
  final Dio _dio;
  
  PlaylistSource? _currentSource;
  ServerInfo? _serverInfo;

  XtreamService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: ApiConstants.connectionTimeout,
              receiveTimeout: ApiConstants.receiveTimeout,
            ));

  /// Set the current Xtream source to use
  void setSource(PlaylistSource source) {
    if (source.type != PlaylistType.xtream) {
      throw ArgumentError('Source must be of type Xtream');
    }
    _currentSource = source;
    _serverInfo = null;
  }

  /// Get the current source
  PlaylistSource? get currentSource => _currentSource;

  /// Get cached server info
  ServerInfo? get serverInfo => _serverInfo;

  /// Authenticate and get server info
  Future<ServerInfo> authenticate() async {
    _ensureSourceSet();
    
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        _currentSource!.xtreamApiUrl,
      );
      
      if (response.data == null) {
        throw Exception('Empty response from server');
      }
      
      _serverInfo = ServerInfo.fromXtream(response.data!);
      
      if (!_serverInfo!.isActive) {
        throw Exception(_serverInfo!.message ?? 'Account is not active');
      }
      
      return _serverInfo!;
    } on DioException catch (e) {
      throw Exception('Authentication failed: ${e.message}');
    }
  }

  /// Get live TV categories
  Future<List<Category>> getLiveCategories() async {
    _ensureSourceSet();
    
    try {
      final response = await _dio.get<List<dynamic>>(
        '${_currentSource!.xtreamApiUrl}&action=${ApiConstants.getLiveCategories}',
      );
      
      if (response.data == null) return [];
      
      return response.data!
          .map((json) => Category.fromXtream(json as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw Exception('Failed to fetch live categories: ${e.message}');
    }
  }

  /// Get live TV channels
  Future<List<Channel>> getLiveStreams({String? categoryId}) async {
    _ensureSourceSet();
    
    try {
      String url = '${_currentSource!.xtreamApiUrl}&action=${ApiConstants.getLiveStreams}';
      if (categoryId != null && categoryId.isNotEmpty) {
        url += '&category_id=$categoryId';
      }
      
      final response = await _dio.get<List<dynamic>>(url);
      
      if (response.data == null) return [];
      
      return response.data!
          .map((json) => Channel.fromXtream(
                json as Map<String, dynamic>,
                _currentSource!.url,
                _currentSource!.username!,
                _currentSource!.password!,
              ))
          .toList();
    } on DioException catch (e) {
      throw Exception('Failed to fetch live streams: ${e.message}');
    }
  }

  /// Get VOD categories
  Future<List<Category>> getVodCategories() async {
    _ensureSourceSet();
    
    try {
      final response = await _dio.get<List<dynamic>>(
        '${_currentSource!.xtreamApiUrl}&action=${ApiConstants.getVodCategories}',
      );
      
      if (response.data == null) return [];
      
      return response.data!
          .map((json) => Category.fromXtream(json as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw Exception('Failed to fetch VOD categories: ${e.message}');
    }
  }

  /// Get VOD streams (movies)
  Future<List<VODItem>> getVodStreams({String? categoryId}) async {
    _ensureSourceSet();
    
    try {
      String url = '${_currentSource!.xtreamApiUrl}&action=${ApiConstants.getVodStreams}';
      if (categoryId != null && categoryId.isNotEmpty) {
        url += '&category_id=$categoryId';
      }
      
      final response = await _dio.get<List<dynamic>>(url);
      
      if (response.data == null) return [];
      
      return response.data!
          .map((json) => VODItem.fromXtreamVod(
                json as Map<String, dynamic>,
                _currentSource!.url,
                _currentSource!.username!,
                _currentSource!.password!,
              ))
          .toList();
    } on DioException catch (e) {
      throw Exception('Failed to fetch VOD streams: ${e.message}');
    }
  }

  /// Get series categories
  Future<List<Category>> getSeriesCategories() async {
    _ensureSourceSet();
    
    try {
      final response = await _dio.get<List<dynamic>>(
        '${_currentSource!.xtreamApiUrl}&action=${ApiConstants.getSeriesCategories}',
      );
      
      if (response.data == null) return [];
      
      return response.data!
          .map((json) => Category.fromXtream(json as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw Exception('Failed to fetch series categories: ${e.message}');
    }
  }

  /// Get series list
  Future<List<Map<String, dynamic>>> getSeries({String? categoryId}) async {
    _ensureSourceSet();
    
    try {
      String url = '${_currentSource!.xtreamApiUrl}&action=${ApiConstants.getSeries}';
      if (categoryId != null && categoryId.isNotEmpty) {
        url += '&category_id=$categoryId';
      }
      
      final response = await _dio.get<List<dynamic>>(url);
      
      if (response.data == null) return [];
      
      return response.data!.cast<Map<String, dynamic>>();
    } on DioException catch (e) {
      throw Exception('Failed to fetch series: ${e.message}');
    }
  }

  /// Get series info (episodes)
  Future<Map<String, dynamic>> getSeriesInfo(int seriesId) async {
    _ensureSourceSet();
    
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '${_currentSource!.xtreamApiUrl}&action=${ApiConstants.getSeriesInfo}&series_id=$seriesId',
      );
      
      if (response.data == null) {
        throw Exception('Series not found');
      }
      
      return response.data!;
    } on DioException catch (e) {
      throw Exception('Failed to fetch series info: ${e.message}');
    }
  }

  /// Get VOD info
  Future<Map<String, dynamic>> getVodInfo(int vodId) async {
    _ensureSourceSet();
    
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '${_currentSource!.xtreamApiUrl}&action=${ApiConstants.getVodInfo}&vod_id=$vodId',
      );
      
      if (response.data == null) {
        throw Exception('VOD not found');
      }
      
      return response.data!;
    } on DioException catch (e) {
      throw Exception('Failed to fetch VOD info: ${e.message}');
    }
  }

  /// Get short EPG for a channel
  Future<List<EPGProgram>> getShortEpg(String streamId, {int limit = 10}) async {
    _ensureSourceSet();
    
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '${_currentSource!.xtreamApiUrl}&action=${ApiConstants.getShortEpg}&stream_id=$streamId&limit=$limit',
      );
      
      if (response.data == null) return [];
      
      final epgListings = response.data!['epg_listings'];
      if (epgListings == null || epgListings is! List) return [];
      
      return epgListings
          .map((json) => EPGProgram.fromXtream(json as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw Exception('Failed to fetch EPG: ${e.message}');
    }
  }

  /// Get all EPG data
  Future<List<EPGProgram>> getAllEpg() async {
    _ensureSourceSet();
    
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '${_currentSource!.xtreamApiUrl}&action=${ApiConstants.getSimpleDataTable}&stream_id=all',
      );
      
      if (response.data == null) return [];
      
      final epgListings = response.data!['epg_listings'];
      if (epgListings == null || epgListings is! List) return [];
      
      return epgListings
          .map((json) => EPGProgram.fromXtream(json as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw Exception('Failed to fetch all EPG: ${e.message}');
    }
  }

  /// Get live stream URL with authentication
  String getLiveStreamUrl(int streamId, {String extension = 'ts'}) {
    _ensureSourceSet();
    return '${_currentSource!.url}/live/${_currentSource!.username}/${_currentSource!.password}/$streamId.$extension';
  }

  /// Get VOD stream URL with authentication
  String getVodStreamUrl(int vodId, {String extension = 'mp4'}) {
    _ensureSourceSet();
    return '${_currentSource!.url}/movie/${_currentSource!.username}/${_currentSource!.password}/$vodId.$extension';
  }

  /// Get series episode URL with authentication
  String getSeriesStreamUrl(int episodeId, {String extension = 'mp4'}) {
    _ensureSourceSet();
    return '${_currentSource!.url}/series/${_currentSource!.username}/${_currentSource!.password}/$episodeId.$extension';
  }

  void _ensureSourceSet() {
    if (_currentSource == null) {
      throw StateError('Xtream source not set. Call setSource() first.');
    }
  }
}

