// Tests purs (VM) de la pagination SERVEUR des abonnés Plus (migration 0085,
// routes EF subscriptions/list + subscriptions/stats) : construction de la
// requête, lecture de la réponse, équivalent local (aperçu), compteurs,
// indicateurs « Plus » des auteurs, corps d'écriture « champs fournis
// uniquement ». Aucune dépendance dart:html.

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/plus_user.dart';
import 'package:mgt_admin/domain/models/suggestion_author.dart';
import 'package:mgt_admin/domain/plus_paging.dart';

PlusUser _user(
  String id, {
  String name = 'Joueur',
  String plan = 'monthly',
  bool active = true,
  String source = 'admin',
  DateTime? startedAt,
}) => PlusUser(
  id: id,
  displayName: name,
  plan: plan,
  startedAt: startedAt ?? DateTime.utc(2026, 1, 1),
  active: active,
  source: source,
);

void main() {
  group('PlusPageQuery.toRequestBody', () {
    test('défauts : page 0, 100 par page, plus récents d\'abord', () {
      expect(const PlusPageQuery().toRequestBody(), <String, dynamic>{
        'page': 0,
        'pageSize': 100,
        'sort': 'started_at',
        'ascending': false,
      });
    });

    test('bornes et normalisation (miroir du serveur)', () {
      final Map<String, dynamic> body = const PlusPageQuery(
        page: -3,
        pageSize: 5000,
        search: '  Nox  ',
        status: 'expired',
        source: 'manual',
        sort: 'email; drop table',
        ascending: true,
      ).toRequestBody();
      expect(body['page'], 0);
      expect(body['pageSize'], kPlusMaxPageSize);
      expect(body['search'], 'Nox');
      expect(body['status'], 'inactive');
      expect(body['source'], 'admin');
      expect(body['sort'], 'started_at');
      expect(body['ascending'], isTrue);
      expect(const PlusPageQuery(pageSize: 0).toRequestBody()['pageSize'], 1);
    });

    test('filtres inconnus ou vides → clés absentes (= tous)', () {
      final Map<String, dynamic> body = const PlusPageQuery(
        search: '   ',
        status: 'whatever',
        source: 'play',
      ).toRequestBody();
      expect(body.containsKey('search'), isFalse);
      expect(body.containsKey('status'), isFalse);
      expect(body.containsKey('source'), isFalse);
    });

    test('recherche tronquée à 100 caractères sans couper une paire', () {
      final String long = 'é' * 150;
      expect(PlusPageQuery(search: long).normalizedSearch.length, 100);
      final String emojis = '🎮' * 120; // 2 unités UTF-16 par emoji
      final String cut = PlusPageQuery(search: emojis).normalizedSearch;
      expect(cut.runes.length, kPlusSearchMaxLength);
      expect(cut, '🎮' * 100);
    });
  });

  group('parsePlusPage (réponse EF subscriptions/list)', () {
    test('lignes serveur → PlusUser + total exact', () {
      final PlusPage page = parsePlusPage(<String, dynamic>{
        'subscriptions': [
          {
            'user_id': '11111111-1111-1111-1111-111111111111',
            'plan': 'yearly',
            'is_active': true,
            'started_at': '2026-08-01T10:00:00+00:00',
            'expires_at': '2027-08-01T10:00:00+00:00',
            'updated_at': '2026-08-02T10:00:00+00:00',
            'source': 'google_verified',
            'display_name': 'Nox',
            'is_banned': true,
          },
          {
            'user_id': '22222222-2222-2222-2222-222222222222',
            'plan': 'monthly',
            'is_active': false,
            'started_at': '2026-07-01T10:00:00+00:00',
            'expires_at': null,
            'source': 'admin',
            'display_name': null,
            'is_banned': false,
          },
          {'plan': 'monthly'}, // sans identifiant → ignorée
        ],
        'total': 250,
        'page': 0,
        'pageSize': 100,
      });
      expect(page.total, 250);
      expect(page.items, hasLength(2));
      final PlusUser a = page.items.first;
      expect(a.id, '11111111-1111-1111-1111-111111111111');
      expect(a.displayName, 'Nox');
      expect(a.plan, 'yearly');
      expect(a.active, isTrue);
      expect(a.isGoogle, isTrue);
      expect(a.isVerified, isTrue);
      expect(a.isBanned, isTrue);
      expect(a.startedAt, DateTime.utc(2026, 8, 1, 10));
      expect(a.expiresAt, DateTime.utc(2027, 8, 1, 10));
      final PlusUser b = page.items.last;
      expect(b.displayName, 'Inconnu');
      expect(b.active, isFalse);
      expect(b.expiresAt, isNull);
      expect(b.isBanned, isFalse);
    });

    test('total absent (EF antérieure) → nombre de lignes reçues', () {
      final PlusPage page = parsePlusPage(<String, dynamic>{
        'subscriptions': [
          {'user_id': 'a', 'plan': 'monthly'},
        ],
      });
      expect(page.total, 1);
      expect(parsePlusPage(const <String, dynamic>{}).items, isEmpty);
    });
  });

  test('plusPageCount : au moins une page, arrondi supérieur', () {
    expect(plusPageCount(0, 100), 1);
    expect(plusPageCount(100, 100), 1);
    expect(plusPageCount(101, 100), 2);
    expect(plusPageCount(250, 100), 3);
    expect(plusPageCount(250000, 100), 2500);
  });

  group('applyPlusQueryLocally (aperçu local = contrat serveur)', () {
    // 250 abonnés : dates distinctes (le n° i commence i jours après le 1er
    // janvier), 1 sur 5 inactif, 1 sur 3 Google, 1 sur 4 annuel.
    final List<PlusUser> all = List<PlusUser>.generate(250, (int i) {
      final String id = 'id-${i.toString().padLeft(4, '0')}';
      return _user(
        id,
        name: 'Joueur $i',
        plan: i % 4 == 0 ? 'yearly' : 'monthly',
        active: i % 5 != 0,
        source: i % 3 == 0
            ? (i.isEven ? 'google' : 'google_verified')
            : 'admin',
        startedAt: DateTime.utc(2026, 1, 1).add(Duration(days: i)),
      );
    });

    test('pages de 100 + total exact, page au-delà de la fin vide', () {
      final PlusPage p0 = applyPlusQueryLocally(all, const PlusPageQuery());
      expect(p0.total, 250);
      expect(p0.items, hasLength(100));
      // Tri par défaut : plus récents d'abord.
      expect(p0.items.first.id, 'id-0249');
      final PlusPage p2 = applyPlusQueryLocally(
        all,
        const PlusPageQuery(page: 2),
      );
      expect(p2.items, hasLength(50));
      expect(p2.items.last.id, 'id-0000');
      final PlusPage p3 = applyPlusQueryLocally(
        all,
        const PlusPageQuery(page: 3),
      );
      expect(p3.items, isEmpty);
      expect(p3.total, 250);
    });

    test('pages disjointes et complètes (aucun doublon, aucun oubli)', () {
      final Set<String> seen = <String>{};
      for (var p = 0; p < 3; p++) {
        for (final PlusUser u in applyPlusQueryLocally(
          all,
          PlusPageQuery(page: p),
        ).items) {
          expect(seen.add(u.id), isTrue, reason: 'doublon ${u.id}');
        }
      }
      expect(seen, hasLength(250));
    });

    test('filtres statut et source (« Manuel » = tout sauf google*)', () {
      final int inactive = all.where((PlusUser u) => !u.active).length;
      expect(
        applyPlusQueryLocally(
          all,
          const PlusPageQuery(status: 'inactive'),
        ).total,
        inactive,
      );
      expect(
        applyPlusQueryLocally(all, const PlusPageQuery(status: 'active')).total,
        250 - inactive,
      );
      final PlusPage google = applyPlusQueryLocally(
        all,
        const PlusPageQuery(source: 'google'),
      );
      expect(google.items.every((PlusUser u) => u.isGoogle), isTrue);
      final PlusPage manual = applyPlusQueryLocally(
        all,
        const PlusPageQuery(source: 'admin'),
      );
      expect(google.total + manual.total, 250);
    });

    test(
      'recherche : pseudo « contient » (casse ignorée) ou préfixe d\'id',
      () {
        final List<PlusUser> users = <PlusUser>[
          _user('abc12345-0000', name: 'Zelda'),
          _user('ffff0000-0000', name: 'Link ABC'),
          _user('99990000-0000', name: 'Ganon'),
        ];
        final PlusPage byName = applyPlusQueryLocally(
          users,
          const PlusPageQuery(search: 'abc'),
        );
        // « abc » : préfixe hexadécimal de la 1re ET pseudo de la 2e.
        expect(byName.items.map((PlusUser u) => u.id).toSet(), {
          'abc12345-0000',
          'ffff0000-0000',
        });
        expect(
          applyPlusQueryLocally(
            users,
            const PlusPageQuery(search: 'GANON'),
          ).items.single.id,
          '99990000-0000',
        );
        // Préfixe uniquement (pas « contient ») pour l'identifiant.
        expect(
          applyPlusQueryLocally(
            users,
            const PlusPageQuery(search: '0000'),
          ).total,
          0,
        );
      },
    );

    test('tris : pseudo, formule, statut + départage stable', () {
      final List<PlusUser> users = <PlusUser>[
        _user('b', name: 'bob', plan: 'yearly', active: false),
        _user('a', name: 'Alice', plan: 'monthly'),
        _user('c', name: 'alice', plan: 'monthly', active: false),
      ];
      List<String> ids(PlusPageQuery q) => applyPlusQueryLocally(
        users,
        q,
      ).items.map((PlusUser u) => u.id).toList();
      // Pseudo croissant, casse ignorée ; égalité → id croissant.
      expect(ids(const PlusPageQuery(sort: 'display_name', ascending: true)), [
        'a',
        'c',
        'b',
      ]);
      expect(ids(const PlusPageQuery(sort: 'plan')), ['b', 'a', 'c']);
      // Statut croissant : inactifs d'abord.
      expect(ids(const PlusPageQuery(sort: 'status', ascending: true)), [
        'b',
        'c',
        'a',
      ]);
    });
  });

  group('PlusStats', () {
    test('fromJson (réponse subscriptions/stats), tolérant', () {
      final PlusStats s = PlusStats.fromJson(<String, dynamic>{
        'total': 12,
        'active': 10,
        'by_plan': {'monthly': 11, 'yearly': 1},
        'by_source': {'admin': 9, 'reward': 1, 'google_verified': 2},
      });
      expect(s.total, 12);
      expect(s.active, 10);
      expect(s.byPlan['yearly'], 1);
      expect(s.bySource['google_verified'], 2);
      final PlusStats empty = PlusStats.fromJson(const <String, dynamic>{
        'by_plan': 'x',
      });
      expect(empty.total, 0);
      expect(empty.byPlan, isEmpty);
    });

    test('fromUsers (aperçu local)', () {
      final PlusStats s = PlusStats.fromUsers(<PlusUser>[
        _user('a'),
        _user('b', active: false, plan: 'yearly', source: 'google'),
      ]);
      expect(s.total, 2);
      expect(s.active, 1);
      expect(s.byPlan, {'monthly': 1, 'yearly': 1});
      expect(s.bySource, {'admin': 1, 'google': 1});
    });
  });

  group('PlusFlags (badge PLUS sans liste complète)', () {
    test(
      'inconnu → false ; indicateur serveur ; action de session prioritaire',
      () {
        final PlusFlags flags = PlusFlags();
        expect(flags.isPlus('u1'), isFalse);
        flags.absorbAuthors(const <SuggestionAuthor>[
          SuggestionAuthor(id: 'u1', displayName: 'A', isPlus: true),
          SuggestionAuthor(id: 'u2', displayName: 'B'),
        ]);
        expect(flags.isPlus('u1'), isTrue);
        expect(flags.isPlus('u2'), isFalse);
        // Suspension confirmée dans la session : prime sur un indicateur
        // serveur lu AVANT l'action.
        flags.setSessionValue('u1', false);
        flags.absorb('u1', true);
        expect(flags.isPlus('u1'), isFalse);
        // Retour arrière (échec serveur) → l'indicateur serveur reprend la main.
        flags.setSessionValue('u1', null);
        expect(flags.isPlus('u1'), isTrue);
        expect(flags.sessionValue('u1'), isNull);
        flags.absorb('', true); // identifiant vide ignoré
        expect(flags.isPlus(''), isFalse);
      },
    );
  });

  group('SupabaseSync.subscriptionUpsertBody (champs fournis uniquement)', () {
    const String id = '11111111-1111-1111-1111-111111111111';

    test('suspension : seul is_active (échéance Google conservée)', () {
      expect(
        SupabaseSync.subscriptionUpsertBody(userId: id, isActive: false),
        <String, dynamic>{'user_id': id, 'is_active': false},
      );
    });

    test('changement de formule : seul plan', () {
      expect(
        SupabaseSync.subscriptionUpsertBody(userId: id, plan: 'yearly'),
        <String, dynamic>{'user_id': id, 'plan': 'yearly'},
      );
    });

    test('octroi manuel : actif, début fourni, échéance effacée (null)', () {
      final Map<String, dynamic> body = SupabaseSync.subscriptionUpsertBody(
        userId: id,
        plan: 'monthly',
        isActive: true,
        startedAt: DateTime.utc(2026, 9, 25, 8, 30),
        clearExpiry: true,
      );
      expect(body['started_at'], '2026-09-25T08:30:00.000Z');
      expect(body.containsKey('expires_at'), isTrue);
      expect(body['expires_at'], isNull);
      expect(
        body.containsKey('source'),
        isFalse,
        reason: 'la source n\'est jamais envoyée',
      );
    });

    test('échéance explicite prioritaire sur clearExpiry', () {
      final Map<String, dynamic> body = SupabaseSync.subscriptionUpsertBody(
        userId: id,
        expiresAt: DateTime.utc(2027, 1, 1),
        clearExpiry: true,
      );
      expect(body['expires_at'], '2027-01-01T00:00:00.000Z');
    });
  });

  group('author_is_plus (suggestions/list)', () {
    test('mapSuggestionRows → SuggestionAuthor.isPlus', () {
      final rows = <dynamic>[
        {
          'id': 's1',
          'url': 'https://youtu.be/a',
          'status': 'pending',
          'shared_at': '2026-09-01T00:00:00Z',
          'author_id': 'u1',
          'author': {'id': 'u1', 'display_name': 'Nox'},
          'author_is_plus': true,
        },
        {
          'id': 's2',
          'url': 'https://youtu.be/b',
          'status': 'pending',
          'shared_at': '2026-09-01T00:00:00Z',
          'author_id': 'u2',
          'author': null,
        },
      ];
      final suggestions = SupabaseSync.mapSuggestionRows(rows);
      expect(suggestions.first.author.isPlus, isTrue);
      expect(suggestions.first.author.displayName, 'Nox');
      expect(
        suggestions.last.author.isPlus,
        isFalse,
        reason: 'indicateur absent (EF antérieure) → false',
      );
      expect(suggestions.last.author.id, 'u2');
    });

    test('SuggestionAuthor : aller-retour JSON du cache local', () {
      const SuggestionAuthor a = SuggestionAuthor(
        id: 'u1',
        displayName: 'Nox',
        isPlus: true,
      );
      expect(SuggestionAuthor.fromJson(a.toJson()).isPlus, isTrue);
      expect(
        SuggestionAuthor.fromJson(const <String, dynamic>{
          'id': 'u2',
          'displayName': 'B',
        }).isPlus,
        isFalse,
      );
    });
  });

  group('PlusUser', () {
    test('aller-retour JSON local avec échéance et bannissement', () {
      final PlusUser u = PlusUser(
        id: 'u1',
        displayName: 'Nox',
        plan: 'yearly',
        startedAt: DateTime.utc(2026, 1, 1),
        source: 'google',
        expiresAt: DateTime.utc(2027, 1, 1),
        isBanned: true,
      );
      final PlusUser back = PlusUser.fromJson(u.toJson());
      expect(back.expiresAt, DateTime.utc(2027, 1, 1));
      expect(back.isBanned, isTrue);
      expect(back.copyWith(active: false).expiresAt, DateTime.utc(2027, 1, 1));
    });

    test('isExpiredAt : échéance dépassée uniquement', () {
      final DateTime now = DateTime.utc(2026, 9, 25);
      expect(_user('a').isExpiredAt(now), isFalse, reason: 'sans échéance');
      final PlusUser past = PlusUser(
        id: 'b',
        displayName: 'B',
        plan: 'monthly',
        startedAt: DateTime.utc(2026, 1, 1),
        expiresAt: DateTime.utc(2026, 2, 1),
      );
      expect(past.isExpiredAt(now), isTrue);
      final PlusUser future = PlusUser(
        id: 'c',
        displayName: 'C',
        plan: 'monthly',
        startedAt: DateTime.utc(2026, 1, 1),
        expiresAt: DateTime.utc(2026, 12, 1),
      );
      expect(future.isExpiredAt(now), isFalse);
    });
  });

  test('formatCount : séparateur de milliers français', () {
    expect(formatCount(0), '0');
    expect(formatCount(999), '999');
    expect(formatCount(100000), '100 000');
    expect(formatCount(1234567), '1 234 567');
    expect(formatCount(-4200), '-4 200');
  });
}
