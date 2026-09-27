// §137 — forme CLÉ des alias (TitleCleaning.aliasKey, isValidAliasKey,
// hasNonLatinLetter) et couche distante des alias (un alias non latin
// n'entre jamais dans la table latine). Vecteurs communs avec
// packages/mgt_core (GameMatcher.aliasKey) : mêmes attendus au caractère
// près. Dart PUR (lib/domain/title_cleaning.dart) : exécuté en VM par
// `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/title_cleaning.dart';

void main() {
  // Vecteurs OBLIGATOIRES (§137). Pleine chasse, deux-points pleine chasse,
  // point médian katakana, Ё et tatweel écrits en échappements : le
  // caractère exact compte.
  const vectors = <String, String>{
    'Diablo 4': 'diablo 4',
    'd4': 'd4',
    "Assassin's Creed Shadows": 'assassins creed shadows',
    'Pokémon Écarlate': 'pokemon ecarlate',
    'Oxygène Not Included': 'oxygene not included',
    'Final Fantasy VII Remake': 'final fantasy 7',
    '\uFF26\uFF26\uFF17': 'ff7', // ＦＦ７
    '发薪日3': '发薪日3',
    '收获日 3': '收获日 3',
    'Ведьмак 3: Дикая Охота': 'ведьмак 3 дикая охота',
    '\u0401лка': '\u0435лка', // Ёлка → елка
    'بوابة بالدور 3': 'بوابة بالدور 3',
    '\u0644\u064A\u0640\u063A\u0648': '\u0644\u064A\u063A\u0648', // ليـغو
    'ゼルダの伝説 ティアーズ オブ ザ キングダム': 'ゼルダの伝説 ティアーズ オブ ザ キングダム',
    'スーパーマリオ\u30FBワンダー': 'スーパーマリオ ワンダー',
    'ファイナルファンタジーVII': 'ファイナルファンタジー7',
    '原神\uFF1A星穹铁道': '原神 星穹铁道',
    '엘든 링': '엘든 링',
    'लेगो बैटमैन': 'लेगो बैटमैन',
    'Minecraft マインクラフト': 'minecraft マインクラフト',
    '!!!': '',
    '3': '3',
    '  ': '',
  };

  /// Clés refusées par [TitleCleaning.isValidAliasKey] (vide ou sans lettre).
  const invalidInputs = {'!!!', '3', '  '};

  group('§137 — aliasKey (vecteurs obligatoires)', () {
    for (final v in vectors.entries) {
      test('« ${v.key} » → « ${v.value} »', () {
        final key = TitleCleaning.aliasKey(v.key);
        expect(key, v.value);
        expect(TitleCleaning.isValidAliasKey(key),
            !invalidInputs.contains(v.key),
            reason: 'validité de « $key »');
      });
    }
  });

  group('§137 — isValidAliasKey / hasNonLatinLetter', () {
    test('clé vide ou sans lettre refusée, toute lettre acceptée', () {
      for (final key in ['', '3', '2077', '3 4', ' ']) {
        expect(TitleCleaning.isValidAliasKey(key), isFalse, reason: key);
      }
      for (final key in ['d4', '原神', 'ведьмак 3', 'ليغو', 'ー']) {
        expect(TitleCleaning.isValidAliasKey(key), isTrue, reason: key);
      }
    });

    test('lettre non latine détectée, latin accentué et chiffres non', () {
      for (final t in ['发薪日3', 'Ведьмак', 'Minecraft マインクラフト', 'ليغو',
          '엘든', 'लेगो']) {
        expect(TitleCleaning.hasNonLatinLetter(t), isTrue, reason: t);
      }
      for (final t in ['Pokémon Écarlate', 'Œuvre', '2077', '!!!', '']) {
        expect(TitleCleaning.hasNonLatinLetter(t), isFalse, reason: t);
      }
    });
  });

  group('§137 — invariants', () {
    test('alias latin : clé identique à la forme clé d\'avant (B-001)', () {
      for (final raw in vectors.keys) {
        if (TitleCleaning.hasNonLatinLetter(raw) || raw.contains('\uFF26')) {
          continue;
        }
        expect(TitleCleaning.aliasKey(raw),
            TitleCleaning.normalizeGameNameNoAlias(raw),
            reason: raw);
      }
      // Forme CLÉ, jamais la forme canonique résolue.
      expect(TitleCleaning.aliasKey('d4'), 'd4');
      expect(TitleCleaning.normalizeGameName('d4'), 'diablo 4');
    });

    test('normalisation des TITRES inchangée', () {
      expect(TitleCleaning.normalizeGameNameNoAlias('发薪日3'), '3');
      expect(TitleCleaning.normalizeGameNameNoAlias('原神'), '');
      expect(TitleCleaning.normalizeGameName('Final Fantasy VII Remake'),
          'final fantasy 7');
    });
  });

  group('§137 — alias distants non latins hors de la table latine', () {
    tearDown(() => TitleCleaning.setRemoteAliases(const []));

    void load() => TitleCleaning.setRemoteAliases(const [
          (alias: '发薪日3', aliasNorm: '发薪日3', gameName: 'Payday 3'),
          // Ligne d'avant §137 : clé latine « 3 », reste de « 发薪日3 ».
          (alias: '发薪日3', aliasNorm: '3', gameName: 'Payday 3'),
          (alias: '原神', aliasNorm: '', gameName: 'Genshin Impact'),
          // Clé latine sans lettre : ignorée aussi.
          (alias: '2077', aliasNorm: '2077', gameName: 'Cyberpunk 2077'),
          (alias: 'PD3', aliasNorm: 'pd3', gameName: 'Payday 3'),
        ]);

    test('ni « », ni « 3 », ni « 2077 », ni écriture non latine', () {
      load();
      final known = TitleCleaning.knownAliases;
      expect(known.containsKey('3'), isFalse);
      expect(known.containsKey(''), isFalse);
      expect(known.containsKey('2077'), isFalse);
      expect(known.keys.where(TitleCleaning.hasNonLatinLetter), isEmpty);
      expect(known['pd3'], 'payday 3');
      // Un titre qui normalise en « 3 » n'est rattaché à aucun jeu.
      expect(TitleCleaning.normalizeGameName('发薪日3'), '3');
      expect(TitleCleaning.normalizeGameName('3'), '3');
    });

    test('alias non latins rangés par jeu (nom résolu par alias)', () {
      load();
      expect(TitleCleaning.nonLatinAliasesFor('PAYDAY 3'), ['发薪日3']);
      expect(TitleCleaning.nonLatinAliasesFor('PD3'), ['发薪日3']);
      expect(TitleCleaning.nonLatinAliasesFor('Genshin Impact'), ['原神']);
      expect(TitleCleaning.nonLatinAliasesFor('Cyberpunk 2077'), isEmpty);
    });

    test('ajoutés aux titres traduits, puis retirés des titres', () {
      expect(TitleCleaning.withNonLatinAliases('Payday 3', null), isNull,
          reason: 'base non chargée : comportement antérieur');
      load();
      expect(TitleCleaning.withNonLatinAliases('Payday 3', null), ['发薪日3']);
      expect(
          TitleCleaning.withNonLatinAliases('Payday 3', ['收获日3', '发薪日3']),
          ['收获日3', '发薪日3']);
      expect(TitleCleaning.withNonLatinAliases('Diablo 4', ['Diablo IV']),
          ['Diablo IV']);
      expect(
          TitleCleaning.cleanTitleForInsertion('【4K】发薪日3 全成就攻略',
              gameName: 'Payday 3',
              translatedNames:
                  TitleCleaning.withNonLatinAliases('Payday 3', null)),
          '全成就攻略');
    });
  });
}
