// Pur (VM) — règles de l'écran « Modération » (P4b-3, lot L7, conception
// §6.2-§6.8) : pagination, cellules du journal et des refus (masquage des
// clés, groupe, liens, acteur, motif), filtres du journal, puces des refus
// des 24 h, plafonds, messages des réglages (interrupteur, disjoncteur,
// compteurs, erreurs), différences d'empreintes, purge des preuves, id de
// ligne pour la purge d'une chaîne, actions d'une page bloquée.
//
// Les textes du serveur qui peuvent venir d'un tiers (clé de cible, hôte,
// nom d'acteur, motif, `updated_by`) passent par `oneLinePreview` (caractères
// cachés rendus visibles, une ligne, bornés). Les dates sont formatées par
// l'appelant (heure locale, `formatModerationDate`) et reçues en texte.
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM
// (`flutter test test/moderation_screen_rules_test.dart`).
library;

import 'ids.dart';
import 'models/moderation.dart';
import 'moderation_actions.dart';
import 'moderation_labels.dart';
import 'moderation_text.dart';

// ── Libellés fixes de l'écran ────────────────────────────────────────────────

/// Titre de l'en-tête.
const String kModerationScreenTitle = 'Modération des bans automatiques';

/// Libellés EXACTS des 5 onglets, dans l'ordre.
const List<String> kModerationTabLabels = <String>[
  'File de revue',
  'Refus',
  'Réglages',
  'Pages bloquées',
  'Journal',
];

/// Index des onglets.
const int kQueueTabIndex = 0;
const int kRefusalsTabIndex = 1;
const int kSettingsTabIndex = 2;
const int kBlockedPagesTabIndex = 3;
const int kEventsTabIndex = 4;

/// Mode aperçu (texte de `admin_users_screen.dart`).
const String kModerationDemoMessage = 'Mode démo : pas de connexion Supabase.';

/// État 403.
const String kModerationForbiddenMessage = 'Réservé au compte principal.';

/// File vide.
const String kQueueEmptyMessage = 'File vide : aucune décision en attente.';

/// Id de ligne introuvable pour la purge d'une chaîne (§6.4 e).
const String kPurgeRowNotFoundMessage =
    'Ligne de chaîne introuvable : purgez depuis Chaînes YT → Bannir.';

/// Onglet « Refus ».
const String kRefusalsTitle = 'Refus du détecteur — 24 dernières heures';
const String kNoRefusals24hMessage = 'Aucun refus en 24 h.';
const String kRefusalsCountTooltip =
    'Un refus compte une fois par raison : un refus à 3 raisons compte 3 fois.';
const String kDetectorOnlyLabel = 'Détecteur seulement';
const String kRefusalsReadOnlyNote =
    'Lecture seule : un refus « applicable » se décide depuis la file de revue '
    '(élément de tête).';
const String kNoRefusalsMessage = 'Aucun refus.';

/// Onglet « Pages bloquées ».
const String kBlockedPagesHelp =
    'Pages bloquées par le ban automatique (URL exacte, jamais un site '
    'entier). Aucun blocage manuel n\'existe.';
const String kNoBlockedPagesMessage = 'Aucune page bloquée.';

/// Onglet « Journal ».
const String kNoEventsMessage = 'Aucun événement pour ces filtres.';

/// Réglages : textes fixes.
const String kAutoBanSwitchTitle = 'Ban automatique';
const String kAutoBanOffSubtitle =
    'Éteint : toute demande propre part en « À examiner » (ban automatique '
    'éteint).';
const String kAutoBanOnSubtitle =
    'Allumé : les demandes propres sont bannies en revue, dans la limite des '
    'plafonds.';
const String kTurnOnTitle = 'Allumer le ban automatique ?';
const String kTurnOnCheckbox =
    'Je comprends que des bans automatiques pourront être posés sans moi.';
const String kTurnOnButton = 'Allumer';
const String kTurnOffTitle = 'Éteindre le ban automatique ?';
const String kTurnOffMessage =
    'Les demandes propres iront dans « À examiner ».';
const String kTurnOffButton = 'Éteindre';
const String kRearmTitle =
    'Réarmer le disjoncteur et RALLUMER le ban automatique ?';
const String kRearmCheckbox =
    "J'ai examiné la cause du déclenchement ; le ban automatique sera rallumé.";
