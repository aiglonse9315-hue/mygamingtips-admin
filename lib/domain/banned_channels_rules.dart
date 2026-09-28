// Pur (VM) — panneau des chaînes bannies (P4b-3, lot L8, T10, conception
// §6.12) : colonnes et cellules du tableau, bouton de fin de ligne selon
// l'origine CONNUE avant le clic, contrôle du formulaire de ban, textes du
// rapport de ban selon `result`, issue d'un déban et d'une levée.
//
// - ligne MANUELLE (y compris convertie : handle technique `auto:<clé>`) →
//   « Débannir » (confirmation, `channels/unban`) ;
// - ligne AUTO, compte principal → `actionsForActiveAutoBan(status,
//   'channel', true)` (Détail, Confirmer, Lever, Purger) sur `ban_event_id` ;
// - ligne AUTO, autre admin → « Débannir » DÉSACTIVÉ avec explication.
//
// Texte non fiable (clé de chaîne, nom affiché, motif, auteur, titres et URL
// des contenus publiés) : rendu par `oneLinePreview` / `revealInvisibles`
// (caractères cachés visibles), jamais un lien.
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM
// (`flutter test test/banned_channels_rules_test.dart`).
import 'package:flutter/foundation.dart';

import 'models/banned_channel.dart';
import 'moderation_actions.dart';
import 'moderation_labels.dart';
import 'moderation_text.dart';

// ── Textes fixes ─────────────────────────────────────────────────────────────

/// Colonnes du tableau des chaînes bannies (§6.12).
const List<String> kBannedChannelColumns = <String>[
  'Chaîne',
  'Plateforme',
  'État',
  'Catégorie',
  'Motif',
  'Date',
  'Par',
  'Actions',
];

/// Texte d'aide sous le titre du panneau (§6.12, remplace BCP:282-287).
const String kBannedChannelsHelp =
    'Bannir une chaîne rejette ses suggestions en attente (motif « Chaîne '
    'bannie ») ; les contenus déjà publiés sont signalés dans le rapport '
    '(retrait manuel). Les lignes « Auto » viennent du ban automatique : seul '
    'le compte principal peut les confirmer, les lever ou purger leurs '
    'suggestions.';

/// Formulaire incomplet (texte existant, BCP:141).
const String kChannelBanRequiredMessage = 'URL/handle et motif sont requis.';

/// État d'une ligne manuelle issue d'un ban automatique (handle `auto:…`).
const String kConvertedChannelStateLabel = "Manuel (issu d'un ban auto)";

/// Pastille ajoutée quand une intention de ban humain est enregistrée sur
/// une ligne automatique (`manual_event_id`).
const String kManualIntentLabel = '+ intention manuelle';

/// Infobulle de la pastille [kManualIntentLabel].
const String kManualIntentTooltip =
    'Un ban humain est enregistré pour cette chaîne : si le ban automatique '
    'est levé, la ligne devient manuelle et la chaîne reste bannie.';

/// Levée d'un ban automatique alors qu'une intention manuelle existe
/// (`still_banned`, M94:1646-1656 : la ligne est CONVERTIE, pas supprimée).
const String kChannelLiftStillBannedMessage =
    'Ban automatique levé : la ligne devient manuelle (le ban manuel reste en '
    'vigueur).';

/// Suffixe des SnackBars après un ban ou un déban (liste noire des bots).
const String kBotsSyncNotice =
    'Les bots synchroniseront la liste noire au prochain cycle.';

/// Rapport `updated` : ligne manuelle existante mise à jour.
const String kBanReportUpdatedText = 'Motif et catégorie remplacés.';

/// Titre du rapport `auto_en_revue`.
const String kBanReportAutoTitle = 'Chaîne déjà bannie automatiquement';

/// Rapport sans contenu publié.
const String kBanReportNoPublishedText =
    'Aucun contenu publié connu pour cette chaîne.';

/// Nombre maximal de contenus publiés listés dans le rapport (le bouton
/// « Retirer aussi… » annonce le nombre total).
const int kBanReportPublishedShown = 20;

// ── Cellules du tableau ──────────────────────────────────────────────────────

/// Vrai si la ligne porte le handle TECHNIQUE `auto:<clé>` (ligne auto ou
/// convertie) : la « Chaîne » est une clé, affichée en chasse fixe.
bool isChannelKeyRow(BannedChannel c) => c.handle.startsWith('auto:');

/// Libellé de la colonne « État » : « Auto — en revue », « Auto — confirmé »,
/// « Manuel (issu d'un ban auto) » (ligne convertie) ou « Manuel ».
String channelStateLabel(BannedChannel c) {
  if (c.isAuto) return banStatusLabel(c.status);
  if (c.isConverted) return kConvertedChannelStateLabel;
  return banStatusLabel('manuel');
}

/// Statut servant à la COULEUR de la pastille d'état : celui de la ligne
/// auto, « manuel » sinon (ligne manuelle ou convertie).
String channelStateStatus(BannedChannel c) => c.isAuto ? c.status : 'manuel';

