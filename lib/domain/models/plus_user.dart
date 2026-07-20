import 'package:flutter/foundation.dart';

/// Utilisateur premium Plus (gestion admin, sérialisable JSON).
@immutable
class PlusUser {
  final String id;
  final String displayName;
  final String? email;
  final String plan; // 'monthly' ou 'yearly'
  final DateTime startedAt;
  final bool active;
  final String source; // 'google' / 'google_verified' (Play, vérifié serveur) ou 'admin' (manuel)

  const PlusUser({
    required this.id,
    required this.displayName,
    this.email,
    required this.plan,
    required this.startedAt,
    this.active = true,
    this.source = 'admin',
  });

  factory PlusUser.fromJson(Map<String, dynamic> json) {
    return PlusUser(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      email: json['email'] as String?,
      plan: (json['plan'] as String?) ?? 'monthly',
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ??
              DateTime.now(),
      active: (json['active'] as bool?) ?? true,
      source: (json['source'] as String?) ?? 'admin',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'email': email,
        'plan': plan,
        'startedAt': startedAt.toIso8601String(),
        'active': active,
        'source': source,
      };

  bool get isGoogle => source.startsWith('google');

  /// `true` si l'abonnement a été vérifié côté serveur auprès de Google Play
  /// (Edge Function `verify-purchase`, Phase 4.1).
  bool get isVerified => source == 'google_verified';

  PlusUser copyWith({
    bool? active,
    String? plan,
  }) {
    return PlusUser(
      id: id,
      displayName: displayName,
      email: email,
      plan: plan ?? this.plan,
      startedAt: startedAt,
      active: active ?? this.active,
      source: source,
    );
  }

  @override
  bool operator ==(Object other) => other is PlusUser && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
