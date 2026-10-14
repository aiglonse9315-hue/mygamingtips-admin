// Pur (VM) — export CSV du menu « Log » (P4d L3, conception
// tools/PLAN_VISION2_P4d_CONCEPTION.md §4 « L3 — CONTRAT ») : journal
// (page, tout, archives) et tentatives (page, tout).
//
// a) Cellule NEUTRALISÉE : une valeur qui commence par `=`, `+`, `-`, `@`,
//    une tabulation ou un retour chariot est préfixée par `'` (un tableur ne
//    la lit plus comme une formule — injection CSV) ; de même si `=`, `+`,
//    `-` ou `@` vient juste après des blancs ou caractères invisibles de
//    tête (espace, espace insécable, U+200B, saut de ligne… : un import qui
//    les retire en ferait une formule) — le préfixe est alors mis devant
//    TOUTE la valeur, inchangée par ailleurs (sauts de ligne gardés) ;
//    guillemets doublés ; TOUJOURS entre guillemets. Séparateur `;`, BOM
//    UTF-8 en tête (Excel).
// b) Colonnes : 5 historiques + v2 (`success`, `ip`, `ua`, `sid`) pour le
//    journal ; toutes les colonnes de `logs/attempts` pour les tentatives
//    (le `genre` brut compris, jamais interprété).
// c) Export « tout » à BORNE STABLE ([collectStableExport]) : la date de la
//    ligne la plus récente de la 1re page fixe la borne ; une ligne plus
//    récente (arrivée pendant l'export) est ignorée ; un décalage de page
//    (lignes arrivées en tête entre deux lectures) fait relire en tête de
//    page des lignes déjà lues : ces doublons sont retirés (clé = toutes les
//    colonnes exportées). Lecture jusqu'à une page incomplète, plafonnée au
//    nombre de pages annoncé par la 1re page + [kExportExtraPages].
//    Une ligne RETIRÉE entre deux lectures (connexion en cours conclue,
//    ligne devenue masquable) décale les pages dans l'autre sens : une
//    ligne non lue peut être sautée. Le total d'une page plus petit que
//    celui de la page PRÉCÉDENTE marque donc l'export incomplet (la 1re
//    page ne suffit pas : 1 200 → 1 201 → 1 200 cache un retrait). Limites
//    connues : une purge ou un archivage en bas de liste donne une fausse
//    alerte sans gravité ; avec le filtre « activité normale », une ligne
//    masquée qui redevient visible est un ajout au MILIEU de la liste, qui
//    peut cacher la baisse du total si un retrait a lieu entre les deux
//    mêmes lectures. Correction durable (serveur) : pagination par curseur.
//
// Aucune dépendance Flutter ni dart:html : testé sur VM
// (`flutter test test/logs_export_test.dart`).
import 'dart:convert';

import 'models/log_entry.dart';
import 'models/security_attempt.dart';

// ── a) Cellules ──────────────────────────────────────────────────────────────

/// Séparateur des colonnes (comme l'export d'avant L3).
const String kCsvSeparator = ';';

/// Premiers caractères qui font d'une cellule une FORMULE pour un tableur.
const List<String> kCsvFormulaPrefixes = <String>[
  '=',
  '+',
  '-',
  '@',
  '\t',
  '\r',
];

/// Signes de formule cherchés APRÈS les blancs et invisibles de tête
/// ([_csvLeadingBlanks]).
const List<String> kCsvFormulaSigns = <String>['=', '+', '-', '@'];

/// Blancs et caractères invisibles de tête, sautés avant de chercher un
/// signe de formule : `\s`, U+00A0, U+1680, U+2000 à U+200F, U+2028 à
/// U+202F, U+205F à U+2064, U+3000, U+FEFF.
final RegExp _csvLeadingBlanks = RegExp(
  r'^[\s\u00A0\u1680\u2000-\u200F\u2028-\u202F\u205F-\u2064\u3000\uFEFF]+',
);

