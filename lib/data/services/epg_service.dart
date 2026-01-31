import 'dart:io';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../models/epg_program.dart';

class EPGService {
  final Dio _dio;
  
  // In-memory EPG cache
  final Map<String, List<EPGProgram>> _epgCache = {};
  DateTime? _lastFetchTime;

  EPGService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              receiveTimeout: const Duration(minutes: 2),
            ));

  /// Fetch and parse EPG from URL (XMLTV format)
  Future<Map<String, List<EPGProgram>>> fetchEpgFromUrl(String url) async {
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      
      if (response.data == null) {
        throw Exception('Empty EPG response');
      }
      
      final programs = parseXmlTv(response.data!);
      _cachePrograms(programs);
      _lastFetchTime = DateTime.now();
      
      return _epgCache;
    } on DioException catch (e) {
      throw Exception('Failed to fetch EPG: ${e.message}');
    }
  }

  /// Fetch and parse EPG from local file
  Future<Map<String, List<EPGProgram>>> fetchEpgFromFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('EPG file not found: $filePath');
      }
      
      final content = await file.readAsString();
      final programs = parseXmlTv(content);
      _cachePrograms(programs);
      _lastFetchTime = DateTime.now();
      
      return _epgCache;
    } catch (e) {
      throw Exception('Failed to read EPG file: $e');
    }
  }

  /// Parse XMLTV content
  List<EPGProgram> parseXmlTv(String xmlContent) {
    final programs = <EPGProgram>[];
    
    try {
      final document = XmlDocument.parse(xmlContent);
      final programElements = document.findAllElements('programme');
      
      for (final element in programElements) {
        final program = _parseProgramElement(element);
        if (program != null) {
          programs.add(program);
        }
      }
    } catch (e) {
      print('Error parsing XMLTV: $e');
    }
    
    return programs;
  }

  /// Parse a single programme element
  EPGProgram? _parseProgramElement(XmlElement element) {
    try {
      final channelId = element.getAttribute('channel');
      final start = element.getAttribute('start');
      final stop = element.getAttribute('stop');
      
      if (channelId == null || start == null || stop == null) {
        return null;
      }
      
      final titleElement = element.findElements('title').firstOrNull;
      final title = titleElement?.innerText ?? 'Unknown';
      
      final descElement = element.findElements('desc').firstOrNull;
      final description = descElement?.innerText;
      
      final categoryElement = element.findElements('category').firstOrNull;
      final category = categoryElement?.innerText;
      
      final iconElement = element.findElements('icon').firstOrNull;
      final iconUrl = iconElement?.getAttribute('src');
      
      return EPGProgram.fromXmlTv(
        channelId: channelId,
        title: title,
        start: start,
        stop: stop,
        desc: description,
        category: category,
        icon: iconUrl,
      );
    } catch (e) {
      return null;
    }
  }

  /// Cache programs by channel ID
  void _cachePrograms(List<EPGProgram> programs) {
    _epgCache.clear();
    
    for (final program in programs) {
      _epgCache.putIfAbsent(program.channelId, () => []).add(program);
    }
    
    // Sort programs by start time for each channel
    for (final programs in _epgCache.values) {
      programs.sort((a, b) => a.startTime.compareTo(b.startTime));
    }
  }

  /// Get EPG for a specific channel
  List<EPGProgram> getChannelEpg(String channelId) {
    return _epgCache[channelId] ?? [];
  }

  /// Get current program for a channel
  EPGProgram? getCurrentProgram(String channelId) {
    final programs = getChannelEpg(channelId);
    final now = DateTime.now();
    
    try {
      return programs.firstWhere(
        (p) => p.startTime.isBefore(now) && p.endTime.isAfter(now),
      );
    } catch (e) {
      return null;
    }
  }

  /// Get next program for a channel
  EPGProgram? getNextProgram(String channelId) {
    final programs = getChannelEpg(channelId);
    final now = DateTime.now();
    
    try {
      return programs.firstWhere(
        (p) => p.startTime.isAfter(now),
      );
    } catch (e) {
      return null;
    }
  }

  /// Get programs for a channel within a time range
  List<EPGProgram> getProgramsInRange(
    String channelId,
    DateTime start,
    DateTime end,
  ) {
    final programs = getChannelEpg(channelId);
    
    return programs.where((p) {
      return p.endTime.isAfter(start) && p.startTime.isBefore(end);
    }).toList();
  }

  /// Get programs for today
  List<EPGProgram> getTodayPrograms(String channelId) {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));
    
    return getProgramsInRange(channelId, startOfDay, endOfDay);
  }

  /// Get all channel IDs with EPG data
  List<String> getChannelIds() {
    return _epgCache.keys.toList();
  }

  /// Check if EPG cache is stale
  bool isCacheStale(Duration maxAge) {
    if (_lastFetchTime == null) return true;
    return DateTime.now().difference(_lastFetchTime!) > maxAge;
  }

  /// Clear EPG cache
  void clearCache() {
    _epgCache.clear();
    _lastFetchTime = null;
  }

  /// Get EPG data for multiple channels
  Map<String, List<EPGProgram>> getMultiChannelEpg(List<String> channelIds) {
    final result = <String, List<EPGProgram>>{};
    
    for (final channelId in channelIds) {
      final programs = getChannelEpg(channelId);
      if (programs.isNotEmpty) {
        result[channelId] = programs;
      }
    }
    
    return result;
  }

  /// Search programs by title
  List<EPGProgram> searchPrograms(String query) {
    final results = <EPGProgram>[];
    final lowerQuery = query.toLowerCase();
    
    for (final programs in _epgCache.values) {
      results.addAll(
        programs.where((p) => p.title.toLowerCase().contains(lowerQuery)),
      );
    }
    
    results.sort((a, b) => a.startTime.compareTo(b.startTime));
    return results;
  }
}

