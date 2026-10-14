// Tests purs (VM) des modèles du menu « Log » (P4d L3) : LogEntry (colonnes
// v2 success / ip / ua / sid, lecture TOLÉRANTE : absentes ou d'un autre
// type → null ; anciens serveurs et archives), LogPage (masquees,
// filtre_applique, comptes absents ou invalides), SecurityAttempt (libellé
// du serveur, occurrences, « dernière » date) et SecurityAttemptPage.
// Données neutres ; aucune dépendance dart:html.

import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/models/log_entry.dart';
import 'package:mgt_admin/domain/models/security_attempt.dart';

Map<String, dynamic> _logJson([Map<String, dynamic> extra = const {}]) =>
    <String, dynamic>{
      'type': 'auth',
      'at': '2026-10-14T08:00:00.123456+00:00',
      'username': 'compte-exemple',
      'action': 'connexion réussie',
      'detail': 'ok (ip: 203.0.113.7)',
      ...extra,
    };

Map<String, dynamic> _attemptJson([Map<String, dynamic> extra = const {}]) =>
    <String, dynamic>{
      'at': '2026-10-14T07:00:00+00:00',
      'last_at': '2026-10-14T07:00:00+00:00',
      'occurrences': 1,
      'genre': 'code_brut',
      'libelle': 'Libellé du serveur',
      'route': 'admin-login',
      'username': 'login-tape',
      'ip': '198.51.100.4',
      'ua': 'Agent/2.0',
      'detail': null,
      ...extra,
    };

