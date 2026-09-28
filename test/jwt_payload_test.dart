// Tests purs (VM) du décodage du payload d'un jeton de session (P4b-3, lot
// L3, conception §4.7, T14) : base64 standard (`btoa` du serveur) ET
// base64url, remplissage facultatif, repli Latin-1 pour un nom accentué,
// jetons malformés → null. Jetons construits dans le test (aucun secret,
// signature factice).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/jwt_payload.dart';

const String _header = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9';

String _jwt(String payloadSegment) => '$_header.$payloadSegment.signature';

/// Payload dont l'encodage base64 contient `+`, `/` et du remplissage.
const Map<String, Object?> _claims = <String, Object?>{
  'username': '??>>~',
  'is_owner': true,
  'exp': 4102444800,
};

void main() {
  test('base64 standard avec « + », « / » et « = » (btoa du serveur)', () {
    final String seg = base64.encode(utf8.encode(jsonEncode(_claims)));
    expect(seg, contains('+'));
    expect(seg, contains('/'));
    expect(seg, endsWith('='));
    expect(decodeJwtPayload(_jwt(seg)), _claims);
  });

  test('base64url avec « _ » et « - »', () {
    final String seg = base64Url.encode(utf8.encode(jsonEncode(_claims)));
    expect(seg, contains('-'));
    expect(seg, contains('_'));
    expect(decodeJwtPayload(_jwt(seg)), _claims);
  });

  test('sans remplissage', () {
    final String seg = base64Url
        .encode(utf8.encode(jsonEncode(_claims)))
        .replaceAll('=', '');
    expect(seg, isNot(contains('=')));
    expect(decodeJwtPayload(_jwt(seg)), _claims);
  });

  test('payload Latin-1 (octet 0xE9, comme btoa d’un « é ») → « é »', () {
    final List<int> bytes = latin1.encode(
      '{"username":"${String.fromCharCode(0xE9)}","exp":1}',
    );
    expect(bytes, contains(0xE9));
    final Map<String, dynamic>? claims = decodeJwtPayload(
      _jwt(base64.encode(bytes)),
    );
    expect(claims, isNotNull);
    expect(claims!['username'], String.fromCharCode(0xE9));
    expect(claims['exp'], 1);
  });

  test('UTF-8 valide conservé', () {
    final String name =
        'Z${String.fromCharCode(0xE9)}${String.fromCharCode(0x4E2D)}';
    final String seg = base64Url.encode(
      utf8.encode(jsonEncode(<String, Object?>{'username': name})),
    );
    expect(decodeJwtPayload(_jwt(seg)), <String, Object?>{'username': name});
  });

  test('jetons malformés → null', () {
    final String seg = base64.encode(utf8.encode(jsonEncode(_claims)));
    // 2 ou 4 segments.
    expect(decodeJwtPayload('$_header.$seg'), isNull);
    expect(decodeJwtPayload('$_header.$seg.sig.x'), isNull);
    expect(decodeJwtPayload(''), isNull);
    // JSON qui n'est pas un objet.
    expect(decodeJwtPayload(_jwt(base64.encode(utf8.encode('[1,2]')))), isNull);
    expect(
      decodeJwtPayload(_jwt(base64.encode(utf8.encode('"texte"')))),
      isNull,
    );
    // Texte qui n'est pas du JSON.
    expect(
      decodeJwtPayload(_jwt(base64.encode(utf8.encode('pas du json')))),
      isNull,
    );
    // base64 invalide : caractères interdits, longueur impossible, vide.
    expect(decodeJwtPayload(_jwt('@@@@')), isNull);
    expect(decodeJwtPayload(_jwt('abcde')), isNull);
    expect(decodeJwtPayload(_jwt('')), isNull);
    expect(decodeJwtPayload(_jwt('====')), isNull);
  });

  group('isJwtUsable (revue P4b-3, SEC-P4b3-07)', () {
    final DateTime now = DateTime.utc(2026, 9, 28, 12);
    final int nowS = now.millisecondsSinceEpoch ~/ 1000;
    String withClaims(Map<String, Object?> c) =>
        _jwt(base64Url.encode(utf8.encode(jsonEncode(c))));

    test('exp futur → utilisable', () {
      expect(
        isJwtUsable(withClaims(<String, Object?>{'exp': nowS + 60}), now: now),
        isTrue,
      );
      expect(
        isJwtUsable(withClaims(<String, Object?>{'exp': nowS + 0.5}), now: now),
        isTrue,
      );
    });

    test('exp absent, non numérique, passé ou égal → refusé', () {
      expect(
        isJwtUsable(withClaims(<String, Object?>{'username': 'a'}), now: now),
        isFalse,
      );
      expect(
        isJwtUsable(withClaims(<String, Object?>{'exp': null}), now: now),
        isFalse,
      );
      expect(
        isJwtUsable(
          withClaims(<String, Object?>{'exp': '9999999999'}),
          now: now,
        ),
        isFalse,
      );
      expect(
        isJwtUsable(withClaims(<String, Object?>{'exp': nowS}), now: now),
        isFalse,
      );
      expect(
        isJwtUsable(withClaims(<String, Object?>{'exp': nowS - 1}), now: now),
        isFalse,
      );
    });

    test('exp infini (1e400) ou jeton illisible → refusé', () {
      final String inf = base64Url.encode(utf8.encode('{"exp":1e400}'));
      expect(isJwtUsable(_jwt(inf), now: now), isFalse);
      expect(isJwtUsable('a.b.c', now: now), isFalse);
      expect(isJwtUsable('', now: now), isFalse);
    });
  });
}
