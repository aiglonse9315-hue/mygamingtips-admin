import 'package:flutter/foundation.dart';

import 'category.dart';

/// Un contenu (vidéo / guide / lien) rattaché à un jeu (version admin,
/// sérialisable JSON).
@immutable
class Content {
  final String id;
  final String gameId;
  final ContentCategory category;
  final String url;
  final String? titleSource;
  final String? titleAdmin;
  final String? imageUrl;
  final DateTime publishedAt;
  final bool validated;
  final bool isVideo;

  const Content({
    required this.id,
    required this.gameId,
    required this.category,
    required this.url,
    this.titleSource,
    this.titleAdmin,
    this.imageUrl,
    required this.publishedAt,
    this.validated = true,
    this.isVideo = false,
  });

  factory Content.fromJson(Map<String, dynamic> json) {
    return Content(
      id: json['id'] as String,
      gameId: json['gameId'] as String,
      category: ContentCategory.values.firstWhere(
        (e) => e.name == json['category'],
        orElse: () => ContentCategory.links,
      ),
      url: json['url'] as String,
      titleSource: json['titleSource'] as String?,
      titleAdmin: json['titleAdmin'] as String?,
      imageUrl: json['imageUrl'] as String?,
      publishedAt:
          DateTime.tryParse(json['publishedAt'] as String? ?? '') ??
              DateTime.now(),
      validated: (json['validated'] as bool?) ?? true,
      isVideo: (json['isVideo'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'gameId': gameId,
        'category': category.name,
        'url': url,
        'titleSource': titleSource,
        'titleAdmin': titleAdmin,
        'imageUrl': imageUrl,
        'publishedAt': publishedAt.toIso8601String(),
        'validated': validated,
        'isVideo': isVideo,
      };

  /// Titre affiché : admin en priorité, sinon source, sinon URL.
  String get displayTitle => (titleAdmin?.trim().isNotEmpty ?? false)
      ? titleAdmin!.trim()
      : (titleSource?.trim().isNotEmpty ?? false)
          ? titleSource!.trim()
          : url;

  Content copyWith({
    ValueGetter<String?>? titleAdmin,
    ValueGetter<String?>? imageUrl,
    bool? validated,
  }) {
    return Content(
      id: id,
      gameId: gameId,
      category: category,
      url: url,
      titleSource: titleSource,
      titleAdmin: titleAdmin != null ? titleAdmin() : this.titleAdmin,
      imageUrl: imageUrl != null ? imageUrl() : this.imageUrl,
      publishedAt: publishedAt,
      validated: validated ?? this.validated,
      isVideo: isVideo,
    );
  }

  @override
  bool operator ==(Object other) => other is Content && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
