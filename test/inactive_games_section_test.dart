// Section « Jeux inactifs (N) » de l'écran Jeux (P4b-3, lot L9, D2, T7,
// conception §6.13, §6.14) : titre avec le nombre, ouverture automatique
// (au moins un jeu ou une erreur), tableau Jeu · Éditeur · Contenus ·
// Actions, « Réactiver » SANS confirmation, « Modifier », « Supprimer »,
// jeu en cours de création bloqué en production seulement, indicateur par
// ligne, chargement, erreur + « Réessayer », vide, « Recharger ».
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/models/game.dart';
import 'package:mgt_admin/ui/widgets/games/inactive_games_section.dart';

import 'support/widget_fixtures.dart';

const String _uuidA = '11111111-2222-4333-8444-555555555555';
const String _uuidB = '66666666-7777-4888-8999-aaaaaaaaaaaa';
const String _tempId = 'g-1727400000000';

Game _g(String id, String name, {String? publisher}) => Game(
  id: id,
  name: name,
  publisher: publisher,
  active: false,
  createdAt: DateTime.utc(2026, 9, 1),
);

/// Rappels enregistrés.
class _Calls {
  int reloads = 0;
  final List<String> reactivated = <String>[];
  final List<String> edited = <String>[];
  final List<String> deleted = <String>[];
}

Future<void> _pump(
  WidgetTester tester,
  _Calls calls, {
  List<Game>? games,
  int? total,
  bool loading = false,
  String? error,
  bool hasSync = true,
  Set<String> busyIds = const <String>{},
}) async {
  final List<Game> shown =
      games ??
      <Game>[
        _g(_uuidA, 'Jeu Test Prêt A', publisher: 'Studio A'),
        _g(_uuidB, 'Jeu Test Inactif'),
      ];
  await pumpBody(
    tester,
    InactiveGamesSection(
      games: shown,
      total: total ?? shown.length,
      loading: loading,
      error: error,
      hasSync: hasSync,
      busyIds: busyIds,
      contentCountLabel: (Game g) => g.id == _uuidA ? '10' : '—',
      onReload: () => calls.reloads++,
      onReactivate: (Game g) => calls.reactivated.add(g.id),
      onEdit: (Game g) => calls.edited.add(g.id),
      onDelete: (Game g) => calls.deleted.add(g.id),
    ),
    width: 900,
  );
  // Un indicateur de chargement tourne sans fin : pas de pumpAndSettle.
  if (loading || busyIds.isNotEmpty) {
    await tester.pump(const Duration(milliseconds: 400));
  } else {
    await tester.pumpAndSettle();
  }
}

ButtonStyleButton _button(WidgetTester tester, String key) =>
    tester.widget<ButtonStyleButton>(find.byKey(ValueKey<String>(key)));

IconButton _icon(WidgetTester tester, String key) =>
    tester.widget<IconButton>(find.byKey(ValueKey<String>(key)));

