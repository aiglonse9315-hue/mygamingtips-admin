import 'package:flutter/foundation.dart';

import 'suggestion_author.dart';

/// Statut de modération d'une suggestion utilisateur.
enum SuggestionStatus {
  pending,
  accepted,
  rejected;

  String get label {
    switch (this) {
      case SuggestionStatus.pending:
        return 'En attente';
      case SuggestionStatus.accepted:
        return 'Acceptée';
      case SuggestionStatus.rejected:
        return 'Refusée';
    }
  }
}

/// Une suggestion utilisateur partagée depuis l'app mobile, à modérer
/// par l'administrateur (version admin, sérialisable JSON).
///
/// [author] identifie le compte Google à l'origine de la suggestion : permet
/// à l'admin de consulter l'identité de l'auteur et de le bannir si besoin.
///
/// [aiRecommendation] contient le verdict de l'IA Sentinelle (nullable tant
/// que la suggestion n'a pas été analysée).
@immutable
class Suggestion {
  final String id;
  final String url;
  final String? sharedText;
  final SuggestionStatus status;
  final DateTime sharedAt;
  final SuggestionAuthor author;
  final AiRecommendation? aiRecommendation;
  final DateTime? sentinelleStartedAt;

  const Suggestion({
    required this.id,
    required this.url,
    this.sharedText,
    required this.status,
    required this.sharedAt,
    required this.author,
    this.aiRecommendation,
    this.sentinelleStartedAt,
  });

