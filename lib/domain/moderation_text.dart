// Pur (VM) — texte NON FIABLE et saisies de la modération (P4b-3, lot L3,
// conception §4.3).
//
// a) Rendu visible des caractères invisibles, bidirectionnels et de contrôle
//    d'un texte choisi par un tiers (preuve, URL de page, clés, hôtes, noms,
//    motifs) : chaque caractère caché devient un jeton lisible `⟦U+XXXX⟧`
//    (`⟦TAB⟧`, `⟦CR⟧`), les suites sont condensées, les diacritiques
//    empilés au-delà du 2e sont résumés et l'affichage est borné. Le texte
//    rendu ne contient plus aucun caractère caché de la table : un
//    renversement de sens (U+202E) ou un texte en étiquettes (U+E0041…) ne
//    peut plus tromper le lecteur.
// b) Motif de revue (`moderation/review-decide`) : mêmes règles que le
//    serveur (supabase/functions/admin-catalog/moderation.ts:458-468), en
//    POINTS DE CODE.
// c) Empreintes autorisées (64 hex, 50 au plus).
// d) Jours de purge des preuves (30 à 3650, défaut 180).
//
// La table des caractères cachés est encadrée par `// INVISIBLES-DEBUT` /
// `// INVISIBLES-FIN` : le test de parité deno
// `supabase/tests/parity/panel_invisibles_parity_test.ts` exige qu'elle
// COUVRE la classe interdite du serveur (`c_url_bad_re` de la migration
// 0094) à l'exception des seuls espaces visibles tolérés.
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM
// (`flutter test test/moderation_text_test.dart`).
import 'dart:convert';

import 'package:flutter/foundation.dart';

// ── a) Caractères cachés ─────────────────────────────────────────────────────

/// Intervalles FIGÉS (bornes incluses, points de code, triés, disjoints) des
/// caractères rendus visibles. U+0009 et U+000D ont un jeton nommé
/// (`⟦TAB⟧`, `⟦CR⟧`) ; les autres `⟦U+XXXX⟧`.
///
/// Volontairement ABSENTS (espaces visibles, liste exacte du test de
/// parité) : U+000A, U+0020, U+00A0, U+1680, U+2000-U+200A, U+202F, U+205F,
/// U+3000. Règles contextuelles hors table : U+FE00-U+FE0F (sélecteur
/// d'émoji marqué seulement s'il ne suit pas un caractère de base) et
/// diacritiques combinants au-delà du 2e consécutif.
const List<(int, int)> kHiddenCodePointRanges = <(int, int)>[
  // INVISIBLES-DEBUT
  (0x0000, 0x0008), // contrôles C0
  (0x0009, 0x0009), // tabulation → ⟦TAB⟧
  (0x000B, 0x000C), // contrôles C0 (tabulation verticale, saut de page)
  (0x000D, 0x000D), // retour chariot → ⟦CR⟧
  (0x000E, 0x001F), // contrôles C0
  (0x007F, 0x009F), // DEL et contrôles C1
  (0x00AD, 0x00AD), // trait d'union conditionnel
  (0x034F, 0x034F), // graphème de jonction invisible
  (0x0600, 0x0605), // formats arabes
  (0x061C, 0x061C), // marque de lettre arabe (bidi)
  (0x06DD, 0x06DD), // fin d'ayah
  (0x070F, 0x070F), // abréviation syriaque
  (0x0890, 0x0891), // formats arabes
  (0x08E2, 0x08E2), // désignation de disjonction arabe
  (0x115F, 0x1160), // remplisseurs hangûl
  (0x17B4, 0x17B5), // voyelles khmères invisibles
  (0x180B, 0x180F), // sélecteurs et séparateur mongols
  (0x200B, 0x200F), // largeur nulle, LRM, RLM
  (0x2028, 0x202E), // séparateurs de ligne / paragraphe, LRE à RLO
  (0x2060, 0x206F), // joints, isolats bidi, formats obsolètes
  (0x3164, 0x3164), // remplisseur hangûl
  (0xFEFF, 0xFEFF), // indicateur d'ordre des octets / espace insécable nul
  (0xFFA0, 0xFFA0), // remplisseur hangûl demi-chasse
  (0xFFF9, 0xFFFB), // annotations interlinéaires
  (0x110BD, 0x110BD), // format kaithi
  (0x110CD, 0x110CD), // format kaithi
  (0x13430, 0x1343F), // formats des hiéroglyphes
  (0x1BCA0, 0x1BCA3), // formats sténographiques
  (0x1D173, 0x1D17A), // formats musicaux
  (0xE0000, 0xE007F), // étiquettes (texte caché)
  (0xE0100, 0xE01EF), // sélecteurs de variante supplémentaires
  // INVISIBLES-FIN
];

