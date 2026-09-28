// Pur (VM) — boutons et résultats de la modération (P4b-3, lot L3,
// conception §4.5) : actions proposées pour un élément de la file ou un ban
// automatique actif, traduction des résultats de `moderation/review-decide`
// (codes et 409 : moderation.ts:562-585 ; corps : index.ts:2894-2907), des
// débans (`profiles/unban`, `channels/unban`), bilan d'un lot de bans,
// textes de `channels/purge-auto`, rejeu, navigation « Ouvrir dans
// Modération », pagination après retrait, plafonds, disjoncteur,
// différences d'empreintes.
//
// Fonctions sur des chaînes et des entiers seulement (AUCUN type de la
// couche d'accès, pas même `ReviewDecision`) : module indépendant du lot L2.
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM
// (`flutter test test/moderation_actions_test.dart`).
import 'package:flutter/foundation.dart';

import 'moderation_labels.dart';

// ── Boutons ──────────────────────────────────────────────────────────────────

/// Actions d'un élément de la file ou d'un ban automatique actif.
enum ReviewAction { detail, confirm, lift, apply, dismiss, purge }

/// Boutons d'un élément de la FILE (M94:1479-1511 ; validité serveur
/// M94:1562-1687) : un ban en revue se confirme ou se lève ; une demande à
/// examiner ou un refus à revoir s'applique ou s'écarte ; un type inconnu
/// n'a que « Détail ».
List<ReviewAction> actionsForQueueItem(String kind) => switch (kind) {
  'ban_en_revue' => const <ReviewAction>[
    ReviewAction.detail,
    ReviewAction.confirm,
    ReviewAction.lift,
  ],
  'a_examiner' || 'refus_a_revoir' => const <ReviewAction>[
    ReviewAction.detail,
    ReviewAction.apply,
    ReviewAction.dismiss,
  ],
  _ => const <ReviewAction>[ReviewAction.detail],
};

/// Ban AUTO actif vu depuis une liste (bannis, chaînes, pages) : confirm et
/// lift acceptent tout événement `action = 'ban'` ET `origin = 'auto'`
/// (M94:1564-1566). Un ban confirmé ne se reconfirme pas ; seule une chaîne
/// confirmée se purge. Rien pour un autre compte que le compte principal.
List<ReviewAction> actionsForActiveAutoBan({
  required String status,
  required String targetKind,
  required bool isOwner,
}) {
  if (!isOwner) return const <ReviewAction>[];
  return switch (status) {
    'en_revue' => const <ReviewAction>[
      ReviewAction.detail,
      ReviewAction.confirm,
      ReviewAction.lift,
    ],
    'confirme' => <ReviewAction>[
      ReviewAction.detail,
      ReviewAction.lift,
      if (targetKind == 'channel') ReviewAction.purge,
    ],
    _ => const <ReviewAction>[],
  };
}

/// Chemin du bouton « Débannir » (T3 : origine connue AVANT le clic).
enum UnbanPath { confirmManual, liftAuto, autoReservedToOwner }

/// Ban manuel → confirmation puis `profiles/unban` ; ban automatique →
/// levée (compte principal) ou bouton désactivé (autre admin).
UnbanPath unbanPathFor({required String origin, required bool isOwner}) {
  if (origin != 'auto') return UnbanPath.confirmManual;
  return isOwner ? UnbanPath.liftAuto : UnbanPath.autoReservedToOwner;
}

/// Cible d'une navigation « Ouvrir dans Modération » : le statut est FOURNI
/// par l'appelant (banned-list, channels/banned-list et blocked-pages/list
/// le portent).
@immutable
class ModerationFocus {
  const ModerationFocus({required this.eventId, this.status, this.targetKind});

  /// Événement à ouvrir en détail (`ban_event_id`).
  final int eventId;

  /// Statut connu du ban (`en_revue`, `confirme`…) ; null = inconnu.
  final String? status;

  /// `account`, `channel` ou `page` ; null = inconnu.
  final String? targetKind;

  @override
  bool operator ==(Object other) =>
      other is ModerationFocus &&
      other.eventId == eventId &&
      other.status == status &&
      other.targetKind == targetKind;

