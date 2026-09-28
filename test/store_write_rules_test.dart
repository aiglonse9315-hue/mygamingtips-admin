// Tests purs (VM) des règles d'écriture du StoreController (P4b-3, lot L4,
// conception §5) : cible du dialogue « Bannir un compte », résultats et
// échecs d'un ban et de l'envoi partiel d'un jeu, fusion de la liste des
// bannis relue avec le cache, rangement actifs / inactifs d'un jeu ; plus les
// deux retraits ponctuels de SupabaseSync du lot (upsertGame réservé à la
// création). Le contrôleur lui-même importe dart:html (non testable en VM) ;
// aucune dépendance dart:html ici.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:mgt_admin/domain/models/banned_user.dart';
import 'package:mgt_admin/domain/models/game.dart';
import 'package:mgt_admin/domain/moderation_actions.dart';
import 'package:mgt_admin/domain/store_write_rules.dart';
import 'package:mgt_admin/domain/write_outcome.dart';

import 'support/http_fixtures.dart';

const String _a = '0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60';
const String _b = '1c8d7f2b-3e4f-4d6c-9b0f-2e3d4c5b6a71';
const String _c = '2d9e8a3c-4f5a-4e7d-8c1a-3f4e5d6c7b82';

Game _game(
  String id,
  String name, {
  bool active = true,
  String? publisher,
  String? cover,
  String? date,
}) => Game(
  id: id,
  name: name,
  publisher: publisher,
  coverUrl: cover,
  releaseDate: date,
  active: active,
  createdAt: DateTime.utc(2026, 1, 1),
);

