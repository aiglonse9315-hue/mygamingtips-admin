/// P5 (lot L6) — sections du menu Sentinelle du panneau : « 99% sûr —
/// Implémentable en 1 clic », « Attente 2ème passe » et « À vérifier ».
///
/// Règle décidée le 10/10 (Q7, conception P5 §2.13), dans le panneau SEUL
/// (ni Edge Function, ni migration) :
/// - « 99% sûr » : recommandé de confiance > 0,95, TOUTES plateformes et
///   langues (1,0 de la 1re passe, ou 0,97 confirmé par la 2e passe) ;
/// - « Attente 2ème passe » : les CANDIDATS de la 2e passe de Sentinelle
///   (`p5CandidateClassOf` du cœur) — vidéo YouTube, recommandé ≤ 0,95,
///   toutes langues, ni « jeu à créer » ni « jeu non vérifié » ; et (P10)
///   toute vidéo YouTube dont `revue_p5.etat` est un état de la FILE (P10
///   devra écrire un état de FIN pour chaque contenu retiré de la file,
///   sinon il resterait ici) ;
/// - « À vérifier » : tout le reste (dont les recommandés ≤ 0,95 de RUTUBE,
///   bilibili, Twitch et des pages web : aucune 2e passe ne les relira).
///
/// Chaque contenu est dans UNE seule section (partition). La langue ne
/// décide plus de rien (fin des seuils 0,90 FR / EN et 0,95). Fonctions
/// PURES.
library;

import 'models/suggestion.dart';
import 'video_platform.dart';

/// Section d'un contenu analysé par Sentinelle.
enum SentinelleSection {
  /// « 99% sûr — Implémentable en 1 clic ».
  sure,

  /// « Attente 2ème passe ».
  awaitingSecondPass,

  /// « À vérifier ».
  toVerify,
}

/// Confiance au-dessus de laquelle un recommandé est « 99% sûr » (STRICT :
/// 0,95 lui-même attend la 2e passe) — `kP5CandidateMaxConfidence` du cœur.
const double kSentinelleSureAbove = 0.95;

/// Tolérance de comparaison (même valeur que le cœur, `s2_p5.dart`).
const double _kEps = 1e-9;

/// Section d'un contenu analysé.
SentinelleSection sentinelleSectionOf(Suggestion s) {
  final AiRecommendation? ai = s.aiRecommendation;
  if (ai == null) return SentinelleSection.toVerify;
  final bool youTubeVideo = isYouTubeVideoUrl(s.url);
  // P10 : un contenu entré dans la file de la 2e passe y reste jusqu'à son
  // issue, quel que soit le verdict écrit par la 1re passe.
  if (youTubeVideo && (ai.revueP5?.isPending ?? false)) {
    return SentinelleSection.awaitingSecondPass;
  }
  if (ai.verdict != AiVerdict.recommended) return SentinelleSection.toVerify;
  final double c = ai.confidence;
  if (c > kSentinelleSureAbove + _kEps) return SentinelleSection.sure;
  if (youTubeVideo && !ai.needsGameCreation && !ai.gameUnverified) {
    return SentinelleSection.awaitingSecondPass;
  }
  return SentinelleSection.toVerify;
}

/// Contenus d'une liste répartis par section, dans l'ordre de la liste ;
/// « À vérifier » montre d'abord les « astuces courtes sans parole » de la
/// 2e passe (partition STABLE : l'ordre du serveur est gardé dans chaque
/// bloc).
class SentinelleSections {
  SentinelleSections._(this.sure, this.awaitingSecondPass, this.toVerify);

  factory SentinelleSections.of(List<Suggestion> items) {
    final List<Suggestion> sure = <Suggestion>[];
    final List<Suggestion> awaiting = <Suggestion>[];
    final List<Suggestion> shortTips = <Suggestion>[];
    final List<Suggestion> others = <Suggestion>[];
    for (final Suggestion s in items) {
      switch (sentinelleSectionOf(s)) {
        case SentinelleSection.sure:
          sure.add(s);
        case SentinelleSection.awaitingSecondPass:
          awaiting.add(s);
        case SentinelleSection.toVerify:
          if (s.aiRecommendation?.revueP5?.isShortTip ?? false) {
            shortTips.add(s);
          } else {
            others.add(s);
          }
      }
    }
    return SentinelleSections._(
      List<Suggestion>.unmodifiable(sure),
      List<Suggestion>.unmodifiable(awaiting),
      List<Suggestion>.unmodifiable(<Suggestion>[...shortTips, ...others]),
    );
  }

  final List<Suggestion> sure;
  final List<Suggestion> awaitingSecondPass;
  final List<Suggestion> toVerify;
}