const String kRearmButton = 'Réarmer';
const String kBreakerNormalText = 'Disjoncteur : normal';
const String kCeilingHourLabel = 'Bans automatiques par heure (0 à 100)';
const String kCeilingDayLabel = 'Bans automatiques par jour (0 à 1000)';
const String kSaveCeilingsButton = 'Enregistrer les plafonds';
const String kCeilingZeroWarning =
    '0 : le disjoncteur se déclenche au premier ban éligible.';
const String kCeilingIncreaseTitle = 'Relever les plafonds ?';
const String kCeilingIncreaseButton = 'Relever';
const String kRulesFieldLabel =
    'Ajouter une empreinte (64 caractères hexadécimaux)';
const String kRulesAddButton = 'Ajouter';
const String kRulesSaveButton = 'Enregistrer la liste';
const String kRulesChangedOnServerMessage =
    'La liste a changé sur le serveur depuis son chargement.';
const String kRulesReloadButton = 'Recharger';
const String kRulesEmptyListWarning =
    'Liste vide : plus aucun ban automatique ne sera accepté (refus '
    '« empreinte non autorisée »).';
const String kRulesNote =
    "Toute modification du fichier de règles change son empreinte : l'ajouter "
    'ici après mesure à blanc.';
const String kRulesSaveTitle = 'Enregistrer la liste des empreintes ?';
const String kRulesSaveConfirmButton = 'Enregistrer';
const String kPurgeDaysPrefix = 'Purger les preuves de plus de';
const String kPurgeDaysSuffix = 'jours';
const String kEvidencePreviewButton = 'Aperçu';
const String kEvidencePurgeKeepsJournal =
    "Le journal des bans n'est pas touché.";
const String kNothingChangedMessage = 'Aucun changement.';

/// Messages de succès des écritures des réglages (non fixés par la
/// conception).
const String kTurnedOnMessage = 'Ban automatique allumé.';
const String kTurnedOffMessage = 'Ban automatique éteint.';
const String kRearmedMessage = 'Disjoncteur réarmé : ban automatique rallumé.';
const String kCeilingsSavedMessage = 'Plafonds enregistrés.';
const String kRulesSavedMessage = 'Liste des empreintes enregistrée.';

/// Tailles de page (§6.3, §6.5, §6.7, §6.8).
const int kReviewPageSize = 50;
const int kRefusalsPageSize = 50;
const int kEventsPageSize = 50;
const int kBlockedPagesPageSize = 100;

/// Bornes des plafonds (moderation.ts : 0-100 par heure, 0-1000 par jour).
const int kMaxPerHourLimit = 100;
const int kMaxPerDayLimit = 1000;

// ── Pagination ───────────────────────────────────────────────────────────────

/// Nombre de pages (au moins 1).
int totalPages(int total, int pageSize) {
  if (pageSize <= 0 || total <= 0) return 1;
  return (total + pageSize - 1) ~/ pageSize;
}

/// « Page X / N (a–b sur T) » ; [range] faux → « Page X / N ». Total nul →
/// « Page 1 / 1 (0 sur 0) ».
String paginationLabel({
  required int page,
  required int pageSize,
  required int total,
  bool range = true,
}) {
  final int pages = totalPages(total, pageSize);
  final int shown = (page < 0 ? 0 : page) + 1;
  final String head = 'Page $shown / $pages';
  if (!range) return head;
  if (total <= 0) return '$head (0 sur 0)';
  final int first = page * pageSize + 1;
  final int last = ((page + 1) * pageSize).clamp(0, total);
  return '$head ($first–$last sur $total)';
}

// ── Cellules des événements (refus, journal) ─────────────────────────────────

/// Cible d'un événement (§6.5) : clé masquée → « [hôte révélé, sinon
/// 'hôte inconnu'] · empreinte [8 hex]… » ; clé absente → « — » ; compte →
/// id court ; autre → clé révélée (60 points de code).
String eventTargetText(BanEvent e) {
  if (e.targetKeyMasked) {
    final String? host = e.targetHost;
    final String hostText = host == null || host.isEmpty
        ? 'hôte inconnu'
        : oneLinePreview(host, max: 60);
    final String? sha = e.targetKeySha256;
    final String shaText = sha == null || sha.isEmpty
        ? 'empreinte —'
        : 'empreinte ${oneLinePreview(String.fromCharCodes(sha.runes.take(8)))}…';
    return '$hostText · $shaText';
  }
  final String? key = e.targetKey;
  if (key == null || key.isEmpty) return '—';
  if (e.targetKind == 'account') return oneLinePreview(shortId(key));
  return oneLinePreview(key, max: 60);
}

