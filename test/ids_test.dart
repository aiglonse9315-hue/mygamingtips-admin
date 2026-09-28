// Tests purs (VM) des identifiants (P4b-3, lot L2) : UUID Supabase, id
// temporaire de jeu « g-<ms> », forme courte d'affichage. Aucune
// dépendance dart:html.

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/ids.dart';

void main() {
  group('isUuid', () {
    test('minuscules et majuscules', () {
      expect(isUuid('0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60'), isTrue);
      expect(isUuid('0B7C6E1A-2F3D-4C5B-8A9E-1D2C3B4A5F60'), isTrue);
    });

    test('35 caractères, 37 caractères, caractère non hexadécimal → faux', () {
      expect(isUuid('0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f6'), isFalse);
      expect(isUuid('0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f600'), isFalse);
      expect(isUuid('0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f6g'), isFalse);
      expect(isUuid('0b7c6e1a2f3d-4c5b-8a9e-1d2c3b4a5f60-'), isFalse);
    });

    test('id temporaire, vide, id de démonstration → faux', () {
      expect(isUuid('g-123'), isFalse);
      expect(isUuid(''), isFalse);
      expect(isUuid('manual-1727500000000'), isFalse);
      expect(isUuid('g_user_666'), isFalse);
    });
  });

  group('isTempGameId', () {
    test('g- suivi de 1 à 20 chiffres', () {
      expect(isTempGameId('g-1'), isTrue);
      expect(isTempGameId('g-1727500000000'), isTrue);
      expect(isTempGameId('g-${'9' * 20}'), isTrue);
    });

    test('autres formes → faux', () {
      expect(isTempGameId('g-'), isFalse);
      expect(isTempGameId('g-${'9' * 21}'), isFalse);
      expect(isTempGameId('g-12a'), isFalse);
      expect(isTempGameId('G-12'), isFalse);
      expect(isTempGameId(' g-12'), isFalse);
      expect(isTempGameId('0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60'), isFalse);
    });
  });

  group('shortId', () {
    test('8 premiers caractères + « … »', () {
      expect(shortId('0b7c6e1a-2f3d-4c5b-8a9e-1d2c3b4a5f60'), '0b7c6e1a…');
    });

    test('8 caractères ou moins → inchangé', () {
      expect(shortId('abcdefgh'), 'abcdefgh');
      expect(shortId('g-1'), 'g-1');
      expect(shortId(''), '');
    });

    test('ne coupe jamais une paire de substitution', () {
      final String s = '${String.fromCharCode(0x1F600) * 9}x';
      expect(shortId(s), '${String.fromCharCode(0x1F600) * 8}…');
    });
  });
}
