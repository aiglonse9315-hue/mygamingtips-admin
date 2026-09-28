// Carte « Modération automatique » du tableau de bord (P4b-3, lot L6, T9,
// D1, conception §6.10) — COLLE Provider : lit `store.sync` et branche la
// déconnexion (`store.onAuthError`) sur `ModerationAlertLoader` (lecture,
// 403 → carte masquée, 401 → déconnexion, erreur → ligne « illisible »),
// qui monte `ModerationAlertView` (présentation, lot L5).
//
// Affichée par le tableau de bord SEULEMENT pour le compte principal
// (`AuthController.isOwner`, T15) quand une connexion Supabase existe ;
// absente en mode aperçu (§6.14).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/supabase_sync.dart';
import '../../state/store_controller.dart';
import 'moderation/moderation_alert_loader.dart';

class ModerationAlertCard extends StatelessWidget {
  const ModerationAlertCard({super.key, this.onOpenModeration, this.padding});

  /// « Ouvrir la modération » (navigation vers le menu Modération, câblée
  /// par la coquille) ; nul → le bouton ne fait rien.
  final VoidCallback? onOpenModeration;

  /// Marge autour de la carte (masquée avec elle).
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.read<StoreController>();
    final SupabaseSync? sync = store.sync;
    if (sync == null) return const SizedBox.shrink();
    return ModerationAlertLoader(
      load: sync.fetchModerationSettings,
      onAuthError: () => store.onAuthError?.call(),
      onOpen: () => onOpenModeration?.call(),
      padding: padding ?? EdgeInsets.zero,
    );
  }
}
