// Tests purs (VM) de l'édition des jeux (P4b-3, lot L3, conception §4.6) :
// date de sortie (normalisation + calendrier identique au serveur), envoi
// PARTIEL, validations de champ, confirmation de désactivation (D2),
// plafond de « Activer les jeux prêts ». `now` est injecté : aucun test ne
// dépend de la date du jour.

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/game_patch.dart';
import 'package:mgt_admin/domain/models/game.dart';

final DateTime _now = DateTime(2026, 9, 28);

Game _game({
  String name = 'Jeu',
  String? publisher,
  String? coverUrl,
  String? releaseDate,
  bool active = true,
}) => Game(
  id: '0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60',
  name: name,
  publisher: publisher,
  coverUrl: coverUrl,
  releaseDate: releaseDate,
  active: active,
  createdAt: DateTime.utc(2026, 1, 1),
);

/// Patch d'un formulaire rempli avec les valeurs du jeu, sauf celles données.
Map<String, Object?> _patch(
  Game g, {
  String? name,
  String? publisher,
  String? cover,
  String? releaseDateRaw,
  bool? active,
}) {
  final ReleaseDateInput date = parseReleaseDateInput(
    releaseDateRaw ?? g.releaseDate ?? '',
    now: _now,
    original: g.releaseDate,
  );
  expect(date.isValid, isTrue, reason: date.error);
  return buildGamePatch(
    g,
    name: name ?? g.name,
    publisher: publisher ?? g.publisher ?? '',
    cover: cover ?? g.coverUrl ?? '',
    releaseDate: date.value,
    active: active ?? g.active,
  );
}

