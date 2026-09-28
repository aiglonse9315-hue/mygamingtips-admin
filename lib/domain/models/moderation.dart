// Pur (VM) — modèles des routes de MODÉRATION de l'EF admin-catalog
// (migration 0094 + 0096, P4b-3 lot L2) : file de revue, détail d'un
// événement et sa preuve, décision de revue, journal des événements,
// réglages, purge des preuves, pages bloquées, purge d'une chaîne auto,
// résultats des bans / levées manuels.
//
// Lecture JSON TOLÉRANTE partout : entier = `v is num ? v.toInt() : défaut` ;
// texte = `v is String ? v : null` ; liste = éléments du bon type seulement ;
// date = `DateTime.tryParse` (ISO `+00:00`). Un élément sans `id` entier est
// IGNORÉ (`fromJson` rend `null`) : jamais d'exception de lecture, une clé
// ajoutée plus tard côté serveur ne casse rien.
//
// Les textes lus ici (preuve, `target_key` d'une page, `account_display_name`,
// `target_host`, `note`, titres publiés…) sont NON FIABLES : ils sont gardés
// tels quels et ne doivent être affichés qu'en texte brut, caractères
// invisibles rendus visibles (lot L3, `moderation_text.dart`).
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM.
import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// Lecture tolérante (privée au fichier)
// ---------------------------------------------------------------------------

int? _int(Object? v) => v is num ? v.toInt() : null;

String? _str(Object? v) => v is String ? v : null;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

List<String> _strings(Object? v) =>
    v is List ? v.whereType<String>().toList(growable: false) : const [];

List<String>? _stringsOrNull(Object? v) =>
    v is List ? v.whereType<String>().toList(growable: false) : null;

Map<String, dynamic>? _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

// ---------------------------------------------------------------------------
// Décision de revue
// ---------------------------------------------------------------------------

/// Décision envoyée à `moderation/review-decide` (moderation.ts:448-449).
/// Utilisée par la couche d'accès et les widgets (L5), JAMAIS par les
/// modules purs de L3.
enum ReviewDecision {
  confirm,
  lift,
  apply,
  dismiss;

  /// Valeur exacte de la clé `decision` du corps.
  String get code => name;
}

// ---------------------------------------------------------------------------
// File de revue (`moderation/review-list`)
// ---------------------------------------------------------------------------

/// Élément de la file de revue (M94:2369-2381 + 0096 : `channel_row_id`).
@immutable
class ReviewItem {
  const ReviewItem({
    required this.kind,
    this.groupSize = 1,
    required this.id,
    this.createdAt,
    required this.targetKind,
    this.targetKey,
    required this.action,
    required this.category,
    this.reasons = const [],
    this.suggestionId,
    this.sharedAt,
    this.platform,
    this.contentKey,
    this.detectorVersion,
    this.rulesSha256,
    this.rules,
    this.field,
    this.level,
    this.evidenceSha256,
    this.rawSha256,
    this.actorUsername,
    this.suggestionAuthorId,
    this.hasEvidence = false,
    this.accountDisplayName,
    this.manualBanPresent = false,
    this.channelRowId,
  });

  /// `ban_en_revue` | `a_examiner` | `refus_a_revoir` ; une valeur inconnue
  /// est GARDÉE telle quelle (`''` si absente).
  final String kind;

  /// Taille du groupe (1 par défaut).
  final int groupSize;

  /// Identifiant `ban_events` (= `event_id` du détail et de la décision).
  final int id;
  final DateTime? createdAt;

  /// `account` | `channel` | `page`.
  final String targetKind;

  /// Clé de la cible NON masquée (UUID, clé de chaîne ou URL de page
  /// choisie par un tiers : texte non fiable).
  final String? targetKey;
  final String action;
  final String category;
  final List<String> reasons;
  final String? suggestionId;
  final DateTime? sharedAt;
  final String? platform;
  final String? contentKey;
  final String? detectorVersion;
  final String? rulesSha256;
  final List<String>? rules;
  final String? field;
  final String? level;
  final String? evidenceSha256;
  final String? rawSha256;
  final String? actorUsername;
  final String? suggestionAuthorId;

