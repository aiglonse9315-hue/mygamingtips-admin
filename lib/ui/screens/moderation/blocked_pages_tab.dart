// Onglet « Pages bloquées » de l'écran Modération (P4b-3, lot L7, conception
// §6.7) : `moderation/blocked-pages/list` (pages de 100, tri par id), « Page
// X / N ». Colonnes : URL (aperçu révélé 120, chasse fixe, infobulle = URL
// révélée complète, JAMAIS cliquable) · Hôte (révélé 60, S-04) · État ·
// Catégorie · Date · Actions.
//
// Actions (compte principal) : `actionsForActiveAutoBan(status, 'page')` —
// « Détail », « Confirmer » (en revue), « Lever » (motif obligatoire, détail
// replié : `AutoBanLiftDialog`) sur `ban_event_id` ; ligne sans
// `ban_event_id` → aucune action. Après une décision : relecture de la page
// et des réglages de l'en-tête.
//
// Aucun Provider : testable en VM.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show AdminAuthException, AdminForbiddenException, SupabaseSync, errorText;
import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_screen_rules.dart';
import '../../../domain/moderation_text.dart';
import '../../widgets/moderation/moderation_ui.dart';
import '../../widgets/moderation/status_badges.dart';
import 'moderation_common.dart';

/// Longueur maximale de l'URL révélée dans l'infobulle.
const int _kUrlTooltipMaxUnits = 2048;

class BlockedPagesTab extends StatefulWidget {
  const BlockedPagesTab({
    super.key,
    required this.sync,
    required this.isOwner,
    required this.onAuthError,
    this.onChanged,
    this.refreshSeq = 0,
  });

  final SupabaseSync sync;
  final bool isOwner;
  final VoidCallback onAuthError;

  /// Après une décision : relire les réglages de l'en-tête.
  final VoidCallback? onChanged;
  final int refreshSeq;

  @override
  State<BlockedPagesTab> createState() => _BlockedPagesTabState();
}

class _BlockedPagesTabState extends State<BlockedPagesTab> {
  static const List<ModerationColumn> _columns = <ModerationColumn>[
    ModerationColumn('URL', flex: 7),
    ModerationColumn('Hôte', flex: 3),
    ModerationColumn('État', flex: 3),
    ModerationColumn('Catégorie', flex: 3),
    ModerationColumn('Date', flex: 3),
    ModerationColumn('Actions', flex: 5),
  ];

