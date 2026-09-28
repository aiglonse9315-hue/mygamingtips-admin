// Tests purs (VM) des méthodes de BAN de SupabaseSync (P4b-3, lot L2) :
// ban / levée manuels de comptes (catégorie facultative, résultat, 409 du
// ban automatique), liste enrichie des bannis, résolution stricte e-mail →
// UUID (minuscules), ban / levée de chaînes (catégorie, résultat). Client
// HTTP simulé ; fixtures neutres ; aucune dépendance dart:html.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/banned_channel.dart';
import 'package:mgt_admin/domain/models/banned_user.dart';
import 'package:mgt_admin/domain/models/moderation.dart';

import 'support/http_fixtures.dart';

const String _uuid = '0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60';
const String _uuid2 = '1c8d7f2b-3e4f-4d6c-9b0f-2e3d4c5b6a71';

void main() {
  late List<http.Request> seen;
  setUp(() => seen = <http.Request>[]);

  group('Comptes : ban et levée manuels', () {
    test('banUser(uuid, category: spam) → {user_id, reason: null, '
        'category: spam}', () async {
      final ManualBanResult r = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'ok': true,
          'result': 'applied',
          'event_id': 12,
        }),
        () => fakeSync().banUser(_uuid, category: 'spam'),
      );
      expect(isRoute(seen.single, 'profiles/ban'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{
        'user_id': _uuid,
        'reason': null,
        'category': 'spam',
      });
      expect(r.result, 'applied');
      expect(r.eventId, 12);
      expect(r.replayed, isFalse);
    });

    test(
      'banUser sans catégorie → pas de clé category ; already_banned',
      () async {
        final ManualBanResult r = await withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'ok': true,
            'result': 'already_banned',
            'event_id': 13,
          }),
          () => fakeSync().banUser(_uuid, reason: 'Motif neutre'),
        );
        expect(bodyOf(seen.single), <String, dynamic>{
          'user_id': _uuid,
          'reason': 'Motif neutre',
        });
        expect(r.result, 'already_banned');
        expect(r.eventId, 13);
      },
    );

    test('banUser 404 « Profil introuvable. » sans result', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error': 'Profil introuvable.',
          }, 404),
          () => fakeSync().banUser(_uuid),
        ),
        throwsA(
          isA<AdminApiException>()
              .having((e) => e.isNotFound, 'isNotFound', isTrue)
              .having((e) => e.result, 'result', isNull)
              .having((e) => e.message, 'message', 'Profil introuvable.'),
        ),
      );
    });

    test('unbanUser 200 not_banned', () async {
      final ManualUnbanResult r = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'ok': true,
          'result': 'not_banned',
          'event_id': null,
        }),
        () => fakeSync().unbanUser(_uuid),
      );
      expect(isRoute(seen.single, 'profiles/unban'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{'user_id': _uuid});
      expect(r.result, 'not_banned');
      expect(r.eventId, isNull);
      expect(r.replayed, isFalse);
    });

    test('unbanUser : coupure puis not_banned → replayed (INF-01)', () async {
      int n = 0;
      final ManualUnbanResult r = await withMock(seen, (_) {
        if (++n == 1) throw http.ClientException('coupure');
        return jsonResponse(<String, dynamic>{
          'ok': true,
          'result': 'not_banned',
        });
      }, () => fakeSync().unbanUser(_uuid));
      expect(seen, hasLength(2));
      expect(r.result, 'not_banned');
      expect(r.replayed, isTrue);
    });

    test('unbanUser 409 → exception + banEventId', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error': 'Bannissement automatique.',
            'result': 'auto_ban_use_review',
            'ban_event_id': 55,
          }, 409),
          () => fakeSync().unbanUser(_uuid),
        ),
        throwsA(
          isA<AdminApiException>()
              .having((e) => e.isConflict, 'isConflict', isTrue)
              .having((e) => e.result, 'result', 'auto_ban_use_review')
              .having((e) => e.banEventId, 'banEventId', 55),
        ),
      );
    });
  });

  group('Liste enrichie des bannis', () {
    test('fetchBannedList : corps {} et mapping des 10 champs', () async {
      final List<BannedUser> list = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'banned': <Object?>[
            <String, dynamic>{
              'id': _uuid,
              'display_name': 'Joueur A',
              'is_banned': true,
              'ban_reason': 'Modération automatique (en revue)',
              'banned_at': '2026-09-28T10:00:00.123456+00:00',
              'category': 'injection_ia',
              'origin': 'auto',
              'status': 'en_revue',
              'ban_event_id': 44,
              'manual_ban_present': true,
            },
            <String, dynamic>{
              'id': _uuid2,
              'display_name': null,
              'is_banned': true,
              'ban_reason': null,
              'banned_at': null,
              'category': 'moderation',
              'origin': 'manual',
              'status': 'manuel',
              'ban_event_id': null,
            },
            <String, dynamic>{'id': ''},
            <String, dynamic>{'display_name': 'sans id'},
            'pas un objet',
          ],
          'total': 2,
        }),
        () => fakeSync().fetchBannedList(),
      );
      expect(isRoute(seen.single, 'profiles/banned-list'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{});
      expect(list, hasLength(2));
      final BannedUser a = list.first;
      expect(a.id, _uuid);
      expect(a.displayName, 'Joueur A');
      expect(a.reason, 'Modération automatique (en revue)');
      expect(a.bannedAt, DateTime.utc(2026, 9, 28, 10, 0, 0, 123, 456));
      expect(a.category, 'injection_ia');
      expect(a.origin, 'auto');
      expect(a.status, 'en_revue');
      expect(a.banEventId, 44);
      expect(a.manualBanPresent, isTrue);
      expect(a.isAutoInReview, isTrue);
      final BannedUser b = list.last;
      expect(b.displayName, 'Inconnu');
      expect(b.reason, isNull);
      expect(b.bannedAt, isNull);
      expect(b.banEventId, isNull);
      expect(b.manualBanPresent, isFalse);
      expect(b.isAuto, isFalse);
    });

    test(
      'fetchBannedList : banned absent → erreur (jamais une liste vide)',
      () async {
        await expectLater(
          withMock(
            seen,
            (_) => jsonResponse(<String, dynamic>{'total': 0}),
            () => fakeSync().fetchBannedList(),
          ),
          throwsA(isA<AdminApiException>()),
        );
      },
    );

    test('fetchBannedList : 500 → erreur', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error': 'Lecture des bannis indisponible.',
          }, 500),
          () => fakeSync().fetchBannedList(),
        ),
        throwsA(
          isA<AdminApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            500,
          ),
        ),
      );
    });
  });

  group('Résolution e-mail → UUID', () {
    test('lookupProfileIdByEmail : e-mail rogné et en minuscules', () async {
      final String? id = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'id': _uuid}),
        () => fakeSync().lookupProfileIdByEmail(' P1@Exemple.TEST '),
      );
      expect(isRoute(seen.single, 'profiles/find-by-email'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{
        'email': 'p1@exemple.test',
      });
      expect(id, _uuid);
    });

    test('lookupProfileIdByEmail : {id: null} → null', () async {
      final String? id = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'id': null}),
        () => fakeSync().lookupProfileIdByEmail('p1@exemple.test'),
      );
      expect(id, isNull);
    });

    test('lookupProfileIdByEmail : 500 → exception ; findProfileByEmail → '
        'null', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{'error': 'Erreur.'}, 500),
          () => fakeSync().lookupProfileIdByEmail('p1@exemple.test'),
        ),
        throwsA(isA<AdminApiException>()),
      );
      final String? id = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'error': 'Erreur.'}, 500),
        () => fakeSync().findProfileByEmail('p1@exemple.test'),
      );
      expect(id, isNull);
    });

    test('lookupProfileIdByEmail : 400 « Recherche par email échouée » '
        '(issue connue)', () async {
      Object? err;
      try {
        await withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error': 'Recherche par email échouée',
          }, 400),
          () => fakeSync().lookupProfileIdByEmail('p1@exemple.test'),
        );
      } catch (e) {
        err = e;
      }
      expect(err, isA<AdminApiException>());
      expect(isUncertainFailure(err!), isFalse);
    });

    test('findProfileByEmail : 401 relancé', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{'error': 'Non autorisé.'}, 401),
          () => fakeSync().findProfileByEmail('p1@exemple.test'),
        ),
        throwsA(isA<AdminAuthException>()),
      );
    });
  });

  group('Chaînes : ban et levée', () {
    test('banChannel(category:) + report.result == auto_en_revue', () async {
      final BanChannelReport r = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'banned': <String, dynamic>{
            'id': 4,
            'handle': 'auto:UCabcdefghijklmnopqrstuv',
            'channel_id': 'UCabcdefghijklmnopqrstuv',
            'platform': 'youtube',
            'origin': 'auto',
            'category': 'injection_ia',
            'status': 'en_revue',
            'ban_event_id': 8,
            'manual_event_id': 9,
          },
          'purged': 0,
          'published': <Object?>[],
          'published_via': 'suggestions-accepted',
          'result': 'auto_en_revue',
        }),
        () => fakeSync().banChannel(
          handleOrUrl: '@chaine',
          reason: 'Motif neutre',
          category: 'spam',
        ),
      );
      expect(isRoute(seen.single, 'channels/ban'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{
        'handle': '@chaine',
        'reason': 'Motif neutre',
        'category': 'spam',
      });
      expect(r.result, 'auto_en_revue');
      expect(r.banned.isAuto, isTrue);
      expect(r.banned.hasManualIntent, isTrue);
    });

    test('banChannel sans catégorie → pas de clé category', () async {
      await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'banned': <String, dynamic>{'id': 1, 'handle': 'chaine'},
          'purged': 2,
          'published': <Object?>[],
          'published_via': 'suggestions-accepted',
          'result': 'applied',
        }),
        () => fakeSync().banChannel(
          handleOrUrl: '@chaine',
          reason: 'Motif',
          displayName: '  Chaîne  ',
        ),
      );
      expect(bodyOf(seen.single), <String, dynamic>{
        'handle': '@chaine',
        'reason': 'Motif',
        'display_name': 'Chaîne',
      });
    });

    test('unbanChannel → not_found', () async {
      final ({String result, bool replayed}) r = await withMock(
        seen,
        (_) =>
            jsonResponse(<String, dynamic>{'ok': true, 'result': 'not_found'}),
        () => fakeSync().unbanChannel(6),
      );
      expect(isRoute(seen.single, 'channels/unban'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{'id': 6});
      expect(r.result, 'not_found');
      expect(r.replayed, isFalse);
    });

    test('unbanChannel : 502 puis not_found → replayed (INF-01)', () async {
      int n = 0;
      final ({String result, bool replayed}) r = await withMock(
        seen,
        (_) => ++n == 1
            ? jsonResponse(<String, dynamic>{'error': 'passerelle'}, 502)
            : jsonResponse(<String, dynamic>{
                'ok': true,
                'result': 'not_found',
              }),
        () => fakeSync().unbanChannel(6),
      );
      expect(seen, hasLength(2));
      expect(r.result, 'not_found');
      expect(r.replayed, isTrue);
    });

    test('unbanChannel sans result (EF antérieure) → lifted', () async {
      final ({String result, bool replayed}) r = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'ok': true}),
        () => fakeSync().unbanChannel(6),
      );
      expect(r.result, 'lifted');
    });

    test('unbanChannel 409 → banEventId', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error': 'Chaîne bannie automatiquement.',
            'result': 'auto_ban_use_review',
            'ban_event_id': 21,
          }, 409),
          () => fakeSync().unbanChannel(6),
        ),
        throwsA(
          isA<AdminApiException>().having(
            (e) => e.banEventId,
            'banEventId',
            21,
          ),
        ),
      );
    });

    test('unpublishByChannel : bilan du serveur et rejeu', () async {
      int n = 0;
      final ({int deleted, List<Map<String, dynamic>> removed, bool replayed})
      r = await withMock(
        seen,
        (_) => (n++ == 0)
            ? http.Response('', 504)
            : jsonResponse(<String, dynamic>{
                'deleted': 1,
                'removed': <Object?>[
                  <String, dynamic>{'id': 'c1', 'title': 'T', 'url': 'u'},
                ],
              }),
        () => fakeSync().unpublishByChannel('chaine'),
      );
      expect(
        seen.every(
          (http.Request q) => isRoute(q, 'contents/unpublish-by-channel'),
        ),
        isTrue,
      );
      expect(bodyOf(seen.first), <String, dynamic>{'handle': 'chaine'});
      expect(r.deleted, 1);
      expect(r.removed.single['id'], 'c1');
      expect(r.replayed, isTrue);
    });
  });
}