  /// Preuve PROPRE à l'événement encore conservée.
  final bool hasEvidence;

  /// Nom d'affichage du compte visé (texte d'utilisateur, non borné).
  final String? accountDisplayName;

  /// Un ban humain est présent sur la cible (juste pour les chaînes à partir
  /// de 0096).
  final bool manualBanPresent;

  /// `banned_channels.id` de la cible (0096) ; `null` sur une base sans 0096
  /// ou pour une cible qui n'est pas une chaîne bannie.
  final int? channelRowId;

  /// `null` si [j] n'est pas un objet ou n'a pas d'`id` entier.
  static ReviewItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final int? id = _int(j['id']);
    if (id == null) return null;
    return ReviewItem(
      kind: _str(j['kind']) ?? '',
      groupSize: _int(j['group_size']) ?? 1,
      id: id,
      createdAt: _date(j['created_at']),
      targetKind: _str(j['target_kind']) ?? '',
      targetKey: _str(j['target_key']),
      action: _str(j['action']) ?? '',
      category: _str(j['category']) ?? '',
      reasons: _strings(j['reasons']),
      suggestionId: _str(j['suggestion_id']),
      sharedAt: _date(j['shared_at']),
      platform: _str(j['platform']),
      contentKey: _str(j['content_key']),
      detectorVersion: _str(j['detector_version']),
      rulesSha256: _str(j['rules_sha256']),
      rules: _stringsOrNull(j['rules']),
      field: _str(j['field']),
      level: _str(j['level']),
      evidenceSha256: _str(j['evidence_sha256']),
      rawSha256: _str(j['raw_sha256']),
      actorUsername: _str(j['actor_username']),
      suggestionAuthorId: _str(j['suggestion_author_id']),
      hasEvidence: j['has_evidence'] == true,
      accountDisplayName: _str(j['account_display_name']),
      manualBanPresent: j['manual_ban_present'] == true,
      channelRowId: _int(j['channel_row_id']),
    );
  }
}

/// Une page de la file de revue. `total` = taille TOTALE de la file.
@immutable
class ReviewQueuePage {
  const ReviewQueuePage({
    required this.total,
    required this.page,
    required this.pageSize,
    required this.items,
  });

  final int total;
  final int page;
  final int pageSize;
  final List<ReviewItem> items;

  /// Éléments illisibles ignorés ; `total` absent → nombre d'éléments lus ;
  /// `page` absent → 0 ; `pageSize` absent → 50 (défaut serveur).
  static ReviewQueuePage fromJson(Map<String, dynamic> j) {
    final Object? raw = j['items'];
    final List<ReviewItem> items = raw is List
        ? raw.map(ReviewItem.fromJson).whereType<ReviewItem>().toList()
        : <ReviewItem>[];
    return ReviewQueuePage(
      total: _int(j['total']) ?? items.length,
      page: _int(j['page']) ?? 0,
      pageSize: _int(j['pageSize']) ?? 50,
      items: List<ReviewItem>.unmodifiable(items),
    );
  }
}

// ---------------------------------------------------------------------------
// Événement (`review-detail.event`, `events-list.items`)
// ---------------------------------------------------------------------------

/// Ligne `ban_events` (M94:116-165). Dans `events-list`, la clé peut être
/// MASQUÉE (M94:2491-2507) : [targetKey] `null`, [targetKeyMasked] vrai,
/// [targetHost] et [targetKeySha256] à la place. [snapshot] n'est rendu que
/// par `review-detail`.
@immutable
class BanEvent {
  const BanEvent({
    required this.id,
    this.createdAt,
    required this.targetKind,
    this.targetKey,
    this.targetKeyMasked = false,
    this.targetHost,
    this.targetKeySha256,
    required this.action,
    required this.origin,
    required this.category,
    this.actorUsername,
    required this.actorKind,
    this.reasons = const [],
    this.refEventId,
    this.groupEventId,
    this.suggestionId,
    this.sharedAt,
    this.platform,
    this.contentKey,
    this.detectorVersion,
    this.rulesSha256,
    this.rules,
    this.field,
    this.level,
    this.evidenceSha256,
    this.rawSha256,
    this.note,
    this.snapshot,
  });

