import 'package:equatable/equatable.dart';

class ServerInfo extends Equatable {
  final String url;
  final int port;
  final String httpsPort;
  final String serverProtocol;
  final String rtmpPort;
  final String timezone;
  final DateTime? timestampNow;
  final DateTime? expDate;
  final bool isActive;
  final String? message;

  const ServerInfo({
    required this.url,
    required this.port,
    required this.httpsPort,
    required this.serverProtocol,
    required this.rtmpPort,
    required this.timezone,
    this.timestampNow,
    this.expDate,
    required this.isActive,
    this.message,
  });

  /// Create from Xtream Codes API server_info response
  factory ServerInfo.fromXtream(Map<String, dynamic> json) {
    final serverInfo = json['server_info'] ?? json;
    final userInfo = json['user_info'] ?? {};

    return ServerInfo(
      url: serverInfo['url'] ?? '',
      port: _parseInt(serverInfo['port']) ?? 80,
      httpsPort: serverInfo['https_port']?.toString() ?? '',
      serverProtocol: serverInfo['server_protocol'] ?? 'http',
      rtmpPort: serverInfo['rtmp_port']?.toString() ?? '',
      timezone: serverInfo['timezone'] ?? 'UTC',
      timestampNow: _parseTimestamp(serverInfo['time_now'] ?? serverInfo['timestamp_now']),
      expDate: _parseTimestamp(userInfo['exp_date']),
      isActive: userInfo['status'] == 'Active' || userInfo['auth'] == 1,
      message: userInfo['message']?.toString(),
    );
  }

  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  static DateTime? _parseTimestamp(dynamic timestamp) {
    if (timestamp == null) return null;
    
    if (timestamp is int) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    }
    
    if (timestamp is String) {
      final intVal = int.tryParse(timestamp);
      if (intVal != null) {
        return DateTime.fromMillisecondsSinceEpoch(intVal * 1000);
      }
      return DateTime.tryParse(timestamp);
    }
    
    return null;
  }

  /// Check if subscription is expired
  bool get isExpired {
    if (expDate == null) return false;
    return DateTime.now().isAfter(expDate!);
  }

  /// Get days remaining until expiration
  int? get daysRemaining {
    if (expDate == null) return null;
    final remaining = expDate!.difference(DateTime.now()).inDays;
    return remaining > 0 ? remaining : 0;
  }

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'port': port,
      'httpsPort': httpsPort,
      'serverProtocol': serverProtocol,
      'rtmpPort': rtmpPort,
      'timezone': timezone,
      'timestampNow': timestampNow?.toIso8601String(),
      'expDate': expDate?.toIso8601String(),
      'isActive': isActive,
      'message': message,
    };
  }

  @override
  List<Object?> get props => [
        url,
        port,
        httpsPort,
        serverProtocol,
        rtmpPort,
        timezone,
        timestampNow,
        expDate,
        isActive,
        message,
      ];
}

