// Tests purs (VM) des modèles de bans enrichis (P4b-3, lot L2) : BannedUser
// (ancien cache à 6 clés, aller-retour, lecture serveur des bans auto /
// manuels), BannedChannel (ligne sans colonnes 0094, entrées auto
// YouTube / RUTUBE / bilibili, entrée convertie), BanChannelReport,
// catégories de ban (D4 : 4 catégories manuelles, repli, libellés).
// Aucune dépendance dart:html.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/models/ban_category.dart';
import 'package:mgt_admin/domain/models/banned_channel.dart';
import 'package:mgt_admin/domain/models/banned_user.dart';

const String _uuid = '0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60';

void main() {
  group('BannedUser', () {
    test('ANCIEN cache (6 clés, assets/seed/banned.json) → défauts', () {
      final List<dynamic> seed =
          jsonDecode(File('assets/seed/banned.json').readAsStringSync())
              as List<dynamic>;
      final Map<String, dynamic> old = seed.first as Map<String, dynamic>;
      expect(old.keys.toSet(), <String>{
        'id',
        'displayName',
        'avatarUrl',
        'email',
        'bannedAt',
        'reason',
      });
      final BannedUser u = BannedUser.fromJson(old);
      expect(u.id, old['id']);
      expect(u.displayName, old['displayName']);
      expect(u.bannedAt, DateTime.parse(old['bannedAt'] as String));
      expect(u.origin, 'manual');
      expect(u.status, 'manuel');
      expect(u.category, 'moderation');
      expect(u.banEventId, isNull);
      expect(u.manualBanPresent, isFalse);
      expect(u.isAuto, isFalse);
    });

    test('aller-retour toJson / fromJson complet', () {
      final BannedUser u = BannedUser(
        id: _uuid,
        displayName: 'Joueur',
        email: 'p1@exemple.test',
        bannedAt: DateTime.utc(2026, 9, 28, 10),
        reason: 'Motif',
        category: 'injection_ia',
        origin: 'auto',
        status: 'confirme',
        banEventId: 12,
        manualBanPresent: true,
      );
      final Map<String, dynamic> j = u.toJson();
      expect(j.keys.toSet(), <String>{
        'id',
        'displayName',
        'avatarUrl',
        'email',
        'bannedAt',
        'reason',
        'category',
        'origin',
        'status',
        'banEventId',
        'manualBanPresent',
      });
      final BannedUser back = BannedUser.fromJson(
        jsonDecode(jsonEncode(j)) as Map<String, dynamic>,
      );
      expect(back.id, u.id);
      expect(back.displayName, u.displayName);
      expect(back.email, u.email);
      expect(back.bannedAt, u.bannedAt);
      expect(back.reason, u.reason);
      expect(back.category, 'injection_ia');
      expect(back.origin, 'auto');
      expect(back.status, 'confirme');
      expect(back.banEventId, 12);
      expect(back.manualBanPresent, isTrue);
      expect(back.isAutoConfirmed, isTrue);
    });

    test('bannedAt illisible ou absent → null ; displayName absent → id', () {
      final BannedUser a = BannedUser.fromJson(<String, dynamic>{
        'id': 'x1',
        'bannedAt': 'pas une date',
      });
      expect(a.bannedAt, isNull);
      expect(a.displayName, 'x1');
      final BannedUser b = BannedUser.fromJson(<String, dynamic>{'id': 'x2'});
      expect(b.bannedAt, isNull);
      final BannedUser c = BannedUser.fromJson(<String, dynamic>{
        'id': 'x3',
        'bannedAt': null,
      });
      expect(c.toJson()['bannedAt'], isNull);
    });

    test('fromServer : auto en revue', () {
      final BannedUser u = BannedUser.fromServer(<String, dynamic>{
        'id': _uuid,
        'display_name': 'Joueur',
        'ban_reason': 'Modération automatique (en revue)',
        'banned_at': '2026-09-28T10:00:00+00:00',
        'category': 'injection_ia',
        'origin': 'auto',
        'status': 'en_revue',
        'ban_event_id': 3,
        'manual_ban_present': false,
      });
      expect(u.isAuto, isTrue);
      expect(u.isAutoInReview, isTrue);
      expect(u.isAutoConfirmed, isFalse);
      expect(u.banEventId, 3);
    });

    test('fromServer : auto confirmé avec ban manuel présent', () {
      final BannedUser u = BannedUser.fromServer(<String, dynamic>{
        'id': _uuid,
        'origin': 'auto',
        'status': 'confirme',
        'ban_event_id': 4.0,
        'manual_ban_present': true,
      });
      expect(u.isAutoConfirmed, isTrue);
      expect(u.banEventId, 4);
      expect(u.manualBanPresent, isTrue);
      expect(u.displayName, 'Inconnu');
    });

    test('fromServer : manuel (ban antérieur à 0094, sans date)', () {
      final BannedUser u = BannedUser.fromServer(<String, dynamic>{
        'id': _uuid,
        'display_name': 'Joueur',
        'ban_reason': 'Spam',
        'banned_at': null,
        'category': 'moderation',
        'origin': 'manual',
        'status': 'manuel',
        'ban_event_id': null,
      });
      expect(u.isAuto, isFalse);
      expect(u.status, 'manuel');
      expect(u.bannedAt, isNull);
      expect(u.reason, 'Spam');
    });
  });

  group('BannedChannel', () {
    test('ligne v94 (sans colonnes 0094) → défauts', () {
      final BannedChannel c = BannedChannel.fromJson(<String, dynamic>{
        'id': 3,
        'handle': 'chaine',
        'channel_id': null,
        'reason': 'Motif',
        'created_at': '2026-09-01T00:00:00+00:00',
      });
      expect(c.platform, 'youtube');
      expect(c.origin, 'manual');
      expect(c.category, 'moderation');
      expect(c.status, 'manuel');
      expect(c.banEventId, isNull);
      expect(c.manualEventId, isNull);
      expect(c.isAuto, isFalse);
      expect(c.isConverted, isFalse);
      expect(c.hasManualIntent, isFalse);
      expect(c.displayLabel, '@chaine');
      expect(c.displayHandle, '@chaine');
      expect(c.channelKey, 'chaine');
    });

    test('entrée auto YouTube → « YouTube · UC… », isAuto', () {
      final BannedChannel c = BannedChannel.fromJson(<String, dynamic>{
        'id': 4,
        'handle': 'auto:UCabcdefghijklmnopqrstuv',
        'channel_id': 'UCabcdefghijklmnopqrstuv',
        'platform': 'youtube',
        'origin': 'auto',
        'category': 'injection_ia',
        'status': 'confirme',
        'ban_event_id': 10,
        'manual_event_id': null,
      });
      expect(c.isAuto, isTrue);
      expect(c.isConfirmed, isTrue);
      expect(c.isConverted, isFalse);
      expect(c.channelKey, 'UCabcdefghijklmnopqrstuv');
      expect(c.displayLabel, 'YouTube · UCabcdefghijklmnopqrstuv');
      expect(c.banEventId, 10);
    });

    test('entrée auto RUTUBE et bilibili', () {
      final BannedChannel r = BannedChannel.fromJson(<String, dynamic>{
        'id': 5,
        'handle': 'auto:rutube:abc123',
        'channel_id': 'rutube:abc123',
        'platform': 'rutube',
        'origin': 'auto',
        'status': 'en_revue',
        'ban_event_id': 11,
      });
      expect(r.displayLabel, 'RUTUBE · rutube:abc123');
      final BannedChannel b = BannedChannel.fromJson(<String, dynamic>{
        'id': 6,
        'handle': 'auto:bili:12345',
        'channel_id': 'bili:12345',
        'platform': 'bilibili',
        'origin': 'auto',
        'status': 'en_revue',
        'ban_event_id': 12,
      });
      expect(b.displayLabel, 'bilibili · bili:12345');
    });

    test('entrée convertie (origin manual, handle auto:…) → isConverted', () {
      final BannedChannel c = BannedChannel.fromJson(<String, dynamic>{
        'id': 7,
        'handle': 'auto:UCabcdefghijklmnopqrstuv',
        'channel_id': 'UCabcdefghijklmnopqrstuv',
        'platform': 'youtube',
        'origin': 'manual',
        'status': 'manuel',
      });
      expect(c.isAuto, isFalse);
      expect(c.isConverted, isTrue);
      expect(c.displayLabel, 'YouTube · UCabcdefghijklmnopqrstuv');
    });

    test('intention manuelle enregistrée', () {
      final BannedChannel c = BannedChannel.fromJson(<String, dynamic>{
        'id': 8,
        'handle': 'auto:UCabcdefghijklmnopqrstuv',
        'origin': 'auto',
        'status': 'en_revue',
        'manual_event_id': 20,
      });
      expect(c.hasManualIntent, isTrue);
      expect(c.manualEventId, 20);
    });

    test('BanChannelReport sans result → applied', () {
      final BanChannelReport r = BanChannelReport.fromJson(<String, dynamic>{
        'banned': <String, dynamic>{'id': 1, 'handle': 'chaine'},
        'purged': 2,
        'published': <Object?>[],
        'published_via': 'suggestions-accepted',
      });
      expect(r.result, 'applied');
      expect(r.purged, 2);
      expect(r.banned.handle, 'chaine');
    });

    test('BanChannelReport : champs de mauvais type tolérés', () {
      final BanChannelReport r = BanChannelReport.fromJson(<String, dynamic>{
        'banned': <Object?>[],
        'purged': 'x',
        'published': <String, dynamic>{},
        'result': 'updated',
      });
      expect(r.result, 'updated');
      expect(r.purged, 0);
      expect(r.published, isEmpty);
      expect(r.banned.id, 0);
    });
  });

  group('Catégories de ban (D4)', () {
    const List<BanCategory> server = <BanCategory>[
      BanCategory(
        code: 'moderation',
        labelFr: 'Modération',
        autoAllowed: false,
      ),
      BanCategory(code: 'spam', labelFr: 'Spam', autoAllowed: false),
      BanCategory(code: 'abus', labelFr: 'Abus', autoAllowed: false),
      BanCategory(
        code: 'injection_ia',
        labelFr: 'Injection IA',
        autoAllowed: true,
      ),
      BanCategory(code: 'autre', labelFr: 'Autre', autoAllowed: false),
    ];

    test('fromJson tolérant', () {
      expect(BanCategory.fromJson(null), isNull);
      expect(BanCategory.fromJson(<String, dynamic>{'code': ''}), isNull);
      expect(
        BanCategory.fromJson(<String, dynamic>{'code': 'spam'}),
        const BanCategory(code: 'spam', labelFr: 'spam', autoAllowed: false),
      );
      expect(
        BanCategory.fromJson(<String, dynamic>{
          'code': 'injection_ia',
          'label_fr': 'Injection IA',
          'auto_allowed': true,
        })?.autoAllowed,
        isTrue,
      );
    });

    test('manualBanCategories : 4 catégories, ordre serveur, sans '
        'Injection IA', () {
      expect(
        manualBanCategories(server).map((BanCategory c) => c.code),
        <String>['moderation', 'spam', 'abus', 'autre'],
      );
    });

    test('manualBanCategories : injection_ia exclue même non auto', () {
      final List<BanCategory> r = manualBanCategories(const <BanCategory>[
        BanCategory(code: 'injection_ia', labelFr: 'IA', autoAllowed: false),
        BanCategory(code: 'spam', labelFr: 'Spam', autoAllowed: false),
        BanCategory(code: 'spam', labelFr: 'Doublon', autoAllowed: false),
      ]);
      expect(r.map((BanCategory c) => c.labelFr), <String>['Spam']);
    });

    test('manualBanCategories : liste vide ou toutes auto → repli', () {
      expect(
        manualBanCategories(const <BanCategory>[]),
        kManualBanCategoriesFallback,
      );
      expect(
        manualBanCategories(const <BanCategory>[
          BanCategory(code: 'injection_ia', labelFr: 'IA', autoAllowed: true),
        ]),
        kManualBanCategoriesFallback,
      );
      expect(
        kManualBanCategoriesFallback.first.code,
        kDefaultManualBanCategory,
      );
    });

    test('banCategoryLabel : connue, repli, injection_ia, brut, absent', () {
      expect(banCategoryLabel('spam', server), 'Spam');
      expect(
        banCategoryLabel('spam', const <BanCategory>[
          BanCategory(code: 'spam', labelFr: 'Pourriel', autoAllowed: false),
        ]),
        'Pourriel',
      );
      expect(banCategoryLabel('abus'), 'Abus');
      expect(banCategoryLabel('injection_ia'), 'Injection IA');
      expect(banCategoryLabel('nouvelle'), 'nouvelle');
      expect(banCategoryLabel(null), '—');
      expect(banCategoryLabel(''), '—');
    });
  });
}
