// Dialogue d'ajout / édition d'un jeu et confirmation de désactivation
// (P4b-3, lot L9, conception §6.13, T7, D2, v2 ARC-02 / REG-02 / REG-03) :
// envoi PARTIEL (seules les clés modifiées), rien d'envoyé sans
// modification (« Aucune modification. »), date invalide = erreur du champ
// sans requête, effacement explicite d'une date existante, date stockée
// hors borne non contrôlée, « Actif » décoché → même confirmation que la
// bascule AVANT l'envoi (Annuler = retour à l'édition, rien envoyé),
// dialogue OUVERT sur échec, fermé sur succès / session expirée, création
// d'un jeu inactif signalée.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/core/theme/colors.dart';
import 'package:mgt_admin/domain/models/game.dart';
import 'package:mgt_admin/domain/store_write_rules.dart';
import 'package:mgt_admin/domain/write_outcome.dart';
import 'package:mgt_admin/ui/widgets/games/deactivate_game_dialog.dart';
import 'package:mgt_admin/ui/widgets/games/game_edit_dialog.dart';

import 'support/widget_fixtures.dart';

const String _uuid = '11111111-2222-4333-8444-555555555555';

/// Date du jour figée : borne d'année du panneau = 2028.
final DateTime _now = DateTime(2026, 9, 28);

Game _game({
  String name = 'Hades',
  String? publisher = 'Supergiant',
  String? cover,
  String? releaseDate = '2020-09-17',
  bool active = true,
}) => Game(
  id: _uuid,
  name: name,
  publisher: publisher,
  coverUrl: cover,
  releaseDate: releaseDate,
  active: active,
  createdAt: DateTime.utc(2026, 9, 1),
);

/// Écritures enregistrées par un test.
class _Calls {
  final List<Map<String, Object?>> patches = <Map<String, Object?>>[];
  final List<Game> originals = <Game>[];
  final List<GameDraft> drafts = <GameDraft>[];
  final List<Game> translations = <Game>[];
}

Future<DialogProbe<String>> _open(
  WidgetTester tester,
  _Calls calls, {
  Game? game,
  Future<WriteOutcome> Function()? outcome,
  bool withTranslations = false,
}) async {
  final DialogProbe<String> probe = await openDialog<String>(
    tester,
    (_) => GameEditDialog(
      game: game,
      now: _now,
      savePatch: (Game original, Map<String, Object?> patch) {
        calls.originals.add(original);
        calls.patches.add(Map<String, Object?>.of(patch));
        return outcome?.call() ??
            Future<WriteOutcome>.value(const WriteOutcome.ok());
      },
      create: (GameDraft d) async => calls.drafts.add(d),
      onOpenTranslations: withTranslations ? calls.translations.add : null,
    ),
  );
  await tester.pumpAndSettle();
  return probe;
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('games-edit-save')));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.pump();
}

/// Message d'erreur affiché sous le champ [key] (InputDecoration.errorText).
String? _fieldError(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).decoration?.errorText;