/// Intervalles des diacritiques combinants surveillés (empilement « zalgo »).
const List<(int, int)> kCombiningMarkRanges = <(int, int)>[
  (0x0300, 0x036F),
  (0x1AB0, 0x1AFF),
  (0x1DC0, 0x1DFF),
  (0x20D0, 0x20FF),
  (0xFE20, 0xFE2F),
];

/// Diacritiques consécutifs gardés tels quels ; les suivants sont résumés.
const int kMaxStackedMarks = 2;

/// Unités UTF-16 affichées au plus pour un texte révélé.
const int kRevealDisplayMax = 50000;

/// Octets (UTF-8) révélés au plus pour la demande du bot.
const int kRevealedJsonMaxBytes = 65536;

bool _inRanges(List<(int, int)> ranges, int c) {
  for (final (int lo, int hi) in ranges) {
    if (c < lo) return false; // intervalles triés
    if (c <= hi) return true;
  }
  return false;
}

/// Vrai si [c] appartient à la table figée des caractères cachés (hors
/// règles contextuelles).
bool isHiddenCodePoint(int c) {
  if (c >= 0x20 && c < 0x7F) return false; // ASCII imprimable : chemin rapide
  if (c >= 0xD800 && c <= 0xDFFF) return true; // moitié de paire isolée
  return _inRanges(kHiddenCodePointRanges, c);
}

/// Vrai si [c] est un diacritique combinant surveillé.
bool isCombiningMark(int c) {
  if (c < 0x0300) return false;
  return _inRanges(kCombiningMarkRanges, c);
}

bool _isVariationSelector(int c) => c >= 0xFE00 && c <= 0xFE0F;

String _hex(int c) => 'U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}';

String _tokenName(int c) {
  if (c == 0x09) return 'TAB';
  if (c == 0x0D) return 'CR';
  return _hex(c);
}

/// Morceau atomique du texte révélé : jamais coupé (un jeton, un caractère
/// ou une paire de substitution). [raw] = points de code BRUTS qu'il
/// représente.
typedef _Emit = bool Function(String text, int raw);

/// Parcourt [runes] et émet les morceaux révélés. L'émetteur rend faux pour
/// arrêter le parcours. Rend le nombre de caractères cachés, leurs points de
/// code et le nombre total de points de code parcourus.
({int hidden, Set<int> codePoints, int total}) _scan(
  Iterable<int> runes,
  _Emit emit,
) {
  final List<int> run = <int>[];
  final Set<int> codePoints = <int>{};
  int hidden = 0;
  int total = 0;
  int stacked = 0; // diacritiques consécutifs
  int extraMarks = 0; // diacritiques au-delà de kMaxStackedMarks, en attente
  bool prevBase = false; // le point de code précédent est un caractère de base
  bool stopped = false;

  void out(String text, int raw) {
    if (!stopped && !emit(text, raw)) stopped = true;
  }

  void flushMarks() {
    if (extraMarks > 0) {
      out('⟦+$extraMarks diacritiques⟧', extraMarks);
      extraMarks = 0;
    }
  }

  void flushRun() {
    if (run.isEmpty) return;
    final bool same = run.every((int c) => c == run.first);
    if (!same && run.length >= 4) {
      out(
        '⟦${run.length} invisibles ${_hex(run.first)}…${_hex(run.last)}⟧',
        run.length,
      );
    } else {
      int i = 0;
      while (i < run.length) {
        int j = i + 1;
        while (j < run.length && run[j] == run[i]) {
          j++;
        }
        final int n = j - i;
        out(
          n >= 2 ? '⟦${_tokenName(run[i])} ×$n⟧' : '⟦${_tokenName(run[i])}⟧',
          n,
        );
        i = j;
      }
    }
    run.clear();
  }

  for (final int c in runes) {
    if (stopped) break;
    total++;
    final bool isHidden =
        isHiddenCodePoint(c) || (_isVariationSelector(c) && !prevBase);
    if (isHidden) {
      flushMarks();
      stacked = 0;
      run.add(c);
      hidden++;
      codePoints.add(c);
      prevBase = false;
      continue;
    }
    flushRun();
    if (isCombiningMark(c)) {
      stacked++;
      if (stacked > kMaxStackedMarks) {
        extraMarks++;
      } else {
        out(String.fromCharCode(c), 1);
      }
      continue; // prevBase inchangé : le diacritique suit sa base
    }
    flushMarks();
    stacked = 0;
    out(String.fromCharCode(c), 1);
    // Un sélecteur d'émoji ou un saut de ligne n'est pas une base : un
    // second sélecteur qui suit sera marqué.
    prevBase = c != 0x0A && !_isVariationSelector(c);
  }
  flushRun();
  flushMarks();
  return (hidden: hidden, codePoints: codePoints, total: total);
}

