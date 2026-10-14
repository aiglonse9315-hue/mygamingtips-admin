// dart:html est le pattern déjà utilisé par le projet (auth_service.dart,
// store.dart) pour localStorage/Blob — app Flutter Web uniquement.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/supabase_sync.dart';
import '../../domain/logs_screen_rules.dart';
import '../../domain/moderation_screen_rules.dart' show kModerationDemoMessage;
import '../../state/store_controller.dart';
import 'logs/attempts_tab.dart';
import 'logs/journal_tab.dart';
import 'moderation/moderation_common.dart' show ModerationEmptyView;

/// Écran « Log » — journal d'activité du panneau admin (connexions +
/// actions d'administration) et journal des tentatives (accès refusés),
/// **réservé au compte principal (owner)**.
///
/// Les données viennent des routes Edge Function `logs/list` et
/// `logs/attempts` (tri date décroissante côté serveur). La vraie sécurité
/// est serveur (403 si le compte n'est pas owner) : cet écran ne fait
/// qu'afficher les états chargement / erreur / 403 / vide / données.
///
/// COLLE (P4d L3) : lit `StoreController.sync` et `store.onAuthError`
/// (401 → déconnexion) et fournit le téléchargement navigateur des CSV
/// (dart:html) ; les onglets (`logs/journal_tab.dart`,
/// `logs/attempts_tab.dart`) n'importent ni Provider ni dart:html →
/// testables en VM. Export CSV : fichier Dart pur `domain/logs_export.dart`
/// (cellules neutralisées, export « tout » à borne stable).
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: kLogsTabLabels.length,
    vsync: this,
  );

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Déclenche le téléchargement navigateur d'un CSV (Blob + anchor —
  /// pattern web standard, aucune dépendance).
  static void _downloadCsv(String csv, String filename) {
    final html.Blob blob = html.Blob([csv], 'text/csv;charset=utf-8');
    final String url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', filename)
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.read<StoreController>();
    final SupabaseSync? sync = store.sync;
    if (sync == null) {
      return const ModerationEmptyView(
        icon: Icons.cloud_off_rounded,
        message: kModerationDemoMessage,
        messageKey: Key('logs-demo'),
      );
    }
    final ThemeData theme = Theme.of(context);
    void onAuthError() => store.onAuthError?.call();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('Journal d\'activité', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Connexions et actions d\'administration, plus récentes en '
            'premier, et tentatives refusées. Réservé au compte principal.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: <Widget>[
              for (final String label in kLogsTabLabels) Tab(text: label),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                LogJournalTab(
                  sync: sync,
                  onAuthError: onAuthError,
                  saveCsv: _downloadCsv,
                ),
                LogAttemptsTab(
                  sync: sync,
                  onAuthError: onAuthError,
                  saveCsv: _downloadCsv,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
