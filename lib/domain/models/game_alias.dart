import 'package:flutter/foundation.dart';

/// Un alias de nom de jeu (table `game_aliases`), tel que retourné par la
/// route EF `games/aliases/list`.
///
/// Les alias (noms raccourcis, acronymes, noms communautaires — ex. « D4 »
/// pour Diablo 4) servent au matching des titres YouTube par Vision et
/// Sentinelle : c'est la forme NORMALISÉE ([aliasNorm]) qui est comparée.
@immutable
class GameAlias {
  const GameAlias({
    required this.id,
    required this.alias,
    required this.aliasNorm,
  });

  /// Identifiant de la ligne (UUID Supabase).
  final String id;

  /// Alias tel que saisi par l'admin (casse et accents conservés).
  final String alias;

  /// Forme normalisée utilisée pour le matching (minuscules, sans accents,
  /// chiffres romains convertis — même règle que GameMatcher.normalize).
  final String aliasNorm;

  factory GameAlias.fromJson(Map<String, dynamic> json) {
    return GameAlias(
      id: json['id']?.toString() ?? '',
      alias: json['alias']?.toString() ?? '',
      aliasNorm: json['alias_norm']?.toString() ?? '',
    );
  }
}
