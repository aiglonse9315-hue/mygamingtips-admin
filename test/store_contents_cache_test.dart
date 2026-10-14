// Incident du 14/10/2026 : après un rechargement du panneau, les contenus
// (liens, vidéos, Patch & MoD) avaient disparu — un seul affiché. Le
// catalogue (~16 000 contenus) dépasse le seuil du cache localStorage : le
// cache n'était pas persisté, mais le curseur `contents` l'était ; au
// démarrage suivant (curseur de moins de 24 h), la synchro INCRÉMENTALE
// partait d'une liste vide et ne rapportait que les contenus modifiés depuis
// le curseur. Correctif : marqueur « cache complet » du Store ;
// l'incrémental n'est permis que sur une liste complète (synchro complète de
// la session, ou cache persisté avec son marqueur).

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mgt_admin/data/local_storage.dart';
import 'package:mgt_admin/data/store.dart';
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/content.dart';
import 'package:mgt_admin/state/store_controller.dart';

import 'support/http_fixtures.dart' show testJwt;

/// Contenu de test (identifiant UUID : contenu réel, jamais « en attente »).
Content _content(int n) => Content.fromJson(<String, dynamic>{
  'id': '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
  'gameId': '11111111-1111-4111-8111-111111111111',
  'category': n.isEven ? 'video' : 'links',
  'url': 'https://exemple.invalid/contenu/$n',
  'publishedAt': '2026-10-01T00:00:00.000Z',
});

/// `SupabaseSync` factice : catalogue complet sans curseur, [delta] avec
/// un curseur ; `since` reçu à chaque lecture de la page 0 des contenus.
class _FakeSync extends SupabaseSync {
  _FakeSync()
    : super(
        supabaseUrl: 'https://exemple.invalid',
        anonKey: 'anon',
        catalogEndpoint: 'https://exemple.invalid/functions/v1/admin-catalog',
        adminToken: testJwt(),
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

  List<Content> catalogue = <Content>[for (int n = 0; n < 50; n++) _content(n)];
  List<Content> delta = <Content>[_content(49)];
  final List<String?> sinces = <String?>[];

  @override
  Future<({List<Content> items, DateTime? maxUpdatedAt})> fetchContents({
    int page = 0,
    int pageSize = 1000,
    String? since,
  }) async {
    if (page == 0) sinces.add(since);
    final List<Content> rows = since == null ? catalogue : delta;
    return (
      items: page == 0 ? List<Content>.of(rows) : <Content>[],
      maxUpdatedAt: DateTime.utc(2026, 10, 13, 4, 41, 42),
    );
  }

  @override
  Future<int> fetchTableCount(String table, {String? filter}) async =>
      table == 'contents' ? catalogue.length : 0;
}

/// Toute autre requête (jeux, traductions, alias, cache_ops…) : réponse
/// neutre (liste vide en lecture, objet vide en écriture).
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

Future<void> _run(Future<void> Function() body) =>
    http.runWithClient(body, () => _neutralHttp);

Future<void> _settle() async {
  for (int i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Store de test ; [maxBytes] petit = catalogue « trop gros » (cas réel).
Store _store(int maxBytes) => Store(
  gamesSeed: '[]',
  contentsSeed: '[]',
  suggestionsSeed: '[]',
  bannedSeed: '[]',
  plusSeed: '[]',
  maxContentsCacheBytes: maxBytes,
);

void main() {
  setUp(browserLocalStorage.clear);

  group('Store.saveContents : marqueur de cache complet (posé par la synchro seule)', () {
    test('trop volumineux → false, marqueur ET ancien cache retirés', () {
      final Store grand = _store(1 << 30);
      expect(grand.saveContents(<Content>[_content(1)]), isTrue);
      expect(grand.contentsCacheComplete, isFalse, reason: 'jamais posé par saveContents');
      grand.markContentsComplete();
      expect(grand.contentsCacheComplete, isTrue);
      expect(browserLocalStorage['mgt_admin_contents'], isNotNull);

      final Store petit = _store(10);
      expect(petit.saveContents(<Content>[_content(1), _content(2)]), isFalse);
      expect(petit.contentsCacheComplete, isFalse);
      expect(browserLocalStorage.containsKey('mgt_admin_contents'), isFalse);
      expect(petit.loadContents(), isEmpty);
    });
  });

  group('Synchro des contenus au démarrage', () {
    test('INCIDENT : catalogue non persisté + curseur de moins de 24 h → la '
        'session suivante refait une synchro COMPLÈTE (tous les contenus)', () async {
      await _run(() async {
        final _FakeSync sync = _FakeSync();
        // Session 1 : synchro complète ; cache trop gros, curseur enregistré.
        final StoreController s1 = StoreController(_store(10), sync: sync);
        await _settle();
        expect(sync.sinces, <String?>[null]);
        expect(s1.contents.length, 50);
        expect(_store(10).loadCursor('contents'), isNotNull);
        expect(_store(10).contentsCacheComplete, isFalse);

        // Session 2 (rechargement de la page, même navigateur).
        final StoreController s2 = StoreController(_store(10), sync: sync);
        await _settle();
        expect(sync.sinces, <String?>[null, null], reason: 'synchro complète');
        expect(s2.contents.length, 50, reason: 'tous les contenus affichés');
      });
    });

    test('dans la même session, après une synchro complète : incrémental '
        '(pas de rechargement complet du catalogue)', () async {
      await _run(() async {
        final _FakeSync sync = _FakeSync();
        final StoreController s1 = StoreController(_store(10), sync: sync);
        await _settle();
        await s1.syncFromSupabase(datasets: const <SyncDataset>{SyncDataset.contents});
        await _settle();
        expect(sync.sinces.length, 2);
        expect(sync.sinces.first, isNull);
        expect(sync.sinces.last, isNotNull);
        expect(s1.contents.length, 50);
      });
    });

    test('cache persisté complet (catalogue assez petit) : la session suivante '
        'reste incrémentale et garde le cache', () async {
      await _run(() async {
        final _FakeSync sync = _FakeSync();
        StoreController(_store(1 << 30), sync: sync);
        await _settle();
        expect(_store(1 << 30).contentsCacheComplete, isTrue);

        final StoreController s2 = StoreController(_store(1 << 30), sync: sync);
        await _settle();
        expect(sync.sinces.length, 2);
        expect(sync.sinces.last, isNotNull, reason: 'incrémental');
        expect(s2.contents.length, 50, reason: 'cache + delta');
      });
    });
  });
}
