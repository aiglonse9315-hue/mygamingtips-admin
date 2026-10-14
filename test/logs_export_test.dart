// Tests purs (VM) de l'export CSV du menu « Log » (P4d L3,
// lib/domain/logs_export.dart) : cellules neutralisées (formules, y compris
// derrière des blancs ou invisibles de tête ; guillemets, toujours entre
// guillemets), colonnes v2 du journal, colonnes des tentatives, export
// « tout » à BORNE STABLE (pages qui se décalent pendant l'export, lignes
// plus récentes ignorées, doublons retirés, ligne retirée entre deux
// lectures → export incomplet, filtre qui change d'état, plafond de pages).
// Données neutres (IP des plages de documentation) ; aucune dépendance
// dart:html.

import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/logs_export.dart';
import 'package:mgt_admin/domain/models/log_entry.dart';
import 'package:mgt_admin/domain/models/security_attempt.dart';

const String _bom = '﻿';

final DateTime _t0 = DateTime.utc(2026, 10, 14, 8);

/// Ligne du journal n° [n] (plus [n] est grand, plus elle est ancienne).
LogEntry _row(int n, {DateTime? at, String detail = 'détail neutre'}) =>
    LogEntry(
      type: 'action',
      at: at ?? _t0.subtract(Duration(minutes: n)),
      username: 'compte-exemple',
      action: 'games/upsert',
      detail: '$detail $n',
    );

/// Journal simulé trié par date décroissante : [insertTop] ajoute des
/// lignes PLUS RÉCENTES en tête (arrivées pendant l'export) → les pages
/// suivantes se décalent.
class _Journal {
  _Journal(this.rows);

  final List<LogEntry> rows;
  final List<int> pagesRead = <int>[];

  void insertTop(List<LogEntry> fresh) => rows.insertAll(0, fresh);

  /// Retire [row] (connexion en cours conclue, ligne devenue masquable) :
  /// les pages suivantes se décalent dans l'AUTRE sens.
  void remove(LogEntry row) => rows.remove(row);

  ExportPage<LogEntry> page(int p, int size, {bool filtered = false}) {
    pagesRead.add(p);
    return (
      items: rows.skip(p * size).take(size).toList(),
      total: rows.length,
      filtered: filtered,
    );
  }
}

Future<StableExport<LogEntry>> _collect(
  Future<ExportPage<LogEntry>> Function(int page) fetch, {
  int pageSize = 3,
  int extraPages = kExportExtraPages,
}) => collectStableExport<LogEntry>(
  fetchPage: fetch,
  pageSize: pageSize,
  dateOf: (LogEntry l) => l.at,
  fieldsOf: logCsvFields,
  extraPages: extraPages,
);

/// Page simulée de [items] (total annoncé [total]).
ExportPage<LogEntry> _page(
  List<LogEntry> items,
  int total, {
  bool filtered = false,
}) => (items: items, total: total, filtered: filtered);

List<String> _details(StableExport<LogEntry> r) =>
    r.rows.map((LogEntry l) => l.detail).toList();

