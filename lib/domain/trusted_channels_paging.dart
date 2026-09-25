// Chaînes YT — pagination SERVEUR PAR JEU (migration 0088, route EF
// `trusted-channels/list` avec page / games_per_page) : requête de page,
// lecture de la réponse, nombre de pages, bornage, libellé de la barre de
// pagination, regroupement des lignes par jeu, jeux déjà liés à un handle.
//
// Demande propriétaire (25/09/2026) : « paginer le menu "Chaînes YT" […]
// pour afficher seulement 5 jeux à la fois dans un tableau avec autant de
// pages que nécessaire » — l'écran chargeait les ~1 500 chaînes et
// construisait ~1 900 cartes d'un coup.
// Logique PURE (aucun import Flutter ni dart:html) : testée sur VM.

import 'models/trusted_channel.dart';
import 'plus_paging.dart' show formatCount;

/// Jeux par page du tableau (demande propriétaire).
const int kTrustedGamesPerPage = 5;

/// Plafond du nombre de jeux par page (même borne côté EF et RPC 0088).
const int kTrustedMaxGamesPerPage = 50;

/// Longueur maximale de la recherche (caractères) — même borne côté EF/SQL.
const int kTrustedSearchMaxLength = 100;

/// Recherche rognée, tronquée à [kTrustedSearchMaxLength] caractères (points
/// de code : jamais de paire de substitution coupée).
String normalizeTrustedSearch(String raw) {
  final String q = raw.trim();
  if (q.runes.length <= kTrustedSearchMaxLength) return q;
  return String.fromCharCodes(q.runes.take(kTrustedSearchMaxLength));
}

/// Jeux par page bornés à [1, kTrustedMaxGamesPerPage] (comme le serveur).
int clampGamesPerPage(int gamesPerPage) =>
    gamesPerPage.clamp(1, kTrustedMaxGamesPerPage);

/// Nombre de pages pour [totalGames] jeux (au moins 1, même sans résultat).
int trustedPageCount(int totalGames, int gamesPerPage) {
  final int size = clampGamesPerPage(gamesPerPage);
  if (totalGames <= 0) return 1;
  return (totalGames + size - 1) ~/ size;
}

/// [page] bornée aux pages existantes : [0, trustedPageCount - 1].
int clampTrustedPage(int page, int totalGames, int gamesPerPage) =>
    page.clamp(0, trustedPageCount(totalGames, gamesPerPage) - 1);

/// Libellé de la barre de pagination :
/// « Page X / N (jeux a-b sur T · C chaînes) » ([page] = index 0-based).
String trustedPageLabel({
  required int page,
  required int gamesPerPage,
  required int totalGames,
  required int totalChannels,
}) {
  final int pages = trustedPageCount(totalGames, gamesPerPage);
  final int current = clampTrustedPage(page, totalGames, gamesPerPage);
  final String head =
      'Page ${formatCount(current + 1)} / ${formatCount(pages)}';
  if (totalGames <= 0) return '$head (aucun jeu)';
  final int size = clampGamesPerPage(gamesPerPage);
  final int first = current * size + 1;
  final int last = (current + 1) * size > totalGames
      ? totalGames
      : (current + 1) * size;
  final String games = first == last
      ? 'jeu ${formatCount(first)}'
      : 'jeux ${formatCount(first)}-${formatCount(last)}';
  final String channels =
      '${formatCount(totalChannels)} ${totalChannels > 1 ? 'chaînes' : 'chaîne'}';
  return '$head ($games sur ${formatCount(totalGames)} · $channels)';
}

/// Corps JSON de la route EF `trusted-channels/list` en mode page. La
/// présence de `page` / `games_per_page` active ce mode côté serveur (sans
/// eux, la route renvoie la liste COMPLÈTE — contrat de Vision.exe).
Map<String, dynamic> trustedPageRequestBody({
  String search = '',
  int page = 0,
  int gamesPerPage = kTrustedGamesPerPage,
}) {
  final String q = normalizeTrustedSearch(search);
  return <String, dynamic>{
    'page': page < 0 ? 0 : page,
    'games_per_page': clampGamesPerPage(gamesPerPage),
    if (q.isNotEmpty) 'search': q,
  };
}