  @override
  int get hashCode => Object.hash(eventId, status, targetKind);
}

/// Boutons du détail ouvert par [f] : statut connu → [actionsForActiveAutoBan] ;
/// statut inconnu → « Détail » seulement (le serveur tranche ; jamais
/// « confirmé » supposé).
List<ReviewAction> actionsForFocus(ModerationFocus f, {required bool isOwner}) {
  final String? status = f.status;
  if (status == null) return const <ReviewAction>[ReviewAction.detail];
  return actionsForActiveAutoBan(
    status: status,
    targetKind: f.targetKind ?? '',
    isOwner: isOwner,
  );
}

/// Événement dont `banned_channels.ban_event_id` porte la ligne à purger :
/// confirm → [itemId] (l'événement revu, M94:1600-1601) ; apply →
/// [resultEventId] (nouvel événement ban, M94:1795-1807) ; null sinon.
int? purgeLookupEventId(
  String decision, {
  required int itemId,
  int? resultEventId,
}) => switch (decision) {
  'confirm' => itemId,
  'apply' => resultEventId,
  _ => null,
};

/// Page à afficher après le retrait d'éléments : recule d'une page si la
/// page courante devient vide et qu'elle n'est pas la première (sans
/// dépasser la dernière page d'après [total]).
int pageAfterRemoval({
  required int page,
  required int itemsLeftOnPage,
  required int total,
  required int pageSize,
}) {
  if (itemsLeftOnPage > 0 || page <= 0) return page < 0 ? 0 : page;
  int target = page - 1;
  if (pageSize > 0) {
    final int last = total <= 0 ? 0 : (total - 1) ~/ pageSize;
    if (target > last) target = last;
  }
  return target < 0 ? 0 : target;
}

// ── Résultats de review-decide ──────────────────────────────────────────────

/// Ton d'un message (couleur de la SnackBar).
enum OutcomeTone { success, info, warning, error }

/// Traduction d'une décision de revue pour l'écran.
@immutable
class DecisionOutcome {
  const DecisionOutcome({
    required this.tone,
    required this.message,
    this.reloadQueue = false,
    this.removeItem = false,
    this.offerPurge = false,
    this.uncertain = false,
  });

  final OutcomeTone tone;
  final String message;

  /// Relire la file (et les compteurs).
  final bool reloadQueue;

  /// Retirer l'élément de l'affichage.
  final bool removeItem;

  /// Chaîne confirmée / appliquée → proposer `channels/purge-auto`.
  final bool offerPurge;

  /// Issue inconnue : état relu.
  final bool uncertain;

  @override
  String toString() =>
      'DecisionOutcome($tone, $message, reload: $reloadQueue, remove: $removeItem, '
      'offerPurge: $offerPurge, uncertain: $uncertain)';
}

/// Message de rejeu : la réponse initiale a été perdue et la requête a été
/// rejouée (§3.3).
const String kReplayNoticeMessage =
    "Réponse initiale perdue : l'opération a probablement déjà été faite au premier "
    'essai. État relu.';

/// Rejeu : message de remplacement, ou null si la réponse est normale. Non
/// nul si [replayed] ET ([result] commence par `already_` OU [count] == 0).
String? replayNotice({required bool replayed, String? result, int? count}) {
  if (!replayed) return null;
  if ((result != null && result.startsWith('already_')) || count == 0) {
    return kReplayNoticeMessage;
  }
  return null;
}

