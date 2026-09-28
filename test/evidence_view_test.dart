// Preuve d'un événement de modération (P4b-3, lot L5, conception §6.4 a,
// §7.1) : texte choisi par un tiers affiché en texte brut, caractères
// cachés rendus visibles, cadres de hauteur FIXE (aucun débordement même
// avec 20 000 caractères, 60 diacritiques empilés ou une demande de
// 262 Kio), aucun widget cliquable dans la preuve, messages exacts des états
// sans preuve, hôte révélé dans la relecture serveur.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/models/moderation.dart';
import 'package:mgt_admin/ui/widgets/moderation/evidence_view.dart';

import 'support/widget_fixtures.dart';

final String rlo = String.fromCharCode(0x202E);
final String tagA = String.fromCharCodes(<int>[0xDB40, 0xDC41]); // U+E0041
final String acute = String.fromCharCode(0x0301);

Finder get _evidence => find.byKey(const Key('moderation-evidence'));

Future<void> _pumpEvidence(WidgetTester tester, ReviewDetail d) async {
  await pumpBody(tester, EvidenceView(detail: d));
}

ReviewDetail _withText(String text, {String? url, Object? demande}) =>
    reviewDetail(
      evidence: evidenceJson(
        text: text,
        url: url ?? 'https://exemple.test/video/1',
        demande: demande,
      ),
      evidenceEventId: 7,
    );

