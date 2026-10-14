// AuthService en VM (P4d L3, D14 ; tools/PLAN_VISION2_P4d_CONCEPTION.md §4
// « L3 — CONTRAT ») : plus de dart:html (stockage par browserLocalStorage,
// client HTTP injecté). Vérifie :
// - aucun verrou local : chaque essai part au serveur, aucun compteur,
//   aucun « tentative(s) restante(s) », anciennes clés du verrou effacées
//   au démarrage (une session restaurée n'est plus purgée par elles) ;
// - messages distincts 401 / 429 (texte du serveur, UTF-8 même sans
//   charset) / 503 / 400 / réseau / délai / configuration absente ;
// - champ vide (identifiant vide ou fait d'espaces, mot de passe vide) :
//   aucune requête, message local fixe ; mot de passe jamais retouché ;
// - jeton déjà expiré ou illisible : aucune session ouverte ;
// - échéance suivie par l'`exp` du jeton SEUL : un jeton frais plafonné
//   par le serveur (exp avant iat + 2 h, D2) ferme la session à son exp ;
//   un iat ancien avec un exp futur garde la session ouverte.
// Adresses réservées (`.invalid`), jetons de test (signature factice),
// aucun secret, aucun réseau.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mgt_admin/core/auth/auth_service.dart';
import 'package:mgt_admin/core/auth/login_messages.dart';
import 'package:mgt_admin/data/local_storage.dart';

import 'support/http_fixtures.dart' show testJwt;

const String _endpoint = 'https://exemple.invalid/functions/v1/admin-login';
const String _cleJeton = 'mgt_admin_token';
const List<String> _anciennesCles = <String>[
  'mgt_admin_lock_until',
  'mgt_admin_fail_count',
];

/// Requêtes vues par le client simulé.
final List<http.Request> _seen = <http.Request>[];

/// Réponse du client simulé (peut lever : erreur réseau, délai).
http.Response Function(http.Request) _respond = (http.Request req) =>
    _json(<String, Object?>{'error': 'Identifiants incorrects.'}, 401);

AuthService _service({String endpoint = _endpoint}) => AuthService(
  endpoint: endpoint,
  client: MockClient((http.Request req) async {
    _seen.add(req);
    return _respond(req);
  }),
);

/// Réponse dont le corps est [body] encodé en JSON puis en UTF-8.
http.Response _json(
  Object? body,
  int status, {
  Map<String, String> headers = const <String, String>{
    'content-type': 'application/json',
  },
}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: headers,
);

int _maintenant() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Jeton au format du serveur depuis L2 (`sid`, `auth_time`), signature
/// factice.
String _jeton({
  required int iat,
  required int exp,
  int? authTime,
  bool owner = false,
}) => testJwt(
  payload: <String, Object?>{
    'role': 'admin',
    'username': 'compte-test',
    'is_owner': owner,
    'iat': iat,
    'exp': exp,
    'sid': '0123456789abcdef0123456789abcdef',
    'auth_time': authTime ?? iat,
  },
);