/// Traduit une réponse 200 de `moderation/review-decide` (table §4.5).
DecisionOutcome outcomeFromResult({
  required String result,
  String? targetKind,
  List<String> reasons = const <String>[],
  String? previous,
  String? stillBanned,
  int? groupSize,
  bool replayed = false,
}) {
  final bool channel = targetKind == 'channel';
  final DecisionOutcome base = switch (result) {
    'confirmed' => DecisionOutcome(
      tone: OutcomeTone.success,
      message: 'Bannissement confirmé.',
      reloadQueue: true,
      removeItem: true,
      offerPurge: channel,
    ),
    'already_confirmed' => DecisionOutcome(
      tone: OutcomeTone.success,
      message: 'Déjà confirmé.',
      reloadQueue: true,
      removeItem: true,
      offerPurge: channel,
    ),
    'lifted' when stillBanned != null && stillBanned.isNotEmpty =>
      const DecisionOutcome(
        tone: OutcomeTone.warning,
        message: 'Ban automatique levé ; le ban MANUEL reste en vigueur.',
        reloadQueue: true,
        removeItem: true,
      ),
    'lifted' => const DecisionOutcome(
      tone: OutcomeTone.success,
      message:
          'Bannissement levé. Les partages antérieurs sont exemptés du ban automatique.',
      reloadQueue: true,
      removeItem: true,
    ),
    'already_lifted' => const DecisionOutcome(
      tone: OutcomeTone.success,
      message: 'Déjà levé.',
      reloadQueue: true,
      removeItem: true,
    ),
    'applied' => DecisionOutcome(
      tone: OutcomeTone.success,
      message: 'Bannissement appliqué (statut confirmé).',
      reloadQueue: true,
      removeItem: true,
      offerPurge: channel,
    ),
    'already_banned' => const DecisionOutcome(
      tone: OutcomeTone.info,
      message: 'Cible déjà bannie : demande close.',
      reloadQueue: true,
      removeItem: true,
    ),
    'refused' => DecisionOutcome(
      tone: OutcomeTone.info,
      message: _refusedMessage(reasons),
      reloadQueue: true,
      removeItem: true,
    ),
    'dismissed' => DecisionOutcome(
      tone: OutcomeTone.success,
      message:
          'Demande écartée (${groupSize ?? 1} événement(s) du groupe). '
          'Partages antérieurs exemptés.',
      reloadQueue: true,
      removeItem: true,
    ),
    'already_resolved' => DecisionOutcome(
      tone: OutcomeTone.info,
      message:
          'Déjà traitée (précédemment : ${previousDecisionLabel(previous)}).',
      reloadQueue: true,
      removeItem: true,
    ),
    _ => DecisionOutcome(
      tone: OutcomeTone.warning,
      message: 'Résultat inattendu : $result. État relu.',
      reloadQueue: true,
    ),
  };
  final String? notice = replayNotice(replayed: replayed, result: result);
  if (notice == null) return base;
  return DecisionOutcome(
    tone: OutcomeTone.info,
    message: notice,
    reloadQueue: true,
    removeItem: base.removeItem,
    offerPurge: base.offerPurge,
  );
}

String _refusedMessage(List<String> reasons) {
  if (reasons.contains('profil_absent')) {
    return 'Rien appliqué : profil supprimé. Demande close.';
  }
  if (reasons.contains('exempte_apres_levee')) {
    return "Rien appliqué : partage antérieur à une levée ou une mise à l'écart. "
        'Demande close.';
  }
  // Raison non prévue par la conception : libellés lisibles.
  if (reasons.isEmpty) return 'Rien appliqué. Demande close.';
  return 'Rien appliqué : ${reasonLabels(reasons).join(', ')}. Demande close.';
}

/// Traduit une ERREUR de `moderation/review-decide` (hors 401, traité par
/// l'appelant : déconnexion). [uncertain] (erreur réseau, délai, 5xx) passe
/// avant tout le reste.
DecisionOutcome outcomeFromError({
  required int? statusCode,
  String? result,
  int? distinctContents,
  int? threshold,
  required String message,
  bool uncertain = false,
}) {
  if (uncertain) {
    return const DecisionOutcome(
      tone: OutcomeTone.warning,
      message:
          "Réponse du serveur non reçue : l'état a été relu, vérifiez le résultat.",
      reloadQueue: true,
      uncertain: true,
    );
  }
  if (statusCode == 409) {
    return switch (result) {
      'not_applicable' => const DecisionOutcome(
        tone: OutcomeTone.warning,
        message: "Décision non applicable à cet élément : l'état a changé.",
        reloadQueue: true,
      ),
      'ban_not_active' => const DecisionOutcome(
        tone: OutcomeTone.warning,
        message: "Ce bannissement n'est plus actif.",
        reloadQueue: true,
        removeItem: true,
      ),
      'below_threshold' => DecisionOutcome(
        tone: OutcomeTone.warning,
        message:
            'Seuil non atteint : ${distinctContents ?? 0}/${threshold ?? 2} contenus '
            "distincts de cette chaîne sur 90 jours. Rien n'a été appliqué ; la demande "
            "reste dans la file (vous pouvez l'écarter).",
      ),
      // 409 sans code connu : message du serveur, état relu.
      _ => DecisionOutcome(
        tone: OutcomeTone.warning,
        message: message,
        reloadQueue: true,
      ),
    };
  }
  return switch (statusCode) {
    404 => const DecisionOutcome(
      tone: OutcomeTone.warning,
      message: 'Événement introuvable.',
      reloadQueue: true,
      removeItem: true,
    ),
    403 => const DecisionOutcome(
      tone: OutcomeTone.error,
      message: 'Réservé au compte principal.',
    ),
    _ => DecisionOutcome(tone: OutcomeTone.error, message: message),
  };
}

