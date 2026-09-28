// « Bannir un compte » du tableau de bord (P4b-3, lot L6, T4, D4,
// conception §6.10) : saisie e-mail OU identifiant (plus de champ « Nom /
// Pseudo »), catégorie (4, défaut « Modération »), motif normalisé ; échec →
// message DANS le dialogue resté OUVERT ; session expirée → fermé ; succès
// → fermé en rendant l'issue.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/data/supabase_sync.dart' show AdminApiException;
import 'package:mgt_admin/domain/models/ban_category.dart';
import 'package:mgt_admin/domain/write_outcome.dart';
import 'package:mgt_admin/ui/widgets/moderation/ban_account_by_email_dialog.dart';

import 'support/widget_fixtures.dart';

typedef _Call = ({String input, String category, String? reason});

Future<DialogProbe<WriteOutcome>> _open(
  WidgetTester tester,
  List<_Call> calls,
  Future<WriteOutcome> Function(_Call c) respond,
) => openDialog<WriteOutcome>(
  tester,
  (_) => BanAccountByEmailDialog(
    categories: kManualBanCategoriesFallback,
    submit: (String input, String category, String? reason) {
      final _Call c = (input: input, category: category, reason: reason);
      calls.add(c);
      return respond(c);
    },
  ),
);

FilledButton _submitButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('ban-email-submit')));

void main() {
  testWidgets('libellés : champ e-mail ou identifiant, aide, catégorie, '
      'motif, encart ; plus de « Nom / Pseudo »', (WidgetTester tester) async {
    await _open(tester, <_Call>[], (_) async => const WriteOutcome.ok());
    expect(find.text('Bannir un compte'), findsOneWidget);
    expect(find.text('E-mail ou identifiant du compte *'), findsOneWidget);
    expect(
      find.text('Adresse e-mail du compte ou son identifiant (UUID).'),
      findsOneWidget,
    );
    expect(find.text('Catégorie'), findsOneWidget);
    expect(find.text('Modération'), findsOneWidget, reason: 'défaut');
    expect(find.text('Motif (facultatif)'), findsOneWidget);
    expect(find.text('0/500'), findsOneWidget);
    expect(
      find.text(
        "Le compte banni ne pourra plus soumettre de suggestions dans "
        "l'application.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Pseudo'), findsNothing);
  });

  testWidgets('champ vide → « Bannir » désactivé ; saisie → actif', (
    WidgetTester tester,
  ) async {
    await _open(tester, <_Call>[], (_) async => const WriteOutcome.ok());
    expect(_submitButton(tester).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('ban-email-input')), '   ');
    await tester.pump();
    expect(_submitButton(tester).onPressed, isNull, reason: 'espaces seuls');
    await tester.enterText(
      find.byKey(const Key('ban-email-input')),
      'p1@exemple.test',
    );
    await tester.pump();
    expect(_submitButton(tester).onPressed, isNotNull);
  });

  testWidgets('succès : saisie brute, catégorie choisie, motif coupé ; '
      'fermé avec l’issue', (WidgetTester tester) async {
    final List<_Call> calls = <_Call>[];
    final DialogProbe<WriteOutcome> probe = await _open(
      tester,
      calls,
      (_) async => const WriteOutcome.ok(),
    );
    await tester.enterText(
      find.byKey(const Key('ban-email-input')),
      ' P1@Exemple.TEST ',
    );
    await tester.enterText(
      find.byKey(const Key('ban-email-reason')),
      '  motif neutre  ',
    );
    await tester.tap(find.byKey(const Key('ban-category-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spam').last);
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.tap(find.byKey(const Key('ban-email-submit')));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(calls.single.input, ' P1@Exemple.TEST ');
    expect(calls.single.category, 'spam');
    expect(calls.single.reason, 'motif neutre');
    expect(probe.closed, isTrue);
    expect(probe.result?.ok, isTrue);
  });

  testWidgets('motif vide → envoyé nul', (WidgetTester tester) async {
    final List<_Call> calls = <_Call>[];
    await _open(tester, calls, (_) async => const WriteOutcome.ok());
    await tester.enterText(
      find.byKey(const Key('ban-email-input')),
      '11111111-2222-4333-8444-555555555555',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('ban-email-submit')));
    await tester.pumpAndSettle();
    expect(calls.single.reason, isNull);
    expect(calls.single.category, 'moderation');
  });

  testWidgets('échec (e-mail inconnu) → message DANS le dialogue, resté '
      'ouvert ; nouvel essai possible', (WidgetTester tester) async {
    final List<_Call> calls = <_Call>[];
    final DialogProbe<WriteOutcome> probe = await _open(
      tester,
      calls,
      (_) async => const WriteOutcome.failed('Aucun compte avec cet e-mail.'),
    );
    await tester.enterText(
      find.byKey(const Key('ban-email-input')),
      'inconnu@exemple.test',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('ban-email-submit')));
    await tester.pumpAndSettle();
    expect(probe.closed, isFalse);
    expect(find.byKey(const Key('ban-email-error')), findsOneWidget);
    expect(find.text('Aucun compte avec cet e-mail.'), findsOneWidget);
    expect(_submitButton(tester).onPressed, isNotNull, reason: 'réessayer');
    await tester.pump();
    await tester.tap(find.byKey(const Key('ban-email-submit')));
    await tester.pumpAndSettle();
    expect(calls, hasLength(2));
  });

  testWidgets('exception inattendue → message sans « Exception: », ouvert', (
    WidgetTester tester,
  ) async {
    final DialogProbe<WriteOutcome> probe = await _open(
      tester,
      <_Call>[],
      (_) async => throw const AdminApiException(500, 'Erreur serveur.'),
    );
    await tester.enterText(
      find.byKey(const Key('ban-email-input')),
      'p1@exemple.test',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('ban-email-submit')));
    await tester.pumpAndSettle();
    expect(probe.closed, isFalse);
    expect(find.text('Erreur serveur.'), findsOneWidget);
  });

  testWidgets('session expirée → fermé, issue rendue (déconnexion déjà '
      'lancée)', (WidgetTester tester) async {
    final DialogProbe<WriteOutcome> probe = await _open(
      tester,
      <_Call>[],
      (_) async => const WriteOutcome.sessionExpired(),
    );
    await tester.enterText(
      find.byKey(const Key('ban-email-input')),
      'p1@exemple.test',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('ban-email-submit')));
    await tester.pumpAndSettle();
    expect(probe.closed, isTrue);
    expect(probe.result?.sessionExpired, isTrue);
    expect(find.byKey(const Key('ban-email-error')), findsNothing);
  });

  testWidgets('motif de 501 points de code → « Bannir » désactivé', (
    WidgetTester tester,
  ) async {
    await _open(tester, <_Call>[], (_) async => const WriteOutcome.ok());
    await tester.enterText(
      find.byKey(const Key('ban-email-input')),
      'p1@exemple.test',
    );
    await tester.enterText(
      find.byKey(const Key('ban-email-reason')),
      'a' * 501,
    );
    await tester.pump();
    expect(_submitButton(tester).onPressed, isNull);
    expect(find.text('501/500'), findsOneWidget);
  });

  testWidgets('Annuler → fermé sans appel', (WidgetTester tester) async {
    final List<_Call> calls = <_Call>[];
    final DialogProbe<WriteOutcome> probe = await _open(
      tester,
      calls,
      (_) async => const WriteOutcome.ok(),
    );
    await tester.tap(find.byKey(const Key('ban-email-cancel')));
    await tester.pumpAndSettle();
    expect(probe.closed, isTrue);
    expect(probe.result, isNull);
    expect(calls, isEmpty);
  });
}
