// Tests purs (VM) des méthodes du JOURNAL de SupabaseSync (P4d L3) :
// `logs/list` (corps exact, clé `masquer` seulement si demandée, colonnes
// v2, `masquees` / `filtre_applique`, serveur d'avant L2, liste absente →
// réponse illisible), `logs/attempts` (corps, lecture, liste absente),
// archives (liste, téléchargement d'une archive d'avant 0098 à 5 colonnes
// et d'une archive v2 à 9 colonnes), 403 / 401. Client HTTP
// simulé ; adresses réservées ; données neutres ; aucune dépendance
// dart:html.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/log_entry.dart';
import 'package:mgt_admin/domain/models/security_attempt.dart';

import 'support/http_fixtures.dart';

Map<String, dynamic> _log({
  String type = 'auth',
  Map<String, dynamic> extra = const <String, dynamic>{},
}) => <String, dynamic>{
  'type': type,
  'at': '2026-10-14T08:00:00+00:00',
  'username': 'compte-exemple',
  'action': type == 'auth' ? 'connexion réussie' : 'games/upsert',
  'detail': 'détail neutre',
  ...extra,
};

Map<String, dynamic> _attempt({int occurrences = 1}) => <String, dynamic>{
  'at': '2026-10-14T07:00:00+00:00',
  'last_at': '2026-10-14T07:03:00+00:00',
  'occurrences': occurrences,
  'genre': 'code_brut',
  'libelle': 'Libellé du serveur',
  'route': 'admin-login',
  'username': 'login-tape',
  'ip': '198.51.100.4',
  'ua': 'Agent/2.0',
  'detail': null,
};

