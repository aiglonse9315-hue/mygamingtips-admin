// Tests purs (VM) des méthodes de MODÉRATION de SupabaseSync (P4b-3, lot
// L2) : pour chaque route, chemin et corps JSON EXACTS (routes strictes :
// clé nulle omise, `dry_run` toujours explicite, `target_key` vide omise),
// lecture des réponses (file avec et sans `channel_row_id`), erreurs sans
// `result`, réponses 2xx illisibles, rejeu visible. Client HTTP simulé ;
// fixtures neutres ; aucune dépendance dart:html.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/ban_category.dart';
import 'package:mgt_admin/domain/models/banned_channel.dart';
import 'package:mgt_admin/domain/models/moderation.dart';

import 'support/http_fixtures.dart';

const String _hexA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _hexB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Map<String, dynamic> _item(int id, {int? channelRowId}) => <String, dynamic>{
  'kind': 'ban_en_revue',
  'group_size': 1,
  'id': id,
  'created_at': '2026-09-28T10:00:00.000000+00:00',
  'target_kind': 'channel',
  'target_key': 'UCabcdefghijklmnopqrstuv',
  'action': 'ban',
  'category': 'injection_ia',
  'reasons': <Object?>[],
  'suggestion_id': '0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60',
  'shared_at': null,
  'platform': 'youtube',
  'content_key': 'youtube:abcdefghijk',
  'detector_version': 'v1',
  'rules_sha256': _hexA,
  'rules': <Object?>['r1'],
  'field': 'titre',
  'level': 'suspect',
  'evidence_sha256': _hexB,
  'raw_sha256': null,
  'actor_username': 'compte-bot',
  'suggestion_author_id': null,
  'has_evidence': true,
  'account_display_name': null,
  'manual_ban_present': false,
  'channel_row_id': ?channelRowId,
};

Map<String, dynamic> _settings({bool enabled = false}) => <String, dynamic>{
  'auto_ban_enabled': enabled,
  'max_auto_bans_per_hour': 3,
  'max_auto_bans_per_day': 10,
  'allowed_rules_sha256': <Object?>[_hexA],
  'breaker_tripped_at': null,
  'breaker_reason': null,
  'breaker_event_id': null,
  'updated_at': '2026-09-28T10:00:00+00:00',
  'updated_by': null,
  'auto_bans_last_hour': 0,
  'auto_bans_last_day': 0,
  'refused_24h': <String, dynamic>{},
  'review_queue_size': 2,
  'evidence_rows': 5,
  'chain_threshold': 2,
  'chain_window_days': 90,
};