/// Texte révélé : caractères cachés remplacés par des jetons `⟦…⟧`.
@immutable
class RevealedText {
  const RevealedText({
    required this.text,
    required this.hiddenCount,
    required this.codePoints,
    required this.truncated,
  });

  /// Texte à afficher (jamais de caractère caché de la table ; une ligne
  /// finale « … N caractère(s) non affiché(s) » s'il a été coupé).
  final String text;

  /// Nombre de caractères cachés BRUTS du texte entier (et non de jetons).
  final int hiddenCount;

  /// Points de code cachés rencontrés (texte entier).
  final Set<int> codePoints;

  /// Vrai si l'affichage a été coupé à `maxUnits`.
  final bool truncated;
}

/// Rend visibles les caractères cachés de [raw]. U+000A est conservé ;
/// U+000D U+000A → « ⟦CR⟧\n » ; une suite de ≥ 2 occurrences du MÊME
/// caractère caché → `⟦U+E0041 ×37⟧` ; une suite de ≥ 4 caractères cachés
/// non tous identiques → `⟦N invisibles U+XXXX…U+YYYY⟧` ; au-delà du 2e
/// diacritique consécutif → `⟦+N diacritiques⟧`. L'affichage est coupé à
/// [maxUnits] unités UTF-16 (jamais dans un jeton ni une paire) et suivi de
/// la ligne « … N caractère(s) non affiché(s) ».
RevealedText revealInvisibles(String raw, {int maxUnits = kRevealDisplayMax}) {
  final StringBuffer buf = StringBuffer();
  int units = 0;
  int consumed = 0;
  bool truncated = false;
  final ({int hidden, Set<int> codePoints, int total}) r = _scan(raw.runes, (
    String text,
    int n,
  ) {
    // Après la coupure, le parcours continue pour compter les caractères
    // cachés du texte ENTIER (rien n'est plus ajouté).
    if (truncated) return true;
    if (units + text.length > maxUnits) {
      truncated = true;
      return true;
    }
    buf.write(text);
    units += text.length;
    consumed += n;
    return true;
  });
  if (truncated) {
    buf.write('\n… ${r.total - consumed} caractère(s) non affiché(s)');
  }
  return RevealedText(
    text: buf.toString(),
    hiddenCount: r.hidden,
    codePoints: Set<int>.unmodifiable(r.codePoints),
    truncated: truncated,
  );
}

/// Aperçu sur UNE ligne : coupe d'abord le texte BRUT à [max] + 1 points de
/// code (coût proportionnel à [max], jamais à la longueur du texte), puis
/// révèle, remplace les sauts de ligne par « ⏎ » et coupe à [max] points de
/// code affichés sans casser un jeton `⟦…⟧` ni une paire, suivi de « … » si
/// quelque chose a été coupé.
String oneLinePreview(String raw, {int max = 120}) {
  if (max < 1) return raw.isEmpty ? '' : '…';
  final bool rawCut = raw.runes.skip(max + 1).isNotEmpty;
  final StringBuffer buf = StringBuffer();
  int shown = 0;
  bool cut = false;
  _scan(raw.runes.take(max + 1), (String text, int n) {
    final String piece = text == '\n' ? '⏎' : text;
    final int len = piece.runes.length;
    if (shown + len > max) {
      cut = true;
      return false;
    }
    buf.write(piece);
    shown += len;
    return true;
  });
  if (cut || rawCut) buf.write('…');
  return buf.toString();
}

Object? _toEncodable(Object? o) => o.toString();

/// JSON indenté (2 espaces) puis révélé : `jsonEncode` n'échappe ni les
/// caractères bidirectionnels ni U+200B.
String prettyJsonRevealed(Object? json) => revealInvisibles(
  JsonEncoder.withIndent('  ', _toEncodable).convert(json),
).text;

int _utf8Length(String s) {
  int n = 0;
  for (final int c in s.runes) {
    n += c < 0x80
        ? 1
        : c < 0x800
        ? 2
        : c < 0x10000
        ? 3
        : 4;
  }
  return n;
}

