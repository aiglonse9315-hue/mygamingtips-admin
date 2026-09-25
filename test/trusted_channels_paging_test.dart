// Tests purs (VM) de la pagination SERVEUR PAR JEU du menu « Chaînes YT »
// (migration 0088, route EF trusted-channels/list en mode page) : nombre de
// pages, bornage, libellé de la barre, corps de requête, lecture de la
// réponse (et repli EF antérieure), regroupement par jeu, jeux déjà liés à
// un handle (lus à l'ouverture du dialog « Ajouter un jeu »), mise à jour
// d'une ligne après le switch « Active », appels HTTP réels de SupabaseSync
// (client simulé). Aucune dépendance dart:html.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/trusted_channel.dart';
import 'package:mgt_admin/domain/trusted_channels_paging.dart';

/// Espace fine insécable (séparateur de milliers de formatCount).
const String nnbsp = '\u202F';

TrustedChannel _ch(
  String id, {
  String gameId = 'g1',
  String gameName = 'Jeu',
  String handle = '@chaine',
  String? name,
  bool active = true,
}) => TrustedChannel(
  id: id,
  gameId: gameId,
  gameName: gameName,
  channelHandle: handle,
  channelName: name,
  langs: const <String>['FR'],
  active: active,
);

Map<String, dynamic> _row(
  String id, {
  String gameId = 'g1',
  String gameName = 'Jeu',
  String handle = '@chaine',
}) => <String, dynamic>{
  'id': id,
  'game_id': gameId,
  'game_name': gameName,
  'channel_handle': handle,
  'channel_id': null,
  'channel_name': 'Nom $id',
  'langs': <String>['FR', 'EN'],
  'active': true,
  'source': 'snifeur',
  'platform': 'youtube',
  'created_at': '2026-09-01T10:00:00+00:00',
};

