/// §137 (27/09/2026) — listes d'alias d'un jeu prêtes pour la route EF
/// `games/aliases/set` (remplacement COMPLET de la liste du jeu), en Dart
/// PUR (testable en VM : `flutter test test/game_alias_payload_test.dart`).
///
/// Tous les chemins d'écriture du panneau passent ici : dialogue « Alias »
/// du menu Jeux, alias candidat D3.4 (validation Sentinelle) et bouton
/// « Synchroniser les alias connus ». `alias_norm` = forme CLÉ
/// [TitleCleaning.aliasKey] (celle de `StoreController.normalizeGameAlias`),
/// RECALCULÉE depuis la forme affichée pour chaque alias envoyé — ceux déjà
/// en base compris : une ligne d'avant §137 (« 发薪日3 » stocké « 3 ») est
/// réparée. Une clé sans lettre n'est JAMAIS envoyée (l'EF la refuse aussi).
library;

import 'models/game_alias.dart';
import 'title_cleaning.dart';

/// Résultat de [buildGameAliasPayload] : [payload] = entrées
/// `{alias, alias_norm}` dédupliquées par `alias_norm` (première occurrence
/// gardée) ; [invalid] = alias refusés (clé vide ou sans lettre —
/// [TitleCleaning.isValidAliasKey]), dans l'ordre de saisie.
typedef GameAliasPayload = ({
  List<Map<String, String>> payload,
  List<String> invalid,
});

/// Construit la liste d'alias à envoyer à partir des formes affichées
/// [aliases] (rognées ; vides ignorées). À l'appelant de REFUSER l'écriture
/// si [GameAliasPayload.invalid] n'est pas vide (dialogue : message, rien
/// n'est écrit).
GameAliasPayload buildGameAliasPayload(Iterable<String> aliases) {
  final seen = <String>{};
  final payload = <Map<String, String>>[];
  final invalid = <String>[];
  for (final raw in aliases) {
    final alias = raw.trim();
    if (alias.isEmpty) continue;
    final norm = TitleCleaning.aliasKey(alias);
    if (!TitleCleaning.isValidAliasKey(norm)) {
      invalid.add(alias);
      continue;
    }
    if (!seen.add(norm)) continue;
    payload.add({'alias': alias, 'alias_norm': norm});
  }
  return (payload: payload, invalid: invalid);
}

/// Forme affichée d'un alias lu en base (repli sur sa clé si la forme
/// affichée est vide).
String gameAliasDisplay(GameAlias a) =>
    a.alias.trim().isNotEmpty ? a.alias.trim() : a.aliasNorm.trim();

/// Résultat de [mergeGameAliases] : [payload] = alias en base (clés
/// recalculées) + [added] ; [added] = ajouts réellement nouveaux ;
/// [invalidExisting] = alias DÉJÀ en base dont la clé est invalide
/// (« 2077 », reste « 3 » d'un ancien alias…).
typedef GameAliasMerge = ({
  List<Map<String, String>> payload,
  List<String> added,
  List<String> invalidExisting,
});

/// Union « alias en base [existing] + ajouts [additions] » des chemins
/// AUTOMATIQUES (ajout seul, jamais de suppression voulue). Un ajout vide,
/// sans lettre ou déjà présent (même `alias_norm` recalculée) est ignoré
/// sans bruit. Règles pour l'appelant :
/// - [GameAliasMerge.added] vide → rien à écrire (sans-op) ;
/// - [GameAliasMerge.invalidExisting] non vide → NE PAS écrire (l'EF
///   refuserait toute la liste ; les retirer en silence les supprimerait
///   de la base) : avertissement léger, correction dans le dialogue Alias.
GameAliasMerge mergeGameAliases(
    Iterable<GameAlias> existing, Iterable<String> additions) {
  final current = buildGameAliasPayload(existing.map(gameAliasDisplay));
  final present = {for (final e in current.payload) e['alias_norm']!};
  final payload = <Map<String, String>>[...current.payload];
  final added = <String>[];
  for (final raw in additions) {
    final alias = raw.trim();
    final norm = TitleCleaning.aliasKey(alias);
    if (!TitleCleaning.isValidAliasKey(norm) || !present.add(norm)) continue;
    payload.add({'alias': alias, 'alias_norm': norm});
    added.add(alias);
  }
  return (
    payload: payload,
    added: added,
    invalidExisting: current.invalid,
  );
}

/// Motif du refus d'un alias sans lettre (dialogue Alias, avertissements).
const String kAliasNeedsLetter =
    'un alias doit contenir au moins une lettre (un nombre ou des signes '
    'seuls rattacheraient au jeu n\'importe quel titre qui les contient)';

/// Liste lisible d'alias refusés : « 3 », « !!! ».
String quoteGameAliases(Iterable<String> aliases) =>
    aliases.map((a) => '« $a »').join(', ');
