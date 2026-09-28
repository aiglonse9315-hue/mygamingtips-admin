// Onglet « File de revue » de l'écran Modération (P4b-3, lot L7, conception
// §6.3, §6.2 « focus ») : page de 50 éléments (`moderation/review-list`),
// séquence anti-réponse périmée, barre « Page X / N (a–b sur T) », une tuile
// par élément (`ReviewQueueTile`), décisions avec motif, SnackBar selon le
// ton, relecture de la page (recul d'une page si elle se vide :
// `pageAfterRemoval`) et des réglages de l'en-tête, purge proposée d'une
// chaîne confirmée / appliquée.
//
// [focus] non nul (navigation « Ouvrir dans Modération ») : après le premier
// affichage, ouverture du DÉTAIL de cet événement avec les boutons de
// `actionsForFocus` (statut fourni par l'appelant ; inconnu → « Détail »
// seulement) — UNE seule fois (revue P4b-3, ARC-01) : l'onglet est gardé en
// vie quand l'admin change d'onglet (page courante conservée, pas de
// nouvelle ouverture au retour) et [onFocusOpened] prévient l'écran, qui ne
// transmet plus le focus.
//
// Aucun Provider : accès serveur, statut et 401 passés par l'écran → testable
// en VM.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show AdminAuthException, AdminForbiddenException, SupabaseSync, errorText;
import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_screen_rules.dart';
import '../../widgets/moderation/moderation_ui.dart';
import '../../widgets/moderation/review_detail_dialog.dart';
import '../../widgets/moderation/review_queue_tile.dart';
import 'moderation_common.dart';

class ReviewQueueTab extends StatefulWidget {
  const ReviewQueueTab({
    super.key,
    required this.sync,
    required this.isOwner,
    required this.onAuthError,
    this.onChanged,
    this.focus,
    this.onFocusOpened,
    this.refreshSeq = 0,
  });

  final SupabaseSync sync;
  final bool isOwner;

  /// 401 → déconnexion (`store.onAuthError`).
  final VoidCallback onAuthError;

  /// Après une décision qui relit la file : relire les réglages (compteur
  /// « File : N » de l'en-tête).
  final VoidCallback? onChanged;

  /// Événement à ouvrir en détail après le premier affichage.
  final ModerationFocus? focus;

  /// Appelé quand le détail de [focus] est ouvert : l'écran cesse de
  /// transmettre ce focus (jamais une 2e ouverture).
  final VoidCallback? onFocusOpened;

  /// Incrémenté par « Actualiser » : relit la page courante.
  final int refreshSeq;

  @override
  State<ReviewQueueTab> createState() => _ReviewQueueTabState();
}