/// Une page du tableau « Chaînes YT » : chaînes des jeux de la page (triées
/// jeu puis handle) + totaux EXACTS correspondant à la recherche.
class TrustedChannelsPage {
  const TrustedChannelsPage({
    required this.channels,
    required this.totalGames,
    required this.totalChannels,
    required this.page,
    required this.gamesPerPage,
  });

  /// Lignes des jeux de la page, dans l'ordre d'affichage.
  final List<TrustedChannel> channels;

  /// Nombre de jeux (toutes pages) ayant au moins une chaîne gardée.
  final int totalGames;

  /// Nombre de chaînes gardées (toutes pages).
  final int totalChannels;

  /// Page effectivement servie (0 = première).
  final int page;

  /// Jeux par page effectivement appliqués.
  final int gamesPerPage;

  /// Nombre de pages (au moins 1).
  int get pageCount => trustedPageCount(totalGames, gamesPerPage);

  /// Libellé « Page X / N (jeux a-b sur T · C chaînes) ».
  String get label => trustedPageLabel(
    page: page,
    gamesPerPage: gamesPerPage,
    totalGames: totalGames,
    totalChannels: totalChannels,
  );

  /// Page à charger À LA PLACE de celle-ci quand elle est au-delà de la fin
  /// (ex. dernière chaîne du dernier jeu de la dernière page retirée) : la
  /// dernière page existante. null si cette page est valide.
  int? get fallbackPage {
    if (channels.isNotEmpty) return null;
    final int last = pageCount - 1;
    return page > last ? last : null;
  }

  /// Copie avec d'autres lignes (mêmes totaux et page).
  TrustedChannelsPage withChannels(List<TrustedChannel> rows) =>
      TrustedChannelsPage(
        channels: rows,
        totalGames: totalGames,
        totalChannels: totalChannels,
        page: page,
        gamesPerPage: gamesPerPage,
      );
}

/// Lit la réponse de la route EF `trusted-channels/list` en mode page
/// `{channels, total_games, total_channels, page, games_per_page}`. Une
/// ligne sans identifiant est ignorée.
///
/// Réponse SANS `total_games` (EF antérieure à 0088, qui ignore la
/// pagination et renvoie la liste complète) : la page est découpée
/// localement ([applyTrustedPageLocally]) avec [search] / [page] /
/// [gamesPerPage] — l'écran reste cohérent pendant un déploiement partiel.
TrustedChannelsPage parseTrustedChannelsPage(
  Map<String, dynamic> data, {
  String search = '',
  int page = 0,
  int gamesPerPage = kTrustedGamesPerPage,
}) {
  final Object? rows = data['channels'];
  final List<TrustedChannel> channels = rows is List
      ? rows
            .whereType<Map<String, dynamic>>()
            .map(TrustedChannel.fromJson)
            .where((TrustedChannel c) => c.id.isNotEmpty)
            .toList()
      : <TrustedChannel>[];
  final Object? totalGames = data['total_games'];
  if (totalGames is! num) {
    return applyTrustedPageLocally(
      channels,
      search: search,
      page: page,
      gamesPerPage: gamesPerPage,
    );
  }
  final Object? totalChannels = data['total_channels'];
  final Object? servedPage = data['page'];
  final Object? servedSize = data['games_per_page'];
  return TrustedChannelsPage(
    channels: channels,
    totalGames: totalGames.toInt(),
    totalChannels: totalChannels is num
        ? totalChannels.toInt()
        : channels.length,
    page: servedPage is num ? servedPage.toInt() : (page < 0 ? 0 : page),
    gamesPerPage: clampGamesPerPage(
      servedSize is num ? servedSize.toInt() : gamesPerPage,
    ),
  );
}

