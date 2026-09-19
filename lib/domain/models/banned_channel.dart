import 'package:flutter/foundation.dart';

/// Une chaîne YouTube bannie (table `banned_channels`, migration 0064 —
/// chantier B, contrat §70.3 : motif libre, date du jour, auteur = compte
/// admin connecté).
///
/// [handle] est normalisé côté serveur (minuscules, SANS le '@') ;
/// [channelId] (UC…) est enrichi a posteriori par les bots via la route EF
/// `channels/resolve-id` (null tant qu'aucun bot n'a croisé la chaîne).
@immutable
class BannedChannel {
  final int id;
  final String handle;
  final String? channelId;
  final String? channelUrl;
  final String? displayName;
  final String? reason;
  final String? bannedBy;
  final DateTime? createdAt;

  const BannedChannel({
    required this.id,
    required this.handle,
    this.channelId,
    this.channelUrl,
    this.displayName,
    this.reason,
    this.bannedBy,
    this.createdAt,
  });

  factory BannedChannel.fromJson(Map<String, dynamic> json) {
    return BannedChannel(
      id: (json['id'] as num?)?.toInt() ?? 0,
      handle: json['handle']?.toString() ?? '',
      channelId: json['channel_id']?.toString(),
      channelUrl: json['channel_url']?.toString(),
      displayName: json['display_name']?.toString(),
      reason: json['reason']?.toString(),
      bannedBy: json['banned_by']?.toString(),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }

  /// Handle affiché avec le préfixe '@'.
  String get displayHandle => '@$handle';
}

/// Rapport retourné par la route EF `channels/ban` (v74).
///
/// [purged] : nombre de suggestions en file (pending) rejetées
/// automatiquement (motif « Chaîne bannie »).
///
/// [published] : contenus DÉJÀ publiés de la chaîne (retrouvés via les
/// suggestions acceptées — `contents` n'a pas de colonne chaîne, d'où
/// [publishedVia] = 'suggestions-accepted'). Leur retrait reste MANUEL
/// (route `contents/unpublish-by-channel`, au clic du rapport).
@immutable
class BanChannelReport {
  final BannedChannel banned;
  final int purged;
  final List<Map<String, dynamic>> published;
  final String publishedVia;

  const BanChannelReport({
    required this.banned,
    required this.purged,
    required this.published,
    required this.publishedVia,
  });

  factory BanChannelReport.fromJson(Map<String, dynamic> json) {
    return BanChannelReport(
      banned: BannedChannel.fromJson(
        (json['banned'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      purged: (json['purged'] as num?)?.toInt() ?? 0,
      published:
          (json['published'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .toList() ??
          const [],
      publishedVia: json['published_via']?.toString() ?? '',
    );
  }
}
