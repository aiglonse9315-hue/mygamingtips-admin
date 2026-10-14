// Écran de connexion (P4d L3, D14) — tests de widget en VM, possibles
// depuis qu'AuthService n'importe plus dart:html. Vérifie : pendant la
// requête, bouton et champs désactivés et un 2e appui n'envoie rien (anti
// double-clic, seul garde-fou client) ; messages distincts affichés (429 :
// texte du serveur tel quel, 503, 400, réseau) ; plus jamais de compte à
// rebours ni de « tentative(s) restante(s) » (aucun verrou local) ; champ
// vide → aucune requête, message local (constat B01) ; succès → onSuccess. Client HTTP simulé, adresses réservées (`.invalid`), jetons
// de test, aucun réseau.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:mgt_admin/core/auth/auth_controller.dart';
import 'package:mgt_admin/core/auth/auth_service.dart';
import 'package:mgt_admin/core/auth/login_messages.dart';
import 'package:mgt_admin/data/local_storage.dart';
import 'package:mgt_admin/ui/screens/login_screen.dart';

import 'support/http_fixtures.dart' show testJwt;
import 'support/widget_fixtures.dart' show setWindow;

const String _endpoint = 'https://exemple.invalid/functions/v1/admin-login';

final List<http.Request> _seen = <http.Request>[];

/// Si posée, chaque requête attend sa fin (requête encore en vol).
Completer<void>? _gate;

http.Response Function(http.Request) _respond = (http.Request req) =>
    _json(<String, Object?>{'error': 'Identifiants incorrects.'}, 401);

http.Response _json(Object? body, int status) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const <String, String>{'content-type': 'application/json'},
);

/// Monte l'écran avec un contrôleur de PRODUCTION sur un client simulé.
Future<AuthController> _monter(
  WidgetTester tester, {
  VoidCallback? onSuccess,
}) async {
  setWindow(tester, const Size(800, 900));
  final AuthController auth = AuthController(
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
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthController>.value(
      value: auth,
      child: MaterialApp(home: LoginScreen(onSuccess: onSuccess ?? () {})),
    ),
  );
  return auth;
}

/// Saisit des identifiants de test et appuie sur « Connexion ».
Future<void> _connecter(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).at(0), 'compte-test');
  await tester.enterText(find.byType(TextField).at(1), 'mot-de-passe-test');
  await tester.tap(find.byType(OutlinedButton));
  await tester.pump();
}

/// Laisse finir la requête simulée et reconstruit l'écran.
Future<void> _finir(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump();
  }
}

OutlinedButton _bouton(WidgetTester tester) =>
    tester.widget<OutlinedButton>(find.byType(OutlinedButton));