  final int id;
  final DateTime? createdAt;
  final String targetKind;
  final String? targetKey;
  final bool targetKeyMasked;

  /// Hôte lu de la clé masquée (texte non fiable, ≤ 253).
  final String? targetHost;
  final String? targetKeySha256;
  final String action;
  final String origin;
  final String category;
  final String? actorUsername;

  /// `detecteur` | `revue` | `manuel`.
  final String actorKind;
  final List<String> reasons;
  final int? refEventId;
  final int? groupEventId;
  final String? suggestionId;
  final DateTime? sharedAt;
  final String? platform;
  final String? contentKey;
  final String? detectorVersion;
  final String? rulesSha256;
  final List<String>? rules;
  final String? field;
  final String? level;
  final String? evidenceSha256;
  final String? rawSha256;

  /// Motif saisi par un admin (≤ 500).
  final String? note;

  /// Relecture serveur compacte (`review-detail` seulement).
  final Map<String, dynamic>? snapshot;

  /// `null` si [j] n'est pas un objet ou n'a pas d'`id` entier.
  static BanEvent? fromJson(Object? j) {
    if (j is! Map) return null;
    final int? id = _int(j['id']);
    if (id == null) return null;
    return BanEvent(
      id: id,
      createdAt: _date(j['created_at']),
      targetKind: _str(j['target_kind']) ?? '',
      targetKey: _str(j['target_key']),
      targetKeyMasked: j['target_key_masked'] == true,
      targetHost: _str(j['target_host']),
      targetKeySha256: _str(j['target_key_sha256']),
      action: _str(j['action']) ?? '',
      origin: _str(j['origin']) ?? '',
      category: _str(j['category']) ?? '',
      actorUsername: _str(j['actor_username']),
      actorKind: _str(j['actor_kind']) ?? '',
      reasons: _strings(j['reasons']),
      refEventId: _int(j['ref_event_id']),
      groupEventId: _int(j['group_event_id']),
      suggestionId: _str(j['suggestion_id']),
      sharedAt: _date(j['shared_at']),
      platform: _str(j['platform']),
      contentKey: _str(j['content_key']),
      detectorVersion: _str(j['detector_version']),
      rulesSha256: _str(j['rules_sha256']),
      rules: _stringsOrNull(j['rules']),
      field: _str(j['field']),
      level: _str(j['level']),
      evidenceSha256: _str(j['evidence_sha256']),
      rawSha256: _str(j['raw_sha256']),
      note: _str(j['note']),
      snapshot: _map(j['snapshot']),
    );
  }
}

// ---------------------------------------------------------------------------
// Détail d'un événement et preuve (`moderation/review-detail`)
// ---------------------------------------------------------------------------

/// État de la preuve affichée dans le détail.
enum EvidenceState {
  /// Preuve propre à l'événement.
  present,

  /// Preuve de la tête du groupe (ou de l'événement revu).
  headEvidence,

  /// Aucune preuve écrite à l'époque (plafond, membre, already_banned).
  notKept,

  /// Preuve écrite puis purgée.
  purged,

  /// Aucune information (pas de relecture serveur).
  none,
}

/// Preuve conservée (`moderation_evidence`, M94:254-266). Tous les textes
/// sont choisis par un tiers : affichage en texte brut seulement.
@immutable
class Evidence {
  const Evidence({
    required this.eventId,
    this.createdAt,
    this.originKey,
    this.suggestionUrl,
    this.sharedText,
    this.demande,
  });

