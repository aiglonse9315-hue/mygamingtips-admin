// Tests purs (VM) de l'exception typée AdminApiException et du `_post`
// TOLÉRANT de SupabaseSync (P4b-3, lot L2, T1 / T2) : statut et corps
// d'erreur conservés, 401 / 403 inchangés, rejeux d'un 5xx (délais nuls),
// réponse 2xx illisible, rotation du fresh_token, nombre de tentatives
// (rejeu visible), échecs à issue inconnue, texte d'erreur sans
// « Exception: ». Client HTTP simulé ; aucune dépendance dart:html.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/moderation.dart';

import 'support/http_fixtures.dart';

const String _uuid = '0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60';

void main() {
  group('Statuts d\'erreur → exceptions typées', () {
    test('409 auto_ban_use_review : statut, result, ban_event_id, message '
        'sans « Exception: »', () async {
      final List<http.Request> seen = <http.Request>[];
      const String msg =
          'Bannissement automatique : levée par le compte principal '
          'depuis la modération (ban_event_id fourni).';
      final Object? err = await withMock<Object?>(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'error': msg,
          'result': 'auto_ban_use_review',
          'ban_event_id': 42,
        }, 409),
        () async {
          try {
            await fakeSync().unbanUser(_uuid);
            return null;
          } catch (e) {
            return e;
          }
        },
      );
      expect(err, isA<AdminApiException>());
      final AdminApiException e = err! as AdminApiException;
      expect(e.statusCode, 409);
      expect(e.isConflict, isTrue);
      expect(e.result, 'auto_ban_use_review');
      expect(e.banEventId, 42);
      expect(e.message, msg);
      expect(e.toString(), msg);
      expect(e.toString().startsWith('Exception'), isFalse);
      expect(errorText(e), msg);
      expect(seen, hasLength(1)); // un 4xx n'est jamais rejoué
    });

    test('409 below_threshold : distinct_contents et threshold', () async {
      final List<http.Request> seen = <http.Request>[];
      await expectLater(
        withMock<ReviewDecideResult>(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error':
                'Seuil non atteint : moins de 2 contenus distincts de '
                'cette chaîne sur 90 jours.',
            'result': 'below_threshold',
            'distinct_contents': 1,
            'threshold': 2,
          }, 409),
          () => fakeSync().reviewDecide(9, ReviewDecision.apply),
        ),
        throwsA(
          isA<AdminApiException>()
              .having((e) => e.result, 'result', 'below_threshold')
              .having((e) => e.distinctContents, 'distinctContents', 1)
              .having((e) => e.threshold, 'threshold', 2),
        ),
      );
    });

    test('400 settings-set avec reasons → liste décodée', () async {
      final List<http.Request> seen = <http.Request>[];
      await expectLater(
        withMock<ModerationSettings>(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error': 'Réglages invalides.',
            'reasons': <Object?>['max_auto_bans_per_hour', 3, null],
          }, 400),
          () => fakeSync().updateModerationSettings(maxPerHour: 5),
        ),
        throwsA(
          isA<AdminApiException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.reasons, 'reasons', <String>[
                'max_auto_bans_per_hour',
              ])
              .having((e) => e.result, 'result', isNull),
        ),
      );
    });

    test('404 → isNotFound', () async {
      final List<http.Request> seen = <http.Request>[];
      await expectLater(
        withMock<ReviewDetail>(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error': 'Événement introuvable.',
          }, 404),
          () => fakeSync().fetchReviewDetail(5),
        ),
        throwsA(
          isA<AdminApiException>()
              .having((e) => e.isNotFound, 'isNotFound', isTrue)
              .having((e) => e.message, 'message', 'Événement introuvable.'),
        ),
      );
    });

    test('400 sans texte d\'erreur → « Erreur serveur (HTTP 400). »', () async {
      final List<http.Request> seen = <http.Request>[];
      await expectLater(
        withMock<Object>(
          seen,
          (_) => jsonResponse(<String, dynamic>{'error': '  '}, 400),
          () => fakeSync().fetchBanCategories(),
        ),
        throwsA(
          isA<AdminApiException>().having(
            (e) => e.message,
            'message',
            'Erreur serveur (HTTP 400).',
          ),
        ),
      );
    });

    test('401 → AdminAuthException (inchangée)', () async {
      final List<http.Request> seen = <http.Request>[];
      await expectLater(
        withMock<Object>(
          seen,
          (_) => jsonResponse(<String, dynamic>{'error': 'Non autorisé.'}, 401),
          () => fakeSync().fetchBanCategories(),
        ),
        throwsA(
          isA<AdminAuthException>().having(
            (e) => e.message,
            'message',
            'Non autorisé.',
          ),
        ),
      );
    });

    test(
      '401 corps non JSON → AdminAuthException « Session expirée »',
      () async {
        final List<http.Request> seen = <http.Request>[];
        await expectLater(
          withMock<Object>(
            seen,
            (_) => http.Response('<html></html>', 401),
            () => fakeSync().fetchBanCategories(),
          ),
          throwsA(
            isA<AdminAuthException>().having(
              (e) => e.message,
              'message',
              'Session expirée',
            ),
          ),
        );
      },
    );

    test('403 → AdminForbiddenException', () async {
      final List<http.Request> seen = <http.Request>[];
      await expectLater(
        withMock<Object>(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error': 'Accès réservé au compte principal.',
          }, 403),
          () => fakeSync().fetchReviewList(),
        ),
        throwsA(
          isA<AdminForbiddenException>().having(
            (e) => e.message,
            'message',
            'Accès réservé au compte principal.',
          ),
        ),
      );
    });

    test('502 corps HTML → 3 tentatives puis AdminApiException(502)', () async {
      final List<http.Request> seen = <http.Request>[];
      Object? err;
      try {
        await withMock<Object>(
          seen,
          (_) => http.Response('<html>Bad Gateway</html>', 502),
          () => fakeSync().fetchBanCategories(),
        );
      } catch (e) {
        err = e;
      }
      expect(seen, hasLength(3));
      expect(err, isA<AdminApiException>());
      final AdminApiException e = err! as AdminApiException;
      expect(e.statusCode, 502);
      expect(e.message, 'Erreur serveur (HTTP 502).');
      expect(e.body, isEmpty);
      expect(e.isServerError, isTrue);
      expect(isUncertainFailure(e), isTrue);
    });
  });

  group('Réponse 2xx illisible', () {
    test('200 corps non JSON → AdminApiException, issue inconnue', () async {
      final List<http.Request> seen = <http.Request>[];
      Object? err;
      try {
        await withMock<Object>(
          seen,
          (_) => http.Response('pas du json', 200),
          () => fakeSync().fetchBanCategories(),
        );
      } catch (e) {
        err = e;
      }
      expect(err, isA<AdminApiException>());
      expect((err! as AdminApiException).statusCode, 200);
      expect(
        (err as AdminApiException).message,
        'Réponse illisible du serveur (HTTP 200).',
      );
      expect(isUncertainFailure(err), isTrue);
      expect(seen, hasLength(1));
    });

    test('200 tableau JSON → AdminApiException, issue inconnue', () async {
      final List<http.Request> seen = <http.Request>[];
      Object? err;
      try {
        await withMock<Object>(
          seen,
          (_) => jsonResponse(<Object?>[1, 2]),
          () => fakeSync().fetchBanCategories(),
        );
      } catch (e) {
        err = e;
      }
      expect(err, isA<AdminApiException>());
      expect(isUncertainFailure(err!), isTrue);
    });
  });

  group('fresh_token (sliding session)', () {
    test('retiré des données et transmis à onTokenRefreshed', () async {
      final List<http.Request> seen = <http.Request>[];
      final SupabaseSync s = fakeSync();
      final List<String> refreshed = <String>[];
      s.onTokenRefreshed = refreshed.add;
      final String fresh = testJwt();
      final Map<String, dynamic> data = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'ok': <Object?>[],
          'fresh_token': fresh,
        }),
        () => s.acceptSuggestionsBatch(const <Map<String, dynamic>>[]),
      );
      expect(data.containsKey('fresh_token'), isFalse);
      expect(refreshed, <String>[fresh]);
    });

    // Revue P4b-3 (SEC-P4b3-07) : 3 segments ne suffisent plus — payload
    // illisible, sans `exp`, `exp` non numérique ou passé → non transmis.
    for (final String bad in <String>[
      'aaa.bbb',
      '',
      'aaa..ccc',
      'a.b.c.d',
      'a.b.c',
      testJwt(payload: <String, Object?>{'username': 'test'}),
      testJwt(payload: <String, Object?>{'exp': 'demain'}),
      testJwt(validFor: const Duration(minutes: -1)),
    ]) {
      test('fresh_token « $bad » : retiré mais NON transmis', () async {
        final List<http.Request> seen = <http.Request>[];
        final SupabaseSync s = fakeSync();
        final List<String> refreshed = <String>[];
        s.onTokenRefreshed = refreshed.add;
        final Map<String, dynamic> data = await withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'ok': <Object?>[],
            'fresh_token': bad,
          }),
          () => s.acceptSuggestionsBatch(const <Map<String, dynamic>>[]),
        );
        expect(data.containsKey('fresh_token'), isFalse);
        expect(refreshed, isEmpty);
      });
    }

    test('fresh_token non texte : retiré, non transmis', () async {
      final List<http.Request> seen = <http.Request>[];
      final SupabaseSync s = fakeSync();
      final List<String> refreshed = <String>[];
      s.onTokenRefreshed = refreshed.add;
      final Map<String, dynamic> data = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'ok': 1, 'fresh_token': 12}),
        () => s.acceptSuggestionsBatch(const <Map<String, dynamic>>[]),
      );
      expect(data.containsKey('fresh_token'), isFalse);
      expect(refreshed, isEmpty);
    });
  });

  group('Lecture tolérante du corps d\'erreur', () {
    test('reasons objet ou texte → [] sans exception', () {
      const AdminApiException a = AdminApiException(
        400,
        'x',
        body: <String, dynamic>{
          'reasons': <String, dynamic>{'a': 1},
        },
      );
      const AdminApiException b = AdminApiException(
        400,
        'x',
        body: <String, dynamic>{'reasons': 'texte'},
      );
      expect(a.reasons, isEmpty);
      expect(b.reasons, isEmpty);
    });

    test('champs numériques en double ou de mauvais type', () {
      const AdminApiException e = AdminApiException(
        409,
        'x',
        body: <String, dynamic>{
          'ban_event_id': 42.0,
          'distinct_contents': '1',
          'threshold': null,
          'result': 7,
        },
      );
      expect(e.banEventId, 42);
      expect(e.distinctContents, isNull);
      expect(e.threshold, isNull);
      expect(e.result, isNull);
    });
  });

  group('Nombre de tentatives (rejeu visible)', () {
    test('502 puis 200 → 2 tentatives → replayed', () async {
      final List<http.Request> seen = <http.Request>[];
      int n = 0;
      final EvidencePurgeResult r = await withMock(
        seen,
        (_) => (n++ == 0)
            ? http.Response('<html></html>', 502)
            : jsonResponse(<String, dynamic>{'result': 'purged', 'count': 3}),
        () => fakeSync().purgeEvidence(olderThanDays: 180, apply: true),
      );
      expect(seen, hasLength(2));
      expect(r.replayed, isTrue);
      expect(r.count, 3);
    });

    test('200 direct → 1 tentative → pas de rejeu', () async {
      final List<http.Request> seen = <http.Request>[];
      final EvidencePurgeResult r = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'result': 'preview', 'count': 0}),
        () => fakeSync().purgeEvidence(olderThanDays: 180, apply: false),
      );
      expect(seen, hasLength(1));
      expect(r.replayed, isFalse);
    });

    test('ClientException à chaque tentative → relancée (3 essais)', () async {
      final List<http.Request> seen = <http.Request>[];
      await expectLater(
        withMock<Object>(
          seen,
          (_) => throw http.ClientException('coupure'),
          () => fakeSync().fetchBanCategories(),
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(seen, hasLength(3));
    });
  });

  group('isUncertainFailure / errorText', () {
    test('coupure, délai, 5xx, 2xx illisible → vrai', () {
      expect(isUncertainFailure(http.ClientException('x')), isTrue);
      expect(isUncertainFailure(TimeoutException('x')), isTrue);
      expect(isUncertainFailure(const AdminApiException(500, 'x')), isTrue);
      expect(isUncertainFailure(const AdminApiException(503, 'x')), isTrue);
      expect(isUncertainFailure(const AdminApiException(200, 'x')), isTrue);
    });

    test('4xx, 401, 403, autre → faux', () {
      for (final int s in <int>[400, 404, 409]) {
        expect(isUncertainFailure(AdminApiException(s, 'x')), isFalse);
      }
      expect(isUncertainFailure(const AdminAuthException('x')), isFalse);
      expect(isUncertainFailure(const AdminForbiddenException('x')), isFalse);
      expect(isUncertainFailure(Exception('x')), isFalse);
      expect(isUncertainFailure(StateError('x')), isFalse);
    });

    test('errorText retire « Exception: »', () {
      expect(errorText(Exception('x')), 'x');
      expect(
        errorText(const AdminApiException(409, 'Déjà fait.')),
        'Déjà fait.',
      );
      expect(
        errorText(const AdminAuthException('Session expirée')),
        'Session expirée',
      );
    });
  });
}
