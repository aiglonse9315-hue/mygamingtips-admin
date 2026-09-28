// Tests purs (VM) des méthodes JEUX de SupabaseSync (P4b-3, lot L2) :
// envoi PARTIEL d'un jeu existant (clé présente = écrite, null = effacement),
// 404, liste complète actifs / inactifs (corps strict, pagination), aperçu
// et application de « Activer les jeux prêts ». Client HTTP simulé ;
// aucune dépendance dart:html.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/game.dart';
import 'package:mgt_admin/domain/models/ready_games.dart';

import 'support/http_fixtures.dart';

const String _a = '0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60';
const String _b = '1c8d7f2b-3e4f-4d6c-9b0f-2e3d4c5b6a71';

Map<String, dynamic> _gameRow(String id, {bool active = true}) =>
    <String, dynamic>{
      'id': id,
      'name': 'Jeu $id',
      'publisher': 'Éditeur',
      'cover_url': null,
      'active': active,
      'release_date': '2023-11-10',
      'created_at': '2026-01-01T00:00:00+00:00',
      'updated_at': '2026-09-28T00:00:00+00:00',
    };

void main() {
  late List<http.Request> seen;
  setUp(() => seen = <http.Request>[]);

  group('patchGame (envoi partiel)', () {
    test(
      '{active: false} → corps EXACT {id, active: false} (2 clés)',
      () async {
        final Game g = await withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'game': _gameRow(_a, active: false),
            'created': false,
          }),
          () => fakeSync().patchGame(_a, <String, Object?>{'active': false}),
        );
        expect(isRoute(seen.single, 'games'), isTrue);
        expect(bodyOf(seen.single), <String, dynamic>{
          'id': _a,
          'active': false,
        });
        expect(g.id, _a);
        expect(g.active, isFalse);
        expect(g.releaseDate, '2023-11-10');
      },
    );

    test('{release_date: null} → clé PRÉSENTE à null', () async {
      await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'game': _gameRow(_a)}),
        () => fakeSync().patchGame(_a, <String, Object?>{'release_date': null}),
      );
      final Map<String, dynamic> body =
          bodyOf(seen.single)! as Map<String, dynamic>;
      expect(body.containsKey('release_date'), isTrue);
      expect(body['release_date'], isNull);
      expect(body.keys.toSet(), <String>{'id', 'release_date'});
    });

    test('plusieurs champs → clés snake_case telles quelles', () async {
      await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'game': _gameRow(_a)}),
        () => fakeSync().patchGame(_a, <String, Object?>{
          'name': 'Nom',
          'publisher': null,
          'cover_url': 'https://exemple.test/c.png',
        }),
      );
      expect(bodyOf(seen.single), <String, dynamic>{
        'id': _a,
        'name': 'Nom',
        'publisher': null,
        'cover_url': 'https://exemple.test/c.png',
      });
    });

    test('404 « Jeu introuvable. » → isNotFound', () async {
      await expectLater(
        withMock(
          seen,
          (_) =>
              jsonResponse(<String, dynamic>{'error': 'Jeu introuvable.'}, 404),
          () => fakeSync().patchGame(_a, <String, Object?>{'active': true}),
        ),
        throwsA(
          isA<AdminApiException>()
              .having((e) => e.isNotFound, 'isNotFound', isTrue)
              .having((e) => e.message, 'message', 'Jeu introuvable.'),
        ),
      );
    });

    test('réponse sans game → illisible', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{'created': false}),
          () => fakeSync().patchGame(_a, <String, Object?>{'active': true}),
        ),
        throwsA(isA<AdminApiException>()),
      );
    });
  });

  group('games/list', () {
    test('fetchGamesList(active: false) → {page: 0, pageSize: 500, '
        'active: false}', () async {
      final ({List<Game> games, int total}) r = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'games': <Object?>[
            _gameRow(_a, active: false),
            <String, dynamic>{'id': 3, 'name': 'id non texte'},
          ],
          'total': 1,
          'page': 0,
          'pageSize': 500,
        }),
        () => fakeSync().fetchGamesList(active: false),
      );
      expect(isRoute(seen.single, 'games/list'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{
        'page': 0,
        'pageSize': 500,
        'active': false,
      });
      expect(r.total, 1);
      expect(r.games.single.id, _a);
      expect(r.games.single.active, isFalse);
      expect(r.games.single.publisher, 'Éditeur');
    });

    test('fetchGamesList sans active → 2 clés', () async {
      await withMock(
        seen,
        (_) =>
            jsonResponse(<String, dynamic>{'games': <Object?>[], 'total': 0}),
        () => fakeSync().fetchGamesList(),
      );
      expect(bodyOf(seen.single), <String, dynamic>{
        'page': 0,
        'pageSize': 500,
      });
    });

    test('fetchGamesList : games absent → illisible', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{'total': 0}),
          () => fakeSync().fetchGamesList(),
        ),
        throwsA(isA<AdminApiException>()),
      );
    });

    test('fetchAllGames : 2 pages (total 700)', () async {
      final List<Game> all = await withMock(seen, (http.Request req) {
        final int p = (bodyOf(req)! as Map<String, dynamic>)['page'] as int;
        final int n = p == 0 ? 500 : 200;
        return jsonResponse(<String, dynamic>{
          'games': <Object?>[
            for (var i = 0; i < n; i++) _gameRow('g$p-$i', active: false),
          ],
          'total': 700,
        });
      }, () => fakeSync().fetchAllGames(active: false));
      expect(seen, hasLength(2));
      expect(bodyOf(seen.first), <String, dynamic>{
        'page': 0,
        'pageSize': 500,
        'active': false,
      });
      expect(bodyOf(seen.last), <String, dynamic>{
        'page': 1,
        'pageSize': 500,
        'active': false,
      });
      expect(all, hasLength(700));
    });
  });

  group('Activer les jeux prêts', () {
    test('previewReadyGames → {dry_run: true} et lecture', () async {
      final ReadyGamesPreview p = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'dry_run': true,
          'threshold': 10,
          'inactive_total': 3,
          'count': 1,
          'games': <Object?>[
            <String, dynamic>{
              'id': _a,
              'name': 'Jeu prêt',
              'validated_total': 12,
              'video': 6,
              'guides': 4,
              'links': 2,
              'distinct_urls': 11,
              'updated_at': '2026-09-28T00:00:00+00:00',
            },
          ],
        }),
        () => fakeSync().previewReadyGames(),
      );
      expect(isRoute(seen.single, 'games/activate-ready'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{'dry_run': true});
      expect(p.threshold, 10);
      expect(p.inactiveTotal, 3);
      expect(p.games.single.validatedTotal, 12);
      expect(p.games.single.hasDuplicateUrls, isTrue);
    });

    test('previewReadyGames 500 « Aperçu impossible » (sans point) → '
        'message du serveur', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error': 'Aperçu impossible',
          }, 500),
          () => fakeSync().previewReadyGames(),
        ),
        throwsA(
          isA<AdminApiException>().having(
            (e) => e.message.startsWith('Aperçu impossible'),
            'message',
            isTrue,
          ),
        ),
      );
    });

    test('activateReadyGames([a, b]) → {dry_run: false, ids: [a, b]} et '
        'lecture activated / skipped', () async {
      final ActivateReadyResult r = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'dry_run': false,
          'threshold': 10,
          'requested': 2,
          'activated': <Object?>[
            <String, dynamic>{'id': _a, 'name': 'Jeu A', 'validated_total': 12},
          ],
          'skipped': <Object?>[
            <String, dynamic>{'id': _b, 'reason': 'already_active'},
          ],
        }),
        () => fakeSync().activateReadyGames(<String>[_a, _b]),
      );
      expect(isRoute(seen.single, 'games/activate-ready'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{
        'dry_run': false,
        'ids': <String>[_a, _b],
      });
      expect(r.requested, 2);
      expect(r.activated.single.name, 'Jeu A');
      expect(r.skipped.single.reason, 'already_active');
      expect(r.replayed, isFalse);
    });

    test('activateReadyGames : réponse sans activated → illisible', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{'dry_run': false}),
          () => fakeSync().activateReadyGames(<String>[_a]),
        ),
        throwsA(isA<AdminApiException>()),
      );
    });
  });
}
