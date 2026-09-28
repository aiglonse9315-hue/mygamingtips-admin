// Dialogues de ban / déban MANUELS (P4b-3, lot L5, D4, T3, T4, T6,
// conception §6.9-§6.12, §7.1) : liste déroulante des 4 catégories
// (« Injection IA » jamais proposée), champ motif en points de code, ban d'un
// compte (encart ban auto en cours, échec → dialogue ouvert, session
// expirée → fermé), déban (texte d'exemption, 409 ban auto rendu), lot et
// bilan.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/models/ban_category.dart';
import 'package:mgt_admin/domain/moderation_actions.dart';
import 'package:mgt_admin/domain/write_outcome.dart';
import 'package:mgt_admin/ui/widgets/moderation/ban_account_dialog.dart';
import 'package:mgt_admin/ui/widgets/moderation/ban_batch_dialog.dart';
import 'package:mgt_admin/ui/widgets/moderation/ban_category_dropdown.dart';
import 'package:mgt_admin/ui/widgets/moderation/reason_field.dart';
import 'package:mgt_admin/ui/widgets/moderation/unban_confirm_dialog.dart';

import 'support/widget_fixtures.dart';

/// Codes proposés par la liste déroulante (items du `DropdownButton`
/// construit par le `DropdownButtonFormField`).
List<String?> _codes(WidgetTester tester) => tester
    .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
    .items!
    .map((DropdownMenuItem<String> i) => i.value)
    .toList();

/// Réponse serveur de `moderation/categories` (0094) : 5 catégories dont
/// « Injection IA » réservée au ban automatique.
const List<BanCategory> _serverCategories = <BanCategory>[
  BanCategory(code: 'moderation', labelFr: 'Modération', autoAllowed: false),
  BanCategory(code: 'spam', labelFr: 'Spam', autoAllowed: false),
  BanCategory(code: 'abus', labelFr: 'Abus', autoAllowed: false),
  BanCategory(code: 'injection_ia', labelFr: 'Injection IA', autoAllowed: true),
  BanCategory(code: 'autre', labelFr: 'Autre', autoAllowed: false),
];

