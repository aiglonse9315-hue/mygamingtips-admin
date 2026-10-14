// Onglet « Tentatives » du menu « Log » (P4d L3, conception
// tools/PLAN_VISION2_P4d_CONCEPTION.md §4 « L3 — CONTRAT ») : journal des
// accès refusés au serveur d'administration (`logs/attempts`, compte
// principal seul, pages de 100, plus récents en premier), export CSV.
//
// Colonnes : Date (+ « dernière : … » d'une ligne regroupée dont la
// dernière date diffère) · Événement (libellé FRANÇAIS rendu par le
// serveur, « ×N » si regroupée) · Route · Login · IP · User-agent ·
// Détail. Aucun code de tentative interprété ici (dépôt public) ; route,
// login, IP, user-agent et détail : texte NON FIABLE (`UntrustedCell`).
//
// 403 → état « réservé au compte principal » ; 401 → déconnexion (comme
// l'onglet « Journal »). « Réessayer » et « Rafraîchir » relisent la page
// DEMANDÉE ; une page au-delà de la fin (tentatives archivées ou purgées)
// recharge la dernière page qui existe ; message « vide » seulement pour un
// total nul. Onglet gardé en vie. Aucun Provider ni dart:html : testable en
// VM.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show AdminAuthException, AdminForbiddenException, SupabaseSync, errorText;
import '../../../domain/logs_export.dart';
import '../../../domain/logs_screen_rules.dart';
import '../../../domain/models/security_attempt.dart';
import '../../../domain/moderation_actions.dart' show OutcomeTone;
import '../../widgets/moderation/moderation_ui.dart';
import '../moderation/moderation_common.dart';
import 'logs_common.dart';

class LogAttemptsTab extends StatefulWidget {
  const LogAttemptsTab({
    super.key,
    required this.sync,
    required this.onAuthError,
    required this.saveCsv,
  });

  final SupabaseSync sync;
  final VoidCallback onAuthError;
  final CsvSaver saveCsv;

  @override
  State<LogAttemptsTab> createState() => _LogAttemptsTabState();
}