/// Colonne « Plateforme ». Base sans colonne `platform` (défaut `youtube`) :
/// la forme de la clé `auto:rutube:…` / `auto:bili:…` départage, comme
/// `BannedChannel.displayLabel`.
String channelPlatformLabel(BannedChannel c) {
  if (c.platform == 'youtube' && isChannelKeyRow(c)) {
    final String key = c.channelKey;
    if (key.startsWith('rutube:')) return platformLabel('rutube');
    if (key.startsWith('bili:')) return platformLabel('bilibili');
  }
  return platformLabel(c.platform);
}

/// Colonne « Motif » (BRUT, à révéler par l'appelant) : pour une ligne AUTO,
/// l'état (le motif reste « Modération automatique (en revue) » après la
/// confirmation, M94:1446 vs 1601) ; sinon le motif, « — » s'il manque.
String channelReasonText(BannedChannel c) {
  if (c.isAuto) return banStatusLabel(c.status);
  final String? r = c.reason;
  return r == null || r.trim().isEmpty ? '—' : r;
}

/// Infobulle de la colonne « Chaîne » : libellé complet RÉVÉLÉ, puis le nom
/// affiché (révélé, une ligne) s'il existe.
String channelCellTooltip(BannedChannel c) {
  final StringBuffer b = StringBuffer(
    revealInvisibles(c.displayLabel, maxUnits: 512).text,
  );
  final String? name = c.displayName;
  if (name != null && name.trim().isNotEmpty) {
    b.write('\nNom affiché : ${oneLinePreview(name.trim(), max: 120)}');
  }
  return b.toString();
}

// ── Bouton de fin de ligne ───────────────────────────────────────────────────

/// Action de fin d'une ligne de chaîne bannie.
enum ChannelRowAction {
  /// Confirmation puis `channels/unban` (ligne manuelle, convertie, ou auto
  /// sans événement connu : le serveur tranche, 409 → levée).
  unban,

  /// Boutons de revue du compte principal sur `ban_event_id`.
  review,

  /// Ligne automatique vue par un autre admin : « Débannir » désactivé.
  reservedToOwner,
}

/// Action et boutons de revue d'une ligne.
@immutable
class ChannelRowControl {
  const ChannelRowControl(this.action, {this.actions = const <ReviewAction>[]});

  final ChannelRowAction action;

  /// Boutons de revue ([ChannelRowAction.review] seulement).
  final List<ReviewAction> actions;

  @override
  bool operator ==(Object other) =>
      other is ChannelRowControl &&
      other.action == action &&
      listEquals(other.actions, actions);

  @override
  int get hashCode => Object.hash(action, Object.hashAll(actions));

  @override
  String toString() => 'ChannelRowControl($action, $actions)';
}

/// Fin de ligne selon l'origine CONNUE de [c] et le statut « compte
/// principal » de l'interface ([isOwner], T15). Ligne auto sans événement
/// (incomplète) vue par le compte principal → « Débannir » : le 409 du
/// serveur porte l'événement, puis la levée s'ouvre. Statut auto inconnu →
/// « Détail » seulement (jamais « confirmé » supposé).
ChannelRowControl channelRowControl(BannedChannel c, {required bool isOwner}) {
  if (!c.isAuto) return const ChannelRowControl(ChannelRowAction.unban);
  if (!isOwner) {
    return const ChannelRowControl(ChannelRowAction.reservedToOwner);
  }
  if (c.banEventId == null) {
    return const ChannelRowControl(ChannelRowAction.unban);
  }
  final List<ReviewAction> actions = actionsForActiveAutoBan(
    status: c.status,
    targetKind: 'channel',
    isOwner: true,
  );
  return ChannelRowControl(
    ChannelRowAction.review,
    actions: actions.isEmpty
        ? const <ReviewAction>[ReviewAction.detail]
        : actions,
  );
}

// ── Formulaire de ban ────────────────────────────────────────────────────────

/// null = envoyable. URL / handle et motif requis ; motif de 1 à 500 points
/// de code sans caractère interdit (U+0000, demi-paire), comme le serveur
/// (IDX:4435-4438, qui retire ces caractères au lieu de refuser : le
/// panneau refuse, plus strict).
String? channelBanFormError(String handleOrUrl, String reason) {
  if (handleOrUrl.trim().isEmpty || reason.trim().isEmpty) {
    return kChannelBanRequiredMessage;
  }
  return validateReviewReason(reason, required: true);
}

// ── Rapport de ban ───────────────────────────────────────────────────────────

/// Forme du rapport de `channels/ban` selon `result`.
enum BanReportKind { applied, updated, autoInReview }

/// `applied` (et toute valeur inconnue : réponse 200 = ban posé) |
/// `updated` | `auto_en_revue`.
BanReportKind banReportKind(String result) => switch (result) {
  'updated' => BanReportKind.updated,
  'auto_en_revue' => BanReportKind.autoInReview,
  _ => BanReportKind.applied,
};

