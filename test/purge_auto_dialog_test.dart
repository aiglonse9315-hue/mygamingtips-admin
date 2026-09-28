// Purge des suggestions d'une chaîne bannie automatiquement (P4b-3, lot L5,
// conception §6.4 d, §7.1) : texte d'aperçu, « Rien à purger » désactivé,
// application et bilan, « (200 premiers) », erreurs du serveur `{error}`
// SANS `result` affichées telles quelles (409 → « Fermer » seul), 401 →
// fermeture + déconnexion, rejeu à 0 → message de rejeu, issue incertaine
// → « Réessayer ».
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/moderation.dart';
import 'package:mgt_admin/domain/moderation_actions.dart';
import 'package:mgt_admin/ui/widgets/moderation/purge_auto_dialog.dart';

import 'support/widget_fixtures.dart';

List<PublishedContent> _published(int n) => <PublishedContent>[
  for (int i = 0; i < n; i++)
    PublishedContent(
      id: 'c$i',
      title: 'Vidéo $i',
      url: 'https://exemple.test/$i',
    ),
];

PurgeAutoResult _preview({int pending = 3, int published = 1}) =>
    PurgeAutoResult(
      result: 'preview',
      pending: pending,
      pendingByDetection: pending == 0 ? 0 : 2,
      pendingByChannelId: pending == 0 ? 0 : pending - 2,
      published: _published(published),
    );

Future<DialogProbe<PurgeAutoResult>> _open(
  WidgetTester tester, {
  required Future<PurgeAutoResult> Function() loadPreview,
  Future<PurgeAutoResult> Function()? apply,
  VoidCallback? onAuthError,
}) async {
  final DialogProbe<PurgeAutoResult> probe = await openDialog<PurgeAutoResult>(
    tester,
    (_) => PurgeAutoDialog(
      channelLabel: 'YouTube · UCexemple',
      loadPreview: loadPreview,
      apply:
          apply ??
          () async =>
              const PurgeAutoResult(result: 'purged', pending: 3, purged: 3),
      onAuthError: onAuthError ?? () {},
    ),
  );
  await tester.pumpAndSettle();
  return probe;
}

FilledButton _applyButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.byKey(const Key('moderation-purge-apply')),
);

void main() {
  testWidgets('aperçu : titre et texte exacts', (WidgetTester tester) async {
    await _open(tester, loadPreview: () async => _preview());
    expect(
      find.text('Purger les suggestions de YouTube · UCexemple ?'),
      findsOneWidget,
    );
    expect(
      shownText(tester, find.byKey(const Key('moderation-purge-text'))),
      purgePreviewText(3, 2, 1, 1),
    );
    expect(find.text('Rejeter 3 suggestion(s)'), findsOneWidget);
    expect(find.text('Plus tard'), findsOneWidget);
    expect(_applyButton(tester).onPressed, isNotNull);
  });

  testWidgets('rien en attente → « Rien à purger » désactivé', (
    WidgetTester tester,
  ) async {
    await _open(tester, loadPreview: () async => _preview(pending: 0));
    expect(find.text('Rien à purger'), findsOneWidget);
    expect(_applyButton(tester).onPressed, isNull);
  });

  testWidgets('application → bilan + publiés, « Fermer » rend le résultat', (
    WidgetTester tester,
  ) async {
    int applied = 0;
    final DialogProbe<PurgeAutoResult> probe = await _open(
      tester,
      loadPreview: () async => _preview(),
      apply: () async {
        applied++;
        return PurgeAutoResult(
          result: 'purged',
          pending: 3,
          purged: 2,
          published: _published(1),
        );
      },
    );
    await tester.tap(find.byKey(const Key('moderation-purge-apply')));
    await tester.pumpAndSettle();
    expect(applied, 1);
    expect(
      find.text('2 suggestion(s) rejetée(s) sur 3 en attente.'),
      findsOneWidget,
    );
    expect(find.text('• Vidéo 0'), findsOneWidget);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(probe.result!.purged, 2);
  });

  testWidgets('200 publiés → « (200 premiers) », non cliquables', (
    WidgetTester tester,
  ) async {
    await _open(tester, loadPreview: () async => _preview(published: 200));
    expect(tester.takeException(), isNull);
    expect(
      shownText(
        tester,
        find.byKey(const Key('moderation-purge-published-title')),
      ),
      contains('(200 premiers)'),
    );
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
  });

  testWidgets('199 publiés → pas de mention « premiers »', (
    WidgetTester tester,
  ) async {
    await _open(tester, loadPreview: () async => _preview(published: 199));
    expect(find.textContaining('premiers'), findsNothing);
  });

  testWidgets('409 sans result : message EXACT du serveur + « Fermer » seul', (
    WidgetTester tester,
  ) async {
    const String msg = "Confirmez d'abord le bannissement (file de revue).";
    final DialogProbe<PurgeAutoResult> probe = await _open(
      tester,
      loadPreview: () async => throw const AdminApiException(
        409,
        msg,
        body: <String, dynamic>{'error': msg},
      ),
    );
    expect(find.text(msg), findsOneWidget);
    expect(find.text('Réessayer'), findsNothing);
    expect(find.text('Fermer'), findsOneWidget);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(probe.closed, isTrue);
    expect(probe.result, isNull);
  });

  testWidgets('403 → « Réservé au compte principal. »', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      loadPreview: () async => throw const AdminForbiddenException('interdit'),
    );
    expect(find.text('Réservé au compte principal.'), findsOneWidget);
  });

  testWidgets('401 → onAuthError et fermeture', (WidgetTester tester) async {
    int auth = 0;
    final DialogProbe<PurgeAutoResult> probe = await _open(
      tester,
      loadPreview: () async => _preview(),
      apply: () async => throw const AdminAuthException('Session expirée'),
      onAuthError: () => auth++,
    );
    await tester.tap(find.byKey(const Key('moderation-purge-apply')));
    await tester.pumpAndSettle();
    expect(auth, 1);
    expect(probe.closed, isTrue);
    expect(find.byType(PurgeAutoDialog), findsNothing);
  });

  testWidgets('rejeu avec 0 rejetée → message de rejeu à la place du bilan', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      loadPreview: () async => _preview(),
      apply: () async => const PurgeAutoResult(
        result: 'purged',
        pending: 0,
        purged: 0,
        replayed: true,
      ),
    );
    await tester.tap(find.byKey(const Key('moderation-purge-apply')));
    await tester.pumpAndSettle();
    expect(find.text(kReplayNoticeMessage), findsOneWidget);
    expect(find.textContaining('rejetée(s) sur'), findsNothing);
  });

  testWidgets(
    'issue incertaine → message + « Réessayer » qui rejoue l\'étape',
    (WidgetTester tester) async {
      int calls = 0;
      await _open(
        tester,
        loadPreview: () async => _preview(),
        apply: () async {
          calls++;
          if (calls == 1) throw http.ClientException('coupure');
          return const PurgeAutoResult(result: 'purged', pending: 3, purged: 3);
        },
      );
      await tester.tap(find.byKey(const Key('moderation-purge-apply')));
      await tester.pumpAndSettle();
      expect(find.text('Réessayer'), findsOneWidget);
      await tester.tap(find.text('Réessayer'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(
        find.text('3 suggestion(s) rejetée(s) sur 3 en attente.'),
        findsOneWidget,
      );
    },
  );
}
