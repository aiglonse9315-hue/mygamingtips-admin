// Fin de session du panneau (journaux Supabase du 12/10/2026) — tests VM.
//
// Constats : (1) un onglet masqué interrogeait `suggestions/list` environ
// 3 fois par minute pendant 45 min avec un jeton périmé (401 à chaque
// fois) : le rafraîchissement « Analyses en cours » (30 s, 3 pages par
// tick) ne s'arrêtait qu'au démontage de l'écran Sentinelle, qui attend une
// image — aucune dans un onglet masqué ; (2) au chargement, avant la
// connexion, des appels admin-catalog partaient sans jeton utilisable
// (`cache-ops/list` et `games/aliases/list-all` de la synchro publique ;
// passe du tableau de bord enchaînée qui démarre après une déconnexion :
// 5 modes × 3 pages de `suggestions/list` + `profiles/banned-list`).
//
// Vérifie : aucun appel admin-catalog sans jeton utilisable (rejeux
// compris) ; un 401 arrête les rafraîchissements et ne déconnecte qu'une
// fois ; le refus d'une passe partie avant une connexion ne ferme pas la
// nouvelle session ; un fresh_token tardif ne reconnecte pas ; les
// lectures admin du démarrage partent à la connexion. Client HTTP simulé,
// adresses réservées (`.invalid`), aucun secret, aucun réseau.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mgt_admin/data/local_storage.dart';
import 'package:mgt_admin/data/store.dart';
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/state/store_controller.dart';

import 'support/http_fixtures.dart' show isRoute, jsonResponse, testJwt;

/// Requêtes vues par le client simulé (toutes, PostgREST compris).
final List<http.Request> _seen = <http.Request>[];

/// Réponse du client simulé ; neutre par défaut.
http.Response Function(http.Request) _respond = _neutral;

/// Si posée, les requêtes retenues par [_gated] attendent sa fin (requête
/// encore en vol).
Completer<void>? _gate;
bool Function(http.Request) _gated = _isPostgrest;

