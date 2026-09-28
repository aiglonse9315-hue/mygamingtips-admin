// Tests purs (VM) des modèles de MODÉRATION (P4b-3, lot L2) : lecture
// tolérante des éléments de la file, du détail (état de la preuve pour les
// 5 cas, membres du groupe), des réglages (disjoncteur, refus 24 h), d'un
// événement masqué, du résultat de décision (7 clés), des jeux prêts et du
// bilan d'activation. Fixtures neutres ; aucune dépendance dart:html.

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/models/moderation.dart';
import 'package:mgt_admin/domain/models/ready_games.dart';

const String _hexA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _uuid = '0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60';

Map<String, dynamic> _fullItem() => <String, dynamic>{
  'kind': 'a_examiner',
  'group_size': 3,
  'id': 21,
  'created_at': '2026-09-28T10:00:00.000000+00:00',
  'target_kind': 'page',
  'target_key': 'https://exemple.test/une/page',
  'action': 'pending_review',
  'category': 'injection_ia',
  'reasons': <Object?>['page_publiee', 'auto_ban_desactive'],
  'suggestion_id': _uuid,
  'shared_at': '2026-09-27T09:00:00+00:00',
  'platform': 'web',
  'content_key': null,
  'detector_version': 'v1',
  'rules_sha256': _hexA,
  'rules': <Object?>['r1', 'r2'],
  'field': 'titre',
  'level': 'extraction',
  'evidence_sha256': _hexA,
  'raw_sha256': _hexA,
  'actor_username': 'compte-bot',
  'suggestion_author_id': _uuid,
  'has_evidence': true,
  'account_display_name': null,
  'manual_ban_present': false,
  'channel_row_id': null,
};

Map<String, dynamic> _event(int id, {Object? snapshot}) => <String, dynamic>{
  'id': id,
  'created_at': '2026-09-28T10:00:00+00:00',
  'target_kind': 'account',
  'target_key': _uuid,
  'action': 'pending_review',
  'origin': 'auto',
  'category': 'injection_ia',
  'actor_username': 'compte-bot',
  'actor_kind': 'detecteur',
  'reasons': <Object?>['auto_ban_desactive'],
  'ref_event_id': null,
  'group_event_id': null,
  'note': null,
  'snapshot': snapshot,
};

Map<String, dynamic> _evidence(int eventId) => <String, dynamic>{
  'event_id': eventId,
  'created_at': '2026-09-28T10:00:00+00:00',
  'origin_key': 'compte:$_uuid',
  'suggestion_url': 'https://exemple.test/v',
  'shared_text': 'Texte partagé neutre',
  'demande': <String, dynamic>{'entity_key': 'x'},
};

Map<String, dynamic> _detail({
  required int id,
  Object? snapshot,
  Map<String, dynamic>? evidence,
  int? evidenceEventId,
  List<Object?> members = const <Object?>[],
}) => <String, dynamic>{
  'result': 'ok',
  'event': _event(id, snapshot: snapshot),
  'evidence': evidence,
  'evidence_event_id': evidenceEventId,
  'group': <String, dynamic>{
    'head_id': 10,
    'size': 1 + members.length,
    'members': members,
  },
};

