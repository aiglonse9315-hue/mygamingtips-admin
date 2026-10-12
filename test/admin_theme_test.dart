// Ascenseurs du panneau (thème `core/theme/app_theme.dart`, demande du
// propriétaire du 12/10/2026) : le curseur occupe toute la largeur de sa
// colonne — on l'attrape aussi par les bords (avant : curseur de 8 px entre
// deux marges de 2 px, difficile à saisir).

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/core/theme/app_theme.dart';

void main() {
  test('ascenseur : marge latérale nulle, épaisseur fixe, colonne visible', () {
    for (final ThemeData theme in <ThemeData>[
      AdminTheme.dark,
      AdminTheme.light,
    ]) {
      final ScrollbarThemeData s = theme.scrollbarTheme;
      expect(s.crossAxisMargin, 0);
      for (final Set<WidgetState> states in <Set<WidgetState>>[
        <WidgetState>{},
        <WidgetState>{WidgetState.hovered},
        <WidgetState>{WidgetState.dragged},
      ]) {
        expect(
          s.thickness!.resolve(states),
          AdminTheme.kScrollbarThickness,
          reason: '$states',
        );
      }
      expect(s.thumbVisibility!.resolve(<WidgetState>{}), isTrue);
      expect(s.trackVisibility!.resolve(<WidgetState>{}), isTrue);
      expect(s.interactive, isTrue);
    }
  });

  testWidgets("le curseur s'attrape sur toute la largeur de sa colonne "
      '(bords compris), pas à côté', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ScrollController controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        theme: AdminTheme.dark,
        home: Scaffold(
          body: ListView.builder(
            controller: controller,
            itemCount: 200,
            itemExtent: 50,
            itemBuilder: (_, int i) => Text('ligne $i'),
          ),
        ),
      ),
    );
    await tester.pump();
    // Le curseur apparaît en fondu : on laisse l'animation finir.
    await tester.pump(const Duration(milliseconds: 500));
    // Ascenseur ajouté par le comportement de défilement « bureau ».
    final Finder scrollbar = find.byType(Scrollbar);
    expect(scrollbar, findsOneWidget);
    ScrollbarPainter? painter;
    for (final CustomPaint paint in tester.widgetList<CustomPaint>(
      find.descendant(of: scrollbar, matching: find.byType(CustomPaint)),
    )) {
      if (paint.foregroundPainter is ScrollbarPainter) {
        painter = paint.foregroundPainter! as ScrollbarPainter;
      }
    }
    expect(painter, isNotNull);
    const double w = 800;
    const double k = AdminTheme.kScrollbarThickness;
    // Toute la colonne attrape le curseur : bord gauche (w - k), milieu,
    // dernier pixel à droite ; juste à gauche de la colonne : non.
    for (final double x in <double>[w - k, w - k / 2, w - 1]) {
      expect(
        painter!.hitTestOnlyThumbInteractive(
          Offset(x, 10),
          PointerDeviceKind.mouse,
        ),
        isTrue,
        reason: 'x = $x',
      );
    }
    expect(
      painter!.hitTestOnlyThumbInteractive(
        const Offset(w - k - 2, 10),
        PointerDeviceKind.mouse,
      ),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
}
