// Onglets du menu « Log » (P4d L3, conception §4 « L3 — CONTRAT ») :
// journal (bascule « Masquer l'activité normale » après la source, éteinte
// par défaut ; compteur des lignes masquées ; « Filtre indisponible » ;
// pagination et export qui suivent la bascule ; colonnes v2 ; textes non
// fiables ; 403 / 401 ; total qui diminue → dernière page qui existe ;
// « Réessayer » / « Rafraîchir » après un changement de bascule ou de
// source en échec → page 1 du nouveau filtre), archives (listées,
// téléchargées, PLUS de bouton de suppression ; état gardé quand la section
// sort de la vue ou change de place, fichier enregistré même section
// démontée), export CSV (page, tout à borne stable, filtre qui change
// d'état) et tentatives (libellé du serveur, « ×N », « dernière : … »,
// pagination, total qui diminue, page demandée relue, 403 / 401, export).
//
// Les onglets n'importent NI Provider NI dart:html : ils sont montés ici
// avec un `SupabaseSync` FACTICE (méthodes surchargées, aucun réseau) et un
// enregistreur de CSV qui capture les fichiers. Exécuté en VM par
// `flutter test`. Données neutres (IP des plages de documentation) ;
// caractères spéciaux construits par String.fromCharCode.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/logs_export.dart';
import 'package:mgt_admin/domain/logs_screen_rules.dart';
import 'package:mgt_admin/domain/models/log_entry.dart';
import 'package:mgt_admin/domain/models/security_attempt.dart';
import 'package:mgt_admin/ui/screens/logs/attempts_tab.dart';
import 'package:mgt_admin/ui/screens/logs/journal_tab.dart';
import 'package:mgt_admin/ui/widgets/moderation/moderation_ui.dart';

import 'support/http_fixtures.dart' show testJwt;
import 'support/widget_fixtures.dart';

final String _rlo = String.fromCharCode(0x202E);
final String _zwsp = String.fromCharCode(0x200B);
final String _tab = String.fromCharCode(0x09);

const String _sid = '0123456789abcdef0123456789abcdef';

const String _illisible = 'Réponse illisible du serveur.';

/// Lecture du journal reçue par le serveur factice.
typedef _LogCall = ({int page, int pageSize, String source, bool masquer});

/// Fichier CSV capturé.
typedef _Saved = ({String csv, String name});

/// `SupabaseSync` factice : chaque route renvoie ce que le test a préparé et
/// enregistre l'appel. Aucune requête HTTP.
class _FakeSync extends SupabaseSync {
  _FakeSync()
    : super(
        supabaseUrl: 'https://exemple.invalid',
        anonKey: 'anon',
        catalogEndpoint: 'https://exemple.invalid/functions/v1/admin-catalog',
        adminToken: testJwt(),
        retryDelays: const <Duration>[Duration.zero, Duration.zero],
      );

  final List<_LogCall> logCalls = <_LogCall>[];
  final List<({int page, int pageSize})> attemptCalls =
      <({int page, int pageSize})>[];
  final List<String> downloads = <String>[];

  /// Lectures de `logs/archives/list`.
  int archiveListCalls = 0;

  /// Téléchargement d'archive retenu jusqu'à `complete()` (null :
  /// immédiat).
  Completer<void>? archiveGate;

  /// Lectures d'export « tout » (pages de [kLogsExportChunk]) retenues
  /// jusqu'à `complete()` (null : immédiates).
  Completer<void>? exportGate;

  LogPage Function(_LogCall c) logs = (_LogCall c) =>
      const LogPage(items: <LogEntry>[], total: 0);
  SecurityAttemptPage Function(int page) attempts = (int page) =>
      const SecurityAttemptPage(items: <SecurityAttempt>[], total: 0);
  List<Map<String, dynamic>> Function() archives = () =>
      <Map<String, dynamic>>[];
  List<LogEntry> Function(String table) archive = (String table) =>
      <LogEntry>[];

  @override
  Future<LogPage> fetchLogs({
    int page = 0,
    int pageSize = 100,
    String source = 'all',
    bool masquer = false,
  }) async {
    final _LogCall c = (
      page: page,
      pageSize: pageSize,
      source: source,
      masquer: masquer,
    );
    logCalls.add(c);
    if (pageSize == kLogsExportChunk && exportGate != null) {
      await exportGate!.future;
    }
    return logs(c);
  }

  @override
  Future<SecurityAttemptPage> fetchSecurityAttempts({
    int page = 0,
    int pageSize = 100,
  }) async {
    attemptCalls.add((page: page, pageSize: pageSize));
    if (pageSize == kLogsExportChunk && exportGate != null) {
      await exportGate!.future;
    }
    return attempts(page);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchLogArchives() async {
    archiveListCalls++;
    return archives();
  }

  @override
  Future<List<LogEntry>> downloadLogArchive(String table) async {
    downloads.add(table);
    final Completer<void>? gate = archiveGate;
    if (gate != null) await gate.future;
    return archive(table);
  }
}

final DateTime _t0 = DateTime.utc(2026, 10, 14, 8);

/// Ligne n° [n] du journal (plus [n] est grand, plus elle est ancienne).
LogEntry _entry(
  int n, {
  String type = 'auth',
  bool? success = true,
  String? ip = '203.0.113.7',
  String? ua = 'Navigateur/1.0',
  String? sid = _sid,
  String username = 'compte-exemple',
  String? detail,
}) => LogEntry(
  type: type,
  at: _t0.subtract(Duration(minutes: n)),
  username: username,
  action: type == 'auth' ? 'connexion réussie' : 'games/upsert',
  detail: detail ?? 'détail neutre $n',
  success: success,
  ip: ip,
  ua: ua,
  sid: sid,
);

/// Monte [tab] puis laisse partir la première lecture.
Future<void> _pumpTab(
  WidgetTester tester,
  Widget tab, {
  Size size = const Size(1400, 2400),
}) async {
  setWindow(tester, size);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: tab)));
  await tester.pump(); // rappel après la première image → lecture
  await tester.pump(); // réponse
}

