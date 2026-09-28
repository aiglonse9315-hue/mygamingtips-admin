// « Activer les jeux prêts » (P4b-3, lot L5, D2, EF-02, conception §6.13,
// §7.1) : toutes les cases cochées, décocher, tout décocher → désactivé,
// doublons d'URL signalés, ids cochés transmis après confirmation, plafond
// de 500 (501 jeux → 500 cochés + rappel, 501e coché → désactivé), 401 →
// déconnexion, bilan (activés, ignorés, rejeu).
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/ready_games.dart';
import 'package:mgt_admin/ui/widgets/games/ready_games_dialog.dart';

import 'support/widget_fixtures.dart';

ReadyGame _game(int i, {int total = 12, int distinct = 12}) => ReadyGame(
  id: 'g$i',
  name: 'Jeu $i',
  validatedTotal: total,
  video: 6,
  guides: 4,
  links: 2,
  distinctUrls: distinct,
);

ReadyGamesPreview _preview(List<ReadyGame> games) => ReadyGamesPreview(
  threshold: 10,
  inactiveTotal: games.length + 5,
  count: games.length,
  games: games,
);

Future<DialogProbe<ActivateReadyResult>> _open(
  WidgetTester tester,
  ReadyGamesPreview preview, {
  Future<ActivateReadyResult> Function(List<String>)? apply,
  VoidCallback? onAuthError,
}) async {
  final DialogProbe<ActivateReadyResult> probe =
      await openDialog<ActivateReadyResult>(
        tester,
        (_) => ReadyGamesDialog(
          preview: preview,
          apply:
              apply ??
              (List<String> ids) async => ActivateReadyResult(
                threshold: 10,
                requested: ids.length,
                activated: <ActivatedGame>[
                  for (final String id in ids)
                    ActivatedGame(
                      id: id,
                      name: 'Jeu ${id.substring(1)}',
                      validatedTotal: 12,
                    ),
                ],
                skipped: const <SkippedGame>[],
              ),
          onAuthError: onAuthError ?? () {},
        ),
      );
  await tester.pumpAndSettle();
  return probe;
}

FilledButton _applyButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('games-ready-apply')));

