// Confirmation de désactivation d'un jeu (P4b-3, lot L9, D2, conception
// §6.13) : MÊME dialogue pour la bascule du tableau principal et pour
// l'interrupteur « Actif » décoché dans le dialogue d'édition (v2, ARC-02).
// Titre « Désactiver <nom> ? », texte fixe, bouton « Désactiver » rouge.
// Rend `true` si l'admin confirme, `false` sinon (Annuler, Échap, clic hors
// du dialogue).
//
// Widget « de présentation » (aucun Provider) → testable en VM. Clés :
// `games-deactivate-confirm`, `games-deactivate-cancel`.
import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../domain/games_screen_rules.dart';

class DeactivateGameDialog extends StatelessWidget {
  const DeactivateGameDialog({super.key, required this.name});

  /// Nom du jeu (titre du dialogue).
  final String name;

  /// Ouvre la confirmation ; `true` seulement si « Désactiver » est choisi.
  static Future<bool> confirm(BuildContext context, String name) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (_) => DeactivateGameDialog(name: name),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(deactivateGameTitle(name)),
    content: const SizedBox(width: 420, child: Text(kDeactivateGameText)),
    actions: <Widget>[
      TextButton(
        key: const Key('games-deactivate-cancel'),
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Annuler'),
      ),
      FilledButton(
        key: const Key('games-deactivate-confirm'),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.categoryVideo,
          foregroundColor: Colors.white,
        ),
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text(kDeactivateGameButton),
      ),
    ],
  );
}
