// Carte « Modération automatique » du tableau de bord (P4b-3, lot L5, T9,
// D1, conception §6.10, §6.9) — partie PRÉSENTATION : l'état est passé en
// paramètre (réglages, chargement, erreur) ; la lecture serveur, le 403 (la
// carte disparaît) et le 401 sont gérés par `ModerationAlertCard` (lot L6).
//
// Contenu : titre + pastille « allumée » / « éteinte » ; « File de revue :
// N élément(s) » ; « Bans automatiques : h/H (1 h) · d/D (24 h) » ;
// disjoncteur ouvert → carte ROUGE + « ⛔ Disjoncteur déclenché le
// JJ/MM/AAAA HH:mm (<motif>) : le ban automatique est coupé. » ; bouton
// « Ouvrir la modération » ; erreur → « État de la modération illisible. »
// + ↻ (pas de SnackBar).
//
// Widget « de présentation » (aucun Provider) → testable en VM.
import 'package:flutter/material.dart';

import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_labels.dart';
import 'moderation_ui.dart';

/// Message d'erreur de la carte.
const String kModerationAlertError = 'État de la modération illisible.';

/// Bandeau du disjoncteur (carte du tableau de bord et en-tête de l'écran
/// Modération) : date en heure LOCALE.
String breakerBannerText(DateTime trippedAt, String? reason) =>
    '⛔ Disjoncteur déclenché le ${formatModerationDate(trippedAt)} '
    '(${breakerReasonLabel(reason)}) : le ban automatique est coupé.';

class ModerationAlertView extends StatelessWidget {
  const ModerationAlertView({
    super.key,
    required this.settings,
    this.loading = false,
    this.error,
    required this.onRefresh,
    required this.onOpen,
  });

  /// Réglages lus (null : pas encore lus ou erreur).
  final ModerationSettings? settings;
  final bool loading;

  /// Erreur de lecture (hors 401 / 403) : affiche la ligne d'erreur.
  final String? error;
  final VoidCallback onRefresh;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ModerationSettings? s = settings;
    final bool breaker = s?.breakerOpen ?? false;
    final Color danger = ModerationColors.danger;

    final Widget content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                breaker ? Icons.gpp_bad_outlined : Icons.gavel_rounded,
                size: 18,
                color: breaker ? danger : theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Modération automatique',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: breaker ? danger : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (s != null)
                ModerationPill(
                  key: const Key('moderation-alert-state'),
                  label: s.autoBanEnabled ? 'allumée' : 'éteinte',
                  color: s.autoBanEnabled
                      ? ModerationColors.success
                      : ModerationColors.neutral,
                ),
              const Spacer(),
              if (loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  key: const Key('moderation-alert-refresh'),
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  tooltip: 'Actualiser',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (s == null && error != null)
            Text(
              kModerationAlertError,
              key: const Key('moderation-alert-error'),
              style: TextStyle(fontSize: 12.5, color: Colors.orange.shade300),
            )
          else if (s == null)
            Text('Chargement…', style: theme.textTheme.bodySmall)
          else ...<Widget>[
            if (breaker) ...<Widget>[
              Text(
                breakerBannerText(s.breakerTrippedAt!, s.breakerReason),
                key: const Key('moderation-alert-breaker'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: danger,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              'File de revue : ${s.reviewQueueSize} élément(s)',
              key: const Key('moderation-alert-queue'),
              style: const TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 4),
            Text(
              'Bans automatiques : ${s.autoBansLastHour}/${s.maxPerHour} (1 h) · '
              '${s.autoBansLastDay}/${s.maxPerDay} (24 h)',
              key: const Key('moderation-alert-counters'),
              style: const TextStyle(fontSize: 12.5),
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                kModerationAlertError,
                key: const Key('moderation-alert-error'),
                style: TextStyle(fontSize: 12, color: Colors.orange.shade300),
              ),
            ],
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              key: const Key('moderation-alert-open'),
              onPressed: onOpen,
              icon: const Icon(Icons.gavel_rounded, size: 18),
              label: const Text('Ouvrir la modération'),
            ),
          ),
        ],
      ),
    );

    if (!breaker) return Card(child: content);
    return Card(
      key: const Key('moderation-alert-breaker-card'),
      color: danger.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: danger, width: 1.5),
      ),
      child: content,
    );
  }
}
