// §123 — nettoyage des titres pour insertion (copie du panneau, même
// algorithme que Sentinelle) et titre des pages web.
// Dart PUR (lib/domain/title_cleaning.dart) : aucune dépendance Flutter
// ni dart:html — exécuté en VM par `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/models/suggestion.dart';
import 'package:mgt_admin/domain/title_cleaning.dart';

void main() {
  String clean(String t, String? g, [List<String>? tr]) =>
      TitleCleaning.cleanTitleForInsertion(t,
          gameName: g, translatedNames: tr);

  test('exemples du propriétaire (25/09/2026)', () {
    expect(
        clean(
            'How to eliminate your enemies fast in #armareforger #gaming '
            '#pc #tactics #ps5 #xbox #tutorial',
            'Arma Reforger'),
        'How to eliminate your enemies fast');
    expect(
        clean('Do this in Arma Reforger #armareforger #gaming #pc #ps5 #tips',
            'Arma Reforger'),
        'Do this');
  });

  test('bords du titre intacts loin de la mention, possessif retiré', () {
    expect(clean('To beat the boss in Elden Ring', 'Elden Ring'),
        'To beat the boss');
    expect(clean('Elden Ring - Do this now', 'Elden Ring'), 'Do this now');
    expect(clean("Top 10 Arma Reforger's secrets", 'Arma Reforger'),
        'Top 10 secrets');
    expect(clean('DO it yourself build', 'Elden Ring'), 'DO it yourself build');
    // Cas historiques inchangés.
    expect(clean('Comment jouer son nécromancien Dans Albion', 'Albion'),
        'Comment jouer son nécromancien');
    expect(clean('Guide complet (Elden Ring)', 'Elden Ring'), 'Guide complet');
    expect(clean('Obby astuces #328 #bloxfruits', 'Roblox'),
        'Obby astuces #328 #bloxfruits');
  });

  test('entités HTML, 【4K】, bilibili, nom chinois du jeu', () {
    expect(clean('Elden Ring &#8211; Assassin&#039;s build', 'Elden Ring'),
        'Assassin\'s build');
    expect(clean('【4K】艾尔登法环 全BOSS攻略 Elden Ring', 'Elden Ring', ['艾尔登法环']),
        '全BOSS攻略');
    expect(clean('艾尔登法环全BOSS攻略_哔哩哔哩_bilibili', 'Elden Ring', ['艾尔登法环']),
        '全BOSS攻略');
  });

  test('une préposition par mention ; langues des packs ; CJK', () {
    expect(clean('What to do in Elden Ring', 'Elden Ring'), 'What to do');
    expect(clean('Guide for (Elden Ring)', 'Elden Ring'), 'Guide');
    expect(clean('Dicas para Elden Ring', 'Elden Ring'), 'Dicas');
    expect(clean('Гайд по Elden Ring для новичков', 'Elden Ring'),
        'Гайд для новичков');
    expect(clean('Como upar rápido no Elden Ring', 'Elden Ring'),
        'Como upar rápido');
    expect(clean('No Elden Ring spoilers please', 'Elden Ring'),
        'No spoilers please');
    expect(clean('艾尔登法环的全BOSS攻略', 'Elden Ring', ['艾尔登法环']),
        '全BOSS攻略');
    expect(clean('Elden Ring | 艾尔登法环 | 攻略', 'Elden Ring', ['艾尔登法环']),
        '攻略');
    expect(clean('Best build in #d4 #diablo', 'Diablo 4'), 'Best build');
  });

  test('alias de la base (couche distante) retirés comme chez Sentinelle', () {
    addTearDown(() => TitleCleaning.setRemoteAliases(const []));
    const title = 'Controversial New Glitch Breaking GTA 5 Speedrun Community';
    // Sans la base : « GTA 5 » n'est pas un alias codé en dur.
    expect(clean(title, 'Grand Theft Auto V'), title);
    TitleCleaning.setRemoteAliases(const [
      (aliasNorm: 'gta 5', gameName: 'Grand Theft Auto V'),
      (aliasNorm: 'gta5', gameName: 'Grand Theft Auto V'),
      (aliasNorm: '', gameName: 'Grand Theft Auto V'), // ignoré
    ]);
    expect(clean(title, 'Grand Theft Auto V'),
        'Controversial New Glitch Breaking Speedrun Community');
    expect(clean('Best heist in #gta5 #gaming', 'Grand Theft Auto V'),
        'Best heist');
    // Résolution d'un nom par la base (jeu proposé sous son alias).
    expect(TitleCleaning.normalizeGameName('GTA 5'), 'grand theft auto 5');
    expect(clean(title, 'GTA 5'),
        'Controversial New Glitch Breaking Speedrun Community');
  });

  test('§125 — nom de la chaîne retiré quand il est détaché', () {
    addTearDown(() => TitleCleaning.setRemoteAliases(const []));
    TitleCleaning.setRemoteAliases(const [
      (aliasNorm: 'gta 5', gameName: 'Grand Theft Auto V'),
    ]);
    // Exemple du propriétaire (titre brut : alias « GTA 5 » + chaîne).
    expect(
        TitleCleaning.cleanTitleForInsertion(
            'Controversial New Glitch Breaking GTA 5 Speedrun Community - '
            'Director Glitching - DarkViperAU',
            gameName: 'Grand Theft Auto V',
            channelName: 'DarkViperAU'),
        'Controversial New Glitch Breaking Speedrun Community - Director '
        'Glitching');
    // Titre PROPOSÉ par une analyse d'avant §125 (chaîne restée dedans).
    expect(
        TitleCleaning.stripChannelName(
            'Secret Forbidden Staircase - DarkViperAU', 'DarkViperAU',
            gameName: 'Grand Theft Auto V'),
        'Secret Forbidden Staircase');
    expect(TitleCleaning.stripChannelName('濟州島還安全嗎？｜志祺七七', '志祺七七'),
        '濟州島還安全嗎？');
    // Gardé dans la phrase ; idempotent ; sans chaîne = inchangé.
    const kept = 'How IGN Won a Team Fighting Game Tournament';
    expect(TitleCleaning.stripChannelName(kept, 'IGN'), kept);
    expect(TitleCleaning.stripChannelName('Secret Forbidden Staircase',
            'DarkViperAU'),
        'Secret Forbidden Staircase');
    expect(TitleCleaning.stripChannelName('Boss - DarkViperAU', null),
        'Boss - DarkViperAU');
  });

  test('§125 — nom de la chaîne lu pour chaque plateforme', () {
    AiRecommendation parse(Map<String, dynamic> extra) =>
        AiRecommendation.fromJson({'verdict': 'recommended', ...extra});
    expect(parse({'youtube_channel': 'DarkViperAU'}).channelName,
        'DarkViperAU');
    expect(parse({'bili_channel': '志祺七七'}).channelName, '志祺七七');
    expect(parse({'rutube_channel': 'Гайды'}).channelName, 'Гайды');
    expect(parse({}).channelName, isNull);
    // Copie locale (toJson → fromJson) : le nom survit.
    final back = AiRecommendation.fromJson(
        parse({'bili_channel': '志祺七七'}).toJson());
    expect(back.channelName, '志祺七七');
  });

  test('§126 — noms de jeux à chiffres romains retirés', () {
    // Forme normalisée « modern warfare 3 » : le titre écrit « III ».
    expect(
        clean('Campaign Trailer | Call of Duty: Modern Warfare III',
            'Call of Duty Modern Warfare 3'),
        'Campaign Trailer');
    expect(clean('Civ Tour: England | Civilization VII', 'Civilization 7'),
        'Civ Tour: England');
    expect(clean('Mortal Kombat X: My Top 5 Characters', 'Mortal Kombat X'),
        'My Top 5 Characters');
    expect(clean('V Rising - Castle build guide', 'V Rising'),
        'Castle build guide');
    // Autre jeu de la série (« X4 ») et hashtag ordinaire : gardés.
    expect(clean('Mega Man X4 speedrun any%', 'Mega Man X'),
        'Mega Man X4 speedrun any%');
    expect(clean('Chaos mode in #pov', 'Grand Theft Auto V'),
        'Chaos mode in');
    // Hashtag à romain collé : repère du jeu (« in » part avec lui).
    expect(clean('Best build in #BaldursGateIII #gaming', "Baldur's Gate 3"),
        'Best build');
  });

  test('page web : domaine du site ; plateformes vidéo reconnues', () {
    const url = 'https://gamerant.com/alan-wake-2-walkthrough-chapters/';
    expect(TitleCleaning.webTitleWithDomain('Walkthrough: Chapters', url),
        'Walkthrough: Chapters (gamerant.com)');
    expect(
        TitleCleaning.webTitleWithDomain(
            'Alan Wake 2 Walkthrough | Game Rant', url),
        'Alan Wake 2 Walkthrough (gamerant.com)');
    expect(TitleCleaning.isVideoPlatformUrl(url), isFalse);
    expect(
        TitleCleaning.isVideoPlatformUrl(
            'https://www.bilibili.com/video/BV1xx'),
        isTrue);
    expect(TitleCleaning.isVideoPlatformUrl('https://b23.tv/abc'), isTrue);
    expect(TitleCleaning.isVideoPlatformUrl('https://rutube.ru/video/x/'),
        isTrue);
  });
}