void main() {
  group('BanCategoryDropdown', () {
    testWidgets('4 options, défaut « Modération », « Injection IA » absente', (
      WidgetTester tester,
    ) async {
      final List<String> changed = <String>[];
      await pumpBody(
        tester,
        BanCategoryDropdown(
          categories: _serverCategories,
          value: 'moderation',
          onChanged: changed.add,
        ),
      );
      expect(_codes(tester), <String>['moderation', 'spam', 'abus', 'autre']);
      expect(find.text('Modération'), findsOneWidget, reason: 'défaut');
      expect(find.text('Injection IA'), findsNothing);
      await tester.tap(find.byKey(const Key('ban-category-dropdown')));
      await tester.pumpAndSettle();
      expect(find.text('Injection IA'), findsNothing);
      for (final String l in <String>['Spam', 'Abus', 'Autre']) {
        expect(find.text(l), findsWidgets, reason: l);
      }
      await tester.tap(find.text('Spam').last);
      await tester.pumpAndSettle();
      expect(changed, <String>['spam']);
    });

    testWidgets('injection_ia exclue même marquée manuelle ; valeur inconnue '
        '→ défaut « Modération »', (WidgetTester tester) async {
      await pumpBody(
        tester,
        BanCategoryDropdown(
          categories: const <BanCategory>[
            BanCategory(
              code: 'injection_ia',
              labelFr: 'Injection IA',
              autoAllowed: false,
            ),
            ...kManualBanCategoriesFallback,
          ],
          value: 'injection_ia',
          onChanged: (_) {},
        ),
      );
      expect(_codes(tester), <String>['moderation', 'spam', 'abus', 'autre']);
      expect(find.text('Injection IA'), findsNothing);
      expect(find.text('Modération'), findsOneWidget);
      expect(effectiveBanCategory(const <BanCategory>[], 'xyz'), 'moderation');
    });

    testWidgets('liste vide → repli des 4 catégories locales', (
      WidgetTester tester,
    ) async {
      await pumpBody(
        tester,
        BanCategoryDropdown(
          categories: const <BanCategory>[],
          value: 'moderation',
          onChanged: (_) {},
        ),
      );
      expect(_codes(tester), <String>['moderation', 'spam', 'abus', 'autre']);
    });
  });

  testWidgets('ReasonField : compteur en points de code, sans maxLength', (
    WidgetTester tester,
  ) async {
    final TextEditingController c = TextEditingController();
    addTearDown(c.dispose);
    await pumpBody(
      tester,
      ReasonField(controller: c, fieldKey: const Key('f')),
    );
    expect(find.text('Motif (facultatif)'), findsOneWidget);
    expect(find.text('0/500'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('f')), ' ${'🎮' * 3} ');
    await tester.pump();
    expect(find.text('3/500'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('f'))).maxLength,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('f')),
      'a${String.fromCharCode(0)}',
    );
    await tester.pump();
    expect(
      find.text('Motif invalide : caractère interdit (U+0000 ou demi-paire).'),
      findsOneWidget,
    );
  });

  group('BanAccountDialog', () {
    testWidgets('texte, encart « ban automatique en cours », envoi normalisé', (
      WidgetTester tester,
    ) async {
      final List<(String, String?)> sent = <(String, String?)>[];
      final DialogProbe<WriteOutcome> probe = await openDialog<WriteOutcome>(
        tester,
        (_) => BanAccountDialog(
          displayName: 'Compte Exemple',
          categories: _serverCategories,
          autoBanInReview: true,
          submit: (String cat, String? reason) async {
            sent.add((cat, reason));
            return const WriteOutcome.ok();
          },
        ),
      );
      expect(find.text('Bannir Compte Exemple ?'), findsOneWidget);
      expect(
        find.text(
          "Le compte ne pourra plus partager de contenus dans l'application.",
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Un bannissement automatique est en cours pour ce compte : ce ban '
          'MANUEL sera enregistré et restera en vigueur même si le ban '
          'automatique est levé.',
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('ban-account-reason')),
        '  doublons  ',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('ban-account-submit')));
      await tester.pumpAndSettle();
      expect(sent, <(String, String?)>[('moderation', 'doublons')]);
      expect(probe.closed, isTrue);
      expect(probe.result!.ok, isTrue);
    });

    testWidgets('sans ban auto en cours : pas d\'encart ; motif vide → null', (
      WidgetTester tester,
    ) async {
      final List<String?> reasons = <String?>[];
      await openDialog<WriteOutcome>(
        tester,
        (_) => BanAccountDialog(
          displayName: 'Compte Exemple',
          categories: _serverCategories,
          submit: (String cat, String? reason) async {
            reasons.add(reason);
            return const WriteOutcome.ok();
          },
        ),
      );
      expect(find.byKey(const Key('ban-account-auto-notice')), findsNothing);
      await tester.tap(find.byKey(const Key('ban-account-submit')));
      await tester.pumpAndSettle();
      expect(reasons, <String?>[null]);
    });

    testWidgets('échec → le dialogue reste ouvert avec le message', (
      WidgetTester tester,
    ) async {
      final DialogProbe<WriteOutcome> probe = await openDialog<WriteOutcome>(
        tester,
        (_) => BanAccountDialog(
          displayName: 'Compte Exemple',
          categories: _serverCategories,
          submit: (_, _) async =>
              const WriteOutcome.failed('Profil introuvable.'),
        ),
      );
      await tester.tap(find.byKey(const Key('ban-account-submit')));
      await tester.pumpAndSettle();
      expect(probe.closed, isFalse);
      expect(find.byType(BanAccountDialog), findsOneWidget);
      expect(find.text('Profil introuvable.'), findsOneWidget);
    });

    testWidgets('session expirée → fermé sans message', (
      WidgetTester tester,
    ) async {
      final DialogProbe<WriteOutcome> probe = await openDialog<WriteOutcome>(
        tester,
        (_) => BanAccountDialog(
          displayName: 'Compte Exemple',
          categories: _serverCategories,
          submit: (_, _) async => const WriteOutcome.sessionExpired(),
        ),
      );
      await tester.tap(find.byKey(const Key('ban-account-submit')));
      await tester.pumpAndSettle();
      expect(probe.closed, isTrue);
      expect(probe.result!.sessionExpired, isTrue);
    });
  });

  group('UnbanConfirmDialog', () {
    testWidgets('compte : texte d\'exemption, levé → fermé avec l\'issue', (
      WidgetTester tester,
    ) async {
      final DialogProbe<UnbanOutcome> probe = await openDialog<UnbanOutcome>(
        tester,
        (_) => UnbanConfirmDialog(
          name: 'Compte Exemple',
          submit: () async => const UnbanOutcome(UnbanKind.lifted),
        ),
      );
      expect(find.text('Débannir Compte Exemple ?'), findsOneWidget);
      expect(
        find.text(
          'Le compte pourra de nouveau partager des contenus. Ses partages '
          'ANTÉRIEURS à cette levée seront exemptés du bannissement '
          'automatique.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('ban-unban-submit')));
      await tester.pumpAndSettle();
      expect(probe.result!.kind, UnbanKind.lifted);
    });

    testWidgets('chaîne : texte propre aux chaînes', (
      WidgetTester tester,
    ) async {
      await openDialog<UnbanOutcome>(
        tester,
        (_) => UnbanConfirmDialog(
          name: '@exemple',
          channel: true,
          submit: () async => const UnbanOutcome(UnbanKind.lifted),
        ),
      );
      expect(
        find.textContaining('Les bots pourront de nouveau la proposer.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('exemptés du bannissement automatique'),
        findsOneWidget,
      );
    });

    testWidgets('409 ban auto → fermé, issue rendue avec l\'événement', (
      WidgetTester tester,
    ) async {
      final DialogProbe<UnbanOutcome> probe = await openDialog<UnbanOutcome>(
        tester,
        (_) => UnbanConfirmDialog(
          name: 'Compte Exemple',
          submit: () async =>
              const UnbanOutcome(UnbanKind.autoBan, banEventId: 42),
        ),
      );
      await tester.tap(find.byKey(const Key('ban-unban-submit')));
      await tester.pumpAndSettle();
      expect(probe.result!.kind, UnbanKind.autoBan);
      expect(probe.result!.banEventId, 42);
    });

    testWidgets('échec → message dans le dialogue resté ouvert ; Annuler', (
      WidgetTester tester,
    ) async {
      final DialogProbe<UnbanOutcome> probe = await openDialog<UnbanOutcome>(
        tester,
        (_) => UnbanConfirmDialog(
          name: 'Compte Exemple',
          submit: () async =>
              const UnbanOutcome(UnbanKind.failure, message: 'Erreur serveur.'),
        ),
      );
      await tester.tap(find.byKey(const Key('ban-unban-submit')));
      await tester.pumpAndSettle();
      expect(probe.closed, isFalse);
      expect(find.text('Erreur serveur.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ban-unban-cancel')));
      await tester.pumpAndSettle();
      expect(probe.closed, isTrue);
      expect(probe.result, isNull);
    });
  });

  group('lot de bans', () {
    testWidgets('BanBatchDialog : catégorie et motif communs → bilan rendu', (
      WidgetTester tester,
    ) async {
      final List<(String, String?)> sent = <(String, String?)>[];
      final DialogProbe<BanBatchReport> probe =
          await openDialog<BanBatchReport>(
            tester,
            (_) => BanBatchDialog(
              count: 6,
              categories: _serverCategories,
              submit: (String cat, String? reason) async {
                sent.add((cat, reason));
                return const BanBatchReport(applied: 6);
              },
            ),
          );
      expect(find.text('Bannir 6 compte(s) ?'), findsOneWidget);
      expect(
        find.text('Ils ne pourront plus soumettre de suggestions.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('ban-category-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abus').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('ban-batch-reason')),
        'lot vérifié',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('ban-batch-submit')));
      await tester.pumpAndSettle();
      expect(sent, <(String, String?)>[('abus', 'lot vérifié')]);
      expect(probe.result!.applied, 6);
    });

    testWidgets('BanBatchReportDialog : bilan, erreurs, lot interrompu', (
      WidgetTester tester,
    ) async {
      await openDialog<void>(
        tester,
        (_) => const BanBatchReportDialog(
          report: BanBatchReport(
            applied: 3,
            alreadyBanned: 1,
            errors: <({String id, String message})>[
              (
                id: '11111111-2222-4333-8444-555555555555',
                message: 'Profil introuvable.',
              ),
              (id: '99999999-2222-4333-8444-555555555555', message: 'Erreur.'),
            ],
            stoppedBySession: true,
          ),
        ),
      );
      expect(
        find.text(
          'Bilan : 3 compte(s) banni(s), 1 déjà banni(s), 2 erreur(s).',
        ),
        findsOneWidget,
      );
      expect(find.text('• 11111111… : Profil introuvable.'), findsOneWidget);
      expect(find.text('Session expirée : lot interrompu.'), findsOneWidget);
      await tester.tap(find.text('Fermer'));
      await tester.pumpAndSettle();
      expect(find.byType(BanBatchReportDialog), findsNothing);
    });

    testWidgets('bilan sans erreur ni interruption', (
      WidgetTester tester,
    ) async {
      await openDialog<void>(
        tester,
        (_) => const BanBatchReportDialog(report: BanBatchReport(applied: 2)),
      );
      expect(
        find.text(
          'Bilan : 2 compte(s) banni(s), 0 déjà banni(s), 0 erreur(s).',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('ban-batch-stopped')), findsNothing);
    });
  });
}
