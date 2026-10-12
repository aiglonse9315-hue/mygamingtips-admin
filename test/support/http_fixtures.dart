// Aide commune des tests VM de la couche d'accès (P4b-3, lot L2) : un
// SupabaseSync factice (adresses d'exemple, délais de rejeu NULS), une
// réponse JSON et l'exécution d'un appel avec un client HTTP simulé qui
// enregistre les requêtes. Aucune dépendance dart:html, aucun secret.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mgt_admin/data/supabase_sync.dart';

/// SupabaseSync pointé sur un domaine RÉSERVÉ (`.invalid`, RFC 6761 : une
/// requête partie hors du client simulé ne peut atteindre aucun serveur —
/// revue P4b-3, SEC-P4b3-09), rejeux immédiats (un 502 se teste sans
/// attendre 6 s).
SupabaseSync fakeSync() => SupabaseSync(
  supabaseUrl: 'https://exemple.invalid',
  anonKey: 'anon',
  catalogEndpoint: 'https://exemple.invalid/functions/v1/admin-catalog',
  adminToken: testJwt(),
  retryDelays: const [Duration.zero, Duration.zero],
);

/// Réponse JSON ([body] encodé) avec le statut [status].
http.Response jsonResponse(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

/// Exécute [fn] avec un MockClient qui ajoute chaque requête à [seen] puis
/// rend `respond(requête)` ([respond] peut lever, ex. `ClientException`).
Future<T> withMock<T>(
  List<http.Request> seen,
  http.Response Function(http.Request) respond,
  Future<T> Function() fn,
) {
  final MockClient client = MockClient((http.Request req) async {
    seen.add(req);
    return respond(req);
  });
  return http.runWithClient(fn, () => client);
}

/// Corps JSON décodé de la requête [req].
Object? bodyOf(http.Request req) => jsonDecode(req.body);

/// Vrai si la requête vise la route [route] de l'EF admin-catalog.
bool isRoute(http.Request req, String route) =>
    req.url.path.endsWith('/admin-catalog/$route');

/// Segment base64url sans remplissage de [json] (encodé en JSON).
String _segment(Object? json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

/// Jeton de TEST à 3 segments (signature factice) dont le payload porte
/// [payload] ; par défaut `exp` = maintenant + [validFor] (revue P4b-3,
/// SEC-P4b3-07 : seul un jeton à échéance future est transmis).
String testJwt({
  Duration validFor = const Duration(hours: 2),
  Map<String, Object?>? payload,
}) {
  final int exp = DateTime.now().add(validFor).millisecondsSinceEpoch ~/ 1000;
  return '${_segment(<String, Object?>{'alg': 'HS256', 'typ': 'JWT'})}.'
      '${_segment(payload ?? <String, Object?>{'username': 'test', 'exp': exp})}'
      '.signature';
}
