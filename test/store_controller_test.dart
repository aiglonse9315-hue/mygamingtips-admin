// StoreController exécuté en VM (revue P4b-3, TST-01) : depuis que `Store`
// passe par `data/local_storage.dart` (import conditionnel : localStorage
// du navigateur sur le web, table en mémoire en VM), le contrôleur se monte
// dans `flutter test` avec un `SupabaseSync` factice (méthodes surchargées ;
// toute autre requête HTTP reçoit une réponse neutre d'un MockClient).
//
// Couvre l'ENCHAÎNEMENT réel du contrôleur (et plus seulement les règles
// pures) : ban optimiste puis retrait, 401 → onAuthError + sessionExpired,
// 409 d'un ban automatique (la ligne reste), liste des bannis jamais mise en
// cache en production (SEC-P4b3-01) et écritures de jeux croisées avec un
// chargement des jeux inactifs (ARC-03).
//
// Données neutres, aucun secret, aucun réseau.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mgt_admin/data/local_storage.dart';
import 'package:mgt_admin/data/store.dart';
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/banned_user.dart';
import 'package:mgt_admin/domain/models/category.dart';
import 'package:mgt_admin/domain/models/content.dart';
import 'package:mgt_admin/domain/models/game.dart';
import 'package:mgt_admin/domain/models/moderation.dart';
import 'package:mgt_admin/domain/models/suggestion.dart';
import 'package:mgt_admin/domain/models/suggestion_author.dart';
import 'package:mgt_admin/domain/moderation_actions.dart';
import 'package:mgt_admin/domain/write_outcome.dart';
import 'package:mgt_admin/state/store_controller.dart';

const String _uuid = '11111111-2222-4333-8444-555555555555';
const String _gameId = '22222222-3333-4444-8555-666666666666';
const String _kBannedKey = 'mgt_admin_banned';

Game _game({String id = _gameId, bool active = true}) => Game(
  id: id,
  name: 'Jeu neutre',
  active: active,
  createdAt: DateTime.utc(2026, 1, 1),
);

BannedUser _serverBanned({
  String id = _uuid,
  String name = 'Joueur A',
  String origin = 'manual',
  String status = 'manuel',
  int? eventId,
}) => BannedUser.fromServer(<String, dynamic>{
  'id': id,
  'display_name': name,
  'is_banned': true,
  'ban_reason': 'Motif neutre',
  'banned_at': '2026-09-28T10:00:00+00:00',
  'category': 'moderation',
  'origin': origin,
  'status': status,
  'ban_event_id': eventId,
});

