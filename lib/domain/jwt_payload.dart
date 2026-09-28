// Pur (VM) — lecture du payload d'un jeton de session (P4b-3, lot L3,
// conception §4.7, T14).
//
// Le serveur signe `btoa(JSON.stringify(payload))`
// (supabase/functions/admin-catalog/index.ts `makeJwt`,
// supabase/functions/admin-login/index.ts) : base64 STANDARD (`+`, `/`,
// `=`), et `btoa` code chaque caractère ≤ U+00FF sur UN octet (Latin-1).
// L'ancien décodage du panneau remplaçait `_` par `=` (au lieu de `/`) et
// refusait un nom de compte accentué (octets Latin-1 qui ne sont pas de
// l'UTF-8 valide) → jeton jugé « malformé » → déconnexion.
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM
// (`flutter test test/jwt_payload_test.dart`).
import 'dart:convert';
import 'dart:typed_data';

final RegExp _base64BodyRe = RegExp(r'^[A-Za-z0-9+/]+$');

/// Octets d'un segment base64 standard OU base64url (`-` → `+`, `_` → `/`),
/// remplissage `=` facultatif ; null si le segment est malformé.
Uint8List? _decodeSegment(String segment) {
  String s = segment.replaceAll('-', '+').replaceAll('_', '/');
  int end = s.length;
  while (end > 0 && s.codeUnitAt(end - 1) == 0x3D) {
    end--; // '='
  }
  s = s.substring(0, end);
  if (s.isEmpty || !_base64BodyRe.hasMatch(s) || s.length % 4 == 1) return null;
  try {
    return base64.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));
  } on FormatException {
    return null;
  }
}

/// Payload JSON d'un JWT (segment du milieu) : accepte base64 standard ET
/// base64url, complète le remplissage, décode en UTF-8 et, si ce n'est pas
/// de l'UTF-8 valide, en Latin-1 (`btoa` du serveur). null si le jeton n'a
/// pas 3 segments, si le segment est malformé ou si le JSON n'est pas un
/// objet.
Map<String, dynamic>? decodeJwtPayload(String jwt) {
  final List<String> parts = jwt.split('.');
  if (parts.length != 3) return null;
  final Uint8List? bytes = _decodeSegment(parts[1]);
  if (bytes == null) return null;
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = latin1.decode(bytes);
  }
  try {
    final Object? v = jsonDecode(text);
    return v is Map<String, dynamic> ? v : null;
  } on FormatException {
    return null;
  }
}

/// Vrai si [jwt] a un payload lisible ([decodeJwtPayload]) portant un `exp`
/// numérique fini situé APRÈS [now] (défaut : maintenant) — revue P4b-3,
/// SEC-P4b3-07. Un jeton sans `exp`, ou dont l'`exp` est illisible ou
/// passé, est refusé : le panneau n'accepte jamais une session sans
/// échéance (les jetons du serveur portent toujours `exp`).
bool isJwtUsable(String jwt, {DateTime? now}) {
  final Object? exp = decodeJwtPayload(jwt)?['exp'];
  if (exp is! num || !exp.isFinite) return false;
  final int nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  return exp > nowSeconds;
}