bool _checked(WidgetTester tester, String id) => tester
    .widget<CheckboxListTile>(find.byKey(ValueKey<String>('games-ready-$id')))
    .value!;

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('games-ready-apply')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('games-ready-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('titre, lignes, toutes cochées ; décocher 1 → « Activer 2 »', (
    WidgetTester tester,
  ) async {
    await _open(tester, _preview(<ReadyGame>[_game(1), _game(2), _game(3)]));
    expect(
      find.text('Jeux prêts à activer (seuil : 10 contenus validés)'),
      findsOneWidget,
    );
    expect(find.text('Jeu 1 — 12 contenus (V 6 · G 4 · L 2)'), findsOneWidget);
    for (final String id in <String>['g1', 'g2', 'g3']) {
      expect(_checked(tester, id), isTrue, reason: id);
    }
    expect(find.text('Activer 3 jeu(x)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('games-ready-g2')));
    await tester.pump();
    expect(find.text('Activer 2 jeu(x)'), findsOneWidget);
    expect(_applyButton(tester).onPressed, isNotNull);
  });

  testWidgets('tout décocher → désactivé ; tout cocher → réactivé', (
    WidgetTester tester,
  ) async {
    await _open(tester, _preview(<ReadyGame>[_game(1), _game(2)]));
    await tester.tap(find.byKey(const Key('games-ready-none')));
    await tester.pump();
    expect(_applyButton(tester).onPressed, isNull);
    expect(find.text('Aucun jeu sélectionné.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('games-ready-all')));
    await tester.pump();
    expect(_applyButton(tester).onPressed, isNotNull);
    expect(find.text('Activer 2 jeu(x)'), findsOneWidget);
  });

  testWidgets('doublons d\'URL signalés', (WidgetTester tester) async {
    await _open(
      tester,
      _preview(<ReadyGame>[_game(1, total: 12, distinct: 10), _game(2)]),
    );
    expect(find.text('2 URL en double'), findsOneWidget);
  });

  testWidgets('confirmation puis apply reçoit les ids cochés ; bilan', (
    WidgetTester tester,
  ) async {
    final List<List<String>> sent = <List<String>>[];
    final DialogProbe<ActivateReadyResult> probe = await _open(
      tester,
      _preview(<ReadyGame>[_game(1), _game(2), _game(3)]),
      apply: (List<String> ids) async {
        sent.add(ids);
        return const ActivateReadyResult(
          threshold: 10,
          requested: 2,
          activated: <ActivatedGame>[
            ActivatedGame(id: 'g1', name: 'Jeu 1', validatedTotal: 12),
          ],
          skipped: <SkippedGame>[
            SkippedGame(id: 'g3', reason: 'below_threshold'),
          ],
        );
      },
    );
    await tester.tap(find.byKey(const ValueKey<String>('games-ready-g2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('games-ready-apply')));
    await tester.pumpAndSettle();
    expect(find.text('Activer 2 jeu(x) ?'), findsOneWidget);
    expect(
      find.text("Ils deviendront visibles dans l'application."),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('games-ready-confirm')));
    await tester.pumpAndSettle();
    expect(sent, <List<String>>[
      <String>['g1', 'g3'],
    ]);
    expect(find.text('1 jeu(x) activé(s)'), findsOneWidget);
    expect(find.text('• Jeu 1'), findsOneWidget);
    expect(
      find.text('• Jeu 3 : sous le seuil (contenus retirés entre-temps)'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('games-ready-close')));
    await tester.pumpAndSettle();
    expect(probe.result!.activated.single.id, 'g1');
  });

  testWidgets('confirmation annulée → rien envoyé', (
    WidgetTester tester,
  ) async {
    int calls = 0;
    await _open(
      tester,
      _preview(<ReadyGame>[_game(1)]),
      apply: (List<String> ids) async {
        calls++;
        return const ActivateReadyResult(
          threshold: 10,
          requested: 1,
          activated: <ActivatedGame>[],
          skipped: <SkippedGame>[],
        );
      },
    );
    await tester.tap(find.byKey(const Key('games-ready-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('games-ready-confirm-cancel')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byType(ReadyGamesDialog), findsOneWidget);
  });

  testWidgets('501 jeux : 500 cochés, rappel de la limite, bouton actif ; '
      'cocher le 501e → désactivé', (WidgetTester tester) async {
    final List<ReadyGame> games = <ReadyGame>[
      for (int i = 1; i <= 501; i++) _game(i),
    ];
    await _open(tester, _preview(games));
    expect(find.text('Activer 500 jeu(x)'), findsOneWidget);
    expect(_applyButton(tester).onPressed, isNotNull);
    expect(find.text(kReadyGamesOverLimitNotice), findsOneWidget);
    expect(_checked(tester, 'g1'), isTrue);

    final Finder last = find.byKey(const ValueKey<String>('games-ready-g501'));
    await tester.scrollUntilVisible(
      last,
      2000,
      scrollable: find.descendant(
        of: find.byType(ReadyGamesDialog),
        matching: find.byType(Scrollable),
      ),
    );
    expect(_checked(tester, 'g501'), isFalse);
    await tester.tap(last);
    await tester.pump();
    expect(find.text('Activer 501 jeu(x)'), findsOneWidget);
    expect(_applyButton(tester).onPressed, isNull);
    expect(
      find.textContaining(
        '500 jeux au plus par activation (limite du '
        'serveur) : décochez-en 1',
      ),
      findsOneWidget,
    );
  });

  testWidgets('401 → onAuthError et fermeture', (WidgetTester tester) async {
    int auth = 0;
    final DialogProbe<ActivateReadyResult> probe = await _open(
      tester,
      _preview(<ReadyGame>[_game(1)]),
      apply: (_) async => throw const AdminAuthException('Session expirée'),
      onAuthError: () => auth++,
    );
    await _confirm(tester);
    expect(auth, 1);
    expect(probe.closed, isTrue);
    expect(find.byType(ReadyGamesDialog), findsNothing);
  });

  testWidgets(
    '403 → « Réservé au compte principal. » ; 500 → message tel quel',
    (WidgetTester tester) async {
      int calls = 0;
      await _open(
        tester,
        _preview(<ReadyGame>[_game(1)]),
        apply: (_) async {
          calls++;
          if (calls == 1) throw const AdminForbiddenException('interdit');
          throw const AdminApiException(500, 'Activation impossible');
        },
      );
      await _confirm(tester);
      expect(find.text('Réservé au compte principal.'), findsOneWidget);
      await _confirm(tester);
      expect(find.text('Activation impossible'), findsOneWidget);
    },
  );

  testWidgets('rejeu : tous déjà actifs → message dédié', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      _preview(<ReadyGame>[_game(1), _game(2)]),
      apply: (_) async => const ActivateReadyResult(
        threshold: 10,
        requested: 2,
        activated: <ActivatedGame>[],
        skipped: <SkippedGame>[
          SkippedGame(id: 'g1', reason: 'already_active'),
          SkippedGame(id: 'g2', reason: 'already_active'),
        ],
        replayed: true,
      ),
    );
    await _confirm(tester);
    expect(find.text(kReadyGamesAllAlreadyActive), findsOneWidget);
  });

  testWidgets('aperçu vide → message et « Fermer »', (
    WidgetTester tester,
  ) async {
    await _open(tester, _preview(const <ReadyGame>[]));
    expect(
      find.text(
        'Aucun jeu prêt : 5 jeu(x) inactif(s), seuil : 10 contenus '
        'validés.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('games-ready-apply')), findsNothing);
  });
}
