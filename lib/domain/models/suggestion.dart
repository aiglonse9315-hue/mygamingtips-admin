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
  });

  factory AiRecommendation.fromJson(Map<String, dynamic> json) {
    return AiRecommendation(
      verdict: AiVerdict.values.firstWhere(
        (e) => e.name == (json['verdict'] as String? ?? 'caution'),
        orElse: () => AiVerdict.caution,
      ),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      reason: json['reason'] as String? ?? '',
      suggestedGame: json['suggested_game'] as String?,
      suggestedCategory: json['suggested_category'] as String?,
      youtubeViews: json['youtube_views'] as int?,
      youtubeLikes: json['youtube_likes'] as int?,
      youtubeTitle: json['youtube_title'] as String?,
      youtubePublishedAt:
          DateTime.tryParse(json['youtube_published_at'] as String? ?? ''),
      analyzedAt: DateTime.tryParse(json['analyzed_at'] as String? ?? ''),
    );
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
      };
}
