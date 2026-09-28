// Bans de COMPTES aux 4 endroits (tableau de bord, Suggestions, Abonnements,
// Comptes à bannir ; P4b-3, lot L6, T3-T6, conception §6.10, §6.11) — COLLE
// commune : `StoreController` (écritures NON optimistes pour le déban,
// relecture de la liste des bannis), `AuthController.isOwner` (T15),
// dialogues de présentation du lot L5 et SnackBars.
//
// - Bannir → `BanAccountDialog` (catégorie D4 + motif) → `store.banAccount` ;
//   succès → « Compte banni. » (ou l'avertissement orange du serveur) ;
//   erreur → dans le dialogue ; session expirée → fermé, rien affiché.
// - Débannir (ban manuel ou origine inconnue) → `UnbanConfirmDialog` (texte
//   d'exemption) → `store.unbanAccount` ; 409 `auto_ban_use_review` (liste
//   périmée) → compte principal : levée sur l'événement du 409 ; autre
//   admin : « levée réservée au compte principal ».
// - Lever (ban automatique, compte principal) → `AutoBanLiftDialog`
//   (détail + preuve + motif obligatoire, `review-decide lift`), puis
//   relecture de la liste des bannis ; « Ouvrir dans Modération » si la
//   coquille fournit la navigation.
// Chaque fonction rend `true` si une écriture a pu changer l'état (l'écran
// relit alors sa page), `false` si rien n'a été fait (annulation, session
// expirée, bouton désactivé).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_controller.dart';
import '../../data/supabase_sync.dart';
import '../../domain/models/banned_user.dart';
import '../../domain/models/moderation.dart';
import '../../domain/moderation_actions.dart';
import '../../domain/moderation_text.dart';
import '../../domain/write_outcome.dart';
import '../../state/store_controller.dart';
import 'moderation/account_ban_widgets.dart';
import 'moderation/auto_ban_lift_dialog.dart';
import 'moderation/ban_account_dialog.dart';
import 'moderation/review_decision_dialog.dart';
import 'moderation/unban_confirm_dialog.dart';

/// Navigation vers le menu Modération (câblée par la coquille, lot L7) ;
/// nulle = pas de lien « Ouvrir dans Modération ».
typedef OpenModeration = void Function([ModerationFocus? focus]);

/// SnackBar « Compte banni. » après un ban réussi.
const String kAccountBannedMessage = 'Compte banni.';

/// Mode aperçu : aucune levée de ban automatique possible.
const String kDemoModeMessage = 'Mode démo : pas de connexion Supabase.';

/// SnackBar selon le ton (conventions §6 : succès 4 s par défaut,
/// avertissement orange 6 s, erreur rouge 5 s).
void showBanSnack(
  BuildContext context,
  String message, {
  OutcomeTone tone = OutcomeTone.success,
}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final SnackBar bar = switch (tone) {
    OutcomeTone.error => SnackBar(
      content: Text(message),
      backgroundColor: Colors.red.shade700,
      duration: const Duration(seconds: 5),
    ),
    OutcomeTone.warning => SnackBar(
      content: Text(message),
      backgroundColor: Colors.orange.shade700,
      duration: const Duration(seconds: 6),
    ),
    OutcomeTone.success || OutcomeTone.info => SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 4),
    ),
  };
  messenger.showSnackBar(bar);
}

/// Issue RÉUSSIE d'un ban (dialogue fermé sur succès) : « Compte banni. »,
/// ou l'avertissement orange (`already_banned`, rejeu). Échec ou session
/// expirée : rien (déjà affiché dans le dialogue / déconnexion).
void showBanWriteOutcome(BuildContext context, WriteOutcome o) {
  if (!o.ok) return;
  final String? notice = o.notice;
  if (notice != null) {
    showBanSnack(context, notice, tone: OutcomeTone.warning);
  } else {
    showBanSnack(context, kAccountBannedMessage);
  }
}

/// « Bannir `nom` ? » d'un compte CONNU ([userId] = UUID) :
/// catégories lues au serveur à la première ouverture (repli local sinon),
/// encart si l'entrée connue est un ban automatique.
Future<bool> banAccountFlow(
  BuildContext context, {
  required String userId,
  required String displayName,
}) async {
  final StoreController store = context.read<StoreController>();
  final BannedUser? entry = store.bannedEntry(userId);
  unawaited(store.loadBanCategories());
  final WriteOutcome? o = await showDialog<WriteOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) => BanAccountDialog(
      displayName: displayName,
      categories: ctx.watch<StoreController>().manualBanCategories,
      autoBanInReview: entry?.isAuto ?? false,
      submit: (String category, String? reason) => store.banAccount(
        userId,
        displayName: displayName,
        category: category,
        reason: reason,
      ),
    ),
  );
  if (o == null || o.sessionExpired) return false;
  if (context.mounted) showBanWriteOutcome(context, o);
  return true;
}