/// `SupabaseSync` factice : réponses préparées par le test, appels comptés.
class _FakeSync extends SupabaseSync {
  _FakeSync()
    : super(
        supabaseUrl: 'https://exemple.invalid',
        anonKey: 'anon',
        catalogEndpoint: 'https://exemple.invalid/functions/v1/admin-catalog',
        adminToken: 'jeton',
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

  /// Jeux ACTIFS de la lecture publique (synchro des jeux).
  List<Game> serverGames = <Game>[];

  /// Liste des bannis rendue par `profiles/banned-list`.
  List<BannedUser> serverBanned = <BannedUser>[];

  /// Un chargement `games/list {active:false}` par appel, terminé par le test.
  final List<Completer<List<Game>>> inactiveLoads = <Completer<List<Game>>>[];

  /// Réponse de `games` (envoi partiel).
  Game Function(String id, Map<String, Object?> patch) onPatch =
      (String id, Map<String, Object?> patch) =>
          _game(id: id, active: patch['active'] as bool? ?? true);

  Future<ManualBanResult> Function(String id) onBan = (String id) async =>
      const ManualBanResult(result: 'applied', eventId: 5);

  Future<ManualUnbanResult> Function(String id) onUnban = (String id) async =>
      const ManualUnbanResult(result: 'lifted', eventId: 6);

  int bannedListReads = 0;
  final List<String> deleted = <String>[];

  @override
  Future<({List<Game> items, DateTime? maxUpdatedAt})> fetchGames({
    int page = 0,
    int pageSize = 1000,
    String? since,
  }) async => (
    items: page == 0 ? List<Game>.of(serverGames) : <Game>[],
    maxUpdatedAt: null,
  );

  @override
  Future<({List<Content> items, DateTime? maxUpdatedAt})> fetchContents({
    int page = 0,
    int pageSize = 1000,
    String? since,
  }) async => (items: <Content>[], maxUpdatedAt: null);

  @override
  Future<int> fetchTableCount(String table, {String? filter}) async =>
      table == 'games' ? serverGames.length : 0;

  @override
  Future<List<Game>> fetchAllGames({bool? active}) {
    final Completer<List<Game>> c = Completer<List<Game>>();
    inactiveLoads.add(c);
    return c.future;
  }

  @override
  Future<Game> patchGame(String id, Map<String, Object?> patch) async =>
      onPatch(id, patch);

  @override
  Future<void> deleteGame(String id) async {
    deleted.add(id);
    serverGames = serverGames.where((Game g) => g.id != id).toList();
  }

  @override
  Future<List<BannedUser>> fetchBannedList() async {
    bannedListReads++;
    return List<BannedUser>.of(serverBanned);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchBadContributors() async =>
      <Map<String, dynamic>>[];

  @override
  Future<ManualBanResult> banUser(
    String userId, {
    String? reason,
    String? category,
  }) => onBan(userId);

  @override
  Future<ManualUnbanResult> unbanUser(String userId) => onUnban(userId);

  /// L6 — suggestions analysées du serveur (mode `analyzed`) : TOUTES sans
  /// curseur, [analyzedDelta] avec un curseur (`since`).
  List<Suggestion> serverAnalyzed = <Suggestion>[];
  List<Suggestion> analyzedDelta = <Suggestion>[];

  /// `since` reçu à chaque lecture du mode `analyzed` (page 0).
  final List<String?> analyzedSinces = <String?>[];

  /// Relecture L6 (F1 / F2) : modes « new » et « analyzing » du serveur.
  /// null = non surchargé (réponse neutre du client HTTP : liste vide).
  List<Suggestion>? serverNew;
  List<Suggestion> newDelta = <Suggestion>[];
  List<Suggestion>? serverAnalyzing;

  @override
  Future<({List<Suggestion> items, DateTime? maxUpdatedAt})> fetchSuggestions({
    int page = 0,
    int pageSize = 500,
    String? since,
  }) async {
    final List<Suggestion>? all = serverNew;
    if (all == null) {
      return super.fetchSuggestions(page: page, pageSize: pageSize, since: since);
    }
    final List<Suggestion> rows = since == null ? all : newDelta;
    return (
      items: page == 0 ? List<Suggestion>.of(rows) : <Suggestion>[],
      maxUpdatedAt: DateTime.utc(2026, 10, 12, 9),
    );
  }

  @override
  Future<({List<Suggestion> items, DateTime? maxUpdatedAt})>
  fetchSentinelleAnalyzing({int page = 0, int pageSize = 500, String? since}) async {
    final List<Suggestion>? all = serverAnalyzing;
    if (all == null) {
      return super.fetchSentinelleAnalyzing(
        page: page,
        pageSize: pageSize,
        since: since,
      );
    }
    return (
      items: page == 0 ? List<Suggestion>.of(all) : <Suggestion>[],
      maxUpdatedAt: null,
    );
  }

  /// Validation d'une suggestion (`suggestions/accept`) : ids reçus ; lève
  /// [acceptError] s'il est posé.
  final List<String> accepted = <String>[];
  Object? acceptError;

  @override
  Future<void> acceptSuggestion({
    required String suggestionId,
    required String gameId,
    required ContentCategory category,
    required String titleAdmin,
    bool isVideo = false,
    DateTime? publishedAt,
    String? videoLanguage,
  }) async {
    accepted.add(suggestionId);
    final Object? e = acceptError;
    if (e != null) throw e;
  }

  @override
  Future<({List<Suggestion> items, DateTime? maxUpdatedAt})>
  fetchSentinelleSuggestions({
    int page = 0,
    int pageSize = 500,
    String? since,
  }) async {
    if (page == 0) analyzedSinces.add(since);
    final List<Suggestion> rows = since == null ? serverAnalyzed : analyzedDelta;
    return (
      items: page == 0 ? List<Suggestion>.of(rows) : <Suggestion>[],
      maxUpdatedAt: DateTime.utc(2026, 10, 12, 9),
    );
  }
}

int _sugSeq = 0;

/// Suggestion analysée par Sentinelle (L6), id UUID neutre.
Suggestion _analyzed(
  String url, {
  String verdict = 'recommended',
  double confidence = 0.9,
  Map<String, Object?>? revue,
  DateTime? startedAt,
  String source = Suggestion.sourceVision,
}) {
  _sugSeq++;
  return Suggestion(
    id: '33333333-4444-4555-8666-${_sugSeq.toString().padLeft(12, '0')}',
    url: url,
    status: SuggestionStatus.pending,
    sharedAt: DateTime.utc(2026, 10, 12),
    author: const SuggestionAuthor(id: '', displayName: 'Vision'),
    sentinelleStartedAt: startedAt,
    source: source,
    aiRecommendation: AiRecommendation.fromJson(<String, dynamic>{
      'verdict': verdict,
      'confidence': confidence,
      'reason': 'neutre',
      'revue_p5': ?revue,
    }),
  );
}

const String _ytUrl = 'https://www.youtube.com/watch?v=AAAAAAAAAAA';
const String _webUrl = 'https://www.jeuxvideo.com/news/123.htm';

Store _store() => Store(
  gamesSeed: '[]',
  contentsSeed: '[]',
  suggestionsSeed: '[]',
  bannedSeed: '[]',
  plusSeed: '[]',
);

/// Toute requête HTTP non surchargée (traductions, alias, suggestions,
/// statut de synchro…) reçoit une réponse neutre : liste vide en lecture,
/// objet vide en écriture.
final MockClient _neutralHttp = MockClient((http.Request req) async {
  final bool read = req.method == 'GET' || req.method == 'HEAD';
  return http.Response(
    read ? '[]' : '{}',
    200,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
});

/// Exécute [body] avec le client HTTP neutre (le contrôleur et ses
/// continuations restent dans la zone du client).
Future<void> _run(Future<void> Function() body) =>
    http.runWithClient(body, () => _neutralHttp);

/// Laisse s'écouler les microtâches et continuations en attente.
Future<void> _settle() async {
  for (int i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Contrôleur de PRODUCTION monté sur [sync], synchro initiale terminée.
Future<StoreController> _production(_FakeSync sync) async {
  final StoreController c = StoreController(_store(), sync: sync);
  await _settle();
  return c;
}

bool _storageMentions(String text) =>
    browserLocalStorage.values.any((String v) => v.contains(text));

void main() {
  setUp(browserLocalStorage.clear);

  group('Sections de Sentinelle (P5, lot L6)', () {
    test('trois sections disjointes ; « 99% sûr » > 0,95, « Attente » = '
        'YouTube ≤ 0,95, « À vérifier » = le reste, astuces courtes '
        'd\'abord', () async {
      await _run(() async {
        final _FakeSync sync = _FakeSync();
        final Suggestion web90 = _analyzed(_webUrl);
        final Suggestion yt90 = _analyzed(_ytUrl);
        final Suggestion yt95 = _analyzed(_ytUrl, confidence: 0.95);
        final Suggestion yt97 = _analyzed(_ytUrl, confidence: 0.97);
        final Suggestion web100 = _analyzed(_webUrl, confidence: 1.0);
        final Suggestion astuce = _analyzed(
          _ytUrl,
          verdict: 'caution',
          confidence: 0.0,
          revue: const <String, Object?>{
            'etat': 'sans_parole_court',
            'motif': 'astuce_courte',
          },
        );
        sync.serverAnalyzed = <Suggestion>[
          web90,
          yt90,
          yt95,
          yt97,
          web100,
          astuce,
        ];
        final StoreController c = await _production(sync);
        await c.ensureDatasets(<SyncDataset>{SyncDataset.sentinelleAnalyzed});
        await _settle();
        List<String> ids(List<Suggestion> l) => [for (final s in l) s.id];
        expect(ids(c.sentinelleTrusted), ids(<Suggestion>[yt97, web100]));
        expect(
          ids(c.sentinelleAwaitingSecondPass),
          ids(<Suggestion>[yt90, yt95]),
        );
        expect(ids(c.sentinelleToVerify), ids(<Suggestion>[astuce, web90]));
        // Calcul mis en cache : même liste tant que la source ne change pas.
        expect(
          identical(c.sentinelleToVerify, c.sentinelleToVerify),
          isTrue,
        );
      });
    });

    test('correctif L6 : 1re sync du mode « analysées » COMPLÈTE même avec '
        'un curseur valide gardé dans le navigateur (rechargement de la '
        'page) ; la suivante est incrémentale', () async {
      await _run(() async {
        // Curseur de moins de 24 h laissé par une visite précédente.
        _store().saveCursor(
          'sug_analyzed',
          '2026-10-12T08:00:00.000Z',
          DateTime.now().toUtc(),
        );
        final _FakeSync sync = _FakeSync()
          ..serverAnalyzed = <Suggestion>[
            _analyzed(_ytUrl),
            _analyzed(_webUrl, confidence: 1.0),
          ]
          ..analyzedDelta = <Suggestion>[];
        final StoreController c = await _production(sync);
        await c.ensureDatasets(<SyncDataset>{SyncDataset.sentinelleAnalyzed});
        await _settle();
        expect(sync.analyzedSinces, <String?>[null]);
        expect(c.sentinelleAwaitingSecondPass, hasLength(1));
        expect(c.sentinelleTrusted, hasLength(1));
        // 2e sync de la session : delta seulement (curseur), rien de perdu.
        await c.syncFromSupabase(
          datasets: <SyncDataset>{SyncDataset.sentinelleAnalyzed},
        );
        await _settle();
        expect(sync.analyzedSinces, hasLength(2));
        expect(sync.analyzedSinces.last, isNotNull);
        expect(c.sentinelleAwaitingSecondPass, hasLength(1));
        expect(c.sentinelleTrusted, hasLength(1));
      });
    });

    test('relecture R01 : une suggestion passée de « new » à « analysées » '
        'panneau fermé ne reste pas en double dans « new » (gardée dans le '
        'navigateur) ; une ligne du Scruteur (jamais démarrée) y reste',
        () async {
      await _run(() async {
        final Suggestion r = _analyzed(
          _ytUrl,
          startedAt: DateTime.utc(2026, 10, 12, 8),
        );
        final Suggestion scruteur = _analyzed(
          _webUrl,
          confidence: 1.0,
          source: Suggestion.sourceScruteur,
        );
        // Liste « new » d'une visite précédente : r encore sans analyse.
        final Suggestion rAsNew = Suggestion(
          id: r.id,
          url: r.url,
          status: SuggestionStatus.pending,
          sharedAt: r.sharedAt,
          author: r.author,
          source: r.source,
        );
        _store()
          ..ensureInitialized()
          ..saveSuggestions(<Suggestion>[rAsNew, scruteur]);
        final DateTime now = DateTime.now().toUtc();
        for (final String n in <String>[
          'sug_new',
          'sug_analyzing',
          'sug_analyzed',
          'sug_scruteur',
          'sug_gtc',
        ]) {
          _store().saveCursor(n, '2026-10-12T08:00:00.000Z', now);
        }
        final _FakeSync sync = _FakeSync()
          ..serverAnalyzed = <Suggestion>[r, scruteur];
        final StoreController c = await _production(sync);
        expect(c.suggestions.map((Suggestion s) => s.id), contains(r.id));
        await c.ensureDatasets(<SyncDataset>{SyncDataset.sentinelleAnalyzed});
        await _settle();
        expect(sync.analyzedSinces, <String?>[null]);
        expect(
          c.suggestions.map((Suggestion s) => s.id),
          isNot(contains(r.id)),
        );
        expect(c.suggestions.map((Suggestion s) => s.id), contains(scruteur.id));
        expect(
          c.sentinelleSuggestions.map((Suggestion s) => s.id),
          <String>[r.id, scruteur.id],
        );
        // Retrait aussi dans le navigateur (relu au prochain chargement).
        expect(
          _store().loadSuggestions().map((Suggestion s) => s.id),
          isNot(contains(r.id)),
        );
      });
    });
  });

  group('« Ajouter manuellement » depuis Sentinelle (correctif 12/10)', () {
    test('la suggestion validée quitte « À vérifier » tout de suite et n\'y '
        'revient pas après la resynchro (delta « analyzed » sans elle)', () async {
      await _run(() async {
        final Suggestion row = _analyzed(_webUrl, verdict: 'caution');
        final Suggestion other = _analyzed(_webUrl, verdict: 'caution');
        final _FakeSync sync = _FakeSync()
          ..serverAnalyzed = <Suggestion>[row, other];
        final StoreController c = await _production(sync);
        await c.ensureDatasets(<SyncDataset>{SyncDataset.sentinelleAnalyzed});
        await _settle();
        expect(c.sentinelleToVerify, hasLength(2));
        // Le serveur ne la renvoie plus (acceptée) : delta vide.
        sync.analyzedDelta = <Suggestion>[];
        final Future<void> done = c.acceptSuggestion(
          suggestion: row,
          gameId: _gameId,
          category: ContentCategory.links,
          titleAdmin: 'Titre neutre',
        );
        // Retrait OPTIMISTE, avant la réponse du serveur.
        expect(c.sentinelleToVerify.map((Suggestion s) => s.id), [other.id]);
        await done;
        await _settle();
        expect(sync.accepted, <String>[row.id]);
        expect(c.sentinelleToVerify.map((Suggestion s) => s.id), [other.id]);
        expect(c.sentinelleSuggestions.map((Suggestion s) => s.id), [
          other.id,
        ]);
        expect(c.lastActionError, isNull);
      });
    });

    test('échec du serveur : la suggestion revient dans « À vérifier », '
        'message d\'erreur', () async {
      await _run(() async {
        final Suggestion row = _analyzed(_webUrl, verdict: 'caution');
        final _FakeSync sync = _FakeSync()
          ..serverAnalyzed = <Suggestion>[row]
          ..acceptError = Exception('panne neutre');
        final StoreController c = await _production(sync);
        await c.ensureDatasets(<SyncDataset>{SyncDataset.sentinelleAnalyzed});
        await _settle();
        await c.acceptSuggestion(
          suggestion: row,
          gameId: _gameId,
          category: ContentCategory.links,
          titleAdmin: 'Titre neutre',
        );
        await _settle();
        expect(c.sentinelleToVerify.map((Suggestion s) => s.id), [row.id]);
        expect(c.lastActionError, contains('Suggestion non validée'));
        // Le tombstone est tombé : une sync complète la garde affichée.
        await c.syncFromSupabase(
          datasets: <SyncDataset>{SyncDataset.sentinelleAnalyzed},
          forceFull: true,
        );
        await _settle();
        expect(c.sentinelleToVerify.map((Suggestion s) => s.id), [row.id]);
      });
    });

    test('relecture F1 : une ligne du Scruteur (aussi dans « new ») validée '
        'à la main quitte « À vérifier » mais RESTE dans les « Acceptées » '
        'après une sync complète (aucun tombstone)', () async {
      await _run(() async {
        final Suggestion x = _analyzed(
          _webUrl,
          verdict: 'caution',
          confidence: 0.5,
          source: Suggestion.sourceScruteur,
        );
        final _FakeSync sync = _FakeSync()
          ..serverNew = <Suggestion>[x]
          ..serverAnalyzed = <Suggestion>[x];
        final StoreController c = await _production(sync);
        await c.ensureDatasets(<SyncDataset>{SyncDataset.sentinelleAnalyzed});
        await _settle();
        expect(c.suggestions.map((Suggestion s) => s.id), [x.id]);
        expect(c.sentinelleToVerify.map((Suggestion s) => s.id), [x.id]);
        // Côté serveur après la validation : acceptée, hors « analyzed ».
        final Suggestion accepted = x.copyWith(
          status: SuggestionStatus.accepted,
        );
        sync
          ..serverNew = <Suggestion>[accepted]
          ..newDelta = <Suggestion>[accepted]
          ..serverAnalyzed = <Suggestion>[]
          ..analyzedDelta = <Suggestion>[];
        final Future<void> done = c.acceptSuggestion(
          suggestion: x,
          gameId: _gameId,
          category: ContentCategory.links,
          titleAdmin: 'Titre neutre',
        );
        expect(c.sentinelleToVerify, isEmpty);
        await done;
        await _settle();
        await c.syncFromSupabase(forceFull: true);
        await _settle();
        expect(c.sentinelleToVerify, isEmpty);
        final List<Suggestion> news = c.suggestions
            .where((Suggestion s) => s.id == x.id)
            .toList();
        expect(news, hasLength(1));
        expect(news.single.status, SuggestionStatus.accepted);
      });
    });
  });

  group('Polling « Analyses en cours » (relecture L6, F2)', () {
    testWidgets('le tick (hors chaîne de sync) ne retire rien de « new »', (
      WidgetTester tester,
    ) async {
      browserLocalStorage.clear();
      {
        final Suggestion x = _analyzed(_ytUrl);
        final Suggestion xAsNew = Suggestion(
          id: x.id,
          url: x.url,
          status: SuggestionStatus.pending,
          sharedAt: x.sharedAt,
          author: x.author,
          source: x.source,
        );
        // Réponse du tick plus vieille qu'un « Débloquer » déjà fusionné :
        // x encore « en analyse » (démarrée) alors qu'elle est revenue dans
        // « new ».
        final Suggestion xStarted = Suggestion(
          id: x.id,
          url: x.url,
          status: SuggestionStatus.pending,
          sharedAt: x.sharedAt,
          author: x.author,
          source: x.source,
          sentinelleStartedAt: DateTime.utc(2026, 10, 12, 8),
        );
        final _FakeSync sync = _FakeSync()
          ..serverNew = <Suggestion>[xAsNew]
          ..serverAnalyzing = <Suggestion>[];
        // Mise en place en temps RÉEL (synchros du contrôleur) ; seul le
        // tick de 30 s passe par le temps simulé du test.
        late StoreController c;
        await tester.runAsync(
          () => _run(() async {
            c = await _production(sync);
            await c.ensureDatasets(<SyncDataset>{SyncDataset.suggestionsNew});
            await _settle();
          }),
        );
        expect(c.suggestions.map((Suggestion s) => s.id), [x.id]);
        sync.serverAnalyzing = <Suggestion>[xStarted];
        c.startAnalyzingPolling();
        await tester.pump(const Duration(seconds: 31));
        await tester.pump();
        expect(c.sentinelleAnalyzing.map((Suggestion s) => s.id), [x.id]);
        expect(c.suggestions.map((Suggestion s) => s.id), [x.id]);
        c.stopAnalyzingPolling();
      }
    });
  });

  group('Bannis jamais mis en cache en production (SEC-P4b3-01)', () {
    test('cache hérité effacé au démarrage ; relecture gardée en mémoire '
        'seulement', () async {
      await _run(() async {
        browserLocalStorage['mgt_admin_initialized'] = 'true';
        browserLocalStorage[_kBannedKey] = jsonEncode(<Object?>[
          <String, dynamic>{
            'id': _uuid,
            'displayName': 'Nom en cache',
            'email': 'ancien@exemple.test',
            'reason': 'Motif en cache',
            'bannedAt': '2026-09-01T00:00:00.000Z',
          },
        ]);
        final _FakeSync sync = _FakeSync()
          ..serverBanned = <BannedUser>[_serverBanned()];
        final StoreController c = await _production(sync);
        expect(browserLocalStorage.containsKey(_kBannedKey), isFalse);
        expect(c.banned, isEmpty);

        await c.reloadBannedList();
        expect(sync.bannedListReads, 1);
        expect(c.bannedEntry(_uuid)?.displayName, 'Joueur A');
        expect(browserLocalStorage.containsKey(_kBannedKey), isFalse);
        expect(_storageMentions('Joueur A'), isFalse);
        expect(_storageMentions('Motif neutre'), isFalse);
      });
    });

    test('bannir puis débannir : aucune écriture du cache', () async {
      await _run(() async {
        final _FakeSync sync = _FakeSync();
        final StoreController c = await _production(sync);
        final WriteOutcome ban = await c.banAccount(
          _uuid,
          displayName: 'Joueur B',
          category: 'spam',
          reason: 'Motif B',
        );
        expect(ban.ok, isTrue);
        expect(browserLocalStorage.containsKey(_kBannedKey), isFalse);
        expect(_storageMentions('Joueur B'), isFalse);
        final UnbanOutcome unban = await c.unbanAccount(_uuid);
        expect(unban.kind, UnbanKind.lifted);
        expect(browserLocalStorage.containsKey(_kBannedKey), isFalse);
      });
    });

    test('déconnexion : liste des bannis oubliée', () async {
      await _run(() async {
        final _FakeSync sync = _FakeSync()
          ..serverBanned = <BannedUser>[_serverBanned()];
        final StoreController c = await _production(sync);
        c.updateAdminToken('a.b.c'); // connexion : datasets du tableau de bord
        await _settle();
        expect(c.bannedEntry(_uuid), isNotNull);
        c.updateAdminToken(null);
        expect(c.banned, isEmpty);
        expect(browserLocalStorage.containsKey(_kBannedKey), isFalse);
        // Reconnexion dans la même page, moins de 2 min après : la liste
        // vidée doit être RELUE (essai local du 28/09/2026 : elle restait
        // vide car le jeu de données passait encore pour « frais »).
        c.updateAdminToken('d.e.f');
        await _settle();
        expect(c.bannedEntry(_uuid), isNotNull);
      });
    });

    test('aperçu (sans Supabase) : la liste locale reste persistée', () async {
      final StoreController c = StoreController(_store());
      final WriteOutcome r = await c.banAccount(
        _uuid,
        displayName: 'Compte démo',
        category: 'moderation',
      );
      expect(r.ok, isTrue);
      expect(browserLocalStorage[_kBannedKey], contains(_uuid));
    });
  });

  group('Enchaînements des bans (TST-01)', () {
    test('ban : entrée optimiste visible PENDANT la requête, retirée sur '
        '404 avec « Profil introuvable. »', () async {
      await _run(() async {
        final Completer<ManualBanResult> pending = Completer<ManualBanResult>();
        final _FakeSync sync = _FakeSync()
          ..onBan = ((String id) => pending.future);
        final StoreController c = await _production(sync);
        final Future<WriteOutcome> call = c.banAccount(
          _uuid,
          displayName: 'Joueur C',
          category: 'moderation',
        );
        await _settle();
        expect(c.isAuthorBanned(_uuid), isTrue, reason: 'badge immédiat');
        pending.completeError(
          const AdminApiException(404, 'Profil introuvable.'),
        );
        final WriteOutcome r = await call;
        expect(r.ok, isFalse);
        expect(r.message, 'Profil introuvable.');
        expect(c.isAuthorBanned(_uuid), isFalse);
      });
    });

    test(
      'ban : 401 → onAuthError puis sessionExpired, entrée retirée',
      () async {
        await _run(() async {
          final _FakeSync sync = _FakeSync()
            ..onBan = ((String id) async =>
                throw const AdminAuthException('Session expirée'));
          final StoreController c = await _production(sync);
          int authErrors = 0;
          c.onAuthError = () => authErrors++;
          final WriteOutcome r = await c.banAccount(
            _uuid,
            category: 'moderation',
          );
          expect(r.sessionExpired, isTrue);
          expect(authErrors, 1);
          expect(c.isAuthorBanned(_uuid), isFalse);
        });
      },
    );

    test('ban déjà posé : avertissement, relecture de la liste', () async {
      await _run(() async {
        final _FakeSync sync = _FakeSync()
          ..onBan = ((String id) async =>
              const ManualBanResult(result: 'already_banned'))
          ..serverBanned = <BannedUser>[_serverBanned()];
        final StoreController c = await _production(sync);
        final WriteOutcome r = await c.banAccount(
          _uuid,
          category: 'moderation',
        );
        await _settle();
        expect(r.ok, isTrue);
        expect(r.notice, isNotNull);
        expect(sync.bannedListReads, greaterThanOrEqualTo(1));
        expect(c.bannedEntry(_uuid)?.displayName, 'Joueur A');
      });
    });

    test(
      'débannir un ban AUTOMATIQUE : 409 → autoBan(42), la ligne RESTE',
      () async {
        await _run(() async {
          final _FakeSync sync = _FakeSync()
            ..serverBanned = <BannedUser>[
              _serverBanned(origin: 'auto', status: 'en_revue', eventId: 42),
            ]
            ..onUnban = ((String id) async => throw const AdminApiException(
              409,
              'Bannissement automatique : levée par la revue.',
              body: <String, dynamic>{
                'result': 'auto_ban_use_review',
                'ban_event_id': 42,
              },
            ));
          final StoreController c = await _production(sync);
          await c.reloadBannedList();
          final UnbanOutcome o = await c.unbanAccount(_uuid);
          expect(o.kind, UnbanKind.autoBan);
          expect(o.banEventId, 42);
          await _settle();
          expect(c.bannedEntry(_uuid), isNotNull);
        });
      },
    );

    test('débannir : aucune ligne retirée AVANT la réponse ; lifted → '
        'retrait', () async {
      await _run(() async {
        final Completer<ManualUnbanResult> pending =
            Completer<ManualUnbanResult>();
        final _FakeSync sync = _FakeSync()
          ..serverBanned = <BannedUser>[_serverBanned()]
          ..onUnban = ((String id) => pending.future);
        final StoreController c = await _production(sync);
        await c.reloadBannedList();
        final Future<UnbanOutcome> call = c.unbanAccount(_uuid);
        await _settle();
        expect(c.bannedEntry(_uuid), isNotNull, reason: 'non optimiste');
        sync.serverBanned = <BannedUser>[];
        pending.complete(const ManualUnbanResult(result: 'lifted'));
        expect((await call).kind, UnbanKind.lifted);
        expect(c.bannedEntry(_uuid), isNull);
      });
    });

    test('débannir : 401 → onAuthError puis sessionExpired', () async {
      await _run(() async {
        final _FakeSync sync = _FakeSync()
          ..serverBanned = <BannedUser>[_serverBanned()]
          ..onUnban = ((String id) async =>
              throw const AdminAuthException('Session expirée'));
        final StoreController c = await _production(sync);
        await c.reloadBannedList();
        int authErrors = 0;
        c.onAuthError = () => authErrors++;
        final UnbanOutcome o = await c.unbanAccount(_uuid);
        expect(o.kind, UnbanKind.sessionExpired);
        expect(authErrors, 1);
        expect(c.bannedEntry(_uuid), isNotNull);
      });
    });
  });

  group('Jeux inactifs et écritures croisées (ARC-03)', () {
    test('désactivation pendant un chargement des inactifs : la lecture '
        'partie AVANT est ignorée puis relancée', () async {
      await _run(() async {
        final _FakeSync sync = _FakeSync()..serverGames = <Game>[_game()];
        final StoreController c = await _production(sync);
        expect(c.games.map((Game g) => g.id), <String>[_gameId]);

        unawaited(c.loadInactiveGames());
        await _settle();
        expect(sync.inactiveLoads, hasLength(1));
        expect(c.inactiveGamesLoading, isTrue);

        final WriteOutcome r = await c.setGameActive(_game(), false);
        expect(r.ok, isTrue);
        expect(c.inactiveGames.map((Game g) => g.id), <String>[_gameId]);
        expect(c.games, isEmpty);
        expect(sync.inactiveLoads, hasLength(2), reason: 'lecture relancée');

        // Lecture périmée (partie avant la désactivation) : ignorée.
        sync.inactiveLoads[0].complete(<Game>[]);
        await _settle();
        expect(c.inactiveGames.map((Game g) => g.id), <String>[_gameId]);
        expect(c.inactiveGamesLoading, isTrue);

        sync.inactiveLoads[1].complete(<Game>[_game(active: false)]);
        await _settle();
        expect(c.inactiveGames.map((Game g) => g.id), <String>[_gameId]);
        expect(c.games, isEmpty);
        expect(c.inactiveGamesLoading, isFalse);
        expect(c.inactiveGamesLoaded, isTrue);
      });
    });

    test('réactivation pendant un chargement : la lecture périmée ne retire '
        'pas le jeu de la liste principale', () async {
      await _run(() async {
        final _FakeSync sync = _FakeSync();
        final StoreController c = await _production(sync);
        unawaited(c.loadInactiveGames());
        await _settle();

        final WriteOutcome r = await c.setGameActive(
          _game(active: false),
          true,
        );
        expect(r.ok, isTrue);
        expect(c.games.map((Game g) => g.id), <String>[_gameId]);

        sync.inactiveLoads[0].complete(<Game>[_game(active: false)]);
        await _settle();
        expect(c.games.map((Game g) => g.id), <String>[_gameId]);
        expect(c.inactiveGames, isEmpty);

        sync.inactiveLoads[1].complete(<Game>[]);
        await _settle();
        expect(c.games.map((Game g) => g.id), <String>[_gameId]);
        expect(c.inactiveGames, isEmpty);
        expect(c.inactiveGamesLoading, isFalse);
      });
    });

    test('suppression d’un jeu inactif pendant un chargement : le jeu ne '
        'revient pas', () async {
      await _run(() async {
        final _FakeSync sync = _FakeSync();
        final StoreController c = await _production(sync);
        unawaited(c.loadInactiveGames());
        await _settle();
        sync.inactiveLoads[0].complete(<Game>[_game(active: false)]);
        await _settle();
        expect(c.inactiveGames.map((Game g) => g.id), <String>[_gameId]);

        unawaited(c.loadInactiveGames()); // lecture partie AVANT la suppression
        await _settle();
        await c.deleteGame(_gameId);
        expect(sync.deleted, <String>[_gameId]);
        expect(c.inactiveGames, isEmpty);

        sync.inactiveLoads[1].complete(<Game>[_game(active: false)]);
        await _settle();
        expect(c.inactiveGames, isEmpty, reason: 'lecture périmée ignorée');

        for (final Completer<List<Game>> l in sync.inactiveLoads.skip(2)) {
          if (!l.isCompleted) l.complete(<Game>[]);
        }
        await _settle();
        expect(c.inactiveGames, isEmpty);
        expect(c.inactiveGamesLoading, isFalse);
      });
    });
  });
}
