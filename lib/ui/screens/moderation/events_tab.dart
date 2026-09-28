// Onglet « Journal » de l'écran Modération (P4b-3, lot L7, conception §6.8) :
// `moderation/events-list` (pages de 50) avec filtres « Type de cible »
// (Tous / Compte / Chaîne / Page), « Action » (Toutes + 9 libellés),
// « Clé exacte » (coupée ; UUID en minuscules ; vide → aucun filtre, v2
// C-12), boutons « Filtrer » / « Effacer ».
//
// Colonnes : Date · Action · Cible (masquage de §6.5 : une clé masquée ne
// s'affiche qu'au détail ou avec « Clé exacte », M94:2491-2507) · Origine ·
// Acteur · Catégorie · Raisons · Motif · Liens · « Détail » (lecture seule).
//
// Onglet gardé en vie (filtres conservés au changement d'onglet). Aucun
// Provider : testable en VM.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show AdminAuthException, AdminForbiddenException, SupabaseSync, errorText;
import '../../../domain/models/ban_category.dart';
import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_labels.dart';
import '../../../domain/moderation_screen_rules.dart';
import '../../widgets/moderation/moderation_ui.dart';
import '../../widgets/moderation/reason_chips.dart';
import 'moderation_common.dart';

class EventsTab extends StatefulWidget {
  const EventsTab({
    super.key,
    required this.sync,
    required this.onAuthError,
    this.refreshSeq = 0,
  });

  final SupabaseSync sync;
  final VoidCallback onAuthError;
  final int refreshSeq;

  @override
  State<EventsTab> createState() => _EventsTabState();
}

