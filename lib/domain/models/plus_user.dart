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

  /// Échéance de l'abonnement (`expires_at`) : null = sans fin (manuels,
  /// offerts). Renseignée pour Google Play et les récompenses.
  final DateTime? expiresAt;

  /// Compte banni (`profiles.is_banned`, fourni ligne par ligne par la route
  /// EF `subscriptions/list` — migration 0085).
  final bool isBanned;

  const PlusUser({
    required this.id,
    required this.displayName,
    this.email,
    required this.plan,
    required this.startedAt,
    this.active = true,
    this.source = 'admin',
    this.expiresAt,
    this.isBanned = false,
  });

  /// Format LOCAL (camelCase — cache de l'aperçu local, seeds).
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
      expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
      isBanned: (json['isBanned'] as bool?) ?? false,
    );
  }

  /// Ligne SERVEUR (snake_case) de la route EF `subscriptions/list` :
  /// user_id, plan, is_active, started_at, expires_at, source, display_name,
  /// is_banned. Tolérant : un champ absent ou mal typé prend une valeur par
  /// défaut sûre (jamais d'exception de parsing sur une ligne).
  factory PlusUser.fromServerRow(Map<String, dynamic> row) {
    final Object? name = row['display_name'];
    final Object? plan = row['plan'];
    final Object? source = row['source'];
    return PlusUser(
      id: row['user_id']?.toString() ?? '',
      displayName: name is String && name.isNotEmpty ? name : 'Inconnu',
      plan: plan is String ? plan : 'monthly',
      startedAt:
          DateTime.tryParse(row['started_at']?.toString() ?? '') ??
              DateTime.now(),
      active: row['is_active'] == true,
      source: source is String ? source : 'admin',
      expiresAt: DateTime.tryParse(row['expires_at']?.toString() ?? ''),
      isBanned: row['is_banned'] == true,
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
        'expiresAt': expiresAt?.toIso8601String(),
        'isBanned': isBanned,
      };

  bool get isGoogle => source.startsWith('google');

  /// `true` si l'abonnement a été vérifié côté serveur auprès de Google Play
  /// (Edge Function `verify-purchase`, Phase 4.1).
  bool get isVerified => source == 'google_verified';

  /// Échéance DÉJÀ PASSÉE à [now] (défaut : maintenant) : l'app et Analytics
  /// considèrent alors l'abonnement comme expiré, même si `is_active` est vrai.
  bool isExpiredAt([DateTime? now]) =>
      expiresAt != null && expiresAt!.isBefore(now ?? DateTime.now());

  PlusUser copyWith({
    bool? active,
    String? plan,
    bool? isBanned,
  }) {
    return PlusUser(
      id: id,
      displayName: displayName,
      email: email,
      plan: plan ?? this.plan,
      startedAt: startedAt,
      active: active ?? this.active,
      source: source,
      expiresAt: expiresAt,
      isBanned: isBanned ?? this.isBanned,
    );
  }

  @override
  bool operator ==(Object other) => other is PlusUser && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
