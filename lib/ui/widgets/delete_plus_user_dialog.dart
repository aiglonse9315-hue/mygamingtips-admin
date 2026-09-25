import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import '../../domain/models/plus_user.dart';

/// Confirmation de la suppression DÉFINITIVE d'un abonnement Plus (demande
/// du propriétaire du 25/09/2026 : « une vraie suppression, avec
/// confirmation pour ne pas la faire par inadvertance »).
///
/// Double confirmation : le bouton rouge reste GRISÉ tant que la case
/// « Je confirme la suppression définitive » n'est pas cochée — un clic
/// malheureux (ou Entrée) ne supprime rien. Rappelle ce qui est supprimé et
/// prévient qu'un abonnement Google Play n'est pas annulé chez Google.
class DeletePlusUserDialog extends StatefulWidget {
  const DeletePlusUserDialog({
    super.key,
    required this.user,
    required this.onConfirm,
  });

  final PlusUser user;

  /// Appelé (après fermeture du dialog) quand la suppression est confirmée.
  final VoidCallback onConfirm;

  @override
  State<DeletePlusUserDialog> createState() => _DeletePlusUserDialogState();
}

class _DeletePlusUserDialogState extends State<DeletePlusUserDialog> {
  bool _confirmed = false;

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final PlusUser u = widget.user;
    final String plan = u.plan == 'yearly' ? 'Annuel' : 'Mensuel';
    final String source = u.isGoogle ? 'Google Play' : 'Manuel';
    final String status = u.active ? 'Actif' : 'Expiré';
    return AlertDialog(
      title: Text('Supprimer définitivement l\'abonnement de ${u.displayName} ?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$plan • $source • $status • depuis le ${_date(u.startedAt)}'
              '${u.expiresAt != null ? ' • fin le ${_date(u.expiresAt!)}' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text(
              'L\'abonnement est effacé de la base : l\'utilisateur perd Plus '
              'immédiatement et la ligne disparaît de la liste et des '
              'statistiques. Cette action est irréversible (une trace reste '
              'dans le journal d\'audit).',
            ),
            if (u.isGoogle) ...[
              const SizedBox(height: 12),
              const Text(
                '⚠️ Abonnement Google Play : le supprimer ici ne l\'annule PAS '
                'chez Google (l\'utilisateur reste facturé) et il peut '
                'réapparaître à la prochaine vérification d\'achat de l\'app.',
                style: TextStyle(color: AppColors.categoryVideo),
              ),
            ],
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('delete-plus-confirm-checkbox'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _confirmed,
              onChanged: (bool? v) => setState(() => _confirmed = v ?? false),
              title: const Text('Je confirme la suppression définitive'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          key: const Key('delete-plus-confirm-button'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.categoryVideo,
          ),
          onPressed: _confirmed
              ? () {
                  Navigator.pop(context);
                  widget.onConfirm();
                }
              : null,
          child: const Text('Supprimer définitivement'),
        ),
      ],
    );
  }
}