/// Libellé court de la cible d'un événement pour les dialogues de décision
/// (`<cible>`) : compte → « Compte [id court] » ; chaîne → « [plateforme] ·
/// [clé] » ; page → URL ; tout révélé.
String eventTargetLabel(BanEvent e) {
  final String key = e.targetKey ?? '';
  switch (e.targetKind) {
    case 'account':
      return key.isEmpty ? 'Compte' : 'Compte ${oneLinePreview(shortId(key))}';
    case 'channel':
      return '${platformLabel(e.platform)} · '
          '${key.isEmpty ? '—' : oneLinePreview(key, max: 60)}';
    default:
      return key.isEmpty ? '—' : oneLinePreview(key, max: 60);
  }
}

/// Groupe (§6.5) : « tête » si l'événement n'a pas de tête, sinon
/// « membre de #[id] ».
String eventGroupText(BanEvent e) {
  final int? head = e.groupEventId;
  return head == null ? 'tête' : 'membre de #$head';
}

/// Liens (§6.8) : « réf. #x », « groupe #y » ; aucun → « — ».
String eventLinksText(BanEvent e) {
  final List<String> parts = <String>[
    if (e.refEventId != null) 'réf. #${e.refEventId}',
    if (e.groupEventId != null) 'groupe #${e.groupEventId}',
  ];
  return parts.isEmpty ? '—' : parts.join(' · ');
}

/// Acteur (§6.8) : libellé du type d'acteur + nom révélé (40 points de
/// code) s'il est connu.
String eventActorText(BanEvent e) {
  final String kind = actorKindLabel(e.actorKind);
  final String? name = e.actorUsername;
  if (name == null || name.isEmpty) return kind;
  return '$kind · ${oneLinePreview(name, max: 40)}';
}

/// Motif (§6.8) : `note` révélée (60 points de code) ; absent → « — ».
String eventNoteText(BanEvent e) {
  final String? note = e.note;
  if (note == null || note.isEmpty) return '—';
  return oneLinePreview(note, max: 60);
}

/// Filtre local « Détecteur seulement » (§6.5) : masque les refus de la
/// revue (`actor_kind == 'revue'`), events-list mélangeant les deux.
List<BanEvent> filterDetectorOnly(List<BanEvent> items, bool detectorOnly) {
  if (!detectorOnly) return items;
  return <BanEvent>[
    for (final BanEvent e in items)
      if (e.actorKind != 'revue') e,
  ];
}

/// Une puce « [libellé] : N » des refus des 24 h.
typedef RefusalCount = ({String code, String label, int count});

/// Refus des 24 h par raison, triés par N décroissant puis libellé ; les
/// comptes nuls sont ignorés.
List<RefusalCount> refusalCounts(Map<String, int> refused24h) {
  final List<RefusalCount> out = <RefusalCount>[
    for (final MapEntry<String, int> e in refused24h.entries)
      if (e.value > 0) (code: e.key, label: reasonLabel(e.key), count: e.value),
  ];
  out.sort((RefusalCount a, RefusalCount b) {
    final int c = b.count.compareTo(a.count);
    return c != 0 ? c : a.label.compareTo(b.label);
  });
  return out;
}

/// Texte d'une puce des refus : « [libellé] : N ».
String refusalChipText(RefusalCount r) => '${r.label} : ${r.count}';

// ── Filtres du journal (§6.8) ────────────────────────────────────────────────

/// Choix « Type de cible » : null = Tous.
const List<(String?, String)> kEventTargetKindChoices = <(String?, String)>[
  (null, 'Tous'),
  ('account', 'Compte'),
  ('channel', 'Chaîne'),
  ('page', 'Page'),
];

/// Choix « Action » : null = Toutes, puis les 9 actions du journal.
List<(String?, String)> eventActionChoices() => <(String?, String)>[
  (null, 'Toutes'),
  for (final MapEntry<String, String> e in kEventActionLabels.entries)
    (e.key, e.value),
];

/// « Clé exacte » : coupée ; UUID → minuscules ; vide → null (aucun filtre).
String? normalizeEventKeyFilter(String raw) {
  final String t = raw.trim();
  if (t.isEmpty) return null;
  return isUuid(t) ? t.toLowerCase() : t;
}

