// Aide commune des tests de WIDGETS de présentation (P4b-3, lot L5) :
// ouverture d'un dialogue dans une application minimale (fenêtre de taille
// fixe) avec capture du résultat, et fabriques de données de modération
// NEUTRES (aucune phrase d'attaque ; caractères spéciaux construits par
// `String.fromCharCode`). Aucune dépendance dart:html.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/models/moderation.dart';

/// Résultat d'un dialogue ouvert par [openDialog].
class DialogProbe<T> {
  bool closed = false;
  T? result;
}

/// Fixe la fenêtre de test à [size] (ratio 1) et la rétablit à la fin.
void setWindow(WidgetTester tester, [Size size = const Size(1280, 1000)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Monte une application minimale, ouvre le dialogue construit par
/// [builder] et rend une sonde qui reçoit son résultat à la fermeture.
/// N'attend PAS la stabilisation (un indicateur de chargement tournerait
/// indéfiniment) : l'appelant enchaîne `pump` / `pumpAndSettle`.
Future<DialogProbe<T>> openDialog<T>(
  WidgetTester tester,
  WidgetBuilder builder, {
  Size size = const Size(1280, 1000),
}) async {
  setWindow(tester, size);
  final DialogProbe<T> probe = DialogProbe<T>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () async {
                probe.result = await showDialog<T>(
                  context: context,
                  builder: builder,
                );
                probe.closed = true;
              },
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('ouvrir'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return probe;
}

/// Monte [child] seul (pas de dialogue) dans une zone de [width] px.
Future<void> pumpBody(
  WidgetTester tester,
  Widget child, {
  double width = 754,
  Size size = const Size(1024, 900),
  bool scroll = true,
}) async {
  setWindow(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: scroll ? SingleChildScrollView(child: child) : child,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Texte affiché par le `Text` ou le `SelectableText` trouvé par [finder].
String shownText(WidgetTester tester, Finder finder) {
  final Widget w = tester.widget(finder);
  if (w is Text) return w.data ?? w.textSpan?.toPlainText() ?? '';
  if (w is SelectableText) return w.data ?? w.textSpan?.toPlainText() ?? '';
  final Finder inner = find.descendant(
    of: finder,
    matching: find.byWidgetPredicate(
      (Widget x) => x is Text || x is SelectableText,
    ),
  );
  return shownText(tester, inner.first);
}

/// Élément de la file de revue.
ReviewItem reviewItem({
  int id = 7,
  String kind = 'ban_en_revue',
  String targetKind = 'account',
  String? targetKey = '11111111-2222-4333-8444-555555555555',
  String? accountDisplayName = 'Compte Exemple',
  String? platform,
  List<String> reasons = const <String>['auto_ban_desactive'],
  int groupSize = 1,
  String? actorUsername = 'bot-exemple',
  String? suggestionAuthorId,
  bool hasEvidence = true,
  bool manualBanPresent = false,
}) => ReviewItem(
  kind: kind,
  groupSize: groupSize,
  id: id,
  createdAt: DateTime.utc(2026, 9, 28, 3, 15),
  targetKind: targetKind,
  targetKey: targetKey,
  action: 'ban',
  category: 'injection_ia',
  reasons: reasons,
  platform: platform,
  actorUsername: actorUsername,
  suggestionAuthorId: suggestionAuthorId,
  hasEvidence: hasEvidence,
  accountDisplayName: accountDisplayName,
  manualBanPresent: manualBanPresent,
);

/// Détail d'un événement, construit par `ReviewDetail.fromJson` (forme
/// exacte de `moderation/review-detail`).
ReviewDetail reviewDetail({
  int id = 7,
  String targetKind = 'account',
  String? targetKey = '11111111-2222-4333-8444-555555555555',
  Map<String, dynamic>? evidence,
  int? evidenceEventId,
  Map<String, dynamic>? snapshot,
  int headId = 7,
  int size = 1,
  List<int> members = const <int>[],
  String? note,
  String? rulesSha256,
  String? rawSha256,
}) {
  final ReviewDetail? d = ReviewDetail.fromJson(<String, dynamic>{
    'result': 'ok',
    'event': <String, dynamic>{
      'id': id,
      'created_at': '2026-09-28T03:15:00+00:00',
      'target_kind': targetKind,
      'target_key': targetKey,
      'action': 'ban',
      'origin': 'auto',
      'category': 'injection_ia',
      'actor_username': 'bot-exemple',
      'actor_kind': 'detecteur',
      'reasons': <String>['auto_ban_desactive'],
      'note': note,
      'rules_sha256': rulesSha256,
      'raw_sha256': rawSha256,
      'snapshot': snapshot,
    },
    'evidence': evidence,
    'evidence_event_id': evidenceEventId,
    'group': <String, dynamic>{
      'head_id': headId,
      'size': size,
      'members': members,
    },
  });
  return d!;
}

/// Preuve (forme `moderation_evidence`).
Map<String, dynamic> evidenceJson({
  int eventId = 7,
  String? url = 'https://exemple.test/video/1',
  String? text = 'Texte partagé neutre.',
  Object? demande,
  String? originKey = 'origine-exemple',
}) => <String, dynamic>{
  'event_id': eventId,
  'created_at': '2026-09-28T03:15:00+00:00',
  'origin_key': originKey,
  'suggestion_url': url,
  'shared_text': text,
  'demande': demande,
};