  final int eventId;
  final DateTime? createdAt;
  final String? originKey;
  final String? suggestionUrl;
  final String? sharedText;

  /// Demande reconstruite par l'EF (objet JSON brut, ≤ 256 Kio) ou `null`.
  final Object? demande;

  /// `null` si [j] n'est pas un objet ou n'a pas d'`event_id` entier.
  static Evidence? fromJson(Object? j) {
    if (j is! Map) return null;
    final int? eventId = _int(j['event_id']);
    if (eventId == null) return null;
    return Evidence(
      eventId: eventId,
      createdAt: _date(j['created_at']),
      originKey: _str(j['origin_key']),
      suggestionUrl: _str(j['suggestion_url']),
      sharedText: _str(j['shared_text']),
      demande: j['demande'],
    );
  }
}

/// Réponse de `moderation/review-detail` (M94:2408-2455).
@immutable
class ReviewDetail {
  const ReviewDetail({
    required this.event,
    this.evidence,
    this.evidenceEventId,
    required this.groupHeadId,
    required this.groupSize,
    this.groupMembers = const [],
  });

  final BanEvent event;
  final Evidence? evidence;

  /// Événement dont vient la preuve (≠ `event.id` : preuve de la tête).
  final int? evidenceEventId;
  final int groupHeadId;
  final int groupSize;

  /// Membres du groupe (≤ 100, triés).
  final List<int> groupMembers;

  /// `present` : preuve propre ; `headEvidence` : preuve de la tête
  /// (`evidenceEventId` ≠ `event.id`) ; sinon `snapshot.preuve == true` →
  /// `purged`, `== false` → `notKept` ; snapshot absent (ou sans `preuve`
  /// booléen) → `none`.
  EvidenceState get evidenceState {
    final Evidence? ev = evidence;
    if (ev != null) {
      return (evidenceEventId ?? ev.eventId) == event.id
          ? EvidenceState.present
          : EvidenceState.headEvidence;
    }
    final Object? preuve = event.snapshot?['preuve'];
    if (preuve == true) return EvidenceState.purged;
    if (preuve == false) return EvidenceState.notKept;
    return EvidenceState.none;
  }

  /// `null` si `result != 'ok'` ou si `event` est illisible.
  static ReviewDetail? fromJson(Map<String, dynamic> j) {
    if (j['result'] != 'ok') return null;
    final BanEvent? event = BanEvent.fromJson(j['event']);
    if (event == null) return null;
    final Map<String, dynamic>? group = _map(j['group']);
    final Object? members = group?['members'];
    return ReviewDetail(
      event: event,
      evidence: Evidence.fromJson(j['evidence']),
      evidenceEventId: _int(j['evidence_event_id']),
      groupHeadId: _int(group?['head_id']) ?? event.id,
      groupSize: _int(group?['size']) ?? 1,
      groupMembers: members is List
          ? members.map(_int).whereType<int>().toList(growable: false)
          : const [],
    );
  }
}

// ---------------------------------------------------------------------------
// Décision (`moderation/review-decide`)
// ---------------------------------------------------------------------------

/// Réponse 200 de `moderation/review-decide` : les 7 clés d'index.ts:2903-2907.
@immutable
class ReviewDecideResult {
  const ReviewDecideResult({
    required this.result,
    this.eventId,
    this.targetKind,
    this.reasons = const [],
    this.previous,
    this.stillBanned,
    this.groupSize,
    this.replayed = false,
  });

  /// `confirmed`, `already_confirmed`, `lifted`, `already_lifted`, `applied`,
  /// `already_banned`, `refused`, `dismissed`, `already_resolved`.
  final String result;
  final int? eventId;
  final String? targetKind;
  final List<String> reasons;

  /// Décision déjà prise (`already_resolved`).
  final String? previous;

  /// `manuel` si un ban humain reste posé après une levée.
  final String? stillBanned;
  final int? groupSize;

