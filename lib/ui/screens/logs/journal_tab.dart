// Onglet « Journal » du menu « Log » (P4d L3, conception
// tools/PLAN_VISION2_P4d_CONCEPTION.md §4 « L3 — CONTRAT ») : journal
// d'activité (`logs/list`, pages de 100, tri par date décroissante côté
// serveur), filtre de source (Tout / Connexions / Actions), bascule
// « Masquer l'activité normale », export CSV, archives.
//
// Bascule APRÈS le choix de la source, éteinte par défaut. Allumée → appel
// avec `masquer: true` : le FILTRE est fait par le serveur (sa règle n'est
// jamais dans ce dépôt public) ; la page affichée porte « N lignes
// masquées » (`masquees`) ou, si le serveur répond `filtre_applique: false`,
// « Filtre indisponible : tout est affiché ». Pagination et export suivent
// la bascule.
//
// Colonnes : Date · Compte · Type · Réussite · Action · Détail · IP ·
// User-agent · Session (8 premiers caractères). Compte, action (route),
// détail, IP et user-agent : texte NON FIABLE (`UntrustedCell`).
//
// « Réessayer » et « Rafraîchir » relisent la page DEMANDÉE ; une page
// au-delà de la fin (lignes archivées ou purgées) recharge la dernière page
// qui existe ; message « vide » seulement pour un total nul. Section des
// archives à clé stable, gardée en vie.
//
// Onglet gardé en vie. Aucun Provider ni dart:html : testable en VM.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../data/supabase_sync.dart'
    show AdminAuthException, AdminForbiddenException, SupabaseSync, errorText;
import '../../../domain/logs_export.dart';
import '../../../domain/logs_screen_rules.dart';
import '../../../domain/models/log_entry.dart';
import '../../../domain/moderation_actions.dart' show OutcomeTone;
import '../../widgets/moderation/moderation_ui.dart';
import '../moderation/moderation_common.dart';
import 'archives_section.dart';
import 'logs_common.dart';

class LogJournalTab extends StatefulWidget {
  const LogJournalTab({
    super.key,
    required this.sync,
    required this.onAuthError,
    required this.saveCsv,
  });

  final SupabaseSync sync;
  final VoidCallback onAuthError;
  final CsvSaver saveCsv;

  @override
  State<LogJournalTab> createState() => _LogJournalTabState();
}

