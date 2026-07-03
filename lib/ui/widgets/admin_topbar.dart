import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';

/// Barre supérieure du panneau admin : titre de la section + actions.
class AdminTopbar extends StatelessWidget {
  const AdminTopbar({
    super.key,
    required this.title,
    required this.onReset,
    required this.onLogout,
    this.showReset = true,
    this.onRefresh,
    this.isSyncing = false,
    this.syncError,
    this.onDismissError,
  });

  final String title;
  final VoidCallback onReset;
  final VoidCallback onLogout;

  /// Affiche le bouton "Réinitialiser la démo" uniquement en mode aperçu
  /// local. En production (Supabase connecté), il est masqué car il
  /// n'a pas de sens d'écraser les données serveur.
  final bool showReset;

  /// Callback de rafraîchissement (resync Supabase). Si null, le bouton
  /// n'apparaît pas.
  final VoidCallback? onRefresh;

  /// Indique qu'une synchronisation est en cours (bouton en loading).
  final bool isSyncing;

  /// Dernière erreur de synchronisation (affichée si non null).
  final String? syncError;

  /// Callback pour fermer la bannière d'erreur.
  final VoidCallback? onDismissError;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(
            color: Theme.of(context).canvasColor,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).dividerColor,
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (onRefresh != null)
                TextButton.icon(
                  onPressed: isSyncing ? null : onRefresh,
                  icon: isSyncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('Actualiser'),
                ),
              if (onRefresh != null) const SizedBox(width: 8),
              if (showReset)
                TextButton.icon(
                  onPressed: onReset,
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: const Text('Réinitialiser la démo'),
                ),
              if (showReset) const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.nitro.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.nitro.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.shield_rounded,
                        size: 16, color: AppColors.nitro),
                    SizedBox(width: 6),
                    Text(
                      'admin',
                      style: TextStyle(
                        color: AppColors.nitro,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Se déconnecter',
                onPressed: onLogout,
                icon: const Icon(Icons.logout_rounded, size: 20),
              ),
            ],
          ),
        ),
        if (syncError != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            color: AppColors.categoryVideo.withValues(alpha: 0.15),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded,
                    size: 18, color: AppColors.categoryVideo),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    syncError!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.categoryVideo,
                    ),
                  ),
                ),
                if (onDismissError != null)
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 16),
                    onPressed: onDismissError,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
