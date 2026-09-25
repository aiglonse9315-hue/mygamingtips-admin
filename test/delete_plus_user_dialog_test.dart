// Suppression définitive d'un abonnement Plus (25/09/2026) : la
// confirmation ne se déclenche PAS par inadvertance (case à cocher
// obligatoire) et prévient pour un abonnement Google Play.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/models/plus_user.dart';
import 'package:mgt_admin/ui/widgets/delete_plus_user_dialog.dart';

void main() {
  PlusUser user({String source = 'admin'}) => PlusUser(
        id: '00000000-0000-4000-8000-000000000001',
        displayName: 'Nox',
        plan: 'yearly',
        startedAt: DateTime(2026, 9, 1),
        source: source,
      );

  Future<void> open(WidgetTester tester, PlusUser u, VoidCallback onConfirm) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => DeletePlusUserDialog(user: u, onConfirm: onConfirm),
            ),
            child: const Text('ouvrir'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
  }

  FilledButton confirmButton(WidgetTester tester) => tester.widget<FilledButton>(
        find.byKey(const Key('delete-plus-confirm-button')),
      );

  testWidgets('bouton grisé tant que la case n\'est pas cochée', (tester) async {
    var calls = 0;
    await open(tester, user(), () => calls++);
    expect(find.textContaining('Supprimer définitivement l\'abonnement de Nox'),
        findsOneWidget);
    expect(confirmButton(tester).onPressed, isNull);
    await tester.tap(find.byKey(const Key('delete-plus-confirm-button')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byType(DeletePlusUserDialog), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-plus-confirm-checkbox')));
    await tester.pump();
    expect(confirmButton(tester).onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('delete-plus-confirm-button')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(DeletePlusUserDialog), findsNothing);
  });

  testWidgets('Annuler ne supprime rien', (tester) async {
    var calls = 0;
    await open(tester, user(), () => calls++);
    await tester.tap(find.byKey(const Key('delete-plus-confirm-checkbox')));
    await tester.pump();
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byType(DeletePlusUserDialog), findsNothing);
  });

  testWidgets('avertissement Google Play seulement pour un abonnement Google',
      (tester) async {
    await open(tester, user(source: 'google_verified'), () {});
    expect(find.textContaining('ne l\'annule PAS'), findsOneWidget);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();

    await open(tester, user(), () {});
    expect(find.textContaining('ne l\'annule PAS'), findsNothing);
  });
}
