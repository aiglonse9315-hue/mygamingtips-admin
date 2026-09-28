// Onglets de l'écran « Modération » (P4b-3, lot L7, conception §6.2-§6.8) :
// file de revue (pagination, décision, purge proposée, navigation « focus »,
// erreur incertaine, 403 / 401), refus (puces des 24 h, filtre « Détecteur
// seulement », cible masquée révélée), réglages (Allumer / Éteindre /
// Réarmer, plafonds, empreintes S-07, preuves), pages bloquées (levée depuis
// la liste) et journal (filtres).
//
// Les onglets n'importent NI Provider NI StoreController (l'écran passe
// l'accès serveur, le statut et `onAuthError`) : ils sont montés ici avec un
// `SupabaseSync` FACTICE (méthodes surchargées, aucun réseau).
// Aucune dépendance dart:html — exécuté en VM par `flutter test`. Données
// neutres ; caractères spéciaux construits par String.fromCharCode.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/banned_channel.dart';
import 'package:mgt_admin/domain/models/moderation.dart';
import 'package:mgt_admin/domain/moderation_actions.dart';
import 'package:mgt_admin/domain/moderation_screen_rules.dart';
import 'package:mgt_admin/ui/screens/moderation/blocked_pages_tab.dart';
import 'package:mgt_admin/ui/screens/moderation/events_tab.dart';
import 'package:mgt_admin/ui/screens/moderation/moderation_common.dart';
import 'package:mgt_admin/ui/screens/moderation/refusals_tab.dart';
import 'package:mgt_admin/ui/screens/moderation/review_queue_tab.dart';
import 'package:mgt_admin/ui/screens/moderation/settings_tab.dart';

import 'support/widget_fixtures.dart';

const String _uuid = '11111111-2222-4333-8444-555555555555';
final String _rlo = String.fromCharCode(0x202E);
final String _shaA = 'a' * 64;
final String _shaB = 'b' * 64;

/// Décision reçue par le serveur factice.
typedef _Decision = ({int eventId, ReviewDecision decision, String? reason});

/// Écriture des réglages reçue par le serveur factice.
typedef _SettingsWrite = ({
  bool? enabled,
  int? perHour,
  int? perDay,
  List<String>? rules,
});