/// Vrai si un tableur peut lire [value] comme une formule : premier
/// caractère de [kCsvFormulaPrefixes], ou signe de [kCsvFormulaSigns] juste
/// après des blancs ou invisibles de tête.
bool _startsLikeFormula(String value) =>
    kCsvFormulaPrefixes.any(value.startsWith) ||
    kCsvFormulaSigns.any(value.replaceFirst(_csvLeadingBlanks, '').startsWith);

/// Cellule CSV neutralisée : préfixe `'` devant TOUTE la valeur qui
/// commence comme une formule (blancs et invisibles de tête sautés),
/// guillemets doublés, toujours entre guillemets. Rien d'autre ne change
/// (sauts de ligne gardés).
String csvCell(String value) {
  final String safe = _startsLikeFormula(value) ? "'$value" : value;
  return '"${safe.replaceAll('"', '""')}"';
}

/// Ligne CSV (cellules neutralisées, séparées par `;`).
String csvRow(Iterable<String> cells) =>
    cells.map(csvCell).join(kCsvSeparator);

/// Fichier CSV : BOM UTF-8, en-tête puis une ligne par entrée.
String csvDocument(List<String> header, Iterable<List<String>> rows) {
  final StringBuffer sb = StringBuffer('﻿')..writeln(csvRow(header));
  for (final List<String> r in rows) {
    sb.writeln(csvRow(r));
  }
  return sb.toString();
}

// ── b) Colonnes ──────────────────────────────────────────────────────────────

/// En-tête du journal : 5 colonnes historiques + v2.
const List<String> kLogCsvHeader = <String>[
  'at',
  'username',
  'type',
  'action',
  'detail',
  'success',
  'ip',
  'ua',
  'sid',
];

/// Valeurs d'une ligne du journal, dans l'ordre de [kLogCsvHeader] (valeur
/// absente → cellule vide).
List<String> logCsvFields(LogEntry l) => <String>[
  l.at?.toIso8601String() ?? '',
  l.username,
  l.type,
  l.action,
  l.detail,
  switch (l.success) {
    true => 'true',
    false => 'false',
    null => '',
  },
  l.ip ?? '',
  l.ua ?? '',
  l.sid ?? '',
];

/// CSV du journal (page, tout ou archive).
String logsToCsv(Iterable<LogEntry> logs) =>
    csvDocument(kLogCsvHeader, logs.map(logCsvFields));

/// En-tête des tentatives (colonnes de `logs/attempts`).
const List<String> kAttemptCsvHeader = <String>[
  'at',
  'last_at',
  'occurrences',
  'genre',
  'libelle',
  'route',
  'username',
  'ip',
  'ua',
  'detail',
];

/// Valeurs d'une tentative, dans l'ordre de [kAttemptCsvHeader].
List<String> attemptCsvFields(SecurityAttempt a) => <String>[
  a.at?.toIso8601String() ?? '',
  a.lastAt?.toIso8601String() ?? '',
  '${a.occurrences}',
  a.genre ?? '',
  a.libelle,
  a.route ?? '',
  a.username ?? '',
  a.ip ?? '',
  a.ua ?? '',
  a.detail ?? '',
];

/// CSV des tentatives (page ou tout).
String attemptsToCsv(Iterable<SecurityAttempt> attempts) =>
    csvDocument(kAttemptCsvHeader, attempts.map(attemptCsvFields));

// ── c) Export « tout » à borne stable ────────────────────────────────────────

/// Pages lues au-delà du nombre annoncé par la 1re page (lignes arrivées
/// pendant l'export, qui repoussent les plus anciennes plus loin).
const int kExportExtraPages = 3;

/// Page lue pendant un export « tout » : lignes, total annoncé, et
/// [filtered] = le filtre du serveur a tourné pour cette page (toujours
/// faux pour les tentatives).
typedef ExportPage<T> = ({List<T> items, int total, bool filtered});

/// Le filtre du serveur n'a pas eu le même état d'une page à l'autre (filtre
/// tombé en panne ou revenu pendant l'export) : pages incompatibles, export
/// abandonné.
class ExportFilterChangedException implements Exception {
  const ExportFilterChangedException();

