// Briques communes du menu « Log » (P4d L3, conception
// tools/PLAN_VISION2_P4d_CONCEPTION.md §4 « L3 — CONTRAT ») : enregistreur
// de CSV (fourni par l'écran : téléchargement navigateur), état 403,
// indicateur d'attente, menu d'export (page / tout), icône de réussite,
// cellule de texte NON FIABLE.
//
// AUCUN import de StoreController, Provider ni dart:html : l'écran passe
// l'accès serveur (`SupabaseSync`), `onAuthError` (401 → déconnexion) et
// l'enregistreur de CSV → onglets testables en VM
// (`test/logs_tabs_test.dart`).
//
// Texte non fiable (logins tapés, user-agents, détails, routes, IP d'avant
// la normalisation) : `UntrustedLine` (caractères cachés rendus visibles,
// gauche-à-droite, rogné), infobulle RÉVÉLÉE elle aussi, jamais de lien.
import 'package:flutter/material.dart';

import '../../../domain/logs_screen_rules.dart' show successTooltip;
import '../../../domain/moderation_text.dart' show revealInvisibles;
import '../../widgets/moderation/moderation_ui.dart';

/// Enregistre le CSV [csv] sous [filename] (navigateur : téléchargement).
typedef CsvSaver = void Function(String csv, String filename);

/// Longueur maximale (unités UTF-16) du texte révélé d'une infobulle.
const int kLogsTooltipMax = 2000;

/// État 403 : « Réservé au compte principal. » + explication (motif de
/// l'écran d'avant L3).
class LogsForbiddenView extends StatelessWidget {
  const LogsForbiddenView({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.lock_outline_rounded,
              size: 40,
              color: theme.textTheme.bodySmall?.color,
            ),
            const SizedBox(height: 12),
            Text(
              'Réservé au compte principal.',
              key: const Key('logs-forbidden'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Le journal d\'activité n\'est consultable que par le compte '
              'propriétaire (contrôle appliqué côté serveur).',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Indicateur d'attente 40 × 40 (à la place d'un bouton en cours).
class LogsBusyBox extends StatelessWidget {
  const LogsBusyBox({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 40,
    height: 40,
    child: Center(
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

/// Menu d'export CSV : « Exporter la page (CSV) » / « Exporter tout
/// (CSV) » ; indicateur d'attente pendant un export.
class LogsExportMenu extends StatelessWidget {
  const LogsExportMenu({
    super.key,
    required this.enabled,
    required this.exporting,
    required this.onExportPage,
    required this.onExportAll,
  });

  final bool enabled;
  final bool exporting;
  final VoidCallback onExportPage;
  final VoidCallback onExportAll;

  @override
  Widget build(BuildContext context) {
    if (exporting) return const LogsBusyBox(key: Key('logs-exporting'));
    return PopupMenuButton<String>(
      key: const Key('logs-export'),
      icon: const Icon(Icons.download_rounded),
      tooltip: 'Exporter en CSV',
      enabled: enabled,
      onSelected: (String choice) {
        if (choice == 'page') {
          onExportPage();
        } else {
          onExportAll();
        }
      },
      itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          key: Key('logs-export-page'),
          value: 'page',
          child: ListTile(
            leading: Icon(Icons.description_outlined),
            title: Text('Exporter la page (CSV)'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem<String>(
          key: Key('logs-export-all'),
          value: 'all',
          child: ListTile(
            leading: Icon(Icons.download_done_rounded),
            title: Text('Exporter tout (CSV)'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

/// Icône de réussite : coche verte (réussie), croix rouge (échec ou
/// blocage), rien si non renseigné (action, archive d'avant 0098, serveur
/// d'avant L2).
class LogSuccessIcon extends StatelessWidget {
  const LogSuccessIcon(this.success, {super.key});

  final bool? success;

  @override
  Widget build(BuildContext context) {
    final bool? s = success;
    final String? tip = successTooltip(s);
    if (s == null || tip == null) return const SizedBox.shrink();
    return Tooltip(
      message: tip,
      child: Icon(
        s ? Icons.check_circle_rounded : Icons.cancel_rounded,
        size: 18,
        color: s ? ModerationColors.success : ModerationColors.danger,
      ),
    );
  }
}

/// Cellule de texte NON FIABLE sur une ligne (`UntrustedLine`) avec
/// infobulle du texte COMPLET révélé ; « — » si vide ou absent.
class UntrustedCell extends StatelessWidget {
  const UntrustedCell(
    this.raw, {
    super.key,
    this.max = 120,
    this.monospace = false,
    this.style,
    this.tooltip = true,
  });

  final String? raw;
  final int max;
  final bool monospace;
  final TextStyle? style;

  /// Faux : pas d'infobulle (texte court).
  final bool tooltip;

  @override
  Widget build(BuildContext context) {
    final String? text = raw;
    if (text == null || text.isEmpty) {
      return Text('—', style: style ?? const TextStyle(fontSize: 12.5));
    }
    final Widget line = UntrustedLine(
      text,
      max: max,
      monospace: monospace,
      style: style,
    );
    if (!tooltip) return line;
    return Tooltip(
      message: revealInvisibles(text, maxUnits: kLogsTooltipMax).text,
      child: line,
    );
  }
}
