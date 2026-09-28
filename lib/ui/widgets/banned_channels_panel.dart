import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/theme/colors.dart';
import '../../data/supabase_sync.dart';
import '../../domain/banned_channels_rules.dart';
import '../../domain/models/ban_category.dart';
import '../../domain/models/banned_channel.dart';
import '../../domain/models/moderation.dart';
import '../../domain/moderation_actions.dart';
import '../../domain/moderation_text.dart';
import '../../state/store_controller.dart';
import '../screens/moderation/moderation_common.dart'
    show offerChannelPurge, showModerationSnack;
import 'moderation/auto_ban_lift_dialog.dart';
import 'moderation/ban_channel_report_dialog.dart';
import 'moderation/banned_channels_view.dart';
import 'moderation/moderation_ui.dart' show decisionForAction;
import 'moderation/review_decision_dialog.dart';
import 'moderation/review_detail_dialog.dart';
import 'moderation/unban_confirm_dialog.dart';

/// Panneau « 🚫 Chaînes bannies » (chantier B, migration 0064, contrat
/// §70.3 ; P4b-3 lot L8, T10, conception §6.12), ouvert depuis le menu
/// Chaîne YT (bouton « 🚫 Bannir »).
///
/// Contient :
///  - le formulaire de bannissement (URL ou handle, nom affiché optionnel,
///    catégorie parmi les 4 du ban manuel (D4), motif 1-500 points de code)
///    — la normalisation est faite côté serveur (EF `channels/ban`) ; un ban
///    réussi ouvre le rapport ([BanChannelReportDialog]) selon `result`
///    (`applied` / `updated` / `auto_en_revue`), avec le retrait MANUEL et
///    CONFIRMÉ des contenus publiés (jamais automatique) ;
///  - la liste paginée des chaînes bannies (Chaîne · Plateforme · État ·
///    Catégorie · Motif · Date · Par · Actions) : « Débannir » pour une
///    ligne manuelle (confirmation, NON optimiste) ; pour une ligne AUTO, le
///    compte principal a « Détail », « Confirmer », « Lever » (motif
///    obligatoire) et « Purger » ; un autre admin voit « Débannir »
///    désactivé.
///
/// Comme l'écran Chaînes YT hôte, ce panneau fait ses propres appels EF
/// (pas de dataset synchronisé) : états chargement / erreur / vide / données.
/// 401 (chargement ou action) : les dialogues ouverts se ferment, puis le
/// panneau se ferme et `store.onAuthError` déconnecte (S-08). 403 des
/// actions du compte principal : « Réservé au compte principal. » (dans les
/// dialogues) ; le CHARGEMENT n'est pas réservé (pas de branche 403).
class BannedChannelsPanel extends StatefulWidget {
  const BannedChannelsPanel({super.key});

  /// Ouvre le panneau en dialog.
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const BannedChannelsPanel(),
    );
  }

  @override
  State<BannedChannelsPanel> createState() => _BannedChannelsPanelState();
}

class _BannedChannelsPanelState extends State<BannedChannelsPanel> {
  /// Taille de page demandée au serveur (le serveur borne à 100).
  static const int _pageSize = 10;

  late final StoreController _store;

  List<BannedChannel> _items = <BannedChannel>[];
  int _total = 0;
  int _page = 0;

  bool _loading = false;
  String? _error;

  /// Séquence des lectures : seule la plus récente est appliquée.
  int _loadSeq = 0;

  /// Catégories demandées au serveur (une fois, après la 1re lecture
  /// réussie : un jeton expiré ne déclenche qu'UNE déconnexion).
  bool _categoriesRequested = false;

  /// Identifiants des lignes dont une action est en cours.
  final Set<int> _busyIds = <int>{};

  /// Session expirée : le panneau se ferme (il reste monté pendant
  /// l'animation de sortie) — plus aucun dialogue ni aucune lecture.
  bool _expired = false;

  /// Monté ET session valide : garde après chaque `await` d'un enchaînement.
  bool get _alive => mounted && !_expired;

  int get _totalPages => (_total / _pageSize).ceil().clamp(1, 1 << 30);

