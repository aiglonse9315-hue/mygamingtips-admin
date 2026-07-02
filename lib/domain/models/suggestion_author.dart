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

  const SuggestionAuthor({
    required this.id,
    required this.displayName,
    this.avatarUrl,
    this.email,
  });

  factory SuggestionAuthor.fromJson(Map<String, dynamic> json) {
    return SuggestionAuthor(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      avatarUrl: json['avatarUrl'] as String?,
      email: json['email'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'avatarUrl': avatarUrl,
        'email': email,
      };

  SuggestionAuthor copyWith({bool? banned}) => this; // pour compat future

  @override
  bool operator ==(Object other) =>
      other is SuggestionAuthor && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
