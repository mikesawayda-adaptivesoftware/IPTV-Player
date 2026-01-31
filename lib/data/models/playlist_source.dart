import 'package:equatable/equatable.dart';
import 'package:hive/hive.dart';

part 'playlist_source.g.dart';

@HiveType(typeId: 2)
enum PlaylistType {
  @HiveField(0)
  m3u,
  
  @HiveField(1)
  xtream,
}

@HiveType(typeId: 3)
class PlaylistSource extends Equatable {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final PlaylistType type;

  /// For M3U: file path or URL
  /// For Xtream: base server URL
  @HiveField(3)
  final String url;

  /// Xtream username (null for M3U)
  @HiveField(4)
  final String? username;

  /// Xtream password (null for M3U)
  @HiveField(5)
  final String? password;

  /// EPG URL (optional)
  @HiveField(6)
  final String? epgUrl;

  @HiveField(7)
  final DateTime createdAt;

  @HiveField(8)
  final DateTime? lastUpdated;

  @HiveField(9)
  final bool isActive;

  const PlaylistSource({
    required this.id,
    required this.name,
    required this.type,
    required this.url,
    this.username,
    this.password,
    this.epgUrl,
    required this.createdAt,
    this.lastUpdated,
    this.isActive = true,
  });

  /// Create an M3U playlist source
  factory PlaylistSource.m3u({
    required String id,
    required String name,
    required String url,
    String? epgUrl,
  }) {
    return PlaylistSource(
      id: id,
      name: name,
      type: PlaylistType.m3u,
      url: url,
      epgUrl: epgUrl,
      createdAt: DateTime.now(),
    );
  }

  /// Create an Xtream Codes playlist source
  factory PlaylistSource.xtream({
    required String id,
    required String name,
    required String serverUrl,
    required String username,
    required String password,
  }) {
    // Ensure the URL doesn't end with a slash
    final cleanUrl = serverUrl.endsWith('/') 
        ? serverUrl.substring(0, serverUrl.length - 1) 
        : serverUrl;
    
    return PlaylistSource(
      id: id,
      name: name,
      type: PlaylistType.xtream,
      url: cleanUrl,
      username: username,
      password: password,
      createdAt: DateTime.now(),
    );
  }

  /// Get the full Xtream API URL
  String get xtreamApiUrl {
    if (type != PlaylistType.xtream) return '';
    return '$url/player_api.php?username=$username&password=$password';
  }

  /// Get the Xtream live stream base URL
  String get xtreamLiveUrl {
    if (type != PlaylistType.xtream) return '';
    return '$url/live/$username/$password';
  }

  /// Get the Xtream VOD stream base URL
  String get xtreamVodUrl {
    if (type != PlaylistType.xtream) return '';
    return '$url/movie/$username/$password';
  }

  /// Get the Xtream Series stream base URL
  String get xtreamSeriesUrl {
    if (type != PlaylistType.xtream) return '';
    return '$url/series/$username/$password';
  }

  /// Get the EPG URL for this playlist
  String? get effectiveEpgUrl {
    if (epgUrl != null && epgUrl!.isNotEmpty) return epgUrl;
    if (type == PlaylistType.xtream) {
      return '$url/xmltv.php?username=$username&password=$password';
    }
    return null;
  }

  PlaylistSource copyWith({
    String? id,
    String? name,
    PlaylistType? type,
    String? url,
    String? username,
    String? password,
    String? epgUrl,
    DateTime? createdAt,
    DateTime? lastUpdated,
    bool? isActive,
  }) {
    return PlaylistSource(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      epgUrl: epgUrl ?? this.epgUrl,
      createdAt: createdAt ?? this.createdAt,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      isActive: isActive ?? this.isActive,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'url': url,
      'username': username,
      'password': password,
      'epgUrl': epgUrl,
      'createdAt': createdAt.toIso8601String(),
      'lastUpdated': lastUpdated?.toIso8601String(),
      'isActive': isActive,
    };
  }

  @override
  List<Object?> get props => [
        id,
        name,
        type,
        url,
        username,
        password,
        epgUrl,
        createdAt,
        lastUpdated,
        isActive,
      ];
}