/// `SupabaseSync` factice : chaque route renvoie ce que le test a préparé et
/// enregistre l'appel. Aucune requête HTTP.
class _FakeSync extends SupabaseSync {
  _FakeSync()
    : super(
        supabaseUrl: 'https://exemple.invalid',
        anonKey: 'anon',
        catalogEndpoint: 'https://exemple.invalid/functions/v1/admin-catalog',
        adminToken: 'jeton',
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

  final List<String> calls = <String>[];
  final List<_Decision> decisions = <_Decision>[];
  final List<_SettingsWrite> settingsWrites = <_SettingsWrite>[];
  final List<({int page, String? kind, String? key, String? action})> events =
      <({int page, String? kind, String? key, String? action})>[];
  final List<({int id, bool apply})> purges = <({int id, bool apply})>[];
  final List<({int days, bool apply})> evidencePurges =
      <({int days, bool apply})>[];

  ReviewQueuePage Function(int page) reviewList = (int page) =>
      const ReviewQueuePage(total: 0, page: 0, pageSize: 50, items: []);
  ReviewDetail Function(int id) detail = (int id) => reviewDetail(id: id);
  ReviewDecideResult Function(_Decision d) decide = (_Decision d) =>
      const ReviewDecideResult(result: 'confirmed');
  EventsPage Function(int page) eventsList = (int page) =>
      const EventsPage(total: 0, page: 0, pageSize: 50, items: []);
  ModerationSettings Function() settings = () => _settings();
  ModerationSettings Function(_SettingsWrite w) writeSettings =
      (_SettingsWrite w) => _settings();
  BlockedPagesPage Function(int page) blockedPages = (int page) =>
      const BlockedPagesPage(pages: [], total: 0);
  BannedChannel? Function(int eventId) findChannel = (int eventId) => null;
  PurgeAutoResult Function(int id, bool apply) purgeAuto =
      (int id, bool apply) => PurgeAutoResult(
        result: apply ? 'purged' : 'preview',
        pending: 2,
        purged: apply ? 2 : null,
      );
  EvidencePurgeResult Function(bool apply) evidence = (bool apply) =>
      EvidencePurgeResult(result: apply ? 'purged' : 'preview', count: 4);

  @override
  Future<ReviewQueuePage> fetchReviewList({
    int page = 0,
    int pageSize = 50,
  }) async {
    calls.add('review-list $page');
    return reviewList(page);
  }

  @override
  Future<ReviewDetail> fetchReviewDetail(int eventId) async {
    calls.add('review-detail $eventId');
    return detail(eventId);
  }

  @override
  Future<ReviewDecideResult> reviewDecide(
    int eventId,
    ReviewDecision decision, {
    String? reason,
  }) async {
    final _Decision d = (eventId: eventId, decision: decision, reason: reason);
    decisions.add(d);
    return decide(d);
  }

  @override
  Future<EventsPage> fetchEvents({
    int page = 0,
    int pageSize = 50,
    String? targetKind,
    String? targetKey,
    String? action,
  }) async {
    events.add((page: page, kind: targetKind, key: targetKey, action: action));
    return eventsList(page);
  }

  @override
  Future<ModerationSettings> fetchModerationSettings() async {
    calls.add('settings-get');
    return settings();
  }

  @override
  Future<ModerationSettings> updateModerationSettings({
    bool? autoBanEnabled,
    int? maxPerHour,
    int? maxPerDay,
    List<String>? allowedRulesSha256,
  }) async {
    final _SettingsWrite w = (
      enabled: autoBanEnabled,
      perHour: maxPerHour,
      perDay: maxPerDay,
      rules: allowedRulesSha256,
    );
    settingsWrites.add(w);
    return writeSettings(w);
  }

  @override
  Future<EvidencePurgeResult> purgeEvidence({
    required int olderThanDays,
    required bool apply,
  }) async {
    evidencePurges.add((days: olderThanDays, apply: apply));
    return evidence(apply);
  }

  @override
  Future<BlockedPagesPage> fetchBlockedPages({
    int page = 0,
    int pageSize = 100,
  }) async {
    calls.add('blocked-pages $page');
    return blockedPages(page);
  }

  @override
  Future<BannedChannel?> findBannedChannelByEventId(
    int banEventId, {
    int maxPages = 5,
  }) async {
    calls.add('find-channel $banEventId');
    return findChannel(banEventId);
  }

  @override
  Future<PurgeAutoResult> purgeAutoChannel({
    required int id,
    required bool apply,
  }) async {
    purges.add((id: id, apply: apply));
    return purgeAuto(id, apply);
  }
}

ModerationSettings _settings({
  bool enabled = false,
  int perHour = 3,
  int perDay = 10,
  int lastHour = 1,
  int lastDay = 2,
  List<String> rules = const <String>[],
  String? trippedAt,
  int? breakerEventId,
  Map<String, int> refused = const <String, int>{},
  String? updatedBy,
}) => ModerationSettings.fromJson(<String, dynamic>{
  'auto_ban_enabled': enabled,
  'max_auto_bans_per_hour': perHour,
  'max_auto_bans_per_day': perDay,
  'auto_bans_last_hour': lastHour,
  'auto_bans_last_day': lastDay,
  'allowed_rules_sha256': rules,
  'breaker_tripped_at': trippedAt,
  'breaker_reason': trippedAt == null ? null : 'plafond_heure',
  'breaker_event_id': breakerEventId,
  'refused_24h': refused,
  'review_queue_size': 2,
  'evidence_rows': 5,
  'updated_by': updatedBy,
})!;

ReviewQueuePage _queue(List<ReviewItem> items, {int? total, int page = 0}) =>
    ReviewQueuePage(
      total: total ?? items.length,
      page: page,
      pageSize: 50,
      items: items,
    );

ReviewItem _channelItem({
  int id = 8,
  String kind = 'ban_en_revue',
  int? channelRowId,
}) => ReviewItem(
  kind: kind,
  id: id,
  createdAt: DateTime.utc(2026, 9, 28, 3, 15),
  targetKind: 'channel',
  targetKey: 'UCexemple',
  action: kind == 'ban_en_revue' ? 'ban' : 'pending_review',
  category: 'injection_ia',
  platform: 'youtube',
  channelRowId: channelRowId,
);

BanEvent _event(int id, Map<String, dynamic> extra) =>
    BanEvent.fromJson(<String, dynamic>{
      'id': id,
      'created_at': '2026-09-28T03:15:00+00:00',
      'target_kind': 'account',
      'target_key': _uuid,
      'action': 'refused',
      'origin': 'auto',
      'category': 'injection_ia',
      'actor_kind': 'detecteur',
      'reasons': <String>['source_non_utilisateur'],
      ...extra,
    })!;

/// Monte [tab] puis laisse partir la première lecture.
Future<void> _pumpTab(
  WidgetTester tester,
  Widget tab, {
  Size size = const Size(1400, 2400),
}) async {
  setWindow(tester, size);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: tab)));
  await tester.pump(); // rappel après la première image → lecture
  await tester.pump(); // réponse
}

