// Règles de l'écran Jeux (P4b-3, lot L9, conception §6.13, §6.14, D2,
// REG-02) : tableau principal limité aux jeux actifs, recherche, écritures
// bloquées pour un id temporaire en production seulement, bouton « Activer
// les jeux prêts », textes fixes (confirmation de désactivation, SnackBars,
// section « Jeux inactifs »).
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/games_screen_rules.dart';
import 'package:mgt_admin/domain/models/game.dart';
import 'package:mgt_admin/domain/store_write_rules.dart';

const String _uuid = '11111111-2222-4333-8444-555555555555';

Game _g(String id, String name, {String? publisher, bool active = true}) =>
    Game(
      id: id,
      name: name,
      publisher: publisher,
      active: active,
      createdAt: DateTime.utc(2026, 9, 1),
    );

void main() {
  group('Listes', () {
    test('tableau principal : jeux actifs seulement, ordre conservé', () {
      final List<Game> all = <Game>[
        _g('a', 'Alpha'),
        _g('b', 'Beta', active: false),
        _g('c', 'Gamma'),
      ];
      expect(activeGamesOnly(all).map((Game g) => g.id).toList(), <String>[
        'a',
        'c',
      ]);
      expect(activeGamesOnly(const <Game>[]), isEmpty);
    });

    test('recherche vide → liste inchangée', () {
      final List<Game> all = <Game>[_g('a', 'Alpha'), _g('b', 'Beta')];
      expect(filterGamesBySearch(all, ''), hasLength(2));
    });

    test('recherche sur le nom ou l’éditeur, casse ignorée', () {
      final List<Game> all = <Game>[
        _g('a', 'Elden Ring', publisher: 'Bandai Namco'),
        _g('b', 'Hades', publisher: 'Supergiant'),
        _g('c', 'Tetris'),
      ];
      expect(filterGamesBySearch(all, 'ELDEN').map((Game g) => g.id), <String>[
        'a',
      ]);
      expect(filterGamesBySearch(all, 'giant').map((Game g) => g.id), <String>[
        'b',
      ]);
      // Éditeur absent : seul le nom compte.
      expect(filterGamesBySearch(all, 'namco').map((Game g) => g.id), <String>[
        'a',
      ]);
      expect(filterGamesBySearch(all, 'zzz'), isEmpty);
    });
  });

  group('Écritures bloquées', () {
    test('production : id temporaire g-<ms> ou non UUID → bloqué', () {
      expect(
        gameWriteBlocked(_g('g-1727400000000', 'X'), hasSync: true),
        isTrue,
      );
      expect(gameWriteBlocked(_g('g-eldenring', 'X'), hasSync: true), isTrue);
      expect(gameWriteBlocked(_g(_uuid, 'X'), hasSync: true), isFalse);
      expect(
        gameWriteBlocked(_g(_uuid.toUpperCase(), 'X'), hasSync: true),
        isFalse,
      );
    });

    test('aperçu : rien n’est bloqué (jeux de démonstration)', () {
      expect(
        gameWriteBlocked(_g('g-1727400000000', 'X'), hasSync: false),
        isFalse,
      );
      expect(gameWriteBlocked(_g('g-eldenring', 'X'), hasSync: false), isFalse);
    });

    test('infobulle = message du contrôleur pour un id temporaire', () {
      expect(kGameWriteBlockedTooltip, kGameTempIdMessage);
      expect(kGameWriteBlockedTooltip, startsWith('Jeu en cours de création'));
    });

    test('bouton « Activer les jeux prêts » : compte principal ET serveur', () {
      expect(showReadyGamesButton(isOwner: true, hasSync: true), isTrue);
      expect(showReadyGamesButton(isOwner: false, hasSync: true), isFalse);
      expect(showReadyGamesButton(isOwner: true, hasSync: false), isFalse);
      expect(showReadyGamesButton(isOwner: false, hasSync: false), isFalse);
    });
  });

  group('Textes', () {
    test('confirmation de désactivation (D2)', () {
      expect(deactivateGameTitle('Hades'), 'Désactiver Hades ?');
      expect(
        kDeactivateGameText,
        "Le jeu disparaîtra de l'application et de la liste principale. "
        'Vous pourrez le réactiver depuis « Jeux inactifs ».',
      );
      expect(kDeactivateGameButton, 'Désactiver');
    });

    test('SnackBars', () {
      expect(gameReactivatedMessage('Hades'), 'Hades réactivé.');
      expect(
        gameDeactivatedMessage('Hades'),
        'Hades désactivé (section « Jeux inactifs »).',
      );
      expect(
        gameCreatedInactiveMessage('Hades'),
        'Hades créé INACTIF (section « Jeux inactifs »).',
      );
      expect(kNoGameChangeMessage, 'Aucune modification.');
    });

    test('échec hors dialogue : messages du contrôleur tels quels', () {
      expect(gameWriteFailureText(kGameNotFoundMessage), kGameNotFoundMessage);
      expect(gameWriteFailureText(kGameTempIdMessage), kGameTempIdMessage);
      expect(
        gameWriteFailureText(kGameUncertainMessage),
        kGameUncertainMessage,
      );
    });

    test('échec hors dialogue : message du serveur préfixé, vide → défaut', () {
      expect(
        gameWriteFailureText('active (booléen) requis.'),
        'Jeu non modifié : active (booléen) requis.',
      );
      expect(gameWriteFailureText(null), 'Jeu non modifié.');
      expect(gameWriteFailureText('  '), 'Jeu non modifié.');
    });
  });

  group('Section « Jeux inactifs »', () {
    test('titre, état vide', () {
      expect(inactiveGamesTitle(0), 'Jeux inactifs (0)');
      expect(inactiveGamesTitle(3), 'Jeux inactifs (3)');
      expect(kNoInactiveGamesText, 'Aucun jeu inactif.');
    });

    test('erreur : point final ajouté, jamais doublé', () {
      expect(
        inactiveGamesErrorText('Lecture des jeux échouée'),
        'Liste des jeux inactifs illisible : Lecture des jeux échouée.',
      );
      expect(
        inactiveGamesErrorText('Réponse illisible du serveur.'),
        'Liste des jeux inactifs illisible : Réponse illisible du serveur.',
      );
      expect(
        inactiveGamesErrorText(' Session expirée. '),
        'Liste des jeux inactifs illisible : Session expirée.',
      );
      expect(inactiveGamesErrorText(''), 'Liste des jeux inactifs illisible.');
      expect(
        inactiveGamesErrorText('...'),
        'Liste des jeux inactifs illisible.',
      );
    });

    test('ouverte s’il y a au moins un jeu inactif ou une erreur', () {
      expect(inactiveSectionOpen(total: 0, hasError: false), isFalse);
      expect(inactiveSectionOpen(total: 1, hasError: false), isTrue);
      expect(inactiveSectionOpen(total: 0, hasError: true), isTrue);
    });

    test('colonne « Contenus » : « — » sans cache des contenus', () {
      expect(gameContentCountLabel(contentsCached: false, count: 0), '—');
      expect(gameContentCountLabel(contentsCached: false, count: 12), '—');
      expect(gameContentCountLabel(contentsCached: true, count: 0), '0');
      expect(gameContentCountLabel(contentsCached: true, count: 12), '12');
    });
  });

  group('« Activer les jeux prêts »', () {
    test('erreur de l’aperçu : 403 → réservé ; sinon message tel quel', () {
      expect(
        readyGamesErrorMessage(forbidden: true, message: 'Accès refusé.'),
        'Réservé au compte principal.',
      );
      // v2 C-11 : avec ou sans point, jamais retouché.
      expect(
        readyGamesErrorMessage(forbidden: false, message: 'Aperçu impossible'),
        'Aperçu impossible',
      );
      expect(
        readyGamesErrorMessage(forbidden: false, message: 'Aperçu impossible.'),
        'Aperçu impossible.',
      );
    });
  });
}