// ── Réglages : interrupteur, disjoncteur, compteurs (§6.6) ──────────────────

/// Pastille de l'en-tête : « Ban automatique : allumé » / « éteint ».
String autoBanPillLabel(bool enabled) =>
    'Ban automatique : ${enabled ? 'allumé' : 'éteint'}';

/// Pastille de l'en-tête : « File : N ».
String queueSizePillLabel(int n) => 'File : $n';

/// Sous-titre de l'interrupteur.
String autoBanSubtitle(bool enabled) =>
    enabled ? kAutoBanOnSubtitle : kAutoBanOffSubtitle;

/// Texte du dialogue fort « Allumer ».
String turnOnText({required int maxPerHour, required int maxPerDay}) =>
    'Des comptes, chaînes et pages pourront être bannis SANS intervention '
    'humaine (statut « en revue »), dans la limite de $maxPerHour/heure et '
    "$maxPerDay/jour. Vision2 n'envoie pas encore de demandes de ban (étape "
    "P4b-4) : pour l'instant, l'interrupteur n'a d'effet que sur les demandes "
    'reçues.';

/// Encart du disjoncteur ouvert : « Disjoncteur déclenché le [date] :
/// [motif] (événement #[id]). Le ban automatique a été coupé. ».
String breakerBoxText({required String date, String? reason, int? eventId}) =>
    'Disjoncteur déclenché le $date : ${breakerReasonLabel(reason)}'
    '${eventId == null ? '' : ' (événement #$eventId)'}. '
    'Le ban automatique a été coupé.';

/// Texte du dialogue fort « Réarmer » : motif et date.
String rearmText({required String date, String? reason}) =>
    'Disjoncteur déclenché le $date : ${breakerReasonLabel(reason)}. Réarmer '
    'rallume le ban automatique (même effet que « Allumer ») ; les compteurs '
    'ne sont pas remis à zéro.';

/// Lien « Voir l'événement #[id] ».
String viewEventLabel(int eventId) => "Voir l'événement #$eventId";

/// Compteurs (lecture) : « Bans automatiques : h dans l'heure (plafond H),
/// d sur 24 h (plafond D) ».
String settingsCountersText(ModerationSettings s) =>
    "Bans automatiques : ${s.autoBansLastHour} dans l'heure (plafond "
    '${s.maxPerHour}), ${s.autoBansLastDay} sur 24 h (plafond ${s.maxPerDay})';

/// « Seuil des chaînes : 2 contenus distincts sur 90 jours ».
String chainThresholdText(ModerationSettings s) =>
    'Seuil des chaînes : ${s.chainThreshold} contenus distincts sur '
    '${s.chainWindowDays} jours';

/// Auteur de la dernière modification : `disjoncteur` → « le disjoncteur » ;
/// sinon le nom révélé (40 points de code) ; absent → « — ».
String updatedByText(String? by) {
  if (by == null || by.isEmpty) return '—';
  if (by == 'disjoncteur') return 'le disjoncteur';
  return oneLinePreview(by, max: 40);
}

/// « Dernière modification : [date] par [auteur] ».
String lastModifiedText({required String date, String? by}) =>
    'Dernière modification : $date par ${updatedByText(by)}';

/// Message d'une erreur 400 des réglages : message du serveur, puis les
/// champs refusés traduits SEULEMENT si la liste n'est pas vide (branche SQL
/// inatteignable par l'EF, décodée par sécurité — v2, C-02).
String settingsErrorText(String message, List<String> reasons) {
  if (reasons.isEmpty) return message;
  return '$message (${reasons.map(settingsFieldLabel).join(', ')})';
}

// ── Plafonds ─────────────────────────────────────────────────────────────────

/// Plafond saisi : entier de 0 à [max] (chiffres seulement, espaces autour
/// ignorés) ; sinon message.
({int? value, String? error}) parseCeiling(String raw, {required int max}) {
  final String s = raw.trim();
  final int? n = RegExp(r'^\d{1,9}$').hasMatch(s) ? int.parse(s) : null;
  if (n == null || n > max) {
    return (value: null, error: 'Entier de 0 à $max attendu.');
  }
  return (value: n, error: null);
}

/// Avertissement sous un champ de plafond : valeur 0 → le disjoncteur se
/// déclenche au premier ban éligible (M94:1310-1319).
String? ceilingWarning(String raw) {
  final ({int? value, String? error}) p = parseCeiling(raw, max: 1 << 30);
  return p.value == 0 ? kCeilingZeroWarning : null;
}

/// Texte de la confirmation d'une hausse : « par heure : 3 → 100 ; … Plus
/// de bans automatiques pourront être posés sans vous avant que le
/// disjoncteur ne coupe. ».
String ceilingIncreaseText(List<String> increases) =>
    '${increases.join(' ; ')}. Plus de bans automatiques pourront être posés '
    'sans vous avant que le disjoncteur ne coupe.';

// ── Empreintes autorisées ────────────────────────────────────────────────────

String _normSha(String s) => s.trim().toLowerCase();

/// Même ensemble d'empreintes (coupées, en minuscules ; ordre et doublons
/// ignorés).
bool sameRulesList(List<String> a, List<String> b) {
  final Set<String> sa = a.map(_normSha).toSet();
  final Set<String> sb = b.map(_normSha).toSet();
  return sa.length == sb.length && sa.containsAll(sb);
}

/// Forme courte d'une empreinte : 8 premiers caractères suivis de « … ».
String shortSha(String sha) {
  final String s = _normSha(sha);
  return s.length <= 8 ? s : '${s.substring(0, 8)}…';
}

/// Lignes du dialogue de différences : avertissement si la liste envoyée
/// est vide, puis « N ajoutée(s) : » / « + a1b2c3d4… » et « M retirée(s) : »
/// / « − e5f6a7b8… » (8 premiers hex).
List<String> rulesDiffLines(List<String> before, List<String> after) {
  final ({List<String> added, List<String> removed}) d = rulesDiff(
    before.map(_normSha).toList(),
    after.map(_normSha).toList(),
  );
  return <String>[
    if (after.isEmpty) kRulesEmptyListWarning,
    if (d.added.isNotEmpty) ...<String>[
      '${d.added.length} ajoutée(s) :',
      for (final String s in d.added) '+ ${shortSha(s)}',
    ],
    if (d.removed.isNotEmpty) ...<String>[
      '${d.removed.length} retirée(s) :',
      for (final String s in d.removed) '− ${shortSha(s)}',
    ],
  ];
}

/// Compteur « N/50 ».
String rulesCounterText(int n) => '$n/$kMaxAllowedRulesSha';

// ── Preuves anciennes ────────────────────────────────────────────────────────

/// Résultat de l'aperçu de purge des preuves.
String evidencePreviewText(int count) =>
    '$count preuve(s) seraient supprimées (les éléments encore dans la file '
    "sont exclus ; le nombre peut changer à l'application).";

/// Bouton « Purger N preuve(s) ».
String evidencePurgeButtonLabel(int count) => 'Purger $count preuve(s)';

/// Titre de la confirmation « Supprimer définitivement N preuve(s) ? ».
String evidencePurgeConfirmTitle(int count) =>
    'Supprimer définitivement $count preuve(s) ?';

/// Bilan de la purge : message de rejeu (rejeu à 0, UX-02) ou « N
/// preuve(s) supprimée(s). ».
String evidencePurgedText(EvidencePurgeResult r) =>
    replayNotice(replayed: r.replayed, count: r.count) ??
    '${r.count} preuve(s) supprimée(s).';

// ── Purge d'une chaîne après décision (§6.4 e) ───────────────────────────────

/// Id de ligne `banned_channels` connu d'avance : `channel_row_id` de
/// l'élément, seulement pour une CONFIRMATION (il désigne la ligne jointe à
/// l'événement revu, 0096). Pour `apply`, la ligne est créée par la décision
/// → recherche par `réponse.event_id` (null ici).
int? purgeRowIdFromItem({required String decision, int? channelRowId}) {
  if (decision != 'confirm') return null;
  final int? id = channelRowId;
  return id != null && id > 0 ? id : null;
}

// ── Pages bloquées (§6.7) ────────────────────────────────────────────────────

/// Actions d'une page bloquée : aucune sans `ban_event_id` ; sinon
/// `actionsForActiveAutoBan(status, 'page', isOwner)`.
List<ReviewAction> blockedPageActions(BlockedPage p, {required bool isOwner}) {
  if (p.banEventId == null) return const <ReviewAction>[];
  return actionsForActiveAutoBan(
    status: p.status,
    targetKind: 'page',
    isOwner: isOwner,
  );
}
