// AuthController en VM (P4d L3, D14) : seul garde-fou client gardé après le
// retrait du verrou local — UNE connexion à la fois (un double-clic ou une
// touche Entrée répétée pendant la requête ne part pas une 2e fois et
// reçoit le même résultat) ; message du serveur exposé par `error` ;
// fermeture par l'échéance du jeton (fin de session plafonnée par le
// serveur, D2) annoncée à l'écran de connexion, message effacé à la
// connexion suivante. Client HTTP simulé, adresses réservées (`.invalid`),
// jetons de test, aucun réseau.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mgt_admin/core/auth/auth_controller.dart';
import 'package:mgt_admin/core/auth/auth_service.dart';
import 'package:mgt_admin/core/auth/login_messages.dart';
import 'package:mgt_admin/data/local_storage.dart';

import 'support/http_fixtures.dart' show testJwt;

const String _endpoint = 'https://exemple.invalid/functions/v1/admin-login';

final List<http.Request> _seen = <http.Request>[];

/// Si posée, chaque requête attend sa fin (requête encore en vol).
Completer<void>? _gate;

http.Response Function(http.Request) _respond = _refus401;

http.Response _refus401(http.Request req) =>
    _json(<String, Object?>{'error': 'Identifiants incorrects.'}, 401);

http.Response _json(Object? body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const <String, String>{'content-type': 'application/json'},
);

AuthController _controller() => AuthController(
  AuthService(
    endpoint: _endpoint,
    client: MockClient((http.Request req) async {
      _seen.add(req);
      final Completer<void>? gate = _gate;
      if (gate != null) await gate.future;
      return _respond(req);
    }),
  ),
);

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() {
    browserLocalStorage.clear();
    _seen.clear();
    _gate = null;
    _respond = _refus401;
  });

  test('double-clic : 2e et 3e appels pendant la requête → une seule '
      'requête, même résultat', () async {
    final AuthController c = _controller();
    _gate = Completer<void>();
    final Future<bool> premier = c.login(username: 'u', password: 'p');
    final Future<bool> second = c.login(username: 'u', password: 'p');
    final Future<bool> troisieme = c.login(username: 'autre', password: 'x');
    await _settle();
    expect(c.isLoading, isTrue);
    expect(_seen, hasLength(1));
    expect(jsonDecode(_seen.single.body), <String, Object?>{
      'username': 'u',
      'password': 'p',
    });

    _gate!.complete();
    expect(await premier, isFalse);
    expect(await second, isFalse);
    expect(await troisieme, isFalse);
    expect(c.isLoading, isFalse);
    expect(c.error, kMessageIdentifiantsIncorrects);
    expect(_seen, hasLength(1));

    // Requête terminée : une nouvelle connexion repart.
    _gate = null;
    await c.login(username: 'u', password: 'p');
    expect(_seen, hasLength(2));
  });

  test('appel reçu pendant la notification du début de connexion : aucune '
      '2e requête', () async {
    final AuthController c = _controller();
    _gate = Completer<void>();
    final List<Future<bool>> relances = <Future<bool>>[];
    void ecouteur() {
      if (c.isLoading && relances.isEmpty) {
        relances.add(c.login(username: 'u', password: 'p'));
      }
    }

    c.addListener(ecouteur);
    final Future<bool> premier = c.login(username: 'u', password: 'p');
    expect(relances, hasLength(1));
    await _settle();
    expect(_seen, hasLength(1));
    _gate!.complete();
    expect(await premier, isFalse);
    expect(await relances.single, isFalse);
    expect(_seen, hasLength(1));
    c.removeListener(ecouteur);
  });

  test('429 : `error` porte le message du serveur, tel quel', () async {
    const String serveur = 'Trop de tentatives. Réessayez dans 17 minute(s).';
    _respond = (http.Request req) =>
        _json(<String, Object?>{'error': serveur}, 429);
    final AuthController c = _controller();
    expect(await c.login(username: 'u', password: 'p'), isFalse);
    expect(c.error, serveur);
  });

  test('champ vide : `error` porte le message local, aucune requête, '
      'connexion suivante possible (constat B01)', () async {
    final AuthController c = _controller();
    expect(await c.login(username: '', password: 'p'), isFalse);
    expect(c.error, kMessageChampsRequis);
    expect(c.isLoading, isFalse);
    expect(_seen, isEmpty);
    expect(await c.login(username: 'u', password: 'p'), isFalse);
    expect(c.error, kMessageIdentifiantsIncorrects);
    expect(_seen, hasLength(1));
  });

  testWidgets('fin de session par l\'échéance du jeton : message à l\'écran '
      'de connexion, effacé à la connexion suivante', (
    WidgetTester tester,
  ) async {
    final AuthController c = _controller();
    int notifications = 0;
    c.addListener(() => notifications++);
    final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Jeton frais plafonné par le serveur : exp bien avant iat + 2 h.
    c.refreshToken(
      testJwt(
        payload: <String, Object?>{
          'username': 'compte-test',
          'is_owner': false,
          'iat': now,
          'exp': now + 2,
          'auth_time': now + 2 - 12 * 3600,
        },
      ),
    );
    expect(c.isAuthenticated, isTrue);
    expect(c.error, isNull);
    final int avant = notifications;

    await tester.pump(const Duration(seconds: 3));
    expect(c.isAuthenticated, isFalse);
    expect(c.token, isNull);
    expect(c.error, kMessageSessionExpiree);
    expect(notifications, avant + 1);

    // Connexion suivante : le message d'échéance disparaît (remplacé par la
    // réponse du serveur).
    await tester.runAsync(() => c.login(username: 'u', password: 'p'));
    expect(c.error, kMessageIdentifiantsIncorrects);
  });
}