http.Response _neutral(http.Request req) {
  final bool read = req.method == 'GET' || req.method == 'HEAD';
  return http.Response(
    read ? '[]' : '{}',
    200,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

bool _isCatalog(http.Request req) => req.url.path.contains('/admin-catalog/');

bool _isPostgrest(http.Request req) => !_isCatalog(req);

/// Lecture PostgREST de la table `games` (comptage ou page).
bool _isGamesRead(http.Request req) => req.url.path.endsWith('/rest/v1/games');

/// Routes admin-catalog appelées, dans l'ordre.
List<String> _catalogRoutes() => <String>[
  for (final http.Request r in _seen.where(_isCatalog))
    r.url.path.split('/admin-catalog/').last,
];

final MockClient _client = MockClient((http.Request req) async {
  _seen.add(req);
  final Completer<void>? gate = _gate;
  if (gate != null && _gated(req)) await gate.future;
  return _respond(req);
});

/// Exécute [body] avec le client simulé (les minuteries créées dedans
/// gardent ce client).
R _run<R>(R Function() body) => http.runWithClient(body, () => _client);

/// Comme `main.dart` : jeton vide tant que l'admin n'est pas connecté.
SupabaseSync _sync(String adminToken) => SupabaseSync(
  supabaseUrl: 'https://exemple.invalid',
  anonKey: 'anon',
  catalogEndpoint: 'https://exemple.invalid/functions/v1/admin-catalog',
  adminToken: adminToken,
  retryDelays: const <Duration>[Duration.zero, Duration.zero],
);

Store _store() => Store(
  gamesSeed: '[]',
  contentsSeed: '[]',
  suggestionsSeed: '[]',
  bannedSeed: '[]',
  plusSeed: '[]',
);

/// Store dont le curseur des contenus est récent : synchro incrémentale,
/// donc relecture du journal cache_ops (route admin) — les « paires » du
/// journal.
/// Curseur `contents` de moins de 24 h ET cache des contenus marqué complet
/// (incident du 14/10 : sans ce marqueur, le démarrage refait une synchro
/// complète au lieu de l'incrémental voulu ici).
Store _storeWithContentsCursor() {
  final Store store = _store();
  store.saveCursor(
    'contents',
    '2026-10-12T00:00:00.000Z',
    DateTime.now().toUtc(),
  );
  store.markContentsComplete();
  return store;
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

http.Response _unauthorized(http.Request req) => _isCatalog(req)
    ? jsonResponse(<String, Object?>{'error': 'Non autorisé.'}, 401)
    : _neutral(req);

void main() {
  setUp(() {
    browserLocalStorage.clear();
    _seen.clear();
    _respond = _neutral;
    _gate = null;
    _gated = _isPostgrest;
    StoreController.resetRemoteAliasesTriedForTest();
  });

  group('SupabaseSync : aucun appel admin-catalog sans jeton utilisable', () {
    final Map<String, String> sansJeton = <String, String>{
      'vide': '',
      'illisible': 'jeton',
      'expiré': testJwt(validFor: const Duration(minutes: -1)),
    };
    for (final MapEntry<String, String> cas in sansJeton.entries) {
      test(
        'jeton ${cas.key} : lecture et écriture refusées sans requête',
        () async {
          final SupabaseSync s = _sync(cas.value);
          await _run(() async {
            await expectLater(
              s.fetchSuggestions(),
              throwsA(isA<AdminAuthException>()),
            );
            await expectLater(
              s.deleteGame('g1'),
              throwsA(isA<AdminAuthException>()),
            );
          });
          expect(_seen, isEmpty);
        },
      );
    }

    test('jeton utilisable : la requête part avec X-Admin-Token', () async {
      final String jeton = testJwt();
      await _run(() => _sync(jeton).fetchSuggestions());
      expect(_seen, hasLength(1));
      expect(isRoute(_seen.single, 'suggestions/list'), isTrue);
      expect(_seen.single.headers['X-Admin-Token'], jeton);
    });

    test(
      'rejeu après un 5xx : jeton vidé entre-temps → pas de 2e requête',
      () async {
        final SupabaseSync s = _sync(testJwt());
        _respond = (http.Request req) {
          s.setAdminToken(''); // fin de session pendant le délai de rejeu
          return jsonResponse(<String, Object?>{'error': 'Indisponible.'}, 502);
        };
        await _run(
          () => expectLater(
            s.fetchSuggestions(),
            throwsA(isA<AdminAuthException>()),
          ),
        );
        expect(_seen, hasLength(1));
      },
    );

    test('fresh_token d\'une requête envoyée avec un autre jeton (autre compte '
        'connecté entre-temps) : ignoré', () async {
      final String compteA = testJwt(validFor: const Duration(hours: 1));
      final String compteB = testJwt(validFor: const Duration(hours: 2));
      final String fresh = testJwt(validFor: const Duration(hours: 3));
      final SupabaseSync s = _sync(compteA);
      final List<String> refreshed = <String>[];
      s.onTokenRefreshed = refreshed.add;
      _respond = (http.Request req) =>
          jsonResponse(<String, Object?>{'fresh_token': fresh});
      _gated = _isCatalog;
      _gate = Completer<void>();
      await _run(() async {
        final Future<Object?> inFlight = s.fetchSuggestions();
        await _settle();
        s.setAdminToken(compteB); // le compte B se connecte dans l'onglet
        _gate!.complete();
        await inFlight;
      });
      expect(refreshed, isEmpty);
    });

    test('sans jeton, les lectures PostgREST (clé publique) partent', () async {
      await _run(() => _sync('').fetchGames());
      expect(_seen, hasLength(1));
      expect(_isCatalog(_seen.single), isFalse);
    });
  });

  group('Démarrage sur l\'écran de connexion (jeton vide)', () {
    test('aucun appel admin-catalog avant la connexion ; à la connexion : '
        'retraits, alias, tableau de bord', () async {
      int authErrors = 0;
      await _run(() async {
        final StoreController c = StoreController(
          _storeWithContentsCursor(),
          sync: _sync(''),
        );
        c.onAuthError = () => authErrors++;
        await _settle();
        expect(_catalogRoutes(), isEmpty);
        expect(_seen, isNotEmpty); // jeux et contenus : PostgREST
        expect(authErrors, 0); // pas de « Session expirée » à l'ouverture

        c.updateAdminToken(testJwt());
        await _settle();
        expect(
          _catalogRoutes().toSet(),
          containsAll(<String>[
            'cache-ops/list',
            'games/aliases/list-all',
            'suggestions/list',
            'profiles/banned-list',
          ]),
        );
        expect(authErrors, 0);
      });
    });

    test('passe du tableau de bord enchaînée qui démarre après une '
        'déconnexion : ni suggestions/list ni profiles/banned-list', () async {
      int authErrors = 0;
      final String jeton = testJwt();
      await _run(() async {
        // Synchro publique du démarrage retenue : la passe du tableau de bord
        // (connexion) s'enchaîne derrière elle.
        _gate = Completer<void>();
        final StoreController c = StoreController(_store(), sync: _sync(''));
        c.onAuthError = () => authErrors++;
        await _settle();
        c.updateAdminToken(jeton); // session restaurée
        await _settle();
        c.updateAdminToken(null); // déconnexion avant la fin de la synchro
        _gate!.complete();
        await _settle();
      });
      expect(_catalogRoutes(), isNot(contains('suggestions/list')));
      expect(_catalogRoutes(), isNot(contains('profiles/banned-list')));
      for (final http.Request r in _seen.where(_isCatalog)) {
        expect(r.headers['X-Admin-Token'], jeton); // jamais de jeton vide
      }
      expect(authErrors, 0); // déconnexion volontaire : pas de 2e message
    });

    test('session restaurée pendant la synchro du démarrage : la synchro '
        'partie sans jeton ne la ferme pas', () async {
      final SupabaseSync sync = _sync('');
      final String jeton = testJwt();
      int authErrors = 0;
      await _run(() async {
        // Les jeux traînent ; les contenus (incrémental) reviennent avant la
        // 1re image, qui pousse le jeton restauré.
        _gated = _isGamesRead;
        _gate = Completer<void>();
        final StoreController c = StoreController(
          _storeWithContentsCursor(),
          sync: sync,
        );
        c.onAuthError = () => authErrors++;
        await _settle();
        c.updateAdminToken(jeton);
        await _settle();
        _gate!.complete();
        await _settle();
      });
      expect(authErrors, 0);
      expect(sync.adminToken, jeton);
      expect(_catalogRoutes(), contains('cache-ops/list')); // après connexion
    });

    test('passe partie sans jeton puis connexion avant sa fin : la nouvelle '
        'session reste ouverte', () async {
      final SupabaseSync sync = _sync('');
      final String jeton = testJwt();
      int authErrors = 0;
      await _run(() async {
        final StoreController c = StoreController(_store(), sync: sync);
        c.onAuthError = () => authErrors++;
        await _settle();
        _gated = _isGamesRead;
        _gate = Completer<void>();
        final Future<void> pass = c.syncFromSupabase(
          datasets: const <SyncDataset>{
            SyncDataset.games,
            SyncDataset.suggestionsNew,
          },
        );
        await _settle();
        c.updateAdminToken(jeton); // connexion pendant la passe
        await _settle();
        _gate!.complete();
        await pass;
        await _settle();
      });
      expect(authErrors, 0);
      expect(sync.adminToken, jeton);
    });

    test('refus d\'une passe partie avec l\'ancienne session, reçu après une '
        'reconnexion : la nouvelle session reste ouverte', () async {
      final String ancien = testJwt(validFor: const Duration(hours: 1));
      final String nouveau = testJwt(validFor: const Duration(hours: 2));
      final SupabaseSync sync = _sync('');
      int authErrors = 0;
      await _run(() async {
        final StoreController c = StoreController(_store(), sync: sync);
        c.onAuthError = () => authErrors++;
        await _settle();
        c.updateAdminToken(ancien);
        await _settle();
        // L'ancienne session est refusée par le serveur ; ses réponses
        // arrivent après la reconnexion.
        _respond = (http.Request req) =>
            _isCatalog(req) && req.headers['X-Admin-Token'] == ancien
            ? jsonResponse(<String, Object?>{'error': 'Non autorisé.'}, 401)
            : _neutral(req);
        _gated = _isCatalog;
        _gate = Completer<void>();
        final Future<void> pass = c.syncFromSupabase(
          datasets: const <SyncDataset>{SyncDataset.suggestionsNew},
        );
        await _settle();
        c.updateAdminToken(null); // déconnexion
        c.updateAdminToken(nouveau); // reconnexion avant la fin de la passe
        await _settle();
        _gate!.complete();
        await pass;
        await _settle();
      });
      expect(authErrors, 0);
      expect(sync.adminToken, nouveau);
    });
  });

  group(
    'Un 401 arrête les rafraîchissements et ne déconnecte qu\'une fois',
    () {
      testWidgets('polling « Analyses en cours » : 401 → arrêt, jeton oublié, '
          'une seule déconnexion', (WidgetTester tester) async {
        final SupabaseSync sync = _sync(testJwt());
        late StoreController c;
        await tester.runAsync(() async {
          await _run(() async {
            c = StoreController(_store(), sync: sync);
            await _settle();
          });
        });
        _seen.clear();
        _respond = _unauthorized;
        int authErrors = 0;
        c.onAuthError = () => authErrors++;
        _run(c.startAnalyzingPolling);

        await tester.pump(const Duration(seconds: 31));
        await tester.pump();
        final int afterFirstTick = _catalogRoutes().length;
        expect(afterFirstTick, greaterThan(0));
        expect(_catalogRoutes().toSet(), <String>{'suggestions/list'});
        expect(authErrors, 1);
        expect(sync.adminToken, isEmpty);

        // Onglet resté ouvert : plus aucune requête, plus aucun message (et,
        // contrôle de fin de testWidgets, plus aucune minuterie en attente).
        await tester.pump(const Duration(minutes: 45));
        await tester.pump();
        expect(_catalogRoutes(), hasLength(afterFirstTick));
        expect(authErrors, 1);
      });

      testWidgets('jeton expiré dans un onglet masqué : aucune requête, '
          'polling arrêté, une seule déconnexion', (WidgetTester tester) async {
        final SupabaseSync sync = _sync(testJwt());
        late StoreController c;
        await tester.runAsync(() async {
          await _run(() async {
            c = StoreController(_store(), sync: sync);
            await _settle();
          });
        });
        _seen.clear();
        int authErrors = 0;
        c.onAuthError = () => authErrors++;
        _run(c.startAnalyzingPolling);
        // L'échéance passe sans image (onglet masqué) : le contrôleur garde
        // l'ancien jeton, désormais expiré.
        sync.setAdminToken(testJwt(validFor: const Duration(minutes: -1)));

        await tester.pump(const Duration(seconds: 31));
        await tester.pump();
        expect(authErrors, 1);
        expect(sync.adminToken, isEmpty);
        await tester.pump(const Duration(minutes: 45));
        await tester.pump();
        expect(_seen, isEmpty);
        expect(authErrors, 1);
      });

      test('plusieurs refus : une seule requête, un seul message ; un nouveau '
          'jeton réarme', () async {
        final SupabaseSync sync = _sync(testJwt());
        int authErrors = 0;
        await _run(() async {
          final StoreController c = StoreController(_store(), sync: sync);
          await _settle();
          _seen.clear();
          _respond = _unauthorized;
          c.onAuthError = () => authErrors++;

          await c.reloadBannedList(reportErrors: false);
          await c.reloadBannedList(reportErrors: false);
          c.onAuthError?.call(); // un écran qui reçoit lui aussi un 401
          expect(_catalogRoutes(), <String>['profiles/banned-list']);
          expect(authErrors, 1);

          _respond = _neutral;
          c.updateAdminToken(testJwt()); // nouvelle connexion
          await _settle();
          expect(authErrors, 1);
          c.onAuthError?.call();
          c.onAuthError?.call();
          expect(authErrors, 2);
        });
      });

      test('fresh_token d\'une réponse encore en vol après la fin de session : '
          'ignoré', () async {
        final SupabaseSync sync = _sync(testJwt());
        final List<String> refreshed = <String>[];
        final String fresh = testJwt(validFor: const Duration(hours: 3));
        await _run(() async {
          final StoreController c = StoreController(_store(), sync: sync);
          await _settle();
          c.onTokenRefreshed = refreshed.add;
          _respond = (http.Request req) => _isCatalog(req)
              ? jsonResponse(<String, Object?>{'fresh_token': fresh})
              : _neutral(req);
          await sync.fetchSuggestions(); // session active : transmis
          expect(refreshed, <String>[fresh]);

          _gated = _isCatalog;
          _gate = Completer<void>();
          final Future<Object?> inFlight = sync.fetchSuggestions();
          await _settle();
          c.onAuthError?.call(); // 401 reçu par un autre appel
          _gate!.complete();
          await inFlight;
        });
        expect(refreshed, <String>[fresh]);
      });
    },
  );
}
