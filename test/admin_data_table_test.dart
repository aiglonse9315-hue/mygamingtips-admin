// Tableau commun du panneau (`ui/widgets/admin_data_table.dart`) : chaque
// titre de l'en-tête est aligné sur sa colonne (correctif du 12/10/2026,
// décalage signalé par le propriétaire dans le menu Sentinelle — la colonne
// « Actions » de l'en-tête avait un flex 0 et ses cellules un flex 1).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/ui/widgets/admin_data_table.dart';

void main() {
  testWidgets('titres alignés sur leurs cellules, « Actions » comprise, avec '
      'ou sans en-tête personnalisé', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdminDataTable(
            columns: const <String>['☐', 'Titre', 'Confiance', 'Actions'],
            headerWidgets: const <int, Widget>{0: Text('case-page')},
            onSort: (_) {},
            nonSortableColumns: const <String>['☐', 'Titre', 'Actions'],
            rows: const <List<Widget>>[
              <Widget>[
                Text('case-1'),
                Text('titre-1'),
                Text('97%'),
                Text('actions-1'),
              ],
              <Widget>[
                Text('case-2'),
                Text('titre-2'),
                Text('90%'),
                Text('actions-2'),
              ],
            ],
          ),
        ),
      ),
    );
    double x(String text) => tester.getTopLeft(find.text(text)).dx;
    for (final String row in <String>['1', '2']) {
      expect(x('case-$row'), x('case-page'), reason: 'case, ligne $row');
      expect(x('titre-$row'), x('Titre'), reason: 'titre, ligne $row');
      expect(x('actions-$row'), x('Actions'), reason: 'actions, ligne $row');
    }
    expect(x('97%'), x('Confiance'));
  });
}
