// Tuile d'un élément de la file de revue (P4b-3, lot L5, conception §6.3,
// §7.1) : boutons selon le type (clés `moderation-action-<id>-<action>`),
// badge « Ban manuel présent », « sans preuve », URL de page longue sur une
// ligne, boutons désactivés pendant une décision, action transmise.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/models/moderation.dart';
import 'package:mgt_admin/domain/moderation_actions.dart';
import 'package:mgt_admin/ui/widgets/moderation/review_queue_tile.dart';

import 'support/widget_fixtures.dart';

Future<void> _pumpTile(
  WidgetTester tester,
  ReviewItem item, {
  bool busy = false,
  void Function(ReviewAction)? onAction,
}) async {
  await pumpBody(
    tester,
    ReviewQueueTile(item: item, busy: busy, onAction: onAction ?? (_) {}),
  );
}

Finder _action(int id, ReviewAction a) =>
    find.byKey(ValueKey<String>('moderation-action-$id-${a.name}'));

void main() {
  group('boutons par type d\'élément', () {
    final Map<String, List<ReviewAction>> expected =
        <String, List<ReviewAction>>{
          'ban_en_revue': <ReviewAction>[
            ReviewAction.detail,
            ReviewAction.confirm,
            ReviewAction.lift,
          ],
          'a_examiner': <ReviewAction>[
            ReviewAction.detail,
            ReviewAction.apply,
            ReviewAction.dismiss,
          ],
          'refus_a_revoir': <ReviewAction>[
            ReviewAction.detail,
            ReviewAction.apply,
            ReviewAction.dismiss,
          ],
          'type_futur': <ReviewAction>[ReviewAction.detail],
        };
    expected.forEach((String kind, List<ReviewAction> actions) {
      testWidgets(kind, (WidgetTester tester) async {
        await _pumpTile(tester, reviewItem(id: 3, kind: kind));
        for (final ReviewAction a in ReviewAction.values) {
          expect(
            _action(3, a),
            actions.contains(a) ? findsOneWidget : findsNothing,
            reason: '$kind → ${a.name}',
          );
        }
      });
    });
  });

  testWidgets('libellés des boutons et du type', (WidgetTester tester) async {
    await _pumpTile(tester, reviewItem(kind: 'ban_en_revue'));
    expect(find.text('Ban en revue'), findsOneWidget);
    expect(find.text('Détail'), findsOneWidget);
    expect(find.text('Confirmer'), findsOneWidget);
    expect(find.text('Lever'), findsOneWidget);
    expect(find.text('#7'), findsOneWidget);
    expect(find.text('Ban automatique éteint'), findsOneWidget);
  });

  testWidgets('badge « Ban manuel présent » seulement en cas de conflit', (
    WidgetTester tester,
  ) async {
    await _pumpTile(tester, reviewItem(manualBanPresent: true));
    expect(find.text('Ban manuel présent'), findsOneWidget);
    await _pumpTile(tester, reviewItem());
    expect(find.text('Ban manuel présent'), findsNothing);
  });

  testWidgets('« sans preuve » / « Preuve conservée »', (
    WidgetTester tester,
  ) async {
    await _pumpTile(tester, reviewItem(hasEvidence: false));
    expect(find.text('sans preuve'), findsOneWidget);
    expect(find.text('Preuve conservée'), findsNothing);
    await _pumpTile(tester, reviewItem());
    expect(find.text('Preuve conservée'), findsOneWidget);
    expect(find.text('sans preuve'), findsNothing);
  });

  testWidgets('URL de page longue : une seule ligne, aucun débordement', (
    WidgetTester tester,
  ) async {
    final String url = 'https://exemple.test/${'segment/' * 250}fin';
    await _pumpTile(
      tester,
      reviewItem(kind: 'a_examiner', targetKind: 'page', targetKey: url),
    );
    expect(tester.takeException(), isNull);
    final Text t = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('moderation-tile-target')),
        matching: find.byType(Text),
      ),
    );
    expect(t.maxLines, 1);
    expect(t.softWrap, isFalse);
    expect(t.data!.runes.length, lessThanOrEqualTo(121));
    expect(t.data, endsWith('…'));
  });

  testWidgets('compte : nom révélé, « (profil supprimé) » si absent', (
    WidgetTester tester,
  ) async {
    final String rlo = String.fromCharCode(0x202E);
    await _pumpTile(tester, reviewItem(accountDisplayName: 'Nom${rlo}xe'));
    expect(
      shownText(tester, find.byKey(const Key('moderation-tile-target'))),
      'Nom⟦U+202E⟧xe',
    );
    await _pumpTile(tester, reviewItem(accountDisplayName: null));
    expect(
      shownText(tester, find.byKey(const Key('moderation-tile-target'))),
      '(profil supprimé)',
    );
  });

  testWidgets('chaîne : plateforme, groupe, auteur du partage', (
    WidgetTester tester,
  ) async {
    await _pumpTile(
      tester,
      reviewItem(
        kind: 'ban_en_revue',
        targetKind: 'channel',
        targetKey: 'UCexemple0123456789',
        platform: 'youtube',
        groupSize: 3,
        suggestionAuthorId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
      ),
    );
    expect(find.text('YouTube · '), findsOneWidget);
    expect(find.text('Groupe : 3'), findsOneWidget);
    expect(find.text('Auteur du partage : aaaaaaaa…'), findsOneWidget);
  });

  testWidgets('occupée : boutons désactivés', (WidgetTester tester) async {
    await _pumpTile(tester, reviewItem(), busy: true);
    for (final ReviewAction a in <ReviewAction>[
      ReviewAction.detail,
      ReviewAction.confirm,
      ReviewAction.lift,
    ]) {
      final ButtonStyleButton b = tester.widget<ButtonStyleButton>(
        _action(7, a),
      );
      expect(b.onPressed, isNull, reason: a.name);
    }
  });

  testWidgets('le rappel reçoit l\'action pressée', (
    WidgetTester tester,
  ) async {
    final List<ReviewAction> got = <ReviewAction>[];
    await _pumpTile(tester, reviewItem(), onAction: got.add);
    await tester.tap(_action(7, ReviewAction.lift));
    await tester.tap(_action(7, ReviewAction.detail));
    expect(got, <ReviewAction>[ReviewAction.lift, ReviewAction.detail]);
  });
}