/// Équivalent LOCAL de la RPC `admin_trusted_channels_page` sur une liste
/// complète (repli EF antérieure) : même filtre (handle, nom de chaîne ou
/// nom du jeu « contient », casse ignorée), jeux triés par nom (casse
/// ignorée) puis id, découpage par jeu, lignes triées jeu puis handle.
/// Seul l'ordre des caractères non ASCII peut différer de la collation SQL.
TrustedChannelsPage applyTrustedPageLocally(
  List<TrustedChannel> all, {
  String search = '',
  int page = 0,
  int gamesPerPage = kTrustedGamesPerPage,
}) {
  final String q = normalizeTrustedSearch(search).toLowerCase();
  final int size = clampGamesPerPage(gamesPerPage);
  final int current = page < 0 ? 0 : page;

  final List<TrustedChannel> kept = q.isEmpty
      ? List<TrustedChannel>.of(all)
      : all
            .where(
              (TrustedChannel c) =>
                  c.channelHandle.toLowerCase().contains(q) ||
                  (c.channelName?.toLowerCase().contains(q) ?? false) ||
                  c.gameName.toLowerCase().contains(q),
            )
            .toList();
  kept.sort(_rowOrder);

  // Jeux distincts dans l'ordre d'affichage (kept est déjà trié par jeu).
  final List<String> gameIds = <String>[];
  final Set<String> seen = <String>{};
  for (final TrustedChannel c in kept) {
    if (seen.add(c.gameId)) gameIds.add(c.gameId);
  }
  final Set<String> pageGames = gameIds.skip(current * size).take(size).toSet();

  return TrustedChannelsPage(
    channels: <TrustedChannel>[
      for (final TrustedChannel c in kept)
        if (pageGames.contains(c.gameId)) c,
    ],
    totalGames: gameIds.length,
    totalChannels: kept.length,
    page: current,
    gamesPerPage: size,
  );
}

/// Ordre des lignes : nom du jeu (casse ignorée), id du jeu, handle (casse
/// ignorée), id — miroir de l'ORDER BY de la RPC 0088.
int _rowOrder(TrustedChannel a, TrustedChannel b) {
  int c = a.gameName.toLowerCase().compareTo(b.gameName.toLowerCase());
  if (c != 0) return c;
  c = a.gameId.compareTo(b.gameId);
  if (c != 0) return c;
  c = a.channelHandle.toLowerCase().compareTo(b.channelHandle.toLowerCase());
  if (c != 0) return c;
  return a.id.compareTo(b.id);
}

/// Groupe des lignes d'un même jeu (ordre serveur conservé).
class TrustedGameGroup {
  const TrustedGameGroup({
    required this.gameId,
    required this.gameName,
    required this.channels,
  });

  final String gameId;
  final String gameName;
  final List<TrustedChannel> channels;
}

/// Regroupe les lignes par jeu (identifiant — deux jeux homonymes restent
/// distincts), dans l'ordre de première apparition.
List<TrustedGameGroup> groupTrustedChannelsByGame(List<TrustedChannel> rows) {
  final Map<String, List<TrustedChannel>> byGame =
      <String, List<TrustedChannel>>{};
  for (final TrustedChannel c in rows) {
    byGame.putIfAbsent(c.gameId, () => <TrustedChannel>[]).add(c);
  }
  return <TrustedGameGroup>[
    for (final MapEntry<String, List<TrustedChannel>> e in byGame.entries)
      TrustedGameGroup(
        gameId: e.key,
        gameName: e.value.first.gameName,
        channels: List<TrustedChannel>.unmodifiable(e.value),
      ),
  ];
}

/// Jeux déjà liés au handle de [channel] (casse ignorée), à exclure du
/// dialog « Ajouter un jeu » : [serverGameIds] (route EF
/// `trusted-channels/handle-games`, lue à l'ouverture du dialog — toute la
/// table) ∪ jeux des lignes de [pageRows] portant le même handle ∪ jeu de
/// la ligne elle-même.
Set<String> linkedGameIdsForHandle(
  TrustedChannel channel,
  Iterable<TrustedChannel> pageRows, {
  Iterable<String> serverGameIds = const <String>[],
}) {
  final String key = channel.channelHandle.toLowerCase();
  return <String>{
    ...serverGameIds,
    channel.gameId,
    for (final TrustedChannel c in pageRows)
      if (c.channelHandle.toLowerCase() == key) c.gameId,
  }..remove('');
}

/// Remplace dans [rows] la ligne de même identifiant que [updated] (ex.
/// réponse d'un upsert après le switch « Active ») ; id inconnu (page
/// changée entre-temps) : liste inchangée.
List<TrustedChannel> replaceTrustedRow(
  List<TrustedChannel> rows,
  TrustedChannel updated,
) => <TrustedChannel>[
  for (final TrustedChannel c in rows) c.id == updated.id ? updated : c,
];
