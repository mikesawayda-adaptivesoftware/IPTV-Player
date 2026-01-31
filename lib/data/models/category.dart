import 'package:equatable/equatable.dart';

class Category extends Equatable {
  final String id;
  final String name;
  final int? channelCount;
  final String? parentId;

  const Category({
    required this.id,
    required this.name,
    this.channelCount,
    this.parentId,
  });

  /// Create from Xtream Codes API response
  factory Category.fromXtream(Map<String, dynamic> json) {
    return Category(
      id: json['category_id']?.toString() ?? '',
      name: json['category_name'] ?? 'Unknown',
      parentId: json['parent_id']?.toString(),
    );
  }

  /// Create "All" category
  factory Category.all({int? count}) {
    return Category(
      id: 'all',
      name: 'All Channels',
      channelCount: count,
    );
  }

  /// Create "Favorites" category
  factory Category.favorites({int? count}) {
    return Category(
      id: 'favorites',
      name: 'Favorites',
      channelCount: count,
    );
  }

  /// Create "Recent" category
  factory Category.recent({int? count}) {
    return Category(
      id: 'recent',
      name: 'Recently Watched',
      channelCount: count,
    );
  }

  Category copyWith({
    String? id,
    String? name,
    int? channelCount,
    String? parentId,
  }) {
    return Category(
      id: id ?? this.id,
      name: name ?? this.name,
      channelCount: channelCount ?? this.channelCount,
      parentId: parentId ?? this.parentId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'channelCount': channelCount,
      'parentId': parentId,
    };
  }

  @override
  List<Object?> get props => [id, name, channelCount, parentId];
}

