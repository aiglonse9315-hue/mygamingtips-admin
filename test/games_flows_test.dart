// Enchaînements de l'écran Jeux (P4b-3, lot L9, conception §6.13, D2, T7) :
// bascule (désactiver = confirmation, Annuler = aucun envoi ; réactiver sans
// confirmation ; indicateur ; SnackBars de succès et d'échec ; rien sur une
// session expirée) et « Activer les jeux prêts » (401 → déconnexion, 403 →
// « Réservé au compte principal. », 500 → message tel quel, aucun jeu prêt
// → dialogue d'information avec le seuil LU, sinon dialogue des jeux prêts
// jusqu'au bilan).
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/game.dart';
import 'package:mgt_admin/domain/models/ready_games.dart';
import 'package:mgt_admin/domain/store_write_rules.dart';
import 'package:mgt_admin/domain/write_outcome.dart';
import 'package:mgt_admin/ui/widgets/games/games_flows.dart';
import 'package:mgt_admin/ui/widgets/games/ready_games_dialog.dart';

import 'support/widget_fixtures.dart';

const String _uuid = '11111111-2222-4333-8444-555555555555';

Game _game({bool active = true}) => Game(
  id: _uuid,
  name: 'Hades',
  active: active,
  createdAt: DateTime.utc(2026, 9, 1),
);

