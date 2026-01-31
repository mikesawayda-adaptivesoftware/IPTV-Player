import 'package:equatable/equatable.dart';
import 'package:hive/hive.dart';

part 'channel.g.dart';

@HiveType(typeId: 0)
class Channel extends Equatable {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final String streamUrl;

  @HiveField(3)
  final String? logoUrl;

  @HiveField(4)
  final String? groupTitle;

  @HiveField(5)
  final String? epgChannelId;

  @HiveField(6)
  final int? streamId;

  @HiveField(7)
  final String? categoryId;

  @HiveField(8)
  final bool isFavorite;

  @HiveField(9)
  final DateTime? lastWatched;

  const Channel({
    required this.id,
    required this.name,
    required this.streamUrl,
    this.logoUrl,
    this.groupTitle,
    this.epgChannelId,
    this.streamId,
    this.categoryId,
    this.isFavorite = false,
    this.lastWatched,
  });

  Channel copyWith({
    String? id,
    String? name,
    String? streamUrl,
    String? logoUrl,
    String? groupTitle,
    String? epgChannelId,
    int? streamId,
    String? categoryId,
    bool? isFavorite,
    DateTime? lastWatched,
  }) {
    return Channel(
      id: id ?? this.id,
      name: name ?? this.name,
      streamUrl: streamUrl ?? this.streamUrl,
      logoUrl: logoUrl ?? this.logoUrl,
      groupTitle: groupTitle ?? this.groupTitle,
      epgChannelId: epgChannelId ?? this.epgChannelId,
      streamId: streamId ?? this.streamId,
      categoryId: categoryId ?? this.categoryId,
      isFavorite: isFavorite ?? this.isFavorite,
      lastWatched: lastWatched ?? this.lastWatched,
    );
  }

  /// Create from M3U EXTINF metadata
  factory Channel.fromM3U({
    required String id,
    required String name,
    required String streamUrl,
    Map<String, String>? attributes,
  }) {
    return Channel(
      id: id,
      name: name,
      streamUrl: streamUrl,
      logoUrl: attributes?['tvg-logo'] ?? attributes?['logo'],
      groupTitle: attributes?['group-title'],
      epgChannelId: attributes?['tvg-id'],
    );
  }

  /// Create from Xtream Codes API response
  factory Channel.fromXtream(Map<String, dynamic> json, String baseUrl, String username, String password) {
    final streamId = json['stream_id'];
    final extension = json['container_extension'] ?? 'ts';
    
    return Channel(
      id: streamId.toString(),
      name: json['name'] ?? 'Unknown',
      streamUrl: '$baseUrl/live/$username/$password/$streamId.$extension',
      logoUrl: json['stream_icon'],
      groupTitle: json['category_name'],
      epgChannelId: json['epg_channel_id'],
      streamId: streamId is int ? streamId : int.tryParse(streamId.toString()),
      categoryId: json['category_id']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'streamUrl': streamUrl,
      'logoUrl': logoUrl,
      'groupTitle': groupTitle,
      'epgChannelId': epgChannelId,
      'streamId': streamId,
      'categoryId': categoryId,
      'isFavorite': isFavorite,
      'lastWatched': lastWatched?.toIso8601String(),
    };
  }

  @override
  List<Object?> get props => [id, name, streamUrl, logoUrl, groupTitle, epgChannelId, streamId, categoryId, isFavorite, lastWatched];
}