class _EventsTabState extends State<EventsTab>
    with AutomaticKeepAliveClientMixin {
  static const List<ModerationColumn> _columns = <ModerationColumn>[
    ModerationColumn('Date', flex: 9),
    ModerationColumn('Action', flex: 9),
    ModerationColumn('Cible', flex: 14),
    ModerationColumn('Origine', flex: 5),
    ModerationColumn('Acteur', flex: 11),
    ModerationColumn('Catégorie', flex: 7),
    ModerationColumn('Raisons', flex: 14),
    ModerationColumn('Motif', flex: 10),
    ModerationColumn('Liens', flex: 8),
    ModerationColumn('', flex: 7),
  ];

  /// Valeur « Tous » / « Toutes » des listes déroulantes.
  static const String _all = '';

  // Filtres saisis (appliqués par « Filtrer »).
  String _kind = _all;
  String _action = _all;
  final TextEditingController _key = TextEditingController();
  int _filterEpoch = 0;

  // Filtres appliqués.
  String? _appliedKind;
  String? _appliedAction;
  String? _appliedKey;

  List<BanEvent> _events = const <BanEvent>[];
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  bool _loaded = false;
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

  @override
  void didUpdateWidget(EventsTab old) {
    super.didUpdateWidget(old);
    if (old.refreshSeq != widget.refreshSeq) unawaited(_load(_page));
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _load(int page) async {
    final int seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final EventsPage p = await widget.sync.fetchEvents(
        page: page,
        pageSize: kEventsPageSize,
        targetKind: _appliedKind,
        targetKey: _appliedKey,
        action: _appliedAction,
      );
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _events = p.items;
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

  void _applyFilters() {
    setState(() {
      _appliedKind = _kind == _all ? null : _kind;
      _appliedAction = _action == _all ? null : _action;
      _appliedKey = normalizeEventKeyFilter(_key.text);
    });
    unawaited(_load(0));
  }

  void _clearFilters() {
    setState(() {
      _kind = _all;
      _action = _all;
      _key.clear();
      _filterEpoch++;
      _appliedKind = null;
      _appliedAction = null;
      _appliedKey = null;
    });
    unawaited(_load(0));
  }

  void _detail(BanEvent e) {
    unawaited(
      openEventDetail(
        context,
        sync: widget.sync,
        eventId: e.id,
        onAuthError: widget.onAuthError,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_forbidden) return const ModerationForbiddenView();
    final ThemeData theme = Theme.of(context);
    final TextStyle small = theme.textTheme.bodySmall ?? const TextStyle();
    final String? error = _error;
    return ListView(
      padding: const EdgeInsets.only(top: 16, bottom: 16),
      children: <Widget>[
        _filters(),
        const SizedBox(height: 12),
        if (error != null) ...<Widget>[
          ModerationErrorBanner(message: error, onRetry: () => _load(_page)),
          const SizedBox(height: 12),
        ],
        if (!_loaded && error == null)
          const ModerationLoadingView()
        else if (_loaded && _events.isEmpty)
          const ModerationEmptyView(
            icon: Icons.receipt_long_rounded,
            message: kNoEventsMessage,
            messageKey: Key('moderation-events-empty'),
          )
        else if (_loaded) ...<Widget>[
          ModerationPaginationBar(
            page: _page,
            pageSize: kEventsPageSize,
            total: _total,
            loading: _loading,
            onPage: (int p) => unawaited(_load(p)),
          ),
          const SizedBox(height: 8),
          ModerationTable(
            key: const Key('moderation-events-table'),
            columns: _columns,
            minWidth: 1180,
            rowKeys: <Key>[
              for (final BanEvent e in _events)
                ValueKey<String>('moderation-event-${e.id}'),
            ],
            rows: <List<Widget>>[
              for (final BanEvent e in _events) _row(e, small),
            ],
          ),
        ],
      ],
    );
  }

  Widget _filters() {
    final List<(String?, String)> actions = eventActionChoices();
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        SizedBox(
          width: 180,
          child: DropdownButtonFormField<String>(
            key: ValueKey<String>('moderation-events-kind-$_filterEpoch'),
            initialValue: _kind,
            decoration: const InputDecoration(
              labelText: 'Type de cible',
              isDense: true,
            ),
            items: <DropdownMenuItem<String>>[
              for (final (String? code, String label)
                  in kEventTargetKindChoices)
                DropdownMenuItem<String>(
                  value: code ?? _all,
                  child: Text(label),
                ),
            ],
            onChanged: (String? v) => setState(() => _kind = v ?? _all),
          ),
        ),
        SizedBox(
          width: 240,
          child: DropdownButtonFormField<String>(
            key: ValueKey<String>('moderation-events-action-$_filterEpoch'),
            initialValue: _action,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Action',
              isDense: true,
            ),
            items: <DropdownMenuItem<String>>[
              for (final (String? code, String label) in actions)
                DropdownMenuItem<String>(
                  value: code ?? _all,
                  child: Text(label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (String? v) => setState(() => _action = v ?? _all),
          ),
        ),
        SizedBox(
          width: 320,
          child: TextField(
            key: const Key('moderation-events-key'),
            controller: _key,
            decoration: const InputDecoration(
              labelText: 'Clé exacte',
              isDense: true,
            ),
            onSubmitted: (_) => _applyFilters(),
          ),
        ),
        FilledButton(
          key: const Key('moderation-events-filter'),
          onPressed: _applyFilters,
          child: const Text('Filtrer'),
        ),
        TextButton(
          key: const Key('moderation-events-clear'),
          onPressed: _clearFilters,
          child: const Text('Effacer'),
        ),
      ],
    );
  }

  List<Widget> _row(BanEvent e, TextStyle small) => <Widget>[
    Text(formatModerationDate(e.createdAt), style: small),
    Text(eventActionLabel(e.action), style: small),
    RevealedCell(
      eventTargetText(e),
      key: ValueKey<String>('moderation-event-target-${e.id}'),
      monospace: e.targetKind != 'account',
    ),
    Text(banOriginLabel(e.origin), style: small),
    RevealedCell(eventActorText(e), style: small),
    Text(
      banCategoryLabel(e.category),
      style: small,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    ReasonChips(codes: e.reasons),
    RevealedCell(
      eventNoteText(e),
      key: ValueKey<String>('moderation-event-note-${e.id}'),
      style: small,
    ),
    Text(eventLinksText(e), style: small),
    Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton(
        key: ValueKey<String>('moderation-event-detail-${e.id}'),
        onPressed: () => _detail(e),
        child: const Text('Détail'),
      ),
    ),
  ];
}
