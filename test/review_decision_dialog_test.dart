// Dialogues de décision de revue, de détail et de levée depuis une liste
// (P4b-3, lot L5, conception §6.4 a-c, §7.1) : motif obligatoire d'une
// levée, compteur en points de code, motif envoyé coupé, erreur 400 affichée
// dans le dialogue resté OUVERT, confirmation sans motif, 401 → fermeture
// PUIS déconnexion (S-08), autres erreurs rendues à l'appelant.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/moderation.dart';
import 'package:mgt_admin/domain/moderation_actions.dart';
import 'package:mgt_admin/ui/widgets/moderation/auto_ban_lift_dialog.dart';
import 'package:mgt_admin/ui/widgets/moderation/review_decision_dialog.dart';
import 'package:mgt_admin/ui/widgets/moderation/review_detail_dialog.dart';

import 'support/widget_fixtures.dart';

const Key _reason = Key('moderation-decision-reason');
const Key _submit = Key('moderation-decision-submit');

FilledButton _submitButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(_submit));

ReviewDecideResult _ok(String result, {String? targetKind}) =>
    ReviewDecideResult(result: result, targetKind: targetKind);

void main() {
  group('ReviewDecisionDialog', () {
    testWidgets('lever : bouton désactivé tant que le motif est vide, '
        'compteur N/500', (WidgetTester tester) async {
      await openDialog<DecisionDialogOutcome>(
        tester,
        (_) => ReviewDecisionDialog(
          decision: ReviewDecision.lift,
          targetLabel: 'Compte Exemple',
          submit: (_) async => _ok('lifted'),
          onAuthError: () {},
        ),
      );
      expect(find.text('Lever le bannissement automatique ?'), findsOneWidget);
      expect(find.text('Motif de la levée *'), findsOneWidget);
      expect(_submitButton(tester).onPressed, isNull);
      expect(find.text('0/500'), findsOneWidget);

      await tester.enterText(find.byKey(_reason), '   ');
      await tester.pump();
      expect(_submitButton(tester).onPressed, isNull, reason: 'espaces seuls');

      // 2 émojis = 2 points de code (4 unités UTF-16).
      await tester.enterText(find.byKey(_reason), '${'😀' * 2}ok');
      await tester.pump();
      expect(find.text('4/500'), findsOneWidget);
      expect(_submitButton(tester).onPressed, isNotNull);
    });

    testWidgets('motif trop long : bouton désactivé + erreur locale', (
      WidgetTester tester,
    ) async {
      await openDialog<DecisionDialogOutcome>(
        tester,
        (_) => ReviewDecisionDialog(
          decision: ReviewDecision.confirm,
          targetLabel: 'Compte Exemple',
          submit: (_) async => _ok('confirmed'),
          onAuthError: () {},
        ),
      );
      await tester.enterText(find.byKey(_reason), 'x' * 501);
      await tester.pump();
      expect(find.text('501/500'), findsOneWidget);
      expect(
        find.text('Motif trop long : 501/500 caractères.'),
        findsOneWidget,
      );
      expect(_submitButton(tester).onPressed, isNull);
    });

    testWidgets('motif avec espaces envoyé coupé ; résultat rendu', (
      WidgetTester tester,
    ) async {
      final List<String?> sent = <String?>[];
      final DialogProbe<DecisionDialogOutcome> probe =
          await openDialog<DecisionDialogOutcome>(
            tester,
            (_) => ReviewDecisionDialog(
              decision: ReviewDecision.lift,
              targetLabel: 'Compte Exemple',
              submit: (String? r) async {
                sent.add(r);
                return _ok('lifted');
              },
              onAuthError: () {},
            ),
          );
      await tester.enterText(find.byKey(_reason), '  motif de levée  ');
      await tester.pump();
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(sent, <String?>['motif de levée']);
      expect(probe.closed, isTrue);
      expect(probe.result!.result!.result, 'lifted');
      expect(
        probe.result!.outcome.message,
        'Bannissement levé. Les partages antérieurs sont exemptés du ban '
        'automatique.',
      );
    });

    testWidgets('confirmer sans motif → submit(null)', (
      WidgetTester tester,
    ) async {
      final List<String?> sent = <String?>['non appelé'];
      final DialogProbe<DecisionDialogOutcome> probe =
          await openDialog<DecisionDialogOutcome>(
            tester,
            (_) => ReviewDecisionDialog(
              decision: ReviewDecision.confirm,
              targetLabel: 'YouTube · UCexemple',
              targetKind: 'channel',
              submit: (String? r) async {
                sent
                  ..clear()
                  ..add(r);
                return _ok('confirmed', targetKind: 'channel');
              },
              onAuthError: () {},
            ),
          );
      expect(find.text('Motif (facultatif)'), findsOneWidget);
      expect(
        find.textContaining('Vous pourrez ensuite purger ses suggestions'),
        findsOneWidget,
      );
      expect(_submitButton(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(sent, <String?>[null]);
      expect(probe.result!.outcome.offerPurge, isTrue);
    });

    testWidgets('erreur 400 → dialogue OUVERT + message sous le champ', (
      WidgetTester tester,
    ) async {
      final DialogProbe<DecisionDialogOutcome> probe =
          await openDialog<DecisionDialogOutcome>(
            tester,
            (_) => ReviewDecisionDialog(
              decision: ReviewDecision.dismiss,
              targetLabel: 'Compte Exemple',
              groupSize: 3,
              submit: (_) async => throw const AdminApiException(
                400,
                'reason trop long (500 max).',
              ),
              onAuthError: () {},
            ),
          );
      expect(
        find.textContaining(
          'La décision vaut pour tout le groupe (3 '
          'événement(s)).',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(probe.closed, isFalse);
      expect(find.byType(ReviewDecisionDialog), findsOneWidget);
      expect(find.text('reason trop long (500 max).'), findsOneWidget);
      expect(_submitButton(tester).onPressed, isNotNull, reason: 'réessai');
    });

    testWidgets('409 below_threshold → fermé, erreur rendue et traduite', (
      WidgetTester tester,
    ) async {
      final DialogProbe<DecisionDialogOutcome> probe =
          await openDialog<DecisionDialogOutcome>(
            tester,
            (_) => ReviewDecisionDialog(
              decision: ReviewDecision.apply,
              targetLabel: 'YouTube · UCexemple',
              submit: (_) async => throw const AdminApiException(
                409,
                'Seuil non atteint.',
                body: <String, dynamic>{
                  'result': 'below_threshold',
                  'distinct_contents': 1,
                  'threshold': 2,
                },
              ),
              onAuthError: () {},
            ),
          );
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(probe.closed, isTrue);
      final DecisionOutcome o = probe.result!.outcome;
      expect(o.tone, OutcomeTone.warning);
      expect(
        o.message,
        startsWith('Seuil non atteint : 1/2 contenus distincts'),
      );
    });

    testWidgets('erreur réseau → fermé, issue incertaine', (
      WidgetTester tester,
    ) async {
      final DialogProbe<DecisionDialogOutcome> probe =
          await openDialog<DecisionDialogOutcome>(
            tester,
            (_) => ReviewDecisionDialog(
              decision: ReviewDecision.confirm,
              targetLabel: 'Compte Exemple',
              submit: (_) async => throw http.ClientException('coupure'),
              onAuthError: () {},
            ),
          );
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(probe.result!.outcome.uncertain, isTrue);
      expect(probe.result!.outcome.reloadQueue, isTrue);
    });

    testWidgets('401 → onAuthError appelé et dialogue fermé', (
      WidgetTester tester,
    ) async {
      int auth = 0;
      final DialogProbe<DecisionDialogOutcome> probe =
          await openDialog<DecisionDialogOutcome>(
            tester,
            (_) => ReviewDecisionDialog(
              decision: ReviewDecision.confirm,
              targetLabel: 'Compte Exemple',
              submit: (_) async =>
                  throw const AdminAuthException('Session expirée'),
              onAuthError: () => auth++,
            ),
          );
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(auth, 1);
      expect(probe.closed, isTrue);
      expect(probe.result, isNull);
      expect(find.byType(ReviewDecisionDialog), findsNothing);
    });

    testWidgets('levée avec ban manuel présent → encart', (
      WidgetTester tester,
    ) async {
      await openDialog<DecisionDialogOutcome>(
        tester,
        (_) => ReviewDecisionDialog(
          decision: ReviewDecision.lift,
          targetLabel: 'Compte Exemple',
          manualBanPresent: true,
          submit: (_) async => _ok('lifted'),
          onAuthError: () {},
        ),
      );
      expect(
        find.text(
          'Un ban MANUEL a été posé pendant la revue : la cible restera '
          'bannie (ban manuel).',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Annuler → null, rien envoyé', (WidgetTester tester) async {
      int calls = 0;
      final DialogProbe<DecisionDialogOutcome> probe =
          await openDialog<DecisionDialogOutcome>(
            tester,
            (_) => ReviewDecisionDialog(
              decision: ReviewDecision.confirm,
              targetLabel: 'Compte Exemple',
              submit: (_) async {
                calls++;
                return _ok('confirmed');
              },
              onAuthError: () {},
            ),
          );
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(probe.closed, isTrue);
      expect(probe.result, isNull);
    });
  });

  group('ReviewDetailDialog', () {
    testWidgets('chargement 401 → onAuthError appelé et dialogue fermé', (
      WidgetTester tester,
    ) async {
      int auth = 0;
      final DialogProbe<ReviewAction> probe = await openDialog<ReviewAction>(
        tester,
        (_) => ReviewDetailDialog(
          load: () async => throw const AdminAuthException('Session expirée'),
          onAuthError: () => auth++,
        ),
      );
      await tester.pumpAndSettle();
      expect(auth, 1);
      expect(probe.closed, isTrue);
      expect(find.byType(ReviewDetailDialog), findsNothing);
    });

    testWidgets('404 / 403 : messages exacts, sans « Réessayer »', (
      WidgetTester tester,
    ) async {
      await openDialog<ReviewAction>(
        tester,
        (_) => ReviewDetailDialog(
          load: () async =>
              throw const AdminApiException(404, 'Événement introuvable.'),
          onAuthError: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Événement introuvable.'), findsOneWidget);
      expect(find.text('Réessayer'), findsNothing);
      await tester.tap(find.byKey(const Key('moderation-detail-close')));
      await tester.pumpAndSettle();

      await openDialog<ReviewAction>(
        tester,
        (_) => ReviewDetailDialog(
          load: () async => throw const AdminForbiddenException('interdit'),
          onAuthError: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Réservé au compte principal.'), findsOneWidget);
    });

    testWidgets('autre erreur : message + « Réessayer » qui recharge', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      await openDialog<ReviewAction>(
        tester,
        (_) => ReviewDetailDialog(
          load: () async {
            calls++;
            if (calls == 1) {
              throw const AdminApiException(502, 'Erreur serveur (HTTP 502).');
            }
            return reviewDetail(note: 'Motif neutre');
          },
          actions: const <ReviewAction>[
            ReviewAction.detail,
            ReviewAction.confirm,
            ReviewAction.lift,
          ],
          onAuthError: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Erreur serveur (HTTP 502).'), findsOneWidget);
      await tester.tap(find.text('Réessayer'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('Événement #7 — Bannissement'), findsOneWidget);
      // « Détail » n'est pas proposé dans le détail lui-même.
      expect(
        find.byKey(const ValueKey<String>('moderation-detail-action-detail')),
        findsNothing,
      );
    });

    testWidgets('détail chargé : sections, empreintes copiables, membres ; '
        'une action ferme en la rendant', (WidgetTester tester) async {
      final String sha = 'ab' * 32;
      final List<ReviewAction> chosen = <ReviewAction>[];
      final DialogProbe<ReviewAction> probe = await openDialog<ReviewAction>(
        tester,
        (_) => ReviewDetailDialog(
          load: () async => reviewDetail(
            rulesSha256: sha,
            rawSha256: 'pas une empreinte',
            headId: 7,
            size: 105,
            members: List<int>.generate(100, (int i) => 100 + i),
          ),
          actions: const <ReviewAction>[
            ReviewAction.confirm,
            ReviewAction.lift,
          ],
          onAction: chosen.add,
          onAuthError: () {},
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Cible'), findsOneWidget);
      expect(find.text('Décision du détecteur'), findsOneWidget);
      expect(find.text('Preuve (texte brut)'), findsOneWidget);
      expect(find.text('Tête #7 — 105 événement(s)'), findsOneWidget);
      expect(
        shownText(tester, find.byKey(const Key('moderation-detail-members'))),
        endsWith(' … et 4 autres'),
      );
      expect(
        find.byKey(const ValueKey<String>('moderation-copy-rules')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('moderation-copy-raw')),
        findsNothing,
        reason: 'pas de « Copier » pour une valeur qui n\'est pas 64 hex',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('moderation-detail-action-lift')),
      );
      await tester.pumpAndSettle();
      expect(probe.result, ReviewAction.lift);
      expect(chosen, <ReviewAction>[ReviewAction.lift]);
    });
  });

  group('AutoBanLiftDialog', () {
    testWidgets('chargement du détail 401 → onAuthError et fermeture', (
      WidgetTester tester,
    ) async {
      int auth = 0;
      final DialogProbe<DecisionDialogOutcome> probe =
          await openDialog<DecisionDialogOutcome>(
            tester,
            (_) => AutoBanLiftDialog(
              loadDetail: () async =>
                  throw const AdminAuthException('Session expirée'),
              submit: (_) async => _ok('lifted'),
              targetLabel: 'Compte Exemple',
              onAuthError: () => auth++,
            ),
          );
      await tester.pumpAndSettle();
      expect(auth, 1);
      expect(probe.closed, isTrue);
      expect(find.byType(AutoBanLiftDialog), findsNothing);
    });

    testWidgets('décision 401 → onAuthError et fermeture', (
      WidgetTester tester,
    ) async {
      int auth = 0;
      final DialogProbe<DecisionDialogOutcome> probe =
          await openDialog<DecisionDialogOutcome>(
            tester,
            (_) => AutoBanLiftDialog(
              loadDetail: () async => reviewDetail(),
              submit: (_) async =>
                  throw const AdminAuthException('Session expirée'),
              targetLabel: 'Compte Exemple',
              onAuthError: () => auth++,
            ),
          );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('moderation-decision-detail')),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(_reason), 'levée vérifiée');
      await tester.pump();
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      expect(auth, 1);
      expect(probe.closed, isTrue);
      expect(probe.result, isNull);
    });

    testWidgets('détail replié + levée : motif obligatoire, résultat rendu', (
      WidgetTester tester,
    ) async {
      final DialogProbe<DecisionDialogOutcome> probe =
          await openDialog<DecisionDialogOutcome>(
            tester,
            (_) => AutoBanLiftDialog(
              loadDetail: () async =>
                  reviewDetail(evidence: evidenceJson(), evidenceEventId: 7),
              submit: (_) async => const ReviewDecideResult(
                result: 'lifted',
                stillBanned: 'manuel',
              ),
              targetLabel: 'Compte Exemple',
              manualBanPresent: true,
              onAuthError: () {},
            ),
          );
      await tester.pumpAndSettle();
      // Preuve repliée par défaut.
      expect(find.byKey(const Key('moderation-evidence')), findsNothing);
      expect(_submitButton(tester).onPressed, isNull);
      await tester.enterText(find.byKey(_reason), 'vérifié');
      await tester.pump();
      await tester.tap(find.byKey(_submit));
      await tester.pumpAndSettle();
      final DecisionOutcome o = probe.result!.outcome;
      expect(o.tone, OutcomeTone.warning);
      expect(
        o.message,
        'Ban automatique levé ; le ban MANUEL reste en vigueur.',
      );
    });

    testWidgets('« Ouvrir dans Modération » ferme puis appelle le rappel', (
      WidgetTester tester,
    ) async {
      int opened = 0;
      final DialogProbe<DecisionDialogOutcome> probe =
          await openDialog<DecisionDialogOutcome>(
            tester,
            (_) => AutoBanLiftDialog(
              loadDetail: () async => reviewDetail(),
              submit: (_) async => _ok('lifted'),
              targetLabel: 'Compte Exemple',
              onOpenModeration: () => opened++,
              onAuthError: () {},
            ),
          );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ouvrir dans Modération'));
      await tester.pumpAndSettle();
      expect(opened, 1);
      expect(probe.closed, isTrue);
      expect(probe.result, isNull);
    });
  });

  group('decisionText (essai local du 28/09/2026)', () {
    test('page : « bloquée », jamais « banni(e) »', () {
      for (final ReviewDecision d in <ReviewDecision>[
        ReviewDecision.apply,
        ReviewDecision.lift,
      ]) {
        final String t = decisionText(
          d,
          target: 'https://exemple.test/page',
          targetKind: 'page',
          groupSize: 2,
        );
        expect(t, contains('bloquée'));
        expect(t, isNot(contains('banni(e)')));
      }
    });

    test('compte et chaîne : « banni(e) »', () {
      for (final String kind in <String>['account', 'channel']) {
        expect(
          decisionText(ReviewDecision.apply, target: 'X', targetKind: kind),
          contains('sera banni(e)'),
        );
        expect(
          decisionText(ReviewDecision.lift, target: 'X', targetKind: kind),
          contains('ne sera plus banni(e)'),
        );
      }
    });
  });
}
