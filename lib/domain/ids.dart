// Pur (VM) — identifiants manipulés par le panneau (P4b-3, lot L2) :
// UUID Supabase (comptes, jeux, suggestions), identifiant TEMPORAIRE d'un
// jeu pas encore créé côté serveur (« g-<ms> », même forme que TEMP_ID_RE
// de supabase/functions/admin-catalog/games_body.ts:24) et forme courte
// pour l'affichage.
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM
// (`flutter test test/ids_test.dart`).
library;

final RegExp _uuidRe = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

final RegExp _tempGameIdRe = RegExp(r'^g-\d{1,20}$');

/// Vrai UUID Supabase (36 caractères `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`,
/// chiffres hexadécimaux, casse indifférente). Même règle que l'ancien
/// `StoreController._isUuid` (qui délègue ici à partir du lot L4).
bool isUuid(String id) => id.length == 36 && _uuidRe.hasMatch(id);

/// Identifiant temporaire d'un jeu créé localement et pas encore enregistré
/// (`g-` suivi de 1 à 20 chiffres) : le serveur le traite comme une
/// CRÉATION ; l'édition et la bascule d'un tel jeu sont bloquées.
bool isTempGameId(String id) => _tempGameIdRe.hasMatch(id);

/// Forme courte pour l'affichage : les 8 premiers caractères suivis de « … ».
/// Un identifiant de 8 caractères ou moins est rendu tel quel (rien n'est
/// coupé, donc pas de « … »). Coupe par points de code (jamais au milieu
/// d'une paire de substitution).
String shortId(String id) {
  final List<int> runes = id.runes.toList(growable: false);
  if (runes.length <= 8) return id;
  return '${String.fromCharCodes(runes.take(8))}…';
}
