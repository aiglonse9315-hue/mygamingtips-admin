// Tableau « Chaînes YT » (pagination par jeu, migration 0088) : regroupement
// par jeu (nom + nombre de chaînes sur la 1re ligne du groupe), actions de
// ligne, état « opération en cours », et AUCUN débordement horizontal vers
// 1 024 px de large (textes longs tronqués).
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/models/trusted_channel.dart';
import 'package:mgt_admin/ui/widgets/trusted_channels_table.dart';

/// Largeur laissée au tableau par un panneau de 1 024 px : barre latérale
/// (230 px) et marges de l'écran (2 × 20 px) déduites.
const double kPanelTableWidth = 1024 - 230 - 40;

const String _longGame =
    'The Legend of Zelda: Tears of the Kingdom — Édition Collector Ultime '
    'Définitive Remasterisée';
const String _longHandle = '@shinladlovesfightinggames_et_un_handle_tres_long';
const String _longName =
    'Une chaîne au nom extrêmement long pour vérifier la troncature';

List<TrustedChannel> _page() => <TrustedChannel>[
  // Jeu 1 : 3 chaînes, textes longs, toutes les langues, source inconnue.
  TrustedChannel(
    id: 'c1',
    gameId: 'g1',
    gameName: _longGame,
    channelHandle: _longHandle,
    channelName: _longName,
    langs: const <String>[
      'FR', 'EN', 'ES', 'PT', 'DE', 'IT', 'RU', 'JA', 'ZH', 'KO', 'AR', 'HI', //
    ],
    source: 'source_inconnue_tres_longue',
  ),
  const TrustedChannel(
    id: 'c2',
    gameId: 'g1',
    gameName: _longGame,
    channelHandle: '@ign',
    langs: <String>['EN'],
    source: 'const',
  ),
  const TrustedChannel(
    id: 'c3',
    gameId: 'g1',
    gameName: _longGame,
    channelHandle: '@inactive',
    channelName: 'Chaîne inactive',
    langs: <String>['FR'],
    active: false,
    source: 'snifeur',
  ),
  // Jeu 2 : 1 chaîne.
  const TrustedChannel(
    id: 'c4',
    gameId: 'g2',
    gameName: '2XKO',
    channelHandle: '@zuuluuyt',
    langs: <String>['FR', 'EN'],
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  double width = kPanelTableWidth,
  List<TrustedChannel>? channels,
  Set<String> busy = const <String>{},
  void Function(TrustedChannel, bool)? onToggle,
  void Function(TrustedChannel)? onAddGame,
  void Function(TrustedChannel)? onDelete,
}) async {
  tester.view.physicalSize = const Size(1024, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: TrustedChannelsTable(
                channels: channels ?? _page(),
                busyIds: busy,
                onToggleActive: onToggle ?? (_, _) {},
                onAddGame: onAddGame ?? (_) {},
                onDelete: onDelete ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('1 024 px : aucun débordement, textes longs tronqués', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);
    // Largeur exacte du panneau, sans défilement horizontal.
    expect(
      tester.getSize(find.byType(TrustedChannelsTable)).width,
      kPanelTableWidth,
    );
    expect(
      find.descendant(
        of: find.byType(TrustedChannelsTable),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        ),
      ),
      findsNothing,
    );
    // Le handle long est tronqué (ellipse sur une ligne).
    final Text handle = tester.widget<Text>(find.text(_longHandle));
    expect(handle.maxLines, 1);
    expect(handle.overflow, TextOverflow.ellipsis);
    // En-têtes des 7 colonnes.
    for (final String h in <String>[
      'Jeu',
      'Chaîne',
      'Nom',
      'Langues',
      'Source',
      'Active',
      'Actions',
    ]) {
      expect(find.text(h), findsOneWidget, reason: 'en-tête $h');
    }
  });

  testWidgets('largeur minimale et étroite : toujours aucun débordement', (
    WidgetTester tester,
  ) async {
    await _pump(tester, width: TrustedChannelsTable.minWidth);
    expect(tester.takeException(), isNull);
    // Plus étroit que le minimum : défilement horizontal, pas de casse.
    await _pump(tester, width: 480);
    expect(tester.takeException(), isNull);
    expect(
      tester
          .getSize(find.byKey(const ValueKey<String>('trusted-group-g1')))
          .width,
      TrustedChannelsTable.minWidth - 2, // bordure de 1 px de chaque côté
    );
  });

  testWidgets('groupes : nom du jeu + nombre de chaînes une seule fois', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    expect(find.text(_longGame), findsOneWidget);
    expect(find.text('3 chaînes'), findsOneWidget);
    expect(find.text('2XKO'), findsOneWidget);
    expect(find.text('1 chaîne'), findsOneWidget);
    // Nom du jeu aligné sur la 1re ligne de son groupe.
    final double gameTop = tester.getTopLeft(find.text(_longGame)).dy;
    final double firstRowTop = tester
        .getTopLeft(find.byKey(const ValueKey<String>('trusted-row-c1')))
        .dy;
    final double secondRowTop = tester
        .getTopLeft(find.byKey(const ValueKey<String>('trusted-row-c2')))
        .dy;
    expect(gameTop, greaterThanOrEqualTo(firstRowTop));
    expect(gameTop, lessThan(secondRowTop));
    // Nom de chaîne absent → tiret.
    expect(find.text('—'), findsNWidgets(2));
    // Colonnes alignées : le switch de chaque ligne est dans la même colonne.
    final double x1 = tester
        .getTopLeft(
          find.descendant(
            of: find.byKey(const ValueKey<String>('trusted-row-c1')),
            matching: find.byType(Switch),
          ),
        )
        .dx;
    final double x4 = tester
        .getTopLeft(
          find.descendant(
            of: find.byKey(const ValueKey<String>('trusted-row-c4')),
            matching: find.byType(Switch),
          ),
        )
        .dx;
    expect(x4, x1);
  });

  testWidgets('actions : switch Active, ajouter un jeu, retirer', (
    WidgetTester tester,
  ) async {
    final List<String> calls = <String>[];
    await _pump(
      tester,
      onToggle: (TrustedChannel c, bool v) => calls.add('toggle ${c.id} $v'),
      onAddGame: (TrustedChannel c) => calls.add('add ${c.id}'),
      onDelete: (TrustedChannel c) => calls.add('delete ${c.id}'),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('trusted-row-c4')),
        matching: find.byType(Switch),
      ),
    );
    await tester.tap(find.byKey(const ValueKey<String>('trusted-add-game-c2')));
    await tester.tap(find.byKey(const ValueKey<String>('trusted-delete-c3')));
    await tester.pump();
    expect(calls, <String>['toggle c4 false', 'add c2', 'delete c3']);
  });

  testWidgets('opération en cours : indicateur, boutons grisés', (
    WidgetTester tester,
  ) async {
    await _pump(tester, busy: const <String>{'c2'});
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('trusted-row-c2')),
        matching: find.byType(Switch),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('trusted-row-c2')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    IconButton button(String key) =>
        tester.widget<IconButton>(find.byKey(ValueKey<String>(key)));
    expect(button('trusted-add-game-c2').onPressed, isNull);
    expect(button('trusted-delete-c2').onPressed, isNull);
    expect(button('trusted-delete-c1').onPressed, isNotNull);
  });
}
