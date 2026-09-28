// « Retirer aussi ces N contenus publiés » (P4b-3, lot L5, S-02, conception
// §6.12, §7.1) : un clic n'appelle PAS le serveur tant que la confirmation
// ROUGE n'est pas validée ; Annuler → aucun appel ; confirmer → bilan
// `deleted` + liste `removed` RENVOYÉS par le serveur (révélés, non
// cliquables) ; rejeu à 0 → message de rejeu ; 401 → onAuthError.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/moderation_actions.dart';
import 'package:mgt_admin/ui/widgets/moderation/unpublish_section.dart';

import 'support/widget_fixtures.dart';

const Key _button = Key('moderation-unpublish-button');

Future<void> _pump(
  WidgetTester tester, {
  required Future<UnpublishResult> Function() unpublish,
  VoidCallback? onAuthError,
}) => pumpBody(
  tester,
  UnpublishPublishedSection(
    count: 3,
    channelLabel: '@exemple',
    unpublish: unpublish,
    onAuthError: onAuthError ?? () {},
  ),
);

void main() {
  testWidgets('un clic ouvre la confirmation rouge SANS appeler le serveur ; '
      'Annuler → aucun appel', (WidgetTester tester) async {
    int calls = 0;
    await _pump(
      tester,
      unpublish: () async {
        calls++;
        return (
          deleted: 0,
          removed: const <Map<String, dynamic>>[],
          replayed: false,
        );
      },
    );
    expect(find.text('Retirer aussi ces 3 contenus publiés'), findsOneWidget);
    await tester.tap(find.byKey(_button));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(
      find.text('Supprimer définitivement 3 contenu(s) publié(s) ?'),
      findsOneWidget,
    );
    expect(find.text(kUnpublishConfirmMessage), findsOneWidget);
    expect(kUnpublishConfirmMessage, contains('RECALCULÉE par le serveur'));
    expect(kUnpublishConfirmMessage, contains('homonymes'));
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byKey(_button), findsOneWidget);
  });

  testWidgets('confirmer → bilan et liste RENVOYÉS par le serveur', (
    WidgetTester tester,
  ) async {
    final String rlo = String.fromCharCode(0x202E);
    int calls = 0;
    await _pump(
      tester,
      unpublish: () async {
        calls++;
        return (
          deleted: 2,
          removed: <Map<String, dynamic>>[
            <String, dynamic>{'id': 'c1', 'title': 'Vidéo${rlo}A', 'url': 'u1'},
            <String, dynamic>{
              'id': 'c2',
              'title': null,
              'url': 'https://exemple.test/2',
            },
          ],
          replayed: false,
        );
      },
    );
    await tester.tap(find.byKey(_button));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(
      find.text('✅ 2 contenu(s) publié(s) retiré(s) de @exemple.'),
      findsOneWidget,
    );
    expect(find.text('• Vidéo⟦U+202E⟧A'), findsOneWidget);
    expect(find.text('• https://exemple.test/2'), findsOneWidget);
    expect(find.byKey(_button), findsNothing);
  });

  testWidgets('rejeu avec 0 supprimé → message de rejeu', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      unpublish: () async =>
          (deleted: 0, removed: const <Map<String, dynamic>>[], replayed: true),
    );
    await tester.tap(find.byKey(_button));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer'));
    await tester.pumpAndSettle();
    expect(find.text(kReplayNoticeMessage), findsOneWidget);
  });

  testWidgets('401 → onAuthError ; autre erreur → message, bouton rendu', (
    WidgetTester tester,
  ) async {
    int auth = 0;
    int calls = 0;
    await _pump(
      tester,
      unpublish: () async {
        calls++;
        if (calls == 1) throw const AdminApiException(500, 'Erreur serveur.');
        throw const AdminAuthException('Session expirée');
      },
      onAuthError: () => auth++,
    );
    await tester.tap(find.byKey(_button));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer'));
    await tester.pumpAndSettle();
    expect(find.text('Erreur serveur.'), findsOneWidget);
    expect(
      tester.widget<ButtonStyleButton>(find.byKey(_button)).onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(_button));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer'));
    await tester.pumpAndSettle();
    expect(auth, 1);
  });
}
