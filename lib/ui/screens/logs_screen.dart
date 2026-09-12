// dart:html est le pattern déjà utilisé par le projet (auth_service.dart,
// store.dart) pour localStorage/Blob — app Flutter Web uniquement.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/colors.dart';
import '../../data/supabase_sync.dart';
import '../../domain/models/log_entry.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_data_table.dart';

/// Écran « Log » — journal d'activité du panneau admin (connexions +
/// actions d'administration), **réservé au compte principal (owner)**.
///
/// Les données viennent de la route Edge Function `logs/list` (tri date
/// décroissante côté serveur). La vraie sécurité est serveur (403 si le
/// compte n'est pas owner) : cet écran ne fait qu'afficher les états
/// chargement / erreur / 403 / vide / données.
///
/// Export CSV (séparateur `;`, échappement guillemets) : la page courante
/// ou l'intégralité du journal (fetch par pages de 500 côté client).
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  /// Taille de page demandée au serveur (100 lignes/page).
  static const int _pageSize = 100;

  /// Taille des lots pour l'export complet (plafond serveur : 500).
  static const int _exportChunk = 500;

  List<LogEntry> _logs = <LogEntry>[];
  int _total = 0;
  int _page = 0;
  String _source = 'all';

  bool _loading = false;
  bool _exporting = false;
  bool _forbidden = false;
  String? _error;

  // ── Archives mensuelles ──
  List<_LogArchive> _archives = <_LogArchive>[];
  bool _archivesLoading = false;
  String? _archivesError;

  /// Nom de table de l'archive en cours de téléchargement / suppression
  /// (un seul traitement à la fois, indicateur par ligne).
  String? _archiveBusy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load(0);
      _loadArchives();
    });
  }

  int get _totalPages => (_total / _pageSize).ceil().clamp(1, 1 << 30);

  /// Charge la page [page] du journal (filtre courant [_source]).
  Future<void> _load(int page) async {
    final sync = context.read<StoreController>().sync;
    if (sync == null) {
      setState(() => _error = 'Mode démo : pas de connexion Supabase.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _forbidden = false;
    });
    try {
      final res = await sync.fetchLogs(
        page: page,
        pageSize: _pageSize,
        source: _source,
      );
      if (!mounted) return;
      setState(() {
        _logs = res.items;
        _total = res.total;
        _page = page;
        _loading = false;
      });
    } on AdminForbiddenException {
      // 403 : compte non owner — le serveur a tranché, message dédié.
      if (!mounted) return;
      setState(() {
        _forbidden = true;
        _loading = false;
      });
    } on AdminAuthException {
      // 401 : session expirée → logout forcé (même règle que les écritures).
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _onSourceChanged(String source) {
    if (source == _source) return;
    setState(() => _source = source);
    _load(0); // changement de filtre → retour page 1
  }

  // ---------------------------------------------------------------------------
  // Export CSV
  // ---------------------------------------------------------------------------

  /// Échappe une cellule CSV (séparateur `;`) : entoure de guillemets si la
  /// valeur contient `"`, `;` ou un retour à la ligne, et double les
  /// guillemets internes.
  static String _csvCell(String value) {
    final bool needsQuotes = value.contains('"') ||
        value.contains(';') ||
        value.contains('\n') ||
        value.contains('\r');
    final String escaped = value.replaceAll('"', '""');
    return needsQuotes ? '"$escaped"' : escaped;
  }

  /// Sérialise des logs en CSV : en-tête `at;username;type;action;detail`
  /// + une ligne par entrée. BOM UTF-8 en tête pour Excel.
  static String _toCsv(List<LogEntry> logs) {
    final StringBuffer sb = StringBuffer('\uFEFF')
      ..writeln('at;username;type;action;detail');
    for (final LogEntry l in logs) {
      sb.writeln(
        <String>[
          _csvCell(l.at?.toIso8601String() ?? ''),
          _csvCell(l.username),
          _csvCell(l.type),
          _csvCell(l.action),
          _csvCell(l.detail),
        ].join(';'),
      );
    }
    return sb.toString();
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

  static String _fileStamp() {
    final DateTime d = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}';
  }

  /// Export de la page courante (déjà en mémoire — aucun appel réseau).
  void _exportPage() {
    _downloadCsv(
      _toCsv(_logs),
      'logs_page_${_page + 1}_${_fileStamp()}.csv',
    );
  }

  /// Export de TOUT le journal : fetch toutes les pages par lots de 500
  /// (plafond serveur) avec le filtre courant, puis un seul fichier CSV.
  Future<void> _exportAll() async {
    final sync = context.read<StoreController>().sync;
    if (sync == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final first = await sync.fetchLogs(
        page: 0,
        pageSize: _exportChunk,
        source: _source,
      );
      final List<LogEntry> all = List<LogEntry>.from(first.items);
      final int pages = (first.total / _exportChunk).ceil();
      for (var p = 1; p < pages; p++) {
        final res = await sync.fetchLogs(
          page: p,
          pageSize: _exportChunk,
          source: _source,
        );
        all.addAll(res.items);
      }
      if (!mounted) return;
      _downloadCsv(_toCsv(all), 'logs_complets_${_fileStamp()}.csv');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export terminé : ${all.length} lignes.')),
      );
    } on AdminForbiddenException {
      if (!mounted) return;
      setState(() => _forbidden = true);
    } on AdminAuthException {
      if (!mounted) return;
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export impossible : $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Archives mensuelles
  // ---------------------------------------------------------------------------

  /// Charge la liste des archives (route EF `logs/archives/list`).
  Future<void> _loadArchives() async {
    final sync = context.read<StoreController>().sync;
    if (sync == null) return;
    setState(() {
      _archivesLoading = true;
      _archivesError = null;
    });
    try {
      final List<Map<String, dynamic>> rows = await sync.fetchLogArchives();
      if (!mounted) return;
      setState(() {
        _archives = rows.map(_LogArchive.fromJson).toList();
        _archivesLoading = false;
      });
    } on AdminForbiddenException {
      // 403 : l'écran principal affiche déjà l'état « réservé au compte
      // principal » — la section archives reste simplement vide.
      if (!mounted) return;
      setState(() {
        _archives = <_LogArchive>[];
        _archivesLoading = false;
      });
    } on AdminAuthException {
      if (!mounted) return;
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _archivesError = e.toString();
        _archivesLoading = false;
      });
    }
  }

  /// Télécharge l'archive et l'exporte en CSV (même format que l'export
  /// de l'écran : BOM UTF-8, en-tête `at;username;type;action;detail`).
  Future<void> _downloadArchive(_LogArchive archive) async {
    final sync = context.read<StoreController>().sync;
    if (sync == null || _archiveBusy != null) return;
    setState(() => _archiveBusy = archive.tableName);
    try {
      final List<LogEntry> logs = await sync.downloadLogArchive(
        archive.tableName,
      );
      if (!mounted) return;
      _downloadCsv(
        _toCsv(logs),
        'logs_archive_${archive.tableName}_${_fileStamp()}.csv',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Archive « ${archive.periodLabel} » exportée : '
            '${logs.length} lignes.',
          ),
        ),
      );
    } on AdminAuthException {
      if (!mounted) return;
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Téléchargement impossible : $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _archiveBusy = null);
    }
  }

  /// Suppression DÉFINITIVE d'une archive : dialog de confirmation
  /// explicite obligatoire (action irréversible côté serveur).
  Future<void> _confirmDeleteArchive(_LogArchive archive) async {
    final sync = context.read<StoreController>().sync;
    if (sync == null || _archiveBusy != null) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Supprimer l\'archive ?'),
        content: Text(
          'Supprimer définitivement l\'archive « ${archive.periodLabel} » '
          '(${archive.rowsCount} lignes) ?\n\n'
          'Cette action est irréversible.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _archiveBusy = archive.tableName);
    try {
      await sync.deleteLogArchive(archive.tableName);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Archive « ${archive.periodLabel} » supprimée.'),
        ),
      );
      await _loadArchives();
    } on AdminAuthException {
      if (!mounted) return;
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Suppression impossible : $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _archiveBusy = null);
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  /// Date au format JJ/MM/AAAA HH:mm (heure locale du navigateur).
  static String _fmtDate(DateTime? at) {
    if (at == null) return '—';
    final DateTime d = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  Widget _typeChip(LogEntry log) {
    final bool auth = log.isAuth;
    final Color color = auth ? AppColors.categoryLink : AppColors.neonViolet;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        auth ? 'auth' : 'action',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    // État 403 : réservé au compte principal.
    if (_forbidden) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded,
                size: 40, color: theme.textTheme.bodySmall?.color),
            const SizedBox(height: 12),
            Text('Réservé au compte principal.',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Le journal d\'activité n\'est consultable que par le compte '
              'propriétaire (contrôle appliqué côté serveur).',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // État erreur (hors 403).
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 18, color: Colors.orange.shade300),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _error!,
                      style: TextStyle(color: Colors.orange.shade300),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _load(_page),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      );
    }

    // État chargement initial (aucune donnée à montrer).
    if (_loading && _logs.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }

    // État vide.
    if (_logs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_rounded,
                size: 40, color: theme.textTheme.bodySmall?.color),
            const SizedBox(height: 12),
            Text('Aucun log pour ce filtre.',
                style: theme.textTheme.titleMedium),
          ],
        ),
      );
    }

    // État données : pagination serveur + tableau.
    final int firstRow = _page * _pageSize + 1;
    final int lastRow =
        ((_page + 1) * _pageSize).clamp(0, _total).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Barre de pagination (basée sur le total serveur) ──
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.first_page_rounded),
              onPressed: _page > 0 && !_loading ? () => _load(0) : null,
              tooltip: 'Première page',
            ),
            IconButton(
              icon: const Icon(Icons.chevron_left_rounded),
              onPressed:
                  _page > 0 && !_loading ? () => _load(_page - 1) : null,
              tooltip: 'Page précédente',
            ),
            const SizedBox(width: 8),
            Text(
              'Page ${_page + 1} / $_totalPages'
              ' ($firstRow-$lastRow sur $_total)',
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.chevron_right_rounded),
              onPressed: _page < _totalPages - 1 && !_loading
                  ? () => _load(_page + 1)
                  : null,
              tooltip: 'Page suivante',
            ),
            IconButton(
              icon: const Icon(Icons.last_page_rounded),
              onPressed: _page < _totalPages - 1 && !_loading
                  ? () => _load(_totalPages - 1)
                  : null,
              tooltip: 'Dernière page',
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminDataTable(
          columns: const ['Date', 'Compte', 'Type', 'Action', 'Détail'],
          rows: _logs
              .map(
                (l) => <Widget>[
                  Text(
                    _fmtDate(l.at),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    l.username,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _typeChip(l),
                  ),
                  Text(l.action, style: const TextStyle(fontSize: 12.5)),
                  Tooltip(
                    message: l.detail,
                    child: Text(
                      l.detail,
                      style: const TextStyle(fontSize: 12.5),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
              .toList(),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Section « Archives mensuelles »
  // ---------------------------------------------------------------------------

  Widget _buildArchivesSection(ThemeData theme) {
    final Color? dim = theme.textTheme.bodySmall?.color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 32),
        Divider(color: dim?.withValues(alpha: 0.25)),
        const SizedBox(height: 20),
        Row(
          children: [
            Text('Archives mensuelles', style: theme.textTheme.titleMedium),
            const Spacer(),
            if (_archivesLoading)
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
                onPressed: _loadArchives,
                icon: const Icon(Icons.refresh_rounded, size: 20),
                tooltip: 'Rafraîchir les archives',
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Le journal du mois écoulé est archivé automatiquement en fin de '
          'mois. Chaque archive est téléchargeable en CSV.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (_archivesError != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: Colors.orange.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 18, color: Colors.orange.shade300),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _archivesError!,
                    style: TextStyle(color: Colors.orange.shade300),
                  ),
                ),
                TextButton(
                  onPressed: _loadArchives,
                  child: const Text('Réessayer'),
                ),
              ],
            ),
          )
        else if (_archivesLoading && _archives.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          )
        else if (_archives.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              children: [
                Icon(Icons.inventory_2_outlined, size: 36, color: dim),
                const SizedBox(height: 10),
                Text(
                  'Aucune archive pour l\'instant — le premier archivage '
                  'automatique a lieu en fin de mois.',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else
          ..._archives.map((a) => _archiveRow(a, theme)),
      ],
    );
  }

  Widget _archiveRow(_LogArchive archive, ThemeData theme) {
    final bool busy = _archiveBusy == archive.tableName;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.neonViolet.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: AppColors.neonViolet.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.archive_outlined,
              size: 20, color: AppColors.neonViolet.withValues(alpha: 0.9)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                  '${_fmtDate(archive.createdAt)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: theme.textTheme.bodySmall?.color,
                    fontFeatures: const [FontFeature.tabularFigures()],
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
          else ...[
            IconButton(
              onPressed: _archiveBusy == null
                  ? () => _downloadArchive(archive)
                  : null,
              icon: const Icon(Icons.download_rounded, size: 20),
              tooltip: 'Télécharger (CSV)',
            ),
            IconButton(
              onPressed: _archiveBusy == null
                  ? () => _confirmDeleteArchive(archive)
                  : null,
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: Colors.red.shade300,
              ),
              tooltip: 'Supprimer définitivement',
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── En-tête : titre + filtre source + actions ──
          Row(
            children: [
              Text('Journal d\'activité', style: theme.textTheme.titleLarge),
              const Spacer(),
              // Filtre source (all | auth | actions).
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'all', label: Text('Tout')),
                  ButtonSegment(value: 'auth', label: Text('Connexions')),
                  ButtonSegment(value: 'actions', label: Text('Actions')),
                ],
                selected: {_source},
                onSelectionChanged: (Set<String> sel) =>
                    _onSourceChanged(sel.first),
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStateProperty.all(
                    const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Rafraîchir / indicateur de chargement.
              if (_loading)
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else
                IconButton(
                  onPressed: () => _load(_page),
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Rafraîchir',
                ),
              // Export CSV (page courante ou intégralité).
              if (_exporting)
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else
                PopupMenuButton<String>(
                  icon: const Icon(Icons.download_rounded),
                  tooltip: 'Exporter en CSV',
                  enabled: !_loading && !_forbidden && _logs.isNotEmpty,
                  onSelected: (String choice) {
                    if (choice == 'page') {
                      _exportPage();
                    } else {
                      _exportAll();
                    }
                  },
                  itemBuilder: (BuildContext context) => const [
                    PopupMenuItem(
                      value: 'page',
                      child: ListTile(
                        leading: Icon(Icons.description_outlined),
                        title: Text('Exporter la page (CSV)'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'all',
                      child: ListTile(
                        leading: Icon(Icons.download_done_rounded),
                        title: Text('Exporter tout (CSV)'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Connexions et actions d\'administration, plus récentes en '
            'premier. Réservé au compte principal.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          _buildBody(theme),
          if (!_forbidden) _buildArchivesSection(theme),
        ],
      ),
    );
  }
}

/// Archive mensuelle du journal d'activité (route EF `logs/archives/list`).
///
/// Une archive est une table serveur contenant les logs d'un mois écoulé.
/// La suppression (`logs/archive/delete`) est définitive et irréversible.
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
