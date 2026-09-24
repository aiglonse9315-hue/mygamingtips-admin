import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/alt_titles_input.dart';
import 'package:mgt_admin/domain/models/suggestion.dart';

// §119 — champ « Autres noms » de la fenêtre Traductions et repère « jeu
// cherché par Vision » du tableau Sentinelle.
void main() {
  group('parseAltTitlesInput', () {
    test('un nom par ligne (ou « ; »), rogné, vides ignorés', () {
      expect(parseAltTitlesInput('发薪日3\n  PD3 ; \n\n收获日三；payday three'),
          ['发薪日3', 'PD3', '收获日三', 'payday three']);
    });

    test('doublons (casse ignorée) et nom identique au titre écartés', () {
      expect(
          parseAltTitlesInput('Майнкрафт\nмайнкрафт\nMinecraft',
              title: 'Minecraft'),
          ['Майнкрафт']);
    });

    test('bornes : 20 noms max, 200 caractères max par nom', () {
      final many = List.generate(30, (i) => 'nom $i').join('\n');
      expect(parseAltTitlesInput(many), hasLength(kAltTitlesMaxPerLang));
      expect(parseAltTitlesInput('${'x' * 201}\nok'), ['ok']);
    });
  });

  group('AiRecommendation.visionSearchLabel', () {
    test('jeu cherché, langue, chaîne de confiance', () {
      final ai = AiRecommendation.fromJson({
        'target_game': 'Raft',
        'search_language': 'RU',
        'found_via': 'trusted_channel',
      });
      expect(ai.visionSearchLabel,
          '🔎 Vision cherchait : Raft · RU · chaîne de confiance');
      expect(AiRecommendation.fromJson(ai.toJson()).visionSearchLabel,
          ai.visionSearchLabel,
          reason: 'aller-retour du stockage local');
    });

    test('inconnu (avant §119, Scruteur, joueurs) → null', () {
      expect(AiRecommendation.fromJson({'verdict': 'caution'}).visionSearchLabel,
          isNull);
    });
  });
}