  factory Suggestion.fromJson(Map<String, dynamic> json) {
    return Suggestion(
      id: json['id'] as String,
      url: json['url'] as String,
      sharedText: json['sharedText'] as String?,
      status: SuggestionStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => SuggestionStatus.pending,
      ),
      sharedAt: DateTime.tryParse(json['sharedAt'] as String? ?? '') ??
          DateTime.now(),
      author: SuggestionAuthor.fromJson(
          json['author'] as Map<String, dynamic>),
      aiRecommendation: json['aiRecommendation'] != null
          ? AiRecommendation.fromJson(
              json['aiRecommendation'] as Map<String, dynamic>)
          : null,
      sentinelleStartedAt: DateTime.tryParse(
          json['sentinelleStartedAt'] as String? ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'sharedText': sharedText,
        'status': status.name,
        'sharedAt': sharedAt.toIso8601String(),
        'author': author.toJson(),
        if (aiRecommendation != null) 'aiRecommendation': aiRecommendation!.toJson(),
      };

  Suggestion copyWith({SuggestionStatus? status}) {
    return Suggestion(
      id: id,
      url: url,
      sharedText: sharedText,
      status: status ?? this.status,
      sharedAt: sharedAt,
      author: author,
      aiRecommendation: aiRecommendation,
    );
  }

  @override
  bool operator ==(Object other) => other is Suggestion && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Verdict possible de l'IA Sentinelle.
enum AiVerdict {
  recommended,
  caution,
  reject;

  String get label {
    switch (this) {
      case AiVerdict.recommended:
        return 'Recommandé';
      case AiVerdict.caution:
        return 'À vérifier';
      case AiVerdict.reject:
        return 'Risqué';
    }
  }
}

/// Alias candidat proposé par l'assistant de rattachement D3.1 (Hermes
/// borné) quand un contenu hors catalogue a été rattaché à un jeu existant
/// sous un nom NOUVEAU (abréviation, acronyme, nom de DLC...). Affiché dans
/// le panneau Sentinelle avec une case cochée par défaut : à la validation,
/// l'alias est ajouté à la base (décochable → jamais créé).
@immutable
class AiAliasCandidate {
  /// Alias proposé (= le nom de jeu suggéré d'origine par le 1er LLM, avant
  /// rattachement assisté — ex. « SF: Shattered Space »).
  final String alias;

  /// Nom canonique du jeu du catalogue auquel l'alias serait rattaché.
  final String game;

  const AiAliasCandidate({required this.alias, required this.game});

  factory AiAliasCandidate.fromJson(Map<String, dynamic> json) {
    return AiAliasCandidate(
      alias: json['alias']?.toString() ?? '',
      game: json['game']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'alias': alias, 'game': game};
}

/// Recommandation de l'IA Sentinelle sur une suggestion.
///
/// L'IA analyse l'URL, la pertinence gaming, le contenu inapproprié, et les
/// vues YouTube. Elle propose aussi un jeu et une catégorie. **L'IA ne valide
/// jamais seule** : c'est l'admin qui décide.
@immutable
class AiRecommendation {
  final AiVerdict verdict;
  final double confidence;
  final String reason;
  final String? suggestedGame;
  final String? suggestedCategory;
  final int? youtubeViews;
  final int? youtubeLikes;
  final String? youtubeTitle;
  final DateTime? youtubePublishedAt;
  final DateTime? analyzedAt;

  /// Vrai quand Sentinelle a détecté que le jeu suggéré n'existe pas dans la
  /// base mais que la vidéo est un tuto/guide valide. L'admin peut créer le
  /// jeu depuis le tableau « Jeux à créer ».
  final bool needsGameCreation;

  /// Code langue YouTube détecté par Sentinelle (ex : 'FR', 'EN', 'JA').
  /// Utilisé pour appliquer un seuil de confiance plus strict (0.95) aux
  /// langues non natives (tout sauf FR/EN), conformément à la demande
  /// utilisateur : seules les suggestions > 95% sont auto-acceptées pour
  /// les autres langues du pack 12.
  final String? youtubeLanguage;

  /// D3.2 — alias candidat proposé par l'assistant de rattachement borné
  /// (clé `alias_candidate` du jsonb ai_recommendation, fusionné par l'EF —
  /// aucune migration). Null quand le contenu a été rattaché trivialement ou
  /// n'a pas pu être rattaché.
  final AiAliasCandidate? aliasCandidate;

  /// §119 — jeu que Vision CHERCHAIT quand il a trouvé ce contenu (clés
  /// `target_game`, `search_language`, `found_via` écrites à l'insertion) :
  /// repère les recherches qui ramènent du hors-sujet. Null = inconnu
  /// (contenus d'avant §119, liens du Scruteur, suggestions des joueurs).
  final String? targetGame;
  final String? searchLanguage;

  /// 'search' (recherche générique) | 'trusted_channel' (chaîne de confiance).
  final String? foundVia;

  const AiRecommendation({
    required this.verdict,
    required this.confidence,
    required this.reason,
    this.suggestedGame,
    this.suggestedCategory,
    this.youtubeViews,
    this.youtubeLikes,
    this.youtubeTitle,
    this.youtubePublishedAt,
    this.analyzedAt,
    this.needsGameCreation = false,
    this.youtubeLanguage,
    this.aliasCandidate,
    this.targetGame,
    this.searchLanguage,
    this.foundVia,
  });

  /// « 🔎 Vision cherchait : Raft · RU » (+ « · chaîne de confiance »), null
  /// si le jeu cherché est inconnu.
  String? get visionSearchLabel {
    final game = targetGame?.trim();
    if (game == null || game.isEmpty) return null;
    return '🔎 Vision cherchait : ${[
      game,
      ?searchLanguage,
      if (foundVia == 'trusted_channel') 'chaîne de confiance',
    ].join(' · ')}';
  }

  factory AiRecommendation.fromJson(Map<String, dynamic> json) {
    return AiRecommendation(
      verdict: AiVerdict.values.firstWhere(
        (e) => e.name == (json['verdict'] as String? ?? 'caution'),
        orElse: () => AiVerdict.caution,
      ),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      // Chantier B (fix revue I-001) : les suggestions purgées au ban portent
      // leur motif dans `reject_reason` SANS clé `reason` ni verdict IA —
      // fallback pour que le board « Refusées » affiche le vrai motif au lieu
      // d'un tooltip vide. `reason` reste prioritaire quand il existe.
      reason: _parseReason(json),
      suggestedGame: json['suggested_game'] as String?,
      suggestedCategory: json['suggested_category'] as String?,
      youtubeViews: json['youtube_views'] as int?,
      youtubeLikes: json['youtube_likes'] as int?,
      youtubeTitle: json['youtube_title'] as String?,
      youtubePublishedAt:
          DateTime.tryParse(json['youtube_published_at'] as String? ?? ''),
      analyzedAt: DateTime.tryParse(json['analyzed_at'] as String? ?? ''),
      needsGameCreation: json['needs_game_creation'] as bool? ?? false,
      // Langue détectée : Sentinelle utilise 'youtube_language', le Scruteur
      // utilise 'detected_language'. On lit les deux (youtube prioritaire)
      // pour qu'un même champ serve au seuil de confiance et à video_language.
      youtubeLanguage:
          (json['youtube_language'] as String?) ?? (json['detected_language'] as String?),
      // D3.2 — alias candidat (rattachement assisté) : lu depuis la clé
      // `alias_candidate` du jsonb. Entrées vides → null (défensif).
      aliasCandidate: _parseAliasCandidate(json['alias_candidate']),
      targetGame: json['target_game'] as String?,
      searchLanguage: json['search_language'] as String?,
      foundVia: json['found_via'] as String?,
    );
  }

  /// Motif affiché : `reason` (analyse Sentinelle) en priorité ; à défaut
  /// `reject_reason` (purge au ban, chantier B — pas de verdict IA). Jamais
  /// null : chaîne vide si les deux clés sont absentes/vides.
  static String _parseReason(Map<String, dynamic> json) {
    final reason = json['reason'] as String?;
    if (reason != null && reason.isNotEmpty) return reason;
    return json['reject_reason'] as String? ?? '';
  }

  /// Parse défensif de la clé `alias_candidate` du jsonb ai_recommendation :
  /// null si absente, mal formée, ou avec alias/game vides.
  static AiAliasCandidate? _parseAliasCandidate(Object? raw) {
    if (raw is! Map) return null;
    final candidate =
        AiAliasCandidate.fromJson(Map<String, dynamic>.from(raw));
    if (candidate.alias.isEmpty || candidate.game.isEmpty) return null;
    return candidate;
  }

  Map<String, dynamic> toJson() => {
        'verdict': verdict.name,
        'confidence': confidence,
        'reason': reason,
        if (suggestedGame != null) 'suggested_game': suggestedGame,
        if (suggestedCategory != null) 'suggested_category': suggestedCategory,
        if (youtubeViews != null) 'youtube_views': youtubeViews,
        if (youtubeLikes != null) 'youtube_likes': youtubeLikes,
        if (youtubeTitle != null) 'youtube_title': youtubeTitle,
        if (youtubePublishedAt != null)
          'youtube_published_at': youtubePublishedAt!.toIso8601String(),
        if (analyzedAt != null) 'analyzed_at': analyzedAt!.toIso8601String(),
        if (needsGameCreation) 'needs_game_creation': true,
        if (youtubeLanguage != null) 'youtube_language': youtubeLanguage,
        if (aliasCandidate != null) 'alias_candidate': aliasCandidate!.toJson(),
        'target_game': ?targetGame,
        'search_language': ?searchLanguage,
        'found_via': ?foundVia,
      };
}