void main() {
  late List<http.Request> seen;
  setUp(() => seen = <http.Request>[]);

  group('logs/list', () {
    test('bascule éteinte : corps d\'avant L3 (aucune clé masquer) ; '
        'colonnes v2 lues', () async {
      final LogPage p = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'logs': <Object?>[
            _log(
              extra: <String, dynamic>{
                'success': true,
                'ip': '203.0.113.7',
                'ua': 'Navigateur/1.0',
                'sid': '0123456789abcdef0123456789abcdef',
              },
            ),
            _log(
              type: 'action',
              extra: <String, dynamic>{
                'success': null,
                'ip': null,
                'ua': null,
                'sid': null,
              },
            ),
          ],
          'total': 2,
          'masquees': 0,
          'filtre_applique': false,
          'fresh_token': 'a.b.c',
        }),
        () => fakeSync().fetchLogs(page: 2, pageSize: 100, source: 'auth'),
      );
      expect(isRoute(seen.single, 'logs/list'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{
        'page': 2,
        'pageSize': 100,
        'source': 'auth',
      });
      expect(p.items.length, 2);
      expect(p.items.first.success, isTrue);
      expect(p.items.first.ip, '203.0.113.7');
      expect(p.items.first.ua, 'Navigateur/1.0');
      expect(p.items.first.sid, '0123456789abcdef0123456789abcdef');
      expect(p.items.last.success, isNull);
      expect(p.items.last.sid, isNull);
      expect(p.total, 2);
      expect(p.masquees, 0);
      expect(p.filtreApplique, isFalse);
    });

    test('bascule allumée : masquer: true ; masquees et filtre_applique '
        'lus', () async {
      final LogPage p = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'logs': <Object?>[_log()],
          'total': 1,
          'masquees': 41,
          'filtre_applique': true,
        }),
        () => fakeSync().fetchLogs(masquer: true),
      );
      expect(bodyOf(seen.single), <String, dynamic>{
        'page': 0,
        'pageSize': 100,
        'source': 'all',
        'masquer': true,
      });
      expect(p.total, 1);
      expect(p.masquees, 41);
      expect(p.filtreApplique, isTrue);
    });

    test('filtre en échec côté serveur (filtre_applique: false) : tout est '
        'rendu, l\'écho est conservé', () async {
      final LogPage p = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'logs': <Object?>[_log(), _log()],
          'total': 2,
          'masquees': 0,
          'filtre_applique': false,
        }),
        () => fakeSync().fetchLogs(masquer: true),
      );
      expect(p.items.length, 2);
      expect(p.filtreApplique, isFalse);
    });

    test('serveur d\'avant L2 (ni masquees ni filtre_applique) : 0 et '
        'faux', () async {
      final LogPage p = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'logs': <Object?>[_log()],
          'total': 1,
        }),
        () => fakeSync().fetchLogs(masquer: true),
      );
      expect(p.masquees, 0);
      expect(p.filtreApplique, isFalse);
      expect(p.items.single.ip, isNull);
    });

    test('pageSize borné à 1-500', () async {
      Future<void> call(int size) => withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'logs': <Object?>[], 'total': 0}),
        () => fakeSync().fetchLogs(pageSize: size),
      );
      await call(5000);
      await call(0);
      expect((bodyOf(seen[0])! as Map<String, dynamic>)['pageSize'], 500);
      expect((bodyOf(seen[1])! as Map<String, dynamic>)['pageSize'], 1);
    });

    test('liste logs absente ou non liste → réponse illisible (jamais un '
        'journal vide)', () async {
      for (final Object? logs in <Object?>[null, 'x', <String, dynamic>{}]) {
        await expectLater(
          withMock(
            seen,
            (_) => jsonResponse(<String, dynamic>{'logs': logs, 'total': 0}),
            () => fakeSync().fetchLogs(),
          ),
          throwsA(
            isA<AdminApiException>().having(
              (AdminApiException e) => e.message,
              'message',
              'Réponse illisible du serveur.',
            ),
          ),
        );
      }
    });

    test('403 → AdminForbiddenException ; 401 → AdminAuthException', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(
            <String, dynamic>{'error': 'Accès réservé.'},
            403,
          ),
          () => fakeSync().fetchLogs(masquer: true),
        ),
        throwsA(isA<AdminForbiddenException>()),
      );
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{'error': 'Non autorisé.'}, 401),
          () => fakeSync().fetchLogs(),
        ),
        throwsA(isA<AdminAuthException>()),
      );
    });
  });

  group('logs/attempts', () {
    test('route, corps {page, pageSize}, lecture', () async {
      final SecurityAttemptPage p = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'tentatives': <Object?>[_attempt(occurrences: 3), _attempt()],
          'total': 230,
          'fresh_token': 'a.b.c',
        }),
        () => fakeSync().fetchSecurityAttempts(page: 1, pageSize: 100),
      );
      expect(isRoute(seen.single, 'logs/attempts'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{
        'page': 1,
        'pageSize': 100,
      });
      expect(p.total, 230);
      expect(p.items.length, 2);
      expect(p.items.first.occurrences, 3);
      expect(p.items.first.libelle, 'Libellé du serveur');
      expect(p.items.first.lastAt, DateTime.utc(2026, 10, 14, 7, 3));
      expect(p.items.last.detail, isNull);
    });

    test('pageSize borné à 500 ; tentatives absente → réponse '
        'illisible', () async {
      await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'tentatives': <Object?>[],
          'total': 0,
        }),
        () => fakeSync().fetchSecurityAttempts(pageSize: 9999),
      );
      expect(bodyOf(seen.single), <String, dynamic>{
        'page': 0,
        'pageSize': 500,
      });
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{'total': 0}),
          () => fakeSync().fetchSecurityAttempts(),
        ),
        throwsA(isA<AdminApiException>()),
      );
    });

    test('403 → AdminForbiddenException ; 401 → AdminAuthException ; '
        '500 rejoué puis AdminApiException', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(
            <String, dynamic>{'error': 'Accès réservé.'},
            403,
          ),
          () => fakeSync().fetchSecurityAttempts(),
        ),
        throwsA(isA<AdminForbiddenException>()),
      );
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{'error': 'Non autorisé.'}, 401),
          () => fakeSync().fetchSecurityAttempts(),
        ),
        throwsA(isA<AdminAuthException>()),
      );
      seen.clear();
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(
            <String, dynamic>{'error': 'Lecture des tentatives indisponible.'},
            500,
          ),
          () => fakeSync().fetchSecurityAttempts(),
        ),
        throwsA(
          isA<AdminApiException>().having(
            (AdminApiException e) => e.message,
            'message',
            'Lecture des tentatives indisponible.',
          ),
        ),
      );
      expect(seen.length, 3); // 1 essai + 2 rejeux
    });
  });

  group('Archives', () {
    test('liste et téléchargement d\'une archive d\'avant 0098 (5 colonnes : '
        'v2 à null)', () async {
      final List<Map<String, dynamic>> archives = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'archives': <Object?>[
            <String, dynamic>{
              'table_name': 'archive_exemple',
              'period_label': 'Septembre 2026',
              'rows_count': 12,
              'created_at': '2026-10-01T04:37:00+00:00',
            },
          ],
        }),
        () => fakeSync().fetchLogArchives(),
      );
      expect(isRoute(seen.single, 'logs/archives/list'), isTrue);
      expect(archives.single['period_label'], 'Septembre 2026');

      seen.clear();
      final List<LogEntry> logs = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'logs': <Object?>[_log(), _log(type: 'action')],
        }),
        () => fakeSync().downloadLogArchive('archive_exemple'),
      );
      expect(isRoute(seen.single, 'logs/archive/download'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{
        'table': 'archive_exemple',
      });
      expect(logs.length, 2);
      expect(logs.first.success, isNull);
      expect(logs.first.ip, isNull);
    });

    test('téléchargement d\'une archive v2 (9 colonnes) : colonnes v2 lues, '
        'mêlées sans erreur à des lignes sans v2', () async {
      final List<LogEntry> logs = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'logs': <Object?>[
            _log(
              extra: <String, dynamic>{
                'success': false,
                'ip': '203.0.113.7',
                'ua': 'Navigateur/1.0',
                'sid': '0123456789abcdef0123456789abcdef',
              },
            ),
            _log(type: 'action'),
          ],
        }),
        () => fakeSync().downloadLogArchive('archive_exemple'),
      );
      expect(isRoute(seen.single, 'logs/archive/download'), isTrue);
      expect(logs.length, 2);
      expect(logs.first.success, isFalse);
      expect(logs.first.ip, '203.0.113.7');
      expect(logs.first.ua, 'Navigateur/1.0');
      expect(logs.first.sid, '0123456789abcdef0123456789abcdef');
      expect(logs.last.success, isNull);
      expect(logs.last.sid, isNull);
    });
  });
}
