// Tests purs (VM) du texte non fiable et des saisies de la modération
// (P4b-3, lot L3, conception §4.3) : rendu visible des caractères cachés,
// condensation et bornes d'affichage, aperçu sur une ligne, JSON révélé,
// motif de revue en points de code, empreintes, jours de purge.
//
// Aucune fixture ne contient de phrase d'attaque : les caractères spéciaux
// sont construits par String.fromCharCode. Aucune assertion de durée.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/moderation_text.dart';

String ch(int codePoint) => String.fromCharCode(codePoint);

String rep(String s, int n) => List<String>.filled(n, s).join();

String hex(int c) => 'U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}';

void main() {
  group('revealInvisibles — jetons', () {
    test('CR LF → « ⟦CR⟧ » puis un vrai saut de ligne', () {
      final RevealedText r = revealInvisibles('a\r\nb');
      expect(r.text, 'a⟦CR⟧\nb');
      expect(r.hiddenCount, 1);
      expect(r.codePoints, <int>{0x0D});
      expect(r.truncated, isFalse);
    });

    test('tabulation → « ⟦TAB⟧ »', () {
      final RevealedText r = revealInvisibles('a\tb');
      expect(r.text, 'a⟦TAB⟧b');
      expect(r.hiddenCount, 1);
    });

    test(
      'bidi, largeur nulle, BOM, trait conditionnel, étiquette, sélecteur, remplisseur',
      () {
        for (final int c in <int>[
          0x202E,
          0x2066,
          0x200B,
          0x200D,
          0xFEFF,
          0x00AD,
          0xE0041,
          0xE0100,
          0x3164,
        ]) {
          final RevealedText r = revealInvisibles('a${ch(c)}b');
          expect(r.text, 'a⟦${hex(c)}⟧b', reason: hex(c));
          expect(r.hiddenCount, 1, reason: hex(c));
          expect(r.codePoints, <int>{c}, reason: hex(c));
        }
        expect(revealInvisibles('a${ch(0xE0041)}b').text, 'a⟦U+E0041⟧b');
      },
    );

    test(
      'v2 (S-05) : formats arabes, syriaques, kaithi, hiéroglyphes → jetons',
      () {
        for (final int c in <int>[
          0x0600,
          0x06DD,
          0x070F,
          0x0890,
          0x08E2,
          0x110BD,
          0x13430,
        ]) {
          expect(
            revealInvisibles('a${ch(c)}b').text,
            'a⟦${hex(c)}⟧b',
            reason: hex(c),
          );
        }
      },
    );

    test('contrôles C0 / C1 → jetons', () {
      expect(revealInvisibles('a${ch(0x00)}b').text, 'a⟦U+0000⟧b');
      expect(revealInvisibles('a${ch(0x1B)}b').text, 'a⟦U+001B⟧b');
      expect(revealInvisibles('a${ch(0x85)}b').text, 'a⟦U+0085⟧b');
    });

    test('moitié de paire isolée → jeton', () {
      expect(revealInvisibles('a${ch(0xD800)}b').text, 'a⟦U+D800⟧b');
      expect(revealInvisibles('a${ch(0xDC00)}b').text, 'a⟦U+DC00⟧b');
      expect(revealInvisibles('a${ch(0xD83D)}').hiddenCount, 1);
    });

    test('émojis et sélecteur après une base INCHANGÉS', () {
      final String smile = ch(0x1F600);
      final String heart = '${ch(0x2764)}${ch(0xFE0F)}';
      final RevealedText r = revealInvisibles('a $smile $heart b');
      expect(r.text, 'a $smile $heart b');
      expect(r.hiddenCount, 0);
      expect(r.codePoints, isEmpty);
    });

    test('espaces visibles tolérés INCHANGÉS', () {
      for (final int c in <int>[
        0x20,
        0xA0,
        0x202F,
        0x3000,
        0x1680,
        0x2000,
        0x2003,
        0x200A,
        0x205F,
      ]) {
        final RevealedText r = revealInvisibles('a${ch(c)}b');
        expect(r.text, 'a${ch(c)}b', reason: hex(c));
        expect(r.hiddenCount, 0, reason: hex(c));
      }
      expect(revealInvisibles('a\nb').text, 'a\nb');
    });

    test(
      'v2 : sélecteur en tête, après un autre sélecteur, après un caché ou un saut de ligne → jeton',
      () {
        final String vs = ch(0xFE0F);
        final String heart = ch(0x2764);
        expect(revealInvisibles('${vs}x').text, '⟦U+FE0F⟧x');
        expect(revealInvisibles('$heart$vs$vs').text, '$heart$vs⟦U+FE0F⟧');
        expect(
          revealInvisibles('a${ch(0xE0100)}${vs}b').text,
          'a⟦U+E0100⟧⟦U+FE0F⟧b',
        );
        expect(revealInvisibles('a\n$vs').text, 'a\n⟦U+FE0F⟧');
        expect(
          revealInvisibles('a${ch(0x200B)}${ch(0xFE00)}').text,
          'a⟦U+200B⟧⟦U+FE00⟧',
        );
      },
    );

    test('aucun caractère de la table ne survit au rendu', () {
      final StringBuffer b = StringBuffer();
      for (final (int lo, int hi) in kHiddenCodePointRanges) {
        for (final int c in <int>{lo, (lo + hi) ~/ 2, hi}) {
          b.write('x${ch(c)}');
        }
      }
      final RevealedText r = revealInvisibles(b.toString());
      for (final int c in r.text.runes) {
        expect(isHiddenCodePoint(c), isFalse, reason: hex(c));
      }
      expect(r.hiddenCount, greaterThan(60));
    });
  });

  group('revealInvisibles — condensation et bornes (v2, S-06)', () {
    test('37 × U+E0041 → « ⟦U+E0041 ×37⟧ », hiddenCount 37', () {
      final RevealedText r = revealInvisibles('a${rep(ch(0xE0041), 37)}b');
      expect(r.text, 'a⟦U+E0041 ×37⟧b');
      expect(r.hiddenCount, 37);
      expect(r.codePoints, <int>{0xE0041});
    });

    test(
      '5 caractères cachés différents → « ⟦5 invisibles U+E0041…U+E0045⟧ »',
      () {
        final String s = <int>[
          0xE0041,
          0xE0042,
          0xE0043,
          0xE0044,
          0xE0045,
        ].map(ch).join();
        final RevealedText r = revealInvisibles(s);
        expect(r.text, '⟦5 invisibles U+E0041…U+E0045⟧');
        expect(r.hiddenCount, 5);
      },
    );

    test('suites courtes mélangées : jetons un à un, doublons condensés', () {
      expect(
        revealInvisibles('${ch(0x200B)}${ch(0x200D)}').text,
        '⟦U+200B⟧⟦U+200D⟧',
      );
      expect(
        revealInvisibles('${ch(0x200B)}${ch(0x200B)}${ch(0x200D)}').text,
        '⟦U+200B ×2⟧⟦U+200D⟧',
      );
      expect(revealInvisibles('\t\t').text, '⟦TAB ×2⟧');
    });

    test('20 000 × U+E0041 → texte court, aucun plafond atteint', () {
      final RevealedText r = revealInvisibles(rep(ch(0xE0041), 20000));
      expect(r.text, '⟦U+E0041 ×20000⟧');
      expect(r.hiddenCount, 20000);
      expect(r.truncated, isFalse);
    });

    test(
      'alternance « a » U+200B sur 20 000 points de code → coupé, mention',
      () {
        final RevealedText r = revealInvisibles(rep('a${ch(0x200B)}', 10000));
        expect(r.truncated, isTrue);
        const String mention = '\n… 8889 caractère(s) non affiché(s)';
        expect(r.text.endsWith(mention), isTrue);
        final String shown = r.text.substring(
          0,
          r.text.length - mention.length,
        );
        expect(shown.length, lessThanOrEqualTo(kRevealDisplayMax));
        // Le texte ENTIER est compté, même la partie non affichée.
        expect(r.hiddenCount, 10000);
      },
    );

    test('coupure jamais dans un jeton ni une paire', () {
      expect(
        revealInvisibles('abcdef', maxUnits: 3).text,
        'abc\n… 3 caractère(s) non affiché(s)',
      );
      expect(
        revealInvisibles('a${ch(0x202E)}b', maxUnits: 5).text,
        'a\n… 2 caractère(s) non affiché(s)',
      );
      final String smile = ch(0x1F600);
      expect(
        revealInvisibles('$smile$smile', maxUnits: 3).text,
        '$smile\n… 1 caractère(s) non affiché(s)',
      );
    });

    test(
      '60 diacritiques U+0301 sur une lettre → 2 gardés + « ⟦+58 diacritiques⟧ »',
      () {
        final String acute = ch(0x0301);
        final RevealedText r = revealInvisibles('e${rep(acute, 60)}x');
        expect(r.text, 'e$acute$acute⟦+58 diacritiques⟧x');
        expect(r.hiddenCount, 0);
        // Un ou deux diacritiques ordinaires ne sont pas touchés.
        expect(revealInvisibles('e$acute$acute').text, 'e$acute$acute');
      },
    );
  });

  group('oneLinePreview', () {
    test('texte court inchangé ; saut de ligne → ⏎', () {
      expect(oneLinePreview('abc'), 'abc');
      expect(oneLinePreview('a\nb'), 'a⏎b');
      expect(oneLinePreview('a\r\nb'), 'a⟦CR⟧⏎b');
    });

    test('coupe à 120 points de code + « … »', () {
      expect(oneLinePreview(rep('a', 120)), rep('a', 120));
      expect(oneLinePreview(rep('a', 121)), '${rep('a', 120)}…');
      expect(oneLinePreview(rep('a', 200)), '${rep('a', 120)}…');
      expect(oneLinePreview(rep('a', 100), max: 60), '${rep('a', 60)}…');
    });

    test('ne casse ni une paire ni un jeton', () {
      final String smile = ch(0x1F600);
      final String p = oneLinePreview('${rep('a', 119)}$smile$smile');
      expect(p, '${rep('a', 119)}$smile…');
      expect(p.runes.length, 121);
      expect(
        oneLinePreview('${rep('a', 115)}${ch(0x202E)}b'),
        '${rep('a', 115)}…',
      );
    });

    test(
      '1 000 000 de points de code : seuls les 121 premiers sont révélés',
      () {
        expect(oneLinePreview(rep('a', 1000000)), '${rep('a', 120)}…');
        expect(oneLinePreview(rep(ch(0x200B), 1000000)), '⟦U+200B ×121⟧…');
      },
    );

    test('caractère caché révélé dans l’aperçu', () {
      expect(oneLinePreview('abc${ch(0x202E)}def', max: 60), 'abc⟦U+202E⟧def');
    });
  });

  group('JSON révélé', () {
    test('prettyJsonRevealed révèle un U+202E dans une valeur', () {
      final String s = prettyJsonRevealed(<String, Object?>{
        'k': 'a${ch(0x202E)}b',
        'n': 1,
      });
      expect(s, '{\n  "k": "a⟦U+202E⟧b",\n  "n": 1\n}');
      expect(s.contains(ch(0x202E)), isFalse);
    });

    test('revealedJsonLines : petit JSON → ses lignes', () {
      expect(
        revealedJsonLines(<String, Object?>{'a': 1, 'b': 'x${ch(0x200B)}'}),
        <String>['{', '  "a": 1,', '  "b": "x⟦U+200B⟧"', '}'],
      );
      expect(revealedJsonLines(null), <String>['null']);
    });

    test('revealedJsonLines : plafond de 64 Kio + mention de troncature', () {
      final Map<String, Object?> big = <String, Object?>{
        'demande': rep('x', 300000),
      };
      final List<String> lines = revealedJsonLines(big);
      final int total = utf8.encode(jsonEncode(big)).length;
      expect(
        lines.last,
        "Demande tronquée à l'affichage (${(total + 1023) ~/ 1024} Kio au total).",
      );
      expect(lines.last, "Demande tronquée à l'affichage (293 Kio au total).");
      int bytes = 0;
      for (final String l in lines.sublist(0, lines.length - 1)) {
        bytes += utf8.encode(l).length + 1;
      }
      expect(bytes, lessThanOrEqualTo(kRevealedJsonMaxBytes + 1));
    });
  });

  group('motif de revue', () {
    test('vide : requis → message ; facultatif → valide', () {
      expect(
        validateReviewReason('', required: true),
        'Motif obligatoire pour une levée (1 à 500 caractères).',
      );
      expect(
        validateReviewReason('   ', required: true),
        'Motif obligatoire pour une levée (1 à 500 caractères).',
      );
      expect(validateReviewReason('', required: false), isNull);
    });

    test('500 points de code dont 100 émojis (600 unités UTF-16) → valide', () {
      final String s = '${rep('a', 400)}${rep(ch(0x1F600), 100)}';
      expect(s.length, 600);
      expect(reasonCodePoints(s), 500);
      expect(validateReviewReason(s, required: true), isNull);
    });

    test('501 points de code → « Motif trop long : 501/500 caractères. »', () {
      expect(
        validateReviewReason(rep('a', 501), required: false),
        'Motif trop long : 501/500 caractères.',
      );
    });

    test('espaces autour ignorés', () {
      expect(
        validateReviewReason('  ${rep('a', 500)}  ', required: true),
        isNull,
      );
      expect(normalizeReviewReason('  motif  '), 'motif');
      expect(normalizeReviewReason('   '), isNull);
      expect(reasonCodePoints('  ab  '), 2);
    });

    test('U+0000 ou demi-paire → caractère interdit', () {
      const String msg =
          'Motif invalide : caractère interdit (U+0000 ou demi-paire).';
      expect(validateReviewReason('a${ch(0)}b', required: false), msg);
      expect(validateReviewReason('a${ch(0xD800)}b', required: false), msg);
      expect(validateReviewReason('a${ch(0xDC00)}', required: true), msg);
      // Demi-paire en bord de texte : contrôlée AVANT la coupe.
      expect(validateReviewReason('${ch(0xD83D)} ', required: false), msg);
    });

    test('hasUnstorableChars', () {
      expect(hasUnstorableChars('abc ${ch(0x1F600)}'), isFalse);
      expect(hasUnstorableChars(''), isFalse);
      expect(hasUnstorableChars(ch(0)), isTrue);
      expect(hasUnstorableChars('a${ch(0xD83D)}'), isTrue);
      expect(hasUnstorableChars('${ch(0xDE00)}${ch(0xD83D)}'), isTrue);
    });
  });

  group('empreintes autorisées', () {
    final String a = rep('a', 64);
    final String b = rep('b', 64);

    test('normalizeRulesSha', () {
      expect(normalizeRulesSha(rep('A', 64)), a);
      expect(normalizeRulesSha('  $a  '), a);
      expect(normalizeRulesSha(rep('a', 63)), isNull);
      expect(normalizeRulesSha(rep('a', 65)), isNull);
      expect(normalizeRulesSha('${rep('a', 63)}g'), isNull);
      expect(kSha256Re.hasMatch(a), isTrue);
    });

    test('addRulesSha : invalide, doublon, tri', () {
      expect(
        addRulesSha(<String>[], 'xyz').error,
        'Empreinte invalide : 64 caractères hexadécimaux attendus.',
      );
      expect(
        addRulesSha(<String>[a], rep('A', 64)).error,
        'Empreinte déjà présente.',
      );
      final ({List<String>? list, String? error}) r = addRulesSha(<String>[
        b,
      ], a);
      expect(r.error, isNull);
      expect(r.list, <String>[a, b]);
    });

    test('addRulesSha : la 51e est refusée', () {
      final List<String> fifty = <String>[
        for (int i = 0; i < 50; i++) i.toRadixString(16).padLeft(64, '0'),
      ];
      expect(addRulesSha(fifty, rep('f', 64)).error, '50 empreintes au plus.');
      expect(addRulesSha(fifty.sublist(0, 49), rep('f', 64)).list!.length, 50);
    });
  });

  group('jours de purge', () {
    test('30 à 3650 acceptés', () {
      for (final String s in <String>['30', '180', ' 365 ', '3650']) {
        expect(validatePurgeDays(s), isNull, reason: s);
      }
      expect(kPurgeDaysDefault, 180);
    });

    test('hors bornes ou non entier → message', () {
      for (final String s in <String>[
        '',
        '29',
        '3651',
        'abc',
        '12.5',
        '-40',
        '1e3',
      ]) {
        expect(
          validatePurgeDays(s),
          'Nombre de jours invalide : entier de 30 à 3650.',
          reason: s,
        );
      }
    });
  });

  group('table figée', () {
    test('intervalles triés, disjoints, sans les espaces visibles tolérés', () {
      int prev = -1;
      for (final (int lo, int hi) in kHiddenCodePointRanges) {
        expect(lo, greaterThan(prev));
        expect(hi, greaterThanOrEqualTo(lo));
        prev = hi;
      }
      for (final int c in <int>[
        0x0A,
        0x20,
        0xA0,
        0x1680,
        0x2000,
        0x2005,
        0x200A,
        0x202F,
        0x205F,
        0x3000,
      ]) {
        expect(isHiddenCodePoint(c), isFalse, reason: hex(c));
      }
    });
  });
}
