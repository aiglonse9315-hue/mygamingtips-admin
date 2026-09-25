import 'package:flutter/foundation.dart';

/// Profil de l'auteur d'une suggestion (côté admin), sérialisable JSON.
///
/// Permet à l'administrateur d'identifier le compte Google à l'origine d'une
/// suggestion, pour la modération et le bannissement éventuel.
@immutable
class SuggestionAuthor {
  final String id;
  final String displayName;
  final String? avatarUrl;
  final String? email;

  /// Auteur abonné Plus ACTIF au moment de la lecture (`author_is_plus` de la
  /// route EF `suggestions/list`, migration 0085) — badge PLUS et bouton
  /// « Plus » sans charger la liste complète des abonnés.
  final bool isPlus;

  const SuggestionAuthor({
    required this.id,
    required this.displayName,
    this.avatarUrl,
    this.email,
    this.isPlus = false,
  });

  factory SuggestionAuthor.fromJson(Map<String, dynamic> json) {
    return SuggestionAuthor(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      avatarUrl: json['avatarUrl'] as String?,
      email: json['email'] as String?,
      isPlus: (json['isPlus'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'avatarUrl': avatarUrl,
        'email': email,
        'isPlus': isPlus,
      };

  SuggestionAuthor copyWith({bool? banned}) => this; // pour compat future

  @override
  bool operator ==(Object other) =>
      other is SuggestionAuthor && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
