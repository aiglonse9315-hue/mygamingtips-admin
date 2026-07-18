import 'dart:ui';

/// Langue supportée par MyGamingTips (contenu des vidéos, pas l'interface).
///
/// Source canonique des 12 langues du pack. Dupliquée à l'identique dans :
/// - `admin/lib/core/i18n/app_languages.dart` (panneau admin web)
/// - `tools/vision/lib/app_languages.dart` (app desktop Vision/Sentinelle/Check)
///
/// La langue est stockée en base sous forme de code majuscule 2 lettres
/// (`contents.video_language`, type TEXT sans contrainte CHECK côté BD —
/// cf. migration `0013_video_language.sql`).
class AppLanguage {
  const AppLanguage({
    required this.code,
    required this.label,
    required this.flag,
    required this.youtubeQuery,
    required this.color,
  });

  /// Code majuscule canonique (`'FR'`, `'EN'`, `'JA'`...).
  /// C'est la valeur stockée en base et comparée dans les filtres.
  final String code;

  /// Code minuscule pour l'API YouTube (`relevanceLanguage` accepte
  /// uniquement les codes BCP-47 à 2 lettres minuscules).
  String get codeLower => code.toLowerCase();

  /// Libellé natif affiché dans l'UI ('Français', 'English', '日本語'...).
  final String label;

  /// Emoji drapeau pour les badges et listes.
  final String flag;

  /// Mots-clés gaming combinés en UNE requête YouTube (opérateur OR).
  /// Équivalents natifs de « tips/guide/tutorial/walkthrough/best/secret ».
  final String youtubeQuery;

  /// Couleur du badge (stable par langue pour la reconnaissance visuelle).
  final Color color;

  @override
  String toString() => '$flag $code';
}

/// Les 12 langues officiellement supportées par le pack complet.
///
/// Ordre important : reprend l'ordre des paires [kLanguagePairs] pour
/// faciliter le rendu UI (FR+EN d'abord, puis Europe, Asie, autres).
const List<AppLanguage> kSupportedLanguages = [
  AppLanguage(
    code: 'FR',
    label: 'Français',
    flag: '🇫🇷',
    youtubeQuery:
        'astuce OR guide OR soluce OR solution OR tutoriel OR comment OR meilleur OR secret',
    color: Color(0xFF007FFF), // bleu France
  ),
  AppLanguage(
    code: 'EN',
    label: 'English',
    flag: '🇬🇧',
    youtubeQuery:
        'tips OR guide OR tutorial OR walkthrough OR best OR unlock OR secret OR trick',
    color: Color(0xFFD32F2F), // rouge UK
  ),
  AppLanguage(
    code: 'ES',
    label: 'Español',
    flag: '🇪🇸',
    youtubeQuery:
        'trucos OR guía OR tutorial OR recorrido OR mejor OR secreto OR consejo OR solución',
    color: Color(0xFFC60B1E), // rouge Espagne
  ),
  AppLanguage(
    code: 'PT',
    label: 'Português',
    flag: '🇵🇹',
    youtubeQuery:
        'dicas OR guia OR tutorial OR прохождение OR melhor OR segredo OR truque OR solução',
    color: Color(0xFF006600), // vert Portugal
  ),
  AppLanguage(
    code: 'DE',
    label: 'Deutsch',
    flag: '🇩🇪',
    youtubeQuery:
        'tipps OR guide OR anleitung OR walkthrough OR bester OR geheimnis OR trick OR lösung',
    // Gris très clair (et non noir pur) : le badge LanguageBadge rend la
    // couleur du texte sur un fond `color.withValues(alpha: 0.18)`. Avec du
    // blanc pur, le texte blanc sur fond blanc-transparent serait illisible ;
    // avec du noir, le texte noir serait invisible sur les miniatures YouTube
    // sombres (le badge est posé sur un overlay noir semi-transparent). Ce
    // gris clair reste lisible dans les deux thèmes (light/dark) et sur les
    // deux fonds (carte claire / overlay sombre des thumbnails).
    color: Color(0xFFE0E0E0), // gris très clair Allemagne
  ),
  AppLanguage(
    code: 'IT',
    label: 'Italiano',
    flag: '🇮🇹',
    youtubeQuery:
        'trucchi OR guida OR tutorial OR soluzione OR migliore OR segreto OR consiglio OR walk',
    color: Color(0xFF008C45), // vert Italie
  ),
  AppLanguage(
    code: 'RU',
    label: 'Русский',
    flag: '🇷🇺',
    youtubeQuery:
        'советы OR руководство OR прохождение OR урок OR лучший OR секрет OR подсказка OR решение',
    color: Color(0xFF0039A6), // bleu Russie
  ),
  AppLanguage(
    code: 'JA',
    label: '日本語',
    flag: '🇯🇵',
    youtubeQuery:
        '攻略 OR ガイド OR チュートリアル OR 最強 OR 裏技 OR 秘密 OR 解説 OR ベスト',
    color: Color(0xFFBC002D), // rouge Japon
  ),
  AppLanguage(
    code: 'ZH',
    label: '中文',
    flag: '🇨🇳',
    youtubeQuery:
        '攻略 OR 指南 OR 教程 OR 最佳 OR 秘密 OR 技巧 OR 解说 OR 通关',
    color: Color(0xFFDE2910), // rouge Chine
  ),
  AppLanguage(
    code: 'KO',
    label: '한국어',
    flag: '🇰🇷',
    youtubeQuery:
        '공략 OR 가이드 OR 튜토리얼 OR 최고 OR 비밀 OR 팁 OR 해설 OR 클리어',
    color: Color(0xFF003478), // bleu Corée
  ),
  AppLanguage(
    code: 'AR',
    label: 'العربية',
    flag: '🇸🇦',
    youtubeQuery:
        'نصائح OR دليل OR شرح OR أفضل OR سر OR حيلة OR حل OR جولة',
    color: Color(0xFF006C35), // vert Arabie
  ),
  AppLanguage(
    code: 'HI',
    label: 'हिन्दी',
    flag: '🇮🇳',
    youtubeQuery:
        'टिप्स OR गाइड OR ट्यूटोरियल OR सबसे अच्छा OR रहस्य OR ट्रिक OR समाधान OR वॉकथ्रू',
    color: Color(0xFFFF9933), // orange Inde
  ),
];

