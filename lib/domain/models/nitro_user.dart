import 'package:flutter/foundation.dart';

/// Utilisateur premium Nitro (gestion admin, sérialisable JSON).
@immutable
class NitroUser {
  final String id;
  final String displayName;
  final String? email;
  final String plan; // 'monthly' ou 'yearly'
  final DateTime startedAt;
  final bool active;

  const NitroUser({
    required this.id,
    required this.displayName,
    this.email,
    required this.plan,
    required this.startedAt,
    this.active = true,
  });

  factory NitroUser.fromJson(Map<String, dynamic> json) {
    return NitroUser(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      email: json['email'] as String?,
      plan: (json['plan'] as String?) ?? 'monthly',
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ??
              DateTime.now(),
      active: (json['active'] as bool?) ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'email': email,
        'plan': plan,
        'startedAt': startedAt.toIso8601String(),
        'active': active,
      };

  NitroUser copyWith({
    bool? active,
    String? plan,
  }) {
    return NitroUser(
      id: id,
      displayName: displayName,
      email: email,
      plan: plan ?? this.plan,
      startedAt: startedAt,
      active: active ?? this.active,
    );
  }

  @override
  bool operator ==(Object other) => other is NitroUser && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
