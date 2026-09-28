// Enchaînements de l'écran Jeux (P4b-3, lot L9, conception §6.13, D2, T7)
// sortis de l'écran pour être testés en VM : les écritures du contrôleur
// sont INJECTÉES (aucun Provider, aucun StoreController).
//
// - [runSetGameActive] : bascule d'un jeu. Désactiver un jeu actif ouvre la
//   confirmation (D2) ; « Réactiver » n'en demande pas. Indicateur par ligne
//   ([onBusy]), SnackBar de succès, SnackBar ROUGE sur échec, rien sur une
//   session expirée (déconnexion déjà faite par le contrôleur).
// - [runReadyGamesFlow] : « Activer les jeux prêts ». Aperçu ; aucun jeu
//   prêt → dialogue d'information (seuil LU de la réponse, jamais codé) ;
//   sinon `ReadyGamesDialog` (cases, confirmation, bilan). Erreur de
//   l'aperçu : 401 → `onAuthError` ; 403 → « Réservé au compte principal. » ;
//   autre → message du serveur tel quel (SnackBar rouge).
import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show AdminAuthException, AdminForbiddenException, errorText;
import '../../../domain/game_patch.dart' show needsDeactivationConfirm;
import '../../../domain/games_screen_rules.dart';
import '../../../domain/models/game.dart';
import '../../../domain/models/ready_games.dart';
import '../../../domain/moderation_actions.dart' show OutcomeTone;
import '../../../domain/write_outcome.dart';
import 'deactivate_game_dialog.dart';
import 'ready_games_dialog.dart';

/// SnackBar selon le ton (conventions §6 : succès / info 4 s par défaut,
/// avertissement orange 6 s, erreur rouge 5 s).
void showGamesSnack(
  BuildContext context,
  String message, {
  OutcomeTone tone = OutcomeTone.success,
}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(switch (tone) {
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
  });
}

/// Active ([active] vrai) ou désactive [game] par [setActive]
/// (`store.setGameActive`, envoi `{id, active}` seul). Désactiver un jeu
/// actif demande d'abord la confirmation ; Annuler = aucun envoi.
/// [onBusy] encadre l'envoi (indicateur de la ligne). Rend l'issue de
/// l'écriture (null si l'admin a annulé).
Future<WriteOutcome?> runSetGameActive(
  BuildContext context, {
  required Game game,
  required bool active,
  required Future<WriteOutcome> Function(Game game, bool active) setActive,
  required void Function(bool busy) onBusy,
}) async {
  if (needsDeactivationConfirm(game, <String, Object?>{'active': active})) {
    final bool ok = await DeactivateGameDialog.confirm(context, game.name);
    if (!ok) return null;
  }
  onBusy(true);
  WriteOutcome out;
  try {
    out = await setActive(game, active);
  } catch (e) {
    // Le contrôleur ne lève pas ; garde-fou (l'indicateur ne reste jamais).
    out = WriteOutcome.failed(errorText(e));
  }
  onBusy(false);
  if (!context.mounted || out.sessionExpired) return out;
  if (out.ok) {
    showGamesSnack(
      context,
      active
          ? gameReactivatedMessage(game.name)
          : gameDeactivatedMessage(game.name),
    );
    final String? notice = out.notice;
    if (notice != null && notice.isNotEmpty) {
      showGamesSnack(context, notice, tone: OutcomeTone.warning);
    }
  } else {
    showGamesSnack(
      context,
      gameWriteFailureText(out.message),
      tone: OutcomeTone.error,
    );
  }
  return out;
}

/// Dialogue d'information : l'aperçu ne compte aucun jeu prêt.
class NoReadyGamesDialog extends StatelessWidget {
  const NoReadyGamesDialog({super.key, required this.preview});

  final ReadyGamesPreview preview;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text(kNoReadyGamesTitle),
    content: Text(
      noReadyGamesText(preview),
      key: const Key('games-ready-info'),
    ),
    actions: <Widget>[
      FilledButton(
        key: const Key('games-ready-info-close'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Fermer'),
      ),
    ],
  );
}

/// « Activer les jeux prêts » : [preview] (`store.previewReadyGames`, qui
/// relance toutes les erreurs), puis dialogue d'information ou
/// `ReadyGamesDialog` avec [apply] (`store.activateReadyGames` : synchro
/// complète des jeux et relecture des inactifs après l'activation). Rend le
/// bilan (null si rien n'a été activé ou en cas d'erreur).
Future<ActivateReadyResult?> runReadyGamesFlow(
  BuildContext context, {
  required Future<ReadyGamesPreview> Function() preview,
  required Future<ActivateReadyResult> Function(List<String> ids) apply,
  required VoidCallback onAuthError,
}) async {
  final ReadyGamesPreview p;
  try {
    p = await preview();
  } on AdminAuthException {
    onAuthError();
    return null;
  } catch (e) {
    if (context.mounted) {
      showGamesSnack(
        context,
        readyGamesErrorMessage(
          forbidden: e is AdminForbiddenException,
          message: errorText(e),
        ),
        tone: OutcomeTone.error,
      );
    }
    return null;
  }
  if (!context.mounted) return null;
  if (p.count == 0 || p.games.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (_) => NoReadyGamesDialog(preview: p),
    );
    return null;
  }
  return ReadyGamesDialog.show(
    context,
    preview: p,
    apply: apply,
    onAuthError: onAuthError,
  );
}