/// Titre du rapport ; [label] = `displayLabel` BRUT de la ligne (révélé ici,
/// 60 points de code).
String banReportTitle(BanReportKind kind, String label) {
  final String shown = oneLinePreview(label, max: 60);
  return switch (kind) {
    BanReportKind.applied => '🚫 $shown bannie',
    BanReportKind.updated => '$shown : bannissement mis à jour',
    BanReportKind.autoInReview => kBanReportAutoTitle,
  };
}

/// Texte du rapport `auto_en_revue` (v2, C-09 : formulation neutre,
/// `manual_recorded` n'est pas transmis par l'EF). [status] = statut de la
/// ligne AUTO renvoyée (`confirme` → « Confirmé », sinon « En revue »).
String banReportAutoText(String status) {
  final String state = status == 'confirme' ? 'Confirmé' : 'En revue';
  return 'Cette chaîne est déjà bannie par le ban automatique ($state). Une '
      'intention manuelle est enregistrée pour cette chaîne (la première '
      'saisie est conservée) ; elle restera en vigueur si le ban automatique '
      "est levé. Aucune suggestion n'a été purgée ici.";
}

/// « N suggestion(s) en file rejetée(s) (motif : Chaîne bannie). »
String banReportPurgedText(int purged) =>
    '$purged suggestion(s) en file rejetée(s) (motif : Chaîne bannie).';

/// En-tête de la liste des contenus déjà publiés.
String banReportPublishedHeader(int count) =>
    "⚠️ $count contenu(s) de cette chaîne sont déjà PUBLIÉS dans l'app :";

/// « … et N autre(s). » au-delà de [kBanReportPublishedShown].
String banReportMoreText(int more) => '… et $more autre(s).';

/// Libellé BRUT d'un contenu publié (`{id, title, url}`) : titre, sinon URL,
/// sinon id, sinon « — » (à révéler par l'appelant).
String publishedItemLabel(Map<String, dynamic> m) {
  final Object? title = m['title'];
  if (title is String && title.trim().isNotEmpty) return title;
  final Object? url = m['url'];
  if (url is String && url.trim().isNotEmpty) return url;
  final Object? id = m['id'];
  return id == null ? '—' : id.toString();
}

/// Le rapport propose « Retirer aussi ces N contenus publiés » : jamais pour
/// `auto_en_revue` (`unpublish-by-channel` refuse un handle `auto:…`,
/// carto 2 P15 / P18), et seulement s'il y a des contenus publiés.
bool banReportOffersUnpublish(BanReportKind kind, int publishedCount) =>
    kind != BanReportKind.autoInReview && publishedCount > 0;

// ── Déban et levée ───────────────────────────────────────────────────────────

/// SnackBar d'un déban de chaîne terminé ; null pour la session expirée
/// (déconnexion) et le ban automatique (levée ou message dédié). [name] =
/// libellé DÉJÀ révélé. [totalSync] : demander la synchro totale des bots.
({String message, OutcomeTone tone, bool totalSync})? channelUnbanFeedback(
  UnbanOutcome o, {
  required String name,
}) => switch (o.kind) {
  UnbanKind.lifted => (
    message: '${unbanMessage(o, name: name, channel: true)} $kBotsSyncNotice',
    tone: OutcomeTone.success,
    totalSync: true,
  ),
  // Rejeu (INF-01) : la levée a très probablement été faite au 1er essai →
  // avertissement de rejeu et propagation aux bots comme une levée.
  UnbanKind.notBanned || UnbanKind.notFound => (
    message: unbanMessage(o, name: name, channel: true),
    tone: o.replayed ? OutcomeTone.warning : OutcomeTone.info,
    totalSync: o.replayed,
  ),
  UnbanKind.failure => (
    message: unbanMessage(o, name: name, channel: true),
    tone: OutcomeTone.error,
    totalSync: false,
  ),
  UnbanKind.autoBan || UnbanKind.sessionExpired => null,
};

/// Issue d'une décision prise depuis le panneau : une levée avec
/// `still_banned` CONVERTIT la ligne (elle reste, en manuel) → message
/// dédié, ligne non retirée ; le reste inchangé (`outcomeFromResult` /
/// `outcomeFromError`).
DecisionOutcome channelDecisionOutcome(
  DecisionOutcome o, {
  String? result,
  String? stillBanned,
}) {
  if (result == 'lifted' && stillBanned != null && stillBanned.isNotEmpty) {
    return DecisionOutcome(
      tone: OutcomeTone.warning,
      message: kChannelLiftStillBannedMessage,
      reloadQueue: true,
      uncertain: o.uncertain,
    );
  }
  return o;
}

/// Page à relire quand la page [page] revient VIDE du serveur (dernière
/// ligne retirée, liste raccourcie ailleurs) : recule jusqu'à la dernière
/// page existante ; null = garder la page.
int? channelsPageFallback({
  required int page,
  required int itemCount,
  required int total,
  required int pageSize,
}) {
  if (itemCount > 0 || page <= 0) return null;
  final int target = pageAfterRemoval(
    page: page,
    itemsLeftOnPage: 0,
    total: total,
    pageSize: pageSize,
  );
  return target == page ? null : target;
}