  /// Réponse obtenue après un REJEU (la 1re réponse a été perdue).
  final bool replayed;

  static ReviewDecideResult fromJson(
    Map<String, dynamic> j, {
    bool replayed = false,
  }) {
    return ReviewDecideResult(
      result: _str(j['result']) ?? '',
      eventId: _int(j['event_id']),
      targetKind: _str(j['target_kind']),
      reasons: _strings(j['reasons']),
      previous: _str(j['previous']),
      stillBanned: _str(j['still_banned']),
      groupSize: _int(j['group_size']),
      replayed: replayed,
    );
  }
}

// ---------------------------------------------------------------------------
// Journal (`moderation/events-list`)
// ---------------------------------------------------------------------------

/// Une page du journal des événements.
@immutable
class EventsPage {
  const EventsPage({
    required this.total,
    required this.page,
    required this.pageSize,
    required this.items,
  });

  final int total;
  final int page;
  final int pageSize;
  final List<BanEvent> items;

  static EventsPage fromJson(Map<String, dynamic> j) {
    final Object? raw = j['items'];
    final List<BanEvent> items = raw is List
        ? raw.map(BanEvent.fromJson).whereType<BanEvent>().toList()
        : <BanEvent>[];
    return EventsPage(
      total: _int(j['total']) ?? items.length,
      page: _int(j['page']) ?? 0,
      pageSize: _int(j['pageSize']) ?? 50,
      items: List<BanEvent>.unmodifiable(items),
    );
  }
}

// ---------------------------------------------------------------------------
// Réglages (`moderation/settings-get`, `moderation/settings-set`)
// ---------------------------------------------------------------------------

/// Réglages de la modération automatique (M94:2245-2280).
@immutable
class ModerationSettings {
  const ModerationSettings({
    required this.autoBanEnabled,
    required this.maxPerHour,
    required this.maxPerDay,
    this.allowedRulesSha256 = const [],
    this.breakerTrippedAt,
    this.breakerReason,
    this.breakerEventId,
    this.updatedAt,
    this.updatedBy,
    this.autoBansLastHour = 0,
    this.autoBansLastDay = 0,
    this.refused24h = const {},
    this.reviewQueueSize = 0,
    this.evidenceRows = 0,
    this.chainThreshold = 2,
    this.chainWindowDays = 90,
  });

  final bool autoBanEnabled;
  final int maxPerHour;
  final int maxPerDay;
  final List<String> allowedRulesSha256;
  final DateTime? breakerTrippedAt;

  /// `plafond_heure` | `plafond_jour`.
  final String? breakerReason;
  final int? breakerEventId;
  final DateTime? updatedAt;

  /// Compte qui a modifié les réglages, ou `disjoncteur`.
  final String? updatedBy;
  final int autoBansLastHour;
  final int autoBansLastDay;

  /// Refus du détecteur des 24 dernières heures PAR RAISON (`{}` si absent).
  final Map<String, int> refused24h;
  final int reviewQueueSize;
  final int evidenceRows;
  final int chainThreshold;
  final int chainWindowDays;

  /// Disjoncté = éteint + horodatage (M94:1453-1461) ; allumer efface
  /// l'horodatage.
  bool get breakerOpen => breakerTrippedAt != null;

