// Onglet « Refus » de l'écran Modération (P4b-3, lot L7, conception §6.5) :
// puces des refus du détecteur des 24 dernières heures (par raison, triées
// par nombre décroissant, depuis `settings.refused_24h`), puis la liste des
// événements `refused` (`moderation/events-list`, pages de 50) avec le
// filtre LOCAL « Détecteur seulement » (coché par défaut : events-list
// mélange refus du détecteur et refus de la revue). Lecture seule +
// « Détail » : un refus applicable se décide depuis la file (tête).
//
// Cible masquée (page refusée) : hôte RÉVÉLÉ + 8 premiers hex de
// l'empreinte (un U+202E devient `⟦U+202E⟧`, S-04).
//
// Aucun Provider : testable en VM.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show AdminAuthException, AdminForbiddenException, SupabaseSync, errorText;
import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_labels.dart';
import '../../../domain/moderation_screen_rules.dart';
import '../../widgets/moderation/moderation_ui.dart';
import '../../widgets/moderation/reason_chips.dart';
import 'moderation_common.dart';

class RefusalsTab extends StatefulWidget {
  const RefusalsTab({
    super.key,
    required this.sync,
    required this.onAuthError,
    required this.settings,
    this.refreshSeq = 0,
  });

  final SupabaseSync sync;
  final VoidCallback onAuthError;

  /// Réglages lus par l'écran (`refused_24h`) ; null = pas encore lus.
  final ModerationSettings? settings;
  final int refreshSeq;

  @override
  State<RefusalsTab> createState() => _RefusalsTabState();
}

class _RefusalsTabState extends State<RefusalsTab> {
  static const List<ModerationColumn> _columns = <ModerationColumn>[
    ModerationColumn('Date', flex: 3),
    ModerationColumn('Cible', flex: 5),
    ModerationColumn('Acteur', flex: 3),
    ModerationColumn('Raisons', flex: 6),
    ModerationColumn('Groupe', flex: 3),
    ModerationColumn('', flex: 2),
  ];

  List<BanEvent> _events = const <BanEvent>[];
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  bool _loaded = false;
  bool _forbidden = false;
  String? _error;
  int _loadSeq = 0;
  bool _detectorOnly = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(0));
    });
  }

  @override
  void didUpdateWidget(RefusalsTab old) {
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
      final EventsPage p = await widget.sync.fetchEvents(
        action: 'refused',
        page: page,
        pageSize: kRefusalsPageSize,
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
    if (_forbidden) return const ModerationForbiddenView();
    final ThemeData theme = Theme.of(context);
    final TextStyle small = theme.textTheme.bodySmall ?? const TextStyle();
    final String? error = _error;
    final List<BanEvent> shown = filterDetectorOnly(_events, _detectorOnly);

    return ListView(
      padding: const EdgeInsets.only(top: 16, bottom: 16),
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              kRefusalsTitle,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 6),
            const Tooltip(
              message: kRefusalsCountTooltip,
              child: Icon(Icons.info_outline_rounded, size: 16),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _refusedChips(small),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Checkbox(
              key: const Key('moderation-refusals-detector-only'),
              value: _detectorOnly,
              onChanged: (bool? v) => setState(() => _detectorOnly = v ?? true),
            ),
            const Text(kDetectorOnlyLabel),
            const SizedBox(width: 16),
            Expanded(child: Text(kRefusalsReadOnlyNote, style: small)),
          ],
        ),
        const SizedBox(height: 8),
        if (error != null) ...<Widget>[
          ModerationErrorBanner(message: error, onRetry: () => _load(_page)),
          const SizedBox(height: 12),
        ],
        if (!_loaded && error == null)
          const ModerationLoadingView()
        else if (_loaded) ...<Widget>[
          ModerationPaginationBar(
            page: _page,
            pageSize: kRefusalsPageSize,
            total: _total,
            loading: _loading,
            onPage: (int p) => unawaited(_load(p)),
          ),
          const SizedBox(height: 8),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  kNoRefusalsMessage,
                  key: const Key('moderation-refusals-empty'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
            )
          else
            ModerationTable(
              key: const Key('moderation-refusals-table'),
              columns: _columns,
              rowKeys: <Key>[
                for (final BanEvent e in shown)
                  ValueKey<String>('moderation-refusal-${e.id}'),
              ],
              rows: <List<Widget>>[
                for (final BanEvent e in shown)
                  <Widget>[
                    Text(formatModerationDate(e.createdAt), style: small),
                    RevealedCell(
                      eventTargetText(e),
                      key: ValueKey<String>(
                        'moderation-refusal-target-${e.id}',
                      ),
                      monospace: e.targetKind != 'account',
                    ),
                    Text(actorKindLabel(e.actorKind), style: small),
                    ReasonChips(codes: e.reasons),
                    Text(eventGroupText(e), style: small),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        key: ValueKey<String>(
                          'moderation-refusal-detail-${e.id}',
                        ),
                        onPressed: () => _detail(e),
                        child: const Text('Détail'),
                      ),
                    ),
                  ],
              ],
            ),
        ],
      ],
    );
  }

  Widget _refusedChips(TextStyle small) {
    final ModerationSettings? s = widget.settings;
    if (s == null) return Text('…', style: small);
    final List<RefusalCount> counts = refusalCounts(s.refused24h);
    if (counts.isEmpty) {
      return Text(
        kNoRefusals24hMessage,
        key: const Key('moderation-refusals-24h-empty'),
        style: small,
      );
    }
    return Wrap(
      key: const Key('moderation-refusals-24h'),
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        for (final RefusalCount r in counts)
          ModerationPill(
            label: refusalChipText(r),
            color: ModerationColors.neutral,
            tooltip: r.code,
          ),
      ],
    );
  }
}
