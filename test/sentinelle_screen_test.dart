// P5 (lot L6) — écran Sentinelle du panneau : section « Attente 2ème
// passe » entre « 99% sûr » et « À vérifier », avec les mêmes possibilités
// que « 99% sûr » (décision du propriétaire du 12/10 : cases, case de la
// page, « Tout sélectionner », « Valider sélection », « Tout valider »),
// « 1 clic » par ligne, tri par « Confiance » ; total de l'en-tête ; badge
// « Astuce courte » en tête de « À vérifier ».
//
// Possible en VM depuis que `SuggestionReviewDialog` vit dans
// `ui/widgets/suggestion_review_dialog.dart` (l'écran n'importe plus
// `suggestions_screen.dart`, qui dépend de `dart:html` par
// `core/auth/auth_controller.dart`). Contrôleur de PRODUCTION monté sur un
// `SupabaseSync` factice (données neutres, aucun réseau : toute autre
// requête reçoit une réponse vide d'un MockClient).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mgt_admin/data/local_storage.dart';
import 'package:mgt_admin/data/store.dart';
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/content.dart';
import 'package:mgt_admin/domain/models/game.dart';
import 'package:mgt_admin/domain/models/suggestion.dart';
import 'package:mgt_admin/domain/models/suggestion_author.dart';
import 'package:mgt_admin/state/store_controller.dart';
import 'package:mgt_admin/ui/screens/sentinelle_screen.dart';
import 'package:provider/provider.dart';

import 'support/http_fixtures.dart' show testJwt;

const String _gameId = '22222222-3333-4444-8555-666666666666';