// ── Débans (T3, T10) ────────────────────────────────────────────────────────

/// Issue d'un déban (compte ou chaîne).
enum UnbanKind { lifted, notBanned, autoBan, notFound, failure, sessionExpired }

@immutable
class UnbanOutcome {
  const UnbanOutcome(
    this.kind, {
    this.banEventId,
    this.message,
    this.replayed = false,
  });

  final UnbanKind kind;

  /// Événement du ban automatique (409 `auto_ban_use_review`).
  final int? banEventId;

  /// Message du serveur (échec) ou texte fixe (introuvable).
  final String? message;

  /// Réponse obtenue après un rejeu (revue P4b-3, INF-01) : un « n'était
  /// plus banni » / « déjà débannie » vient alors très probablement de la
  /// levée faite au 1er essai → message de rejeu ([kReplayNoticeMessage]).
  final bool replayed;

  @override
  String toString() =>
      'UnbanOutcome($kind, $banEventId, $message, rejeu: $replayed)';
}

/// Résultat 200 : `lifted` | `not_banned` (compte) ; `lifted` | `not_found`
/// (chaîne) ; [replayed] : réponse obtenue après un rejeu.
UnbanOutcome unbanOutcomeFromResult(String result, {bool replayed = false}) =>
    switch (result) {
      'lifted' => UnbanOutcome(UnbanKind.lifted, replayed: replayed),
      'not_banned' => UnbanOutcome(UnbanKind.notBanned, replayed: replayed),
      'not_found' => UnbanOutcome(UnbanKind.notFound, replayed: replayed),
      _ => UnbanOutcome(
        UnbanKind.failure,
        message: 'Résultat inattendu : $result.',
      ),
    };

/// Erreur : 409 + `auto_ban_use_review` → ban automatique ([banEventId]) ;
/// 404 → « Profil introuvable. » ; le reste → échec avec [message].
UnbanOutcome unbanOutcomeFromError({
  required int statusCode,
  String? result,
  int? banEventId,
  required String message,
}) {
  if (statusCode == 409 && result == 'auto_ban_use_review') {
    return UnbanOutcome(UnbanKind.autoBan, banEventId: banEventId);
  }
  if (statusCode == 404) {
    return const UnbanOutcome(
      UnbanKind.notFound,
      message: 'Profil introuvable.',
    );
  }
  return UnbanOutcome(UnbanKind.failure, message: message);
}

/// Message d'un déban pour la SnackBar ou le dialogue.
String unbanMessage(
  UnbanOutcome o, {
  required String name,
  required bool channel,
}) => switch (o.kind) {
  // INF-01 : « plus banni » / « déjà débannie » obtenu par un rejeu.
  UnbanKind.notBanned ||
  UnbanKind.notFound when o.replayed => kReplayNoticeMessage,
  UnbanKind.lifted => channel ? 'Chaîne $name débannie.' : '$name débanni.',
  UnbanKind.notBanned =>
    channel ? "Chaîne $name n'était plus bannie." : "$name n'était plus banni.",
  UnbanKind.notFound =>
    channel ? 'Chaîne déjà débannie.' : (o.message ?? 'Profil introuvable.'),
  UnbanKind.autoBan =>
    'Bannissement automatique : levée réservée au compte principal (menu Modération).',
  UnbanKind.failure => o.message ?? 'Débannissement impossible.',
  UnbanKind.sessionExpired => 'Session expirée.',
};