class _LogJournalTabState extends State<LogJournalTab>
    with AutomaticKeepAliveClientMixin {
  static const List<ModerationColumn> _columns = <ModerationColumn>[
    ModerationColumn('Date', flex: 9),
    ModerationColumn('Compte', flex: 9),
    ModerationColumn('Type', flex: 6),
    ModerationColumn('Réussite', flex: 5),
    ModerationColumn('Action', flex: 10),
    ModerationColumn('Détail', flex: 16),
    ModerationColumn('IP', flex: 9),
    ModerationColumn('User-agent', flex: 14),
    ModerationColumn('Session', flex: 6),
  ];

  List<LogEntry> _logs = const <LogEntry>[];
  int _total = 0;

  /// Page AFFICHÉE (barre de pagination, nom du fichier de l'export page).
  int _page = 0;

  /// Page DEMANDÉE par le dernier chargement, réussi ou non : « Réessayer »
  /// et « Rafraîchir » la relisent (après l'échec d'un changement de source
  /// ou de bascule : page 1 du nouveau filtre, pas l'ancienne page).
  int _wantedPage = 0;
  String _source = 'all';

  /// Bascule « Masquer l'activité normale » (éteinte par défaut).
  bool _masquer = false;

  // État du filtre de la page AFFICHÉE (pas de la bascule pendant un
  // chargement) : demandé, appliqué par le serveur, lignes cachées.
  bool _shownMasquer = false;
  bool _filtreApplique = false;
  int _masquees = 0;

  bool _loading = false;
  bool _loaded = false;
  bool _exporting = false;
  bool _forbidden = false;
  String? _error;
  int _loadSeq = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(0));
    });
  }

  /// Charge la page [page] du journal (source et bascule courantes). Page
  /// au-delà de la fin (lignes archivées ou purgées pendant la
  /// consultation) → dernière page qui existe.
  Future<void> _load(int page) async {
    final int seq = ++_loadSeq;
    final String source = _source;
    final bool masquer = _masquer;
    _wantedPage = page;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final LogPage p = await widget.sync.fetchLogs(
        page: page,
        pageSize: kLogsPageSize,
        source: source,
        masquer: masquer,
      );
      if (!mounted || seq != _loadSeq) return;
      final int? last = lastPageIfBeyondEnd(
        page: page,
        empty: p.items.isEmpty,
        total: p.total,
      );
      if (last != null) {
        await _load(last);
        return;
      }
      setState(() {
        _logs = p.items;
        _total = p.total;
        _page = page;
        _shownMasquer = masquer;
        _filtreApplique = p.filtreApplique;
        _masquees = p.masquees;
        _loading = false;
        _loaded = true;
        _forbidden = false;
      });
    } on AdminForbiddenException {
      // 403 : compte non owner — le serveur a tranché, message dédié.
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _forbidden = true;
        _loading = false;
      });
    } on AdminAuthException {
      // 401 : session expirée → déconnexion (même règle que les écritures).
      if (mounted && seq == _loadSeq) setState(() => _loading = false);
      widget.onAuthError();
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  void _onSourceChanged(String source) {
    if (source == _source) return;
    setState(() => _source = source);
    unawaited(_load(0)); // changement de filtre → retour page 1
  }

  void _onMaskChanged(bool value) {
    if (value == _masquer) return;
    setState(() => _masquer = value);
    unawaited(_load(0)); // autre jeu de lignes → retour page 1
  }

  // ---------------------------------------------------------------------------
  // Export CSV
  // ---------------------------------------------------------------------------

  /// Suffixe des noms de fichiers quand le filtre du serveur a tourné.
  static String _filterSuffix(bool filtered) => filtered ? '_filtre' : '';

  /// Export de la page courante (déjà en mémoire — aucun appel réseau).
  void _exportPage() {
    widget.saveCsv(
      logsToCsv(_logs),
      'logs_page_${_page + 1}'
      '${_filterSuffix(_shownMasquer && _filtreApplique)}_'
      '${exportFileStamp(DateTime.now())}.csv',
    );
  }

  /// Export de TOUT le journal (source et bascule courantes) par pages de
  /// 500, à borne stable ([collectStableExport]), puis un seul fichier.
  Future<void> _exportAll() async {
    if (_exporting) return;
    final String source = _source;
    final bool masquer = _masquer;
    // Enregistreur pris AVANT l'attente : le fichier est enregistré même si
    // l'onglet est démonté entre-temps (menu quitté ; même motif que la
    // section Archives, relecture P4D-L3-A03) ; seul le message en dépend.
    final CsvSaver save = widget.saveCsv;
    setState(() => _exporting = true);
    try {
      final StableExport<LogEntry> r = await collectStableExport<LogEntry>(
        fetchPage: (int p) async {
          final LogPage page = await widget.sync.fetchLogs(
            page: p,
            pageSize: kLogsExportChunk,
            source: source,
            masquer: masquer,
          );
          return (
            items: page.items,
            total: page.total,
            filtered: page.filtreApplique,
          );
        },
        pageSize: kLogsExportChunk,
        dateOf: (LogEntry l) => l.at,
        fieldsOf: logCsvFields,
      );
      save(
        logsToCsv(r.rows),
        'logs_complets${_filterSuffix(r.filtered)}_'
        '${exportFileStamp(DateTime.now())}.csv',
      );
      if (!mounted) return;
      showModerationSnack(
        context,
        exportDoneMessage(r, maskRequested: masquer),
        tone: r.complete && (r.filtered || !masquer)
            ? OutcomeTone.success
            : OutcomeTone.warning,
      );
    } on AdminForbiddenException {
      if (!mounted) return;
      setState(() => _forbidden = true);
    } on AdminAuthException {
      widget.onAuthError();
    } on ExportFilterChangedException {
      if (!mounted) return;
      showModerationSnack(
        context,
        ExportFilterChangedException.message,
        tone: OutcomeTone.warning,
      );
    } catch (e) {
      if (!mounted) return;
      showModerationSnack(
        context,
        'Export impossible : ${errorText(e)}',
        tone: OutcomeTone.error,
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_forbidden) return const LogsForbiddenView();
    final String? error = _error;
    return ListView(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      children: <Widget>[
        _controls(),
        const SizedBox(height: 16),
        if (error != null)
          ModerationErrorBanner(
            message: error,
            onRetry: () => _load(_wantedPage),
          )
        else if (!_loaded)
          const ModerationLoadingView()
        else if (showLogsEmpty(empty: _logs.isEmpty, total: _total))
          const ModerationEmptyView(
            icon: Icons.receipt_long_rounded,
            message: kLogsEmptyMessage,
            messageKey: Key('logs-empty'),
          )
        else ...<Widget>[
          ModerationPaginationBar(
            page: _page,
            pageSize: kLogsPageSize,
            total: _total,
            loading: _loading,
            onPage: (int p) => unawaited(_load(p)),
          ),
          if (_logs.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            ModerationTable(
              key: const Key('logs-table'),
              columns: _columns,
              minWidth: 1180,
              rowKeys: <Key>[
                for (int i = 0; i < _logs.length; i++)
                  ValueKey<String>('logs-row-$i'),
              ],
              rows: <List<Widget>>[
                for (int i = 0; i < _logs.length; i++) _row(_logs[i], i),
              ],
            ),
          ],
        ],
        // Clé STABLE : la section garde son état (liste, téléchargement en
        // cours) quand les enfants au-dessus changent (bandeau d'erreur,
        // chargement, journal vide) ; gardée en vie hors de la vue.
        LogArchivesSection(
          key: const ValueKey<String>('logs-archives-section'),
          sync: widget.sync,
          onAuthError: widget.onAuthError,
          saveCsv: widget.saveCsv,
        ),
      ],
    );
  }

  /// Source, bascule et son état, rafraîchir, export.
  Widget _controls() {
    return Row(
      children: <Widget>[
        Expanded(
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              // Filtre source (all | auth | actions).
              SegmentedButton<String>(
                key: const Key('logs-source'),
                segments: const <ButtonSegment<String>>[
                  ButtonSegment<String>(value: 'all', label: Text('Tout')),
                  ButtonSegment<String>(
                    value: 'auth',
                    label: Text('Connexions'),
                  ),
                  ButtonSegment<String>(
                    value: 'actions',
                    label: Text('Actions'),
                  ),
                ],
                selected: <String>{_source},
                onSelectionChanged: (Set<String> sel) =>
                    _onSourceChanged(sel.first),
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStateProperty.all(
                    const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              // Bascule « Masquer l'activité normale » (après la source).
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Switch(
                    key: const Key('logs-mask'),
                    value: _masquer,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: _onMaskChanged,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    kLogsMaskToggleLabel,
                    style: TextStyle(fontSize: 12.5),
                  ),
                ],
              ),
              if (_loaded && _shownMasquer)
                _filtreApplique
                    ? ModerationPill(
                        key: const Key('logs-masked-count'),
                        label: maskedCountLabel(_masquees),
                        color: ModerationColors.info,
                        icon: Icons.visibility_off_outlined,
                      )
                    : ModerationPill(
                        key: const Key('logs-filter-unavailable'),
                        label: kLogsFilterUnavailable,
                        color: ModerationColors.warning,
                        icon: Icons.warning_amber_rounded,
                      ),
            ],
          ),
        ),
        // Rafraîchir / indicateur de chargement.
        if (_loading)
          const LogsBusyBox(key: Key('logs-loading'))
        else
          IconButton(
            key: const Key('logs-refresh'),
            onPressed: () => _load(_wantedPage),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Rafraîchir',
          ),
        // Export CSV (page courante ou intégralité).
        LogsExportMenu(
          enabled: !_loading && _logs.isNotEmpty,
          exporting: _exporting,
          onExportPage: _exportPage,
          onExportAll: () => unawaited(_exportAll()),
        ),
      ],
    );
  }

  /// Cellules d'une ligne du journal.
  List<Widget> _row(LogEntry l, int i) => <Widget>[
    Text(
      formatLogDate(l.at),
      style: const TextStyle(
        fontSize: 12.5,
        fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
      ),
    ),
    UntrustedCell(
      l.username,
      key: ValueKey<String>('logs-user-$i'),
      max: 60,
      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
    ),
    Align(alignment: Alignment.centerLeft, child: _typeChip(l)),
    Align(
      alignment: Alignment.centerLeft,
      child: LogSuccessIcon(l.success, key: ValueKey<String>('logs-ok-$i')),
    ),
    UntrustedCell(l.action, key: ValueKey<String>('logs-action-$i'), max: 80),
    UntrustedCell(l.detail, key: ValueKey<String>('logs-detail-$i')),
    UntrustedCell(
      l.ip,
      key: ValueKey<String>('logs-ip-$i'),
      max: 45,
      monospace: true,
      tooltip: false,
    ),
    UntrustedCell(l.ua, key: ValueKey<String>('logs-ua-$i')),
    UntrustedLine(
      shortSid(l.sid),
      key: ValueKey<String>('logs-sid-$i'),
      monospace: true,
    ),
  ];

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
}