  /// `null` si [j] n'est pas un objet ou si l'interrupteur et les plafonds
  /// sont illisibles (choix sûr : un réglage de sécurité illisible n'est
  /// jamais lu comme « éteint » ou « 0 » par défaut).
  static ModerationSettings? fromJson(Object? j) {
    if (j is! Map) return null;
    final Object? enabled = j['auto_ban_enabled'];
    final int? perHour = _int(j['max_auto_bans_per_hour']);
    final int? perDay = _int(j['max_auto_bans_per_day']);
    if (enabled is! bool || perHour == null || perDay == null) return null;
    final Object? refused = j['refused_24h'];
    final Map<String, int> refusedMap = <String, int>{};
    if (refused is Map) {
      refused.forEach((Object? k, Object? v) {
        if (k is String && v is num) refusedMap[k] = v.toInt();
      });
    }
    return ModerationSettings(
      autoBanEnabled: enabled,
      maxPerHour: perHour,
      maxPerDay: perDay,
      allowedRulesSha256: _strings(j['allowed_rules_sha256']),
      breakerTrippedAt: _date(j['breaker_tripped_at']),
      breakerReason: _str(j['breaker_reason']),
      breakerEventId: _int(j['breaker_event_id']),
      updatedAt: _date(j['updated_at']),
      updatedBy: _str(j['updated_by']),
      autoBansLastHour: _int(j['auto_bans_last_hour']) ?? 0,
      autoBansLastDay: _int(j['auto_bans_last_day']) ?? 0,
      refused24h: Map<String, int>.unmodifiable(refusedMap),
      reviewQueueSize: _int(j['review_queue_size']) ?? 0,
      evidenceRows: _int(j['evidence_rows']) ?? 0,
      chainThreshold: _int(j['chain_threshold']) ?? 2,
      chainWindowDays: _int(j['chain_window_days']) ?? 90,
    );
  }
}

// ---------------------------------------------------------------------------
// Purge des preuves (`moderation/evidence-purge`)
// ---------------------------------------------------------------------------

/// `{result: preview | purged, count}` + rejeu.
@immutable
class EvidencePurgeResult {
  const EvidencePurgeResult({
    required this.result,
    required this.count,
    this.replayed = false,
  });

  final String result;
  final int count;
  final bool replayed;

  static EvidencePurgeResult fromJson(
    Map<String, dynamic> j, {
    bool replayed = false,
  }) {
    return EvidencePurgeResult(
      result: _str(j['result']) ?? '',
      count: _int(j['count']) ?? 0,
      replayed: replayed,
    );
  }
}

// ---------------------------------------------------------------------------
// Pages bloquées (`moderation/blocked-pages/list`)
// ---------------------------------------------------------------------------

/// Page web bloquée (URL canonique EXACTE choisie par un tiers : texte brut,
/// jamais cliquable).
@immutable
class BlockedPage {
  const BlockedPage({
    required this.id,
    required this.url,
    this.host,
    required this.status,
    required this.origin,
    required this.category,
    this.banEventId,
    this.createdAt,
  });

  final int id;
  final String url;
  final String? host;

  /// `en_revue` | `confirme` | `manuel`.
  final String status;

  /// `auto` | `manual`.
  final String origin;
  final String category;
  final int? banEventId;
  final DateTime? createdAt;

  /// `null` si [j] n'est pas un objet ou n'a pas d'`id` entier.
  static BlockedPage? fromJson(Object? j) {
    if (j is! Map) return null;
    final int? id = _int(j['id']);
    if (id == null) return null;
    return BlockedPage(
      id: id,
      url: _str(j['url']) ?? '',
      host: _str(j['host']),
      status: _str(j['status']) ?? '',
      origin: _str(j['origin']) ?? '',
      category: _str(j['category']) ?? '',
      banEventId: _int(j['ban_event_id']),
      createdAt: _date(j['created_at']),
    );
  }
}

/// `{pages[], total}` (pas d'écho de page ni de taille).
@immutable
class BlockedPagesPage {
  const BlockedPagesPage({required this.pages, required this.total});

  final List<BlockedPage> pages;
  final int total;

  static BlockedPagesPage fromJson(Map<String, dynamic> j) {
    final Object? raw = j['pages'];
    final List<BlockedPage> pages = raw is List
        ? raw.map(BlockedPage.fromJson).whereType<BlockedPage>().toList()
        : <BlockedPage>[];
    return BlockedPagesPage(
      pages: List<BlockedPage>.unmodifiable(pages),
      total: _int(j['total']) ?? pages.length,
    );
  }
}