void main() {
  setUp(() {
    browserLocalStorage.clear();
    _seen.clear();
    _gate = null;
    _respond = (http.Request req) =>
        _json(<String, Object?>{'error': 'Identifiants incorrects.'}, 401);
  });

  testWidgets('pendant la requête : bouton et champs désactivés, un 2e '
      'appui n\'envoie rien', (WidgetTester tester) async {
    await _monter(tester);
    _gate = Completer<void>();
    await _connecter(tester);

    expect(_seen, hasLength(1));
    expect(_bouton(tester).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    for (final TextField champ in tester.widgetList<TextField>(
      find.byType(TextField),
    )) {
      expect(champ.enabled, isFalse);
    }
    await tester.tap(find.byType(OutlinedButton), warnIfMissed: false);
    await tester.pump();
    expect(_seen, hasLength(1));

    _gate!.complete();
    await _finir(tester);
    expect(_bouton(tester).onPressed, isNotNull);
    expect(find.text(kMessageIdentifiantsIncorrects), findsOneWidget);
    expect(_seen, hasLength(1));
  });

  testWidgets('refus répétés : chaque appui part au serveur, jamais de '
      'compte à rebours ni de tentatives restantes', (
    WidgetTester tester,
  ) async {
    await _monter(tester);
    for (int i = 0; i < 5; i++) {
      await _connecter(tester); // champs remplis à chaque tour
      await _finir(tester);
      expect(find.text(kMessageIdentifiantsIncorrects), findsOneWidget);
    }
    expect(_seen, hasLength(5));
    expect(find.textContaining('restante'), findsNothing);
    expect(find.textContaining('bloqué'), findsNothing);
    expect(find.textContaining('secondes'), findsNothing);
  });

  testWidgets('champ vide (Entrée dans le mot de passe, bouton) ou '
      'identifiant fait d\'espaces : aucune requête, message local affiché', (
    WidgetTester tester,
  ) async {
    await _monter(tester);
    final Finder identifiant = find.byType(TextField).at(0);
    final Finder motDePasse = find.byType(TextField).at(1);

    // Entrée dans le mot de passe avant le remplissage automatique.
    await tester.enterText(identifiant, 'compte-test');
    await tester.enterText(motDePasse, ''); // place le focus
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _finir(tester);
    expect(find.text(kMessageChampsRequis), findsOneWidget);
    expect(_seen, isEmpty);

    // Champs remplis : la requête part, le message local est remplacé.
    await _connecter(tester);
    await _finir(tester);
    expect(_seen, hasLength(1));
    expect(find.text(kMessageChampsRequis), findsNothing);
    expect(find.text(kMessageIdentifiantsIncorrects), findsOneWidget);

    // Bouton, champs vides : rien ne part, le message du serveur est
    // remplacé par le message local (jamais « Requête refusée… »).
    await tester.enterText(identifiant, '');
    await tester.enterText(motDePasse, '');
    await tester.tap(find.byType(OutlinedButton));
    await _finir(tester);
    expect(find.text(kMessageChampsRequis), findsOneWidget);
    expect(find.text(kMessageIdentifiantsIncorrects), findsNothing);
    expect(find.text(kMessageRequeteRefusee), findsNothing);
    expect(_seen, hasLength(1));

    // Identifiant fait d'espaces, mot de passe rempli : rien ne part.
    await _connecter(tester);
    await _finir(tester);
    expect(_seen, hasLength(2));
    expect(find.text(kMessageIdentifiantsIncorrects), findsOneWidget);
    await tester.enterText(identifiant, '   ');
    await tester.enterText(motDePasse, 'mot-de-passe-test');
    await tester.tap(find.byType(OutlinedButton));
    await _finir(tester);
    expect(find.text(kMessageChampsRequis), findsOneWidget);
    expect(find.text(kMessageIdentifiantsIncorrects), findsNothing);
    expect(_seen, hasLength(2));
    expect(_bouton(tester).onPressed, isNotNull);
  });

  testWidgets('messages distincts : 429 du serveur tel quel, 503, 400, '
      'réseau', (WidgetTester tester) async {
    await _monter(tester);
    const String serveur = 'Trop de tentatives. Réessayez dans 17 minute(s).';
    final Map<String, http.Response Function(http.Request)> cas =
        <String, http.Response Function(http.Request)>{
          serveur: (http.Request req) =>
              _json(<String, Object?>{'error': serveur}, 429),
          kMessageServiceIndisponible: (http.Request req) => _json(
            <String, Object?>{'error': 'Service momentanément indisponible.'},
            503,
          ),
          kMessageRequeteRefusee: (http.Request req) =>
              _json(<String, Object?>{'error': 'Champs manquants.'}, 400),
          kMessageServeurInjoignable: (http.Request req) =>
              throw http.ClientException('XMLHttpRequest error.', req.url),
        };
    for (final MapEntry<String, http.Response Function(http.Request)> c
        in cas.entries) {
      _respond = c.value;
      await _connecter(tester);
      await _finir(tester);
      expect(find.text(c.key), findsOneWidget, reason: c.key);
      expect(find.text(kMessageIdentifiantsIncorrects), findsNothing);
    }
    expect(_seen, hasLength(4)); // l'erreur réseau est levée après l'envoi
  });

  testWidgets('succès : onSuccess appelé une fois, message effacé', (
    WidgetTester tester,
  ) async {
    int succes = 0;
    final AuthController auth = await _monter(
      tester,
      onSuccess: () => succes++,
    );
    await _connecter(tester);
    await _finir(tester);
    expect(find.text(kMessageIdentifiantsIncorrects), findsOneWidget);

    final int now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final String jeton = testJwt(
      payload: <String, Object?>{
        'username': 'compte-test',
        'is_owner': false,
        'iat': now,
        'exp': now + 7200,
      },
    );
    _respond = (http.Request req) =>
        _json(<String, Object?>{'token': jeton, 'is_owner': false}, 200);
    await _connecter(tester);
    await _finir(tester);
    expect(succes, 1);
    expect(auth.isAuthenticated, isTrue);
    expect(find.text(kMessageIdentifiantsIncorrects), findsNothing);
    auth.logout(); // arrête le minuteur d'échéance avant la fin du test
  });
}