/// Bouton de fin d'une ligne bannie : dispatch selon l'origine CONNUE
/// ([entry] ; nulle = origine inconnue) — confirmation du déban, levée du
/// ban automatique (compte principal) ou rien (bouton désactivé).
Future<bool> accountUnbanFlow(
  BuildContext context, {
  required String userId,
  required String name,
  BannedUser? entry,
  OpenModeration? onOpenModeration,
}) {
  final bool owner = context.read<AuthController>().isOwner;
  final AccountUnbanControl c = accountUnbanControl(entry, isOwner: owner);
  switch (c.action) {
    case AccountUnbanAction.unbanConfirm:
      return confirmUnbanFlow(
        context,
        userId: userId,
        name: name,
        onOpenModeration: onOpenModeration,
      );
    case AccountUnbanAction.liftAuto:
      return liftAccountAutoBanFlow(
        context,
        banEventId: entry!.banEventId!,
        targetLabel: name,
        status: entry.status,
        manualBanPresent: entry.manualBanPresent,
        onOpenModeration: onOpenModeration,
      );
    case AccountUnbanAction.reservedToOwner:
      return Future<bool>.value(false);
  }
}

/// « Débannir `nom` ? » (ban MANUEL ou origine inconnue) — NON optimiste :
/// la ligne ne disparaît qu'après la réponse. 409 `auto_ban_use_review`
/// (liste périmée, T3) → levée (compte principal) sur l'événement du 409,
/// statut inconnu ; sinon « levée réservée au compte principal ».
Future<bool> confirmUnbanFlow(
  BuildContext context, {
  required String userId,
  required String name,
  OpenModeration? onOpenModeration,
}) async {
  final StoreController store = context.read<StoreController>();
  final UnbanOutcome? o = await UnbanConfirmDialog.show(
    context,
    name: name,
    submit: () => store.unbanAccount(userId),
  );
  if (o == null) return false;
  if (!context.mounted) return true;
  final String shown = oneLinePreview(name, max: 60);
  switch (o.kind) {
    case UnbanKind.sessionExpired:
      return false;
    case UnbanKind.autoBan:
      final int? eventId = o.banEventId;
      if (context.read<AuthController>().isOwner &&
          eventId != null &&
          store.sync != null) {
        await liftAccountAutoBanFlow(
          context,
          banEventId: eventId,
          targetLabel: name,
          onOpenModeration: onOpenModeration,
        );
      } else {
        showBanSnack(
          context,
          unbanMessage(o, name: shown, channel: false),
          tone: OutcomeTone.warning,
        );
      }
      return true;
    case UnbanKind.lifted:
    case UnbanKind.notBanned:
      showBanSnack(
        context,
        unbanMessage(o, name: shown, channel: false),
        // INF-01 : « n'était plus banni » obtenu par un rejeu → message de
        // rejeu en orange.
        tone: o.replayed ? OutcomeTone.warning : OutcomeTone.success,
      );
      return true;
    case UnbanKind.notFound:
      showBanSnack(
        context,
        unbanMessage(o, name: shown, channel: false),
        tone: OutcomeTone.warning,
      );
      return true;
    case UnbanKind.failure:
      // Le dialogue reste ouvert sur un échec : cas défensif seulement.
      showBanSnack(
        context,
        unbanMessage(o, name: shown, channel: false),
        tone: OutcomeTone.error,
      );
      return true;
  }
}

/// Levée d'un ban AUTOMATIQUE de compte depuis une liste (compte principal)
/// : détail + preuve + motif obligatoire (`review-decide lift` sur
/// [banEventId]) ; le résultat est traduit par `outcomeFromResult` /
/// `outcomeFromError` (SnackBar selon le ton) et la liste des bannis est
/// relue quand l'état a pu changer. « Ouvrir dans Modération » navigue avec
/// `ModerationFocus(banEventId, status, 'account')` ([status] = statut
/// affiché ; nul = inconnu → « Détail » seulement côté Modération).
Future<bool> liftAccountAutoBanFlow(
  BuildContext context, {
  required int banEventId,
  required String targetLabel,
  String? status,
  bool manualBanPresent = false,
  OpenModeration? onOpenModeration,
}) async {
  final StoreController store = context.read<StoreController>();
  final SupabaseSync? sync = store.sync;
  if (sync == null) {
    showBanSnack(context, kDemoModeMessage, tone: OutcomeTone.warning);
    return false;
  }
  final VoidCallback? open = onOpenModeration == null
      ? null
      : () => onOpenModeration(
          ModerationFocus(
            eventId: banEventId,
            status: status,
            targetKind: 'account',
          ),
        );
  final DecisionDialogOutcome? r = await AutoBanLiftDialog.show(
    context,
    loadDetail: () => sync.fetchReviewDetail(banEventId),
    submit: (String? reason) =>
        sync.reviewDecide(banEventId, ReviewDecision.lift, reason: reason),
    targetLabel: targetLabel,
    manualBanPresent: manualBanPresent,
    onOpenModeration: open,
    onAuthError: () => store.onAuthError?.call(),
  );
  // Annulé, fermé sur 401 (déconnexion lancée) ou « Ouvrir dans Modération ».
  if (r == null) return false;
  final DecisionOutcome out = r.outcome;
  if (out.reloadQueue) unawaited(store.reloadBannedList());
  if (context.mounted) showBanSnack(context, out.message, tone: out.tone);
  return out.reloadQueue;
}
