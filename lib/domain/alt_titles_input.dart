/// « Autres noms » d'un jeu dans une langue (§119 — colonne
/// `game_translations.alt_titles`, migration 0080) : variantes employées par
/// les vidéos (« 发薪日3 » à côté du titre « 收获日3 » pour Payday 3).
/// Ils servent UNIQUEMENT à reconnaître le jeu (tri Vision, Sentinelle) :
/// jamais affichés dans l'app, jamais utilisés pour les recherches.
library;

/// Nombre maximum d'autres noms par langue (même borne que l'EF).
const int kAltTitlesMaxPerLang = 20;

/// Longueur maximale d'un autre nom (même borne que l'EF).
const int kAltTitleMaxLength = 200;

/// Saisie du panneau → liste propre : un nom par ligne (ou séparés par
/// « ; »), espaces rognés ; vides, doublons (casse ignorée), nom identique
/// au [title] de la langue et noms trop longs écartés ; au plus
/// [kAltTitlesMaxPerLang] noms.
List<String> parseAltTitlesInput(String raw, {String title = ''}) {
  final seen = <String>{title.trim().toLowerCase()};
  final names = <String>[];
  for (final part in raw.split(RegExp(r'[\n;；]'))) {
    final name = part.trim();
    if (name.isEmpty || name.length > kAltTitleMaxLength) continue;
    if (!seen.add(name.toLowerCase())) continue;
    names.add(name);
    if (names.length == kAltTitlesMaxPerLang) break;
  }
  return names;
}
