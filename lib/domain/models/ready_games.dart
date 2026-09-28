// Pur (VM) — « Activer les jeux prêts » (route EF `games/activate-ready`,
// migration 0095 : aperçu `admin_games_ready_preview` M95:36-68, application
// `admin_games_activate_ready` M95:73-145). P4b-3, lot L2.
//
// Lecture JSON tolérante (entier = `v is num`, texte = `v is String`) ; un
// jeu sans `id` texte non vide est ignoré.
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM.
import 'package:flutter/foundation.dart';

int? _int(Object? v) => v is num ? v.toInt() : null;

String? _id(Object? v) => v is String && v.isNotEmpty ? v : null;

/// Jeu INACTIF ayant au moins le seuil de contenus validés (aperçu).
@immutable
class ReadyGame {
  const ReadyGame({
    required this.id,
    required this.name,
    required this.validatedTotal,
    this.video = 0,
    this.guides = 0,
    this.links = 0,
    required this.distinctUrls,
    this.updatedAt,
  });

  final String id;
  final String name;
  final int validatedTotal;
  final int video;
  final int guides;
  final int links;
  final int distinctUrls;
  final DateTime? updatedAt;

  /// Des contenus validés partagent la même URL (doublons à vérifier).
  bool get hasDuplicateUrls => distinctUrls < validatedTotal;

  static ReadyGame? fromJson(Object? j) {
    if (j is! Map) return null;
    final String? id = _id(j['id']);
    if (id == null) return null;
    final int total = _int(j['validated_total']) ?? 0;
    final Object? name = j['name'];
    final Object? updated = j['updated_at'];
    return ReadyGame(
      id: id,
      name: name is String ? name : '',
      validatedTotal: total,
      video: _int(j['video']) ?? 0,
      guides: _int(j['guides']) ?? 0,
      links: _int(j['links']) ?? 0,
      // Absent → pas de doublon supposé.
      distinctUrls: _int(j['distinct_urls']) ?? total,
      updatedAt: updated is String ? DateTime.tryParse(updated) : null,
    );
  }
}

/// Aperçu (NON borné côté serveur) : seuil, nombre de jeux inactifs, nombre
/// de jeux prêts et leur liste (tri : contenus validés décroissants, nom).
@immutable
class ReadyGamesPreview {
  const ReadyGamesPreview({
    required this.threshold,
    required this.inactiveTotal,
    required this.count,
    required this.games,
  });

  final int threshold;
  final int inactiveTotal;
  final int count;
  final List<ReadyGame> games;

  /// `null` si [j] n'est pas un objet ou n'a pas de liste `games` (réponse
  /// illisible : jamais un aperçu vide supposé).
  static ReadyGamesPreview? fromJson(Object? j) {
    if (j is! Map) return null;
    final Object? raw = j['games'];
    if (raw is! List) return null;
    final List<ReadyGame> games = raw
        .map(ReadyGame.fromJson)
        .whereType<ReadyGame>()
        .toList(growable: false);
    return ReadyGamesPreview(
      threshold: _int(j['threshold']) ?? 10,
      inactiveTotal: _int(j['inactive_total']) ?? 0,
      count: _int(j['count']) ?? games.length,
      games: games,
    );
  }
}

/// Jeu activé par l'application.
@immutable
class ActivatedGame {
  const ActivatedGame({
    required this.id,
    required this.name,
    required this.validatedTotal,
  });

  final String id;
  final String name;
  final int validatedTotal;

  static ActivatedGame? fromJson(Object? j) {
    if (j is! Map) return null;
    final String? id = _id(j['id']);
    if (id == null) return null;
    final Object? name = j['name'];
    return ActivatedGame(
      id: id,
      name: name is String ? name : '',
      validatedTotal: _int(j['validated_total']) ?? 0,
    );
  }
}

/// Jeu demandé mais non activé : `already_active` | `below_threshold` |
/// `not_found`.
@immutable
class SkippedGame {
  const SkippedGame({required this.id, required this.reason});

  final String id;
  final String reason;

  static SkippedGame? fromJson(Object? j) {
    if (j is! Map) return null;
    final String? id = _id(j['id']);
    if (id == null) return null;
    final Object? reason = j['reason'];
    return SkippedGame(id: id, reason: reason is String ? reason : '');
  }
}

/// Bilan de l'activation `{threshold, requested, activated[], skipped[]}` +
/// rejeu.
@immutable
class ActivateReadyResult {
  const ActivateReadyResult({
    required this.threshold,
    required this.requested,
    required this.activated,
    required this.skipped,
    this.replayed = false,
  });

  final int threshold;
  final int requested;
  final List<ActivatedGame> activated;
  final List<SkippedGame> skipped;

  /// Réponse obtenue après un REJEU (la 1re réponse a été perdue : les jeux
  /// ont pu être activés au premier essai, ils apparaissent alors ignorés
  /// `already_active`).
  final bool replayed;

  /// `null` si [j] n'est pas un objet ou si `activated` / `skipped` ne sont
  /// pas des listes (réponse illisible).
  static ActivateReadyResult? fromJson(Object? j, {bool replayed = false}) {
    if (j is! Map) return null;
    final Object? act = j['activated'];
    final Object? skip = j['skipped'];
    if (act is! List || skip is! List) return null;
    final List<ActivatedGame> activated = act
        .map(ActivatedGame.fromJson)
        .whereType<ActivatedGame>()
        .toList(growable: false);
    final List<SkippedGame> skipped = skip
        .map(SkippedGame.fromJson)
        .whereType<SkippedGame>()
        .toList(growable: false);
    return ActivateReadyResult(
      threshold: _int(j['threshold']) ?? 10,
      requested: _int(j['requested']) ?? (activated.length + skipped.length),
      activated: activated,
      skipped: skipped,
      replayed: replayed,
    );
  }
}