// ── Lot de bans (T6) ────────────────────────────────────────────────────────

/// Bilan d'un lot de bans.
@immutable
class BanBatchReport {
  const BanBatchReport({
    this.applied = 0,
    this.alreadyBanned = 0,
    this.errors = const <({String id, String message})>[],
    this.stoppedBySession = false,
  });

  final int applied;
  final int alreadyBanned;
  final List<({String id, String message})> errors;

  /// Vrai si le lot a été interrompu par une session expirée (401).
  final bool stoppedBySession;
}

/// « 3 compte(s) banni(s), 1 déjà banni(s), 2 erreur(s). »
String banBatchSummary(BanBatchReport r) =>
    '${r.applied} compte(s) banni(s), ${r.alreadyBanned} déjà banni(s), '
    '${r.errors.length} erreur(s).';

// ── channels/purge-auto ─────────────────────────────────────────────────────

/// Texte de l'aperçu de purge d'une chaîne automatique. Les compteurs par
/// détection / par identifiant n'existent qu'en aperçu (M94:2223-2228).
String purgePreviewText(
  int pending,
  int? byDetection,
  int? byChannelId,
  int published,
) {
  final StringBuffer b = StringBuffer();
  if (pending > 0) {
    b.write(
      '$pending suggestion(s) en attente seront rejetées (motif « Chaîne bannie »)',
    );
    if (byDetection != null && byChannelId != null) {
      b.write(
        ' : $byDetection trouvée(s) par détection, $byChannelId par identifiant de chaîne.',
      );
    } else {
      b.write('.');
    }
  } else {
    b.write('Aucune suggestion en attente à rejeter.');
  }
  if (published > 0) {
    b.write(
      ' $published contenu(s) déjà publié(s) (liste ci-dessous ; retrait manuel).',
    );
  } else {
    b.write(' Aucun contenu déjà publié.');
  }
  return b.toString();
}

/// « N suggestion(s) rejetée(s) sur P en attente. »
String purgeResultText(int purged, int pending) =>
    '$purged suggestion(s) rejetée(s) sur $pending en attente.';

// ── Réglages (S-01, S-07, UX-01) ────────────────────────────────────────────

/// Seulement les plafonds MODIFIÉS, avec les clés de `settings-set` (Map
/// vide = rien à envoyer).
Map<String, int> ceilingsPatch({
  required int oldHour,
  required int oldDay,
  required int newHour,
  required int newDay,
}) => <String, int>{
  if (newHour != oldHour) 'max_auto_bans_per_hour': newHour,
  if (newDay != oldDay) 'max_auto_bans_per_day': newDay,
};

/// Hausses de plafond à confirmer, ex. `['par heure : 3 → 100']`.
List<String> ceilingIncreases({
  required int oldHour,
  required int oldDay,
  required int newHour,
  required int newDay,
}) => <String>[
  if (newHour > oldHour) 'par heure : $oldHour → $newHour',
  if (newDay > oldDay) 'par jour : $oldDay → $newDay',
];

/// Compteurs du dialogue « Allumer » / « Réarmer » et avertissement si un
/// plafond est déjà atteint (les compteurs ne sont PAS remis à zéro,
/// M94:1307-1319 : le disjoncteur se redéclencherait au prochain ban
/// éligible).
({String counters, String? warning}) rearmWarning({
  required int hour,
  required int maxHour,
  required int day,
  required int maxDay,
}) => (
  counters: '$hour/$maxHour (1 h) · $day/$maxDay (24 h)',
  warning: hour >= maxHour || day >= maxDay
      ? 'Un plafond est déjà atteint : le disjoncteur se redéclenchera au prochain '
            "ban éligible. Relevez d'abord le plafond."
      : null,
);

/// Différences entre la liste d'empreintes chargée et celle à envoyer
/// (triées, sans doublon).
({List<String> added, List<String> removed}) rulesDiff(
  List<String> before,
  List<String> after,
) {
  final Set<String> b = before.toSet();
  final Set<String> a = after.toSet();
  return (
    added: a.difference(b).toList()..sort(),
    removed: b.difference(a).toList()..sort(),
  );
}
