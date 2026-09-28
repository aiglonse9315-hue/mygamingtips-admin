// Confirmation FORTE « Allumer » / « Réarmer » le ban automatique (P4b-3,
// lot L5, S-01, UX-01, conception §6.6, §7.1) : bouton désactivé tant que
// la case n'est pas cochée, avertissement quand un plafond est déjà
// atteint, `true` seulement après case + bouton, `false` sur Annuler.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/ui/widgets/moderation/strong_confirm_dialog.dart';

import 'support/widget_fixtures.dart';

const String _warning =
    'Un plafond est déjà atteint : le disjoncteur se redéclenchera au '
    "prochain ban éligible. Relevez d'abord le plafond.";

Future<void> _rearm(
  WidgetTester tester, {
  required int hour,
  required int day,
}) async {
  await openDialog<bool>(
    tester,
    (_) => StrongConfirmDialog(
      title: 'Réarmer le disjoncteur et RALLUMER le ban automatique ?',
      text: 'Disjoncteur déclenché : plafond horaire atteint.',
      extra: <Widget>[
        AutoBanCountersNotice(hour: hour, maxHour: 3, day: day, maxDay: 10),
      ],
      checkboxLabel:
          "J'ai examiné la cause du déclenchement ; le ban automatique sera "
          'rallumé.',
      confirmLabel: 'Réarmer',
      confirmColor: Colors.orange.shade700,
    ),
  );
  await tester.pumpAndSettle();
}

FilledButton _confirm(WidgetTester tester) => tester.widget<FilledButton>(
  find.byKey(const Key('moderation-strong-confirm')),
);

void main() {
  testWidgets('« Réarmer » désactivé tant que la case n\'est pas cochée ; '
      'case + bouton → true', (WidgetTester tester) async {
    final DialogProbe<bool> probe = await openDialog<bool>(
      tester,
      (_) => const StrongConfirmDialog(
        title: 'Allumer le ban automatique ?',
        text: 'Des comptes, chaînes et pages pourront être bannis.',
        checkboxLabel:
            'Je comprends que des bans automatiques pourront être posés sans '
            'moi.',
        confirmLabel: 'Allumer',
      ),
    );
    await tester.pumpAndSettle();
    expect(_confirm(tester).onPressed, isNull);
    await tester.tap(find.byKey(const Key('moderation-strong-confirm')));
    await tester.pumpAndSettle();
    expect(probe.closed, isFalse, reason: 'bouton inactif : rien ne se passe');

    await tester.tap(find.byKey(const Key('moderation-strong-checkbox')));
    await tester.pump();
    expect(_confirm(tester).onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('moderation-strong-confirm')));
    await tester.pumpAndSettle();
    expect(probe.closed, isTrue);
    expect(probe.result, isTrue);
  });

  testWidgets('compteurs 3/3 → encart « Un plafond est déjà atteint… »', (
    WidgetTester tester,
  ) async {
    await _rearm(tester, hour: 3, day: 7);
    expect(
      find.text('Bans automatiques : 3/3 (1 h) · 7/10 (24 h)'),
      findsOneWidget,
    );
    expect(find.text(_warning), findsOneWidget);
    expect(find.text('Réarmer'), findsOneWidget);
  });

  testWidgets('compteurs 2/3 et 7/10 → aucun encart', (
    WidgetTester tester,
  ) async {
    await _rearm(tester, hour: 2, day: 7);
    expect(find.text(_warning), findsNothing);
    expect(find.byKey(const Key('moderation-ceiling-warning')), findsNothing);
  });

  testWidgets('Annuler → false, même case cochée', (WidgetTester tester) async {
    final DialogProbe<bool> probe = await openDialog<bool>(
      tester,
      (_) => const StrongConfirmDialog(
        title: 'Allumer le ban automatique ?',
        text: 'Texte.',
        checkboxLabel: 'Je comprends.',
        confirmLabel: 'Allumer',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moderation-strong-checkbox')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('moderation-strong-cancel')));
    await tester.pumpAndSettle();
    expect(probe.closed, isTrue);
    expect(probe.result, isFalse);
  });

  testWidgets('StrongConfirmDialog.show : fermeture hors du dialogue → false', (
    WidgetTester tester,
  ) async {
    setWindow(tester);
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                result = await StrongConfirmDialog.show(
                  context,
                  title: 'Allumer le ban automatique ?',
                  text: 'Texte.',
                  checkboxLabel: 'Je comprends.',
                  confirmLabel: 'Allumer',
                );
              },
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
