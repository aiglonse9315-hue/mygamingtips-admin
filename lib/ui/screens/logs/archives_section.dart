// Section « Archives du journal » de l'onglet « Journal » du menu « Log »
// (P4d L3) : liste (`logs/archives/list`) et téléchargement en CSV
// (`logs/archive/download`, même format que l'export du journal, 9
// colonnes). Colonnes v2 (réussite, IP, user-agent, session) : remplies
// quand la route les rend (archive créée depuis 0098) ; vides pour une
// archive d'avant 0098 (juillet à septembre 2026 : sans ces colonnes
// jusqu'à son regroupement annuel) ou si la route ne les rend pas. C'est
// une limite de la route ou de l'ancienne archive, pas des archives : la
// lecture accepte les deux formes.
//
// Bouton de suppression RETIRÉ (D7) : le serveur répond 410 à
// `logs/archive/delete` ; il regroupe et purge lui-même les archives
// anciennes. Un jeton principal volé ne peut plus effacer l'historique.
//
// État gardé en vie (et clé stable posée par l'onglet) : la liste n'est pas
// relue et un téléchargement en cours n'est pas perdu quand la section sort
// de la vue ou change de place. Le fichier est enregistré même si la
// section a été démontée pendant le téléchargement (menu quitté) ; seul le
// message a besoin d'elle.
//
// Aucun Provider ni dart:html (l'écran passe l'accès serveur,
// `onAuthError` et l'enregistreur de CSV) : testable en VM.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../data/supabase_sync.dart'
    show AdminAuthException, AdminForbiddenException, SupabaseSync, errorText;
import '../../../domain/logs_export.dart';
import '../../../domain/logs_screen_rules.dart';
import '../../../domain/models/log_entry.dart';
import '../../../domain/moderation_actions.dart' show OutcomeTone;
import '../moderation/moderation_common.dart' show showModerationSnack;
import 'logs_common.dart';

class LogArchivesSection extends StatefulWidget {
  const LogArchivesSection({
    super.key,
    required this.sync,
    required this.onAuthError,
    required this.saveCsv,
  });

  final SupabaseSync sync;
  final VoidCallback onAuthError;
  final CsvSaver saveCsv;

  @override
  State<LogArchivesSection> createState() => _LogArchivesSectionState();
}

