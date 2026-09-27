// §137 — gardes d'écriture des alias (route EF games/aliases/set) :
// dialogue Alias du menu Jeux (buildGameAliasPayload), alias candidat D3.4
// et « Synchroniser les alias connus » (mergeGameAliases). Dart PUR
// (lib/domain/game_alias_payload.dart) : exécuté en VM par `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/game_alias_payload.dart';
import 'package:mgt_admin/domain/models/game_alias.dart';

GameAlias _row(String alias, String norm) =>
    GameAlias(id: 'id-$norm', alias: alias, aliasNorm: norm);

void main() {
  group('§137 — buildGameAliasPayload (dialogue Alias)', () {
    test('clés d\'alias, dédup par alias_norm, vides ignorés', () {
      final r = buildGameAliasPayload(
          [' D4 ', 'd4', '发薪日3', '', '\uFF26\uFF26\uFF17', 'FF7', '原神']);
      expect(r.invalid, isEmpty);
      expect(r.payload, [
        {'alias': 'D4', 'alias_norm': 'd4'},
        {'alias': '发薪日3', 'alias_norm': '发薪日3'},
        {'alias': '\uFF26\uFF26\uFF17', 'alias_norm': 'ff7'},
        {'alias': '原神', 'alias_norm': '原神'},
      ]);
    });

    test('clé sans lettre refusée : l\'appelant n\'écrit rien', () {
      final r = buildGameAliasPayload(['Diablo IV', '3', '!!!', '2077']);
      expect(r.invalid, ['3', '!!!', '2077']);
      expect(r.payload, [
        {'alias': 'Diablo IV', 'alias_norm': 'diablo 4'},
      ]);
      expect(quoteGameAliases(r.invalid), '« 3 », « !!! », « 2077 »');
    });
  });

  group('§137 — mergeGameAliases (chemins automatiques)', () {
    test('union : ancienne ligne « 3 » réparée, ajout en fin', () {
      final m = mergeGameAliases(
          [_row('PD3', 'pd3'), _row('发薪日3', '3')], ['收获日3']);
      expect(m.added, ['收获日3']);
      expect(m.invalidExisting, isEmpty);
      expect(m.payload, [
        {'alias': 'PD3', 'alias_norm': 'pd3'},
        {'alias': '发薪日3', 'alias_norm': '发薪日3'},
        {'alias': '收获日3', 'alias_norm': '收获日3'},
      ]);
    });

    test('ajout déjà présent, vide ou sans lettre : sans-op', () {
      final m = mergeGameAliases([_row('D4', 'd4')], ['d4', ' ', '3', '!!!']);
      expect(m.added, isEmpty);
      expect(m.payload, [
        {'alias': 'D4', 'alias_norm': 'd4'},
      ]);
    });

    test('alias déjà en base sans lettre : signalé, jamais envoyé', () {
      final m = mergeGameAliases([_row('2077', '2077')], ['cp2077']);
      expect(m.added, ['cp2077']);
      expect(m.invalidExisting, ['2077']);
      expect(m.payload.map((e) => e['alias_norm']), isNot(contains('2077')));
    });

    test('ajouts de même clé (oxygène / oxygene) : un seul', () {
      final m = mergeGameAliases(const <GameAlias>[],
          ['oni', 'oxygene not included', 'oxygène not included']);
      expect(m.added, ['oni', 'oxygene not included']);
    });

    test('forme affichée vide en base : repli sur la clé', () {
      expect(gameAliasDisplay(_row('', 'lb')), 'lb');
      expect(gameAliasDisplay(_row(' LEGO Batman ', 'lego batman')),
          'LEGO Batman');
    });
  });
}