/// Les 6 paires géographiques pour le bouton « Run selected » du panneau
/// Vision. Chaque paire est lancée indépendamment pour répartir la charge
/// sur le quota YouTube (10 000 unités/jour) et ne pas saturer l'API.
const List<List<String>> kLanguagePairs = [
  ['FR', 'EN'], // paire native (inchangée historiquement)
  ['ES', 'PT'], // latin
  ['DE', 'IT'], // Europe centrale
  ['RU', 'JA'],
  ['ZH', 'KO'], // Asie de l'Est
  ['AR', 'HI'],
];

/// Langues « natives » (FR/EN) qui gardent le seuil Sentinelle permissif (0.9).
/// Les 10 autres exigent un seuil plus strict (0.95).
const Set<String> kNativeLanguageCodes = {'FR', 'EN'};

/// Map code majuscule → [AppLanguage], pour lookup performant.
final Map<String, AppLanguage> _languageByCode = {
  for (final lang in kSupportedLanguages) lang.code: lang,
};

/// Recherche une langue par code (case-insensitive).
///
/// Accepte `'FR'`, `'fr'`, `'Fr'`, `'french'` (préfixe)...
/// Retourne `null` si le code ne correspond à aucune langue supportée.
AppLanguage? findLanguage(String? code) {
  if (code == null) return null;
  final upper = code.toUpperCase().trim();
  // Match exact d'abord.
  final exact = _languageByCode[upper];
  if (exact != null) return exact;
  // Préfixe (ex: 'fr-FR', 'french' → 'FR').
  for (final lang in kSupportedLanguages) {
    if (upper.startsWith(lang.code)) return lang;
  }
  return null;
}

/// Code canonique majuscule si reconnu, sinon `null`.
/// Utilitaire pour les bots (Check, Sentinelle) qui reçoivent des codes
/// YouTube potentiellement variés ('fr', 'fr-FR', 'French'...).
String? normalizeLanguageCode(String? code) => findLanguage(code)?.code;

/// Vrai si le code correspond à une langue supportée.
bool isSupportedLanguage(String? code) => findLanguage(code) != null;

/// Détecte la langue de l'appareil et la mappe sur une langue du pack 12.
///
/// Utilise [PlatformDispatcher.instance.locale] (BCP-47 de l'OS Android).
/// Exemples :
///   - `fr_FR` → `'FR'`
///   - `ja_JP` → `'JA'`
///   - `pt_BR` → `'PT'`
///   - `ko_KR` → `'KO'`
///
/// **Fallback** : si la locale device ne correspond à aucune langue du pack
/// (ex : néerlandais `nl_NL`, suédois `sv_SE`), retourne `'EN'` par défaut,
/// conformément à la demande utilisateur.
///
/// À appeler au démarrage de l'app pour pré-remplir le filtre de langue du
/// catalogue avec la langue native de l'utilisateur.
String detectDeviceLanguageCode() {
  final locale = PlatformDispatcher.instance.locale;
  final code = findLanguage(locale.languageCode) ??
      findLanguage(locale.countryCode) ??
      findLanguage(locale.toString());
  return code?.code ?? 'EN';
}

/// Retourne l'ensemble de langues par défaut à activer au démarrage.
///
/// Combine la langue device (détectée) avec l'anglais comme socle commun,
/// conformément à la demande utilisateur :
///   - Si le device est en FR → `{'FR', 'EN'}` (pas de doublon).
///   - Si le device est en JA → `{'JA', 'EN'}`.
///   - Si le device est en néerlandais (non supporté) → `{'EN'}` (fallback).
Set<String> defaultActiveLanguagesForDevice() {
  final device = detectDeviceLanguageCode();
  return device == 'EN' ? const {'EN'} : {device, 'EN'};
}
