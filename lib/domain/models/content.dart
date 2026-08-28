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
  final DateTime? createdAt; // date d'ajout dans la base
  final bool validated;
  final bool isVideo;
  final String? videoLanguage;
  final DateTime? checkedAt;
  /// Date(s) saisies manuellement par l'admin (migration 0053) — le bot
  /// Check ne recherche/corrige plus jamais la date de ce contenu.
  final bool manualDate;
  /// Check validé manuellement par l'admin (migration 0053) — le bot Check
  /// exclut ce contenu de toutes ses phases.
  final bool manualCheck;

  const Content({
    required this.id,
    required this.gameId,
    required this.category,
    required this.url,
    this.titleSource,
    this.titleAdmin,
    this.imageUrl,
    required this.publishedAt,
    this.createdAt,
    this.validated = true,
    this.isVideo = false,
    this.videoLanguage,
    this.checkedAt,
    this.manualDate = false,
    this.manualCheck = false,
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
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      validated: (json['validated'] as bool?) ?? true,
      isVideo: (json['isVideo'] as bool?) ?? false,
      videoLanguage: json['videoLanguage'] as String?,
      checkedAt: json['checkedAt'] != null
          ? DateTime.tryParse(json['checkedAt'] as String)
          : null,
      manualDate: (json['manualDate'] as bool?) ?? false,
      manualCheck: (json['manualCheck'] as bool?) ?? false,
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
        if (videoLanguage != null) 'videoLanguage': videoLanguage,
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
    ValueGetter<String?>? url,
    String? gameId,
    ContentCategory? category,
    DateTime? publishedAt,
    DateTime? createdAt,
    DateTime? checkedAt,
    bool? validated,
    bool? manualDate,
    bool? manualCheck,
    String? videoLanguage,
  }) {
    return Content(
      id: id,
      gameId: gameId ?? this.gameId,
      category: category ?? this.category,
      url: url != null ? url() ?? '' : this.url,
      titleSource: titleSource,
      titleAdmin: titleAdmin != null ? titleAdmin() : this.titleAdmin,
      imageUrl: imageUrl != null ? imageUrl() : this.imageUrl,
      publishedAt: publishedAt ?? this.publishedAt,
      // createdAt / checkedAt / flags manuels : préservés par défaut (le
      // copyWith les perdait avant — l'icône Checked repassait rouge après
      // chaque édition locale jusqu'au prochain resync).
      createdAt: createdAt ?? this.createdAt,
      checkedAt: checkedAt ?? this.checkedAt,
      validated: validated ?? this.validated,
      isVideo: category == ContentCategory.video ? true : (category == null ? isVideo : false),
      videoLanguage: videoLanguage ?? this.videoLanguage,
      manualDate: manualDate ?? this.manualDate,
      manualCheck: manualCheck ?? this.manualCheck,
    );
  }

  @override
  bool operator ==(Object other) => other is Content && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
