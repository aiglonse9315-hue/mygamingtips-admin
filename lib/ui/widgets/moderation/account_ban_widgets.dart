// Bans de COMPTES dans les listes (P4b-3, lot L6, T3, conception §6.10,
// §6.11) : bouton « Débannir » / « Lever… » choisi d'après l'origine CONNUE
// avant le clic, ligne de la liste « Comptes bannis » du tableau de bord.
//
// - Ban manuel → « Débannir » (confirmation, `profiles/unban`) ;
// - ban AUTOMATIQUE, compte principal → « Lever… » (dialogue de levée avec
//   détail, preuve et motif obligatoire, `review-decide lift`) ;
// - ban AUTOMATIQUE, autre admin → « Débannir » DÉSACTIVÉ avec explication ;
// - origine inconnue (entrée absente de la liste) → « Débannir » : le
//   serveur tranche (409 `auto_ban_use_review` → levée).
//
// Widgets « de présentation » (aucun Provider) → testables en VM ; la colle
// (StoreController, dialogues, SnackBars) est dans `account_ban_flows.dart`.
import 'package:flutter/material.dart';

import '../../../domain/ids.dart';
import '../../../domain/models/ban_category.dart';
import '../../../domain/models/banned_user.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_labels.dart';
import '../../../domain/moderation_text.dart';
import 'moderation_ui.dart';
import 'status_badges.dart';

/// Infobulle « Débannir » d'un ban MANUEL.
const String kUnbanManualTooltip = 'Débannir (ban manuel)';

/// Infobulle « Lever… » d'un ban automatique en revue.
const String kLiftInReviewTooltip = 'Lever (ban automatique en revue)';

/// Infobulle « Lever… » d'un ban automatique confirmé.
const String kLiftConfirmedTooltip = 'Lever (ban automatique confirmé)';

/// Infobulle du bouton désactivé (ban automatique, autre admin).
const String kAutoBanReservedTooltip =
    'Bannissement automatique : levée réservée au compte principal (menu '
    'Modération).';

/// Action du bouton de fin d'une ligne bannie.
enum AccountUnbanAction {
  /// Confirmation puis `profiles/unban` (ban manuel ou origine inconnue).
  unbanConfirm,

  /// Dialogue de levée du ban automatique (compte principal).
  liftAuto,

  /// Ban automatique vu par un autre admin : bouton désactivé.
  reservedToOwner,
}

/// Libellé, infobulle et action du bouton de fin d'une ligne bannie.
@immutable
class AccountUnbanControl {
  const AccountUnbanControl(
    this.action, {
    required this.label,
    required this.tooltip,
  });

  final AccountUnbanAction action;
  final String label;
  final String tooltip;

  bool get enabled => action != AccountUnbanAction.reservedToOwner;

  @override
  bool operator ==(Object other) =>
      other is AccountUnbanControl &&
      other.action == action &&
      other.label == label &&
      other.tooltip == tooltip;

  @override
  int get hashCode => Object.hash(action, label, tooltip);

  @override
  String toString() => 'AccountUnbanControl($action, $label, $tooltip)';
}

/// Bouton de fin d'une ligne bannie selon l'origine CONNUE ([entry], lue dans
/// `profiles/banned-list`) et le statut « compte principal » de l'interface
/// ([isOwner], T15). [entry] nulle (origine inconnue) → « Débannir » simple.
/// Ban automatique sans événement connu (ligne incomplète) → « Débannir » :
/// le serveur répond 409 avec l'événement, puis la levée s'ouvre.
AccountUnbanControl accountUnbanControl(
  BannedUser? entry, {
  required bool isOwner,
}) {
  if (entry == null) {
    return const AccountUnbanControl(
      AccountUnbanAction.unbanConfirm,
      label: 'Débannir',
      tooltip: 'Débannir',
    );
  }
  switch (unbanPathFor(origin: entry.origin, isOwner: isOwner)) {
    case UnbanPath.confirmManual:
      return const AccountUnbanControl(
        AccountUnbanAction.unbanConfirm,
        label: 'Débannir',
        tooltip: kUnbanManualTooltip,
      );
    case UnbanPath.liftAuto:
      if (entry.banEventId == null) {
        return const AccountUnbanControl(
          AccountUnbanAction.unbanConfirm,
          label: 'Débannir',
          tooltip: 'Débannir',
        );
      }
      return AccountUnbanControl(
        AccountUnbanAction.liftAuto,
        label: 'Lever…',
        tooltip: entry.status == 'confirme'
            ? kLiftConfirmedTooltip
            : kLiftInReviewTooltip,
      );
    case UnbanPath.autoReservedToOwner:
      return const AccountUnbanControl(
        AccountUnbanAction.reservedToOwner,
        label: 'Débannir',
        tooltip: kAutoBanReservedTooltip,
      );
  }
}

