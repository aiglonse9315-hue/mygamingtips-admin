// Écran « Modération » (P4b-3, lot L7, conception §6.2, D1) — réservé au
// compte principal (entrée de menu masquée sinon ; le serveur reste la
// barrière : 403 sur les routes `moderation/*`).
//
// États, dans l'ordre : mode aperçu (`sync == null`) → « Mode démo : pas de
// connexion Supabase. » ; compte non principal → état 403 ; sinon en-tête
// (titre, pastilles « Ban automatique : allumé / éteint » et « File : N »,
// bandeau du disjoncteur + « Voir les réglages », ↻ « Actualiser » qui relit
// l'onglet courant ET les réglages) et 5 onglets : « File de revue »,
// « Refus », « Réglages », « Pages bloquées », « Journal ».
//
// [focus] (navigation « Ouvrir dans Modération » depuis une liste de bans) :
// onglet « File de revue » et, après le premier affichage, détail de cet
// événement (boutons de `actionsForFocus`) — une SEULE fois : le focus est
// consommé dès son ouverture (revue P4b-3, ARC-01 ; l'onglet est aussi
// gardé en vie). La coquille reconstruit l'écran à chaque navigation avec
// paramètre (`ValueKey` + compteur).
//
// COLLE : lit `StoreController.sync`, `AuthController.isOwner` et
// `store.onAuthError` (401 → déconnexion) puis les passe aux onglets, qui
// n'importent pas Provider (testables en VM).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_controller.dart';
import '../../data/supabase_sync.dart';
import '../../domain/models/moderation.dart';
import '../../domain/moderation_actions.dart';
import '../../domain/moderation_screen_rules.dart';
import '../../state/store_controller.dart';
import 'moderation/blocked_pages_tab.dart';
import 'moderation/events_tab.dart';
import 'moderation/moderation_common.dart';
import 'moderation/refusals_tab.dart';
import 'moderation/review_queue_tab.dart';
import 'moderation/settings_tab.dart';

class ModerationScreen extends StatefulWidget {
  const ModerationScreen({super.key, this.focus});

  /// Événement à ouvrir en détail (statut connu de l'appelant) ; null = rien.
  final ModerationFocus? focus;

  @override
  State<ModerationScreen> createState() => _ModerationScreenState();
}

class _ModerationScreenState extends State<ModerationScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: kModerationTabLabels.length,
    initialIndex: kQueueTabIndex,
    vsync: this,
  );

  /// Compteur de relecture PAR onglet (« Actualiser » ne relit que l'onglet
  /// courant).
  final List<int> _refresh = List<int>.filled(kModerationTabLabels.length, 0);

  /// Vrai dès que le détail du [ModerationScreen.focus] a été ouvert : le
  /// focus n'est plus transmis à l'onglet (ARC-01, jamais de réouverture).
  bool _focusConsumed = false;

  ModerationSettings? _settings;
  bool _settingsLoading = false;
  String? _settingsError;
  int _settingsSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadSettings());
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Réglages de l'en-tête (compteur de file, interrupteur, disjoncteur).
  Future<void> _loadSettings() async {
    final StoreController store = context.read<StoreController>();
    final SupabaseSync? sync = store.sync;
    if (sync == null || !context.read<AuthController>().isOwner) return;
    final int seq = ++_settingsSeq;
    setState(() => _settingsLoading = true);
    try {
      final ModerationSettings s = await sync.fetchModerationSettings();
      if (!mounted || seq != _settingsSeq) return;
      setState(() {
        _settings = s;
        _settingsError = null;
        _settingsLoading = false;
      });
    } on AdminAuthException {
      if (mounted && seq == _settingsSeq) {
        setState(() => _settingsLoading = false);
      }
      store.onAuthError?.call();
    } catch (e) {
      if (!mounted || seq != _settingsSeq) return;
      setState(() {
        _settingsError = headerSettingsError(
          forbidden: e is AdminForbiddenException,
        );
        _settingsLoading = false;
      });
    }
  }

  /// Réglages lus ou écrits par l'onglet « Réglages » : plus récents que
  /// toute lecture de l'en-tête en cours.
  void _onSettings(ModerationSettings s) {
    if (!mounted) return;
    _settingsSeq++;
    setState(() {
      _settings = s;
      _settingsError = null;
      _settingsLoading = false;
    });
  }

  void _refreshCurrent() {
    setState(() => _refresh[_tabs.index]++);
    unawaited(_loadSettings());
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.read<StoreController>();
    final SupabaseSync? sync = store.sync;
    final bool isOwner = context.watch<AuthController>().isOwner;

    if (sync == null) {
      return const ModerationEmptyView(
        icon: Icons.cloud_off_rounded,
        message: kModerationDemoMessage,
        messageKey: Key('moderation-demo'),
      );
    }
    if (!isOwner) return const ModerationForbiddenView();

    void onAuthError() => store.onAuthError?.call();
    void onChanged() => unawaited(_loadSettings());

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ModerationHeader(
            settings: _settings,
            loading: _settingsLoading,
            error: _settingsError,
            onRefresh: _refreshCurrent,
            onOpenSettings: () => _tabs.animateTo(kSettingsTabIndex),
          ),
          const SizedBox(height: 8),
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: <Widget>[
              for (final String label in kModerationTabLabels) Tab(text: label),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                ReviewQueueTab(
                  sync: sync,
                  isOwner: isOwner,
                  onAuthError: onAuthError,
                  onChanged: onChanged,
                  focus: _focusConsumed ? null : widget.focus,
                  onFocusOpened: () {
                    if (mounted && !_focusConsumed) {
                      setState(() => _focusConsumed = true);
                    }
                  },
                  refreshSeq: _refresh[kQueueTabIndex],
                ),
                RefusalsTab(
                  sync: sync,
                  onAuthError: onAuthError,
                  settings: _settings,
                  refreshSeq: _refresh[kRefusalsTabIndex],
                ),
                SettingsTab(
                  sync: sync,
                  onAuthError: onAuthError,
                  onSettings: _onSettings,
                  refreshSeq: _refresh[kSettingsTabIndex],
                ),
                BlockedPagesTab(
                  sync: sync,
                  isOwner: isOwner,
                  onAuthError: onAuthError,
                  onChanged: onChanged,
                  refreshSeq: _refresh[kBlockedPagesTabIndex],
                ),
                EventsTab(
                  sync: sync,
                  onAuthError: onAuthError,
                  refreshSeq: _refresh[kEventsTabIndex],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
