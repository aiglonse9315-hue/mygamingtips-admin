// P5 (lot L6) — sections du menu Sentinelle : « 99% sûr », « Attente 2ème
// passe », « À vérifier » (`lib/domain/sentinelle_sections.dart`), lecture
// de `revue_p5` et copie de la détection YouTube du cœur
// (`lib/domain/video_platform.dart`).
//
// La table de cas (langues × confiances × plateformes × `revue_p5`) est la
// JUMELLE de celle du banc P4 (`tools/vision2_bench/p4/test/unites_test.dart`,
// groupe « section du panneau (L6) ») : toute règle changée ici se change
// là-bas.

import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/models/suggestion.dart';
import 'package:mgt_admin/domain/models/suggestion_author.dart';
import 'package:mgt_admin/domain/sentinelle_sections.dart';
import 'package:mgt_admin/domain/video_platform.dart';

/// Id YouTube / RUTUBE / bilibili neutres (ceux des tests du cœur).
const String yt = 'AAAAAAAAAAA';
const String victime = 'BBBBBBBBBBB';
const String hex = '0123456789abcdef0123456789abcdef';
const String bv = 'BV1xx411c7mD';

/// Une URL par plateforme de la table.
const Map<String, String> kUrls = {
  'youtube': 'https://www.youtube.com/watch?v=$yt',
  'rutube': 'https://rutube.ru/video/$hex/',
  'bilibili': 'https://www.bilibili.com/video/$bv',
  'web': 'https://www.jeuxvideo.com/news/123.htm',
};

/// `revue_p5` de la table : absente, en file (`a_faire`), état de fin avec
/// motif.
const Map<String, Map<String, Object?>?> kRevues = {
  'absente': null,
  'a_faire': {
    'etat': 'a_faire',
    'version': 'p5-1',
    'at': '2026-10-12T08:00:00.000Z',
    'source': 'whisper',
    'avant': {'verdict': 'recommended', 'confiance': 0.9},
  },
  'fin': {
    'etat': 'analyse',
    'version': 'p5-1',
    'at': '2026-10-12T08:00:00.000Z',
    'source': 'whisper',
    'motif': 'avis_ia',
    'avant': {'verdict': 'recommended', 'confiance': 0.9},
  },
};

int _seq = 0;

Suggestion sug({
  required String url,
  String verdict = 'recommended',
  num confidence = 0.9,
  String? lang,
  Map<String, Object?>? revue,
  bool needsGameCreation = false,
  bool gameUnverified = false,
  bool noAi = false,
}) {
  _seq++;
  return Suggestion(
    id: 'id-$_seq',
    url: url,
    status: SuggestionStatus.pending,
    sharedAt: DateTime.utc(2026, 10, 12),
    author: const SuggestionAuthor(id: '', displayName: 'Vision'),
    source: Suggestion.sourceVision,
    aiRecommendation: noAi
        ? null
        : AiRecommendation.fromJson(<String, dynamic>{
            'verdict': verdict,
            'confidence': confidence,
            'reason': 'neutre',
            'youtube_language': ?lang,
            'revue_p5': ?revue,
            if (needsGameCreation) 'needs_game_creation': true,
            if (gameUnverified) 'game_unverified': true,
          }),
  );
}

/// Section ATTENDUE (règle du §2.13 de la conception P5, écrite à part du
/// code testé).
SentinelleSection attendue(String plateforme, double c, String revue) {
  final bool youtube = plateforme == 'youtube';
  if (youtube && revue == 'a_faire') {
    return SentinelleSection.awaitingSecondPass;
  }
  if (c > 0.95) return SentinelleSection.sure;
  return youtube
      ? SentinelleSection.awaitingSecondPass
      : SentinelleSection.toVerify;
}