/// Sous-titre d'une ligne bannie : « id court · catégorie · date (ou
/// « date inconnue ») · motif (ou « Sans motif ») » (motif révélé, 80
/// points de code ; date en heure locale).
String bannedAccountSubtitle(
  BannedUser b, {
  List<BanCategory> categories = const <BanCategory>[],
}) {
  final DateTime? at = b.bannedAt;
  final String date = at == null ? 'date inconnue' : formatModerationDate(at);
  final String? reason = b.reason;
  final String motif = reason == null || reason.trim().isEmpty
      ? 'Sans motif'
      : oneLinePreview(reason.trim(), max: 80);
  return '${oneLinePreview(shortId(b.id), max: 12)} · '
      '${banCategoryLabel(b.category, categories)} · $date · $motif';
}

/// Pastille « auto » à côté d'un badge « BANNI » (statut en infobulle :
/// « Auto — en revue », « Auto — confirmé »).
class AutoBanPill extends StatelessWidget {
  const AutoBanPill({super.key, required this.status});

  final String? status;

  @override
  Widget build(BuildContext context) {
    return BanOriginBadge(
      status: status,
      label: 'auto',
      tooltip: banStatusLabel(status),
    );
  }
}

/// Bouton d'icône « Débannir » / « Lever » des tableaux (Suggestions,
/// Abonnements, Comptes à bannir).
class AccountUnbanIconButton extends StatelessWidget {
  const AccountUnbanIconButton({
    super.key,
    required this.control,
    required this.onUnban,
    required this.onLift,
    this.size = 20,
  });

  final AccountUnbanControl control;

  /// Nul → bouton désactivé (action en cours sur la ligne).
  final VoidCallback? onUnban;
  final VoidCallback? onLift;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bool lift = control.action == AccountUnbanAction.liftAuto;
    final Color color = !control.enabled
        ? Colors.grey
        : (lift ? ModerationColors.warning : Colors.green);
    return IconButton(
      tooltip: control.tooltip,
      icon: Icon(
        lift ? Icons.gavel_rounded : Icons.lock_open_rounded,
        size: size,
        color: color,
      ),
      onPressed: !control.enabled ? null : (lift ? onLift : onUnban),
    );
  }
}

/// Ligne de la liste « Comptes bannis » du tableau de bord (§6.10) : nom
/// révélé (60), sous-titre, statut (`kBanStatusLabels`), « + ban manuel »
/// si un ban humain est aussi posé, bouton de fin selon
/// [accountUnbanControl].
class BannedAccountTile extends StatelessWidget {
  const BannedAccountTile({
    super.key,
    required this.entry,
    required this.isOwner,
    this.categories = const <BanCategory>[],
    required this.onUnban,
    required this.onLift,
  });

  final BannedUser entry;
  final bool isOwner;

  /// Catégories connues (libellé de la catégorie).
  final List<BanCategory> categories;
  final VoidCallback onUnban;
  final VoidCallback onLift;

  @override
  Widget build(BuildContext context) {
    final AccountUnbanControl c = accountUnbanControl(entry, isOwner: isOwner);
    final bool lift = c.action == AccountUnbanAction.liftAuto;
    return ListTile(
      leading: const CircleAvatar(
        backgroundColor: ModerationColors.danger,
        child: Icon(Icons.block_rounded, color: Colors.white, size: 18),
      ),
      title: Row(
        children: <Widget>[
          Flexible(
            child: UntrustedLine(
              entry.displayName,
              max: 60,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 6),
          BanOriginBadge(status: entry.status),
          if (entry.manualBanPresent) ...<Widget>[
            const SizedBox(width: 6),
            const ManualPresentBadge(label: '+ ban manuel'),
          ],
        ],
      ),
      subtitle: Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          bannedAccountSubtitle(entry, categories: categories),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
      ),
      trailing: Tooltip(
        message: c.tooltip,
        child: TextButton.icon(
          key: Key('ban-row-action-${entry.id}'),
          onPressed: !c.enabled ? null : (lift ? onLift : onUnban),
          icon: Icon(
            lift ? Icons.gavel_rounded : Icons.lock_open_rounded,
            size: 18,
          ),
          label: Text(c.label),
        ),
      ),
    );
  }
}