void main() {
  group('parseBanTarget (dialogue « Bannir un compte »)', () {
    test('vide ou espaces → « Saisissez… »', () {
      for (final String s in <String>['', '   ', '\n']) {
        final BanTarget t = parseBanTarget(s);
        expect(t.error, "Saisissez l'e-mail ou l'identifiant du compte.");
        expect(t.userId, isNull);
        expect(t.email, isNull);
      }
    });

    test('UUID (espaces autour, majuscules) → ban direct, coupé', () {
      expect(parseBanTarget('  $_a ').userId, _a);
      expect(parseBanTarget(_a.toUpperCase()).userId, _a.toUpperCase());
      expect(parseBanTarget(_a).email, isNull);
      expect(parseBanTarget(_a).error, isNull);
    });

    test('ni UUID ni e-mail → « E-mail ou identifiant invalide. »', () {
      for (final String s in <String>['abc', 'g-123', 'manual-1727', '0b7c']) {
        expect(parseBanTarget(s).error, 'E-mail ou identifiant invalide.');
      }
    });

    test('e-mail → résolu par le serveur (coupé, casse gardée)', () {
      final BanTarget t = parseBanTarget(' P1@Exemple.TEST ');
      expect(t.email, 'P1@Exemple.TEST');
      expect(t.userId, isNull);
      expect(t.error, isNull);
    });
  });

  group('banSuccessOutcome (profiles/ban 200)', () {
    test('applied → succès sans avertissement', () {
      final WriteOutcome o = banSuccessOutcome(
        result: 'applied',
        replayed: false,
      );
      expect(o.ok, isTrue);
      expect(o.notice, isNull);
    });

    test('already_banned → « Déjà banni : … conservés. »', () {
      final WriteOutcome o = banSuccessOutcome(
        result: 'already_banned',
        replayed: false,
      );
      expect(o.ok, isTrue);
      expect(o.notice, 'Déjà banni : motif et catégorie existants conservés.');
    });

    test('already_banned après rejeu → message de rejeu', () {
      final WriteOutcome o = banSuccessOutcome(
        result: 'already_banned',
        replayed: true,
      );
      expect(o.ok, isTrue);
      expect(o.notice, kReplayNoticeMessage);
    });

    test('applied après rejeu, résultat illisible → succès simple', () {
      expect(
        banSuccessOutcome(result: 'applied', replayed: true).notice,
        isNull,
      );
      expect(banSuccessOutcome(result: '', replayed: false).ok, isTrue);
    });
  });

  group('banFailureOutcome (profiles/ban en erreur, 401 exclu)', () {
    test('issue inconnue → message fixe, uncertain', () {
      final WriteOutcome o = banFailureOutcome(
        statusCode: 502,
        message: 'Erreur serveur (HTTP 502).',
        uncertain: true,
      );
      expect(o.ok, isFalse);
      expect(o.uncertain, isTrue);
      expect(o.message, 'Réponse non reçue : la liste des bannis a été relue.');
      expect(
        banFailureOutcome(message: 'x', uncertain: true).message,
        kBanUncertainMessage,
      );
    });

    test('404 → « Profil introuvable. »', () {
      final WriteOutcome o = banFailureOutcome(
        statusCode: 404,
        message: 'autre texte',
        uncertain: false,
      );
      expect(o.message, 'Profil introuvable.');
      expect(o.uncertain, isFalse);
      expect(o.sessionExpired, isFalse);
    });

    test('400 / 403 → message du serveur tel quel', () {
      expect(
        banFailureOutcome(
          statusCode: 400,
          message: 'category inconnue.',
          uncertain: false,
        ).message,
        'category inconnue.',
      );
      expect(
        banFailureOutcome(
          statusCode: 403,
          message: 'Accès refusé (403)',
          uncertain: false,
        ).message,
        'Accès refusé (403)',
      );
    });
  });

  group('gamePatchFailureOutcome (route games en erreur, 401 exclu)', () {
    test('404 → jeu supprimé entre-temps', () {
      expect(
        gamePatchFailureOutcome(
          statusCode: 404,
          message: 'Jeu introuvable.',
          uncertain: false,
        ).message,
        'Jeu introuvable : il a été supprimé entre-temps.',
      );
    });

    test('400 → message du serveur', () {
      expect(
        gamePatchFailureOutcome(
          statusCode: 400,
          message: 'release_date invalide (AAAA-MM-JJ ou null).',
          uncertain: false,
        ).message,
        'release_date invalide (AAAA-MM-JJ ou null).',
      );
    });

    test('issue inconnue → listes relues, uncertain', () {
      final WriteOutcome o = gamePatchFailureOutcome(
        message: 'ClientException',
        uncertain: true,
      );
      expect(o.message, 'Réponse non reçue : la liste des jeux a été relue.');
      expect(o.uncertain, isTrue);
    });

    test('messages fixes du lot', () {
      expect(
        kGameTempIdMessage,
        'Jeu en cours de création : réessayez après la synchronisation.',
      );
      expect(
        kBanNotUuidMessage,
        "Compte non bannissable : identifiant non UUID (partage d'un bot ?).",
      );
      expect(kBanEmailUnknownMessage, 'Aucun compte avec cet e-mail.');
    });
  });

  group('mergeBannedWithCache (banned-list relue)', () {
    test('liste SERVEUR seule : entrées locales non UUID abandonnées', () {
      final List<BannedUser> merged = mergeBannedWithCache(
        <BannedUser>[
          BannedUser.fromServer(<String, dynamic>{
            'id': _a,
            'display_name': 'Joueur A',
            'origin': 'auto',
            'status': 'en_revue',
            'category': 'injection_ia',
            'ban_event_id': 42,
            'manual_ban_present': true,
            'banned_at': '2026-09-28T10:00:00+00:00',
          }),
        ],
        const <BannedUser>[
          BannedUser(id: 'g_user_666', displayName: 'Démo'),
          BannedUser(id: 'manual-1727000000000', displayName: 'Fictif'),
          BannedUser(id: _b, displayName: 'Levé ailleurs'),
        ],
      );
      expect(merged.map((BannedUser b) => b.id), <String>[_a]);
      final BannedUser a = merged.single;
      expect(a.displayName, 'Joueur A');
      expect(a.isAutoInReview, isTrue);
      expect(a.category, 'injection_ia');
      expect(a.banEventId, 42);
      expect(a.manualBanPresent, isTrue);
      expect(a.bannedAt, DateTime.utc(2026, 9, 28, 10));
    });

    test('e-mail et avatar repris du cache de même id', () {
      final List<BannedUser> merged = mergeBannedWithCache(
        <BannedUser>[
          BannedUser.fromServer(<String, dynamic>{
            'id': _a,
            'display_name': 'Nom serveur',
            'ban_reason': 'Spam',
            'category': 'spam',
          }),
          BannedUser.fromServer(<String, dynamic>{'id': _b}),
        ],
        const <BannedUser>[
          BannedUser(
            id: _a,
            displayName: 'Ancien nom',
            email: 'a@exemple.test',
            avatarUrl: 'https://exemple.test/a.png',
            reason: 'Ancien motif',
          ),
          BannedUser(id: _b, displayName: 'B'),
        ],
      );
      expect(merged, hasLength(2));
      expect(merged[0].email, 'a@exemple.test');
      expect(merged[0].avatarUrl, 'https://exemple.test/a.png');
      expect(merged[0].displayName, 'Nom serveur');
      expect(merged[0].reason, 'Spam');
      expect(merged[0].category, 'spam');
      expect(merged[1].displayName, 'Inconnu');
      expect(merged[1].email, isNull);
    });

    test('ordre du serveur conservé ; liste serveur vide → liste vide', () {
      final List<BannedUser> merged = mergeBannedWithCache(<BannedUser>[
        BannedUser.fromServer(<String, dynamic>{'id': _c}),
        BannedUser.fromServer(<String, dynamic>{'id': _a}),
      ], const <BannedUser>[]);
      expect(merged.map((BannedUser b) => b.id), <String>[_c, _a]);
      expect(
        mergeBannedWithCache(const <BannedUser>[], const <BannedUser>[
          BannedUser(id: _a, displayName: 'A'),
        ]),
        isEmpty,
      );
    });
  });

  test('unbanRemovesLocalEntry : seulement lifted / not_banned', () {
    expect(unbanRemovesLocalEntry(UnbanKind.lifted), isTrue);
    expect(unbanRemovesLocalEntry(UnbanKind.notBanned), isTrue);
    for (final UnbanKind k in <UnbanKind>[
      UnbanKind.autoBan,
      UnbanKind.notFound,
      UnbanKind.failure,
      UnbanKind.sessionExpired,
    ]) {
      expect(unbanRemovesLocalEntry(k), isFalse, reason: '$k');
    }
  });

  group('applyGamePatch (aperçu)', () {
    final Game g = _game(
      'g-eldenring',
      'Elden Ring',
      publisher: 'FromSoftware',
      cover: 'https://exemple.test/c.jpg',
      date: '2022-02-25',
    );

    test('patch vide → jeu inchangé', () {
      final Game r = applyGamePatch(g, const <String, Object?>{});
      expect(r.name, g.name);
      expect(r.publisher, g.publisher);
      expect(r.coverUrl, g.coverUrl);
      expect(r.releaseDate, g.releaseDate);
      expect(r.active, g.active);
    });

    test('clé présente à null = effacement', () {
      final Game r = applyGamePatch(g, const <String, Object?>{
        'publisher': null,
        'cover_url': null,
        'release_date': null,
      });
      expect(r.publisher, isNull);
      expect(r.coverUrl, isNull);
      expect(r.releaseDate, isNull);
      expect(r.name, 'Elden Ring');
    });

    test('valeurs écrites ; id et date de création gardés', () {
      final Game r = applyGamePatch(g, const <String, Object?>{
        'name': 'Elden Ring NR',
        'publisher': 'Bandai',
        'release_date': '2025-05-30',
        'active': false,
      });
      expect(r.id, 'g-eldenring');
      expect(r.createdAt, g.createdAt);
      expect(r.name, 'Elden Ring NR');
      expect(r.publisher, 'Bandai');
      expect(r.releaseDate, '2025-05-30');
      expect(r.active, isFalse);
      expect(r.coverUrl, 'https://exemple.test/c.jpg');
    });

    test('clé inconnue, mauvais type, nom vide → ignorés', () {
      final Game r = applyGamePatch(g, const <String, Object?>{
        'id': 'autre',
        'name': '  ',
        'active': 'non',
        'publisher': 12,
      });
      expect(r.id, 'g-eldenring');
      expect(r.name, 'Elden Ring');
      expect(r.active, isTrue);
      expect(r.publisher, 'FromSoftware');
    });
  });

  group('placeGameRow (ligne serveur = vérité)', () {
    final List<Game> active = <Game>[_game(_a, 'Alpha'), _game(_b, 'bravo')];
    final List<Game> inactive = <Game>[_game(_c, 'Charlie', active: false)];

    test('désactivation : sort des actifs, entre dans les inactifs', () {
      final r = placeGameRow(
        active: active,
        inactive: inactive,
        id: _a,
        row: _game(_a, 'Alpha', active: false),
      );
      expect(r.active.map((Game g) => g.id), <String>[_b]);
      expect(r.inactive.map((Game g) => g.id), <String>[_a, _c]);
    });

    test('réactivation : sort des inactifs, entre dans les actifs (tri)', () {
      final r = placeGameRow(
        active: active,
        inactive: inactive,
        id: _c,
        row: _game(_c, 'Charlie'),
      );
      expect(r.active.map((Game g) => g.name), <String>[
        'Alpha',
        'bravo',
        'Charlie',
      ]);
      expect(r.inactive, isEmpty);
    });

    test('ligne modifiée remplace l\'ancienne (pas de doublon)', () {
      final r = placeGameRow(
        active: active,
        inactive: inactive,
        id: _b,
        row: _game(_b, 'Aaa', publisher: 'Nouveau'),
      );
      expect(r.active.map((Game g) => g.id), <String>[_b, _a]);
      expect(r.active.first.publisher, 'Nouveau');
      expect(r.inactive.map((Game g) => g.id), <String>[_c]);
    });

    test('création : l\'id temporaire est remplacé par la ligne UUID', () {
      final r = placeGameRow(
        active: <Game>[...active, _game('g-1727', 'Delta')],
        inactive: inactive,
        id: 'g-1727',
        row: _game(
          '3e0f9b4d-5a6b-4f8e-9d2b-4a5f6e7d8c93',
          'Delta',
          active: false,
        ),
      );
      expect(r.active.map((Game g) => g.id), <String>[_a, _b]);
      expect(r.inactive.map((Game g) => g.name), <String>['Charlie', 'Delta']);
    });

    test('404 (row null) → retiré des deux listes', () {
      final r1 = placeGameRow(active: active, inactive: inactive, id: _a);
      expect(r1.active.map((Game g) => g.id), <String>[_b]);
      expect(r1.inactive, hasLength(1));
      final r2 = placeGameRow(active: active, inactive: inactive, id: _c);
      expect(r2.active, hasLength(2));
      expect(r2.inactive, isEmpty);
    });
  });

  test('withoutInactiveIds : réconciliation du cache des actifs', () {
    final List<Game> kept = withoutInactiveIds(
      <Game>[_game(_a, 'A'), _game(_b, 'B'), _game('g-1', 'Local')],
      <Game>[_game(_b, 'B', active: false), _game(_c, 'C', active: false)],
    );
    expect(kept.map((Game g) => g.id), <String>[_a, 'g-1']);
  });

  test('compareGamesByName : casse ignorée', () {
    final List<Game> l = <Game>[
      _game(_a, 'zelda'),
      _game(_b, 'Alpha'),
      _game(_c, 'beta'),
    ]..sort(compareGamesByName);
    expect(l.map((Game g) => g.name), <String>['Alpha', 'beta', 'zelda']);
  });

  group('SupabaseSync.upsertGame (création seulement, lot L4)', () {
    late List<http.Request> seen;
    setUp(() => seen = <http.Request>[]);

    test('id temporaire → 6 clés envoyées (création)', () async {
      final Game created = await withMock(
        seen,
        (_) => jsonResponse(<String, dynamic>{
          'game': <String, dynamic>{
            'id': _a,
            'name': 'Nouveau',
            'publisher': null,
            'cover_url': null,
            'active': false,
            'release_date': null,
            'created_at': '2026-09-28T00:00:00+00:00',
          },
          'created': true,
        }),
        () => fakeSync().upsertGame(_game('g-1727', 'Nouveau', active: false)),
      );
      expect(isRoute(seen.single, 'games'), isTrue);
      expect(bodyOf(seen.single), <String, dynamic>{
        'id': 'g-1727',
        'name': 'Nouveau',
        'publisher': null,
        'cover_url': null,
        'release_date': null,
        'active': false,
      });
      expect(created.id, _a);
      expect(created.active, isFalse);
    });

    test(
      'UUID → AssertionError, aucune requête (mise à jour = patchGame)',
      () async {
        await expectLater(
          withMock(
            seen,
            (_) => jsonResponse(<String, dynamic>{}),
            () => fakeSync().upsertGame(_game(_a, 'Existant')),
          ),
          throwsA(isA<AssertionError>()),
        );
        expect(seen, isEmpty);
      },
    );
  });
}