class _Sync extends SupabaseSync {
  _Sync(this.analyzed, [this.gamesToCreate = const <Suggestion>[]])
    : super(
        supabaseUrl: 'https://exemple.invalid',
        anonKey: 'anon',
        catalogEndpoint: 'https://exemple.invalid/functions/v1/admin-catalog',
        adminToken: testJwt(),
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

  List<Suggestion> analyzed;

  /// Lignes « Jeux à créer » (mode `games-to-create`).
  List<Suggestion> gamesToCreate;

  @override
  Future<({List<Suggestion> items, DateTime? maxUpdatedAt})>
  fetchGamesToCreate({int page = 0, int pageSize = 500, String? since}) async => (
    items: page == 0 ? List<Suggestion>.of(gamesToCreate) : <Suggestion>[],
    maxUpdatedAt: null,
  );

  /// Lots `suggestions/accept-batch` reçus (ids) ; chaque lot attend que le
  /// test complète [pending].
  final List<List<String>> batches = <List<String>>[];
  Completer<Map<String, dynamic>>? pending;

  /// Jeu du catalogue (« Jeu neutre », jeu suggéré des lignes) : le lot le
  /// retrouve sans en créer.
  @override
  Future<({List<Game> items, DateTime? maxUpdatedAt})> fetchGames({
    int page = 0,
    int pageSize = 1000,
    String? since,
  }) async => (
    items: page == 0
        ? <Game>[
            Game(
              id: _gameId,
              name: 'Jeu neutre',
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          ]
        : <Game>[],
    maxUpdatedAt: null,
  );

  @override
  Future<Map<String, dynamic>> acceptSuggestionsBatch(
    List<Map<String, dynamic>> items,
  ) {
    final List<String> ids = items.map((m) => m['id'] as String).toList();
    batches.add(ids);
    pending = Completer<Map<String, dynamic>>();
    return pending!.future.then((Map<String, dynamic> r) {
      analyzed = analyzed.where((s) => !ids.contains(s.id)).toList();
      return r;
    });
  }

  @override
  Future<({List<Content> items, DateTime? maxUpdatedAt})> fetchContents({
    int page = 0,
    int pageSize = 1000,
    String? since,
  }) async => (items: <Content>[], maxUpdatedAt: null);

  @override
  Future<int> fetchTableCount(String table, {String? filter}) async =>
      table == 'games' ? 1 : 0;

  @override
  Future<({List<Suggestion> items, DateTime? maxUpdatedAt})>
  fetchSentinelleSuggestions({
    int page = 0,
    int pageSize = 500,
    String? since,
  }) async => (
    items: page == 0 ? List<Suggestion>.of(analyzed) : <Suggestion>[],
    maxUpdatedAt: null,
  );
}

final MockClient _neutralHttp = MockClient((http.Request req) async {
  final bool read = req.method == 'GET' || req.method == 'HEAD';
  return http.Response(
    read ? '[]' : '{}',
    200,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
});

int _seq = 0;

Suggestion _analyzed(
  String url,
  String title, {
  String verdict = 'recommended',
  double confidence = 0.9,
  Map<String, Object?>? revue,
  bool needsGameCreation = false,
}) {
  _seq++;
  return Suggestion(
    id: '33333333-4444-4555-8666-${_seq.toString().padLeft(12, '0')}',
    url: url,
    sharedText: title,
    status: SuggestionStatus.pending,
    sharedAt: DateTime.utc(2026, 10, 12),
    author: const SuggestionAuthor(id: '', displayName: 'Vision'),
    source: Suggestion.sourceVision,
    aiRecommendation: AiRecommendation.fromJson(<String, dynamic>{
      'verdict': verdict,
      'confidence': confidence,
      'reason': 'Raison neutre',
      'youtube_title': title,
      'suggested_game': 'Jeu neutre',
      'suggested_category': 'video',
      'revue_p5': ?revue,
      if (needsGameCreation) 'needs_game_creation': true,
    }),
  );
}

/// Monte l'écran sur un contrôleur dont la liste « analysées » vaut [rows].
Future<StoreController> _mount(
  WidgetTester tester,
  List<Suggestion> rows, {
  List<Suggestion> gamesToCreate = const <Suggestion>[],
  Size size = const Size(2400, 4000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  browserLocalStorage.clear();
  late StoreController store;
  await tester.runAsync(() async {
    await http.runWithClient(() async {
      store = StoreController(
        Store(
          gamesSeed: '[]',
          contentsSeed: '[]',
          suggestionsSeed: '[]',
          bannedSeed: '[]',
          plusSeed: '[]',
        ),
        sync: _Sync(rows, gamesToCreate),
      );
      await store.ensureDatasets(<SyncDataset>{
        SyncDataset.sentinelleAnalyzed,
      });
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }, () => _neutralHttp);
  });
  await tester.pumpWidget(
    ChangeNotifierProvider<StoreController>.value(
      value: store,
      child: const MaterialApp(home: Scaffold(body: SentinelleScreen())),
    ),
  );
  await tester.pump();
  return store;
}

/// Démonte l'écran (arrête le polling « Analyses en cours »).
Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

/// Recharge les 5 modes de suggestions depuis le faux serveur (sync
/// COMPLÈTE : ses listes REMPLACENT les listes locales, comme
/// « Actualiser ») ; les tableaux gardent leur état.
Future<void> _resync(WidgetTester tester, StoreController store) async {
  await tester.runAsync(() async {
    await http.runWithClient(() async {
      await store.syncFromSupabase(
        datasets: <SyncDataset>{SyncDataset.sentinelleAnalyzed},
        forceFull: true,
      );
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }, () => _neutralHttp);
  });
  await tester.pump();
}

/// Clique [button] après l'avoir amené à l'écran (la barre de pagination de
/// « À vérifier » et des « Jeux à créer » est SOUS le tableau ; le défilement
/// peut sortir les en-têtes de l'écran).
Future<void> _tapVisible(WidgetTester tester, Finder button) async {
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
}

const ValueKey<String> _kWait = ValueKey<String>('tableau_attente_2e_passe');
const ValueKey<String> _kSure = ValueKey<String>('tableau_99_sur');

void main() {
  testWidgets('trois sections dans l\'ordre, total de l\'en-tête, « Attente '
      '2ème passe » avec cases et « Tout valider », « 1 clic » par ligne, '
      '« Astuce courte » en tête de « À vérifier »', (
    WidgetTester tester,
  ) async {
    final StoreController store = await _mount(tester, <Suggestion>[
      _analyzed('https://www.jeuxvideo.com/news/1.htm', 'Page web 90'),
      _analyzed('https://www.youtube.com/watch?v=AAAAAAAAAAA', 'Video 90'),
      _analyzed('https://youtu.be/BBBBBBBBBBB', 'Video 95', confidence: 0.95),
      _analyzed(
        'https://www.youtube.com/watch?v=CCCCCCCCCCC',
        'Video 100',
        confidence: 1.0,
      ),
      _analyzed(
        'https://www.youtube.com/watch?v=DDDDDDDDDDD',
        'Astuce sans parole',
        verdict: 'caution',
        confidence: 0.0,
        revue: const <String, Object?>{
          'etat': 'sans_parole_court',
          'motif': 'astuce_courte',
        },
      ),
    ]);
    expect(store.sentinelleTrusted, hasLength(1));
    expect(store.sentinelleAwaitingSecondPass, hasLength(2));
    expect(store.sentinelleToVerify, hasLength(2));

    // Total : 0 en cours + 1 + 2 + 2.
    expect(find.text('5 suggestion(s)'), findsOneWidget);
    final double ySure = tester
        .getTopLeft(find.text('99% sûr — Implémentable en 1 clic'))
        .dy;
    final double yWait = tester.getTopLeft(find.text('Attente 2ème passe')).dy;
    final double yCheck = tester.getTopLeft(find.text('À vérifier').first).dy;
    expect(ySure < yWait && yWait < yCheck, isTrue);

    final Finder wait = find.byKey(_kWait);
    final Finder sure = find.byKey(_kSure);
    expect(wait, findsOneWidget);
    expect(sure, findsOneWidget);
    Finder inWait(Finder f) => find.descendant(of: wait, matching: f);
    Finder inSure(Finder f) => find.descendant(of: sure, matching: f);
    // « Attente » : 2 lignes, « 1 clic » sur chacune ; cases : en-tête de
    // page + 1 par ligne (le libellé « ☐ » est remplacé par la case).
    expect(inWait(find.text('1 clic')), findsNWidgets(2));
    expect(inWait(find.text('☐')), findsNothing);
    expect(
      inWait(find.byIcon(Icons.check_box_outline_blank_rounded)),
      findsNWidgets(3),
    );
    // Titre affiché deux fois par ligne (cellule + champ d'insertion).
    expect(inWait(find.text('Video 90')), findsWidgets);
    expect(inWait(find.text('Video 95')), findsWidgets);
    expect(inWait(find.text('Video 100')), findsNothing);
    // « 99% sûr » : colonne de sélection gardée (en-tête + 1 ligne).
    expect(inSure(find.text('☐')), findsNothing); // en-tête remplacé
    expect(
      inSure(find.byIcon(Icons.check_box_outline_blank_rounded)),
      findsNWidgets(2),
    );
    expect(inSure(find.text('Video 100')), findsWidgets);
    // « Tout valider » : « 99% sûr » ET « Attente 2ème passe ».
    expect(find.text('Tout valider'), findsNWidgets(2));
    // Badge « Astuce courte » sur la seule ligne concernée.
    expect(
      find.byKey(const ValueKey<String>('badge_astuce_courte')),
      findsOneWidget,
    );

    await _unmount(tester);
  });

  testWidgets('« Attente 2ème passe » : sélection propre à la section (case '
      'de ligne, case de la page, « Tout sélectionner »), « Valider '
      'sélection (N) » dans SON en-tête, « Tout valider » avec un message '
      "qui dit qu'elles n'attendront pas la 2e passe", (
    WidgetTester tester,
  ) async {
    await _mount(tester, <Suggestion>[
      _analyzed(
        'https://www.youtube.com/watch?v=CCCCCCCCCCC',
        'Video 100',
        confidence: 1.0,
      ),
      _analyzed('https://www.youtube.com/watch?v=AAAAAAAAAAA', 'Video 90'),
      _analyzed('https://youtu.be/BBBBBBBBBBB', 'Video 95', confidence: 0.95),
    ]);
    final Finder wait = find.byKey(_kWait);
    Finder inWait(Finder f) => find.descendant(of: wait, matching: f);
    final double yWait = tester.getTopLeft(find.text('Attente 2ème passe')).dy;
    final double yWaitTable = tester.getTopLeft(wait).dy;
    bool inWaitHeader(Finder f) {
      final double y = tester.getTopLeft(f).dy;
      return y >= yWait - 4 && y < yWaitTable;
    }

    expect(find.textContaining('Valider sélection'), findsNothing);
    // Case de la 1re ligne de « Attente » (index 0 = case de la page).
    await tester.tap(
      inWait(find.byIcon(Icons.check_box_outline_blank_rounded)).at(1),
    );
    await tester.pump();
    expect(find.text('Valider sélection (1)'), findsOneWidget);
    expect(inWaitHeader(find.text('Valider sélection (1)')), isTrue);
    // Case de la page : toute la page de « Attente » (2 lignes), rien
    // dans « 99% sûr ».
    await tester.tap(
      inWait(find.byTooltip('Sélectionner toute la page affichée')),
    );
    await tester.pump();
    expect(find.text('Valider sélection (2)'), findsOneWidget);
    expect(inWaitHeader(find.text('Valider sélection (2)')), isTrue);
    expect(
      inWait(find.byIcon(Icons.check_box_outline_blank_rounded)),
      findsNothing,
    );
    // Relecture (F6) : rien de coché dans « 99% sûr » (case de la page +
    // sa ligne toujours vides).
    expect(
      find.descendant(
        of: find.byKey(_kSure),
        matching: find.byIcon(Icons.check_box_outline_blank_rounded),
      ),
      findsNWidgets(2),
    );
    // « Tout désélectionner » de la section « Attente » (2e en-tête).
    expect(find.text('Tout désélectionner'), findsOneWidget);
    expect(inWaitHeader(find.text('Tout désélectionner')), isTrue);
    await tester.tap(find.text('Tout désélectionner'));
    await tester.pump();
    expect(find.textContaining('Valider sélection'), findsNothing);
    // « Tout valider » de « Attente » : dialogue de confirmation propre.
    final Finder allButtons = find.text('Tout valider');
    expect(allButtons, findsNWidgets(2));
    // Relecture (F1) : boutons d'en-tête dans un Wrap (passent à la ligne
    // sur un écran étroit au lieu de déborder), dans les deux sections.
    for (int i = 0; i < 2; i++) {
      expect(
        find.ancestor(of: allButtons.at(i), matching: find.byType(Wrap)),
        findsOneWidget,
      );
    }
    await tester.tap(allButtons.at(1));
    await tester.pump();
    expect(find.text('Valider toutes les suggestions (2) ?'), findsOneWidget);
    expect(
      find.textContaining("n'attendront pas la 2e passe de Sentinelle"),
      findsOneWidget,
    );
    await tester.tap(find.text('Annuler'));
    await tester.pump();
    expect(find.text('Valider toutes les suggestions (2) ?'), findsNothing);

    await _unmount(tester);
  });

  testWidgets('lot lancé depuis « Attente 2ème passe » : seules ses lignes '
      'cochées partent, progression dans SON en-tête (même section vidée), '
      'autre section désactivée, sélection de « 99% sûr » gardée', (
    WidgetTester tester,
  ) async {
    final List<Suggestion> rows = <Suggestion>[
      _analyzed(
        'https://www.youtube.com/watch?v=SSSSSSSSSS1',
        'Sure 1',
        confidence: 1.0,
      ),
      _analyzed(
        'https://www.youtube.com/watch?v=SSSSSSSSSS2',
        'Sure 2',
        confidence: 1.0,
      ),
      _analyzed('https://www.youtube.com/watch?v=AAAAAAAAAA1', 'Wait 1'),
    ];
    final StoreController store = await _mount(tester, rows);
    final _Sync sync = store.sync! as _Sync;
    expect(store.games, isNotEmpty);
    final Finder wait = find.byKey(_kWait);
    final Finder sure = find.byKey(_kSure);
    // 1 ligne cochée dans chaque section.
    await tester.tap(
      find
          .descendant(
            of: sure,
            matching: find.byIcon(Icons.check_box_outline_blank_rounded),
          )
          .at(1),
    );
    await tester.pump();
    await tester.tap(
      find
          .descendant(
            of: wait,
            matching: find.byIcon(Icons.check_box_outline_blank_rounded),
          )
          .at(1),
    );
    await tester.pump();
    expect(find.text('Valider sélection (1)'), findsNWidgets(2));
    final double yWaitTitle = tester
        .getTopLeft(find.text('Attente 2ème passe'))
        .dy;

    await http.runWithClient(() async {
      // 2e bouton = celui de « Attente » (ordre de l'arbre).
      await tester.tap(find.text('Valider sélection (1)').at(1));
      await tester.pump();
      expect(find.text('Valider 1 suggestion(s) ?'), findsOneWidget);
      await tester.tap(find.text('Valider la sélection'));
      await tester.pump();
      await tester.pump();
    }, () => _neutralHttp);

    // Seule la ligne de « Attente » est envoyée.
    expect(sync.batches, <List<String>>[
      <String>[rows[2].id],
    ]);
    // Pendant le lot : « Attente » est vide (retrait optimiste) mais sa
    // progression reste affichée dans SON en-tête ; « Valider sélection »
    // masqué partout ; « Tout valider » de « 99% sûr » désactivé.
    final Finder progress = find.textContaining('Validation en cours');
    expect(progress, findsOneWidget);
    expect(
      (tester.getTopLeft(progress).dy - yWaitTitle).abs() < 40,
      isTrue,
    );
    expect(find.textContaining('Valider sélection'), findsNothing);
    final FilledButton sureAll = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Tout valider'),
        matching: find.byWidgetPredicate((Widget w) => w is FilledButton),
      ),
    );
    expect(sureAll.onPressed, isNull);

    await http.runWithClient(() async {
      sync.pending!.complete(<String, dynamic>{
        'ok': sync.batches.single,
        'failed': <Object?>[],
      });
      for (int i = 0; i < 20; i++) {
        await tester.pump();
      }
    }, () => _neutralHttp);
    await tester.runAsync(() async {
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();

    expect(store.sentinelleAwaitingSecondPass, isEmpty);
    expect(store.sentinelleTrusted, hasLength(2));
    expect(find.textContaining('Validation en cours'), findsNothing);
    // Sélection de « 99% sûr » gardée (sa ligne cochée), celle de
    // « Attente » vidée.
    expect(find.text('Valider sélection (1)'), findsOneWidget);

    await _unmount(tester);
  });

  testWidgets('écran étroit (1 136 px de contenu = écran de 1 366 px moins le '
      'menu de 230 px) : aucun débordement dans les 4 tableaux ni dans les '
      'en-têtes, lignes cochées comprises', (WidgetTester tester) async {
    // Un débordement (RenderFlex overflowed) fait échouer le test.
    await _mount(
      tester,
      <Suggestion>[
        _analyzed(
          'https://www.youtube.com/watch?v=SSSSSSSSSS1',
          'Sure 1',
          confidence: 1.0,
        ),
        _analyzed('https://www.youtube.com/watch?v=AAAAAAAAAA1', 'Wait 1'),
        _analyzed(
          'https://www.jeuxvideo.com/news/1.htm',
          'Verify 1',
          verdict: 'caution',
          confidence: 0.5,
        ),
      ],
      gamesToCreate: <Suggestion>[
        _analyzed(
          'https://www.youtube.com/watch?v=GGGGGGGGGG1',
          'Gtc 1',
          confidence: 1.0,
          needsGameCreation: true,
        ),
      ],
      size: const Size(1136, 5000),
    );
    expect(find.text('Gtc 1'), findsWidgets);
    expect(find.text('Verify 1'), findsWidgets);
    for (final ValueKey<String> key in <ValueKey<String>>[_kSure, _kWait]) {
      await tester.tap(
        find
            .descendant(
              of: find.byKey(key),
              matching: find.byIcon(Icons.check_box_outline_blank_rounded),
            )
            .at(1),
      );
      await tester.pump();
    }
    expect(find.text('Valider sélection (1)'), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    await _unmount(tester);
  });

  testWidgets('tri par « Confiance » dans « Attente 2ème passe » (colonne '
      'lue par son nom)', (
    WidgetTester tester,
  ) async {
    await _mount(tester, <Suggestion>[
      _analyzed('https://www.youtube.com/watch?v=AAAAAAAAAAA', 'Haut', confidence: 0.95),
      _analyzed('https://www.youtube.com/watch?v=BBBBBBBBBBB', 'Bas', confidence: 0.5),
      _analyzed('https://www.youtube.com/watch?v=CCCCCCCCCCC', 'Milieu', confidence: 0.8),
    ]);
    final Finder wait = find.byKey(_kWait);
    // Le titre figure dans la cellule « Titre » ET dans le champ « Titre
    // pour insertion » : la 1re occurrence suffit pour l'ordre des lignes.
    double y(String t) => tester
        .getTopLeft(find.descendant(of: wait, matching: find.text(t)).first)
        .dy;
    // Ordre du serveur d'abord.
    expect(y('Haut') < y('Bas') && y('Bas') < y('Milieu'), isTrue);
    // 1er clic : confiance croissante.
    await tester.tap(
      find.descendant(of: wait, matching: find.text('Confiance')),
    );
    await tester.pump();
    expect(y('Bas') < y('Milieu') && y('Milieu') < y('Haut'), isTrue);
    // 2e clic : décroissante.
    await tester.tap(
      find.descendant(of: wait, matching: find.text('Confiance')),
    );
    await tester.pump();
    expect(y('Haut') < y('Milieu') && y('Milieu') < y('Bas'), isTrue);

    await _unmount(tester);
  });

  testWidgets('L7 L7-PAN-01 « Attente 2ème passe » : 150 lignes, page 2, '
      'case de la page + « Valider sélection (50) » → les 100 lignes '
      'restantes (page 1) restent affichées, pas un tableau vide ; la page '
      'recalée ne revient pas sur la page 2 quand la liste regrandit', (
    WidgetTester tester,
  ) async {
    String titre(int i) => 'Wait ${i.toString().padLeft(3, '0')}';
    Suggestion ligne(int i) => _analyzed(
      'https://www.youtube.com/watch?v=W${i.toString().padLeft(10, '0')}',
      titre(i),
    );
    final List<Suggestion> rows = <Suggestion>[
      for (int i = 1; i <= 150; i++) ligne(i),
    ];
    final StoreController store = await _mount(tester, rows);
    final _Sync sync = store.sync! as _Sync;
    expect(store.sentinelleAwaitingSecondPass, hasLength(150));
    final Finder wait = find.byKey(_kWait);
    Finder inWait(Finder f) => find.descendant(of: wait, matching: f);

    // Page 2 (barre du haut) : les 50 dernières lignes.
    expect(inWait(find.text('Page 1 / 2')), findsNWidgets(2));
    await _tapVisible(
      tester,
      inWait(find.byTooltip('Page suivante')).first,
    );
    expect(inWait(find.text('Page 2 / 2')), findsNWidgets(2));
    expect(inWait(find.text('1 clic')), findsNWidgets(50));
    expect(inWait(find.text(titre(101))), findsWidgets);
    expect(inWait(find.text(titre(1))), findsNothing);

    // Case de la page puis « Valider sélection (50) » (§171 du 12/10).
    await _tapVisible(
      tester,
      inWait(find.byTooltip('Sélectionner toute la page affichée')),
    );
    await http.runWithClient(() async {
      await _tapVisible(tester, find.text('Valider sélection (50)'));
      expect(find.text('Valider 50 suggestion(s) ?'), findsOneWidget);
      await tester.tap(find.text('Valider la sélection'));
      await tester.pump();
      await tester.pump();
    }, () => _neutralHttp);
    expect(
      sync.batches.single.toSet(),
      <String>{for (final s in rows.sublist(100)) s.id},
    );

    // 100 lignes, une seule page : la page 1, sans barre (avant : page 2
    // gardée → `sublist(100, 100)`, tableau vide, aucun bouton pour revenir).
    void pageUneAffichee() {
      expect(store.sentinelleAwaitingSecondPass, hasLength(100));
      expect(inWait(find.text('1 clic')), findsNWidgets(100));
      expect(inWait(find.text(titre(1))), findsWidgets);
      expect(inWait(find.text(titre(100))), findsWidgets);
      expect(inWait(find.byTooltip('Page suivante')), findsNothing);
      expect(inWait(find.textContaining(RegExp(r'^Page \d'))), findsNothing);
    }

    // Pendant le lot (retrait optimiste), puis après.
    pageUneAffichee();
    await http.runWithClient(() async {
      sync.pending!.complete(<String, dynamic>{
        'ok': sync.batches.single,
        'failed': <Object?>[],
      });
      for (int i = 0; i < 20; i++) {
        await tester.pump();
      }
    }, () => _neutralHttp);
    await tester.runAsync(() async {
      for (int i = 0; i < 30; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    pageUneAffichee();

    // La liste regrandit (10 nouvelles lignes au rechargement) : la page
    // RECALÉE reste la 1re, pas de retour sur la page 2 quittée.
    sync.analyzed = <Suggestion>[
      ...rows.sublist(0, 100),
      for (int i = 151; i <= 160; i++) ligne(i),
    ];
    await _resync(tester, store);
    expect(store.sentinelleAwaitingSecondPass, hasLength(110));
    expect(inWait(find.text('Page 1 / 2')), findsNWidgets(2));
    expect(inWait(find.text(titre(1))), findsWidgets);
    expect(inWait(find.text(titre(151))), findsNothing);

    await _unmount(tester);
  });

  testWidgets('L7 L7-PAN-01 « À vérifier » (page 3 / 3 → 2 pages) et « Jeux '
      'à créer » (page 2 / 2 → 1 page) : la liste raccourcit sous le '
      'tableau → la dernière page existante est affichée, pas une page vide', (
    WidgetTester tester,
  ) async {
    String verif(int i) => 'Verify ${i.toString().padLeft(3, '0')}';
    String gtc(int i) => 'Gtc ${i.toString().padLeft(2, '0')}';
    final List<Suggestion> aVerifier = <Suggestion>[
      for (int i = 1; i <= 250; i++)
        _analyzed(
          'https://www.jeuxvideo.com/news/$i.htm',
          verif(i),
          verdict: 'caution',
          confidence: 0.5,
        ),
    ];
    final List<Suggestion> jeux = <Suggestion>[
      for (int i = 1; i <= 51; i++)
        _analyzed(
          'https://www.youtube.com/watch?v=G${i.toString().padLeft(10, '0')}',
          gtc(i),
          confidence: 1.0,
          needsGameCreation: true,
        ),
    ];
    final StoreController store = await _mount(
      tester,
      aVerifier,
      gamesToCreate: jeux,
    );
    final _Sync sync = store.sync! as _Sync;
    expect(store.sentinelleToVerify, hasLength(250));
    expect(store.gamesToCreate, hasLength(51));
    // Une barre (sous le tableau) par tableau : « À vérifier » puis « Jeux
    // à créer » (ordre de l'écran).
    Finder suivante() => find.byTooltip('Page suivante');
    expect(suivante(), findsNWidgets(2));
    await _tapVisible(tester, suivante().first);
    await _tapVisible(tester, suivante().first);
    expect(find.text('Page 3 / 3'), findsOneWidget);
    expect(find.text(verif(201)), findsWidgets);
    await _tapVisible(tester, suivante().last);
    expect(find.text('Page 2 / 2'), findsOneWidget);
    expect(find.text('Créer'), findsOneWidget);
    expect(find.text(gtc(51)), findsWidgets);

    // Listes raccourcies au rechargement : 150 « À vérifier », 50 jeux.
    sync.analyzed = aVerifier.sublist(0, 150);
    sync.gamesToCreate = jeux.sublist(0, 50);
    await _resync(tester, store);
    expect(store.sentinelleToVerify, hasLength(150));
    expect(store.gamesToCreate, hasLength(50));
    // « À vérifier » : la page 2, dernière existante (avant : « Page 3 / 2 »
    // et un tableau vide).
    expect(find.text('Page 3 / 2'), findsNothing);
    expect(find.text('Page 2 / 2'), findsOneWidget);
    expect(find.text(verif(101)), findsWidgets);
    expect(find.text(verif(150)), findsWidgets);
    // « Jeux à créer » : une seule page → ses 50 lignes, sans barre.
    expect(find.text('Créer'), findsNWidgets(50));
    expect(find.text(gtc(1)), findsWidgets);
    expect(suivante(), findsOneWidget);

    await _unmount(tester);
  });
}