void main() {
  testWidgets('20 000 caractères d\'un seul « mot » : aucun débordement, '
      'cadre de hauteur fixe', (WidgetTester tester) async {
    await _pumpEvidence(tester, _withText('a' * 20000));
    expect(tester.takeException(), isNull);
    expect(
      tester
          .getSize(find.byKey(const Key('moderation-evidence-text-box')))
          .height,
      240,
      reason: 'le cadre du texte partagé a une hauteur fixe',
    );
  });

  testWidgets('U+202E affiché en jeton dans le texte et le lien', (
    WidgetTester tester,
  ) async {
    await _pumpEvidence(
      tester,
      _withText('abc${rlo}def', url: 'https://exemple.test/${rlo}fdp.exe'),
    );
    final String text = shownText(
      tester,
      find.byKey(const Key('moderation-evidence-text')),
    );
    expect(text, 'abc⟦U+202E⟧def');
    expect(text.contains(rlo), isFalse);
    final String url = shownText(
      tester,
      find.byKey(const Key('moderation-evidence-url')),
    );
    expect(url, 'https://exemple.test/⟦U+202E⟧fdp.exe');
    expect(
      find.text('2 caractère(s) invisible(s) ou de contrôle rendus visibles'),
      findsOneWidget,
    );
  });

  testWidgets('aucun widget cliquable dans la preuve (hors en-tête repliable '
      'de la demande)', (WidgetTester tester) async {
    await _pumpEvidence(
      tester,
      _withText(
        'https://exemple.test/lien dans le texte',
        demande: <String, dynamic>{
          'regles': <String>['r1'],
        },
      ),
    );
    for (final Type t in <Type>[
      TextButton,
      OutlinedButton,
      FilledButton,
      ElevatedButton,
      IconButton,
    ]) {
      expect(
        find.descendant(of: _evidence, matching: find.byType(t)),
        findsNothing,
        reason: '$t dans la zone de preuve',
      );
    }
    for (final String k in <String>[
      'moderation-evidence-text-box',
      'moderation-evidence-url',
    ]) {
      expect(
        find.descendant(of: find.byKey(Key(k)), matching: find.byType(InkWell)),
        findsNothing,
        reason: 'lien cliquable dans $k',
      );
    }
    // Les seuls InkWell sont ceux de l'en-tête « Demande du bot ».
    final int all = find
        .descendant(of: _evidence, matching: find.byType(InkWell))
        .evaluate()
        .length;
    final int tile = find
        .descendant(
          of: find.byKey(const Key('moderation-evidence-demande')),
          matching: find.byType(InkWell),
        )
        .evaluate()
        .length;
    expect(all, tile);
  });

  group('états sans preuve : messages exacts', () {
    testWidgets('non conservée (snapshot.preuve == false)', (tester) async {
      await _pumpEvidence(
        tester,
        reviewDetail(snapshot: <String, dynamic>{'preuve': false}),
      );
      expect(find.text(kEvidenceNotKeptMessage), findsOneWidget);
      expect(
        kEvidenceNotKeptMessage,
        'Preuve non conservée (plafond de 20 par origine ou 200 par 24 h '
        'atteint, membre de groupe ou cible déjà bannie).',
      );
    });

    testWidgets('purgée (snapshot.preuve == true)', (tester) async {
      await _pumpEvidence(
        tester,
        reviewDetail(snapshot: <String, dynamic>{'preuve': true}),
      );
      expect(
        find.text('Preuve purgée (durée de conservation).'),
        findsOneWidget,
      );
    });

    testWidgets('aucune (snapshot absent)', (tester) async {
      await _pumpEvidence(tester, reviewDetail());
      expect(
        find.text(
          'Aucune preuve pour cet événement (décision de revue ou ban manuel).',
        ),
        findsOneWidget,
      );
    });

    testWidgets('aucune (snapshot sans clé preuve)', (tester) async {
      await _pumpEvidence(
        tester,
        reviewDetail(
          snapshot: <String, dynamic>{'serveur': <String, dynamic>{}},
        ),
      );
      expect(find.text(kEvidenceNoneMessage), findsOneWidget);
      expect(find.byKey(const Key('moderation-evidence-text')), findsNothing);
    });
  });

  testWidgets('preuve de la tête du groupe : mention de l\'événement source', (
    WidgetTester tester,
  ) async {
    await _pumpEvidence(
      tester,
      reviewDetail(
        id: 9,
        evidence: evidenceJson(eventId: 4),
        evidenceEventId: 4,
      ),
    );
    expect(
      find.text("Preuve de l'événement #4 (tête du groupe ou événement revu)"),
      findsOneWidget,
    );
  });

  testWidgets('20 000 × U+E0041 : condensé, compté, hauteur bornée', (
    WidgetTester tester,
  ) async {
    await _pumpEvidence(tester, _withText(tagA * 20000));
    expect(tester.takeException(), isNull);
    expect(
      shownText(tester, find.byKey(const Key('moderation-evidence-text'))),
      '⟦U+E0041 ×20000⟧',
    );
    expect(
      find.text(
        '20000 caractère(s) invisible(s) ou de contrôle rendus visibles',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(find.byKey(const Key('moderation-evidence-text-box')))
          .height,
      240,
    );
  });

  testWidgets(
    '60 diacritiques empilés : 2 gardés + résumé, pas de débordement',
    (WidgetTester tester) async {
      await _pumpEvidence(tester, _withText('e${acute * 60} fin'));
      expect(tester.takeException(), isNull);
      expect(
        shownText(tester, find.byKey(const Key('moderation-evidence-text'))),
        'e${acute * 2}⟦+58 diacritiques⟧ fin',
      );
      expect(
        tester
            .getSize(find.byKey(const Key('moderation-evidence-text-box')))
            .height,
        240,
      );
    },
  );

  testWidgets('demande de 262 Kio : repliée, puis tronquée à l\'affichage '
      'dans une liste de hauteur fixe', (WidgetTester tester) async {
    final List<Map<String, dynamic>> detections = <Map<String, dynamic>>[
      for (int i = 0; i < 1200; i++)
        <String, dynamic>{'champ': 'titre', 'n': i, 'extrait': 'y' * 200},
    ];
    final Map<String, dynamic> demande = <String, dynamic>{
      'detections': detections,
    };
    final int bytes = utf8.encode(jsonEncode(demande)).length;
    expect(bytes, greaterThan(262 * 1024 - 8192));
    await _pumpEvidence(tester, _withText('texte', demande: demande));
    // Fermée par défaut : rien n'est rendu.
    expect(
      find.byKey(const Key('moderation-evidence-demande-truncated')),
      findsNothing,
    );
    await tester.tap(find.text('Demande du bot'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final String note = shownText(
      tester,
      find.byKey(const Key('moderation-evidence-demande-truncated')),
    );
    expect(note, startsWith("Demande tronquée à l'affichage ("));
    expect(note, endsWith(' Kio au total).'));
    final Finder list = find.descendant(
      of: find.byKey(const Key('moderation-evidence-demande')),
      matching: find.byType(ListView),
    );
    expect(list, findsOneWidget);
    expect(tester.getSize(list).height, lessThanOrEqualTo(300));
  });

  testWidgets('relecture serveur : hôte contenant U+202E rendu ⟦U+202E⟧', (
    WidgetTester tester,
  ) async {
    await pumpBody(
      tester,
      ServerReadbackView(
        snapshot: <String, dynamic>{
          'suggestion': <String, dynamic>{'url_chars': 40, 'texte_chars': 12},
          'serveur': <String, dynamic>{
            'hote_page': 'exemple$rlo.test',
            'hote_suggestion': 'autre.test',
            'motifs_examen': <String>['page_hote_different'],
          },
        },
      ),
    );
    final String host = shownText(
      tester,
      find.byKey(const Key('moderation-readback-host-page')),
    );
    expect(host, 'exemple⟦U+202E⟧.test');
    expect(host.contains(rlo), isFalse);
    expect(find.text('lien 40 · texte 12 caractère(s)'), findsOneWidget);
    expect(
      find.text('Page sur un autre site que le lien partagé'),
      findsOneWidget,
    );
  });
}
