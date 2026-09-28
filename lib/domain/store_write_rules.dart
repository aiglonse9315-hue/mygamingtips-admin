// Pur (VM) — règles des écritures partagées du StoreController (P4b-3, lot
// L4, conception §5) : cible du dialogue « Bannir un compte », traduction
// des résultats et des échecs d'un ban de compte et de l'envoi partiel d'un
// jeu, fusion de la liste des bannis relue avec le cache, rangement d'un jeu
// entre la liste des actifs et celle des inactifs.
//
// Le contrôleur (`state/store_controller.dart`) importe `dart:html` par le
// `Store` : il n'est pas testable en VM. Ces règles en sont sorties pour être
// testées (`flutter test test/store_write_rules_test.dart`). Fonctions sur
// des chaînes, des entiers et les modèles du panneau ; aucune dépendance à
// la couche d'accès (le contrôleur traduit l'exception en statut, message et
// « issue incertaine » avant l'appel).
//
// Aucune dépendance dart:html ni Flutter UI.
import 'ids.dart';
import 'models/banned_user.dart';
import 'models/game.dart';
import 'moderation_actions.dart';
import 'write_outcome.dart';

// ── Bans de comptes (§5.3) ──────────────────────────────────────────────────

/// Compte non bannissable : identifiant non UUID (auteur de bot, entrée de
/// cache locale) — le serveur répondrait 400.
const String kBanNotUuidMessage =
    "Compte non bannissable : identifiant non UUID (partage d'un bot ?).";

/// `profiles/ban` a répondu `already_banned` (sans rejeu).
const String kAlreadyBannedNotice =
    'Déjà banni : motif et catégorie existants conservés.';

/// Ban de compte : 404 du serveur.
const String kBanProfileNotFoundMessage = 'Profil introuvable.';

/// Ban de compte : issue inconnue (coupure, délai, 5xx, réponse illisible).
const String kBanUncertainMessage =
    'Réponse non reçue : la liste des bannis a été relue.';

/// Dialogue « Bannir un compte » : champ vide.
const String kBanTargetEmptyMessage =
    "Saisissez l'e-mail ou l'identifiant du compte.";

/// Dialogue « Bannir un compte » : ni UUID ni e-mail.
const String kBanTargetInvalidMessage = 'E-mail ou identifiant invalide.';

/// Dialogue « Bannir un compte » : e-mail inconnu du serveur.
const String kBanEmailUnknownMessage = 'Aucun compte avec cet e-mail.';

/// Cible saisie dans le dialogue « Bannir un compte » (T4) : un UUID est
/// banni directement, un e-mail est d'abord résolu par le serveur. Une seule
/// des trois valeurs est non nulle.
typedef BanTarget = ({String? userId, String? email, String? error});

/// [input] coupé ; vide → erreur ; UUID → [BanTarget.userId] ; texte sans
/// `@` → erreur ; sinon [BanTarget.email] (rogné, casse conservée : la
/// couche d'accès l'envoie en minuscules).
BanTarget parseBanTarget(String input) {
  final String s = input.trim();
  if (s.isEmpty) {
    return (userId: null, email: null, error: kBanTargetEmptyMessage);
  }
  if (isUuid(s)) return (userId: s, email: null, error: null);
  if (!s.contains('@')) {
    return (userId: null, email: null, error: kBanTargetInvalidMessage);
  }
  return (userId: null, email: s, error: null);
}

/// Succès de `profiles/ban` (§5.3 point 5) : `already_banned` → succès avec
/// avertissement (message de rejeu si la réponse vient d'un rejeu : le ban a
/// très probablement été posé par la 1re tentative) ; sinon succès simple.
WriteOutcome banSuccessOutcome({
  required String result,
  required bool replayed,
}) {
  if (result != 'already_banned') return const WriteOutcome.ok();
  return WriteOutcome.ok(
    notice:
        replayNotice(replayed: replayed, result: result) ??
        kAlreadyBannedNotice,
  );
}

/// Échec de `profiles/ban` (§5.3 point 6), 401 exclu (traité avant par le
/// contrôleur : `WriteOutcome.sessionExpired`). [statusCode] = statut de
/// l'erreur du serveur, null pour une erreur sans statut (coupure, délai) ;
/// [message] = texte lisible de l'erreur ; [uncertain] = issue inconnue.
WriteOutcome banFailureOutcome({
  int? statusCode,
  required String message,
  required bool uncertain,
}) {
  if (uncertain) {
    return const WriteOutcome.failed(kBanUncertainMessage, uncertain: true);
  }
  if (statusCode == 404) {
    return const WriteOutcome.failed(kBanProfileNotFoundMessage);
  }
  return WriteOutcome.failed(message);
}