void main() {
  group('Édition : envoi partiel', () {
    testWidgets('rien de modifié → fermeture « Aucune modification. », '
        'aucun envoi', (WidgetTester tester) async {
      final _Calls calls = _Calls();
      final DialogProbe<String> probe = await _open(
        tester,
        calls,
        game: _game(),
      );
      await _save(tester);
      expect(calls.patches, isEmpty);
      expect(probe.closed, isTrue);
      expect(probe.result, 'Aucune modification.');
    });

    testWidgets('éditeur seul modifié → patch {publisher} EXACT, dialogue '
        'fermé après le succès', (WidgetTester tester) async {
      final _Calls calls = _Calls();
      final DialogProbe<String> probe = await _open(
        tester,
        calls,
        game: _game(),
      );
      await _type(tester, 'games-edit-publisher', '  Nouvel éditeur ');
      await _save(tester);
      expect(calls.patches, <Map<String, Object?>>[
        <String, Object?>{'publisher': 'Nouvel éditeur'},
      ]);
      expect(calls.originals.single.id, _uuid);
      expect(probe.closed, isTrue);
      expect(probe.result, isNull);
    });

    testWidgets('éditeur vidé → {publisher: null}', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      await _open(tester, calls, game: _game());
      await _type(tester, 'games-edit-publisher', '   ');
      await _save(tester);
      expect(calls.patches.single, <String, Object?>{'publisher': null});
    });

    testWidgets('date effacée d’un jeu daté → {release_date: null}', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      await _open(tester, calls, game: _game(releaseDate: '2023-11-10'));
      await _type(tester, 'games-edit-date', '');
      await _save(tester);
      expect(calls.patches.single, <String, Object?>{'release_date': null});
      expect(calls.patches.single.containsKey('release_date'), isTrue);
    });

    testWidgets('date AAAA-MM complétée → {release_date: AAAA-MM-01}', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      await _open(tester, calls, game: _game(releaseDate: null));
      await _type(tester, 'games-edit-date', '2024-02');
      await _save(tester);
      expect(calls.patches.single, <String, Object?>{
        'release_date': '2024-02-01',
      });
    });

    testWidgets('REG-03 : date stockée hors borne (2031) inchangée, éditeur '
        'modifié → {publisher} seul, aucune erreur de date', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      final DialogProbe<String> probe = await _open(
        tester,
        calls,
        game: _game(releaseDate: '2031-01-01'),
      );
      await _type(tester, 'games-edit-publisher', 'Autre');
      await _save(tester);
      // Aucune erreur de date : l'envoi a eu lieu et le dialogue est fermé.
      expect(calls.patches.single, <String, Object?>{'publisher': 'Autre'});
      expect(probe.closed, isTrue);
    });
  });

  group('Édition : validations (rien envoyé)', () {
    testWidgets('date inexistante 2025-02-30 → erreur dans le champ, '
        'dialogue ouvert', (WidgetTester tester) async {
      final _Calls calls = _Calls();
      final DialogProbe<String> probe = await _open(
        tester,
        calls,
        game: _game(),
      );
      await _type(tester, 'games-edit-date', '2025-02-30');
      await _save(tester);
      expect(calls.patches, isEmpty);
      expect(probe.closed, isFalse);
      expect(
        _fieldError(tester, 'games-edit-date'),
        'Date inexistante (ex. 30 février).',
      );
      expect(find.text('Date inexistante (ex. 30 février).'), findsOneWidget);
    });

    testWidgets('format de date invalide et année hors bornes', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      await _open(tester, calls, game: _game());
      await _type(tester, 'games-edit-date', '27/09/2026');
      await _save(tester);
      expect(
        _fieldError(tester, 'games-edit-date'),
        'Date invalide : AAAA, AAAA-MM ou AAAA-MM-JJ.',
      );
      await _type(tester, 'games-edit-date', '2029');
      // La saisie efface l'erreur du champ jusqu'au prochain essai.
      expect(_fieldError(tester, 'games-edit-date'), isNull);
      await _save(tester);
      expect(
        _fieldError(tester, 'games-edit-date'),
        'Année hors bornes (1970 à 2028).',
      );
      expect(calls.patches, isEmpty);
    });

    testWidgets('nom vide → « Nom obligatoire. » ; éditeur trop long', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      await _open(tester, calls, game: _game());
      await _type(tester, 'games-edit-name', '   ');
      await _type(tester, 'games-edit-publisher', 'e' * 501);
      await _save(tester);
      expect(_fieldError(tester, 'games-edit-name'), 'Nom obligatoire.');
      expect(
        _fieldError(tester, 'games-edit-publisher'),
        'Éditeur trop long (500 caractères au plus).',
      );
      expect(calls.patches, isEmpty);
    });

    testWidgets('pochette trop longue', (WidgetTester tester) async {
      final _Calls calls = _Calls();
      await _open(tester, calls, game: _game());
      await _type(tester, 'games-edit-cover', 'h' * 2049);
      await _save(tester);
      expect(
        _fieldError(tester, 'games-edit-cover'),
        'URL de pochette trop longue (2048 caractères au plus).',
      );
      expect(calls.patches, isEmpty);
    });
  });

  group('Édition : désactivation confirmée (D2, ARC-02)', () {
    testWidgets('« Actif » décoché → confirmation AVANT l’envoi ; Annuler → '
        'retour à l’édition, rien envoyé', (WidgetTester tester) async {
      final _Calls calls = _Calls();
      final DialogProbe<String> probe = await _open(
        tester,
        calls,
        game: _game(),
      );
      await tester.tap(find.byKey(const Key('games-edit-active')));
      await tester.pump();
      await _save(tester);
      expect(find.text('Désactiver Hades ?'), findsOneWidget);
      expect(calls.patches, isEmpty);

      await tester.tap(find.byKey(const Key('games-deactivate-cancel')));
      await tester.pumpAndSettle();
      expect(find.text('Désactiver Hades ?'), findsNothing);
      expect(find.text('Modifier le jeu'), findsOneWidget);
      expect(calls.patches, isEmpty);
      expect(probe.closed, isFalse);

      await _save(tester);
      await tester.tap(find.byKey(const Key('games-deactivate-confirm')));
      await tester.pumpAndSettle();
      expect(calls.patches, <Map<String, Object?>>[
        <String, Object?>{'active': false},
      ]);
      expect(probe.closed, isTrue);
    });

    testWidgets('jeu inactif réactivé par l’interrupteur → pas de '
        'confirmation, {active: true}', (WidgetTester tester) async {
      final _Calls calls = _Calls();
      await _open(tester, calls, game: _game(active: false));
      await tester.tap(find.byKey(const Key('games-edit-active')));
      await tester.pump();
      await _save(tester);
      expect(find.byType(DeactivateGameDialog), findsNothing);
      expect(calls.patches.single, <String, Object?>{'active': true});
    });
  });

  group('Édition : réponse du serveur', () {
    testWidgets('envoi en cours : bouton en chargement, fermeture bloquée', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      final Completer<WriteOutcome> pending = Completer<WriteOutcome>();
      final DialogProbe<String> probe = await _open(
        tester,
        calls,
        game: _game(),
        outcome: () => pending.future,
      );
      await _type(tester, 'games-edit-name', 'Hades II');
      await tester.tap(find.byKey(const Key('games-edit-save')));
      await tester.pump();
      expect(calls.patches.single, <String, Object?>{'name': 'Hades II'});
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('games-edit-save')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('games-edit-cancel')))
            .onPressed,
        isNull,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(probe.closed, isFalse);

      pending.complete(const WriteOutcome.ok());
      await tester.pumpAndSettle();
      expect(probe.closed, isTrue);
    });

    testWidgets('échec (404) → dialogue OUVERT, message sous les champs, '
        'nouvel essai possible', (WidgetTester tester) async {
      final _Calls calls = _Calls();
      final DialogProbe<String> probe = await _open(
        tester,
        calls,
        game: _game(),
        outcome: () async => const WriteOutcome.failed(kGameNotFoundMessage),
      );
      await _type(tester, 'games-edit-publisher', 'Autre');
      await _save(tester);
      expect(probe.closed, isFalse);
      expect(
        tester.widget<Text>(find.byKey(const Key('games-edit-error'))).data,
        'Jeu introuvable : il a été supprimé entre-temps.',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('games-edit-save')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('échec 400 → message du serveur tel quel', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      await _open(
        tester,
        calls,
        game: _game(),
        outcome: () async => const WriteOutcome.failed(
          'release_date invalide (AAAA-MM-JJ ou null).',
        ),
      );
      await _type(tester, 'games-edit-date', '2024-01-01');
      await _save(tester);
      expect(
        find.text('release_date invalide (AAAA-MM-JJ ou null).'),
        findsOneWidget,
      );
    });

    testWidgets('session expirée → dialogue fermé, aucun message', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      final DialogProbe<String> probe = await _open(
        tester,
        calls,
        game: _game(),
        outcome: () async => const WriteOutcome.sessionExpired(),
      );
      await _type(tester, 'games-edit-publisher', 'Autre');
      await _save(tester);
      expect(probe.closed, isTrue);
      expect(probe.result, isNull);
    });

    testWidgets('une exception inattendue ne bloque jamais le dialogue', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      final DialogProbe<String> probe = await _open(
        tester,
        calls,
        game: _game(),
        outcome: () async => throw StateError('panne'),
      );
      await _type(tester, 'games-edit-publisher', 'Autre');
      await _save(tester);
      expect(probe.closed, isFalse);
      expect(find.byKey(const Key('games-edit-error')), findsOneWidget);
    });
  });

  group('Création', () {
    testWidgets('« Actif » décoché → créé sans confirmation, SnackBar '
        '« créé INACTIF »', (WidgetTester tester) async {
      final _Calls calls = _Calls();
      final DialogProbe<String> probe = await _open(tester, calls);
      expect(find.text('Ajouter un jeu'), findsOneWidget);
      await _type(tester, 'games-edit-name', '  Nouveau jeu ');
      await _type(tester, 'games-edit-publisher', 'Studio');
      await tester.tap(find.byKey(const Key('games-edit-active')));
      await tester.pump();
      await _save(tester);
      expect(find.byType(DeactivateGameDialog), findsNothing);
      expect(calls.patches, isEmpty);
      expect(calls.drafts, hasLength(1));
      final GameDraft d = calls.drafts.single;
      expect(d.name, 'Nouveau jeu');
      expect(d.publisher, 'Studio');
      expect(d.coverUrl, '');
      expect(d.releaseDate, isNull);
      expect(d.active, isFalse);
      expect(probe.closed, isTrue);
      expect(
        probe.result,
        'Nouveau jeu créé INACTIF (section « Jeux inactifs »).',
      );
    });

    testWidgets('jeu actif avec date AAAA → date normalisée, pas de message', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      final DialogProbe<String> probe = await _open(tester, calls);
      await _type(tester, 'games-edit-name', 'Nouveau jeu');
      await _type(tester, 'games-edit-date', '2024');
      await _save(tester);
      expect(calls.drafts.single.releaseDate, '2024-01-01');
      expect(calls.drafts.single.active, isTrue);
      expect(probe.closed, isTrue);
      expect(probe.result, isNull);
    });

    testWidgets('date invalide ou nom vide → rien créé', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      final DialogProbe<String> probe = await _open(tester, calls);
      await _save(tester);
      expect(_fieldError(tester, 'games-edit-name'), 'Nom obligatoire.');
      await _type(tester, 'games-edit-name', 'Nouveau jeu');
      await _type(tester, 'games-edit-date', '2026-13-01');
      await _save(tester);
      expect(_fieldError(tester, 'games-edit-date'), 'Mois invalide.');
      expect(calls.drafts, isEmpty);
      expect(probe.closed, isFalse);
    });
  });

  group('Traductions', () {
    testWidgets('bouton en édition : reçoit le jeu avec le nom saisi', (
      WidgetTester tester,
    ) async {
      final _Calls calls = _Calls();
      await _open(tester, calls, game: _game(), withTranslations: true);
      await _type(tester, 'games-edit-name', 'Hades II');
      await tester.tap(find.byTooltip('Traductions (12 langues)'));
      await tester.pump();
      expect(calls.translations.single.id, _uuid);
      expect(calls.translations.single.name, 'Hades II');
    });

    testWidgets('absent à la création', (WidgetTester tester) async {
      final _Calls calls = _Calls();
      await _open(tester, calls, withTranslations: true);
      expect(find.byTooltip('Traductions (12 langues)'), findsNothing);
    });
  });

  group('DeactivateGameDialog', () {
    testWidgets('titre, texte, bouton rouge ; « Désactiver » → true', (
      WidgetTester tester,
    ) async {
      final DialogProbe<bool> probe = await openDialog<bool>(
        tester,
        (_) => const DeactivateGameDialog(name: 'Hades'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Désactiver Hades ?'), findsOneWidget);
      expect(
        find.text(
          "Le jeu disparaîtra de l'application et de la liste principale. "
          'Vous pourrez le réactiver depuis « Jeux inactifs ».',
        ),
        findsOneWidget,
      );
      final FilledButton button = tester.widget<FilledButton>(
        find.byKey(const Key('games-deactivate-confirm')),
      );
      expect(
        button.style!.backgroundColor!.resolve(<WidgetState>{}),
        AppColors.categoryVideo,
      );
      await tester.tap(find.byKey(const Key('games-deactivate-confirm')));
      await tester.pumpAndSettle();
      expect(probe.result, isTrue);
    });

    testWidgets('« Annuler » → false', (WidgetTester tester) async {
      final DialogProbe<bool> probe = await openDialog<bool>(
        tester,
        (_) => const DeactivateGameDialog(name: 'Hades'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('games-deactivate-cancel')));
      await tester.pumpAndSettle();
      expect(probe.result, isFalse);
    });
  });
}