void main() {
  group('Cellule CSV', () {
    test('toujours entre guillemets ; guillemets doublés', () {
      expect(csvCell(''), '""');
      expect(csvCell('normal'), '"normal"');
      expect(csvCell('a"b'), '"a""b"');
      expect(csvCell('a;b'), '"a;b"');
      expect(csvCell('ligne 1\nligne 2'), '"ligne 1\nligne 2"');
    });

    test('début de formule neutralisé : =, +, -, @, tabulation, retour '
        'chariot → préfixe \'', () {
      expect(csvCell('=1+1'), '"\'=1+1"');
      expect(csvCell('+33'), '"\'+33"');
      expect(csvCell('-2'), '"\'-2"');
      expect(csvCell('@SOMME(A1)'), '"\'@SOMME(A1)"');
      expect(csvCell('\tcalcul'), '"\'\tcalcul"');
      expect(csvCell('\rcalcul'), '"\'\rcalcul"');
      // Préfixe ET guillemets doublés.
      expect(csvCell('=LIEN("x")'), '"\'=LIEN(""x"")"');
    });

    test('caractère de formule AILLEURS qu\'en tête : inchangé', () {
      expect(csvCell('a=b'), '"a=b"');
      expect(csvCell('x\n=y'), '"x\n=y"');
      expect(csvCell('2026-10-14'), '"2026-10-14"');
      // Blancs de tête SANS signe de formule derrière : inchangé.
      final String nbsp = String.fromCharCode(0xA0);
      expect(csvCell(' x'), '" x"');
      expect(csvCell('${nbsp}a=b'), '"${nbsp}a=b"');
      expect(csvCell('   '), '"   "');
    });

    test('blancs ou invisibles de tête PUIS signe de formule : préfixe \' '
        'devant TOUTE la valeur (sauts de ligne gardés)', () {
      final String nbsp = String.fromCharCode(0xA0);
      final String zwsp = String.fromCharCode(0x200B);
      final String ideo = String.fromCharCode(0x3000);
      final String bom = String.fromCharCode(0xFEFF);
      final String wj = String.fromCharCode(0x2060);
      expect(csvCell(' =x'), '"\' =x"');
      expect(csvCell('$nbsp=1+1'), '"\'$nbsp=1+1"');
      expect(csvCell('$zwsp=1+1'), '"\'$zwsp=1+1"');
      expect(csvCell('$ideo=1+1'), '"\'$ideo=1+1"');
      expect(csvCell('\n=1+1'), '"\'\n=1+1"');
      expect(csvCell('$bom$wj +33'), '"\'$bom$wj +33"');
      expect(csvCell(' \n-2'), '"\' \n-2"');
      expect(csvCell('$nbsp@SOMME(A1)'), '"\'$nbsp@SOMME(A1)"');
      // Préfixe ET guillemets doublés.
      expect(csvCell(' =LIEN("x")'), '"\' =LIEN(""x"")"');
    });

    test('ligne : cellules neutralisées séparées par ;', () {
      expect(csvRow(<String>['a', '=b', 'c"d']), '"a";"\'=b";"c""d"');
    });
  });

  group('CSV du journal', () {
    test('BOM, en-tête à 9 colonnes (v2 comprises), valeurs v2', () {
      final String csv = logsToCsv(<LogEntry>[
        LogEntry(
          type: 'auth',
          at: DateTime.utc(2026, 10, 14, 8, 30),
          username: '=compte',
          action: 'connexion réussie',
          detail: 'ok',
          success: true,
          ip: '203.0.113.7',
          ua: 'Navigateur "test"/1.0',
          sid: '0123456789abcdef0123456789abcdef',
        ),
        LogEntry(
          type: 'auth',
          at: DateTime.utc(2026, 10, 14, 8, 29),
          username: 'compte-exemple',
          action: 'connexion échouée',
          detail: '-x',
          success: false,
        ),
        LogEntry(
          type: 'action',
          at: null,
          username: 'compte-exemple',
          action: 'games/upsert',
          detail: '',
        ),
      ]);
      expect(csv.startsWith(_bom), isTrue);
      final List<String> lines = csv.substring(1).split('\n');
      expect(
        lines[0],
        '"at";"username";"type";"action";"detail";"success";"ip";"ua";"sid"',
      );
      expect(
        lines[1],
        '"2026-10-14T08:30:00.000Z";"\'=compte";"auth";"connexion réussie";'
        '"ok";"true";"203.0.113.7";"Navigateur ""test""/1.0";'
        '"0123456789abcdef0123456789abcdef"',
      );
      expect(
        lines[2],
        '"2026-10-14T08:29:00.000Z";"compte-exemple";"auth";'
        '"connexion échouée";"\'-x";"false";"";"";""',
      );
      expect(
        lines[3],
        '"";"compte-exemple";"action";"games/upsert";"";"";"";"";""',
      );
      expect(lines[4], '');
      expect(lines.length, 5);
    });
  });

  group('CSV des tentatives', () {
    test('en-tête et colonnes ; textes non fiables neutralisés', () {
      final String csv = attemptsToCsv(<SecurityAttempt>[
        SecurityAttempt(
          at: DateTime.utc(2026, 10, 14, 7),
          lastAt: DateTime.utc(2026, 10, 14, 7, 1),
          occurrences: 4,
          genre: 'code_brut',
          libelle: 'Libellé du serveur',
          route: '@route',
          username: '+login',
          ip: '2001:db8::1',
          ua: '\tagent',
          detail: '=detail',
        ),
      ]);
      final List<String> lines = csv.substring(1).split('\n');
      expect(
        lines[0],
        '"at";"last_at";"occurrences";"genre";"libelle";"route";"username";'
        '"ip";"ua";"detail"',
      );
      expect(
        lines[1],
        '"2026-10-14T07:00:00.000Z";"2026-10-14T07:01:00.000Z";"4";'
        '"code_brut";"Libellé du serveur";"\'@route";"\'+login";'
        '"2001:db8::1";"\'\tagent";"\'=detail"',
      );
    });
  });

  group('Export « tout » à borne stable', () {
    test('ajouts en tête seulement : pages qui se décalent, lignes arrivées '
        'en tête ignorées, doublons retirés, aucune ligne perdue', () async {
      final _Journal j = _Journal(<LogEntry>[
        for (int n = 0; n < 7; n++) _row(n),
      ]);
      final StableExport<LogEntry> r = await _collect((int p) async {
        // Deux lignes plus récentes arrivent après la lecture de la 1re
        // page : la page 1 relit r1, r2 (décalage de 2).
        if (p == 1) {
          j.insertTop(<LogEntry>[
            _row(-2, detail: 'nouvelle'),
            _row(-1, detail: 'nouvelle'),
          ]);
        }
        return j.page(p, 3);
      });
      expect(_details(r), <String>[
        for (int n = 0; n < 7; n++) 'détail neutre $n',
      ]);
      expect(r.removedDuplicates, 2);
      expect(r.ignoredRecent, 0);
      expect(r.complete, isTrue);
      expect(j.pagesRead, <int>[0, 1, 2, 3]);
    });

    test('(A) ligne insérée en tête après la page 0 puis RETIRÉE après la '
        'page 1 : une ligne sautée → export marqué incomplet (total '
        'comparé à la page PRÉCÉDENTE : 9 → 10 → 9)', () async {
      final _Journal j = _Journal(<LogEntry>[
        for (int n = 0; n < 9; n++) _row(n),
      ]);
      // Connexion en cours : plus récente que la borne, puis conclue
      // (sortie de la liste) avant la lecture de la page 2.
      final LogEntry pending = _row(-1, detail: 'en cours');
      final List<int> totals = <int>[];
      final StableExport<LogEntry> r = await _collect((int p) async {
        if (p == 1) j.insertTop(<LogEntry>[pending]);
        if (p == 2) j.remove(pending);
        final ExportPage<LogEntry> page = j.page(p, 3);
        totals.add(page.total);
        return page;
      });
      expect(totals, <int>[9, 10, 9, 9]);
      // La ligne n° 5 n'a jamais été lue : décalage de la page 2.
      expect(_details(r), <String>[
        for (final int n in <int>[0, 1, 2, 3, 4, 6, 7, 8]) 'détail neutre $n',
      ]);
      expect(r.removedDuplicates, 1);
      expect(r.complete, isFalse);
    });

    test('(B) ligne présente à la page 0 puis RETIRÉE avant la page 1 : le '
        'NOMBRE de lignes reste juste mais une vraie ligne manque → export '
        'marqué incomplet', () async {
      final LogEntry pending = _row(-1, detail: 'en cours');
      final _Journal j = _Journal(<LogEntry>[
        pending,
        for (int n = 0; n < 8; n++) _row(n),
      ]);
      final StableExport<LogEntry> r = await _collect((int p) async {
        if (p == 1) j.remove(pending);
        return j.page(p, 3);
      });
      // 8 lignes exportées pour 8 vraies lignes, mais la n° 2 manque et la
      // ligne périmée « en cours » est exportée à sa place.
      expect(r.rows.length, 8);
      expect(_details(r), <String>[
        'en cours -1',
        for (final int n in <int>[0, 1, 3, 4, 5, 6, 7]) 'détail neutre $n',
      ]);
      expect(_details(r), isNot(contains('détail neutre 2')));
      expect(r.removedDuplicates, 0);
      expect(r.complete, isFalse);
      expect(j.pagesRead, <int>[0, 1, 2]);
    });

    test('lignes repoussées AU-DELÀ du total annoncé par la 1re page : lues '
        'quand même (jusqu\'à une page incomplète)', () async {
      final _Journal j = _Journal(<LogEntry>[
        for (int n = 0; n < 6; n++) _row(n),
      ]);
      final StableExport<LogEntry> r = await _collect((int p) async {
        if (p == 1) {
          j.insertTop(<LogEntry>[
            for (int n = -3; n < 0; n++) _row(n, detail: 'nouvelle'),
          ]);
        }
        return j.page(p, 3);
      });
      expect(_details(r), <String>[
        for (int n = 0; n < 6; n++) 'détail neutre $n',
      ]);
      expect(r.removedDuplicates, 3);
      expect(r.complete, isTrue);
      // Total annoncé : 6 → 2 pages ; les pages 2 et 3 sont lues en plus.
      expect(j.pagesRead, <int>[0, 1, 2, 3]);
    });

    test('ligne plus récente que la borne dans une page suivante : '
        'ignorée et comptée', () async {
      final LogEntry late = _row(
        99,
        at: _t0.add(const Duration(seconds: 1)),
        detail: 'tardive',
      );
      final List<ExportPage<LogEntry>> pages = <ExportPage<LogEntry>>[
        _page(<LogEntry>[_row(0), _row(1), _row(2)], 5),
        _page(<LogEntry>[late, _row(3), _row(4)], 5),
        _page(const <LogEntry>[], 5),
      ];
      final StableExport<LogEntry> r = await _collect(
        (int p) async => pages[p],
      );
      expect(_details(r), <String>[
        for (int n = 0; n < 5; n++) 'détail neutre $n',
      ]);
      expect(r.ignoredRecent, 1);
      expect(r.removedDuplicates, 0);
    });

    test('la borne est la date la plus récente de la 1re page ; une date '
        'inconnue est gardée', () async {
      final LogEntry undated = LogEntry(
        type: 'action',
        at: null,
        username: 'compte-exemple',
        action: 'games/upsert',
        detail: 'sans date',
      );
      final List<ExportPage<LogEntry>> pages = <ExportPage<LogEntry>>[
        _page(<LogEntry>[_row(1), _row(0), _row(2)], 4),
        _page(<LogEntry>[undated], 4),
      ];
      final StableExport<LogEntry> r = await _collect(
        (int p) async => pages[p],
      );
      expect(_details(r), <String>[
        'détail neutre 1',
        'détail neutre 0',
        'détail neutre 2',
        'sans date',
      ]);
      expect(r.ignoredRecent, 0);
    });

    test('deux lignes identiques dans la MÊME page restent ; identiques à '
        'une page précédente → retirées', () async {
      final LogEntry a = _row(1);
      final LogEntry copy = _row(1);
      final List<ExportPage<LogEntry>> pages = <ExportPage<LogEntry>>[
        _page(<LogEntry>[_row(0), a, copy], 5),
        _page(<LogEntry>[_row(1), _row(2)], 5),
      ];
      final StableExport<LogEntry> r = await _collect(
        (int p) async => pages[p],
      );
      expect(_details(r), <String>[
        'détail neutre 0',
        'détail neutre 1',
        'détail neutre 1',
        'détail neutre 2',
      ]);
      expect(r.removedDuplicates, 1);
    });

    test('clé = TOUTES les colonnes : une seule colonne v2 différente → '
        'pas un doublon', () async {
      LogEntry withSid(String sid) => LogEntry(
        type: 'auth',
        at: _t0,
        username: 'compte-exemple',
        action: 'connexion réussie',
        detail: 'même détail',
        success: true,
        ip: '203.0.113.7',
        ua: 'Navigateur/1.0',
        sid: sid,
      );
      final List<ExportPage<LogEntry>> pages = <ExportPage<LogEntry>>[
        _page(<LogEntry>[withSid('a' * 32)], 2),
        _page(<LogEntry>[withSid('b' * 32)], 2),
        _page(const <LogEntry>[], 2),
      ];
      final StableExport<LogEntry> r = await _collect(
        (int p) async => pages[p],
        pageSize: 1,
      );
      expect(r.rows.map((LogEntry l) => l.sid), <String>['a' * 32, 'b' * 32]);
      expect(r.removedDuplicates, 0);
    });

    test('journal vide ou page incomplète : une seule lecture', () async {
      final _Journal empty = _Journal(<LogEntry>[]);
      final StableExport<LogEntry> r0 = await _collect(
        (int p) async => empty.page(p, 3),
      );
      expect(r0.rows, isEmpty);
      expect(r0.complete, isTrue);
      expect(empty.pagesRead, <int>[0]);

      final _Journal small = _Journal(<LogEntry>[_row(0), _row(1)]);
      final StableExport<LogEntry> r1 = await _collect(
        (int p) async => small.page(p, 3),
      );
      expect(r1.rows.length, 2);
      expect(small.pagesRead, <int>[0]);
    });

    test('filtre du serveur qui change d\'état entre deux pages → '
        'ExportFilterChangedException', () async {
      final _Journal j = _Journal(<LogEntry>[
        for (int n = 0; n < 6; n++) _row(n),
      ]);
      await expectLater(
        _collect((int p) async => j.page(p, 3, filtered: p == 0)),
        throwsA(isA<ExportFilterChangedException>()),
      );
      expect(
        ExportFilterChangedException.message,
        contains('relance l\'export'),
      );
    });

    test('filtre appliqué partout : résultat « filtré »', () async {
      final _Journal j = _Journal(<LogEntry>[
        for (int n = 0; n < 4; n++) _row(n),
      ]);
      final StableExport<LogEntry> r = await _collect(
        (int p) async => j.page(p, 3, filtered: true),
      );
      expect(r.filtered, isTrue);
      expect(r.rows.length, 4);
    });

    test('plafond de pages atteint sur une page encore pleine → export '
        'marqué incomplet', () async {
      int n = 0;
      final StableExport<LogEntry> r = await _collect(
        (int p) async => (
          items: <LogEntry>[_row(n++), _row(n++), _row(n++)],
          total: 3,
          filtered: false,
        ),
        extraPages: 1,
      );
      expect(r.rows.length, 6); // pages 0 et 1 (1 annoncée + 1 de plus)
      expect(r.complete, isFalse);
    });

    test('erreur d\'une page : remonte telle quelle', () async {
      final _Journal j = _Journal(<LogEntry>[
        for (int n = 0; n < 6; n++) _row(n),
      ]);
      await expectLater(
        _collect((int p) async {
          if (p == 1) throw const AdminApiException(500, 'Erreur serveur.');
          return j.page(p, 3);
        }),
        throwsA(isA<AdminApiException>()),
      );
    });
  });
}