void main() {
  group('ReviewItem / ReviewQueuePage', () {
    test('élément complet', () {
      final ReviewItem i = ReviewItem.fromJson(_fullItem())!;
      expect(i.kind, 'a_examiner');
      expect(i.groupSize, 3);
      expect(i.id, 21);
      expect(i.createdAt, DateTime.utc(2026, 9, 28, 10));
      expect(i.targetKind, 'page');
      expect(i.targetKey, 'https://exemple.test/une/page');
      expect(i.action, 'pending_review');
      expect(i.reasons, <String>['page_publiee', 'auto_ban_desactive']);
      expect(i.sharedAt, DateTime.utc(2026, 9, 27, 9));
      expect(i.platform, 'web');
      expect(i.rules, <String>['r1', 'r2']);
      expect(i.level, 'extraction');
      expect(i.suggestionAuthorId, _uuid);
      expect(i.hasEvidence, isTrue);
      expect(i.manualBanPresent, isFalse);
      expect(i.channelRowId, isNull);
    });

    test('id absent → null (élément ignoré par la page)', () {
      final Map<String, dynamic> j = _fullItem()..remove('id');
      expect(ReviewItem.fromJson(j), isNull);
      expect(ReviewItem.fromJson(<String, dynamic>{'id': '21'}), isNull);
      expect(ReviewItem.fromJson('texte'), isNull);
      final ReviewQueuePage p = ReviewQueuePage.fromJson(<String, dynamic>{
        'total': 2,
        'page': 0,
        'pageSize': 50,
        'items': <Object?>[j, _fullItem(), null],
      });
      expect(p.items.map((ReviewItem x) => x.id), <int>[21]);
      expect(p.total, 2);
    });

    test('kind inconnu conservé ; nombres en double ; raisons non texte '
        'filtrées', () {
      final ReviewItem i = ReviewItem.fromJson(<String, dynamic>{
        ..._fullItem(),
        'kind': 'nouveau_kind',
        'id': 21.0,
        'group_size': 2.0,
        'channel_row_id': 7.0,
        'reasons': <Object?>['a', 3, null, 'b'],
        'rules': 'pas une liste',
      })!;
      expect(i.kind, 'nouveau_kind');
      expect(i.id, 21);
      expect(i.groupSize, 2);
      expect(i.channelRowId, 7);
      expect(i.reasons, <String>['a', 'b']);
      expect(i.rules, isNull);
    });

    test('valeurs absentes → défauts', () {
      final ReviewItem i = ReviewItem.fromJson(<String, dynamic>{'id': 1})!;
      expect(i.kind, '');
      expect(i.groupSize, 1);
      expect(i.reasons, isEmpty);
      expect(i.hasEvidence, isFalse);
      expect(i.createdAt, isNull);
    });
  });

  group('ReviewDetail.evidenceState (5 cas)', () {
    test('preuve propre → present', () {
      final ReviewDetail d = ReviewDetail.fromJson(
        _detail(id: 10, evidence: _evidence(10), evidenceEventId: 10),
      )!;
      expect(d.evidenceState, EvidenceState.present);
      expect(d.evidence!.sharedText, 'Texte partagé neutre');
      expect(d.evidence!.originKey, 'compte:$_uuid');
    });

    test('preuve de la tête → headEvidence', () {
      final ReviewDetail d = ReviewDetail.fromJson(
        _detail(
          id: 12,
          evidence: _evidence(10),
          evidenceEventId: 10,
          snapshot: <String, dynamic>{'preuve': false},
        ),
      )!;
      expect(d.evidenceState, EvidenceState.headEvidence);
    });

    test('snapshot.preuve true sans preuve → purged', () {
      final ReviewDetail d = ReviewDetail.fromJson(
        _detail(id: 10, snapshot: <String, dynamic>{'preuve': true}),
      )!;
      expect(d.evidenceState, EvidenceState.purged);
    });

    test('snapshot.preuve false sans preuve → notKept', () {
      final ReviewDetail d = ReviewDetail.fromJson(
        _detail(id: 10, snapshot: <String, dynamic>{'preuve': false}),
      )!;
      expect(d.evidenceState, EvidenceState.notKept);
    });

    test('snapshot nul → none', () {
      final ReviewDetail d = ReviewDetail.fromJson(_detail(id: 10))!;
      expect(d.evidenceState, EvidenceState.none);
    });

    test('membres du groupe, tête et taille', () {
      final ReviewDetail d = ReviewDetail.fromJson(
        _detail(id: 10, members: <Object?>[11, 12.0, 'x', 13]),
      )!;
      expect(d.groupHeadId, 10);
      expect(d.groupSize, 5);
      expect(d.groupMembers, <int>[11, 12, 13]);
    });

    test('result ≠ ok ou event illisible → null', () {
      expect(
        ReviewDetail.fromJson(<String, dynamic>{
          ..._detail(id: 10),
          'result': 'not_found',
        }),
        isNull,
      );
      expect(
        ReviewDetail.fromJson(<String, dynamic>{'result': 'ok', 'event': 3}),
        isNull,
      );
    });

    test('demande et snapshot conservés tels quels', () {
      final ReviewDetail d = ReviewDetail.fromJson(
        _detail(
          id: 10,
          evidence: _evidence(10),
          snapshot: <String, dynamic>{
            'preuve': true,
            'serveur': <String, dynamic>{'hote_page': 'exemple.test'},
          },
        ),
      )!;
      expect(d.evidence!.demande, <String, dynamic>{'entity_key': 'x'});
      expect(d.event.snapshot!['serveur'], <String, dynamic>{
        'hote_page': 'exemple.test',
      });
    });
  });

  group('ModerationSettings', () {
    Map<String, dynamic> settings({
      Object? breaker,
      Object? refused = const <String, dynamic>{},
      bool withRefused = true,
    }) => <String, dynamic>{
      'auto_ban_enabled': false,
      'max_auto_bans_per_hour': 3,
      'max_auto_bans_per_day': 10,
      'allowed_rules_sha256': <Object?>[_hexA],
      'breaker_tripped_at': breaker,
      'breaker_reason': breaker == null ? null : 'plafond_heure',
      'breaker_event_id': breaker == null ? null : 40,
      'updated_at': '2026-09-28T10:00:00+00:00',
      'updated_by': breaker == null ? null : 'disjoncteur',
      'auto_bans_last_hour': 3,
      'auto_bans_last_day': 4,
      'refused_24h': ?(withRefused ? refused : null),
      'review_queue_size': 6,
      'evidence_rows': 9,
      'chain_threshold': 2,
      'chain_window_days': 90,
    };

    test('disjoncteur ouvert → breakerOpen', () {
      final ModerationSettings s = ModerationSettings.fromJson(
        settings(breaker: '2026-09-28T11:00:00+00:00'),
      )!;
      expect(s.breakerOpen, isTrue);
      expect(s.breakerReason, 'plafond_heure');
      expect(s.breakerEventId, 40);
      expect(s.updatedBy, 'disjoncteur');
      expect(s.autoBansLastHour, 3);
      expect(s.allowedRulesSha256, <String>[_hexA]);
    });

    test('disjoncteur fermé → breakerOpen faux', () {
      final ModerationSettings s = ModerationSettings.fromJson(settings())!;
      expect(s.breakerOpen, isFalse);
      expect(s.maxPerHour, 3);
      expect(s.maxPerDay, 10);
      expect(s.reviewQueueSize, 6);
      expect(s.evidenceRows, 9);
    });

    test('refused_24h {} et absent → {}', () {
      expect(ModerationSettings.fromJson(settings())!.refused24h, isEmpty);
      expect(
        ModerationSettings.fromJson(settings(withRefused: false))!.refused24h,
        isEmpty,
      );
    });

    test('refused_24h : valeurs numériques gardées, autres ignorées', () {
      final ModerationSettings s = ModerationSettings.fromJson(
        settings(
          refused: <String, dynamic>{
            'url_invalide': 2,
            'texte_absent': 1.0,
            'autre': 'x',
          },
        ),
      )!;
      expect(s.refused24h, <String, int>{'url_invalide': 2, 'texte_absent': 1});
    });

    test('interrupteur ou plafonds illisibles → null', () {
      expect(ModerationSettings.fromJson(null), isNull);
      expect(
        ModerationSettings.fromJson(<String, dynamic>{
          ...settings(),
          'auto_ban_enabled': 'false',
        }),
        isNull,
      );
      expect(
        ModerationSettings.fromJson(<String, dynamic>{
          ...settings(),
          'max_auto_bans_per_day': null,
        }),
        isNull,
      );
    });
  });

  group('BanEvent / EventsPage', () {
    test('événement masqué : target_key null, hôte, empreinte', () {
      final BanEvent e = BanEvent.fromJson(<String, dynamic>{
        'id': 5,
        'target_kind': 'page',
        'target_key': null,
        'target_key_masked': true,
        'target_host': 'exemple.test',
        'target_key_sha256': _hexA,
        'action': 'refused',
        'origin': 'auto',
        'category': 'injection_ia',
        'actor_kind': 'detecteur',
      })!;
      expect(e.targetKey, isNull);
      expect(e.targetKeyMasked, isTrue);
      expect(e.targetHost, 'exemple.test');
      expect(e.targetKeySha256, _hexA);
      expect(e.snapshot, isNull);
    });

    test('événement non masqué avec motif', () {
      final BanEvent e = BanEvent.fromJson(<String, dynamic>{
        ..._event(6),
        'action': 'lift',
        'actor_kind': 'revue',
        'ref_event_id': 5,
        'note': 'Motif neutre',
        'target_key_masked': false,
      })!;
      expect(e.targetKey, _uuid);
      expect(e.targetKeyMasked, isFalse);
      expect(e.refEventId, 5);
      expect(e.note, 'Motif neutre');
      expect(e.actorKind, 'revue');
    });

    test('EventsPage : éléments illisibles ignorés', () {
      final EventsPage p = EventsPage.fromJson(<String, dynamic>{
        'total': 3,
        'page': 1,
        'pageSize': 2,
        'items': <Object?>[
          _event(1),
          <String, dynamic>{'id': null},
          'x',
        ],
      });
      expect(p.items.map((BanEvent e) => e.id), <int>[1]);
      expect(p.total, 3);
      expect(p.page, 1);
      expect(p.pageSize, 2);
    });
  });

  group('ReviewDecideResult', () {
    test('7 clés lues', () {
      final ReviewDecideResult r = ReviewDecideResult.fromJson(
        <String, dynamic>{
          'result': 'refused',
          'event_id': 70,
          'target_kind': null,
          'reasons': <Object?>['profil_absent'],
          'previous': null,
          'still_banned': null,
          'group_size': null,
        },
        replayed: true,
      );
      expect(r.result, 'refused');
      expect(r.eventId, 70);
      expect(r.targetKind, isNull);
      expect(r.reasons, <String>['profil_absent']);
      expect(r.replayed, isTrue);
      final ReviewDecideResult s =
          ReviewDecideResult.fromJson(<String, dynamic>{
            'result': 'already_resolved',
            'event_id': null,
            'target_kind': null,
            'reasons': <Object?>[],
            'previous': 'dismiss',
            'still_banned': null,
            'group_size': 4,
          });
      expect(s.previous, 'dismiss');
      expect(s.groupSize, 4);
      expect(s.replayed, isFalse);
      final ReviewDecideResult t = ReviewDecideResult.fromJson(
        <String, dynamic>{'result': 'lifted', 'still_banned': 'manuel'},
      );
      expect(t.stillBanned, 'manuel');
    });
  });

  group('Pages bloquées, purge auto, bans manuels', () {
    test('BlockedPage : id absent → null', () {
      expect(BlockedPage.fromJson(<String, dynamic>{'url': 'u'}), isNull);
      final BlockedPage p = BlockedPage.fromJson(<String, dynamic>{
        'id': 1,
        'url': 'https://exemple.test/p',
        'host': 'exemple.test',
        'status': 'confirme',
        'origin': 'auto',
        'category': 'injection_ia',
        'ban_event_id': null,
        'created_at': '2026-09-28T10:00:00+00:00',
      })!;
      expect(p.status, 'confirme');
      expect(p.banEventId, isNull);
    });

    test('PurgeAutoResult : publiés à id texte ou nombre', () {
      final PurgeAutoResult r = PurgeAutoResult.fromJson(<String, dynamic>{
        'result': 'preview',
        'pending': 2,
        'pending_by_detection': 1,
        'pending_by_channel_id': 1,
        'published': <Object?>[
          <String, dynamic>{'id': 'c1', 'title': 'T', 'url': 'u'},
          <String, dynamic>{'id': 9, 'title': null, 'url': null},
          <String, dynamic>{'title': 'sans id'},
        ],
      });
      expect(r.published.map((PublishedContent c) => c.id), <String>[
        'c1',
        '9',
      ]);
      expect(r.purged, isNull);
    });

    test('ManualBanResult / ManualUnbanResult / EvidencePurgeResult', () {
      final ManualBanResult b = ManualBanResult.fromJson(<String, dynamic>{
        'ok': true,
        'result': 'applied',
        'event_id': 3,
      }, replayed: true);
      expect(b.result, 'applied');
      expect(b.eventId, 3);
      expect(b.replayed, isTrue);
      final ManualUnbanResult u = ManualUnbanResult.fromJson(<String, dynamic>{
        'ok': true,
        'result': 'lifted',
        'event_id': 4,
      });
      expect(u.result, 'lifted');
      expect(u.eventId, 4);
      final EvidencePurgeResult e = EvidencePurgeResult.fromJson(
        <String, dynamic>{'result': 'preview', 'count': 7.0},
      );
      expect(e.count, 7);
      expect(e.replayed, isFalse);
    });
  });

  group('Jeux prêts', () {
    test('ReadyGamesPreview : lecture et doublons d\'URL', () {
      final ReadyGamesPreview p = ReadyGamesPreview.fromJson(<String, dynamic>{
        'dry_run': true,
        'threshold': 10,
        'inactive_total': 4,
        'count': 2,
        'games': <Object?>[
          <String, dynamic>{
            'id': _uuid,
            'name': 'Jeu A',
            'validated_total': 12,
            'video': 6,
            'guides': 4,
            'links': 2,
            'distinct_urls': 12,
            'updated_at': '2026-09-28T10:00:00+00:00',
          },
          <String, dynamic>{
            'id': 'b',
            'name': 'Jeu B',
            'validated_total': 10,
            'distinct_urls': 9,
          },
          <String, dynamic>{'name': 'sans id'},
        ],
      })!;
      expect(p.threshold, 10);
      expect(p.inactiveTotal, 4);
      expect(p.count, 2);
      expect(p.games, hasLength(2));
      expect(p.games.first.hasDuplicateUrls, isFalse);
      expect(p.games.first.updatedAt, DateTime.utc(2026, 9, 28, 10));
      expect(p.games.last.hasDuplicateUrls, isTrue);
      expect(p.games.last.video, 0);
    });

    test('ReadyGamesPreview : games absent → null', () {
      expect(ReadyGamesPreview.fromJson(<String, dynamic>{'count': 0}), isNull);
      expect(ReadyGamesPreview.fromJson(null), isNull);
    });

    test('ActivateReadyResult : activated / skipped', () {
      final ActivateReadyResult r = ActivateReadyResult.fromJson(
        <String, dynamic>{
          'threshold': 10,
          'requested': 3,
          'activated': <Object?>[
            <String, dynamic>{
              'id': 'a',
              'name': 'Jeu A',
              'validated_total': 12,
            },
          ],
          'skipped': <Object?>[
            <String, dynamic>{'id': 'b', 'reason': 'below_threshold'},
            <String, dynamic>{'id': 'c', 'reason': 'not_found'},
          ],
        },
        replayed: true,
      )!;
      expect(r.requested, 3);
      expect(r.activated.single.validatedTotal, 12);
      expect(r.skipped.map((SkippedGame s) => s.reason), <String>[
        'below_threshold',
        'not_found',
      ]);
      expect(r.replayed, isTrue);
    });

    test('ActivateReadyResult : listes absentes → null', () {
      expect(
        ActivateReadyResult.fromJson(<String, dynamic>{
          'activated': <Object?>[],
        }),
        isNull,
      );
    });
  });
}