void main() {
  group('parseReleaseDateInput', () {
    ReleaseDateInput p(String raw, {String? original}) =>
        parseReleaseDateInput(raw, now: _now, original: original);

    test('vide → null (effacement), sans erreur', () {
      expect(p('').isValid, isTrue);
      expect(p('').value, isNull);
      expect(p('   ').value, isNull);
    });

    test('AAAA, AAAA-MM, AAAA-MM-JJ complétés', () {
      expect(p('2023').value, '2023-01-01');
      expect(p('2023-11').value, '2023-11-01');
      expect(p('2023-11-10').value, '2023-11-10');
      expect(p(' 2024-02-29 ').value, '2024-02-29');
    });

    test('dates inexistantes', () {
      for (final String s in <String>[
        '2025-02-29',
        '2025-02-30',
        '2026-04-31',
        '2026-01-00',
      ]) {
        final ReleaseDateInput r = p(s);
        expect(r.isValid, isFalse, reason: s);
        expect(r.value, isNull, reason: s);
        expect(r.error, 'Date inexistante (ex. 30 février).', reason: s);
      }
    });

    test('mois invalide', () {
      expect(p('2026-13-01').error, 'Mois invalide.');
      expect(p('2026-00').error, 'Mois invalide.');
    });

    test('année hors bornes (1970 à an+2, now injecté)', () {
      expect(p('1969').error, 'Année hors bornes (1970 à 2028).');
      expect(p('2029').error, 'Année hors bornes (1970 à 2028).');
      expect(p('1970').value, '1970-01-01');
      expect(p('2028-12-31').value, '2028-12-31');
    });

    test('formats refusés', () {
      for (final String s in <String>[
        '2026-9-1',
        '27/09/2026',
        '2026-09-27T00:00:00Z',
        'abc',
      ]) {
        expect(
          p(s).error,
          'Date invalide : AAAA, AAAA-MM ou AAAA-MM-JJ.',
          reason: s,
        );
      }
    });

    test(
      'v2 (REG-03) : date stockée non modifiée → valide, aucun contrôle',
      () {
        final ReleaseDateInput r = p('2031-01-01', original: '2031-01-01');
        expect(r.isValid, isTrue);
        expect(r.value, '2031-01-01');
        expect(p(' 2031-01-01 ', original: '2031-01-01').value, '2031-01-01');
        // Modifiée : la borne s'applique.
        expect(
          p('2031-01-02', original: '2031-01-01').error,
          'Année hors bornes (1970 à 2028).',
        );
      },
    );
  });

  group('buildGamePatch', () {
    test('rien changé → {}', () {
      final Game g = _game(
        publisher: 'Éditeur',
        coverUrl: 'https://exemple.test/a.png',
        releaseDate: '2023-11-10',
      );
      expect(_patch(g), isEmpty);
    });

    test(
      'jeu daté 2031-01-01, date inchangée, éditeur modifié → {publisher} seul',
      () {
        final Game g = _game(publisher: 'Ancien', releaseDate: '2031-01-01');
        expect(_patch(g, publisher: 'Nouveau'), <String, Object?>{
          'publisher': 'Nouveau',
        });
      },
    );

    test('éditeur vidé → {publisher: null}', () {
      final Game g = _game(publisher: 'Éditeur');
      expect(_patch(g, publisher: ''), <String, Object?>{'publisher': null});
      expect(_patch(g, publisher: '   '), <String, Object?>{'publisher': null});
    });

    test('cache « » + saisie vide → {} ; espaces seuls → {}', () {
      final Game g = _game(publisher: '', coverUrl: '');
      expect(_patch(g, publisher: '', cover: ''), isEmpty);
      expect(_patch(g, publisher: '   ', cover: '  '), isEmpty);
      expect(_patch(_game(), publisher: '  ', cover: ' '), isEmpty);
    });

    test('date effacée d’un jeu daté → {release_date: null}', () {
      final Game g = _game(releaseDate: '2023-11-10');
      final Map<String, Object?> patch = _patch(g, releaseDateRaw: '');
      expect(patch, <String, Object?>{'release_date': null});
      expect(patch.containsKey('release_date'), isTrue);
    });

    test('date vide d’un jeu non daté → {}', () {
      expect(_patch(_game(), releaseDateRaw: ''), isEmpty);
    });

    test('date modifiée → valeur normalisée', () {
      expect(
        _patch(_game(releaseDate: '2023-11-10'), releaseDateRaw: '2024'),
        <String, Object?>{'release_date': '2024-01-01'},
      );
    });

    test('bascule seule → {active: x}', () {
      expect(_patch(_game(), active: false), <String, Object?>{
        'active': false,
      });
      expect(_patch(_game(active: false), active: true), <String, Object?>{
        'active': true,
      });
    });

    test('nom coupé identique → {} ; nom changé → coupé', () {
      expect(_patch(_game(name: 'Jeu'), name: '  Jeu  '), isEmpty);
      expect(_patch(_game(name: 'Jeu '), name: 'Jeu'), isEmpty);
      expect(_patch(_game(name: 'Jeu'), name: ' Jeu 2 '), <String, Object?>{
        'name': 'Jeu 2',
      });
    });

    test('plusieurs champs → clés snake_case', () {
      final Game g = _game(
        publisher: 'A',
        coverUrl: 'https://exemple.test/a.png',
      );
      expect(
        _patch(
          g,
          name: 'Autre',
          cover: ' https://exemple.test/b.png ',
          releaseDateRaw: '2020-05',
          active: false,
        ),
        <String, Object?>{
          'name': 'Autre',
          'cover_url': 'https://exemple.test/b.png',
          'release_date': '2020-05-01',
          'active': false,
        },
      );
    });
  });

  group('validations de champ', () {
    test('validateGameName : vide, 200 / 201 unités', () {
      expect(validateGameName(''), 'Nom obligatoire.');
      expect(validateGameName('   '), 'Nom obligatoire.');
      expect(validateGameName(List<String>.filled(200, 'a').join()), isNull);
      expect(
        validateGameName(List<String>.filled(201, 'a').join()),
        'Nom trop long (200 caractères au plus).',
      );
      // Longueur JS = unités UTF-16 : 100 émojis = 200 unités.
      expect(
        validateGameName(
          List<String>.filled(100, String.fromCharCode(0x1F3AE)).join(),
        ),
        isNull,
      );
      expect(
        validateGameName(
          'a${List<String>.filled(100, String.fromCharCode(0x1F3AE)).join()}',
        ),
        'Nom trop long (200 caractères au plus).',
      );
    });

    test('validateGamePublisher / validateGameCover', () {
      expect(validateGamePublisher(''), isNull);
      expect(
        validateGamePublisher(List<String>.filled(500, 'a').join()),
        isNull,
      );
      expect(
        validateGamePublisher(List<String>.filled(501, 'a').join()),
        'Éditeur trop long (500 caractères au plus).',
      );
      expect(validateGameCover(List<String>.filled(2048, 'a').join()), isNull);
      expect(
        validateGameCover(List<String>.filled(2049, 'a').join()),
        'URL de pochette trop longue (2048 caractères au plus).',
      );
    });
  });

  group('D2 et jeux prêts', () {
    test('needsDeactivationConfirm', () {
      expect(
        needsDeactivationConfirm(_game(), <String, Object?>{'active': false}),
        isTrue,
      );
      expect(
        needsDeactivationConfirm(_game(active: false), <String, Object?>{
          'active': false,
        }),
        isFalse,
      );
      expect(
        needsDeactivationConfirm(_game(), <String, Object?>{'publisher': 'x'}),
        isFalse,
      );
      expect(
        needsDeactivationConfirm(_game(), <String, Object?>{'active': true}),
        isFalse,
      );
      expect(
        needsDeactivationConfirm(_game(), <String, Object?>{
          'name': 'x',
          'active': false,
        }),
        isTrue,
      );
    });

    test('readySelectionError : 0, 1, 500, 501', () {
      expect(readySelectionError(0), 'Aucun jeu sélectionné.');
      expect(readySelectionError(1), isNull);
      expect(readySelectionError(500), isNull);
      expect(
        readySelectionError(501),
        '500 jeux au plus par activation (limite du serveur) : décochez-en 1, puis relancez '
        '« Activer les jeux prêts » pour les suivants.',
      );
      expect(kActivateReadyMax, 500);
    });
  });
}