/// Monte un bouton « lancer » qui exécute [action] avec son contexte (sous
/// un Scaffold : les SnackBars s'affichent).
Future<void> _launch(
  WidgetTester tester,
  Future<void> Function(BuildContext context) action,
) async {
  setWindow(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () => action(context),
              child: const Text('lancer'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('lancer'));
  await tester.pump();
}

String? _snackText(WidgetTester tester) {
  final Finder f = find.byType(SnackBar);
  if (f.evaluate().isEmpty) return null;
  final Widget content = tester.widget<SnackBar>(f.first).content;
  return content is Text ? content.data : null;
}

Color? _snackColor(WidgetTester tester) =>
    tester.widget<SnackBar>(find.byType(SnackBar).first).backgroundColor;

/// Appels de `setActive` et de `onBusy`.
class _Toggle {
  final List<bool> sent = <bool>[];
  final List<bool> busy = <bool>[];
  WriteOutcome? result;
  bool done = false;
}

Future<_Toggle> _runToggle(
  WidgetTester tester, {
  required Game game,
  required bool active,
  Future<WriteOutcome> Function()? outcome,
}) async {
  final _Toggle t = _Toggle();
  await _launch(tester, (BuildContext context) async {
    t.result = await runSetGameActive(
      context,
      game: game,
      active: active,
      setActive: (Game g, bool a) {
        t.sent.add(a);
        return outcome?.call() ??
            Future<WriteOutcome>.value(const WriteOutcome.ok());
      },
      onBusy: t.busy.add,
    );
    t.done = true;
  });
  return t;
}

ReadyGamesPreview _preview({int threshold = 10, int n = 2}) =>
    ReadyGamesPreview(
      threshold: threshold,
      inactiveTotal: 3,
      count: n,
      games: <ReadyGame>[
        for (int i = 0; i < n; i++)
          ReadyGame(
            id: 'g$i',
            name: 'Jeu Test Prêt $i',
            validatedTotal: 10,
            video: 5,
            guides: 3,
            links: 2,
            distinctUrls: 10,
          ),
      ],
    );

/// Résultat de [runReadyGamesFlow] et rappels.
class _Ready {
  int authErrors = 0;
  final List<List<String>> applied = <List<String>>[];
  ActivateReadyResult? result;
  bool done = false;
}

Future<_Ready> _runReady(
  WidgetTester tester,
  Future<ReadyGamesPreview> Function() preview,
) async {
  final _Ready r = _Ready();
  await _launch(tester, (BuildContext context) async {
    r.result = await runReadyGamesFlow(
      context,
      preview: preview,
      apply: (List<String> ids) async {
        r.applied.add(ids);
        return ActivateReadyResult(
          threshold: 10,
          requested: ids.length,
          activated: <ActivatedGame>[
            for (final String id in ids)
              ActivatedGame(id: id, name: 'Jeu $id', validatedTotal: 10),
          ],
          skipped: const <SkippedGame>[],
        );
      },
      onAuthError: () => r.authErrors++,
    );
    r.done = true;
  });
  await tester.pumpAndSettle();
  return r;
}

void main() {
  group('Bascule actif / inactif', () {
    testWidgets('désactiver → confirmation ; Annuler → aucun envoi', (
      WidgetTester tester,
    ) async {
      final _Toggle t = await _runToggle(tester, game: _game(), active: false);
      await tester.pumpAndSettle();
      expect(find.text('Désactiver Hades ?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('games-deactivate-cancel')));
      await tester.pumpAndSettle();
      expect(t.done, isTrue);
      expect(t.result, isNull);
      expect(t.sent, isEmpty);
      expect(t.busy, isEmpty);
      expect(_snackText(tester), isNull);
    });

    testWidgets('désactiver → confirmer → {active: false}, indicateur, '
        'SnackBar de succès', (WidgetTester tester) async {
      final _Toggle t = await _runToggle(tester, game: _game(), active: false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('games-deactivate-confirm')));
      await tester.pumpAndSettle();
      expect(t.sent, <bool>[false]);
      expect(t.busy, <bool>[true, false]);
      expect(t.result!.ok, isTrue);
      expect(
        _snackText(tester),
        'Hades désactivé (section « Jeux inactifs »).',
      );
    });

    testWidgets('réactiver : SANS confirmation, SnackBar « <nom> réactivé. »', (
      WidgetTester tester,
    ) async {
      final _Toggle t = await _runToggle(
        tester,
        game: _game(active: false),
        active: true,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(t.sent, <bool>[true]);
      expect(_snackText(tester), 'Hades réactivé.');
    });

    testWidgets('indicateur tenu pendant l’envoi', (WidgetTester tester) async {
      final Completer<WriteOutcome> pending = Completer<WriteOutcome>();
      final _Toggle t = await _runToggle(
        tester,
        game: _game(active: false),
        active: true,
        outcome: () => pending.future,
      );
      await tester.pump();
      expect(t.busy, <bool>[true]);
      pending.complete(const WriteOutcome.ok());
      await tester.pumpAndSettle();
      expect(t.busy, <bool>[true, false]);
    });

    testWidgets('échec → SnackBar ROUGE avec le message', (
      WidgetTester tester,
    ) async {
      await _runToggle(
        tester,
        game: _game(active: false),
        active: true,
        outcome: () async => const WriteOutcome.failed(kGameNotFoundMessage),
      );
      await tester.pumpAndSettle();
      expect(
        _snackText(tester),
        'Jeu introuvable : il a été supprimé entre-temps.',
      );
      expect(_snackColor(tester), Colors.red.shade700);
    });

    testWidgets('échec 400 du serveur → message préfixé', (
      WidgetTester tester,
    ) async {
      await _runToggle(
        tester,
        game: _game(active: false),
        active: true,
        outcome: () async => const WriteOutcome.failed('Opération échouée'),
      );
      await tester.pumpAndSettle();
      expect(_snackText(tester), 'Jeu non modifié : Opération échouée');
    });

    testWidgets('session expirée → aucune SnackBar, indicateur retiré', (
      WidgetTester tester,
    ) async {
      final _Toggle t = await _runToggle(
        tester,
        game: _game(active: false),
        active: true,
        outcome: () async => const WriteOutcome.sessionExpired(),
      );
      await tester.pumpAndSettle();
      expect(t.result!.sessionExpired, isTrue);
      expect(t.busy, <bool>[true, false]);
      expect(_snackText(tester), isNull);
    });

    testWidgets('exception inattendue → SnackBar rouge, indicateur retiré', (
      WidgetTester tester,
    ) async {
      final _Toggle t = await _runToggle(
        tester,
        game: _game(active: false),
        active: true,
        outcome: () async => throw StateError('panne'),
      );
      await tester.pumpAndSettle();
      expect(t.busy, <bool>[true, false]);
      expect(_snackColor(tester), Colors.red.shade700);
    });
  });

  group('« Activer les jeux prêts »', () {
    testWidgets('aperçu 401 → onAuthError, aucun dialogue ni message', (
      WidgetTester tester,
    ) async {
      final _Ready r = await _runReady(
        tester,
        () async => throw const AdminAuthException('Session expirée.'),
      );
      expect(r.done, isTrue);
      expect(r.authErrors, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(_snackText(tester), isNull);
    });

    testWidgets('aperçu 403 → « Réservé au compte principal. »', (
      WidgetTester tester,
    ) async {
      final _Ready r = await _runReady(
        tester,
        () async => throw const AdminForbiddenException(
          'Accès réservé au compte principal.',
        ),
      );
      expect(r.authErrors, 0);
      expect(_snackText(tester), 'Réservé au compte principal.');
      expect(_snackColor(tester), Colors.red.shade700);
    });

    testWidgets('aperçu 500 → message du serveur tel quel', (
      WidgetTester tester,
    ) async {
      await _runReady(
        tester,
        () async => throw const AdminApiException(500, 'Aperçu impossible'),
      );
      expect(_snackText(tester), 'Aperçu impossible');
    });

    testWidgets('aucun jeu prêt → dialogue d’information (seuil LU)', (
      WidgetTester tester,
    ) async {
      final _Ready r = await _runReady(
        tester,
        () async => _preview(threshold: 12, n: 0),
      );
      expect(find.text('Activer les jeux prêts'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('games-ready-info'))).data,
        'Aucun jeu prêt : 3 jeu(x) inactif(s), seuil : 12 contenus validés.',
      );
      expect(find.byType(ReadyGamesDialog), findsNothing);
      await tester.tap(find.byKey(const Key('games-ready-info-close')));
      await tester.pumpAndSettle();
      expect(r.done, isTrue);
      expect(r.result, isNull);
      expect(r.applied, isEmpty);
    });

    testWidgets('jeux prêts → dialogue, confirmation, activation, bilan', (
      WidgetTester tester,
    ) async {
      final _Ready r = await _runReady(tester, () async => _preview());
      expect(
        find.text('Jeux prêts à activer (seuil : 10 contenus validés)'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('games-ready-apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('games-ready-confirm')));
      await tester.pumpAndSettle();
      expect(r.applied, <List<String>>[
        <String>['g0', 'g1'],
      ]);
      expect(find.text('2 jeu(x) activé(s)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('games-ready-close')));
      await tester.pumpAndSettle();
      expect(r.done, isTrue);
      expect(r.result!.activated, hasLength(2));
    });
  });
}
