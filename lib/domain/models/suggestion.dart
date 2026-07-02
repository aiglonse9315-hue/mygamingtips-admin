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
@immutable
class Suggestion {
  final String id;
  final String url;
  final String? sharedText;
  final SuggestionStatus status;
  final DateTime sharedAt;
  final SuggestionAuthor author;

  const Suggestion({
    required this.id,
    required this.url,
    this.sharedText,
    required this.status,
    required this.sharedAt,
    required this.author,
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
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'sharedText': sharedText,
        'status': status.name,
        'sharedAt': sharedAt.toIso8601String(),
        'author': author.toJson(),
      };

  Suggestion copyWith({SuggestionStatus? status}) {
    return Suggestion(
      id: id,
      url: url,
      sharedText: sharedText,
      status: status ?? this.status,
      sharedAt: sharedAt,
      author: author,
    );
  }

  @override
  bool operator ==(Object other) => other is Suggestion && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
