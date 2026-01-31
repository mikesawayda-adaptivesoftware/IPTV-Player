import 'package:equatable/equatable.dart';
import 'package:hive/hive.dart';

part 'vod_item.g.dart';

@HiveType(typeId: 1)
class VODItem extends Equatable {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final String streamUrl;

  @HiveField(3)
  final String? posterUrl;

  @HiveField(4)
  final String? plot;

  @HiveField(5)
  final String? year;

  @HiveField(6)
  final String? categoryId;

  @HiveField(7)
  final String? categoryName;

  @HiveField(8)
  final double? rating;

  @HiveField(9)
  final String? duration;

  @HiveField(10)
  final String? genre;

  @HiveField(11)
  final String? director;

  @HiveField(12)
  final String? cast;

  @HiveField(13)
  final bool isFavorite;

  @HiveField(14)
  final DateTime? lastWatched;

  @HiveField(15)
  final Duration? watchProgress;

  @HiveField(16)
  final bool isSeries;

  @HiveField(17)
  final int? seriesId;

  @HiveField(18)
  final int? seasonNumber;

  @HiveField(19)
  final int? episodeNumber;

  const VODItem({
    required this.id,
    required this.name,
    required this.streamUrl,
    this.posterUrl,
    this.plot,
    this.year,
    this.categoryId,
    this.categoryName,
    this.rating,
    this.duration,
    this.genre,
    this.director,
    this.cast,
    this.isFavorite = false,
    this.lastWatched,
    this.watchProgress,
    this.isSeries = false,
    this.seriesId,
    this.seasonNumber,
    this.episodeNumber,
  });

  VODItem copyWith({
    String? id,
    String? name,
    String? streamUrl,
    String? posterUrl,
    String? plot,
    String? year,
    String? categoryId,
    String? categoryName,
    double? rating,
    String? duration,
    String? genre,
    String? director,
    String? cast,
    bool? isFavorite,
    DateTime? lastWatched,
    Duration? watchProgress,
    bool? isSeries,
    int? seriesId,
    int? seasonNumber,
    int? episodeNumber,
  }) {
    return VODItem(
      id: id ?? this.id,
      name: name ?? this.name,
      streamUrl: streamUrl ?? this.streamUrl,
      posterUrl: posterUrl ?? this.posterUrl,
      plot: plot ?? this.plot,
      year: year ?? this.year,
      categoryId: categoryId ?? this.categoryId,
      categoryName: categoryName ?? this.categoryName,
      rating: rating ?? this.rating,
      duration: duration ?? this.duration,
      genre: genre ?? this.genre,
      director: director ?? this.director,
      cast: cast ?? this.cast,
      isFavorite: isFavorite ?? this.isFavorite,
      lastWatched: lastWatched ?? this.lastWatched,
      watchProgress: watchProgress ?? this.watchProgress,
      isSeries: isSeries ?? this.isSeries,
      seriesId: seriesId ?? this.seriesId,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
    );
  }

  /// Create from Xtream Codes VOD API response
  factory VODItem.fromXtreamVod(Map<String, dynamic> json, String baseUrl, String username, String password) {
    final streamId = json['stream_id'];
    final extension = json['container_extension'] ?? 'mp4';
    
    return VODItem(
      id: streamId.toString(),
      name: json['name'] ?? 'Unknown',
      streamUrl: '$baseUrl/movie/$username/$password/$streamId.$extension',
      posterUrl: json['stream_icon'] ?? json['cover_big'],
      plot: json['plot'],
      year: json['year']?.toString(),
      categoryId: json['category_id']?.toString(),
      categoryName: json['category_name'],
      rating: _parseRating(json['rating']),
      duration: json['duration'],
      genre: json['genre'],
      director: json['director'],
      cast: json['cast'],
    );
  }

  /// Create from Xtream Codes Series episode
  factory VODItem.fromXtreamEpisode(
    Map<String, dynamic> json,
    String baseUrl,
    String username,
    String password,
    int seriesId,
    String seriesName,
    int seasonNumber,
  ) {
    final episodeId = json['id'];
    final extension = json['container_extension'] ?? 'mp4';
    
    return VODItem(
      id: episodeId.toString(),
      name: json['title'] ?? 'Episode ${json['episode_num']}',
      streamUrl: '$baseUrl/series/$username/$password/$episodeId.$extension',
      posterUrl: json['info']?['movie_image'],
      plot: json['info']?['plot'],
      duration: json['info']?['duration'],
      isSeries: true,
      seriesId: seriesId,
      seasonNumber: seasonNumber,
      episodeNumber: int.tryParse(json['episode_num']?.toString() ?? ''),
    );
  }

  static double? _parseRating(dynamic rating) {
    if (rating == null) return null;
    if (rating is double) return rating;
    if (rating is int) return rating.toDouble();
    if (rating is String) return double.tryParse(rating);
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'streamUrl': streamUrl,
      'posterUrl': posterUrl,
      'plot': plot,
      'year': year,
      'categoryId': categoryId,
      'categoryName': categoryName,
      'rating': rating,
      'duration': duration,
      'genre': genre,
      'director': director,
      'cast': cast,
      'isFavorite': isFavorite,
      'lastWatched': lastWatched?.toIso8601String(),
      'watchProgress': watchProgress?.inSeconds,
      'isSeries': isSeries,
      'seriesId': seriesId,
      'seasonNumber': seasonNumber,
      'episodeNumber': episodeNumber,
    };
  }

  @override
  List<Object?> get props => [
        id,
        name,
        streamUrl,
        posterUrl,
        plot,
        year,
        categoryId,
        categoryName,
        rating,
        duration,
        genre,
        director,
        cast,
        isFavorite,
        lastWatched,
        watchProgress,
        isSeries,
        seriesId,
        seasonNumber,
        episodeNumber,
      ];
}