// ---------------------------------------------------------------------------
// Purge d'une chaîne auto (`channels/purge-auto`)
// ---------------------------------------------------------------------------

/// Contenu déjà publié d'une chaîne (rapporté, retrait manuel). Titre et URL
/// non fiables : texte brut.
@immutable
class PublishedContent {
  const PublishedContent({required this.id, this.title, this.url});

  final String id;
  final String? title;
  final String? url;

  /// `null` si [j] n'est pas un objet ou n'a pas d'`id` (texte ou nombre).
  static PublishedContent? fromJson(Object? j) {
    if (j is! Map) return null;
    final Object? id = j['id'];
    final String? idText = id is String
        ? (id.isEmpty ? null : id)
        : (id is num ? id.toString() : null);
    if (idText == null) return null;
    return PublishedContent(
      id: idText,
      title: _str(j['title']),
      url: _str(j['url']),
    );
  }
}

/// Aperçu `{result: preview, pending, pending_by_detection,
/// pending_by_channel_id, published}` ou application `{result: purged,
/// pending, purged, published}` (M94:2223-2237) + rejeu.
@immutable
class PurgeAutoResult {
  const PurgeAutoResult({
    required this.result,
    required this.pending,
    this.pendingByDetection,
    this.pendingByChannelId,
    this.purged,
    this.published = const [],
    this.replayed = false,
  });

  /// `preview` | `purged`.
  final String result;

  /// Suggestions en attente trouvées (par id exact).
  final int pending;

  /// Aperçu seulement.
  final int? pendingByDetection;

  /// Aperçu seulement.
  final int? pendingByChannelId;

  /// Application seulement : suggestions effectivement rejetées.
  final int? purged;

  /// Contenus déjà publiés (≤ 200, tri par id).
  final List<PublishedContent> published;
  final bool replayed;

  static PurgeAutoResult fromJson(
    Map<String, dynamic> j, {
    bool replayed = false,
  }) {
    final Object? raw = j['published'];
    return PurgeAutoResult(
      result: _str(j['result']) ?? '',
      pending: _int(j['pending']) ?? 0,
      pendingByDetection: _int(j['pending_by_detection']),
      pendingByChannelId: _int(j['pending_by_channel_id']),
      purged: _int(j['purged']),
      published: raw is List
          ? List<PublishedContent>.unmodifiable(
              raw.map(PublishedContent.fromJson).whereType<PublishedContent>(),
            )
          : const [],
      replayed: replayed,
    );
  }
}

// ---------------------------------------------------------------------------
// Bans / levées MANUELS de comptes (`profiles/ban`, `profiles/unban`)
// ---------------------------------------------------------------------------

/// `profiles/ban` 200 : `{ok, result: applied | already_banned, event_id}`.
@immutable
class ManualBanResult {
  const ManualBanResult({
    required this.result,
    this.eventId,
    this.replayed = false,
  });

  final String result;
  final int? eventId;
  final bool replayed;

  static ManualBanResult fromJson(
    Map<String, dynamic> j, {
    bool replayed = false,
  }) {
    return ManualBanResult(
      result: _str(j['result']) ?? '',
      eventId: _int(j['event_id']),
      replayed: replayed,
    );
  }
}

/// `profiles/unban` 200 : `{ok, result: lifted | not_banned, event_id}` ;
/// [replayed] = réponse obtenue après un rejeu (revue P4b-3, INF-01 : un
/// `not_banned` rejoué vient très probablement de la levée faite au 1er
/// essai).
@immutable
class ManualUnbanResult {
  const ManualUnbanResult({
    required this.result,
    this.eventId,
    this.replayed = false,
  });

  final String result;
  final int? eventId;
  final bool replayed;

  static ManualUnbanResult fromJson(
    Map<String, dynamic> j, {
    bool replayed = false,
  }) {
    return ManualUnbanResult(
      result: _str(j['result']) ?? '',
      eventId: _int(j['event_id']),
      replayed: replayed,
    );
  }
}