void main() {
  setUp(() {
    browserLocalStorage.clear();
    _seen.clear();
    _respond = (http.Request req) =>
        _json(<String, Object?>{'error': 'Identifiants incorrects.'}, 401);
  });

  group('Aucun verrou local (le serveur fait foi)', () {
    test('6 refus 401 de suite : 6 requêtes, même message, aucun compteur '
        'gardé', () async {
      final AuthService s = _service();
      for (int i = 0; i < 6; i++) {
        final AuthResult r = await s.login(username: 'u', password: 'p');
        expect(r.success, isFalse);
        expect(r.message, kMessageIdentifiantsIncorrects);
      }
      expect(_seen, hasLength(6));
      for (final String cle in _anciennesCles) {
        expect(browserLocalStorage.containsKey(cle), isFalse, reason: cle);
      }
      expect(browserLocalStorage, isEmpty);
    });

    test('après des refus, un bon essai passe aussitôt', () async {
      final AuthService s = _service();
      for (int i = 0; i < 4; i++) {
        await s.login(username: 'u', password: 'p');
      }
      final int now = _maintenant();
      final String jeton = _jeton(iat: now, exp: now + 7200);
      _respond = (http.Request req) =>
          _json(<String, Object?>{'token': jeton, 'is_owner': false}, 200);
      final AuthResult r = await s.login(username: 'u', password: 'p');
      expect(r.success, isTrue);
      expect(s.isAuthenticated, isTrue);
      expect(_seen, hasLength(5));
      s.logout();
    });

    test('anciennes clés du verrou (avant L3) effacées au démarrage ; la '
        'connexion part', () async {
      browserLocalStorage['mgt_admin_lock_until'] = DateTime.now()
          .add(const Duration(days: 1))
          .toIso8601String();
      browserLocalStorage['mgt_admin_fail_count'] = '9';
      final AuthService s = _service();
      for (final String cle in _anciennesCles) {
        expect(browserLocalStorage.containsKey(cle), isFalse, reason: cle);
      }
      await s.login(username: 'u', password: 'p');
      expect(_seen, hasLength(1));
    });

    test('session restaurée malgré un ancien verrou resté dans le '
        'navigateur', () {
      final int now = _maintenant();
      final String jeton = _jeton(iat: now, exp: now + 3600, owner: true);
      browserLocalStorage[_cleJeton] = jeton;
      browserLocalStorage['mgt_admin_lock_until'] = DateTime.now()
          .add(const Duration(days: 1))
          .toIso8601String();
      final AuthService s = _service()..restore();
      expect(s.isAuthenticated, isTrue);
      expect(s.token, jeton);
      expect(s.isOwner, isTrue);
      expect(s.username, 'compte-test');
      s.logout();
    });
  });

  group('Connexion réussie', () {
    test('jeton gardé, privilège et compte relus ; corps envoyé : '
        'username et password seulement', () async {
      final int now = _maintenant();
      final String jeton = _jeton(iat: now, exp: now + 7200, owner: true);
      _respond = (http.Request req) =>
          _json(<String, Object?>{'token': jeton, 'is_owner': true}, 200);
      final AuthService s = _service();
      final AuthResult r = await s.login(username: 'saisi', password: 'mdp');
      expect(r.success, isTrue);
      expect(r.message, isNull);
      expect(s.isAuthenticated, isTrue);
      expect(s.token, jeton);
      expect(browserLocalStorage[_cleJeton], jeton);
      expect(s.isOwner, isTrue);
      expect(s.username, 'compte-test'); // claim du jeton
      final http.Request req = _seen.single;
      expect(req.method, 'POST');
      expect(req.url.toString(), _endpoint);
      expect(jsonDecode(req.body), <String, Object?>{
        'username': 'saisi',
        'password': 'mdp',
      });
      s.logout();
      expect(browserLocalStorage.containsKey(_cleJeton), isFalse);
    });

    test('jeton reçu déjà expiré (horloge de l\'appareil en avance) : '
        'aucune session, message clair', () async {
      final int now = _maintenant();
      final String jeton = _jeton(iat: now - 7300, exp: now - 100);
      _respond = (http.Request req) =>
          _json(<String, Object?>{'token': jeton, 'is_owner': true}, 200);
      final AuthService s = _service();
      final AuthResult r = await s.login(username: 'u', password: 'p');
      expect(r.success, isFalse);
      expect(r.message, kMessageJetonDejaExpire);
      expect(s.isAuthenticated, isFalse);
      expect(s.token, isNull);
      expect(browserLocalStorage.containsKey(_cleJeton), isFalse);
    });

    test('200 sans jeton, ou jeton sans échéance → réponse inattendue',
        () async {
      final AuthService s = _service();
      for (final Object? corps in <Object?>[
        <String, Object?>{'is_owner': true},
        <String, Object?>{'token': ''},
        <String, Object?>{
          'token': testJwt(payload: <String, Object?>{'username': 'x'}),
        },
      ]) {
        _respond = (http.Request req) => _json(corps, 200);
        final AuthResult r = await s.login(username: 'u', password: 'p');
        expect(r.success, isFalse, reason: '$corps');
        expect(r.message, kMessageReponseInattendue, reason: '$corps');
        expect(s.isAuthenticated, isFalse);
      }
      expect(browserLocalStorage.containsKey(_cleJeton), isFalse);
    });
  });

  group('Refus : un message par cause', () {
    test('429 : message du serveur tel quel (UTF-8 même sans charset), '
        'Retry-After non lu', () async {
      const String serveur = 'Trop de tentatives. Réessayez dans 17 minute(s).';
      for (final String type in <String>[
        'application/json',
        'text/plain', // décodé en Latin-1 par défaut par le paquet http
      ]) {
        _respond = (http.Request req) => _json(
          <String, Object?>{'error': serveur},
          429,
          headers: <String, String>{'content-type': type, 'retry-after': '1'},
        );
        final AuthResult r = await _service().login(
          username: 'u',
          password: 'p',
        );
        expect(r.success, isFalse);
        expect(r.message, serveur, reason: type);
      }
    });

    test('503, 400, 403 et 502', () async {
      final Map<int, String> attendus = <int, String>{
        503: kMessageServiceIndisponible,
        400: kMessageRequeteRefusee,
        403: 'Refus détaillé du serveur.',
        502: kMessageServiceIndisponible,
      };
      for (final MapEntry<int, String> cas in attendus.entries) {
        _respond = (http.Request req) => _json(
          <String, Object?>{'error': 'Refus détaillé du serveur.'},
          cas.key,
        );
        final AuthResult r = await _service().login(
          username: 'u',
          password: 'p',
        );
        expect(r.message, cas.value, reason: '${cas.key}');
      }
    });

    test('erreur réseau (ClientException) → « Serveur injoignable. »',
        () async {
      _respond = (http.Request req) =>
          throw http.ClientException('XMLHttpRequest error.', req.url);
      final AuthService s = _service();
      final AuthResult r = await s.login(username: 'u', password: 'p');
      expect(r.message, kMessageServeurInjoignable);
      expect(s.log.last.success, isFalse);
    });

    test('délai dépassé (TimeoutException) → « Serveur injoignable. »',
        () async {
      _respond = (http.Request req) => throw TimeoutException('délai');
      final AuthResult r = await _service().login(username: 'u', password: 'p');
      expect(r.message, kMessageServeurInjoignable);
    });

    test('adresse d\'authentification absente → configuration requise, '
        'aucune requête', () async {
      final AuthResult r = await _service(
        endpoint: '',
      ).login(username: 'u', password: 'p');
      expect(r.success, isFalse);
      expect(r.message, kMessageConfigurationRequise);
      expect(_seen, isEmpty);
    });
  });

  group('Champ vide : rien envoyé, message local (constat B01)', () {
    test('identifiant vide, mot de passe vide, ou les deux → aucune '
        'requête, « Identifiant et mot de passe requis. »', () async {
      final AuthService s = _service();
      for (final (String, String) champs in <(String, String)>[
        ('', 'p'),
        ('u', ''),
        ('', ''),
      ]) {
        final AuthResult r = await s.login(
          username: champs.$1,
          password: champs.$2,
        );
        expect(r.success, isFalse, reason: '$champs');
        expect(r.message, kMessageChampsRequis, reason: '$champs');
        expect(s.isAuthenticated, isFalse);
        expect(s.log.last.success, isFalse);
      }
      expect(_seen, isEmpty);
      expect(browserLocalStorage, isEmpty);
    });

    test('identifiant fait d\'espaces (espace, tabulation, retour à la '
        'ligne) → aucune requête', () async {
      final AuthService s = _service();
      for (final String blanc in <String>[' ', '   ', '\t', ' \n ']) {
        final AuthResult r = await s.login(username: blanc, password: 'p');
        expect(r.message, kMessageChampsRequis, reason: '« $blanc »');
      }
      expect(_seen, isEmpty);
    });

    test('mot de passe fait d\'espaces : envoyé tel quel (jamais retouché), '
        'identifiant non vide envoyé tel quel', () async {
      final AuthResult r = await _service().login(
        username: ' saisi ',
        password: '   ',
      );
      expect(r.message, kMessageIdentifiantsIncorrects);
      expect(jsonDecode(_seen.single.body), <String, Object?>{
        'username': ' saisi ',
        'password': '   ',
      });
    });

    test('adresse absente ET champs vides → configuration requise (adresse '
        'vérifiée d\'abord), aucune requête', () async {
      final AuthResult r = await _service(
        endpoint: '',
      ).login(username: '', password: '');
      expect(r.message, kMessageConfigurationRequise);
      expect(_seen, isEmpty);
    });
  });

  group('Échéance : seul l\'exp du jeton compte (D2)', () {
    test('restore : jeton expiré purgé', () {
      final int now = _maintenant();
      browserLocalStorage[_cleJeton] = _jeton(iat: now - 7300, exp: now - 100);
      final AuthService s = _service()..restore();
      expect(s.isAuthenticated, isFalse);
      expect(browserLocalStorage.containsKey(_cleJeton), isFalse);
    });

    test('iat vieux de 3 h mais exp futur → session ouverte (aucune durée '
        'codée)', () {
      final int now = _maintenant();
      final AuthService s = _service()
        ..refreshToken(_jeton(iat: now - 3 * 3600, exp: now + 600));
      expect(s.isAuthenticated, isTrue);
      s.logout();
    });

    test('jeton frais plafonné, exp déjà passé alors que iat + 2 h est '
        'futur → déconnexion immédiate, une seule fois', () {
      final int now = _maintenant();
      int expirations = 0;
      final AuthService s = _service()..onTokenExpired = () => expirations++;
      s.refreshToken(
        _jeton(iat: now, exp: now - 1, authTime: now - 12 * 3600 - 1),
      );
      expect(s.isAuthenticated, isFalse);
      expect(s.token, isNull);
      expect(expirations, 1);
      expect(browserLocalStorage.containsKey(_cleJeton), isFalse);
    });

    testWidgets('jeton frais plafonné (exp = iat + 3 s, bien avant iat + 2 h) '
        ': session fermée à son exp par le minuteur', (
      WidgetTester tester,
    ) async {
      final int now = _maintenant();
      int expirations = 0;
      final AuthService s = _service()..onTokenExpired = () => expirations++;
      s.refreshToken(
        _jeton(iat: now, exp: now + 3, authTime: now + 3 - 12 * 3600),
      );
      expect(s.isAuthenticated, isTrue);

      await tester.pump(const Duration(seconds: 1));
      expect(expirations, 0);
      expect(s.token, isNotNull);

      await tester.pump(const Duration(seconds: 3));
      expect(expirations, 1);
      expect(s.isAuthenticated, isFalse);
      expect(s.token, isNull);
      expect(browserLocalStorage.containsKey(_cleJeton), isFalse);
    });
  });
}
