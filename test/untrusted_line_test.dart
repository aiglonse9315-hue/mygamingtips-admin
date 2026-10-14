// Noms et textes de tiers dans les listes de comptes (revue P4b-3,
// SEC-P4b3-02) : « Comptes à bannir », « Abonnements » et « Suggestions »
// affichent désormais `display_name` et `shared_text` par `UntrustedLine`,
// dans le même montage que ces écrans (Row min > Flexible > ligne + badge).
// Les écrans eux-mêmes lisent Provider / AuthController (qui dépendait de
// dart:html jusqu'à P4d L3) : ce test vérifie le widget dans ce montage.
// Aucune dépendance dart:html ; caractères spéciaux construits par
// String.fromCharCode.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/ui/widgets/moderation/moderation_ui.dart'
    show UntrustedLine;

import 'support/widget_fixtures.dart';

const TextStyle _nameStyle = TextStyle(
  fontWeight: FontWeight.w700,
  fontSize: 13,
);

/// Montage des lignes d'écran : nom (Flexible) + badge « BANNI ».
Widget _row(String name) => Row(
  mainAxisSize: MainAxisSize.min,
  children: <Widget>[
    Flexible(
      child: UntrustedLine(
        name,
        key: const Key('nom'),
        max: 60,
        style: _nameStyle,
      ),
    ),
    const SizedBox(width: 6),
    const Text('BANNI'),
  ],
);

void main() {
  testWidgets('U+202E révélé en jeton, pas de réordonnancement', (
    WidgetTester tester,
  ) async {
    final String rlo = String.fromCharCode(0x202E);
    await pumpBody(tester, _row('Joueur${rlo}xyz'), width: 320);
    expect(
      shownText(tester, find.byKey(const Key('nom'))),
      'Joueur⟦U+202E⟧xyz',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('nom de 3 000 caractères : UNE ligne, borné à 60 points de '
      'code + « … », badge toujours visible', (WidgetTester tester) async {
    await pumpBody(tester, _row('Court'), width: 320);
    final double oneLine = tester.getSize(find.byKey(const Key('nom'))).height;

    await pumpBody(tester, _row('mot ' * 750), width: 320);
    final String shown = shownText(tester, find.byKey(const Key('nom')));
    expect(shown.runes.length, lessThanOrEqualTo(61));
    expect(shown.endsWith('…'), isTrue);
    expect(tester.getSize(find.byKey(const Key('nom'))).height, oneLine);
    expect(find.text('BANNI'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('texte partagé : sauts de ligne condensés (⏎), une ligne', (
    WidgetTester tester,
  ) async {
    await pumpBody(
      tester,
      const UntrustedLine(
        'ligne 1\nligne 2\nligne 3',
        key: Key('texte'),
        max: 120,
      ),
      width: 320,
    );
    expect(
      shownText(tester, find.byKey(const Key('texte'))),
      'ligne 1⏎ligne 2⏎ligne 3',
    );
  });
}
