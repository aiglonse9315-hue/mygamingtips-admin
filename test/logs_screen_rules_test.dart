// Tests purs (VM) des libellés et règles d'affichage du menu « Log » (P4d
// L3, lib/domain/logs_screen_rules.dart) : compteur des lignes masquées,
// session courte, réussite, « ×N » et « dernière : … » des tentatives,
// page au-delà de la fin, message « vide », horodatage des fichiers,
// message de fin d'export. Le fichier ne contient
// ni règle du filtre, ni seuil, ni code de tentative (vérifié ici sur sa
// source). Aucune dépendance dart:html.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/logs_export.dart';
import 'package:mgt_admin/domain/logs_screen_rules.dart';
import 'package:mgt_admin/domain/models/security_attempt.dart';

SecurityAttempt _attempt({
  int occurrences = 1,
  DateTime? at,
  DateTime? lastAt,
  String libelle = 'Libellé du serveur',
}) => SecurityAttempt(
  at: at ?? DateTime.utc(2026, 10, 14, 7),
  lastAt: lastAt ?? DateTime.utc(2026, 10, 14, 7),
  occurrences: occurrences,
  genre: 'code_brut',
  libelle: libelle,
  route: null,
  username: null,
  ip: null,
  ua: null,
  detail: null,
);

StableExport<Object?> _result({
  int rows = 3,
  int ignored = 0,
  int duplicates = 0,
  bool complete = true,
  bool filtered = false,
}) => StableExport<Object?>(
  rows: List<Object?>.filled(rows, null),
  ignoredRecent: ignored,
  removedDuplicates: duplicates,
  complete: complete,
  filtered: filtered,
);

