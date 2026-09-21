import 'package:flutter/foundation.dart';

/// Un jeu du catalogue (version admin, sérialisable JSON).
@immutable
class Game {
  final String id;
  final String name;
  final String? coverUrl;
  final String? publisher;
  final bool active;
  final DateTime createdAt;

  /// Date de sortie officielle du jeu (optionnelle, format ISO `yyyy-MM-dd`
  /// — colonne `games.release_date`, migration 0071 / chantier §98).
  /// Aide les bots à différencier les éditions homonymes (CoD MW3 2011 vs
  /// MW III 2023) : une vidéo publiée avant appartient à l'édition
  /// antérieure. null = non renseignée (comportement historique).
  final String? releaseDate;

  /// Traductions du titre du jeu, chargées à la demande depuis la table
  /// `game_translations` (route `games/translations-list`).
  ///
  /// **Pas peuplé au chargement normal** : la colonne n'existe pas dans la
  /// table `games`, et le SELECT principal ne fait pas de JOIN. Ce champ
  /// reste `null` sauf si l'UI le remplit explicitement (dialog de
  /// traductions). Ne JAMAIS l'inclure dans [toJson] (pas de colonne
  /// correspondante dans `games`).
  final Map<String, String>? nameTranslations;

  const Game({
    required this.id,
    required this.name,
    this.coverUrl,
    this.publisher,
    this.active = true,
    required this.createdAt,
    this.nameTranslations,
    this.releaseDate,
  });

  factory Game.fromJson(Map<String, dynamic> json) {
    // Les traductions peuvent arriver via un JOIN optionnel (clé
    // `name_translations`). Si la valeur n'est pas un Map, on laisse null
    // (chargement normal sans traductions).
    final rawTranslations = json['name_translations'];
    Map<String, String>? translations;
    if (rawTranslations is Map) {
      translations = {
        for (final entry in rawTranslations.entries)
          if (entry.value is String) entry.key as String: entry.value as String,
      };
    }
    return Game(
      id: json['id'] as String,
      name: json['name'] as String,
      coverUrl: json['coverUrl'] as String?,
      publisher: json['publisher'] as String?,
      active: (json['active'] as bool?) ?? true,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      nameTranslations: translations,
      releaseDate: (json['releaseDate'] as String?)?.isNotEmpty == true
          ? json['releaseDate'] as String?
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'coverUrl': coverUrl,
        'publisher': publisher,
        'active': active,
        'createdAt': createdAt.toIso8601String(),
        'releaseDate': releaseDate,
      };

  Game copyWith({
    String? name,
    ValueGetter<String?>? coverUrl,
    ValueGetter<String?>? publisher,
    bool? active,
    ValueGetter<Map<String, String>?>? nameTranslations,
    ValueGetter<String?>? releaseDate,
  }) {
    return Game(
      id: id,
      name: name ?? this.name,
      coverUrl: coverUrl != null ? coverUrl() : this.coverUrl,
      publisher: publisher != null ? publisher() : this.publisher,
      active: active ?? this.active,
      createdAt: createdAt,
      nameTranslations: nameTranslations != null
          ? nameTranslations()
          : this.nameTranslations,
      releaseDate: releaseDate != null ? releaseDate() : this.releaseDate,
    );
  }

  @override
  bool operator ==(Object other) => other is Game && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