class _ReviewQueueTabState extends State<ReviewQueueTab>
    with AutomaticKeepAliveClientMixin {
  List<ReviewItem> _items = const <ReviewItem>[];
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  bool _loaded = false;
  bool _forbidden = false;
  String? _error;
  int _loadSeq = 0;
  final Set<int> _busyIds = <int>{};

  /// Gardé en vie hors de l'écran (changement d'onglet) : page courante
  /// conservée, focus jamais rouvert (ARC-01).
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_load(0));
      final ModerationFocus? f = widget.focus;
      if (f != null) {
        widget.onFocusOpened?.call();
        unawaited(_openFocus(f));
      }
    });
  }

  @override
  void didUpdateWidget(ReviewQueueTab old) {
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
      final ReviewQueuePage p = await widget.sync.fetchReviewList(
        page: page,
        pageSize: kReviewPageSize,
      );
      if (!mounted || seq != _loadSeq) return;
      // Page devenue vide (file modifiée ailleurs) : dernière page réelle.
      if (p.items.isEmpty && page > 0 && p.total > 0) {
        final int target = pageAfterRemoval(
          page: page,
          itemsLeftOnPage: 0,
          total: p.total,
          pageSize: kReviewPageSize,
        );
        if (target != page) {
          unawaited(_load(target));
          return;
        }
      }
      setState(() {
        _items = p.items;
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

  /// Retrait local puis relecture (recul d'une page si elle s'est vidée).
  void _applyOutcome(DecisionOutcome o, int eventId) {
    if (!mounted) return;
    if (o.removeItem) {
      final int before = _items.length;
      final List<ReviewItem> left = <ReviewItem>[
        for (final ReviewItem i in _items)
          if (i.id != eventId) i,
      ];
      setState(() {
        _items = left;
        if (left.length < before && _total > 0) _total--;
      });
    }
    if (o.reloadQueue) {
      unawaited(
        _load(
          pageAfterRemoval(
            page: _page,
            itemsLeftOnPage: _items.length,
            total: _total,
            pageSize: kReviewPageSize,
          ),
        ),
      );
      widget.onChanged?.call();
    }
  }

  Future<void> _onAction(ReviewItem item, ReviewAction action) async {
    ReviewAction a = action;
    if (a == ReviewAction.detail) {
      final ReviewAction? chosen = await ReviewDetailDialog.show(
        context,
        load: () => widget.sync.fetchReviewDetail(item.id),
        actions: actionsForQueueItem(item.kind),
        onAuthError: widget.onAuthError,
      );
      if (chosen == null || !mounted) return;
      a = chosen;
    }
    final ReviewDecision? decision = decisionForAction(a);
    if (decision == null) return;
    setState(() => _busyIds.add(item.id));
    try {
      await runReviewDecision(
        context,
        sync: widget.sync,
        eventId: item.id,
        decision: decision,
        targetLabel: reviewItemTargetLabel(item),
        targetKind: item.targetKind,
        groupSize: item.groupSize,
        manualBanPresent: item.manualBanPresent,
        channelRowId: item.channelRowId,
        onAuthError: widget.onAuthError,
        onOutcome: (DecisionOutcome o) => _applyOutcome(o, item.id),
      );
    } finally {
      if (mounted) setState(() => _busyIds.remove(item.id));
    }
  }

  Future<void> _openFocus(ModerationFocus f) async {
    await openEventDetail(
      context,
      sync: widget.sync,
      eventId: f.eventId,
      actions: actionsForFocus(f, isOwner: widget.isOwner),
      targetKind: f.targetKind,
      onAuthError: widget.onAuthError,
      onOutcome: (DecisionOutcome o) => _applyOutcome(o, f.eventId),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    if (_forbidden) return const ModerationForbiddenView();
    final String? error = _error;
    if (!_loaded) {
      if (error != null) {
        return ListView(
          padding: const EdgeInsets.only(top: 16),
          children: <Widget>[
            ModerationErrorBanner(message: error, onRetry: () => _load(_page)),
          ],
        );
      }
      return const ModerationLoadingView();
    }
    final List<Widget> head = <Widget>[
      if (error != null) ...<Widget>[
        ModerationErrorBanner(message: error, onRetry: () => _load(_page)),
        const SizedBox(height: 12),
      ],
    ];
    if (_items.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(top: 16),
        children: <Widget>[
          ...head,
          const ModerationEmptyView(
            icon: Icons.task_alt_rounded,
            message: kQueueEmptyMessage,
            messageKey: Key('moderation-queue-empty'),
          ),
          if (_loading) const Center(child: kButtonSpinner),
        ],
      );
    }
    return ListView.builder(
      key: const Key('moderation-queue-list'),
      padding: const EdgeInsets.only(top: 16, bottom: 16),
      itemCount: _items.length + 1,
      itemBuilder: (BuildContext context, int i) {
        if (i == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ...head,
              ModerationPaginationBar(
                page: _page,
                pageSize: kReviewPageSize,
                total: _total,
                loading: _loading,
                onPage: (int p) => unawaited(_load(p)),
              ),
              const SizedBox(height: 8),
            ],
          );
        }
        final ReviewItem item = _items[i - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ReviewQueueTile(
            item: item,
            busy: _busyIds.contains(item.id),
            onAction: (ReviewAction a) => unawaited(_onAction(item, a)),
          ),
        );
      },
    );
  }
}
