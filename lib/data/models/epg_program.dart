import 'package:equatable/equatable.dart';

class EPGProgram extends Equatable {
  final String channelId;
  final String title;
  final DateTime startTime;
  final DateTime endTime;
  final String? description;
  final String? category;
  final String? iconUrl;
  final String? episodeNumber;
  final String? seasonNumber;

  const EPGProgram({
    required this.channelId,
    required this.title,
    required this.startTime,
    required this.endTime,
    this.description,
    this.category,
    this.iconUrl,
    this.episodeNumber,
    this.seasonNumber,
  });

  /// Check if this program is currently airing
  bool get isLive {
    final now = DateTime.now();
    return now.isAfter(startTime) && now.isBefore(endTime);
  }

  /// Check if this program has ended
  bool get hasEnded => DateTime.now().isAfter(endTime);

  /// Check if this program is upcoming
  bool get isUpcoming => DateTime.now().isBefore(startTime);

  /// Get program duration
  Duration get duration => endTime.difference(startTime);

  /// Get progress percentage (0.0 to 1.0) if currently airing
  double get progress {
    if (!isLive) return hasEnded ? 1.0 : 0.0;
    final now = DateTime.now();
    final elapsed = now.difference(startTime);
    return elapsed.inSeconds / duration.inSeconds;
  }

  /// Create from XMLTV programme element
  factory EPGProgram.fromXmlTv({
    required String channelId,
    required String title,
    required String start,
    required String stop,
    String? desc,
    String? category,
    String? icon,
  }) {
    return EPGProgram(
      channelId: channelId,
      title: title,
      startTime: _parseXmlTvDate(start),
      endTime: _parseXmlTvDate(stop),
      description: desc,
      category: category,
      iconUrl: icon,
    );
  }

  /// Create from Xtream Codes EPG API response
  factory EPGProgram.fromXtream(Map<String, dynamic> json) {
    return EPGProgram(
      channelId: json['channel_id']?.toString() ?? json['epg_id']?.toString() ?? '',
      title: json['title'] ?? 'Unknown',
      startTime: _parseXtreamDate(json['start'] ?? json['start_timestamp']),
      endTime: _parseXtreamDate(json['end'] ?? json['stop_timestamp']),
      description: json['description'] ?? json['desc'],
    );
  }

  /// Parse XMLTV date format (YYYYMMDDHHmmss +/-HHMM)
  static DateTime _parseXmlTvDate(String dateStr) {
    try {
      // Format: YYYYMMDDHHmmss +0000
      final parts = dateStr.split(' ');
      final datePart = parts[0];
      
      final year = int.parse(datePart.substring(0, 4));
      final month = int.parse(datePart.substring(4, 6));
      final day = int.parse(datePart.substring(6, 8));
      final hour = int.parse(datePart.substring(8, 10));
      final minute = int.parse(datePart.substring(10, 12));
      final second = datePart.length >= 14 ? int.parse(datePart.substring(12, 14)) : 0;

      var dateTime = DateTime.utc(year, month, day, hour, minute, second);

      // Apply timezone offset if present
      if (parts.length > 1) {
        final offset = parts[1];
        final sign = offset.startsWith('-') ? -1 : 1;
        final offsetStr = offset.replaceAll(RegExp(r'[+-]'), '');
        if (offsetStr.length >= 4) {
          final offsetHours = int.parse(offsetStr.substring(0, 2));
          final offsetMinutes = int.parse(offsetStr.substring(2, 4));
          dateTime = dateTime.subtract(Duration(
            hours: sign * offsetHours,
            minutes: sign * offsetMinutes,
          ));
        }
      }

      return dateTime.toLocal();
    } catch (e) {
      return DateTime.now();
    }
  }

  /// Parse Xtream date (can be Unix timestamp or datetime string)
  static DateTime _parseXtreamDate(dynamic date) {
    if (date == null) return DateTime.now();
    
    if (date is int) {
      return DateTime.fromMillisecondsSinceEpoch(date * 1000);
    }
    
    if (date is String) {
      // Try Unix timestamp first
      final timestamp = int.tryParse(date);
      if (timestamp != null) {
        return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
      }
      // Try ISO format
      return DateTime.tryParse(date) ?? DateTime.now();
    }
    
    return DateTime.now();
  }

  EPGProgram copyWith({
    String? channelId,
    String? title,
    DateTime? startTime,
    DateTime? endTime,
    String? description,
    String? category,
    String? iconUrl,
    String? episodeNumber,
    String? seasonNumber,
  }) {
    return EPGProgram(
      channelId: channelId ?? this.channelId,
      title: title ?? this.title,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      description: description ?? this.description,
      category: category ?? this.category,
      iconUrl: iconUrl ?? this.iconUrl,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      seasonNumber: seasonNumber ?? this.seasonNumber,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'channelId': channelId,
      'title': title,
      'startTime': startTime.toIso8601String(),
      'endTime': endTime.toIso8601String(),
      'description': description,
      'category': category,
      'iconUrl': iconUrl,
      'episodeNumber': episodeNumber,
      'seasonNumber': seasonNumber,
    };
  }

  @override
  List<Object?> get props => [
        channelId,
        title,
        startTime,
        endTime,
        description,
        category,
        iconUrl,
        episodeNumber,
        seasonNumber,
      ];
}

