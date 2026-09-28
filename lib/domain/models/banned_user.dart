import 'package:flutter/foundation.dart';

import 'suggestion_author.dart';

/// Compte utilisateur banni (sérialisable JSON pour le cache local).
///
/// Le bannissement s'appuie sur l'identifiant de compte fiable fourni lors de
/// la connexion. Un compte banni ne peut plus soumettre de suggestions côté
/// application.
///
/// P4b-3 (lot L2) : enrichi depuis la route EF `profiles/banned-list`
/// (fonction SQL `moderation_banned_list`, migration 0094) — catégorie,
/// origine (`auto` | `manual`), statut (`en_revue` | `confirme` | `manuel`),
/// événement du ban et présence d'un ban manuel. [bannedAt] est NULLABLE :
/// un ban antérieur à 0094 n'a pas de date connue du serveur.
@immutable
class BannedUser {
  final String id;
  final String displayName;
  final String? avatarUrl;
  final String? email;

  /// Date du ban ; `null` = ban antérieur à 0094 (date inconnue du serveur)
  /// ou date illisible dans le cache.
  final DateTime? bannedAt;
  final String? reason;

  /// Catégorie du ban (`moderation` par défaut).
  final String category;

  /// Origine du ban actif : `auto` (ban automatique en revue ou confirmé) ou
  /// `manual` (défaut).
  final String origin;

  /// Statut du ban : `en_revue` | `confirme` | `manuel` (défaut).
  final String status;

  /// Événement `ban_events` du ban actif (sert à lever un ban automatique).
  final int? banEventId;

  /// Vrai si un ban HUMAIN a été enregistré en plus d'un ban automatique
  /// (il survit à la levée du ban automatique).
  final bool manualBanPresent;

  const BannedUser({
    required this.id,
    required this.displayName,
    this.avatarUrl,
    this.email,
    this.bannedAt,
    this.reason,
    this.category = 'moderation',
    this.origin = 'manual',
    this.status = 'manuel',
    this.banEventId,
    this.manualBanPresent = false,
  });

  /// Ban automatique (en revue ou confirmé) : sa levée passe par la
  /// modération (compte principal), jamais par `profiles/unban`.
  bool get isAuto => origin == 'auto';

  /// Ban automatique encore en revue.
  bool get isAutoInReview => isAuto && status == 'en_revue';

  /// Ban automatique confirmé.
  bool get isAutoConfirmed => isAuto && status == 'confirme';

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

  /// Élément de `profiles/banned-list` (snake_case, M94:2527-2546) : `id`,
  /// `display_name` (absent → « Inconnu »), `ban_reason`, `banned_at`,
  /// `category`, `origin`, `status`, `ban_event_id`, `manual_ban_present`.
  /// Lecture tolérante : valeur absente ou de mauvais type → défaut.
  factory BannedUser.fromServer(Map<String, dynamic> m) {
    return BannedUser(
      id: _text(m['id']) ?? '',
      displayName: _text(m['display_name']) ?? 'Inconnu',
      reason: _text(m['ban_reason']),
      bannedAt: _date(m['banned_at']),
      category: _nonEmpty(m['category']) ?? 'moderation',
      origin: _nonEmpty(m['origin']) ?? 'manual',
      status: _nonEmpty(m['status']) ?? 'manuel',
      banEventId: _int(m['ban_event_id']),
      manualBanPresent: m['manual_ban_present'] == true,
    );
  }

  /// Cache local (camelCase). Tolère l'ANCIEN cache à 6 clés (`id`,
  /// `displayName`, `avatarUrl`, `email`, `bannedAt`, `reason`) : champs
  /// ajoutés → défauts ; `bannedAt` illisible → `null` ; `displayName`
  /// absent → l'identifiant.
  factory BannedUser.fromJson(Map<String, dynamic> json) {
    final String id = _text(json['id']) ?? '';
    return BannedUser(
      id: id,
      displayName: _text(json['displayName']) ?? id,
      avatarUrl: _text(json['avatarUrl']),
      email: _text(json['email']),
      bannedAt: _date(json['bannedAt']),
      reason: _text(json['reason']),
      category: _nonEmpty(json['category']) ?? 'moderation',
      origin: _nonEmpty(json['origin']) ?? 'manual',
      status: _nonEmpty(json['status']) ?? 'manuel',
      banEventId: _int(json['banEventId']),
      manualBanPresent: json['manualBanPresent'] == true,
    );
  }

  /// Les 6 clés historiques + `category`, `origin`, `status`, `banEventId`,
  /// `manualBanPresent`.
  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'email': email,
    'bannedAt': bannedAt?.toIso8601String(),
    'reason': reason,
    'category': category,
    'origin': origin,
    'status': status,
    'banEventId': banEventId,
    'manualBanPresent': manualBanPresent,
  };

  @override
  bool operator ==(Object other) => other is BannedUser && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

String? _text(Object? v) => v is String ? v : null;

String? _nonEmpty(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _int(Object? v) => v is num ? v.toInt() : null;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