class _LogArchivesSectionState extends State<LogArchivesSection>
    with AutomaticKeepAliveClientMixin {
  List<_LogArchive> _archives = <_LogArchive>[];
  bool _loading = false;
  String? _error;

  /// Nom de table de l'archive en cours de téléchargement (un seul
  /// traitement à la fois, indicateur par ligne).
  String? _busy;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  /// Charge la liste des archives (route EF `logs/archives/list`).
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<Map<String, dynamic>> rows = await widget.sync
          .fetchLogArchives();
      if (!mounted) return;
      setState(() {
        _archives = rows.map(_LogArchive.fromJson).toList();
        _loading = false;
      });
    } on AdminForbiddenException {
      // 403 : l'onglet affiche déjà l'état « réservé au compte principal »
      // — la section reste simplement vide.
      if (!mounted) return;
      setState(() {
        _archives = <_LogArchive>[];
        _loading = false;
      });
    } on AdminAuthException {
      if (mounted) setState(() => _loading = false);
      widget.onAuthError();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  /// Télécharge l'archive et l'exporte en CSV (même format que l'export du
  /// journal : BOM UTF-8, cellules neutralisées, colonnes v2). Le fichier
  /// est enregistré même si la section est démontée pendant l'attente.
  Future<void> _download(_LogArchive archive) async {
    if (_busy != null) return;
    // Gardés AVANT l'attente : ils ne dépendent pas de la section montée.
    final CsvSaver save = widget.saveCsv;
    final VoidCallback onAuthError = widget.onAuthError;
    setState(() => _busy = archive.tableName);
    try {
      final List<LogEntry> logs = await widget.sync.downloadLogArchive(
        archive.tableName,
      );
      save(
        logsToCsv(logs),
        'logs_archive_${archive.tableName}_'
        '${exportFileStamp(DateTime.now())}.csv',
      );
      if (!mounted) return;
      showModerationSnack(
        context,
        'Archive « ${archive.periodLabel} » exportée : '
        '${logs.length} lignes.',
      );
    } on AdminAuthException {
      onAuthError();
    } catch (e) {
      if (!mounted) return;
      showModerationSnack(
        context,
        'Téléchargement impossible : ${errorText(e)}',
        tone: OutcomeTone.error,
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final ThemeData theme = Theme.of(context);
    final Color? dim = theme.textTheme.bodySmall?.color;
    final String? error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 32),
        Divider(color: dim?.withValues(alpha: 0.25)),
        const SizedBox(height: 20),
        Row(
          children: <Widget>[
            Text('Archives du journal', style: theme.textTheme.titleMedium),
            const Spacer(),
            if (_loading)
              const SizedBox(
                width: 32,
                height: 32,
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              IconButton(
                key: const Key('logs-archives-refresh'),
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded, size: 20),
                tooltip: 'Rafraîchir les archives',
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Le journal du mois écoulé est archivé automatiquement en fin de '
          'mois ; le serveur regroupe et purge lui-même les archives '
          'anciennes. Chaque archive est téléchargeable en CSV.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (error != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: Colors.orange.shade300,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error,
                    key: const Key('logs-archives-error'),
                    style: TextStyle(color: Colors.orange.shade300),
                  ),
                ),
                TextButton(onPressed: _load, child: const Text('Réessayer')),
              ],
            ),
          )
        else if (_loading && _archives.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
          )
        else if (_archives.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              children: <Widget>[
                Icon(Icons.inventory_2_outlined, size: 36, color: dim),
                const SizedBox(height: 10),
                Text(
                  'Aucune archive pour l\'instant — le premier archivage '
                  'automatique a lieu en fin de mois.',
                  key: const Key('logs-archives-empty'),
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else
          ..._archives.map((_LogArchive a) => _row(a, theme)),
      ],
    );
  }

  Widget _row(_LogArchive archive, ThemeData theme) {
    final bool busy = _busy == archive.tableName;
    return Container(
      key: ValueKey<String>('logs-archive-${archive.tableName}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.neonViolet.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.neonViolet.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.archive_outlined,
            size: 20,
            color: AppColors.neonViolet.withValues(alpha: 0.9),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  archive.periodLabel,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${archive.rowsCount} lignes · archivée le '
                  '${formatLogDate(archive.createdAt)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: theme.textTheme.bodySmall?.color,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              key: ValueKey<String>(
                'logs-archive-download-${archive.tableName}',
              ),
              onPressed: _busy == null ? () => _download(archive) : null,
              icon: const Icon(Icons.download_rounded, size: 20),
              tooltip: 'Télécharger (CSV)',
            ),
        ],
      ),
    );
  }
}

/// Archive du journal d'activité (route EF `logs/archives/list`) : une
/// table serveur contenant les logs d'un mois écoulé (ou d'une année, après
/// le regroupement fait par le serveur).
class _LogArchive {
  const _LogArchive({
    required this.tableName,
    required this.periodLabel,
    required this.rowsCount,
    required this.createdAt,
  });

  /// Nom technique de la table d'archive (passé tel quel aux routes EF).
  final String tableName;

  /// Libellé de période affichable (ex. « Juin 2026 »).
  final String periodLabel;

  /// Nombre de lignes contenues dans l'archive.
  final int rowsCount;

  /// Date de création de l'archive (null si absente/invalide).
  final DateTime? createdAt;

  factory _LogArchive.fromJson(Map<String, dynamic> json) {
    return _LogArchive(
      tableName: json['table_name']?.toString() ?? '',
      periodLabel: json['period_label']?.toString() ?? 'Archive',
      rowsCount: (json['rows_count'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }
}