  @override
  void initState() {
    super.initState();
    _store = context.read<StoreController>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load(0));
    });
  }

  /// Session expirée (401) : ferme les dialogues encore ouverts au-dessus du
  /// panneau (en général déjà fermés d'eux-mêmes, S-08), puis le panneau,
  /// PUIS déconnecte — une seule fois, même si plusieurs appels reçoivent
  /// le 401.
  void _sessionExpired() {
    if (_expired) return;
    _expired = true;
    final VoidCallback? logout = _store.onAuthError;
    if (mounted) {
      final ModalRoute<Object?>? route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        final NavigatorState nav = Navigator.of(context);
        nav.popUntil((Route<dynamic> r) => r == route);
        if (route.isCurrent) nav.pop();
      }
    }
    logout?.call();
  }

  Future<void> _load(int page) async {
    if (_expired) return;
    final SupabaseSync? sync = _store.sync;
    if (sync == null) {
      setState(() => _error = 'Mode démo : pas de connexion Supabase.');
      return;
    }
    final int seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ({List<BannedChannel> items, int total}) res = await sync
          .fetchBannedChannels(page: page, pageSize: _pageSize);
      if (!mounted || seq != _loadSeq) return;
      // Page revenue vide (dernière ligne retirée, liste raccourcie
      // ailleurs) : recule jusqu'à la dernière page existante.
      final int? fallback = channelsPageFallback(
        page: page,
        itemCount: res.items.length,
        total: res.total,
        pageSize: _pageSize,
      );
      if (fallback != null) {
        await _load(fallback);
        return;
      }
      setState(() {
        _items = res.items;
        _total = res.total;
        _page = page;
        _loading = false;
      });
      if (!_categoriesRequested) {
        _categoriesRequested = true;
        unawaited(_store.loadBanCategories());
      }
    } on AdminAuthException {
      if (mounted && seq == _loadSeq) setState(() => _loading = false);
      _sessionExpired();
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  // ── Bannissement ──

  /// Envoi du formulaire : null = succès (le formulaire se vide), sinon le
  /// message affiché sous le formulaire.
  Future<String?> _submitBan(ChannelBanRequest r) async {
    final SupabaseSync? sync = _store.sync;
    if (sync == null) return 'Mode démo : pas de connexion Supabase.';
    try {
      final BanChannelReport report = await sync.banChannel(
        handleOrUrl: r.handleOrUrl,
        reason: r.reason,
        displayName: r.displayName,
        category: r.category,
      );
      // Chantier B (fix revue I-002) : propage le ban aux bots vivants —
      // demande de sync TOTALE fire-and-forget (chantier C) ; les bots
      // rechargeront la liste noire au prochain cycle/démarrage.
      unawaited(_store.requestTotalSync());
      if (_alive) unawaited(_showReport(sync, report));
      return null;
    } on AdminAuthException {
      _sessionExpired();
      return null;
    } catch (e) {
      // Issue inconnue (coupure, 5xx après rejeux) : le ban a pu passer →
      // relire la liste (T2).
      if (isUncertainFailure(e) && _alive) unawaited(_load(0));
      return errorText(e);
    }
  }

  /// Recharge la liste (la nouvelle chaîne est en tête — tri created_at
  /// desc côté serveur) puis ouvre le rapport de bannissement.
  Future<void> _showReport(SupabaseSync sync, BanChannelReport report) async {
    await _load(0);
    if (!mounted) return;
    if (_expired) return;
    await BanChannelReportDialog.show(
      context,
      report: report,
      unpublish: () => sync.unpublishByChannel(report.banned.handle),
      onAuthError: _sessionExpired,
    );
  }

  // ── Débannir (ligne manuelle) ──

  Future<void> _unban(BannedChannel c) async {
    final SupabaseSync? sync = _store.sync;
    if (sync == null || _busyIds.contains(c.id)) return;
    setState(() => _busyIds.add(c.id));
    try {
      final UnbanOutcome? o = await UnbanConfirmDialog.show(
        context,
        name: c.displayLabel,
        channel: true,
        submit: () async {
          final UnbanOutcome o = await runChannelUnban(
            () => sync.unbanChannel(c.id),
          );
          // Échec (le dialogue reste ouvert) : la liste a pu changer.
          if (o.kind == UnbanKind.failure && mounted) {
            unawaited(_load(_page));
          }
          return o;
        },
      );
      if (o == null || !mounted) return;
      if (o.kind == UnbanKind.sessionExpired) {
        _sessionExpired();
        return;
      }
      if (_expired) return;
      if (o.kind == UnbanKind.autoBan) {
        // Liste périmée : la ligne est un ban AUTOMATIQUE (409).
        final int? eventId = o.banEventId;
        if (context.read<AuthController>().isOwner && eventId != null) {
          await _decide(c, ReviewDecision.lift, eventId: eventId);
          // Levée annulée ou non : la ligne affichée était périmée.
          if (mounted) await _load(_page);
        } else {
          showModerationSnack(
            context,
            unbanMessage(
              o,
              name: oneLinePreview(c.displayLabel, max: 60),
              channel: true,
            ),
            tone: OutcomeTone.warning,
          );
          await _load(_page);
        }
        return;
      }
      final ({String message, OutcomeTone tone, bool totalSync})? f =
          channelUnbanFeedback(
            o,
            name: oneLinePreview(c.displayLabel, max: 60),
          );
      if (f == null) return;
      // Chantier B (fix revue I-002) : propage le débannissement aux bots
      // vivants — sync totale fire-and-forget (chantier C).
      if (f.totalSync) unawaited(_store.requestTotalSync());
      showModerationSnack(context, f.message, tone: f.tone);
      await _load(_page);
    } finally {
      if (mounted) setState(() => _busyIds.remove(c.id));
    }
  }

  // ── Ligne AUTO (compte principal) ──

  Future<void> _onAction(BannedChannel c, ReviewAction a) async {
    final int? eventId = c.banEventId;
    if (_store.sync == null || eventId == null || _busyIds.contains(c.id)) {
      return;
    }
    setState(() => _busyIds.add(c.id));
    try {
      await _runAction(c, a, eventId: eventId);
    } finally {
      if (mounted) setState(() => _busyIds.remove(c.id));
    }
  }

  Future<void> _runAction(
    BannedChannel c,
    ReviewAction a, {
    required int eventId,
    bool fromDetail = false,
  }) async {
    final SupabaseSync? sync = _store.sync;
    if (sync == null || !mounted) return;
    if (_expired) return;
    switch (a) {
      case ReviewAction.detail:
        final ReviewAction? chosen = await ReviewDetailDialog.show(
          context,
          load: () => sync.fetchReviewDetail(eventId),
          // Revue P4b-3 (SEC-P4b3-06) : boutons calculés avec le statut
          // RÉEL du compte (jamais « principal » supposé).
          actions: channelRowControl(
            c,
            isOwner: context.read<AuthController>().isOwner,
          ).actions,
          onAuthError: _sessionExpired,
        );
        if (chosen == null || chosen == ReviewAction.detail || !mounted) {
          return;
        }
        await _runAction(c, chosen, eventId: eventId, fromDetail: true);
      case ReviewAction.purge:
        await offerChannelPurge(
          context,
          sync: sync,
          rowId: c.id,
          channelLabel: c.displayLabel,
          onAuthError: _sessionExpired,
        );
        if (mounted) await _load(_page);
      case ReviewAction.confirm ||
          ReviewAction.lift ||
          ReviewAction.apply ||
          ReviewAction.dismiss:
        final ReviewDecision? decision = decisionForAction(a);
        if (decision == null) return;
        await _decide(c, decision, eventId: eventId, fromDetail: fromDetail);
    }
  }

  /// Décision de revue sur l'événement [eventId] de la ligne [c] : levée
  /// depuis la liste = `AutoBanLiftDialog` (détail replié + motif
  /// obligatoire) ; depuis le détail déjà ouvert ou pour « Confirmer » =
  /// `ReviewDecisionDialog`. Après une levée : synchro totale des bots +
  /// relecture ; après une confirmation : relecture, purge proposée.
  Future<void> _decide(
    BannedChannel c,
    ReviewDecision decision, {
    required int eventId,
    bool fromDetail = false,
  }) async {
    final SupabaseSync? sync = _store.sync;
    if (sync == null || !mounted) return;
    if (_expired) return;
    Future<ReviewDecideResult> submit(String? reason) =>
        sync.reviewDecide(eventId, decision, reason: reason);
    final DecisionDialogOutcome? r =
        decision == ReviewDecision.lift && !fromDetail
        ? await AutoBanLiftDialog.show(
            context,
            loadDetail: () => sync.fetchReviewDetail(eventId),
            submit: submit,
            targetLabel: c.displayLabel,
            manualBanPresent: c.hasManualIntent,
            onAuthError: _sessionExpired,
          )
        : await ReviewDecisionDialog.show(
            context,
            decision: decision,
            targetLabel: c.displayLabel,
            targetKind: 'channel',
            manualBanPresent: c.hasManualIntent,
            submit: submit,
            onAuthError: _sessionExpired,
          );
    // Annulé ou fermé sur 401 (déconnexion déjà lancée).
    if (r == null || !mounted) return;
    if (_expired) return;
    final DecisionOutcome o = channelDecisionOutcome(
      r.outcome,
      result: r.result?.result,
      stillBanned: r.result?.stillBanned,
    );
    if (decision == ReviewDecision.lift && o.reloadQueue) {
      // Ligne supprimée ou convertie : la liste noire des bots change.
      unawaited(_store.requestTotalSync());
    }
    showModerationSnack(context, o.message, tone: o.tone);
    if (o.reloadQueue) await _load(_page);
    if (!o.offerPurge || !mounted) return;
    if (_expired) return;
    await offerChannelPurge(
      context,
      sync: sync,
      rowId: c.id,
      channelLabel: c.displayLabel,
      onAuthError: _sessionExpired,
    );
    if (mounted) await _load(_page);
  }

  // ── Construction ──

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<BanCategory> categories = context
        .watch<StoreController>()
        .manualBanCategories;
    final bool isOwner = context.watch<AuthController>().isOwner;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.block_rounded,
                    size: 22,
                    color: AppColors.categoryVideo,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Chaînes YouTube bannies',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Actualiser',
                    onPressed: _loading ? null : () => _load(_page),
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  ),
                  IconButton(
                    tooltip: 'Fermer',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(kBannedChannelsHelp, style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              ChannelBanForm(categories: categories, submit: _submitBan),
              const SizedBox(height: 12),
              Expanded(child: _buildBody(theme, categories, isOwner)),
              const SizedBox(height: 8),
              _buildPagination(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    List<BanCategory> categories,
    bool isOwner,
  ) {
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: TextStyle(color: Colors.orange.shade300),
              textAlign: TextAlign.center,
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
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          'Aucune chaîne bannie pour le moment.',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      );
    }
    return SingleChildScrollView(
      child: BannedChannelsTable(
        channels: _items,
        isOwner: isOwner,
        busyIds: _busyIds,
        categories: categories,
        onUnban: (BannedChannel c) => unawaited(_unban(c)),
        onAction: (BannedChannel c, ReviewAction a) =>
            unawaited(_onAction(c, a)),
      ),
    );
  }

  /// Barre de pagination (même modèle que le menu Log).
  Widget _buildPagination(ThemeData theme) {
    if (_total == 0) return const SizedBox.shrink();
    final int firstRow = _page * _pageSize + 1;
    final int lastRow = ((_page + 1) * _pageSize).clamp(0, _total).toInt();
    return Row(
      children: [
        Text(
          '$firstRow–$lastRow sur $_total — page ${_page + 1}/$_totalPages',
          style: theme.textTheme.bodySmall,
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.first_page_rounded, size: 20),
          tooltip: 'Première page',
          onPressed: _page > 0 && !_loading ? () => _load(0) : null,
        ),
        IconButton(
          icon: const Icon(Icons.chevron_left_rounded, size: 20),
          tooltip: 'Page précédente',
          onPressed: _page > 0 && !_loading ? () => _load(_page - 1) : null,
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right_rounded, size: 20),
          tooltip: 'Page suivante',
          onPressed: _page + 1 < _totalPages && !_loading
              ? () => _load(_page + 1)
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.last_page_rounded, size: 20),
          tooltip: 'Dernière page',
          onPressed: _page + 1 < _totalPages && !_loading
              ? () => _load(_totalPages - 1)
              : null,
        ),
      ],
    );
  }
}
