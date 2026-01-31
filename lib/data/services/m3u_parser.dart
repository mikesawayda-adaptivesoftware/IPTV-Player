import 'dart:io';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../models/channel.dart';

class M3UParser {
  final Dio _dio;
  final Uuid _uuid = const Uuid();

  M3UParser({Dio? dio}) : _dio = dio ?? Dio();

  /// Parse M3U content from a URL
  Future<List<Channel>> parseFromUrl(String url) async {
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 60),
        ),
      );
      
      if (response.data == null) {
        throw Exception('Empty response from M3U URL');
      }
      
      return parseContent(response.data!);
    } on DioException catch (e) {
      throw Exception('Failed to fetch M3U file: ${e.message}');
    }
  }

  /// Parse M3U content from a local file
  Future<List<Channel>> parseFromFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('M3U file not found: $filePath');
      }
      
      final content = await file.readAsString();
      return parseContent(content);
    } catch (e) {
      throw Exception('Failed to read M3U file: $e');
    }
  }

  /// Parse M3U content string
  List<Channel> parseContent(String content) {
    final channels = <Channel>[];
    final lines = content.split('\n').map((e) => e.trim()).toList();
    
    if (lines.isEmpty) return channels;
    
    // Check for M3U header (optional, some files don't have it)
    int startIndex = 0;
    if (lines[0].toUpperCase().startsWith('#EXTM3U')) {
      startIndex = 1;
    }

    String? currentExtInf;
    
    for (int i = startIndex; i < lines.length; i++) {
      final line = lines[i];
      
      if (line.isEmpty || line.startsWith('#EXTVLCOPT')) {
        continue;
      }
      
      if (line.startsWith('#EXTINF:')) {
        currentExtInf = line;
      } else if (!line.startsWith('#') && currentExtInf != null) {
        // This is a stream URL
        final channel = _parseChannel(currentExtInf, line);
        if (channel != null) {
          channels.add(channel);
        }
        currentExtInf = null;
      }
    }
    
    return channels;
  }

  /// Parse a single channel from EXTINF line and URL
  Channel? _parseChannel(String extInf, String url) {
    try {
      // Remove #EXTINF: prefix and get the rest
      final extinfoContent = extInf.substring(8);
      
      // Parse attributes and name
      final attributes = _parseAttributes(extinfoContent);
      final name = _extractChannelName(extinfoContent);
      
      if (name.isEmpty || url.isEmpty) return null;
      
      return Channel.fromM3U(
        id: _uuid.v4(),
        name: name,
        streamUrl: url.trim(),
        attributes: attributes,
      );
    } catch (e) {
      print('Error parsing channel: $e');
      return null;
    }
  }

  /// Parse EXTINF attributes
  Map<String, String> _parseAttributes(String extinf) {
    final attributes = <String, String>{};
    
    // Match attribute patterns like key="value" or key=value
    final attrRegex = RegExp(r'([a-zA-Z0-9_-]+)="([^"]*)"');
    final matches = attrRegex.allMatches(extinf);
    
    for (final match in matches) {
      final key = match.group(1)?.toLowerCase();
      final value = match.group(2);
      if (key != null && value != null) {
        attributes[key] = value.trim();
      }
    }
    
    return attributes;
  }

  /// Extract channel name from EXTINF line
  String _extractChannelName(String extinf) {
    // The name is typically after the last comma
    final commaIndex = extinf.lastIndexOf(',');
    if (commaIndex != -1 && commaIndex < extinf.length - 1) {
      return extinf.substring(commaIndex + 1).trim();
    }
    
    // Fallback: try to find name after duration
    final match = RegExp(r'^-?\d+\s*,?\s*(.+)$').firstMatch(extinf);
    return match?.group(1)?.trim() ?? '';
  }

  /// Get unique group titles from a list of channels
  List<String> extractGroups(List<Channel> channels) {
    final groups = <String>{};
    
    for (final channel in channels) {
      if (channel.groupTitle != null && channel.groupTitle!.isNotEmpty) {
        groups.add(channel.groupTitle!);
      }
    }
    
    return groups.toList()..sort();
  }

  /// Filter channels by group title
  List<Channel> filterByGroup(List<Channel> channels, String groupTitle) {
    return channels
        .where((c) => c.groupTitle?.toLowerCase() == groupTitle.toLowerCase())
        .toList();
  }

  /// Search channels by name
  List<Channel> searchByName(List<Channel> channels, String query) {
    final lowerQuery = query.toLowerCase();
    return channels
        .where((c) => c.name.toLowerCase().contains(lowerQuery))
        .toList();
  }
}