  List<BlockedPage> _pages = const <BlockedPage>[];
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  bool _loaded = false;
  bool _forbidden = false;
  String? _error;
  int _loadSeq = 0;
  final Set<int> _busyIds = <int>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(0));
    });
  }

  @override
  void didUpdateWidget(BlockedPagesTab old) {
    super.didUpdateWidget(old);
    if (old.refreshSeq != widget.refreshSeq) unawaited(_load(_page));
  }

  Future<void> _load(int page) async {
    final int seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final BlockedPagesPage p = await widget.sync.fetchBlockedPages(
        page: page,
        pageSize: kBlockedPagesPageSize,
      );
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _pages = p.pages;
        _total = p.total;
        _page = page;
        _loading = false;
        _loaded = true;
        _forbidden = false;
      });
    } on AdminAuthException {
      if (mounted && seq == _loadSeq) setState(() => _loading = false);
      widget.onAuthError();
    } on AdminForbiddenException {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _forbidden = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  void _applyOutcome(DecisionOutcome o, int pageId) {
    if (!mounted || !o.reloadQueue) return;
    final int left = o.removeItem
        ? _pages.where((BlockedPage p) => p.id != pageId).length
        : _pages.length;
    unawaited(
      _load(
        pageAfterRemoval(
          page: _page,
          itemsLeftOnPage: left,
          total: o.removeItem && _total > 0 ? _total - 1 : _total,
          pageSize: kBlockedPagesPageSize,
        ),
      ),
    );
    widget.onChanged?.call();
  }

  Future<void> _onAction(BlockedPage p, ReviewAction a) async {
    final int? eventId = p.banEventId;
    if (eventId == null) return;
    final String label = oneLinePreview(p.url, max: 60);
    setState(() => _busyIds.add(p.id));
    try {
      if (a == ReviewAction.detail) {
        await openEventDetail(
          context,
          sync: widget.sync,
          eventId: eventId,
          actions: blockedPageActions(p, isOwner: widget.isOwner),
          targetLabel: label,
          targetKind: 'page',
          onAuthError: widget.onAuthError,
          onOutcome: (DecisionOutcome o) => _applyOutcome(o, p.id),
        );
        return;
      }
      final ReviewDecision? decision = decisionForAction(a);
      if (decision == null) return;
      await runReviewDecision(
        context,
        sync: widget.sync,
        eventId: eventId,
        decision: decision,
        targetLabel: label,
        targetKind: 'page',
        liftFromList: true,
        onAuthError: widget.onAuthError,
        onOutcome: (DecisionOutcome o) => _applyOutcome(o, p.id),
      );
    } finally {
      if (mounted) setState(() => _busyIds.remove(p.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_forbidden) return const ModerationForbiddenView();
    final ThemeData theme = Theme.of(context);
    final TextStyle small = theme.textTheme.bodySmall ?? const TextStyle();
    final String? error = _error;
    return ListView(
      padding: const EdgeInsets.only(top: 16, bottom: 16),
      children: <Widget>[
        Text(
          kBlockedPagesHelp,
          key: const Key('moderation-pages-help'),
          style: small,
        ),
        const SizedBox(height: 12),
        if (error != null) ...<Widget>[
          ModerationErrorBanner(message: error, onRetry: () => _load(_page)),
          const SizedBox(height: 12),
        ],
        if (!_loaded && error == null)
          const ModerationLoadingView()
        else if (_loaded && _pages.isEmpty)
          const ModerationEmptyView(
            icon: Icons.public_off_rounded,
            message: kNoBlockedPagesMessage,
            messageKey: Key('moderation-pages-empty'),
          )
        else if (_loaded) ...<Widget>[
          ModerationPaginationBar(
            page: _page,
            pageSize: kBlockedPagesPageSize,
            total: _total,
            loading: _loading,
            range: false,
            onPage: (int p) => unawaited(_load(p)),
          ),
          const SizedBox(height: 8),
          ModerationTable(
            key: const Key('moderation-pages-table'),
            columns: _columns,
            minWidth: 1000,
            rowKeys: <Key>[
              for (final BlockedPage p in _pages)
                ValueKey<String>('moderation-page-row-${p.id}'),
            ],
            rows: <List<Widget>>[
              for (final BlockedPage p in _pages) _row(p, small),
            ],
          ),
        ],
      ],
    );
  }

  List<Widget> _row(BlockedPage p, TextStyle small) {
    final bool busy = _busyIds.contains(p.id);
    final List<ReviewAction> actions = blockedPageActions(
      p,
      isOwner: widget.isOwner,
    );
    final String? host = p.host;
    return <Widget>[
      RevealedCell(
        oneLinePreview(p.url),
        key: ValueKey<String>('moderation-page-url-${p.id}'),
        tooltip: revealInvisibles(p.url, maxUnits: _kUrlTooltipMaxUnits).text,
        monospace: true,
      ),
      RevealedCell(
        host == null || host.isEmpty ? '—' : oneLinePreview(host, max: 60),
        key: ValueKey<String>('moderation-page-host-${p.id}'),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: BanOriginBadge(status: p.status),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: CategoryChip(code: p.category),
      ),
      Text(formatModerationDate(p.createdAt), style: small),
      Wrap(
        spacing: 6,
        runSpacing: 4,
        children: <Widget>[
          for (final ReviewAction a in actions)
            reviewActionButton(
              a,
              key: ValueKey<String>('moderation-page-${p.id}-${a.name}'),
              onPressed: busy ? null : () => unawaited(_onAction(p, a)),
            ),
          if (busy) kButtonSpinner,
        ],
      ),
    ];
  }
}
