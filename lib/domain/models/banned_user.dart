import 'package:flutter/foundation.dart';

import 'suggestion_author.dart';

/// Compte utilisateur banni par un administrateur (sérialisable JSON).
///
/// Le bannissement s'appuie sur l'identifiant de compte Google fiable fourni
/// lors de la connexion. Un compte banni ne peut plus soumettre de suggestions
/// côté application (application effective via le backend en phase 2 ; en
/// phase mock, l'admin peut suivre et débannir ici).
@immutable
class BannedUser {
  final String id;
  final String displayName;
  final String? avatarUrl;
  final String? email;
  final DateTime bannedAt;
  final String? reason;

  const BannedUser({
    required this.id,
    required this.displayName,
    this.avatarUrl,
    this.email,
    required this.bannedAt,
    this.reason,
  });

  factory BannedUser.fromAuthor(SuggestionAuthor author, {String? reason}) {
    return BannedUser(
      id: author.id,
      displayName: author.displayName,
      avatarUrl: author.avatarUrl,
      email: author.email,
      bannedAt: DateTime.now(),
      reason: reason,
    );
  }

  factory BannedUser.fromJson(Map<String, dynamic> json) {
    return BannedUser(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      avatarUrl: json['avatarUrl'] as String?,
      email: json['email'] as String?,
      bannedAt: DateTime.tryParse(json['bannedAt'] as String? ?? '') ??
          DateTime.now(),
      reason: json['reason'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'avatarUrl': avatarUrl,
        'email': email,
        'bannedAt': bannedAt.toIso8601String(),
        'reason': reason,
      };

  @override
  bool operator ==(Object other) => other is BannedUser && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