/// Lignes du JSON indenté et révélé, pour un affichage paresseux
/// (`ListView.builder`). Au plus [maxBytes] octets (UTF-8) révélés ; au-delà,
/// la dernière ligne est la mention « Demande tronquée à l'affichage (N Kio
/// au total). » (N = taille compacte du JSON, arrondie au Kio supérieur).
List<String> revealedJsonLines(
  Object? json, {
  int maxBytes = kRevealedJsonMaxBytes,
}) {
  final String pretty = JsonEncoder.withIndent(
    '  ',
    _toEncodable,
  ).convert(json);
  final List<String> lines = <String>[];
  int bytes = 0;
  bool truncated = false;
  for (final String line in pretty.split('\n')) {
    final StringBuffer buf = StringBuffer();
    _scan(line.runes, (String text, int n) {
      final int b = _utf8Length(text);
      if (bytes + b > maxBytes) {
        truncated = true;
        return false;
      }
      buf.write(text);
      bytes += b;
      return true;
    });
    if (buf.isNotEmpty || !truncated) lines.add(buf.toString());
    if (truncated) break;
    bytes += 1; // saut de ligne
  }
  if (truncated) {
    final int total = utf8
        .encode(const JsonEncoder(_toEncodable).convert(json))
        .length;
    lines.add(
      "Demande tronquée à l'affichage (${(total + 1023) ~/ 1024} Kio au total).",
    );
  }
  return lines;
}

// ── b) Motif de revue ────────────────────────────────────────────────────────

/// Longueur maximale d'un motif, en points de code (MAX_NOTE_CHARS,
/// moderation.ts:27).
const int kReasonMaxCodePoints = 500;

/// Nombre de points de code du motif coupé (= codePointLength du serveur).
int reasonCodePoints(String s) => s.trim().runes.length;

/// Vrai si [s] contient U+0000 ou une unité UTF-16 de substitution isolée
/// (= hasUnstorableChars de suggestion_guard.ts:27-29) : jamais stockable.
bool hasUnstorableChars(String s) {
  final int n = s.length;
  for (int i = 0; i < n; i++) {
    final int u = s.codeUnitAt(i);
    if (u == 0) return true;
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 < n) {
        final int next = s.codeUnitAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          i++;
          continue;
        }
      }
      return true;
    }
    if (u >= 0xDC00 && u <= 0xDFFF) return true;
  }
  return false;
}

/// null = motif valide. Contrôle du caractère interdit sur le texte BRUT
/// (le serveur teste avant `trim`), longueur sur le texte coupé.
String? validateReviewReason(String raw, {required bool required}) {
  if (hasUnstorableChars(raw)) {
    return 'Motif invalide : caractère interdit (U+0000 ou demi-paire).';
  }
  final int n = reasonCodePoints(raw);
  if (n == 0) {
    return required
        ? 'Motif obligatoire pour une levée (1 à 500 caractères).'
        : null;
  }
  if (n > kReasonMaxCodePoints) {
    return 'Motif trop long : $n/$kReasonMaxCodePoints caractères.';
  }
  return null;
}

/// Motif à envoyer : coupé ; vide → null.
String? normalizeReviewReason(String raw) {
  final String t = raw.trim();
  return t.isEmpty ? null : t;
}

// ── c) Empreintes autorisées ────────────────────────────────────────────────

/// Empreinte SHA-256 en minuscules (SHA256_RE, moderation.ts:30).
final RegExp kSha256Re = RegExp(r'^[0-9a-f]{64}$');

/// Empreintes autorisées au plus (moderation.ts:540).
const int kMaxAllowedRulesSha = 50;

/// Empreinte normalisée (coupée, en minuscules) ; null si ce n'est pas 64
/// caractères hexadécimaux.
String? normalizeRulesSha(String raw) {
  final String s = raw.trim().toLowerCase();
  return kSha256Re.hasMatch(s) ? s : null;
}

/// Ajoute [raw] à [current] : message d'erreur, ou nouvelle liste triée sans
/// doublon.
({List<String>? list, String? error}) addRulesSha(
  List<String> current,
  String raw,
) {
  final String? sha = normalizeRulesSha(raw);
  if (sha == null) {
    return (
      list: null,
      error: 'Empreinte invalide : 64 caractères hexadécimaux attendus.',
    );
  }
  final Set<String> set = <String>{
    for (final String c in current) c.trim().toLowerCase(),
  };
  if (set.contains(sha)) return (list: null, error: 'Empreinte déjà présente.');
  if (set.length >= kMaxAllowedRulesSha) {
    return (list: null, error: '$kMaxAllowedRulesSha empreintes au plus.');
  }
  set.add(sha);
  return (list: set.toList()..sort(), error: null);
}

// ── d) Jours de purge des preuves ───────────────────────────────────────────

/// Bornes de `older_than_days` (moderation.ts:556) et défaut du propriétaire.
const int kPurgeDaysMin = 30;
const int kPurgeDaysMax = 3650;
const int kPurgeDaysDefault = 180;

/// null = entier valide de 30 à 3650.
String? validatePurgeDays(String raw) {
  final String s = raw.trim();
  final int? n = RegExp(r'^\d{1,9}$').hasMatch(s) ? int.parse(s) : null;
  if (n == null || n < kPurgeDaysMin || n > kPurgeDaysMax) {
    return 'Nombre de jours invalide : entier de $kPurgeDaysMin à $kPurgeDaysMax.';
  }
  return null;
}