void main() {
  test('onglets, bascule et messages', () {
    expect(kLogsTabLabels, <String>['Journal', 'Tentatives']);
    expect(kLogsMaskToggleLabel, 'Masquer l\'activité normale');
    expect(kLogsFilterUnavailable, 'Filtre indisponible : tout est affiché');
    expect(kLogsPageSize, 100);
    expect(kLogsExportChunk, 500);
  });

  test('« N ligne(s) masquée(s) »', () {
    expect(maskedCountLabel(0), '0 ligne masquée');
    expect(maskedCountLabel(1), '1 ligne masquée');
    expect(maskedCountLabel(2), '2 lignes masquées');
    expect(maskedCountLabel(1234), '1234 lignes masquées');
  });

  test('session courte : 8 premiers caractères, rien si absente', () {
    expect(shortSid('0123456789abcdef0123456789abcdef'), '01234567');
    expect(shortSid('abc'), 'abc');
    expect(shortSid(''), '');
    expect(shortSid(null), '');
    // Points de code (jamais une paire coupée).
    expect(shortSid('${'a' * 7}\u{1F600}zz'), '${'a' * 7}\u{1F600}');
  });

  test('réussite : infobulle ou rien', () {
    expect(successTooltip(true), 'Réussie');
    expect(successTooltip(false), 'Échec ou blocage');
    expect(successTooltip(null), isNull);
  });

  test('date JJ/MM/AAAA HH:mm en heure locale ; « — » si absente', () {
    final DateTime local = DateTime(2026, 3, 4, 5, 6);
    expect(formatLogDate(local), '04/03/2026 05:06');
    expect(formatLogDate(null), '—');
  });

  test('tentatives : « ×N » et « dernière : … » d\'une ligne regroupée', () {
    expect(attemptOccurrencesLabel(_attempt()), '');
    expect(attemptOccurrencesLabel(_attempt(occurrences: 7)), '×7');

    final DateTime last = DateTime.utc(2026, 10, 14, 7, 30);
    expect(attemptLastAtLabel(_attempt(lastAt: last)), isNull);
    expect(
      attemptLastAtLabel(_attempt(occurrences: 2, lastAt: last)),
      'dernière : ${formatLogDate(last)}',
    );
    expect(attemptLastAtLabel(_attempt(occurrences: 2)), isNull);

    expect(attemptLabel(_attempt()), 'Libellé du serveur');
    expect(attemptLabel(_attempt(libelle: '')), '—');
  });

  test('page au-delà de la fin : dernière page qui existe ; la relance se '
      'termine toujours', () {
    // Total 250 → 120 : la page 3 (index 2) n'existe plus → page 2.
    expect(lastPageIfBeyondEnd(page: 2, empty: true, total: 120), 1);
    expect(lastPageIfBeyondEnd(page: 9, empty: true, total: 50), 0);
    expect(lastPageIfBeyondEnd(page: 2, empty: true, total: 101), 1);
    expect(lastPageIfBeyondEnd(page: 2, empty: true, total: 100), 0);
    // Rien à recharger : page non vide, 1re page, total nul.
    expect(lastPageIfBeyondEnd(page: 2, empty: false, total: 120), isNull);
    expect(lastPageIfBeyondEnd(page: 0, empty: true, total: 120), isNull);
    expect(lastPageIfBeyondEnd(page: 2, empty: true, total: 0), isNull);
    // Page vide DANS les bornes (réponse incohérente) : jamais la même page
    // ni une page plus loin (pas de boucle).
    expect(lastPageIfBeyondEnd(page: 2, empty: true, total: 250), isNull);
    expect(lastPageIfBeyondEnd(page: 1, empty: true, total: 250), isNull);
  });

  test('message « vide » seulement pour un total nul', () {
    expect(showLogsEmpty(empty: true, total: 0), isTrue);
    expect(showLogsEmpty(empty: true, total: 120), isFalse);
    expect(showLogsEmpty(empty: false, total: 0), isFalse);
    expect(showLogsEmpty(empty: false, total: 3), isFalse);
  });

  test('horodatage des fichiers AAAAMMJJ_HHmm', () {
    expect(exportFileStamp(DateTime(2026, 1, 2, 3, 4)), '20260102_0304');
  });

  test('message de fin d\'export', () {
    expect(exportDoneMessage(_result()), 'Export terminé : 3 lignes.');
    expect(exportDoneMessage(_result(rows: 1)), 'Export terminé : 1 ligne.');
    final String all = exportDoneMessage(
      _result(ignored: 2, duplicates: 4, complete: false),
      maskRequested: true,
    );
    expect(all, startsWith('Export terminé : 3 lignes.'));
    expect(all, contains('2 plus récente(s)'));
    expect(all, contains('4 doublon(s) retiré(s).'));
    expect(all, contains(kLogsFilterUnavailable));
    expect(all, contains('incomplet'));
    // Filtre demandé ET appliqué : pas d'avertissement.
    expect(
      exportDoneMessage(_result(filtered: true), maskRequested: true),
      'Export terminé : 3 lignes.',
    );
  });

  test('dépôt public : l\'affichage ne lit JAMAIS le code d\'une tentative '
      '(seul le libellé du serveur) ; plus aucun appel de suppression '
      'd\'archive dans lib/', () {
    // Le code brut (`genre`) n'est lu que par le modèle et l'export CSV.
    const List<String> display = <String>[
      'lib/domain/logs_screen_rules.dart',
      'lib/ui/screens/logs_screen.dart',
      'lib/ui/screens/logs/journal_tab.dart',
      'lib/ui/screens/logs/attempts_tab.dart',
      'lib/ui/screens/logs/archives_section.dart',
      'lib/ui/screens/logs/logs_common.dart',
    ];
    for (final String f in display) {
      expect(File(f).readAsStringSync().contains('genre'), isFalse, reason: f);
    }
    // Route en littéral Dart (un appel) ; les commentaires la citent entre
    // accents graves.
    for (final FileSystemEntity e in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      expect(
        e.readAsStringSync().contains("'logs/archive/delete'"),
        isFalse,
        reason: e.path,
      );
    }
  });
}