void main() {
  group('table de cas (langues × confiances × plateformes × revue_p5)', () {
    test('chaque recommandé tombe dans la section attendue', () {
      for (final lang in ['FR', 'EN', 'JA', 'RU', null]) {
        for (final c in [0.90, 0.95, 0.97, 1.0]) {
          for (final p in kUrls.keys) {
            for (final r in kRevues.keys) {
              final s = sug(
                url: kUrls[p]!,
                confidence: c,
                lang: lang,
                revue: kRevues[r],
              );
              expect(
                sentinelleSectionOf(s),
                attendue(p, c, r),
                reason: '$lang · $c · $p · revue $r',
              );
            }
          }
        }
      }
    });

    test('la langue ne décide plus : 0,90 FR = 0,90 JA (fin du seuil '
        '0,90 FR / EN)', () {
      for (final lang in ['FR', 'EN', 'JA', null]) {
        expect(
          sentinelleSectionOf(sug(url: kUrls['youtube']!, lang: lang)),
          SentinelleSection.awaitingSecondPass,
          reason: '$lang',
        );
        expect(
          sentinelleSectionOf(
            sug(url: kUrls['web']!, confidence: 0.95, lang: lang),
          ),
          SentinelleSection.toVerify,
          reason: '$lang',
        );
      }
    });

    test('« à vérifier » et rejets : toujours « À vérifier » (hors file '
        'de la 2e passe)', () {
      for (final verdict in ['caution', 'reject']) {
        for (final c in [0.0, 0.5, 0.95, 1.0]) {
          for (final p in kUrls.keys) {
            expect(
              sentinelleSectionOf(
                sug(url: kUrls[p]!, verdict: verdict, confidence: c),
              ),
              SentinelleSection.toVerify,
              reason: '$verdict $c $p',
            );
          }
        }
      }
    });

    test('issue de la 2e passe : 0,97 → « 99% sûr », « à vérifier » 0 % → '
        '« À vérifier »', () {
      final confirme = sug(
        url: kUrls['youtube']!,
        confidence: 0.97,
        revue: const {'etat': 'analyse', 'motif': 'confirme'},
      );
      final aVerifier = sug(
        url: kUrls['youtube']!,
        verdict: 'caution',
        confidence: 0.0,
        revue: const {'etat': 'sans_parole', 'motif': 'sans_parole'},
      );
      expect(sentinelleSectionOf(confirme), SentinelleSection.sure);
      expect(sentinelleSectionOf(aVerifier), SentinelleSection.toVerify);
    });

    test('file de la 2e passe (P10) : a_faire / audio / transcrit → '
        '« Attente » quel que soit le verdict ; états de fin → le verdict '
        'décide', () {
      for (final etat in ['a_faire', 'audio', 'transcrit']) {
        for (final verdict in ['recommended', 'caution', 'reject']) {
          expect(
            sentinelleSectionOf(
              sug(
                url: kUrls['youtube']!,
                verdict: verdict,
                confidence: 1.0,
                revue: {'etat': etat},
              ),
            ),
            SentinelleSection.awaitingSecondPass,
            reason: '$etat $verdict',
          );
        }
      }
      for (final etat in [
        'analyse',
        'audio_indisponible',
        'sans_parole',
        'sans_parole_court',
        'texte_inutilisable',
        'trop_long',
        'echec_outil',
        'retire',
        'inconnu',
      ]) {
        expect(
          sentinelleSectionOf(
            sug(
              url: kUrls['youtube']!,
              verdict: 'caution',
              confidence: 0.0,
              revue: {'etat': etat},
            ),
          ),
          SentinelleSection.toVerify,
          reason: etat,
        );
      }
      // Hors YouTube, une file n'a pas de sens : le verdict décide.
      expect(
        sentinelleSectionOf(
          sug(url: kUrls['rutube']!, revue: const {'etat': 'a_faire'}),
        ),
        SentinelleSection.toVerify,
      );
    });
  });

  group('bornes et exclusions (candidats de la 2e passe)', () {
    test('0,95 exactement et 0,95 + 1e-10 → Attente ; 0,951 → 99% sûr', () {
      final u = kUrls['youtube']!;
      expect(
        sentinelleSectionOf(sug(url: u, confidence: 0.95)),
        SentinelleSection.awaitingSecondPass,
      );
      expect(
        sentinelleSectionOf(sug(url: u, confidence: 0.95 + 1e-10)),
        SentinelleSection.awaitingSecondPass,
      );
      expect(
        sentinelleSectionOf(sug(url: u, confidence: 0.951)),
        SentinelleSection.sure,
      );
      expect(
        sentinelleSectionOf(sug(url: u, confidence: 1)),
        SentinelleSection.sure,
      );
      expect(
        sentinelleSectionOf(sug(url: u, confidence: 0.1)),
        SentinelleSection.awaitingSecondPass,
      );
    });

    test('jeu à créer / jeu non vérifié ≤ 0,95 → « À vérifier » ; > 0,95 '
        '→ « 99% sûr »', () {
      final u = kUrls['youtube']!;
      expect(
        sentinelleSectionOf(sug(url: u, needsGameCreation: true)),
        SentinelleSection.toVerify,
      );
      expect(
        sentinelleSectionOf(sug(url: u, gameUnverified: true)),
        SentinelleSection.toVerify,
      );
      expect(
        sentinelleSectionOf(
          sug(url: u, confidence: 1.0, needsGameCreation: true),
        ),
        SentinelleSection.sure,
      );
    });

    test('YouTube sans id vidéo, Twitch, lien court bilibili, page qui '
        'CITE YouTube → « À vérifier »', () {
      for (final url in [
        'https://www.youtube.com/@chaine',
        'https://www.youtube.com/playlist?list=PL123',
        'https://www.youtube.com/results?search_query=mot',
        'https://www.twitch.tv/videos/123456',
        'https://b23.tv/AbCdEf',
        'https://tiers.example/p?v=$victime&from=youtube.com',
        'https://evilyoutube.com/watch?v=$victime',
        'https://youtube.com.tiers.example/watch?v=$victime',
        '',
      ]) {
        expect(
          sentinelleSectionOf(sug(url: url)),
          SentinelleSection.toVerify,
          reason: url,
        );
      }
    });

    test('formes de vidéo YouTube → « Attente »', () {
      for (final url in [
        'https://youtu.be/$yt?si=partage',
        'https://www.youtube.com/shorts/$yt',
        'https://m.youtube.com/watch?feature=share&v=$yt',
        'https://www.youtube-nocookie.com/embed/$yt',
        'www.youtube.com/watch?v=$yt',
      ]) {
        expect(
          sentinelleSectionOf(sug(url: url)),
          SentinelleSection.awaitingSecondPass,
          reason: url,
        );
      }
    });

    test('sans recommandation → « À vérifier »', () {
      expect(
        sentinelleSectionOf(sug(url: kUrls['youtube']!, noAi: true)),
        SentinelleSection.toVerify,
      );
    });
  });

  group('partition et ordre', () {
    test('chaque contenu dans UNE section, ordre de la liste gardé', () {
      final List<Suggestion> items = <Suggestion>[
        for (final c in [0.90, 0.95, 0.97, 1.0])
          for (final p in kUrls.keys)
            for (final r in kRevues.keys)
              for (final verdict in ['recommended', 'caution', 'reject'])
                sug(
                  url: kUrls[p]!,
                  verdict: verdict,
                  confidence: c,
                  revue: kRevues[r],
                ),
        sug(url: kUrls['youtube']!, noAi: true),
      ];
      final sections = SentinelleSections.of(items);
      final all = <Suggestion>[
        ...sections.sure,
        ...sections.awaitingSecondPass,
        ...sections.toVerify,
      ];
      expect(all.length, items.length);
      expect(all.map((s) => s.id).toSet().length, items.length);
      expect(all.toSet(), items.toSet());
      for (final s in sections.sure) {
        expect(sentinelleSectionOf(s), SentinelleSection.sure);
      }
      for (final s in sections.awaitingSecondPass) {
        expect(sentinelleSectionOf(s), SentinelleSection.awaitingSecondPass);
      }
      for (final s in sections.toVerify) {
        expect(sentinelleSectionOf(s), SentinelleSection.toVerify);
      }
      // Ordre de la liste gardé dans chaque section (aucune astuce courte).
      List<int> rangs(List<Suggestion> l) => [for (final s in l) items.indexOf(s)];
      for (final l in [
        sections.sure,
        sections.awaitingSecondPass,
        sections.toVerify,
      ]) {
        final r = rangs(l);
        expect(r, List<int>.of(r)..sort());
      }
    });

    test('« À vérifier » : astuces courtes d\'abord, partition STABLE', () {
      Suggestion astuce() => sug(
        url: kUrls['youtube']!,
        verdict: 'caution',
        confidence: 0.0,
        revue: const {'etat': 'sans_parole_court', 'motif': 'astuce_courte'},
      );
      Suggestion autre() =>
          sug(url: kUrls['web']!, verdict: 'caution', confidence: 0.5);
      final a = autre(), b = astuce(), c = autre(), d = astuce(), e = autre();
      final sections = SentinelleSections.of(<Suggestion>[a, b, c, d, e]);
      expect(sections.toVerify, <Suggestion>[b, d, a, c, e]);
      // Un motif d'une autre issue n'est pas remonté.
      final f = sug(
        url: kUrls['youtube']!,
        verdict: 'caution',
        confidence: 0.0,
        revue: const {'etat': 'sans_parole', 'motif': 'sans_parole'},
      );
      expect(SentinelleSections.of(<Suggestion>[a, f, b]).toVerify, [b, a, f]);
    });

    test('listes non modifiables', () {
      final sections = SentinelleSections.of(<Suggestion>[
        sug(url: kUrls['youtube']!),
      ]);
      expect(
        () => sections.awaitingSecondPass.add(sug(url: kUrls['web']!)),
        throwsUnsupportedError,
      );
    });
  });

  group('lecture de revue_p5 et game_unverified', () {
    test('lecture complète et aller-retour toJson / fromJson', () {
      final ai = AiRecommendation.fromJson(<String, dynamic>{
        'verdict': 'caution',
        'confidence': 0,
        'reason': 'Analyse vidéo : astuce courte',
        'game_unverified': true,
        'revue_p5': {
          'etat': 'sans_parole_court',
          'version': 'p5-1',
          'at': '2026-10-12T08:00:00.000Z',
          'source': 'whisper',
          'motif': 'astuce_courte',
          'langue_origine': 'FR',
          'langues_disponibles': ['FR', 'EN'],
          'avant': {'verdict': 'recommended', 'confiance': 0.95},
        },
      });
      final r = ai.revueP5!;
      expect(r.etat, 'sans_parole_court');
      expect(r.motif, 'astuce_courte');
      expect(r.isShortTip, isTrue);
      expect(r.isPending, isFalse);
      expect(r.version, 'p5-1');
      expect(r.source, 'whisper');
      expect(r.langueOrigine, 'FR');
      expect(r.languesDisponibles, ['FR', 'EN']);
      expect(r.avantVerdict, 'recommended');
      expect(r.avantConfiance, 0.95);
      expect(ai.gameUnverified, isTrue);
      final back = AiRecommendation.fromJson(ai.toJson());
      expect(back.toJson(), ai.toJson());
      expect(back.revueP5!.isShortTip, isTrue);
      expect(back.gameUnverified, isTrue);
    });

    test('lecture TOLÉRANTE : mauvais types ignorés, jamais d\'exception', () {
      for (final raw in <Object?>['a_faire', 3, <Object?>[], null]) {
        expect(
          AiRecommendation.fromJson(<String, dynamic>{
            'verdict': 'recommended',
            'confidence': 0.9,
            'revue_p5': raw,
          }).revueP5,
          isNull,
          reason: '$raw',
        );
      }
      final r = AiRevueP5.tryParse(<String, Object?>{
        'etat': 7,
        'motif': '',
        'langues_disponibles': ['FR', 3, null, 'EN'],
        'avant': 'x',
      })!;
      expect(r.etat, isNull);
      expect(r.motif, isNull);
      expect(r.isPending, isFalse);
      expect(r.languesDisponibles, ['FR', 'EN']);
      expect(r.avantVerdict, isNull);
      expect(r.avantConfiance, isNull);
      expect(r.toJson(), {'langues_disponibles': ['FR', 'EN']});
      // `game_unverified` : seul `true` compte.
      for (final v in <Object?>['true', 1, false, null]) {
        expect(
          AiRecommendation.fromJson(<String, dynamic>{
            'verdict': 'recommended',
            'confidence': 0.9,
            'game_unverified': v,
          }).gameUnverified,
          isFalse,
          reason: '$v',
        );
      }
    });
  });

  group('copie de la détection YouTube du cœur (platform_host.dart)', () {
    test('table d\'URL du cœur (test/platform_host_test.dart) : mêmes ids', () {
      final cas = <String, String?>{
        'https://www.youtube.com/watch?v=$yt': yt,
        'https://youtube.com/watch?v=$yt&t=42s': yt,
        'https://m.youtube.com/watch?feature=share&v=$yt': yt,
        'https://music.youtube.com/watch?v=$yt': yt,
        'https://youtu.be/$yt?si=partage': yt,
        'https://www.youtube.com/shorts/$yt': yt,
        'https://www.youtube.com/embed/$yt?rel=0': yt,
        'https://www.youtube-nocookie.com/embed/$yt': yt,
        'https://youtube-nocookie.com/embed/$yt': yt,
        'https://www.youtube.com/@chaine': null,
        'https://www.youtube.com/results?search_query=mot': null,
        'HTTPS://WWW.YouTube.COM/watch?v=$yt': yt,
        'https://www.youtube.com./watch?v=$yt': yt,
        'www.youtube.com/watch?v=$yt': yt,
        '  https://youtu.be/$yt  ': yt,
        // Pages web, URL tierces piégées, schémas hors http(s).
        'https://example.com/guide': null,
        'pas une url': null,
        '': null,
        'https://tiers.example/p?v=$victime&from=youtube.com&q=mot+neutre':
            null,
        'https://youtube.com.tiers.example/watch?v=$victime': null,
        'https://tiers.example/youtu.be/$victime': null,
        'https://tiers.example/embed/$victime': null,
        'https://youtube.com@tiers.example/watch?v=$victime': null,
        'https://evilyoutube.com/watch?v=$victime': null,
        'ftp://www.youtube.com/watch?v=$yt': null,
        'file://www.youtube.com/watch?v=$yt': null,
        'https://rutube.ru/video/$hex/': null,
        'https://www.bilibili.com/video/$bv': null,
      };
      cas.forEach((url, id) {
        expect(youTubeVideoIdOf(url), id, reason: url);
        expect(isYouTubeVideoUrl(url), id != null, reason: url);
      });
    });
  });
}
