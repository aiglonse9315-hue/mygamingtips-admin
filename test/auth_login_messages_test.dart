// Tests purs (VM) du classement des réponses d'admin-login (P4d L3, D14 ;
// tools/PLAN_VISION2_P4d_CONCEPTION.md §4 « L3 — CONTRAT », partie
// « Connexion ») : un message distinct par statut, le message du 429 rendu
// TEL QUEL par le serveur (sa durée n'est jamais recalculée par le
// panneau), texte du serveur neutralisé (une ligne, caractères invisibles
// rendus visibles, longueur bornée), lecture du corps d'un 200. Corps
// construits dans le test (durées arbitraires), aucun réseau.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/core/auth/login_messages.dart';

String _corps(Object? json) => jsonEncode(json);

/// Corps illisibles ou sans champ `error` textuel utile.
final List<String> _sansMessage = <String>[
  '',
  'pas du JSON',
  '[]',
  '"texte"',
  _corps(<String, Object?>{}),
  _corps(<String, Object?>{'error': null}),
  _corps(<String, Object?>{'error': 12}),
  _corps(<String, Object?>{'error': '   '}),
];

void main() {
  group('Textes du contrat (littéraux)', () {
    test('401, 503, 400, réseau', () {
      expect(kMessageIdentifiantsIncorrects, 'Identifiants incorrects.');
      expect(
        kMessageServiceIndisponible,
        'Service momentanément indisponible, réessaie dans un instant.',
      );
      expect(kMessageRequeteRefusee, 'Requête refusée par le serveur.');
      expect(kMessageServeurInjoignable, 'Serveur injoignable.');
    });

    test('champ vide (texte local, constat B01)', () {
      expect(kMessageChampsRequis, 'Identifiant et mot de passe requis.');
    });

    test('aucun repli ne porte de durée ni de nombre (rien de recopié du '
        'serveur)', () {
      for (final String m in <String>[
        kMessageIdentifiantsIncorrects,
        kMessageServiceIndisponible,
        kMessageRequeteRefusee,
        kMessageServeurInjoignable,
        kMessageChampsRequis,
        kMessageTropDeTentatives,
        kMessageAccesRefuse,
        kMessageReponseInattendue,
      ]) {
        expect(m, isNot(matches(RegExp(r'\d'))), reason: m);
      }
    });
  });

  group('messageRefusConnexion : un message par statut', () {
    test('401 → « Identifiants incorrects. », texte du serveur ignoré', () {
      expect(
        messageRefusConnexion(401, _corps(<String, Object?>{'error': 'autre'})),
        kMessageIdentifiantsIncorrects,
      );
      expect(messageRefusConnexion(401, ''), kMessageIdentifiantsIncorrects);
    });

    test('429 → message du serveur TEL QUEL, durée comprise', () {
      for (final String serveur in <String>[
        'Trop de tentatives. Réessayez dans 17 minute(s).',
        'Trop de tentatives. Réessayez dans 1 minute(s).',
      ]) {
        expect(
          messageRefusConnexion(
            429,
            _corps(<String, Object?>{'error': serveur}),
          ),
          serveur,
        );
      }
    });

    test('429 sans message lisible → repli sans durée inventée', () {
      for (final String corps in _sansMessage) {
        expect(
          messageRefusConnexion(429, corps),
          kMessageTropDeTentatives,
          reason: corps,
        );
      }
    });

    test('503 → indisponibilité, texte du serveur ignoré', () {
      expect(
        messageRefusConnexion(
          503,
          _corps(<String, Object?>{
            'error': 'Service momentanément indisponible.',
          }),
        ),
        kMessageServiceIndisponible,
      );
      expect(messageRefusConnexion(503, ''), kMessageServiceIndisponible);
    });

    test('autres 5xx (passerelle, délai de la fonction) → même message', () {
      for (final int statut in <int>[500, 502, 504, 546, 599]) {
        expect(
          messageRefusConnexion(statut, ''),
          kMessageServiceIndisponible,
          reason: '$statut',
        );
      }
    });

    test('400 → « Requête refusée par le serveur. »', () {
      for (final String serveur in <String>[
        'Champs manquants.',
        'Requête invalide.',
      ]) {
        expect(
          messageRefusConnexion(
            400,
            _corps(<String, Object?>{'error': serveur}),
          ),
          kMessageRequeteRefusee,
        );
      }
    });

    test('403 → message du serveur s\'il existe, sinon générique', () {
      expect(
        messageRefusConnexion(
          403,
          _corps(<String, Object?>{'error': 'Accès non autorisé ici.'}),
        ),
        'Accès non autorisé ici.',
      );
      for (final String corps in _sansMessage) {
        expect(
          messageRefusConnexion(403, corps),
          kMessageAccesRefuse,
          reason: corps,
        );
      }
    });

    test('statut imprévu (200 sans jeton, 302, 404, 418) → réponse '
        'inattendue', () {
      for (final int statut in <int>[200, 302, 404, 418]) {
        expect(
          messageRefusConnexion(
            statut,
            _corps(<String, Object?>{'error': 'x'}),
          ),
          kMessageReponseInattendue,
          reason: '$statut',
        );
      }
    });
  });

  group('messageDuServeur : texte du serveur neutralisé', () {
    test('accents conservés, espaces de bord retirés', () {
      expect(
        messageDuServeur(_corps(<String, Object?>{'error': '  Réessayez.  '})),
        'Réessayez.',
      );
    });

    test('caractère de renversement (U+202E) rendu visible, jamais brut', () {
      final String rlo = String.fromCharCode(0x202E);
      final String? m = messageDuServeur(
        _corps(<String, Object?>{'error': 'abc${rlo}def'}),
      );
      expect(m, isNotNull);
      expect(m, isNot(contains(rlo)));
      expect(m, contains('U+202E'));
    });

    test('plusieurs lignes → une seule', () {
      final String? m = messageDuServeur(
        _corps(<String, Object?>{'error': 'ligne 1\nligne 2'}),
      );
      expect(m, isNot(contains('\n')));
      expect(m, startsWith('ligne 1'));
      expect(m, endsWith('ligne 2'));
    });

    test('texte trop long coupé à $kMessageServeurMax points de code + « … »',
        () {
      final String? m = messageDuServeur(
        _corps(<String, Object?>{'error': 'a' * 5000}),
      );
      expect(m, isNotNull);
      expect(m!.runes.length, kMessageServeurMax + 1);
      expect(m, endsWith('…'));
    });

    test('absent, non textuel ou vide → null', () {
      for (final String corps in _sansMessage) {
        expect(messageDuServeur(corps), isNull, reason: corps);
      }
    });
  });

  group('lireSuccesConnexion : corps d\'un 200', () {
    test('jeton et privilège lus', () {
      final SuccesConnexion? s = lireSuccesConnexion(
        _corps(<String, Object?>{'token': 'a.b.c', 'is_owner': true}),
      );
      expect(s, isNotNull);
      expect(s!.token, 'a.b.c');
      expect(s.isOwner, isTrue);
    });

    test('is_owner absent ou non booléen → faux', () {
      for (final Object? owner in <Object?>[null, 'true', 1]) {
        final Map<String, Object?> corps = <String, Object?>{'token': 'a.b.c'};
        if (owner != null) corps['is_owner'] = owner;
        expect(lireSuccesConnexion(_corps(corps))!.isOwner, isFalse);
      }
    });

    test('sans jeton textuel non vide ou corps illisible → null', () {
      for (final String corps in <String>[
        '',
        'pas du JSON',
        '[]',
        _corps(<String, Object?>{}),
        _corps(<String, Object?>{'token': ''}),
        _corps(<String, Object?>{'token': 12}),
        _corps(<String, Object?>{'token': null, 'is_owner': true}),
      ]) {
        expect(lireSuccesConnexion(corps), isNull, reason: corps);
      }
    });
  });
}
