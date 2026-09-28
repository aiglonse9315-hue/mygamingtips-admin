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
import 'package:mgt_admin/domain/models/content.dart';
import 'package:mgt_admin/domain/models/game.dart';
import 'package:mgt_admin/domain/models/moderation.dart';
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
}

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