void main() {
  testWidgets('titre avec le nombre, section ouverte, lignes du tableau', (
    WidgetTester tester,
  ) async {
    final _Calls calls = _Calls();
    await _pump(tester, calls);
    expect(find.text('Jeux inactifs (2)'), findsOneWidget);
    for (final String col in <String>[
      'Jeu',
      'Éditeur',
      'Contenus',
      'Actions',
    ]) {
      expect(find.text(col), findsOneWidget);
    }
    expect(find.text('Jeu Test Prêt A'), findsOneWidget);
    expect(find.text('Studio A'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    // Éditeur absent et cache des contenus absent → « — ».
    expect(find.text('—'), findsNWidgets(2));
    expect(find.text('Réactiver'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('« Réactiver » : rappel direct, SANS confirmation', (
    WidgetTester tester,
  ) async {
    final _Calls calls = _Calls();
    await _pump(tester, calls);
    await tester.tap(
      find.byKey(const ValueKey<String>('games-inactive-reactivate-$_uuidA')),
    );
    await tester.pumpAndSettle();
    expect(calls.reactivated, <String>[_uuidA]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('« Modifier » et « Supprimer » appellent leurs rappels', (
    WidgetTester tester,
  ) async {
    final _Calls calls = _Calls();
    await _pump(tester, calls);
    await tester.tap(
      find.byKey(const ValueKey<String>('games-inactive-edit-$_uuidB')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('games-inactive-delete-$_uuidB')),
    );
    await tester.pump();
    expect(calls.edited, <String>[_uuidB]);
    expect(calls.deleted, <String>[_uuidB]);
  });

  testWidgets('jeu en cours de création (production) : « Réactiver » et '
      '« Modifier » désactivés avec infobulle', (WidgetTester tester) async {
    final _Calls calls = _Calls();
    await _pump(tester, calls, games: <Game>[_g(_tempId, 'Jeu local')]);
    expect(
      _button(tester, 'games-inactive-reactivate-$_tempId').onPressed,
      isNull,
    );
    expect(_icon(tester, 'games-inactive-edit-$_tempId').onPressed, isNull);
    expect(
      _icon(tester, 'games-inactive-edit-$_tempId').tooltip,
      'Jeu en cours de création : réessayez après la synchronisation.',
    );
    expect(
      find.byTooltip(
        'Jeu en cours de création : réessayez après la synchronisation.',
      ),
      findsNWidgets(2),
    );
    // La suppression reste possible (comportement existant).
    expect(
      _icon(tester, 'games-inactive-delete-$_tempId').onPressed,
      isNotNull,
    );
  });

  testWidgets('aperçu (sans serveur) : jeu local non UUID modifiable', (
    WidgetTester tester,
  ) async {
    final _Calls calls = _Calls();
    await _pump(
      tester,
      calls,
      games: <Game>[_g('g-demo', 'Jeu de démo')],
      hasSync: false,
    );
    expect(
      _button(tester, 'games-inactive-reactivate-g-demo').onPressed,
      isNotNull,
    );
    expect(_icon(tester, 'games-inactive-edit-g-demo').onPressed, isNotNull);
  });

  testWidgets('écriture en cours : indicateur, boutons de la ligne '
      'désactivés, autres lignes intactes', (WidgetTester tester) async {
    final _Calls calls = _Calls();
    await _pump(tester, calls, busyIds: <String>{_uuidA});
    expect(
      _button(tester, 'games-inactive-reactivate-$_uuidA').onPressed,
      isNull,
    );
    expect(_icon(tester, 'games-inactive-edit-$_uuidA').onPressed, isNull);
    expect(_icon(tester, 'games-inactive-delete-$_uuidA').onPressed, isNull);
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('games-inactive-reactivate-$_uuidA'),
        ),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      _button(tester, 'games-inactive-reactivate-$_uuidB').onPressed,
      isNotNull,
    );
  });

  testWidgets('« Recharger » : rappel ; désactivé pendant le chargement', (
    WidgetTester tester,
  ) async {
    final _Calls calls = _Calls();
    await _pump(tester, calls);
    await tester.tap(find.byKey(const Key('games-inactive-reload')));
    expect(calls.reloads, 1);

    await _pump(tester, calls, loading: true);
    expect(_button(tester, 'games-inactive-reload').onPressed, isNull);
  });

  testWidgets('erreur : message exact + « Réessayer », section ouverte même '
      'sans jeu', (WidgetTester tester) async {
    final _Calls calls = _Calls();
    await _pump(
      tester,
      calls,
      games: const <Game>[],
      error: 'Lecture des jeux échouée',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('games-inactive-error'))).data,
      'Liste des jeux inactifs illisible : Lecture des jeux échouée.',
    );
    expect(find.byKey(const Key('games-inactive-empty')), findsNothing);
    await tester.tap(find.byKey(const Key('games-inactive-retry')));
    expect(calls.reloads, 1);
  });

  testWidgets('erreur après une lecture réussie : la liste reste affichée', (
    WidgetTester tester,
  ) async {
    final _Calls calls = _Calls();
    await _pump(tester, calls, error: 'Réponse illisible du serveur.');
    expect(
      find.text(
        'Liste des jeux inactifs illisible : Réponse illisible du serveur.',
      ),
      findsOneWidget,
    );
    expect(find.text('Jeu Test Prêt A'), findsOneWidget);
  });

  testWidgets('aucun jeu inactif : section repliée, « Aucun jeu inactif. » '
      'à l’ouverture', (WidgetTester tester) async {
    final _Calls calls = _Calls();
    await _pump(tester, calls, games: const <Game>[]);
    expect(find.text('Jeux inactifs (0)'), findsOneWidget);
    expect(find.text('Aucun jeu inactif.'), findsNothing);
    await tester.tap(find.text('Jeux inactifs (0)'));
    await tester.pumpAndSettle();
    expect(find.text('Aucun jeu inactif.'), findsOneWidget);
  });

  testWidgets('recherche sans résultat (jeux inactifs existants) : section '
      'ouverte, « Aucun jeu inactif. »', (WidgetTester tester) async {
    final _Calls calls = _Calls();
    await _pump(tester, calls, games: const <Game>[], total: 3);
    expect(find.text('Jeux inactifs (0)'), findsOneWidget);
    expect(find.text('Aucun jeu inactif.'), findsOneWidget);
  });

  testWidgets('chargement sans liste : indicateur, pas d’état vide', (
    WidgetTester tester,
  ) async {
    final _Calls calls = _Calls();
    await pumpBody(
      tester,
      InactiveGamesSection(
        games: const <Game>[],
        total: 0,
        loading: true,
        error: null,
        hasSync: true,
        busyIds: const <String>{},
        contentCountLabel: (Game g) => '—',
        onReload: () => calls.reloads++,
        onReactivate: (Game g) {},
        onEdit: (Game g) {},
        onDelete: (Game g) {},
      ),
      width: 900,
    );
    await tester.pump();
    // Indicateur du titre (visible même replié).
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await tester.tap(find.text('Jeux inactifs (0)'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Aucun jeu inactif.'), findsNothing);
  });

  testWidgets('la section s’ouvre quand des jeux arrivent après un premier '
      'affichage vide', (WidgetTester tester) async {
    final _Calls calls = _Calls();
    await _pump(tester, calls, games: const <Game>[]);
    expect(find.text('Réactiver'), findsNothing);
    await _pump(tester, calls);
    expect(find.text('Jeux inactifs (2)'), findsOneWidget);
    expect(find.text('Réactiver'), findsNWidgets(2));
  });
}