  static const String message =
      'Le filtre « Masquer l\'activité normale » a changé d\'état pendant '
      'l\'export : relance l\'export.';

  @override
  String toString() => message;
}

/// Résultat d'un export « tout ».
class StableExport<T> {
  const StableExport({
    required this.rows,
    required this.ignoredRecent,
    required this.removedDuplicates,
    required this.complete,
    required this.filtered,
  });

  /// Lignes exportées, dans l'ordre du serveur.
  final List<T> rows;

  /// Lignes plus récentes que la borne (arrivées pendant l'export).
  final int ignoredRecent;

  /// Doublons nés d'un décalage de page.
  final int removedDuplicates;

  /// Faux : export peut-être incomplet — plafond de pages atteint sur une
  /// page encore pleine, ou total en baisse d'une page à la suivante (ligne
  /// retirée entre deux lectures : une ligne a pu être sautée).
  final bool complete;

  /// État du filtre du serveur (celui de la 1re page, le même partout).
  final bool filtered;
}

/// Lit TOUTES les pages par [fetchPage] (pages de [pageSize]) et rend les
/// lignes à borne stable (voir l'en-tête). [dateOf] : date de tri de la
/// ligne (null = inconnue : gardée) ; [fieldsOf] : colonnes exportées (clé
/// des doublons).
///
/// Doublon = clé déjà lue dans une page PRÉCÉDENTE : deux lignes identiques
/// dans la MÊME page sont deux vraies lignes et restent toutes les deux.
/// Total en baisse par rapport à la page PRÉCÉDENTE → [StableExport.complete]
/// faux. Lève [ExportFilterChangedException] si [ExportPage.filtered]
/// change d'une page à l'autre ; toute erreur de [fetchPage] remonte telle
/// quelle.
Future<StableExport<T>> collectStableExport<T>({
  required Future<ExportPage<T>> Function(int page) fetchPage,
  required int pageSize,
  required DateTime? Function(T row) dateOf,
  required List<String> Function(T row) fieldsOf,
  int extraPages = kExportExtraPages,
}) async {
  final ExportPage<T> first = await fetchPage(0);
  DateTime? bound;
  for (final T row in first.items) {
    final DateTime? d = dateOf(row);
    if (d != null && (bound == null || d.isAfter(bound))) bound = d;
  }
  final int size = pageSize < 1 ? 1 : pageSize;
  final int announced = first.total <= 0 ? 1 : (first.total + size - 1) ~/ size;
  final int maxPages = announced + (extraPages < 0 ? 0 : extraPages);

  final List<T> rows = <T>[];
  final Set<String> seen = <String>{};
  int ignored = 0;
  int duplicates = 0;

  void take(List<T> items) {
    final Set<String> pageKeys = <String>{};
    for (final T row in items) {
      final DateTime? d = dateOf(row);
      if (bound != null && d != null && d.isAfter(bound)) {
        ignored++;
        continue;
      }
      final String key = jsonEncode(fieldsOf(row));
      if (seen.contains(key)) {
        duplicates++;
        continue;
      }
      pageKeys.add(key);
      rows.add(row);
    }
    seen.addAll(pageKeys);
  }

  take(first.items);
  int lastLength = first.items.length;
  // Total de la page PRÉCÉDENTE (jamais celui de la 1re page seulement).
  int prevTotal = first.total;
  bool shrunk = false;
  int page = 1;
  while (lastLength >= size && page < maxPages) {
    final ExportPage<T> next = await fetchPage(page);
    if (next.filtered != first.filtered) {
      throw const ExportFilterChangedException();
    }
    if (next.total < prevTotal) shrunk = true;
    prevTotal = next.total;
    take(next.items);
    lastLength = next.items.length;
    page++;
  }
  return StableExport<T>(
    rows: rows,
    ignoredRecent: ignored,
    removedDuplicates: duplicates,
    complete: lastLength < size && !shrunk,
    filtered: first.filtered,
  );
}
