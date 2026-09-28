import 'package:flutter/foundation.dart';

/// Une chaîne bannie (table `banned_channels`, migration 0064 — chantier B,
/// contrat §70.3 : motif libre, date du jour, auteur = compte admin
/// connecté ; enrichie par la migration 0094).
///
/// [handle] est normalisé côté serveur (minuscules, SANS le '@') ;
/// [channelId] (UC…) est enrichi a posteriori par les bots via la route EF
/// `channels/resolve-id` (null tant qu'aucun bot n'a croisé la chaîne).
///
/// P4b-3 (lot L2) : colonnes de 0094 lues de `channels/banned-list`
/// (`select *`) — [platform], [origin], [category], [status], [banEventId],
/// [manualEventId]. Une ligne d'une base sans 0094 (colonnes absentes) prend
/// les défauts (`youtube`, `manual`, `moderation`, `manuel`). Une entrée
/// AUTOMATIQUE a le handle technique `auto:<clé>` (clé = identifiant stable
/// de la chaîne : `UC…`, `rutube:…`, `bili:…`) ; elle le garde quand elle est
/// convertie en entrée manuelle (levée avec intention humaine, M94:1646-1656).
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

  /// `youtube` | `rutube` | `bilibili` (défaut `youtube`).
  final String platform;

  /// `manual` (défaut) | `auto`.
  final String origin;

  /// Catégorie du ban (`moderation` par défaut).
  final String category;

  /// `manuel` (défaut) | `en_revue` | `confirme`.
  final String status;

  /// Événement du ban automatique (entrée auto).
  final int? banEventId;

  /// Événement du ban HUMAIN enregistré sur une entrée auto (intention
  /// manuelle, qui survit à la levée du ban automatique).
  final int? manualEventId;

  const BannedChannel({
    required this.id,
    required this.handle,
    this.channelId,
    this.channelUrl,
    this.displayName,
    this.reason,
    this.bannedBy,
    this.createdAt,
    this.platform = 'youtube',
    this.origin = 'manual',
    this.category = 'moderation',
    this.status = 'manuel',
    this.banEventId,
    this.manualEventId,
  });

  factory BannedChannel.fromJson(Map<String, dynamic> json) {
    return BannedChannel(
      id: _int(json['id']) ?? 0,
      handle: json['handle']?.toString() ?? '',
      channelId: json['channel_id']?.toString(),
      channelUrl: json['channel_url']?.toString(),
      displayName: json['display_name']?.toString(),
      reason: json['reason']?.toString(),
      bannedBy: json['banned_by']?.toString(),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      platform: _nonEmpty(json['platform']) ?? 'youtube',
      origin: _nonEmpty(json['origin']) ?? 'manual',
      category: _nonEmpty(json['category']) ?? 'moderation',
      status: _nonEmpty(json['status']) ?? 'manuel',
      banEventId: _int(json['ban_event_id']),
      manualEventId: _int(json['manual_event_id']),
    );
  }

  /// Entrée créée par le ban AUTOMATIQUE (en revue ou confirmée).
  bool get isAuto => origin == 'auto';

  /// Entrée auto convertie en entrée manuelle (ban automatique levé avec
  /// une intention humaine) : handle technique `auto:<clé>` conservé.
  bool get isConverted => !isAuto && handle.startsWith('auto:');

  /// Une intention de ban humain est enregistrée sur l'entrée auto.
  bool get hasManualIntent => manualEventId != null;

  /// Ban automatique confirmé (purge possible).
  bool get isConfirmed => status == 'confirme';

  /// Clé de la chaîne : la clé stable d'une entrée `auto:<clé>`, sinon
  /// l'identifiant de chaîne s'il est connu, sinon le handle.
  String get channelKey =>
      handle.startsWith('auto:') ? handle.substring(5) : (channelId ?? handle);

  /// Libellé d'affichage : « YouTube · UC… », « RUTUBE · rutube:… »,
  /// « bilibili · bili:… » pour une entrée auto ou convertie (handle
  /// technique) ; « @handle » sinon. Texte brut, jamais un lien.
  String get displayLabel => handle.startsWith('auto:')
      ? '${_platformLabel(platform, channelKey)} · $channelKey'
      : displayHandle;

  /// Handle affiché avec le préfixe '@' (conservé pour compatibilité).
  String get displayHandle => '@$handle';
}

/// Nom affiché d'une plateforme de chaîne ; plateforme inconnue → la valeur
/// brute.
String _platformLabel(String platform, String key) {
  switch (platform) {
    case 'youtube':
      // Base sans colonne platform (défaut youtube) : la forme de la clé
      // départage RUTUBE / bilibili.
      if (key.startsWith('rutube:')) return 'RUTUBE';
      if (key.startsWith('bili:')) return 'bilibili';
      return 'YouTube';
    case 'rutube':
      return 'RUTUBE';
    case 'bilibili':
      return 'bilibili';
    default:
      return platform;
  }
}

String? _nonEmpty(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _int(Object? v) => v is num ? v.toInt() : null;

/// Rapport retourné par la route EF `channels/ban` (v74, enrichi v95).
///
/// [purged] : nombre de suggestions en file (pending) rejetées
/// automatiquement (motif « Chaîne bannie »).
///
/// [published] : contenus DÉJÀ publiés de la chaîne (retrouvés via les
/// suggestions acceptées — `contents` n'a pas de colonne chaîne, d'où
/// [publishedVia] = 'suggestions-accepted'). Leur retrait reste MANUEL
/// (route `contents/unpublish-by-channel`, au clic du rapport).
///
/// [result] (v95) : `applied` | `updated` | `auto_en_revue` (la chaîne est
/// déjà bannie AUTOMATIQUEMENT et en revue : rien n'est purgé, l'intention
/// humaine est enregistrée ou la première saisie conservée). Absent (EF
/// antérieure) → `applied`.
@immutable
class BanChannelReport {
  final BannedChannel banned;
  final int purged;
  final List<Map<String, dynamic>> published;
  final String publishedVia;
  final String result;

  const BanChannelReport({
    required this.banned,
    required this.purged,
    required this.published,
    required this.publishedVia,
    this.result = 'applied',
  });

  factory BanChannelReport.fromJson(Map<String, dynamic> json) {
    final Object? banned = json['banned'];
    final Object? published = json['published'];
    return BanChannelReport(
      banned: BannedChannel.fromJson(
        banned is Map ? banned.cast<String, dynamic>() : const {},
      ),
      purged: _int(json['purged']) ?? 0,
      published: published is List
          ? published.whereType<Map<String, dynamic>>().toList()
          : const [],
      publishedVia: json['published_via']?.toString() ?? '',
      result: _nonEmpty(json['result']) ?? 'applied',
    );
  }
}
