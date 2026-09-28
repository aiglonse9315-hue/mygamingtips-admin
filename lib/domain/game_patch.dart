// Pur (VM) — édition des jeux (P4b-3, lot L3, conception §4.6, T7, D2) :
// saisie de la date de sortie (même normalisation que l'ancien dialogue +
// contrôle de calendrier IDENTIQUE au serveur, games_body.ts:29-36), envoi
// PARTIEL (seules les clés modifiées, avec la normalisation du serveur des
// deux côtés), validations de champ alignées sur le serveur
// (games_body.ts:49-65), confirmation de désactivation (D2) et plafond de
// « Activer les jeux prêts » (1 à 500 ids, games_body.ts:107-108).
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM
// (`flutter test test/game_patch_test.dart`).
import 'package:flutter/foundation.dart';

import 'models/game.dart';

/// Longueurs maximales du serveur (longueur JS = unités UTF-16 =
/// `String.length` de Dart).
const int kGameNameMax = 200, kGamePublisherMax = 500, kGameCoverMax = 2048;

/// Date de sortie saisie : valeur normalisée `AAAA-MM-JJ` (null =
/// effacement / absente) ou message d'erreur du champ.
@immutable
class ReleaseDateInput {
  const ReleaseDateInput({this.value, this.error});
  const ReleaseDateInput.valid(this.value) : error = null;
  const ReleaseDateInput.invalid(String this.error) : value = null;

  final String? value;
  final String? error;

  bool get isValid => error == null;

  @override
  String toString() =>
      isValid ? 'ReleaseDateInput($value)' : 'ReleaseDateInput(erreur: $error)';
}

final RegExp _dateInputRe = RegExp(r'^(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?$');

/// Normalise la date saisie. Règles, dans l'ordre :
/// 0. date pré-remplie NON modifiée (`raw.trim() == original`) → gardée
///    telle quelle, AUCUN contrôle (une date stockée hors de la borne de
///    confort ne bloque jamais l'édition des autres champs) ;
/// 1. vide → null (effacement voulu) ;
/// 2. AAAA, AAAA-MM ou AAAA-MM-JJ ;
/// 3. année de 1970 à `(now ?? DateTime.now()).year + 2` (borne de confort du
///    panneau ; le serveur n'en a pas) ;
/// 4. mois / jour absents → 01 ;
/// 5. mois de 1 à 12 ;
/// 6. date réelle du calendrier (30 février refusé, comme `calendarDate`) ;
/// 7. valeur `AAAA-MM-JJ`.
ReleaseDateInput parseReleaseDateInput(
  String raw, {
  DateTime? now,
  String? original,
}) {
  final String s = raw.trim();
  if (original != null && original.isNotEmpty && s == original) {
    return ReleaseDateInput.valid(original);
  }
  if (s.isEmpty) return const ReleaseDateInput.valid(null);
  final RegExpMatch? m = _dateInputRe.firstMatch(s);
  if (m == null) {
    return const ReleaseDateInput.invalid(
      'Date invalide : AAAA, AAAA-MM ou AAAA-MM-JJ.',
    );
  }
  final int maxYear = (now ?? DateTime.now()).year + 2;
  final int y = int.parse(m.group(1)!);
  if (y < 1970 || y > maxYear) {
    return ReleaseDateInput.invalid('Année hors bornes (1970 à $maxYear).');
  }
  final String mo = m.group(2) ?? '01';
  final String d = m.group(3) ?? '01';
  final int month = int.parse(mo);
  final int day = int.parse(d);
  if (month < 1 || month > 12) {
    return const ReleaseDateInput.invalid('Mois invalide.');
  }
  final DateTime dt = DateTime.utc(y, month, day);
  if (dt.year != y || dt.month != month || dt.day != day) {
    return const ReleaseDateInput.invalid('Date inexistante (ex. 30 février).');
  }
  return ReleaseDateInput.valid('${m.group(1)}-$mo-$d');
}

/// Normalisation du serveur pour un texte facultatif : coupé ; vide → null.
String? _optText(String? x) {
  final String? t = x?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

/// Diff PUR : ne rend que les clés modifiées (snake_case, comme la route
/// `games`), avec la normalisation du serveur des DEUX côtés (nom coupé ;
/// éditeur / pochette coupés, vide → null). [releaseDate] est la valeur de
/// [parseReleaseDateInput] (déjà valide) ; null contre null = pas de clé
/// (l'effacement n'est envoyé que si une date existait). Map vide = aucune
/// requête (le serveur répondrait 400 « Rien à mettre à jour. »).
Map<String, Object?> buildGamePatch(
  Game original, {
  required String name,
  required String publisher,
  required String cover,
  required String? releaseDate,
  required bool active,
}) {
  final Map<String, Object?> patch = <String, Object?>{};
  final String n = name.trim();
  if (n != original.name.trim()) patch['name'] = n;
  final String? p = _optText(publisher);
  if (p != _optText(original.publisher)) patch['publisher'] = p;
  final String? c = _optText(cover);
  if (c != _optText(original.coverUrl)) patch['cover_url'] = c;
  final String? before = _optText(original.releaseDate);
  final String? after = _optText(releaseDate);
  if (after != before) patch['release_date'] = after;
  if (active != original.active) patch['active'] = active;
  return patch;
}

/// Nom : obligatoire, 200 caractères au plus (après coupe).
String? validateGameName(String raw) {
  final String t = raw.trim();
  if (t.isEmpty) return 'Nom obligatoire.';
  if (t.length > kGameNameMax) {
    return 'Nom trop long ($kGameNameMax caractères au plus).';
  }
  return null;
}

/// Éditeur : facultatif, 500 caractères au plus (après coupe).
String? validateGamePublisher(String raw) =>
    raw.trim().length > kGamePublisherMax
    ? 'Éditeur trop long ($kGamePublisherMax caractères au plus).'
    : null;

/// Pochette : facultative, 2048 caractères au plus (après coupe).
String? validateGameCover(String raw) => raw.trim().length > kGameCoverMax
    ? 'URL de pochette trop longue ($kGameCoverMax caractères au plus).'
    : null;

/// D2 : vrai si l'envoi DÉSACTIVERAIT un jeu actif (bascule ou dialogue
/// d'édition) → confirmation obligatoire avant l'appel.
bool needsDeactivationConfirm(Game original, Map<String, Object?> patch) =>
    original.active && patch.containsKey('active') && patch['active'] == false;

/// « Activer les jeux prêts » : le serveur accepte 1 à 500 ids.
const int kActivateReadyMax = 500;

/// null si la sélection est envoyable ; sinon le message du dialogue.
String? readySelectionError(int selected) {
  if (selected <= 0) return 'Aucun jeu sélectionné.';
  if (selected > kActivateReadyMax) {
    return '$kActivateReadyMax jeux au plus par activation (limite du serveur) : '
        'décochez-en ${selected - kActivateReadyMax}, puis relancez « Activer les jeux '
        'prêts » pour les suivants.';
  }
  return null;
}