class _LogAttemptsTabState extends State<LogAttemptsTab>
    with AutomaticKeepAliveClientMixin {
  static const List<ModerationColumn> _columns = <ModerationColumn>[
    ModerationColumn('Date', flex: 10),
    ModerationColumn('Événement', flex: 14),
    ModerationColumn('Route', flex: 9),
    ModerationColumn('Login', flex: 9),
    ModerationColumn('IP', flex: 9),
    ModerationColumn('User-agent', flex: 13),
    ModerationColumn('Détail', flex: 15),
  ];

  List<SecurityAttempt> _items = const <SecurityAttempt>[];
  int _total = 0;

  /// Page AFFICHÉE (barre de pagination, nom du fichier de l'export page).
  int _page = 0;

  /// Page DEMANDÉE par le dernier chargement, réussi ou non : « Réessayer »
  /// et « Rafraîchir » la relisent.
  int _wantedPage = 0;
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

  /// Charge la page [page]. Page au-delà de la fin (tentatives archivées ou
  /// purgées pendant la consultation) → dernière page qui existe.
  Future<void> _load(int page) async {
    final int seq = ++_loadSeq;
    _wantedPage = page;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final SecurityAttemptPage p = await widget.sync.fetchSecurityAttempts(
        page: page,
        pageSize: kLogsPageSize,
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
        _items = p.items;
        _total = p.total;
        _page = page;
        _loading = false;
        _loaded = true;
        _forbidden = false;
      });
    } on AdminForbiddenException {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _forbidden = true;
        _loading = false;
      });
    } on AdminAuthException {
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

  // ---------------------------------------------------------------------------
  // Export CSV
  // ---------------------------------------------------------------------------

  /// Export de la page courante (déjà en mémoire — aucun appel réseau).
  void _exportPage() {
    widget.saveCsv(
      attemptsToCsv(_items),
      'tentatives_page_${_page + 1}_${exportFileStamp(DateTime.now())}.csv',
    );
  }

  /// Export de TOUTES les tentatives par pages de 500, à borne stable
  /// ([collectStableExport]), puis un seul fichier.
  Future<void> _exportAll() async {
    if (_exporting) return;
    // Enregistreur pris AVANT l'attente : le fichier est enregistré même si
    // l'onglet est démonté entre-temps (relecture P4D-L3-A03, même motif).
    final CsvSaver save = widget.saveCsv;
    setState(() => _exporting = true);
    try {
      final StableExport<SecurityAttempt> r =
          await collectStableExport<SecurityAttempt>(
            fetchPage: (int p) async {
              final SecurityAttemptPage page = await widget.sync
                  .fetchSecurityAttempts(page: p, pageSize: kLogsExportChunk);
              return (items: page.items, total: page.total, filtered: false);
            },
            pageSize: kLogsExportChunk,
            dateOf: (SecurityAttempt a) => a.at,
            fieldsOf: attemptCsvFields,
          );
      save(
        attemptsToCsv(r.rows),
        'tentatives_completes_${exportFileStamp(DateTime.now())}.csv',
      );
      if (!mounted) return;
      showModerationSnack(
        context,
        exportDoneMessage(r),
        tone: r.complete ? OutcomeTone.success : OutcomeTone.warning,
      );
    } on AdminForbiddenException {
      if (!mounted) return;
      setState(() => _forbidden = true);
    } on AdminAuthException {
      widget.onAuthError();
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
    final ThemeData theme = Theme.of(context);
    final String? error = _error;
    return ListView(
      padding: const EdgeInsets.only(top: 16, bottom: 24),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Accès refusés au serveur d\'administration, plus récents en '
                'premier. Libellés fournis par le serveur.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (_loading)
              const LogsBusyBox(key: Key('logs-attempts-loading'))
            else
              IconButton(
                key: const Key('logs-attempts-refresh'),
                onPressed: () => _load(_wantedPage),
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Rafraîchir',
              ),
            LogsExportMenu(
              enabled: !_loading && _items.isNotEmpty,
              exporting: _exporting,
              onExportPage: _exportPage,
              onExportAll: () => unawaited(_exportAll()),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (error != null)
          ModerationErrorBanner(
            message: error,
            onRetry: () => _load(_wantedPage),
          )
        else if (!_loaded)
          const ModerationLoadingView()
        else if (showLogsEmpty(empty: _items.isEmpty, total: _total))
          const ModerationEmptyView(
            icon: Icons.shield_outlined,
            message: kAttemptsEmptyMessage,
            messageKey: Key('logs-attempts-empty'),
          )
        else ...<Widget>[
          ModerationPaginationBar(
            page: _page,
            pageSize: kLogsPageSize,
            total: _total,
            loading: _loading,
            onPage: (int p) => unawaited(_load(p)),
          ),
          if (_items.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            ModerationTable(
              key: const Key('logs-attempts-table'),
              columns: _columns,
              minWidth: 1180,
              rowKeys: <Key>[
                for (int i = 0; i < _items.length; i++)
                  ValueKey<String>('logs-attempt-$i'),
              ],
              rows: <List<Widget>>[
                for (int i = 0; i < _items.length; i++)
                  _row(_items[i], i, theme),
              ],
            ),
          ],
        ],
      ],
    );
  }

  /// Cellules d'une tentative.
  List<Widget> _row(SecurityAttempt a, int i, ThemeData theme) {
    final String? last = attemptLastAtLabel(a);
    const TextStyle cell = TextStyle(
      fontSize: 12.5,
      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    );
    return <Widget>[
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(formatLogDate(a.at), style: cell),
          if (last != null)
            Text(
              last,
              key: ValueKey<String>('logs-attempt-last-$i'),
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
      Row(
        children: <Widget>[
          Flexible(
            child: Text(
              attemptLabel(a),
              key: ValueKey<String>('logs-attempt-label-$i'),
              style: const TextStyle(fontSize: 12.5),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (a.isGrouped) ...<Widget>[
            const SizedBox(width: 6),
            ModerationPill(
              key: ValueKey<String>('logs-attempt-count-$i'),
              label: attemptOccurrencesLabel(a),
              color: ModerationColors.warning,
            ),
          ],
        ],
      ),
      UntrustedCell(
        a.route,
        key: ValueKey<String>('logs-attempt-route-$i'),
        max: 80,
        monospace: true,
      ),
      UntrustedCell(
        a.username,
        key: ValueKey<String>('logs-attempt-user-$i'),
        max: 60,
      ),
      UntrustedCell(
        a.ip,
        key: ValueKey<String>('logs-attempt-ip-$i'),
        max: 45,
        monospace: true,
        tooltip: false,
      ),
      UntrustedCell(a.ua, key: ValueKey<String>('logs-attempt-ua-$i')),
      UntrustedCell(a.detail, key: ValueKey<String>('logs-attempt-detail-$i')),
    ];
  }
}