void main() {
  group('LogEntry', () {
    test('colonnes v2 lues', () {
      final LogEntry l = LogEntry.fromJson(
        _logJson(<String, dynamic>{
          'success': true,
          'ip': '203.0.113.7',
          'ua': 'Navigateur/1.0',
          'sid': '0123456789abcdef0123456789abcdef',
        }),
      );
      expect(l.type, 'auth');
      expect(l.isAuth, isTrue);
      expect(l.at, DateTime.utc(2026, 10, 14, 8, 0, 0, 123, 456));
      expect(l.username, 'compte-exemple');
      expect(l.success, isTrue);
      expect(l.ip, '203.0.113.7');
      expect(l.ua, 'Navigateur/1.0');
      expect(l.sid, '0123456789abcdef0123456789abcdef');
      final LogEntry failed = LogEntry.fromJson(
        _logJson(<String, dynamic>{'success': false}),
      );
      expect(failed.success, isFalse);
    });

    test('serveur d\'avant L2 / archive (5 colonnes) : v2 à null', () {
      final LogEntry l = LogEntry.fromJson(_logJson());
      expect(l.success, isNull);
      expect(l.ip, isNull);
      expect(l.ua, isNull);
      expect(l.sid, isNull);
    });

    test('valeurs v2 nulles ou d\'un autre type : null, jamais une erreur', () {
      final LogEntry l = LogEntry.fromJson(
        _logJson(<String, dynamic>{
          'success': 'true',
          'ip': 42,
          'ua': <String>['x'],
          'sid': null,
        }),
      );
      expect(l.success, isNull);
      expect(l.ip, isNull);
      expect(l.ua, isNull);
      expect(l.sid, isNull);
    });

    test('champs historiques absents : valeurs par défaut d\'avant L3', () {
      final LogEntry l = LogEntry.fromJson(<String, dynamic>{});
      expect(l.type, 'action');
      expect(l.isAuth, isFalse);
      expect(l.at, isNull);
      expect(l.username, '—');
      expect(l.action, '');
      expect(l.detail, '');
    });
  });

  group('LogPage', () {
    test('{logs, total, masquees, filtre_applique}', () {
      final LogPage p = LogPage.fromJson(<String, dynamic>{
        'logs': <Object?>[_logJson(), 'pas un objet', _logJson()],
        'total': 250,
        'masquees': 37,
        'filtre_applique': true,
      });
      expect(p.items.length, 2);
      expect(p.total, 250);
      expect(p.masquees, 37);
      expect(p.filtreApplique, isTrue);
    });

    test('serveur d\'avant L2 : masquees 0, filtre non appliqué', () {
      final LogPage p = LogPage.fromJson(<String, dynamic>{
        'logs': <Object?>[_logJson()],
        'total': 1,
      });
      expect(p.masquees, 0);
      expect(p.filtreApplique, isFalse);
    });

    test('comptes invalides : total → lignes reçues, masquees → 0 ; '
        'filtre_applique non booléen → faux', () {
      final LogPage p = LogPage.fromJson(<String, dynamic>{
        'logs': <Object?>[_logJson(), _logJson()],
        'total': '9',
        'masquees': -1,
        'filtre_applique': 'true',
      });
      expect(p.total, 2);
      expect(p.masquees, 0);
      expect(p.filtreApplique, isFalse);
    });
  });

  group('SecurityAttempt', () {
    test('lecture complète', () {
      final SecurityAttempt a = SecurityAttempt.fromJson(
        _attemptJson(<String, dynamic>{
          'occurrences': 5,
          'last_at': '2026-10-14T07:00:42+00:00',
          'detail': 'motif',
        }),
      );
      expect(a.at, DateTime.utc(2026, 10, 14, 7));
      expect(a.lastAt, DateTime.utc(2026, 10, 14, 7, 0, 42));
      expect(a.occurrences, 5);
      expect(a.genre, 'code_brut');
      expect(a.libelle, 'Libellé du serveur');
      expect(a.route, 'admin-login');
      expect(a.username, 'login-tape');
      expect(a.ip, '198.51.100.4');
      expect(a.ua, 'Agent/2.0');
      expect(a.detail, 'motif');
      expect(a.isGrouped, isTrue);
      expect(a.showLastAt, isTrue);
    });

    test('« dernière » seulement si regroupée ET dates différentes', () {
      // Une seule occurrence : jamais, même avec une autre date.
      expect(
        SecurityAttempt.fromJson(
          _attemptJson(<String, dynamic>{
            'last_at': '2026-10-14T07:05:00+00:00',
          }),
        ).showLastAt,
        isFalse,
      );
      // Regroupée, même instant (écrit autrement) : non.
      expect(
        SecurityAttempt.fromJson(
          _attemptJson(<String, dynamic>{
            'occurrences': 3,
            'last_at': '2026-10-14T09:00:00+02:00',
          }),
        ).showLastAt,
        isFalse,
      );
      // Regroupée, dernière date absente : non.
      expect(
        SecurityAttempt.fromJson(
          _attemptJson(<String, dynamic>{'occurrences': 3, 'last_at': null}),
        ).showLastAt,
        isFalse,
      );
    });

    test('valeurs absentes ou invalides : occurrences 1, libellé vide, '
        'textes null', () {
      final SecurityAttempt a = SecurityAttempt.fromJson(<String, dynamic>{
        'occurrences': 0,
        'libelle': 7,
        'route': null,
      });
      expect(a.at, isNull);
      expect(a.lastAt, isNull);
      expect(a.occurrences, 1);
      expect(a.isGrouped, isFalse);
      expect(a.libelle, '');
      expect(a.genre, isNull);
      expect(a.route, isNull);
      expect(a.username, isNull);
    });

    test('SecurityAttemptPage : {tentatives, total}', () {
      final SecurityAttemptPage p = SecurityAttemptPage.fromJson(
        <String, dynamic>{
          'tentatives': <Object?>[_attemptJson(), 3, _attemptJson()],
          'total': 120,
        },
      );
      expect(p.items.length, 2);
      expect(p.total, 120);
      expect(
        SecurityAttemptPage.fromJson(<String, dynamic>{
          'tentatives': <Object?>[_attemptJson()],
        }).total,
        1,
      );
    });
  });
}