/// Laisse s'écouler les SnackBars (aucune minuterie en fin de test).
Future<void> _drainSnacks(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pumpAndSettle();
}

/// Ouvre le menu d'export et choisit [item] (`logs-export-page` /
/// `logs-export-all`).
Future<void> _export(WidgetTester tester, String item) async {
  await tester.tap(find.byKey(const Key('logs-export')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(item)));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

LogJournalTab _journal(
  _FakeSync sync,
  List<_Saved> saved, {
  VoidCallback? onAuthError,
  Key? key,
}) => LogJournalTab(
  key: key,
  sync: sync,
  onAuthError: onAuthError ?? () {},
  saveCsv: (String csv, String name) => saved.add((csv: csv, name: name)),
);

LogAttemptsTab _attemptsTab(
  _FakeSync sync,
  List<_Saved> saved, {
  VoidCallback? onAuthError,
  Key? key,
}) => LogAttemptsTab(
  key: key,
  sync: sync,
  onAuthError: onAuthError ?? () {},
  saveCsv: (String csv, String name) => saved.add((csv: csv, name: name)),
);

bool _switchOn(WidgetTester tester) =>
    tester.widget<Switch>(find.byKey(const Key('logs-mask'))).value;

/// Lignes de données d'un CSV (sans BOM, en-tête ni ligne finale vide).
List<String> _csvRows(String csv) {
  final List<String> lines = csv.substring(1).split('\n');
  return lines.sublist(1, lines.length - 1);
}

const String _logHeader =
    '"at";"username";"type";"action";"detail";"success";"ip";"ua";"sid"';

void main() {
  group('Journal', () {
    testWidgets('1re lecture sans filtre ; colonnes v2 : réussite, IP, '
        'user-agent, session courte ; bascule éteinte, aucune pastille', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync()
        ..logs = (_LogCall c) => LogPage(
          items: <LogEntry>[
            _entry(0),
            _entry(1, success: false, ua: null, sid: null),
            _entry(2, type: 'action', success: null, ip: null, sid: null),
          ],
          total: 3,
        );
      await _pumpTab(tester, _journal(sync, <_Saved>[]));
      expect(sync.logCalls, <_LogCall>[
        (page: 0, pageSize: 100, source: 'all', masquer: false),
      ]);
      expect(_switchOn(tester), isFalse);
      expect(find.text(kLogsMaskToggleLabel), findsOneWidget);
      expect(find.byKey(const Key('logs-masked-count')), findsNothing);
      expect(find.byKey(const Key('logs-filter-unavailable')), findsNothing);
      expect(find.text('Page 1 / 1 (1–3 sur 3)'), findsOneWidget);

      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(find.byIcon(Icons.cancel_rounded), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('logs-ok-2')),
          matching: find.byType(Icon),
        ),
        findsNothing,
      );
      String cell(String key) =>
          shownText(tester, find.byKey(ValueKey<String>(key)));
      expect(cell('logs-ip-0'), '203.0.113.7');
      expect(cell('logs-ip-2'), '—');
      expect(cell('logs-ua-0'), 'Navigateur/1.0');
      expect(cell('logs-ua-1'), '—');
      expect(cell('logs-sid-0'), '01234567');
      expect(cell('logs-sid-1'), '');
      expect(cell('logs-detail-1'), 'détail neutre 1');
      expect(find.text(_sid), findsNothing);
    });

    testWidgets('textes NON FIABLES (login, détail, user-agent) : '
        'UntrustedLine, caractères cachés rendus visibles', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync()
        ..logs = (_LogCall c) => LogPage(
          items: <LogEntry>[
            _entry(
              0,
              username: 'compte${_rlo}exemple',
              detail: 'motif${_zwsp}neutre',
              ua: 'Agent${_tab}1.0',
            ),
          ],
          total: 1,
        );
      await _pumpTab(tester, _journal(sync, <_Saved>[]));
      for (final (String key, String token) in <(String, String)>[
        ('logs-user-0', '⟦U+202E⟧'),
        ('logs-detail-0', '⟦U+200B⟧'),
        ('logs-ua-0', '⟦TAB⟧'),
      ]) {
        final Finder f = find.byKey(ValueKey<String>(key));
        expect(
          find.descendant(of: f, matching: find.byType(UntrustedLine)),
          findsOneWidget,
        );
        final String shown = shownText(tester, f);
        expect(shown, contains(token), reason: key);
      }
      final String user = shownText(
        tester,
        find.byKey(const ValueKey<String>('logs-user-0')),
      );
      expect(user, isNot(contains(_rlo)));
      // Action (route) : même rendu.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('logs-action-0')),
          matching: find.byType(UntrustedLine),
        ),
        findsOneWidget,
      );
    });

    testWidgets('bascule allumée → masquer: true, « N lignes masquées » ; '
        'pagination et source suivent la bascule ; éteinte → retour', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync()
        ..logs = (_LogCall c) => c.masquer
            ? LogPage(
                items: <LogEntry>[_entry(0), _entry(1)],
                total: 150,
                masquees: 37,
                filtreApplique: true,
              )
            : LogPage(items: <LogEntry>[_entry(0)], total: 1);
      await _pumpTab(tester, _journal(sync, <_Saved>[]));
      expect(find.byKey(const Key('logs-masked-count')), findsNothing);

      await tester.tap(find.byKey(const Key('logs-mask')));
      await tester.pumpAndSettle();
      expect(_switchOn(tester), isTrue);
      expect(sync.logCalls.last, (
        page: 0,
        pageSize: 100,
        source: 'all',
        masquer: true,
      ));
      expect(
        shownText(tester, find.byKey(const Key('logs-masked-count'))),
        '37 lignes masquées',
      );
      expect(find.text('Page 1 / 2 (1–100 sur 150)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('moderation-page-next')));
      await tester.pumpAndSettle();
      expect(sync.logCalls.last, (
        page: 1,
        pageSize: 100,
        source: 'all',
        masquer: true,
      ));

      await tester.tap(find.text('Connexions'));
      await tester.pumpAndSettle();
      expect(sync.logCalls.last, (
        page: 0,
        pageSize: 100,
        source: 'auth',
        masquer: true,
      ));

      await tester.tap(find.byKey(const Key('logs-mask')));
      await tester.pumpAndSettle();
      expect(_switchOn(tester), isFalse);
      expect(sync.logCalls.last, (
        page: 0,
        pageSize: 100,
        source: 'auth',
        masquer: false,
      ));
      expect(find.byKey(const Key('logs-masked-count')), findsNothing);
      expect(find.text('Page 1 / 1 (1–1 sur 1)'), findsOneWidget);
    });

    testWidgets('filtre demandé mais filtre_applique faux → « Filtre '
        'indisponible : tout est affiché »', (WidgetTester tester) async {
      final _FakeSync sync = _FakeSync()
        ..logs = (_LogCall c) =>
            LogPage(items: <LogEntry>[_entry(0), _entry(1)], total: 2);
      await _pumpTab(tester, _journal(sync, <_Saved>[]));
      // Bascule éteinte : rien à signaler.
      expect(find.text(kLogsFilterUnavailable), findsNothing);

      await tester.tap(find.byKey(const Key('logs-mask')));
      await tester.pumpAndSettle();
      expect(sync.logCalls.last.masquer, isTrue);
      expect(find.text(kLogsFilterUnavailable), findsOneWidget);
      expect(find.byKey(const Key('logs-masked-count')), findsNothing);
      expect(find.text('Page 1 / 1 (1–2 sur 2)'), findsOneWidget);
    });

    testWidgets('journal vide → message ; erreur → bandeau + Réessayer', (
      WidgetTester tester,
    ) async {
      final _FakeSync sync = _FakeSync();
      await _pumpTab(tester, _journal(sync, <_Saved>[]));
      expect(find.byKey(const Key('logs-empty')), findsOneWidget);

      int n = 0;
      final _FakeSync failing = _FakeSync()
        ..logs = (_LogCall c) => n++ == 0
            ? throw const AdminApiException(200, _illisible)
            : LogPage(items: <LogEntry>[_entry(0)], total: 1);
      await _pumpTab(
        tester,
        _journal(failing, <_Saved>[], key: const Key('b')),
      );
      expect(
        shownText(tester, find.byKey(const Key('moderation-tab-error'))),
        _illisible,
      );
      await tester.tap(find.byKey(const Key('moderation-tab-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('moderation-tab-error')), findsNothing);
      expect(find.byKey(const ValueKey<String>('logs-row-0')), findsOneWidget);
    });

    testWidgets('total qui DIMINUE pendant la consultation : page au-delà de '
        'la fin → dernière page qui existe ; message « vide » seulement pour '
        'un total nul', (WidgetTester tester) async {
      int total = 250;
      final _FakeSync sync = _FakeSync()
        ..logs = (_LogCall c) => LogPage(
          items: c.page * c.pageSize < total
              ? <LogEntry>[_entry(c.page * c.pageSize)]
              : const <LogEntry>[],
          total: total,
        );
      await _pumpTab(tester, _journal(sync, <_Saved>[]));
      await tester.tap(find.byKey(const Key('moderation-page-last')));
      await tester.pumpAndSettle();
      expect(find.text('Page 3 / 3 (201–250 sur 250)'), findsOneWidget);

      // Lignes archivées ou purgées : la page 3 n'existe plus.
      total = 120;
      int before = sync.logCalls.length;
      await tester.tap(find.byKey(const Key('logs-refresh')));
      await tester.pumpAndSettle();
      expect(
        sync.logCalls.sublist(before).map((_LogCall c) => c.page),
        <int>[2, 1],
      );
      expect(find.text('Page 2 / 2 (101–120 sur 120)'), findsOneWidget);
      expect(find.byKey(const Key('logs-empty')), findsNothing);
      expect(find.byKey(const ValueKey<String>('logs-row-0')), findsOneWidget);

      // Plus aucune ligne : vrai message « vide ».
      total = 0;
      before = sync.logCalls.length;
      await tester.tap(find.byKey(const Key('logs-refresh')));
      await tester.pumpAndSettle();
      expect(
        sync.logCalls.sublist(before).map((_LogCall c) => c.page),
        <int>[1],
      );
      expect(find.byKey(const Key('logs-empty')), findsOneWidget);
      expect(find.byKey(const Key('moderation-page-label')), findsNothing);
    });

    testWidgets('bascule dont le chargement ÉCHOUE puis « Réessayer » : page 1 '
        'du NOUVEAU filtre, pas l\'ancienne page', (WidgetTester tester) async {
      bool failNext = false;
      final _FakeSync sync = _FakeSync()
        ..logs = (_LogCall c) {
          if (failNext) {
            failNext = false;
            throw const AdminApiException(500, 'Erreur serveur.');
          }
          final int total = c.masquer ? 50 : 1000;
          return LogPage(
            items: c.page * c.pageSize < total
                ? <LogEntry>[_entry(c.page * c.pageSize)]
                : const <LogEntry>[],
            total: total,
            masquees: c.masquer ? 950 : 0,
            filtreApplique: c.masquer,
          );
        };
      await _pumpTab(tester, _journal(sync, <_Saved>[]));
      await tester.tap(find.byKey(const Key('moderation-page-last')));
      await tester.pumpAndSettle();
      expect(sync.logCalls.last.page, 9);

      failNext = true;
      await tester.tap(find.byKey(const Key('logs-mask')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('moderation-tab-error')), findsOneWidget);

      final int before = sync.logCalls.length;
      await tester.tap(find.byKey(const Key('moderation-tab-retry')));
      await tester.pumpAndSettle();
      expect(sync.logCalls.sublist(before), <_LogCall>[
        (page: 0, pageSize: 100, source: 'all', masquer: true),
      ]);
      expect(find.text('Page 1 / 1 (1–50 sur 50)'), findsOneWidget);
      expect(find.byKey(const Key('logs-empty')), findsNothing);
      expect(
        shownText(tester, find.byKey(const Key('logs-masked-count'))),
        '950 lignes masquées',
      );
    });

    testWidgets('source dont le chargement ÉCHOUE puis « Rafraîchir » : page '
        '1 de la NOUVELLE source, pas l\'ancienne page', (
      WidgetTester tester,
    ) async {
      bool failNext = false;
      final _FakeSync sync = _FakeSync()
        ..logs = (_LogCall c) {
          if (failNext) {
            failNext = false;
            throw const AdminApiException(500, 'Erreur serveur.');
          }
          final int total = c.source == 'auth' ? 30 : 1000;
          return LogPage(
            items: c.page * c.pageSize < total
                ? <LogEntry>[_entry(c.page * c.pageSize)]
                : const <LogEntry>[],
            total: total,
          );
        };
      await _pumpTab(tester, _journal(sync, <_Saved>[]));
      await tester.tap(find.byKey(const Key('moderation-page-last')));
      await tester.pumpAndSettle();
      expect(sync.logCalls.last.page, 9);

      failNext = true;
      await tester.tap(find.text('Connexions'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('moderation-tab-error')), findsOneWidget);

      final int before = sync.logCalls.length;
      await tester.tap(find.byKey(const Key('logs-refresh')));
      await tester.pumpAndSettle();
      expect(sync.logCalls.sublist(before), <_LogCall>[
        (page: 0, pageSize: 100, source: 'auth', masquer: false),
      ]);
      expect(find.text('Page 1 / 1 (1–30 sur 30)'), findsOneWidget);
      expect(find.byKey(const Key('logs-empty')), findsNothing);
    });

    testWidgets('403 → état réservé (archives cachées) ; 401 → '
        'déconnexion', (WidgetTester tester) async {
      final _FakeSync forbidden = _FakeSync()
        ..logs = (_LogCall c) =>
            throw const AdminForbiddenException('Accès réservé.');
      await _pumpTab(tester, _journal(forbidden, <_Saved>[]));
      expect(find.byKey(const Key('logs-forbidden')), findsOneWidget);
      expect(find.text('Archives du journal'), findsNothing);

      int logouts = 0;
      final _FakeSync expired = _FakeSync()
        ..logs = (_LogCall c) =>
            throw const AdminAuthException('Non autorisé.');
      await _pumpTab(
        tester,
        _journal(
          expired,
          <_Saved>[],
          onAuthError: () => logouts++,
          key: const Key('c'),
        ),
      );
      expect(logouts, 1);
    });
  });

  group('Archives', () {
    const Key downloadKey = ValueKey<String>(
      'logs-archive-download-archive_exemple',
    );

    /// Serveur factice : [rows] lignes de journal, une archive.
    _FakeSync archiveSync({int rows = 1}) => _FakeSync()
      ..logs = ((_LogCall c) => LogPage(
        items: <LogEntry>[
          for (int n = c.page * c.pageSize; n < rows; n++)
            if (n < (c.page + 1) * c.pageSize) _entry(n),
        ],
        total: rows,
      ))
      ..archives = (() => <Map<String, dynamic>>[
        <String, dynamic>{
          'table_name': 'archive_exemple',
          'period_label': 'Septembre 2026',
          'rows_count': 1,
          'created_at': '2026-10-01T04:37:00+00:00',
        },
      ])
      ..archive = (String table) => <LogEntry>[_entry(0)];

    /// Lance le téléchargement (retenu par `archiveGate`).
    Future<void> startDownload(WidgetTester tester, _FakeSync sync) async {
      sync.archiveGate = Completer<void>();
      await tester.tap(find.byKey(downloadKey));
      await tester.pump();
      expect(sync.downloads, <String>['archive_exemple']);
      // Indicateur à la place du bouton (pas de pumpAndSettle : il tourne).
      expect(find.byKey(downloadKey), findsNothing);
    }

    /// Libère le téléchargement et laisse l'enregistrement se faire.
    Future<void> finishDownload(WidgetTester tester, _FakeSync sync) async {
      sync.archiveGate!.complete();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('listées et téléchargées en CSV : colonnes v2 remplies si '
        'l\'archive les a, vides sinon ; AUCUN bouton de suppression', (
      WidgetTester tester,
    ) async {
      final List<_Saved> saved = <_Saved>[];
      final _FakeSync sync = archiveSync()
        ..archive = (String table) => <LogEntry>[
          // Archive d'avant 0098 : sans colonnes v2.
          LogEntry(
            type: 'auth',
            at: _t0,
            username: '@compte',
            action: 'connexion échouée',
            detail: 'détail',
          ),
          // Archive v2 : colonnes rendues.
          LogEntry(
            type: 'auth',
            at: _t0,
            username: 'compte-exemple',
            action: 'connexion échouée',
            detail: 'détail',
            success: false,
            ip: '203.0.113.7',
            ua: 'Navigateur/1.0',
            sid: _sid,
          ),
        ];
      await _pumpTab(tester, _journal(sync, saved));
      expect(
        find.byKey(const ValueKey<String>('logs-archive-archive_exemple')),
        findsOneWidget,
      );
      expect(find.text('Septembre 2026'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
      expect(find.byTooltip('Supprimer définitivement'), findsNothing);

      await tester.tap(find.byKey(downloadKey));
      await tester.pump();
      await tester.pump();
      expect(sync.downloads, <String>['archive_exemple']);
      expect(saved.single.name, startsWith('logs_archive_archive_exemple_'));
      expect(saved.single.name, endsWith('.csv'));
      expect(saved.single.csv, startsWith('﻿$_logHeader\n'));
      expect(_csvRows(saved.single.csv), <String>[
        '"${_t0.toIso8601String()}";"\'@compte";"auth";"connexion échouée";'
            '"détail";"";"";"";""',
        '"${_t0.toIso8601String()}";"compte-exemple";"auth";'
            '"connexion échouée";"détail";"false";"203.0.113.7";'
            '"Navigateur/1.0";"$_sid"',
      ]);
      expect(
        find.text('Archive « Septembre 2026 » exportée : 2 lignes.'),
        findsOneWidget,
      );
      await _drainSnacks(tester);
    });

    testWidgets('téléchargement en cours puis retour en haut (section hors de '
        'la vue) : fichier enregistré, liste lue UNE fois', (
      WidgetTester tester,
    ) async {
      final List<_Saved> saved = <_Saved>[];
      final _FakeSync sync = archiveSync(rows: 100);
      await _pumpTab(
        tester,
        _journal(sync, saved),
        size: const Size(1400, 900),
      );
      final Finder list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(downloadKey),
        600,
        scrollable: list,
      );
      await tester.pump();
      await startDownload(tester, sync);

      // Retour en haut : la section sort de la vue et de la zone construite.
      tester.state<ScrollableState>(list).position.jumpTo(0);
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('logs-row-0')), findsOneWidget);
      expect(find.text('Archives du journal'), findsNothing);

      await finishDownload(tester, sync);
      expect(saved.length, 1);
      expect(saved.single.name, startsWith('logs_archive_archive_exemple_'));

      // Retour aux archives : même état, aucune relecture de la liste.
      await tester.scrollUntilVisible(
        find.byKey(downloadKey),
        600,
        scrollable: list,
      );
      await tester.pump();
      expect(sync.archiveListCalls, 1);
      await _drainSnacks(tester);
    });

    testWidgets('téléchargement en cours puis « Rafraîchir » du journal en '
        'ÉCHEC (bandeau au-dessus) : fichier enregistré, liste lue UNE '
        'fois', (WidgetTester tester) async {
      final List<_Saved> saved = <_Saved>[];
      int n = 0;
      final _FakeSync sync = archiveSync()
        ..logs = (_LogCall c) => n++ == 0
            ? LogPage(items: <LogEntry>[_entry(0)], total: 1)
            : throw const AdminApiException(500, 'Erreur serveur.');
      await _pumpTab(tester, _journal(sync, saved));
      await startDownload(tester, sync);

      await tester.tap(find.byKey(const Key('logs-refresh')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('moderation-tab-error')), findsOneWidget);

      await finishDownload(tester, sync);
      expect(saved.length, 1);
      expect(sync.archiveListCalls, 1);
      await _drainSnacks(tester);
    });

    testWidgets('téléchargement en cours puis source « Connexions » VIDE : '
        'fichier enregistré, liste lue UNE fois', (WidgetTester tester) async {
      final List<_Saved> saved = <_Saved>[];
      final _FakeSync sync = archiveSync()
        ..logs = (_LogCall c) => c.source == 'auth'
            ? const LogPage(items: <LogEntry>[], total: 0)
            : LogPage(items: <LogEntry>[_entry(0)], total: 1);
      await _pumpTab(tester, _journal(sync, saved));
      await startDownload(tester, sync);

      await tester.tap(find.text('Connexions'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('logs-empty')), findsOneWidget);

      await finishDownload(tester, sync);
      expect(saved.length, 1);
      expect(sync.archiveListCalls, 1);
      await _drainSnacks(tester);
    });

    testWidgets('section DÉMONTÉE pendant le téléchargement (menu quitté) : '
        'fichier enregistré quand même, aucun message', (
      WidgetTester tester,
    ) async {
      final List<_Saved> saved = <_Saved>[];
      final _FakeSync sync = archiveSync();
      await _pumpTab(tester, _journal(sync, saved));
      await startDownload(tester, sync);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      expect(find.text('Archives du journal'), findsNothing);

      await finishDownload(tester, sync);
      expect(saved.length, 1);
      expect(saved.single.name, startsWith('logs_archive_archive_exemple_'));
      expect(find.textContaining('exportée'), findsNothing);
    });
  });

  group('Export du journal', () {
    testWidgets('page : CSV neutralisé de la page affichée, colonnes v2', (
      WidgetTester tester,
    ) async {
      final List<_Saved> saved = <_Saved>[];
      final _FakeSync sync = _FakeSync()
        ..logs = (_LogCall c) => LogPage(
          items: <LogEntry>[_entry(0, detail: '=1+1'), _entry(1)],
          total: 2,
        );
      await _pumpTab(tester, _journal(sync, saved));
      await _export(tester, 'logs-export-page');
      expect(sync.logCalls.length, 1); // aucune lecture de plus
      expect(saved.single.name, startsWith('logs_page_1_'));
      expect(saved.single.csv, startsWith('﻿$_logHeader\n'));
      final List<String> rows = _csvRows(saved.single.csv);
      expect(rows.length, 2);
      expect(
        rows.first,
        '"${_entry(0).at!.toIso8601String()}";"compte-exemple";"auth";'
        '"connexion réussie";"\'=1+1";"true";"203.0.113.7";'
        '"Navigateur/1.0";"$_sid"',
      );
    });

    testWidgets('tout : suit la bascule (masquer: true, pages de 500) ; '
        'borne stable sur des pages qui se décalent', (
      WidgetTester tester,
    ) async {
      final List<_Saved> saved = <_Saved>[];
      final List<LogEntry> rows = <LogEntry>[
        for (int n = 0; n < 600; n++) _entry(n),
      ];
      final _FakeSync sync = _FakeSync()
        ..logs = (_LogCall c) {
          if (c.pageSize == kLogsExportChunk && c.page == 1) {
            // Deux connexions arrivent pendant l'export : la page 1 se
            // décale de 2 (deux lignes déjà lues reviennent).
            rows.insertAll(0, <LogEntry>[_entry(-2), _entry(-1)]);
          }
          return LogPage(
            items: rows.skip(c.page * c.pageSize).take(c.pageSize).toList(),
            total: rows.length,
            masquees: 12,
            filtreApplique: c.masquer,
          );
        };
      await _pumpTab(tester, _journal(sync, saved));
      await tester.tap(find.byKey(const Key('logs-mask')));
      await tester.pumpAndSettle();

      await _export(tester, 'logs-export-all');
      await tester.pumpAndSettle();
      final List<_LogCall> exportCalls = sync.logCalls
          .where((_LogCall c) => c.pageSize == kLogsExportChunk)
          .toList();
      expect(exportCalls, <_LogCall>[
        (page: 0, pageSize: 500, source: 'all', masquer: true),
        (page: 1, pageSize: 500, source: 'all', masquer: true),
      ]);
      expect(saved.single.name, startsWith('logs_complets_filtre_'));
      final List<String> csvRows = _csvRows(saved.single.csv);
      expect(csvRows.length, 600);
      expect(csvRows.toSet().length, 600); // aucun doublon
      expect(csvRows.first, contains('"détail neutre 0"'));
      expect(csvRows.last, contains('"détail neutre 599"'));
      expect(
        find.text('Export terminé : 600 lignes. 2 doublon(s) retiré(s).'),
        findsOneWidget,
      );
      await _drainSnacks(tester);
    });

    testWidgets('tout : filtre qui change d\'état pendant l\'export → '
        'message, aucun fichier', (WidgetTester tester) async {
      final List<_Saved> saved = <_Saved>[];
      final List<LogEntry> rows = <LogEntry>[
        for (int n = 0; n < 600; n++) _entry(n),
      ];
      final _FakeSync sync = _FakeSync()
        ..logs = (_LogCall c) => LogPage(
          items: rows.skip(c.page * c.pageSize).take(c.pageSize).toList(),
          total: rows.length,
          filtreApplique: c.masquer && !(c.pageSize == 500 && c.page == 1),
        );
      await _pumpTab(tester, _journal(sync, saved));
      await tester.tap(find.byKey(const Key('logs-mask')));
      await tester.pumpAndSettle();
      await _export(tester, 'logs-export-all');
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(find.text(ExportFilterChangedException.message), findsOneWidget);
      await _drainSnacks(tester);
    });

    testWidgets('tout : onglet DÉMONTÉ pendant l\'export (menu quitté) : '
        'fichier enregistré quand même', (WidgetTester tester) async {
      final List<_Saved> saved = <_Saved>[];
      final _FakeSync sync = _FakeSync()
        ..exportGate = Completer<void>()
        ..logs = (_LogCall c) =>
            LogPage(items: <LogEntry>[_entry(0)], total: 1);
      await _pumpTab(tester, _journal(sync, saved));
      await _export(tester, 'logs-export-all');
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      sync.exportGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(saved.length, 1);
      expect(saved.single.name, startsWith('logs_complets_'));
    });

    testWidgets('tout : 401 pendant l\'export → déconnexion, aucun fichier', (
      WidgetTester tester,
    ) async {
      final List<_Saved> saved = <_Saved>[];
      int logouts = 0;
      final _FakeSync sync = _FakeSync()
        ..logs = (_LogCall c) => c.pageSize == kLogsExportChunk
            ? throw const AdminAuthException('Non autorisé.')
            : LogPage(items: <LogEntry>[_entry(0)], total: 1);
      await _pumpTab(
        tester,
        _journal(sync, saved, onAuthError: () => logouts++),
      );
      await _export(tester, 'logs-export-all');
      await tester.pumpAndSettle();
      expect(logouts, 1);
      expect(saved, isEmpty);
    });
  });

  group('Tentatives', () {
    SecurityAttempt attempt({
      int occurrences = 1,
      DateTime? lastAt,
      String libelle = 'Libellé du serveur',
      String? route = 'admin-login',
      String? username = 'login-tape',
      String? ua = 'Agent/2.0',
      String? detail,
    }) => SecurityAttempt(
      at: _t0,
      lastAt: lastAt ?? _t0,
      occurrences: occurrences,
      genre: 'code_brut',
      libelle: libelle,
      route: route,
      username: username,
      ip: '198.51.100.4',
      ua: ua,
      detail: detail,
    );

    testWidgets('libellé du serveur, « ×N », « dernière : … » (regroupée et '
        'dates différentes seulement), textes non fiables', (
      WidgetTester tester,
    ) async {
      final DateTime later = _t0.add(const Duration(minutes: 3));
      final _FakeSync sync = _FakeSync()
        ..attempts = (int page) => SecurityAttemptPage(
          items: <SecurityAttempt>[
            attempt(
              occurrences: 3,
              lastAt: later,
              route: 'logs/${_zwsp}list',
              username: 'login$_rlo',
              detail: 'motif neutre',
            ),
            attempt(lastAt: later, libelle: 'Autre libellé'),
            attempt(occurrences: 2),
          ],
          total: 3,
        );
      await _pumpTab(tester, _attemptsTab(sync, <_Saved>[]));
      expect(sync.attemptCalls, <({int page, int pageSize})>[
        (page: 0, pageSize: 100),
      ]);
      String cell(String key) =>
          shownText(tester, find.byKey(ValueKey<String>(key)));
      expect(cell('logs-attempt-label-0'), 'Libellé du serveur');
      expect(cell('logs-attempt-label-1'), 'Autre libellé');
      expect(cell('logs-attempt-count-0'), '×3');
      expect(cell('logs-attempt-count-2'), '×2');
      expect(
        find.byKey(const ValueKey<String>('logs-attempt-count-1')),
        findsNothing,
      );
      expect(cell('logs-attempt-last-0'), 'dernière : ${formatLogDate(later)}');
      expect(
        find.byKey(const ValueKey<String>('logs-attempt-last-1')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('logs-attempt-last-2')),
        findsNothing,
      );
      expect(cell('logs-attempt-route-0'), contains('⟦U+200B⟧'));
      expect(cell('logs-attempt-user-0'), contains('⟦U+202E⟧'));
      expect(cell('logs-attempt-ip-0'), '198.51.100.4');
      expect(cell('logs-attempt-ua-0'), 'Agent/2.0');
      expect(cell('logs-attempt-detail-0'), 'motif neutre');
      expect(cell('logs-attempt-detail-1'), '—');
      for (final String k in <String>[
        'logs-attempt-route-0',
        'logs-attempt-user-0',
        'logs-attempt-ua-0',
        'logs-attempt-detail-0',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey<String>(k)),
            matching: find.byType(UntrustedLine),
          ),
          findsOneWidget,
          reason: k,
        );
      }
      // Le code brut n'est jamais affiché.
      expect(find.textContaining('code_brut'), findsNothing);
    });

    testWidgets('pagination ; vide → message', (WidgetTester tester) async {
      final _FakeSync sync = _FakeSync()
        ..attempts = (int page) => SecurityAttemptPage(
          items: <SecurityAttempt>[attempt()],
          total: 250,
        );
      await _pumpTab(tester, _attemptsTab(sync, <_Saved>[]));
      expect(find.text('Page 1 / 3 (1–100 sur 250)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('moderation-page-next')));
      await tester.pumpAndSettle();
      expect(sync.attemptCalls.last, (page: 1, pageSize: 100));
      expect(find.text('Page 2 / 3 (101–200 sur 250)'), findsOneWidget);

      await _pumpTab(
        tester,
        _attemptsTab(_FakeSync(), <_Saved>[], key: const Key('vide')),
      );
      expect(find.byKey(const Key('logs-attempts-empty')), findsOneWidget);
      expect(find.text(kAttemptsEmptyMessage), findsOneWidget);
    });

    testWidgets('total qui DIMINUE pendant la consultation : page au-delà de '
        'la fin → dernière page qui existe ; message « vide » seulement pour '
        'un total nul', (WidgetTester tester) async {
      int total = 250;
      final _FakeSync sync = _FakeSync()
        ..attempts = (int page) => SecurityAttemptPage(
          items: page * kLogsPageSize < total
              ? <SecurityAttempt>[attempt()]
              : const <SecurityAttempt>[],
          total: total,
        );
      await _pumpTab(tester, _attemptsTab(sync, <_Saved>[]));
      await tester.tap(find.byKey(const Key('moderation-page-last')));
      await tester.pumpAndSettle();
      expect(find.text('Page 3 / 3 (201–250 sur 250)'), findsOneWidget);

      // Archivage mensuel ou purge : la page 3 n'existe plus.
      total = 120;
      int before = sync.attemptCalls.length;
      await tester.tap(find.byKey(const Key('logs-attempts-refresh')));
      await tester.pumpAndSettle();
      expect(
        sync.attemptCalls
            .sublist(before)
            .map((({int page, int pageSize}) c) => c.page),
        <int>[2, 1],
      );
      expect(find.text('Page 2 / 2 (101–120 sur 120)'), findsOneWidget);
      expect(find.byKey(const Key('logs-attempts-empty')), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('logs-attempt-0')),
        findsOneWidget,
      );

      // Plus aucune tentative : vrai message « vide ».
      total = 0;
      before = sync.attemptCalls.length;
      await tester.tap(find.byKey(const Key('logs-attempts-refresh')));
      await tester.pumpAndSettle();
      expect(
        sync.attemptCalls
            .sublist(before)
            .map((({int page, int pageSize}) c) => c.page),
        <int>[1],
      );
      expect(find.byKey(const Key('logs-attempts-empty')), findsOneWidget);
      expect(find.byKey(const Key('moderation-page-label')), findsNothing);
    });

    testWidgets('page suivante en ÉCHEC puis « Réessayer » : la page DEMANDÉE '
        'est relue', (WidgetTester tester) async {
      bool failNext = false;
      final _FakeSync sync = _FakeSync()
        ..attempts = (int page) {
          if (failNext) {
            failNext = false;
            throw const AdminApiException(500, 'Erreur serveur.');
          }
          return SecurityAttemptPage(
            items: <SecurityAttempt>[attempt()],
            total: 250,
          );
        };
      await _pumpTab(tester, _attemptsTab(sync, <_Saved>[]));
      failNext = true;
      await tester.tap(find.byKey(const Key('moderation-page-next')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('moderation-tab-error')), findsOneWidget);

      final int before = sync.attemptCalls.length;
      await tester.tap(find.byKey(const Key('moderation-tab-retry')));
      await tester.pumpAndSettle();
      expect(sync.attemptCalls.sublist(before), <({int page, int pageSize})>[
        (page: 1, pageSize: 100),
      ]);
      expect(find.text('Page 2 / 3 (101–200 sur 250)'), findsOneWidget);
    });

    testWidgets('403 → état réservé ; 401 → déconnexion', (
      WidgetTester tester,
    ) async {
      final _FakeSync forbidden = _FakeSync()
        ..attempts = (int page) =>
            throw const AdminForbiddenException('Accès réservé.');
      await _pumpTab(tester, _attemptsTab(forbidden, <_Saved>[]));
      expect(find.byKey(const Key('logs-forbidden')), findsOneWidget);

      int logouts = 0;
      final _FakeSync expired = _FakeSync()
        ..attempts = (int page) =>
            throw const AdminAuthException('Non autorisé.');
      await _pumpTab(
        tester,
        _attemptsTab(
          expired,
          <_Saved>[],
          onAuthError: () => logouts++,
          key: const Key('c'),
        ),
      );
      expect(logouts, 1);
    });

    testWidgets('export tout : onglet DÉMONTÉ pendant l\'export (menu '
        'quitté) : fichier enregistré quand même', (WidgetTester tester) async {
      final List<_Saved> saved = <_Saved>[];
      final _FakeSync sync = _FakeSync()
        ..exportGate = Completer<void>()
        ..attempts = (int page) =>
            SecurityAttemptPage(items: <SecurityAttempt>[attempt()], total: 1);
      await _pumpTab(tester, _attemptsTab(sync, saved));
      await _export(tester, 'logs-export-all');
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      sync.exportGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(saved.length, 1);
      expect(saved.single.name, startsWith('tentatives_completes_'));
    });

    testWidgets('export : page et tout (colonnes du serveur, cellules '
        'neutralisées)', (WidgetTester tester) async {
      final List<_Saved> saved = <_Saved>[];
      final _FakeSync sync = _FakeSync()
        ..attempts = (int page) => SecurityAttemptPage(
          items: page == 0
              ? <SecurityAttempt>[attempt(username: '=login', occurrences: 4)]
              : const <SecurityAttempt>[],
          total: 1,
        );
      await _pumpTab(tester, _attemptsTab(sync, saved));
      await _export(tester, 'logs-export-page');
      await _export(tester, 'logs-export-all');
      await tester.pumpAndSettle();
      expect(saved.length, 2);
      expect(saved[0].name, startsWith('tentatives_page_1_'));
      expect(saved[1].name, startsWith('tentatives_completes_'));
      for (final _Saved s in saved) {
        expect(
          s.csv,
          startsWith(
            '﻿"at";"last_at";"occurrences";"genre";"libelle";"route";'
            '"username";"ip";"ua";"detail"\n',
          ),
        );
        expect(_csvRows(s.csv), <String>[
          '"${_t0.toIso8601String()}";"${_t0.toIso8601String()}";"4";'
              '"code_brut";"Libellé du serveur";"admin-login";"\'=login";'
              '"198.51.100.4";"Agent/2.0";""',
        ]);
      }
      expect(
        sync.attemptCalls.where((({int page, int pageSize}) c) =>
            c.pageSize == kLogsExportChunk),
        <({int page, int pageSize})>[(page: 0, pageSize: 500)],
      );
      expect(find.text('Export terminé : 1 ligne.'), findsOneWidget);
      await _drainSnacks(tester);
    });
  });
}