/// Liste des bannis relue (`profiles/banned-list`, §5.2) : la liste SERVEUR
/// seule (aucune entrée locale conservée) ; `email` et `avatarUrl`, que le
/// serveur ne renvoie pas, sont repris de l'entrée de [cache] de même id
/// s'il y en a une.
List<BannedUser> mergeBannedWithCache(
  List<BannedUser> server,
  List<BannedUser> cache,
) {
  final Map<String, BannedUser> byId = <String, BannedUser>{
    for (final BannedUser b in cache) b.id: b,
  };
  return <BannedUser>[
    for (final BannedUser s in server)
      if (byId[s.id] case final BannedUser c
          when c.email != null || c.avatarUrl != null)
        BannedUser(
          id: s.id,
          displayName: s.displayName,
          avatarUrl: s.avatarUrl ?? c.avatarUrl,
          email: s.email ?? c.email,
          bannedAt: s.bannedAt,
          reason: s.reason,
          category: s.category,
          origin: s.origin,
          status: s.status,
          banEventId: s.banEventId,
          manualBanPresent: s.manualBanPresent,
        )
      else
        s,
  ];
}

/// Débannissement : l'entrée locale est retirée seulement si le serveur a
/// levé le ban ou si le compte n'était plus banni (§5.4 point 4) ; jamais
/// avant la réponse, jamais sur un ban automatique (409).
bool unbanRemovesLocalEntry(UnbanKind kind) =>
    kind == UnbanKind.lifted || kind == UnbanKind.notBanned;

// ── Jeux (§5.5) ─────────────────────────────────────────────────────────────

/// Édition d'un jeu dont l'id est encore temporaire (`g-…`) : un envoi
/// CRÉERAIT un jeu (games_body.ts:80-87).
const String kGameTempIdMessage =
    'Jeu en cours de création : réessayez après la synchronisation.';

/// Envoi partiel d'un jeu : 404 du serveur.
const String kGameNotFoundMessage =
    'Jeu introuvable : il a été supprimé entre-temps.';

/// Envoi partiel d'un jeu : issue inconnue.
const String kGameUncertainMessage =
    'Réponse non reçue : la liste des jeux a été relue.';

/// Échec de l'envoi partiel d'un jeu (route `games`), 401 exclu : 404 →
/// jeu supprimé entre-temps ; incertain → listes relues ; sinon message du
/// serveur (400 : validations de games_body.ts).
WriteOutcome gamePatchFailureOutcome({
  int? statusCode,
  required String message,
  required bool uncertain,
}) {
  if (uncertain) {
    return const WriteOutcome.failed(kGameUncertainMessage, uncertain: true);
  }
  if (statusCode == 404) return const WriteOutcome.failed(kGameNotFoundMessage);
  return WriteOutcome.failed(message);
}

/// Ordre d'affichage des jeux : nom, casse ignorée (même règle que le
/// contrôleur).
int compareGamesByName(Game a, Game b) =>
    a.name.toLowerCase().compareTo(b.name.toLowerCase());

/// Mode aperçu (sans serveur) : applique localement un patch en snake_case
/// (`buildGamePatch`) à [g]. Clé présente = écrite (null = effacement) ;
/// clé absente, inconnue ou de mauvais type = champ inchangé.
Game applyGamePatch(Game g, Map<String, Object?> patch) {
  String? optText(String key, String? current) {
    if (!patch.containsKey(key)) return current;
    final Object? v = patch[key];
    return v == null ? null : (v is String ? v : current);
  }

  final Object? name = patch['name'];
  final Object? active = patch['active'];
  final String? publisher = optText('publisher', g.publisher);
  final String? cover = optText('cover_url', g.coverUrl);
  final String? date = optText('release_date', g.releaseDate);
  return g.copyWith(
    name: name is String && name.trim().isNotEmpty ? name : null,
    publisher: () => publisher,
    coverUrl: () => cover,
    releaseDate: () => date,
    active: active is bool ? active : null,
  );
}

/// Range la ligne d'un jeu après une écriture : l'id [id] est retiré des
/// DEUX listes, puis [row] (la ligne renvoyée par le serveur, qui fait foi)
/// est ajoutée aux actifs ou aux inactifs selon `row.active` ; listes triées
/// par nom. [row] null (404 : jeu supprimé entre-temps) = retrait seul.
({List<Game> active, List<Game> inactive}) placeGameRow({
  required List<Game> active,
  required List<Game> inactive,
  required String id,
  Game? row,
}) {
  final List<Game> a = <Game>[
    for (final Game g in active)
      if (g.id != id) g,
    if (row != null && row.active) row,
  ]..sort(compareGamesByName);
  final List<Game> i = <Game>[
    for (final Game g in inactive)
      if (g.id != id) g,
    if (row != null && !row.active) row,
  ]..sort(compareGamesByName);
  return (active: a, inactive: i);
}

/// Réconciliation (carto 3 §0.1) : retire des jeux actifs en cache ceux que
/// le serveur liste comme inactifs (jeu désactivé encore présent dans le
/// cache de la lecture publique, qui ne voit que les jeux actifs).
List<Game> withoutInactiveIds(List<Game> active, List<Game> inactive) {
  final Set<String> ids = <String>{for (final Game g in inactive) g.id};
  return <Game>[
    for (final Game g in active)
      if (!ids.contains(g.id)) g,
  ];
}