void main() {
  late List<http.Request> seen;
  setUp(() => seen = <http.Request>[]);

  group('File de revue', () {
    test('fetchReviewList : route, corps {page, pageSize}, lecture avec et '
        'sans channel_row_id', () async {
      final ReviewQueuePage p = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'total': 2,
          'page': 1,
          'pageSize': 20,
          'items': <Object?>[_item(11, channelRowId: 7), _item(10)],
          'fresh_token': 'a.b.c',
        }),
        () => fakeSync().fetchReviewList(page: 1, pageSize: 20),
      );
      expect(isRoute(seen.single, 'moderation/review-list'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{'page': 1, 'pageSize': 20});
      expect(p.total, 2);
      expect(p.items.map((ReviewItem i) => i.id), <int>[11, 10]);
      expect(p.items.first.channelRowId, 7);
      expect(p.items.last.channelRowId, isNull);
    });

    test('fetchReviewList : pageSize borné à 100', () async {
      await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'total': 0,
          'page': 0,
          'pageSize': 100,
          'items': <Object?>[],
        }),
        () => fakeSync().fetchReviewList(pageSize: 500),
      );
      expect(bodyOf(seen.single), <String, dynamic>{
        'page': 0,
        'pageSize': 100,
      });
    });

    test('fetchReviewList : items absent → réponse illisible', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{'total': 0}),
          () => fakeSync().fetchReviewList(),
        ),
        throwsA(
          isA<AdminApiException>().having(
            (e) => isUncertainFailure(e),
            'incertain',
            isTrue,
          ),
        ),
      );
    });

    test('fetchReviewDetail(7) : corps {event_id: 7}', () async {
      final ReviewDetail d = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'result': 'ok',
          'event': <String, dynamic>{
            'id': 7,
            'target_kind': 'account',
            'action': 'ban',
            'origin': 'auto',
            'category': 'injection_ia',
            'actor_kind': 'detecteur',
          },
          'evidence': null,
          'evidence_event_id': null,
          'group': <String, dynamic>{
            'head_id': 7,
            'size': 1,
            'members': <Object?>[],
          },
        }),
        () => fakeSync().fetchReviewDetail(7),
      );
      expect(isRoute(seen.single, 'moderation/review-detail'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{'event_id': 7});
      expect(d.event.id, 7);
      expect(d.evidenceState, EvidenceState.none);
    });

    test('review-detail {result: ok, event: 3} → réponse illisible, '
        'incertaine', () async {
      Object? err;
      try {
        await withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{'result': 'ok', 'event': 3}),
          () => fakeSync().fetchReviewDetail(3),
        );
      } catch (e) {
        err = e;
      }
      expect(err, isA<AdminApiException>());
      expect(
        (err! as AdminApiException).message,
        'Réponse illisible du serveur.',
      );
      expect(isUncertainFailure(err), isTrue);
    });
  });

  group('Décision de revue', () {
    for (final ReviewDecision d in ReviewDecision.values) {
      test('reviewDecide ${d.code} sans motif : clé reason ABSENTE', () async {
        await withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'result': 'dismissed',
            'event_id': 30,
            'target_kind': 'channel',
            'reasons': <Object?>[],
            'previous': null,
            'still_banned': null,
            'group_size': 2,
          }),
          () => fakeSync().reviewDecide(12, d),
        );
        expect(isRoute(seen.single, 'moderation/review-decide'), isTrue);
        expect(bodyOf(seen.single), <String, dynamic>{
          'event_id': 12,
          'decision': d.code,
        });
      });
    }

    test('reviewDecide lift avec motif : clé reason présente', () async {
      final ReviewDecideResult r = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'result': 'lifted',
          'event_id': 31,
          'target_kind': 'account',
          'reasons': <Object?>[],
          'previous': null,
          'still_banned': 'manuel',
          'group_size': null,
        }),
        () => fakeSync().reviewDecide(
          12,
          ReviewDecision.lift,
          reason: 'Motif neutre',
        ),
      );
      expect(bodyOf(seen.single), <String, dynamic>{
        'event_id': 12,
        'decision': 'lift',
        'reason': 'Motif neutre',
      });
      expect(r.result, 'lifted');
      expect(r.stillBanned, 'manuel');
      expect(r.replayed, isFalse);
    });

    test('codes de décision = noms des 4 valeurs', () {
      expect(ReviewDecision.values.map((ReviewDecision d) => d.code), <String>[
        'confirm',
        'lift',
        'apply',
        'dismiss',
      ]);
    });
  });

  group('Journal des événements', () {
    Map<String, dynamic> page() => <String, dynamic>{
      'total': 0,
      'page': 0,
      'pageSize': 50,
      'items': <Object?>[],
    };

    test('fetchEvents sans filtre : {page, pageSize} seulement', () async {
      await withMock(
        seen,
        (_) => jsonResponse(page()),
        () => fakeSync().fetchEvents(),
      );
      expect(isRoute(seen.single, 'moderation/events-list'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{'page': 0, 'pageSize': 50});
    });

    test(
      'fetchEvents avec filtres : target_kind, target_key rognée, action',
      () async {
        await withMock(
          seen,
          (_) => jsonResponse(page()),
          () => fakeSync().fetchEvents(
            page: 2,
            pageSize: 20,
            targetKind: 'account',
            targetKey: '  0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60 ',
            action: 'refused',
          ),
        );
        expect(bodyOf(seen.single), <String, dynamic>{
          'page': 2,
          'pageSize': 20,
          'target_kind': 'account',
          'target_key': '0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60',
          'action': 'refused',
        });
      },
    );

    test('fetchEvents(targetKey: "  ") → pas de clé target_key', () async {
      await withMock(
        seen,
        (_) => jsonResponse(page()),
        () => fakeSync().fetchEvents(targetKey: '  '),
      );
      expect(bodyOf(seen.single), <String, dynamic>{'page': 0, 'pageSize': 50});
    });

    test('fetchEvents : clé masquée lue', () async {
      final EventsPage p = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'total': 1,
          'page': 0,
          'pageSize': 50,
          'items': <Object?>[
            <String, dynamic>{
              'id': 4,
              'target_kind': 'page',
              'target_key': null,
              'target_key_masked': true,
              'target_host': 'exemple.test',
              'target_key_sha256': _hexA,
              'action': 'refused',
              'origin': 'auto',
              'category': 'injection_ia',
              'actor_kind': 'detecteur',
            },
          ],
        }),
        () => fakeSync().fetchEvents(action: 'refused'),
      );
      expect(p.items.single.targetKeyMasked, isTrue);
      expect(p.items.single.targetHost, 'exemple.test');
    });
  });

  group('Réglages', () {
    test('fetchModerationSettings : corps {} et lecture', () async {
      final ModerationSettings s = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'settings': _settings()}),
        () => fakeSync().fetchModerationSettings(),
      );
      expect(isRoute(seen.single, 'moderation/settings-get'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{});
      expect(s.maxPerHour, 3);
      expect(s.reviewQueueSize, 2);
    });

    test(
      'updateModerationSettings(maxPerHour: 5) : seule clé envoyée',
      () async {
        await withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'result': 'updated',
            'settings': _settings(),
          }),
          () => fakeSync().updateModerationSettings(maxPerHour: 5),
        );
        expect(isRoute(seen.single, 'moderation/settings-set'), isTrue);
        expect(bodyOf(seen.single), <String, dynamic>{
          'max_auto_bans_per_hour': 5,
        });
      },
    );

    test(
      'updateModerationSettings : liste d\'empreintes et interrupteur',
      () async {
        final ModerationSettings s = await withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'result': 'updated',
            'settings': _settings(enabled: true),
          }),
          () => fakeSync().updateModerationSettings(
            autoBanEnabled: true,
            maxPerDay: 20,
            allowedRulesSha256: <String>[_hexA, _hexB],
          ),
        );
        expect(bodyOf(seen.single), <String, dynamic>{
          'auto_ban_enabled': true,
          'max_auto_bans_per_day': 20,
          'allowed_rules_sha256': <String>[_hexA, _hexB],
        });
        expect(s.autoBanEnabled, isTrue);
      },
    );

    test(
      'updateModerationSettings : liste vide envoyée telle quelle',
      () async {
        await withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'result': 'updated',
            'settings': _settings(),
          }),
          () => fakeSync().updateModerationSettings(
            allowedRulesSha256: const <String>[],
          ),
        );
        expect(bodyOf(seen.single), <String, dynamic>{
          'allowed_rules_sha256': <String>[],
        });
      },
    );

    test(
      'settings-set {result: updated, settings: null} → illisible',
      () async {
        Object? err;
        try {
          await withMock(
            seen,
            (_) => jsonResponse(<String, dynamic>{
              'result': 'updated',
              'settings': null,
            }),
            () => fakeSync().updateModerationSettings(maxPerHour: 1),
          );
        } catch (e) {
          err = e;
        }
        expect(err, isA<AdminApiException>());
        expect(
          (err! as AdminApiException).message,
          'Réponse illisible du serveur.',
        );
        expect(isUncertainFailure(err), isTrue);
      },
    );

    test('settings-set 400 du parseur : message exact, reasons vide', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error': 'max_auto_bans_per_hour : 0 à 100.',
          }, 400),
          () => fakeSync().updateModerationSettings(maxPerHour: 101),
        ),
        throwsA(
          isA<AdminApiException>()
              .having(
                (e) => e.message,
                'message',
                'max_auto_bans_per_hour : 0 à 100.',
              )
              .having((e) => e.reasons, 'reasons', isEmpty),
        ),
      );
    });

    test('settings-set 400 avec reasons (cas SIMULÉ : branche SQL '
        'inatteignable par l\'EF) → décodé', () async {
      await expectLater(
        withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'error': 'Réglages invalides.',
            'reasons': <Object?>['max_auto_bans_per_day'],
          }, 400),
          () => fakeSync().updateModerationSettings(maxPerDay: 5),
        ),
        throwsA(
          isA<AdminApiException>().having((e) => e.reasons, 'reasons', <String>[
            'max_auto_bans_per_day',
          ]),
        ),
      );
    });
  });

  group('Preuves, pages bloquées, catégories', () {
    test('purgeEvidence(apply: false) → dry_run: true EXPLICITE', () async {
      final EvidencePurgeResult r = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'result': 'preview', 'count': 4}),
        () => fakeSync().purgeEvidence(olderThanDays: 180, apply: false),
      );
      expect(isRoute(seen.single, 'moderation/evidence-purge'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{
        'older_than_days': 180,
        'dry_run': true,
      });
      expect(r.result, 'preview');
      expect(r.count, 4);
    });

    test('purgeEvidence(apply: true) → dry_run: false', () async {
      await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{'result': 'purged', 'count': 4}),
        () => fakeSync().purgeEvidence(olderThanDays: 30, apply: true),
      );
      expect(bodyOf(seen.single), <String, dynamic>{
        'older_than_days': 30,
        'dry_run': false,
      });
    });

    test('rejeu : ClientException puis {purged, 0} → replayed', () async {
      int n = 0;
      final EvidencePurgeResult r = await withMock(seen, (_) {
        if (n++ == 0) throw http.ClientException('coupure');
        return jsonResponse(<String, dynamic>{'result': 'purged', 'count': 0});
      }, () => fakeSync().purgeEvidence(olderThanDays: 180, apply: true));
      expect(seen, hasLength(2));
      expect(r.replayed, isTrue);
      expect(r.count, 0);
    });

    test('fetchBlockedPages : corps et lecture', () async {
      final BlockedPagesPage p = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'pages': <Object?>[
            <String, dynamic>{
              'id': 1,
              'url': 'https://exemple.test/page',
              'host': 'exemple.test',
              'status': 'en_revue',
              'origin': 'auto',
              'category': 'injection_ia',
              'ban_event_id': 9,
              'created_at': '2026-09-28T10:00:00+00:00',
            },
            <String, dynamic>{'url': 'sans id'},
          ],
          'total': 1,
        }),
        () => fakeSync().fetchBlockedPages(pageSize: 1000),
      );
      expect(isRoute(seen.single, 'moderation/blocked-pages/list'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{
        'page': 0,
        'pageSize': 500,
      });
      expect(p.total, 1);
      expect(p.pages.single.banEventId, 9);
    });

    test('fetchBanCategories : corps {} et ordre serveur', () async {
      final List<BanCategory> c = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'categories': <Object?>[
            <String, dynamic>{
              'code': 'moderation',
              'label_fr': 'Modération',
              'auto_allowed': false,
            },
            <String, dynamic>{
              'code': 'injection_ia',
              'label_fr': 'Injection IA',
              'auto_allowed': true,
            },
            <String, dynamic>{'label_fr': 'sans code'},
          ],
        }),
        () => fakeSync().fetchBanCategories(),
      );
      expect(isRoute(seen.single, 'moderation/categories'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{});
      expect(c.map((BanCategory x) => x.code), <String>[
        'moderation',
        'injection_ia',
      ]);
    });

    test('fetchBanCategories : categories absente → liste vide', () async {
      final List<BanCategory> c = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{}),
        () => fakeSync().fetchBanCategories(),
      );
      expect(c, isEmpty);
    });
  });

  group('Chaînes : purge auto et recherche par événement', () {
    test(
      'purgeAutoChannel(id: 3, apply: true) → {id: 3, dry_run: false}',
      () async {
        final PurgeAutoResult r = await withMock(
          seen,
          (_) => jsonResponse(<String, dynamic>{
            'result': 'purged',
            'pending': 2,
            'purged': 2,
            'published': <Object?>[
              <String, dynamic>{
                'id': 'c1',
                'title': 'Titre',
                'url': 'https://exemple.test/v',
              },
            ],
          }),
          () => fakeSync().purgeAutoChannel(id: 3, apply: true),
        );
        expect(isRoute(seen.single, 'channels/purge-auto'), isTrue);
        expect(bodyOf(seen.single), <String, dynamic>{
          'id': 3,
          'dry_run': false,
        });
        expect(r.purged, 2);
        expect(r.published.single.id, 'c1');
        expect(r.replayed, isFalse);
      },
    );

    test('purgeAutoChannel(apply: false) → dry_run: true, aperçu', () async {
      final PurgeAutoResult r = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'result': 'preview',
          'pending': 3,
          'pending_by_detection': 2,
          'pending_by_channel_id': 1,
          'published': <Object?>[],
        }),
        () => fakeSync().purgeAutoChannel(id: 3, apply: false),
      );
      expect(bodyOf(seen.single), <String, dynamic>{'id': 3, 'dry_run': true});
      expect(r.pendingByDetection, 2);
      expect(r.purged, isNull);
    });

    test(
      'purgeAutoChannel 409 corps EXACT sans result → message identique',
      () async {
        const String msg = "Confirmez d'abord le bannissement (file de revue).";
        await expectLater(
          withMock(
            seen,
            (_) => jsonResponse(<String, dynamic>{'error': msg}, 409),
            () => fakeSync().purgeAutoChannel(id: 3, apply: false),
          ),
          throwsA(
            isA<AdminApiException>()
                .having((e) => e.statusCode, 'statusCode', 409)
                .having((e) => e.result, 'result', isNull)
                .having((e) => e.message, 'message', msg),
          ),
        );
      },
    );

    Map<String, dynamic> row(int id, int? eventId) => <String, dynamic>{
      'id': id,
      'handle': 'auto:UCabcdefghijklmnopqrstuv',
      'channel_id': 'UCabcdefghijklmnopqrstuv',
      'platform': 'youtube',
      'origin': 'auto',
      'category': 'injection_ia',
      'status': 'confirme',
      'ban_event_id': eventId,
      'manual_event_id': null,
    };

    test(
      'findBannedChannelByEventId : trouvé en page 1 (2 requêtes)',
      () async {
        final BannedChannel? c = await withMock(seen, (http.Request req) {
          final int p = (bodyOf(req)! as Map<String, dynamic>)['page'] as int;
          return jsonResponse(<String, dynamic>{
            'channels': <Object?>[
              row(p * 100 + 1, p == 1 ? 77 : 5),
              row(p * 100 + 2, null),
            ],
            'total': 250,
          });
        }, () => fakeSync().findBannedChannelByEventId(77));
        expect(seen, hasLength(2));
        expect(
          seen.every((http.Request r) => isRoute(r, 'channels/banned-list')),
          isTrue,
        );
        expect(bodyOf(seen.first), <String, dynamic>{
          'page': 0,
          'pageSize': 100,
        });
        expect(bodyOf(seen.last), <String, dynamic>{
          'page': 1,
          'pageSize': 100,
        });
        expect(c?.id, 101);
      },
    );

    test('findBannedChannelByEventId : absent → s\'arrête quand '
        '(p+1)*100 >= total', () async {
      final BannedChannel? c = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'channels': <Object?>[row(1, 5)],
          'total': 150,
        }),
        () => fakeSync().findBannedChannelByEventId(77),
      );
      expect(seen, hasLength(2));
      expect(c, isNull);
    });

    test('findBannedChannelByEventId : au plus maxPages pages', () async {
      final BannedChannel? c = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'channels': <Object?>[row(1, 5)],
          'total': 100000,
        }),
        () => fakeSync().findBannedChannelByEventId(77, maxPages: 3),
      );
      expect(seen, hasLength(3));
      expect(c, isNull);
    });
  });
}