void main() {
  group('trustedPageCount / clampTrustedPage', () {
    test('au moins une page, arrondi supérieur, 5 jeux par page', () {
      expect(trustedPageCount(0, 5), 1);
      expect(trustedPageCount(1, 5), 1);
      expect(trustedPageCount(5, 5), 1);
      expect(trustedPageCount(6, 5), 2);
      // Production au 25/09/2026 : 362 jeux → 73 pages (la dernière : 2).
      expect(trustedPageCount(362, 5), 73);
    });

    test('jeux par page bornés à [1, 50] comme le serveur', () {
      expect(trustedPageCount(362, 0), 362);
      expect(trustedPageCount(362, -4), 362);
      expect(trustedPageCount(362, 999), 8);
      expect(clampGamesPerPage(0), 1);
      expect(clampGamesPerPage(999), kTrustedMaxGamesPerPage);
      expect(clampGamesPerPage(kTrustedGamesPerPage), 5);
    });

    test('page bornée aux pages existantes', () {
      expect(clampTrustedPage(-3, 362, 5), 0);
      expect(clampTrustedPage(10, 362, 5), 10);
      expect(clampTrustedPage(100, 362, 5), 72);
      expect(clampTrustedPage(3, 0, 5), 0, reason: 'aucun jeu → page 0');
    });
  });

  group('trustedPageLabel', () {
    test('« Page X / N (jeux a-b sur T · C chaînes) »', () {
      expect(
        trustedPageLabel(
          page: 0,
          gamesPerPage: 5,
          totalGames: 362,
          totalChannels: 1509,
        ),
        'Page 1 / 73 (jeux 1-5 sur 362 · 1${nnbsp}509 chaînes)',
      );
      expect(
        trustedPageLabel(
          page: 72,
          gamesPerPage: 5,
          totalGames: 362,
          totalChannels: 1509,
        ),
        'Page 73 / 73 (jeux 361-362 sur 362 · 1${nnbsp}509 chaînes)',
      );
    });

    test('singulier, aucun jeu, page hors bornes', () {
      expect(
        trustedPageLabel(
          page: 0,
          gamesPerPage: 5,
          totalGames: 1,
          totalChannels: 1,
        ),
        'Page 1 / 1 (jeu 1 sur 1 · 1 chaîne)',
      );
      expect(
        trustedPageLabel(
          page: 0,
          gamesPerPage: 5,
          totalGames: 0,
          totalChannels: 0,
        ),
        'Page 1 / 1 (aucun jeu)',
      );
      // Page au-delà de la fin : libellé de la dernière page.
      expect(
        trustedPageLabel(
          page: 9,
          gamesPerPage: 5,
          totalGames: 12,
          totalChannels: 30,
        ),
        'Page 3 / 3 (jeux 11-12 sur 12 · 30 chaînes)',
      );
    });
  });

  group('normalizeTrustedSearch / trustedPageRequestBody', () {
    test('défauts : page 0, 5 jeux, pas de recherche', () {
      expect(trustedPageRequestBody(), <String, dynamic>{
        'page': 0,
        'games_per_page': 5,
      });
    });

    test('page et games_per_page TOUJOURS présents (active le mode page ; '
        'sans eux, la route renvoie la liste complète de Vision)', () {
      final Map<String, dynamic> body = trustedPageRequestBody(
        search: '  Zelda  ',
        page: -2,
        gamesPerPage: 999,
      );
      expect(body['page'], 0);
      expect(body['games_per_page'], kTrustedMaxGamesPerPage);
      expect(body['search'], 'Zelda');
      expect(
        trustedPageRequestBody(search: '   ').containsKey('search'),
        isFalse,
      );
    });

    test('recherche tronquée à 100 caractères sans couper une paire', () {
      expect(normalizeTrustedSearch('é' * 150).length, 100);
      final String cut = normalizeTrustedSearch('🎮' * 120);
      expect(cut.runes.length, kTrustedSearchMaxLength);
      expect(cut, '🎮' * 100);
      expect(normalizeTrustedSearch('  a_b%  '), 'a_b%');
    });
  });

  group('parseTrustedChannelsPage (réponse EF, mode page)', () {
    test('lignes + totaux exacts + page servie', () {
      final TrustedChannelsPage page = parseTrustedChannelsPage(
        <String, dynamic>{
          'channels': <Object?>[
            _row('c1'),
            _row('c2', gameId: 'g2', gameName: 'Autre'),
            <String, dynamic>{'game_id': 'g3'}, // sans id → ignorée
          ],
          'total_games': 362,
          'total_channels': 1509,
          'page': 4,
          'games_per_page': 5,
        },
        page: 4,
      );
      expect(page.channels.map((TrustedChannel c) => c.id), <String>[
        'c1',
        'c2',
      ]);
      expect(page.totalGames, 362);
      expect(page.totalChannels, 1509);
      expect(page.page, 4);
      expect(page.gamesPerPage, 5);
      expect(page.pageCount, 73);
      expect(page.fallbackPage, isNull);
      expect(page.label, startsWith('Page 5 / 73 (jeux 21-25 sur 362'));
    });

    test('page au-delà de la fin → recul sur la dernière page', () {
      TrustedChannelsPage parse(int requested, int totalGames) =>
          parseTrustedChannelsPage(<String, dynamic>{
            'channels': <Object?>[],
            'total_games': totalGames,
            'total_channels': totalGames * 3,
            'page': requested,
            'games_per_page': 5,
          });
      // 362 jeux : 73 pages (0..72).
      expect(parse(73, 362).fallbackPage, 72);
      expect(parse(80, 362).fallbackPage, 72);
      // Aucun résultat : page 0 vide = état vide, pas de boucle.
      expect(parse(0, 0).fallbackPage, isNull);
      expect(parse(3, 0).fallbackPage, 0);
    });

    test('réponse SANS total_games (EF antérieure, liste complète) → page '
        'découpée localement', () {
      final List<Map<String, dynamic>> full = <Map<String, dynamic>>[
        for (int g = 0; g < 7; g++)
          for (int k = 0; k < 2; k++)
            _row(
              'c$g-$k',
              gameId: 'g$g',
              gameName: 'Jeu $g',
              handle: k == 0 ? '@commune' : '@solo$g',
            ),
      ];
      final TrustedChannelsPage page = parseTrustedChannelsPage(
        <String, dynamic>{'channels': full},
        page: 1,
      );
      expect(page.totalGames, 7);
      expect(page.totalChannels, 14);
      expect(page.page, 1);
      expect(page.pageCount, 2);
      expect(page.channels.map((TrustedChannel c) => c.gameId).toSet(), {
        'g5',
        'g6',
      });
    });
  });

  group('applyTrustedPageLocally (miroir de la RPC 0088)', () {
    // 12 jeux (noms volontairement dans le désordre et en casse mixte),
    // 1 à 3 chaînes par jeu.
    final List<TrustedChannel> all = <TrustedChannel>[
      for (int g = 0; g < 12; g++)
        for (int k = 0; k <= g % 3; k++)
          _ch(
            'c${g.toString().padLeft(2, '0')}-$k',
            gameId: 'g${g.toString().padLeft(2, '0')}',
            gameName: g.isEven ? 'jeu ${11 - g}' : 'JEU ${11 - g}',
            handle: k == 1 ? '@Mixed_Case' : '@h$g$k',
            name: k == 2 ? 'Chaîne 100% FR' : null,
          ),
    ];

    test('pages disjointes et complètes, jamais un jeu coupé', () {
      final Set<String> seenRows = <String>{};
      final Set<String> seenGames = <String>{};
      final TrustedChannelsPage p0 = applyTrustedPageLocally(all);
      expect(p0.totalGames, 12);
      expect(p0.totalChannels, all.length);
      expect(p0.pageCount, 3);
      for (int p = 0; p < p0.pageCount; p++) {
        final TrustedChannelsPage page = applyTrustedPageLocally(all, page: p);
        final Set<String> games = page.channels
            .map((TrustedChannel c) => c.gameId)
            .toSet();
        expect(games.length, p < 2 ? 5 : 2);
        expect(games.intersection(seenGames), isEmpty);
        seenGames.addAll(games);
        for (final TrustedChannel c in page.channels) {
          expect(seenRows.add(c.id), isTrue, reason: 'doublon ${c.id}');
        }
      }
      expect(seenRows, hasLength(all.length));
      expect(applyTrustedPageLocally(all, page: 3).channels, isEmpty);
      expect(applyTrustedPageLocally(all, page: 3).fallbackPage, 2);
    });

    test('ordre : nom du jeu (casse ignorée) puis handle (casse ignorée)', () {
      final List<TrustedChannel> rows = <TrustedChannel>[
        for (int p = 0; p < 3; p++)
          ...applyTrustedPageLocally(all, page: p).channels,
      ];
      for (int i = 1; i < rows.length; i++) {
        final TrustedChannel a = rows[i - 1];
        final TrustedChannel b = rows[i];
        final int byGame = a.gameName.toLowerCase().compareTo(
          b.gameName.toLowerCase(),
        );
        expect(byGame <= 0, isTrue, reason: '${a.gameName} > ${b.gameName}');
        if (a.gameId == b.gameId) {
          expect(
            a.channelHandle.toLowerCase().compareTo(
                  b.channelHandle.toLowerCase(),
                ) <=
                0,
            isTrue,
          );
        }
      }
    });

    test('recherche : handle, nom de chaîne ou nom du jeu, casse ignorée, '
        '% et _ littéraux', () {
      int total(String q) =>
          applyTrustedPageLocally(all, search: q).totalChannels;
      // Handle en casse mixte.
      expect(
        total('mixed_case'),
        all
            .where((TrustedChannel c) => c.channelHandle == '@Mixed_Case')
            .length,
      );
      // « _ » littéral : seuls les handles qui en contiennent un.
      expect(total('_'), total('mixed_case'));
      // « % » littéral dans le nom de chaîne.
      expect(
        total('100%'),
        all.where((TrustedChannel c) => c.channelName != null).length,
      );
      // Nom du jeu : toutes les chaînes du jeu sont gardées.
      final TrustedChannelsPage jeu3 = applyTrustedPageLocally(
        all,
        search: 'JEU 3',
      );
      expect(jeu3.totalGames, 1);
      expect(
        jeu3.totalChannels,
        all
            .where((TrustedChannel c) => c.gameName.toLowerCase() == 'jeu 3')
            .length,
      );
      expect(total('introuvable'), 0);
      expect(total('   '), all.length);
    });
  });

  group('groupTrustedChannelsByGame', () {
    test('ordre conservé, homonymes distincts, compte par groupe', () {
      final List<TrustedGameGroup> groups =
          groupTrustedChannelsByGame(<TrustedChannel>[
            _ch('a', gameId: 'g1', gameName: 'Alpha'),
            _ch('b', gameId: 'g1', gameName: 'Alpha'),
            _ch('c', gameId: 'g2', gameName: 'Doublon'),
            _ch('d', gameId: 'g3', gameName: 'Doublon'),
          ]);
      expect(groups.map((TrustedGameGroup g) => g.gameId), <String>[
        'g1',
        'g2',
        'g3',
      ]);
      expect(groups.first.channels.map((TrustedChannel c) => c.id), <String>[
        'a',
        'b',
      ]);
      expect(groups[1].gameName, 'Doublon');
      expect(groups[2].channels, hasLength(1));
      expect(groupTrustedChannelsByGame(const <TrustedChannel>[]), isEmpty);
    });
  });

  group('linkedGameIdsForHandle (dialog « Ajouter un jeu »)', () {
    test('jeux du serveur ∪ jeux de la page du même handle (casse ignorée)',
        () {
      final TrustedChannel target = _ch('x', gameId: 'g1', handle: '@Nox');
      final Set<String> linked = linkedGameIdsForHandle(
        target,
        <TrustedChannel>[
          target,
          _ch('y', gameId: 'g2', handle: '@nox'),
          _ch('z', gameId: 'g3', handle: '@autre'),
        ],
        serverGameIds: const <String>['g1', 'g8', 'g9', ''],
      );
      expect(linked, <String>{'g1', 'g2', 'g8', 'g9'});
    });

    test('lecture serveur échouée : jeu de la ligne + page', () {
      final TrustedChannel target = _ch('x', gameId: 'g1', handle: '@a');
      expect(linkedGameIdsForHandle(target, const <TrustedChannel>[]), <String>{
        'g1',
      });
    });
  });

  group('replaceTrustedRow (switch « Active »)', () {
    test('ligne remplacée par la réponse d\'upsert, les autres intactes', () {
      final List<TrustedChannel> rows = <TrustedChannel>[_ch('a'), _ch('b')];
      final TrustedChannel updated = _ch('a', active: false);
      final List<TrustedChannel> next = replaceTrustedRow(rows, updated);
      expect(next.first.active, isFalse);
      expect(identical(next.first, updated), isTrue);
      expect(identical(next[1], rows[1]), isTrue);
      // Id inconnu (page changée entre-temps) : rien ne change.
      expect(
        replaceTrustedRow(
          rows,
          _ch('zz', active: false),
        ).map((TrustedChannel c) => c.active),
        <bool>[true, true],
      );
    });
  });

  group('SupabaseSync (appel HTTP simulé)', () {
    SupabaseSync sync() => SupabaseSync(
      supabaseUrl: 'https://exemple.supabase.co',
      anonKey: 'anon',
      catalogEndpoint: 'https://exemple.supabase.co/functions/v1/admin-catalog',
      adminToken: 'jeton',
    );

    test('fetchTrustedChannelsPage : route, corps page/games_per_page/search '
        'et lecture de la réponse', () async {
      final List<http.Request> seen = <http.Request>[];
      final MockClient client = MockClient((http.Request req) async {
        seen.add(req);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'channels': <Object?>[
              _row('c1'),
            ],
            'total_games': 1,
            'total_channels': 1,
            'page': 0,
            'games_per_page': 5,
            'fresh_token': 'nouveau',
          }),
          200,
          headers: <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      });
      final SupabaseSync s = sync();
      String? refreshed;
      s.onTokenRefreshed = (String t) => refreshed = t;
      final TrustedChannelsPage page = await http.runWithClient(
        () => s.fetchTrustedChannelsPage(search: '  zelda ', page: 2),
        () => client,
      );
      expect(seen, hasLength(1));
      expect(
        seen.single.url.path,
        endsWith('/admin-catalog/trusted-channels/list'),
      );
      expect(jsonDecode(seen.single.body), <String, dynamic>{
        'page': 2,
        'games_per_page': 5,
        'search': 'zelda',
      });
      expect(page.channels.single.id, 'c1');
      expect(page.totalGames, 1);
      expect(refreshed, 'nouveau');
    });

    test('fetchTrustedChannelGameIds : route handle-games, handle rogné, '
        'identifiants filtrés', () async {
      final List<http.Request> seen = <http.Request>[];
      final MockClient client = MockClient((http.Request req) async {
        seen.add(req);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'game_ids': <Object?>['g1', null, '', 'g2', 3],
          }),
          200,
        );
      });
      final List<String> ids = await http.runWithClient(
        () => sync().fetchTrustedChannelGameIds('  @Nox '),
        () => client,
      );
      expect(
        seen.single.url.path,
        endsWith('/admin-catalog/trusted-channels/handle-games'),
      );
      expect(jsonDecode(seen.single.body), <String, dynamic>{
        'handle': '@Nox',
      });
      expect(ids, <String>['g1', 'g2']);
    });

    test('fetchTrustedChannels (liste complète) : corps {} inchangé', () async {
      final List<String> bodies = <String>[];
      final MockClient client = MockClient((http.Request req) async {
        bodies.add(req.body);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'channels': <Object?>[_row('c1'), _row('c2')],
          }),
          200,
        );
      });
      final List<TrustedChannel> all = await http.runWithClient(
        () => sync().fetchTrustedChannels(),
        () => client,
      );
      expect(bodies, <String>['{}']);
      expect(all, hasLength(2));
    });
  });
}