/// Ouverture d'un dialogue alors qu'un indicateur tourne sur la ligne
/// (décision en cours : `pumpAndSettle` ne se stabiliserait pas).
Future<void> _pumpDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Laisse s'écouler les SnackBars (aucune minuterie en fin de test).
Future<void> _drainSnacks(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

void main() {
  group('File de revue', () {
    testWidgets('page chargée : tuiles et « Page 1 / 1 (1–2 sur 2) »', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync()
        ..reviewList = (int page) =>
            _queue(<ReviewItem>[reviewItem(id: 7), reviewItem(id: 9)]);
      await _pumpTab(
        tester,
        ReviewQueueTab(sync: sync, isOwner: true, onAuthError: () {}),
      );
      expect(sync.calls, <String>['review-list 0']);
      expect(find.byKey(const ValueKey<String>('moderation-tile-7')), findsOne);
      expect(find.byKey(const ValueKey<String>('moderation-tile-9')), findsOne);
      expect(find.text('Page 1 / 1 (1–2 sur 2)'), findsOneWidget);
    });

    testWidgets('file vide → message ; 403 → état réservé ; 401 → '
        'déconnexion', (WidgetTester tester) async {
      final _FakeSync sync = _FakeSync();
      await _pumpTab(
        tester,
        ReviewQueueTab(sync: sync, isOwner: true, onAuthError: () {}),
      );
      expect(find.text(kQueueEmptyMessage), findsOneWidget);

      final _FakeSync forbidden = _FakeSync()
        ..reviewList = (int page) =>
            throw const AdminForbiddenException('Réservé au compte principal.');
      await _pumpTab(
        tester,
        ReviewQueueTab(
          key: const Key('b'),
          sync: forbidden,
          isOwner: true,
          onAuthError: () {},
        ),
      );
      expect(find.byKey(const Key('moderation-forbidden')), findsOneWidget);

      int logouts = 0;
      final _FakeSync expired = _FakeSync()
        ..reviewList = (int page) =>
            throw const AdminAuthException('Session expirée.');
      await _pumpTab(
        tester,
        ReviewQueueTab(
          key: const Key('c'),
          sync: expired,
          isOwner: true,
          onAuthError: () => logouts++,
        ),
      );
      expect(logouts, 1);
    });

    testWidgets('pagination : 120 éléments → page suivante demandée', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync()
        ..reviewList = (int page) => _queue(
          <ReviewItem>[reviewItem(id: 100 + page)],
          total: 120,
          page: page,
        );
      await _pumpTab(
        tester,
        ReviewQueueTab(sync: sync, isOwner: true, onAuthError: () {}),
      );
      expect(find.text('Page 1 / 3 (1–50 sur 120)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('moderation-page-next')));
      await tester.pump();
      await tester.pump();
      expect(sync.calls.last, 'review-list 1');
      expect(find.text('Page 2 / 3 (51–100 sur 120)'), findsOneWidget);
    });

    testWidgets('Confirmer : review-decide, SnackBar, élément retiré, file '
        'et réglages relus', (WidgetTester tester) async {
      int loads = 0;
      int changed = 0;
      final _FakeSync sync = _FakeSync()
        ..reviewList = (int page) {
          loads++;
          return loads == 1
              ? _queue(<ReviewItem>[reviewItem(id: 7), reviewItem(id: 9)])
              : _queue(<ReviewItem>[reviewItem(id: 9)]);
        }
        ..decide = (_Decision d) => const ReviewDecideResult(
          result: 'confirmed',
          targetKind: 'account',
        );
      await _pumpTab(
        tester,
        ReviewQueueTab(
          sync: sync,
          isOwner: true,
          onAuthError: () {},
          onChanged: () => changed++,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('moderation-action-7-confirm')),
      );
      await _pumpDialog(tester);
      expect(find.text('Confirmer le bannissement ?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('moderation-decision-submit')));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sync.decisions.single, (
        eventId: 7,
        decision: ReviewDecision.confirm,
        reason: null,
      ));
      expect(find.text('Bannissement confirmé.'), findsOneWidget);
      expect(changed, 1);
      expect(loads, 2);
      expect(
        find.byKey(const ValueKey<String>('moderation-tile-7')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey<String>('moderation-tile-9')), findsOne);
      await _drainSnacks(tester);
    });

    testWidgets('chaîne confirmée : purge proposée avec channel_row_id, sans '
        'recherche de ligne', (WidgetTester tester) async {
      final _FakeSync sync = _FakeSync()
        ..reviewList = ((int page) =>
            _queue(<ReviewItem>[_channelItem(channelRowId: 12)]))
        ..decide = ((_Decision d) => const ReviewDecideResult(
          result: 'confirmed',
          targetKind: 'channel',
          eventId: 50,
        ));
      await _pumpTab(
        tester,
        ReviewQueueTab(sync: sync, isOwner: true, onAuthError: () {}),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('moderation-action-8-confirm')),
      );
      await _pumpDialog(tester);
      await tester.tap(find.byKey(const Key('moderation-decision-submit')));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sync.purges, <({int id, bool apply})>[(id: 12, apply: false)]);
      expect(
        sync.calls.where((String c) => c.startsWith('find-channel')),
        isEmpty,
      );
      expect(
        find.text('Purger les suggestions de YouTube · UCexemple ?'),
        findsOne,
      );
      await tester.tap(find.byKey(const Key('moderation-purge-apply')));
      await tester.pump();
      await tester.pump();
      expect(sync.purges.last, (id: 12, apply: true));
      expect(
        find.text('2 suggestion(s) rejetée(s) sur 2 en attente.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('moderation-purge-close')));
      await _drainSnacks(tester);
    });

    testWidgets('chaîne appliquée : ligne cherchée par l’événement de la '
        'réponse ; introuvable → message', (WidgetTester tester) async {
      final _FakeSync sync = _FakeSync()
        ..reviewList = ((int page) => _queue(<ReviewItem>[
          _channelItem(kind: 'a_examiner', channelRowId: 12),
        ]))
        ..decide = ((_Decision d) => const ReviewDecideResult(
          result: 'applied',
          targetKind: 'channel',
          eventId: 60,
        ));
      await _pumpTab(
        tester,
        ReviewQueueTab(sync: sync, isOwner: true, onAuthError: () {}),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('moderation-action-8-apply')),
      );
      await _pumpDialog(tester);
      await tester.tap(find.byKey(const Key('moderation-decision-submit')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sync.calls, contains('find-channel 60'));
      expect(sync.purges, isEmpty);
      expect(find.text('Bannissement appliqué (statut confirmé).'), findsOne);
      // Message suivant affiché après la SnackBar de la décision (file).
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(kPurgeRowNotFoundMessage), findsOneWidget);
      await _drainSnacks(tester);
    });

    testWidgets('erreur incertaine : message, relecture, élément gardé', (
      WidgetTester tester,
    ) async {
      int loads = 0;
      final _FakeSync sync = _FakeSync()
        ..reviewList = (int page) {
          loads++;
          return _queue(<ReviewItem>[reviewItem(id: 7)]);
        }
        ..decide = (_Decision d) =>
            throw const AdminApiException(502, 'Erreur serveur (HTTP 502).');
      await _pumpTab(
        tester,
        ReviewQueueTab(sync: sync, isOwner: true, onAuthError: () {}),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('moderation-action-7-confirm')),
      );
      await _pumpDialog(tester);
      await tester.tap(find.byKey(const Key('moderation-decision-submit')));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text(
          "Réponse du serveur non reçue : l'état a été relu, vérifiez le "
          'résultat.',
        ),
        findsOneWidget,
      );
      expect(loads, 2);
      expect(find.byKey(const ValueKey<String>('moderation-tile-7')), findsOne);
      await _drainSnacks(tester);
    });

    testWidgets('focus en revue : détail ouvert avec Confirmer / Lever', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync();
      await _pumpTab(
        tester,
        ReviewQueueTab(
          sync: sync,
          isOwner: true,
          onAuthError: () {},
          focus: const ModerationFocus(
            eventId: 42,
            status: 'en_revue',
            targetKind: 'account',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sync.calls, contains('review-detail 42'));
      expect(find.text('Événement #42 — Bannissement'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('moderation-detail-action-confirm')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('moderation-detail-action-lift')),
        findsOneWidget,
      );
      // Lever → dialogue de motif sur l'événement 42.
      await tester.tap(
        find.byKey(const ValueKey<String>('moderation-detail-action-lift')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lever le bannissement automatique ?'), findsOneWidget);
      expect(find.textContaining('Compte 11111111…'), findsOneWidget);
    });

    testWidgets('focus ouvert UNE fois : changer d’onglet puis revenir ne '
        'rouvre pas le détail et garde la page (ARC-01)', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync()
        ..reviewList = ((int page) => _queue(
          <ReviewItem>[_channelItem(id: 8 + page)],
          total: 120,
          page: page,
        ));
      int opened = 0;
      setWindow(tester, const Size(1400, 2400));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DefaultTabController(
              length: 2,
              child: Column(
                children: <Widget>[
                  const TabBar(
                    tabs: <Widget>[
                      Tab(text: 'File'),
                      Tab(text: 'Autre'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: <Widget>[
                        ReviewQueueTab(
                          sync: sync,
                          isOwner: true,
                          onAuthError: () {},
                          focus: const ModerationFocus(eventId: 42),
                          onFocusOpened: () => opened++,
                        ),
                        const Center(child: Text('autre onglet')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(find.text('Événement #42 — Bannissement'), findsOneWidget);
      await tester.tap(find.byKey(const Key('moderation-detail-close')));
      await tester.pumpAndSettle();
      // Page 2 de la file, puis aller-retour sur l'autre onglet.
      await tester.tap(find.byTooltip('Page suivante'));
      await tester.pumpAndSettle();
      expect(
        sync.calls.where((String c) => c == 'review-list 1'),
        hasLength(1),
      );
      await tester.tap(find.text('Autre'));
      await tester.pumpAndSettle();
      expect(find.text('autre onglet'), findsOneWidget);
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      expect(
        sync.calls.where((String c) => c == 'review-detail 42'),
        hasLength(1),
      );
      expect(find.text('Événement #42 — Bannissement'), findsNothing);
      expect(opened, 1);
      expect(
        sync.calls.where((String c) => c == 'review-list 0'),
        hasLength(1),
      );
      expect(find.textContaining('Page 2 / 3'), findsOneWidget);
    });

    testWidgets('focus au statut inconnu : détail SANS bouton de décision', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync();
      await _pumpTab(
        tester,
        ReviewQueueTab(
          sync: sync,
          isOwner: true,
          onAuthError: () {},
          focus: const ModerationFocus(eventId: 42),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Événement #42 — Bannissement'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('moderation-detail-action-confirm')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('moderation-detail-action-purge')),
        findsNothing,
      );
    });
  });

  group('Refus', () {
    testWidgets('puces des 24 h triées ; events-list action refused ; filtre '
        '« Détecteur seulement » ; cible masquée révélée', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync()
        ..eventsList = (int page) => EventsPage(
          total: 3,
          page: 0,
          pageSize: 50,
          items: <BanEvent>[
            _event(1, <String, dynamic>{}),
            _event(2, <String, dynamic>{'actor_kind': 'revue'}),
            _event(3, <String, dynamic>{
              'target_kind': 'page',
              'target_key': null,
              'target_key_masked': true,
              'target_host': 'exemple.test$_rlo',
              'target_key_sha256': 'c' * 64,
              'group_event_id': 1,
            }),
          ],
        );
      await _pumpTab(
        tester,
        RefusalsTab(
          sync: sync,
          onAuthError: () {},
          settings: _settings(
            refused: <String, int>{'hote_ugc': 1, 'source_non_utilisateur': 4},
          ),
        ),
      );
      expect(sync.events.single, (
        page: 0,
        kind: null,
        key: null,
        action: 'refused',
      ));
      final List<String> chips = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const Key('moderation-refusals-24h')),
              matching: find.byType(Text),
            ),
          )
          .map((Text t) => t.data ?? '')
          .toList();
      expect(chips, <String>[
        "Partage d'un bot : pas de ban de compte : 4",
        "Site de contenus d'utilisateurs (jamais bloqué) : 1",
      ]);
      // Filtre coché : le refus de la revue (#2) est masqué.
      expect(
        find.byKey(const ValueKey<String>('moderation-refusal-1')),
        findsOne,
      );
      expect(
        find.byKey(const ValueKey<String>('moderation-refusal-2')),
        findsNothing,
      );
      expect(
        shownText(
          tester,
          find.byKey(const ValueKey<String>('moderation-refusal-target-3')),
        ),
        'exemple.test⟦U+202E⟧ · empreinte cccccccc…',
      );
      expect(find.text('membre de #1'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('moderation-refusals-detector-only')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('moderation-refusal-2')),
        findsOne,
      );
    });

    testWidgets('aucun refus en 24 h', (WidgetTester tester) async {
      await _pumpTab(
        tester,
        RefusalsTab(
          sync: _FakeSync(),
          onAuthError: () {},
          settings: _settings(),
        ),
      );
      expect(find.text(kNoRefusals24hMessage), findsOneWidget);
    });
  });

  group('Réglages', () {
    testWidgets('Allumer : dialogue FORT (case obligatoire) puis '
        '{auto_ban_enabled: true} seul', (WidgetTester tester) async {
      final List<ModerationSettings> pushed = <ModerationSettings>[];
      final _FakeSync sync = _FakeSync()
        ..writeSettings = (_SettingsWrite w) => _settings(enabled: true);
      await _pumpTab(
        tester,
        SettingsTab(sync: sync, onAuthError: () {}, onSettings: pushed.add),
      );
      expect(pushed, hasLength(1));
      expect(find.text(kAutoBanOffSubtitle), findsOneWidget);
      await tester.tap(find.byKey(const Key('moderation-settings-switch')));
      await tester.pumpAndSettle();
      expect(find.text(kTurnOnTitle), findsOneWidget);
      expect(
        find.text('Bans automatiques : 1/3 (1 h) · 2/10 (24 h)'),
        findsOne,
      );
      final Finder confirm = find.byKey(const Key('moderation-strong-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.tap(find.byKey(const Key('moderation-strong-checkbox')));
      await tester.pump();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(sync.settingsWrites.single, (
        enabled: true,
        perHour: null,
        perDay: null,
        rules: null,
      ));
      expect(pushed.last.autoBanEnabled, isTrue);
      expect(find.text(kAutoBanOnSubtitle), findsOneWidget);
      await _drainSnacks(tester);
    });

    testWidgets('Éteindre : confirmation simple puis {auto_ban_enabled: '
        'false}', (WidgetTester tester) async {
      final _FakeSync sync = _FakeSync()
        ..settings = (() => _settings(enabled: true))
        ..writeSettings = ((_SettingsWrite w) => _settings());
      await _pumpTab(tester, SettingsTab(sync: sync, onAuthError: () {}));
      await tester.tap(find.byKey(const Key('moderation-settings-switch')));
      await tester.pumpAndSettle();
      expect(find.text(kTurnOffTitle), findsOneWidget);
      expect(find.text(kTurnOffMessage), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, kTurnOffButton));
      await tester.pumpAndSettle();
      expect(sync.settingsWrites.single.enabled, isFalse);
      await _drainSnacks(tester);
    });

    testWidgets('Réarmer : encart, dialogue FORT, compteurs et '
        'avertissement plafond atteint, même corps qu’Allumer', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync()
        ..settings = (() => _settings(
          lastHour: 3,
          trippedAt: '2026-09-28T03:15:00+00:00',
          breakerEventId: 42,
        ))
        ..writeSettings = ((_SettingsWrite w) => _settings(enabled: true));
      await _pumpTab(tester, SettingsTab(sync: sync, onAuthError: () {}));
      expect(
        shownText(
          tester,
          find.byKey(const Key('moderation-settings-breaker-text')),
        ),
        contains('(événement #42). Le ban automatique a été coupé.'),
      );
      await tester.tap(find.byKey(const Key('moderation-settings-rearm')));
      await tester.pumpAndSettle();
      expect(find.text(kRearmTitle), findsOneWidget);
      expect(find.byKey(const Key('moderation-ceiling-warning')), findsOne);
      expect(find.text("Voir l'événement #42"), findsOneWidget);
      // Le lien ouvre le détail PAR-DESSUS, sans fermer le dialogue fort.
      await tester.tap(find.byKey(const Key('moderation-rearm-view-event')));
      await tester.pumpAndSettle();
      expect(find.text('Événement #42 — Bannissement'), findsOneWidget);
      await tester.tap(find.byKey(const Key('moderation-detail-close')));
      await tester.pumpAndSettle();
      expect(find.text(kRearmTitle), findsOneWidget);
      await tester.tap(find.byKey(const Key('moderation-strong-checkbox')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('moderation-strong-confirm')));
      await tester.pumpAndSettle();
      expect(sync.settingsWrites.single.enabled, isTrue);
      expect(find.text(kBreakerNormalText), findsOneWidget);
      await _drainSnacks(tester);
    });

    testWidgets('plafonds : hausse confirmée, champ changé seul ; baisse sans '
        'confirmation ; rien changé → aucun envoi ; 0 → avertissement', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync()
        ..writeSettings = (_SettingsWrite w) =>
            _settings(perHour: w.perHour ?? 3, perDay: w.perDay ?? 10);
      await _pumpTab(tester, SettingsTab(sync: sync, onAuthError: () {}));
      final Finder save = find.byKey(
        const Key('moderation-settings-save-ceilings'),
      );
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(sync.settingsWrites, isEmpty);
      expect(find.text(kNothingChangedMessage), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('moderation-settings-hour')),
        '100',
      );
      await tester.pump();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text(kCeilingIncreaseTitle), findsOneWidget);
      expect(find.textContaining('par heure : 3 → 100.'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(FilledButton, kCeilingIncreaseButton),
      );
      await tester.pumpAndSettle();
      expect(sync.settingsWrites.single, (
        enabled: null,
        perHour: 100,
        perDay: null,
        rules: null,
      ));

      await tester.enterText(
        find.byKey(const Key('moderation-settings-day')),
        '0',
      );
      await tester.pump();
      expect(find.text(kCeilingZeroWarning), findsOneWidget);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text(kCeilingIncreaseTitle), findsNothing);
      expect(sync.settingsWrites.last, (
        enabled: null,
        perHour: null,
        perDay: 0,
        rules: null,
      ));
      await _drainSnacks(tester);
    });

    testWidgets('empreintes : invalide refusée, MAJUSCULES normalisées, '
        'différences puis liste ENTIÈRE envoyée', (WidgetTester tester) async {
      final _FakeSync sync = _FakeSync()
        ..settings = (() => _settings(rules: <String>[_shaA]))
        ..writeSettings = ((_SettingsWrite w) =>
            _settings(rules: w.rules ?? const <String>[]));
      await _pumpTab(tester, SettingsTab(sync: sync, onAuthError: () {}));
      expect(find.text('1/50'), findsOneWidget);
      final Finder field = find.byKey(
        const Key('moderation-settings-rule-field'),
      );
      await tester.enterText(field, 'abc');
      await tester.tap(find.byKey(const Key('moderation-settings-rule-add')));
      await tester.pump();
      expect(
        find.text('Empreinte invalide : 64 caractères hexadécimaux attendus.'),
        findsOneWidget,
      );
      await tester.enterText(field, ' ${_shaB.toUpperCase()} ');
      await tester.tap(find.byKey(const Key('moderation-settings-rule-add')));
      await tester.pump();
      expect(find.text('2/50'), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>('moderation-settings-rule-$_shaB')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(ValueKey<String>('moderation-settings-rule-remove-$_shaA')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('moderation-settings-rules-save')));
      await tester.pumpAndSettle();
      expect(find.text(kRulesSaveTitle), findsOneWidget);
      expect(find.textContaining('+ bbbbbbbb…'), findsOneWidget);
      expect(find.textContaining('− aaaaaaaa…'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(FilledButton, kRulesSaveConfirmButton),
      );
      await tester.pumpAndSettle();
      expect(sync.settingsWrites.single.rules, <String>[_shaB]);
      await _drainSnacks(tester);
    });

    testWidgets('empreintes : liste changée sur le serveur → avertissement, '
        'RIEN envoyé, « Recharger »', (WidgetTester tester) async {
      int reads = 0;
      final _FakeSync sync = _FakeSync()
        ..settings = () {
          reads++;
          return _settings(
            rules: reads == 1 ? <String>[_shaA] : <String>[_shaA, _shaB],
          );
        };
      await _pumpTab(tester, SettingsTab(sync: sync, onAuthError: () {}));
      await tester.tap(
        find.byKey(ValueKey<String>('moderation-settings-rule-remove-$_shaA')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('moderation-settings-rules-save')));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text(kRulesChangedOnServerMessage), findsOneWidget);
      expect(find.text(kRulesSaveTitle), findsNothing);
      expect(sync.settingsWrites, isEmpty);
      await tester.tap(
        find.byKey(const Key('moderation-settings-rules-reload')),
      );
      await tester.pumpAndSettle();
      expect(find.text(kRulesChangedOnServerMessage), findsNothing);
      expect(find.text('2/50'), findsOneWidget);
    });

    testWidgets('empreintes : liste changée PENDANT le dialogue des '
        'différences → relue après confirmation, RIEN envoyé (SEC-P4b3-04)', (
      WidgetTester tester,
    ) async {
      int reads = 0;
      final _FakeSync sync = _FakeSync()
        ..settings = () {
          reads++;
          return _settings(
            rules: reads < 3 ? <String>[_shaA] : <String>[_shaA, _shaB],
          );
        };
      await _pumpTab(tester, SettingsTab(sync: sync, onAuthError: () {}));
      await tester.tap(
        find.byKey(ValueKey<String>('moderation-settings-rule-remove-$_shaA')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('moderation-settings-rules-save')));
      await tester.pumpAndSettle();
      expect(find.text(kRulesSaveTitle), findsOneWidget);
      await tester.tap(
        find.widgetWithText(FilledButton, kRulesSaveConfirmButton),
      );
      await tester.pumpAndSettle();
      expect(reads, 3);
      expect(sync.settingsWrites, isEmpty);
      expect(find.text(kRulesChangedOnServerMessage), findsOneWidget);
    });

    testWidgets('Allumer : compteurs RELUS à l’ouverture du dialogue fort ; '
        'déjà allumé ailleurs → pas de dialogue (SEC-P4b3-04)', (
      WidgetTester tester,
    ) async {
      int reads = 0;
      final _FakeSync sync = _FakeSync()
        ..settings = () {
          reads++;
          return _settings(lastHour: reads == 1 ? 1 : 3);
        };
      await _pumpTab(tester, SettingsTab(sync: sync, onAuthError: () {}));
      await tester.tap(find.byKey(const Key('moderation-settings-switch')));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(
        find.text('Bans automatiques : 3/3 (1 h) · 2/10 (24 h)'),
        findsOne,
      );
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(sync.settingsWrites, isEmpty);

      sync.settings = () => _settings(enabled: true);
      await tester.tap(find.byKey(const Key('moderation-settings-switch')));
      await tester.pumpAndSettle();
      expect(find.text(kTurnOnTitle), findsNothing);
      expect(find.text(kAutoBanOnSubtitle), findsOneWidget);
      expect(sync.settingsWrites, isEmpty);
    });

    testWidgets('400 du serveur : message affiché tel quel', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync()
        ..writeSettings = (_SettingsWrite w) => throw const AdminApiException(
          400,
          'max_auto_bans_per_hour : 0 à 100.',
        );
      await _pumpTab(tester, SettingsTab(sync: sync, onAuthError: () {}));
      await tester.enterText(
        find.byKey(const Key('moderation-settings-hour')),
        '2',
      );
      await tester.tap(
        find.byKey(const Key('moderation-settings-save-ceilings')),
      );
      await tester.pumpAndSettle();
      expect(find.text('max_auto_bans_per_hour : 0 à 100.'), findsOneWidget);
      await _drainSnacks(tester);
    });

    testWidgets('preuves : aperçu, confirmation, purge, bilan', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync();
      await _pumpTab(tester, SettingsTab(sync: sync, onAuthError: () {}));
      await tester.enterText(
        find.byKey(const Key('moderation-settings-purge-days')),
        '10',
      );
      await tester.tap(
        find.byKey(const Key('moderation-settings-purge-preview')),
      );
      await tester.pump();
      expect(
        find.text('Nombre de jours invalide : entier de 30 à 3650.'),
        findsOneWidget,
      );
      expect(sync.evidencePurges, isEmpty);
      await tester.enterText(
        find.byKey(const Key('moderation-settings-purge-days')),
        '180',
      );
      await tester.tap(
        find.byKey(const Key('moderation-settings-purge-preview')),
      );
      await tester.pump();
      await tester.pump();
      expect(sync.evidencePurges.single, (days: 180, apply: false));
      expect(find.text(evidencePreviewText(4)), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('moderation-settings-purge-apply')),
      );
      await tester.pumpAndSettle();
      expect(find.text(evidencePurgeConfirmTitle(4)), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Supprimer'));
      await tester.pumpAndSettle();
      expect(sync.evidencePurges.last, (days: 180, apply: true));
      expect(find.text('4 preuve(s) supprimée(s).'), findsOneWidget);
    });
  });

  group('Pages bloquées', () {
    testWidgets('URL révélée non cliquable, actions selon le statut, levée '
        'depuis la liste (détail + motif obligatoire)', (
      WidgetTester tester,
    ) async {
      int loads = 0;
      int changed = 0;
      final _FakeSync sync = _FakeSync()
        ..blockedPages = (int page) {
          loads++;
          return BlockedPagesPage(
            total: 2,
            pages: <BlockedPage>[
              BlockedPage.fromJson(<String, dynamic>{
                'id': 1,
                'url': 'https://exemple.test/a$_rlo',
                'host': 'exemple.test',
                'status': 'en_revue',
                'origin': 'auto',
                'category': 'injection_ia',
                'ban_event_id': 4,
              })!,
              BlockedPage.fromJson(<String, dynamic>{
                'id': 2,
                'url': 'https://exemple.test/b',
                'status': 'confirme',
                'origin': 'auto',
                'category': 'injection_ia',
              })!,
            ],
          );
        }
        ..detail = ((int id) => reviewDetail(
          id: id,
          targetKind: 'page',
          targetKey: 'https://exemple.test/a',
        ))
        ..decide = ((_Decision d) =>
            const ReviewDecideResult(result: 'lifted', targetKind: 'page'));
      await _pumpTab(
        tester,
        BlockedPagesTab(
          sync: sync,
          isOwner: true,
          onAuthError: () {},
          onChanged: () => changed++,
        ),
      );
      expect(find.text(kBlockedPagesHelp), findsOneWidget);
      expect(find.text('Page 1 / 1'), findsOneWidget);
      expect(
        shownText(
          tester,
          find.byKey(const ValueKey<String>('moderation-page-url-1')),
        ),
        'https://exemple.test/a⟦U+202E⟧',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('moderation-pages-table')),
          matching: find.byType(InkWell),
        ),
        findsNWidgets(3),
        reason: 'seuls les 3 boutons de la ligne 1 (aucune ligne cliquable)',
      );
      expect(
        find.byKey(const ValueKey<String>('moderation-page-2-detail')),
        findsNothing,
        reason: 'ligne sans ban_event_id : aucune action',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('moderation-page-1-lift')),
      );
      await _pumpDialog(tester);
      expect(sync.calls, contains('review-detail 4'));
      expect(find.byKey(const Key('moderation-decision-detail')), findsOne);
      final Finder submit = find.byKey(const Key('moderation-decision-submit'));
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('moderation-decision-reason')),
        ' motif ',
      );
      await tester.pump();
      await tester.tap(submit);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sync.decisions.single, (
        eventId: 4,
        decision: ReviewDecision.lift,
        reason: 'motif',
      ));
      expect(loads, 2);
      expect(changed, 1);
      await _drainSnacks(tester);
    });
  });

  group('Journal', () {
    testWidgets('filtres : type, action, clé exacte (UUID en minuscules) ; '
        'Effacer', (WidgetTester tester) async {
      final _FakeSync sync = _FakeSync()
        ..eventsList = (int page) => EventsPage(
          total: 1,
          page: 0,
          pageSize: 50,
          items: <BanEvent>[
            _event(5, <String, dynamic>{
              'action': 'lift',
              'actor_kind': 'revue',
              'actor_username': 'compte-exemple',
              'note': 'motif neutre',
              'ref_event_id': 4,
            }),
          ],
        );
      await _pumpTab(tester, EventsTab(sync: sync, onAuthError: () {}));
      expect(sync.events.single, (
        page: 0,
        kind: null,
        key: null,
        action: null,
      ));
      expect(find.text('Levée'), findsOneWidget);
      expect(find.text('réf. #4'), findsOneWidget);
      expect(
        shownText(
          tester,
          find.byKey(const ValueKey<String>('moderation-event-note-5')),
        ),
        'motif neutre',
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('moderation-events-kind-0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compte').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('moderation-events-action-0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Levée').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('moderation-events-key')),
        '  ${_uuid.toUpperCase()} ',
      );
      await tester.tap(find.byKey(const Key('moderation-events-filter')));
      await tester.pump();
      await tester.pump();
      expect(sync.events.last, (
        page: 0,
        kind: 'account',
        key: _uuid,
        action: 'lift',
      ));

      await tester.tap(find.byKey(const Key('moderation-events-clear')));
      await tester.pump();
      await tester.pump();
      expect(sync.events.last, (page: 0, kind: null, key: null, action: null));
    });
  });

  group('En-tête', () {
    testWidgets('pastilles, bandeau du disjoncteur, « Voir les réglages », '
        '« Actualiser »', (WidgetTester tester) async {
      int opened = 0;
      int refreshed = 0;
      final ModerationSettings s = _settings(
        trippedAt: '2026-09-28T03:15:00+00:00',
      );
      await pumpBody(
        tester,
        ModerationHeader(
          settings: s,
          onRefresh: () => refreshed++,
          onOpenSettings: () => opened++,
        ),
        width: 1000,
      );
      expect(find.text('Modération des bans automatiques'), findsOneWidget);
      expect(find.text('Ban automatique : éteint'), findsOneWidget);
      expect(find.text('File : 2'), findsOneWidget);
      final DateTime local = DateTime.parse(
        '2026-09-28T03:15:00+00:00',
      ).toLocal();
      String two(int v) => v.toString().padLeft(2, '0');
      expect(
        find.textContaining(
          '⛔ Disjoncteur déclenché le ${two(local.day)}/${two(local.month)}/'
          '${local.year} ${two(local.hour)}:${two(local.minute)}',
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('moderation-header-open-settings')),
      );
      await tester.tap(find.byKey(const Key('moderation-refresh')));
      await tester.pump();
      expect(opened, 1);
      expect(refreshed, 1);
    });

    testWidgets('réglages illisibles : message, pas de pastille', (
      WidgetTester tester,
    ) async {
      await pumpBody(
        tester,
        ModerationHeader(
          settings: null,
          error: headerSettingsError(forbidden: false),
          onRefresh: () {},
          onOpenSettings: () {},
        ),
        width: 1000,
      );
      expect(find.text('État de la modération illisible.'), findsOneWidget);
      expect(find.byKey(const Key('moderation-header-state')), findsNothing);
      expect(
        headerSettingsError(forbidden: true),
        'Réservé au compte principal.',
      );
    });
  });
}
