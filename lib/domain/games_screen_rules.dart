// Pur (VM) — règles de l'écran Jeux (P4b-3, lot L9, conception §6.13, D2,
// T7, §6.14) : tableau principal limité aux jeux ACTIFS, recherche commune
// au tableau et à la section « Jeux inactifs », jeux dont l'écriture est
// bloquée (id temporaire en production), bouton « Activer les jeux prêts »
// réservé au compte principal connecté, textes fixes de la confirmation de
// désactivation, des SnackBars et de la section des inactifs.
//
// L'écran (`ui/screens/games_screen.dart`) importe Provider et le
// StoreController (chaîne dart:html) : il n'est pas testable en VM. Ces
// règles en sont sorties pour être testées
// (`flutter test test/games_screen_rules_test.dart`).
//
// Aucune dépendance dart:html ni Flutter UI.
import 'ids.dart';
import 'models/game.dart';
import 'store_write_rules.dart'
    show kGameNotFoundMessage, kGameTempIdMessage, kGameUncertainMessage;

// ── Listes ──────────────────────────────────────────────────────────────────

/// Tableau principal : jeux ACTIFS seulement, en production ET en aperçu
/// (v2, REG-02 : en aperçu les jeux inactifs vivent dans la même liste
/// locale ; en production le cache peut encore contenir un jeu désactivé
/// avant la réconciliation de `loadInactiveGames`).
List<Game> activeGamesOnly(Iterable<Game> games) => <Game>[
  for (final Game g in games)
    if (g.active) g,
];

/// Recherche de l'écran (nom ou éditeur, casse ignorée), appliquée au
/// tableau principal ET à la section « Jeux inactifs ». Recherche vide →
/// liste inchangée (même règle que l'ancien écran).
List<Game> filterGamesBySearch(Iterable<Game> games, String search) {
  if (search.isEmpty) return games.toList();
  final String q = search.toLowerCase();
  return <Game>[
    for (final Game g in games)
      if (g.name.toLowerCase().contains(q) ||
          (g.publisher?.toLowerCase().contains(q) ?? false))
        g,
  ];
}

/// Bascule, « Réactiver » et « Modifier » bloqués : en production, un id qui
/// n'est pas un UUID (jeu créé localement, `g-<ms>`, pas encore confirmé)
/// CRÉERAIT un jeu côté serveur (games_body.ts:80-87). En aperçu (sans
/// serveur), rien n'est bloqué : les jeux de démonstration ont des ids non
/// UUID et restent modifiables localement (§6.14) — même règle que
/// `StoreController.saveGamePatch`.
bool gameWriteBlocked(Game g, {required bool hasSync}) =>
    hasSync && !isUuid(g.id);

/// Infobulle des boutons bloqués d'un jeu en cours de création.
const String kGameWriteBlockedTooltip = kGameTempIdMessage;

/// Bouton « Activer les jeux prêts » : compte principal (T15 :
/// `AuthController.isOwner`) ET connexion au serveur (masqué en aperçu).
bool showReadyGamesButton({required bool isOwner, required bool hasSync}) =>
    isOwner && hasSync;

// ── Désactivation (D2) ──────────────────────────────────────────────────────

/// Titre de la confirmation de désactivation (bascule et dialogue d'édition).
String deactivateGameTitle(String name) => 'Désactiver $name ?';

/// Texte de la confirmation de désactivation.
const String kDeactivateGameText =
    "Le jeu disparaîtra de l'application et de la liste principale. Vous "
    'pourrez le réactiver depuis « Jeux inactifs ».';

/// Bouton (rouge) de la confirmation de désactivation.
const String kDeactivateGameButton = 'Désactiver';

// ── SnackBars ───────────────────────────────────────────────────────────────

/// « Réactiver » réussi (section « Jeux inactifs », sans confirmation, D2).
String gameReactivatedMessage(String name) => '$name réactivé.';

/// Désactivation réussie (texte non fixé par la conception : le jeu quitte
/// le tableau principal, la SnackBar dit où le retrouver).
String gameDeactivatedMessage(String name) =>
    '$name désactivé (section « Jeux inactifs »).';

/// Création d'un jeu « Actif » décoché (REG-02) : aucune confirmation, le jeu
/// apparaît aussitôt dans la section.
String gameCreatedInactiveMessage(String name) =>
    '$name créé INACTIF (section « Jeux inactifs »).';

/// Dialogue d'édition : rien de modifié → fermeture sans requête.
const String kNoGameChangeMessage = 'Aucune modification.';

/// Échec d'une écriture de jeu hors dialogue (bascule, « Réactiver ») →
/// SnackBar rouge. Les messages déjà explicites du contrôleur (id temporaire,
/// jeu supprimé, issue inconnue) sont rendus tels quels ; un message du
/// serveur (400) est préfixé pour garder le contexte.
String gameWriteFailureText(String? message) {
  if (message == null || message.trim().isEmpty) return 'Jeu non modifié.';
  if (message == kGameTempIdMessage ||
      message == kGameNotFoundMessage ||
      message == kGameUncertainMessage) {
    return message;
  }
  return 'Jeu non modifié : $message';
}

// ── Section « Jeux inactifs » ───────────────────────────────────────────────

/// Titre de la section ; [n] = nombre de jeux inactifs AFFICHÉS (après la
/// recherche).
String inactiveGamesTitle(int n) => 'Jeux inactifs ($n)';

/// Section vide (aucun jeu inactif, ou aucun ne correspond à la recherche).
const String kNoInactiveGamesText = 'Aucun jeu inactif.';

/// Erreur de lecture de la liste : « Liste des jeux inactifs illisible : »
/// suivi du message et d'un point (un point final déjà présent dans le
/// message n'est pas doublé).
String inactiveGamesErrorText(String message) {
  String m = message.trim();
  while (m.endsWith('.')) {
    m = m.substring(0, m.length - 1).trimRight();
  }
  if (m.isEmpty) return 'Liste des jeux inactifs illisible.';
  return 'Liste des jeux inactifs illisible : $m.';
}

/// Section ouverte au premier affichage : au moins un jeu inactif, ou une
/// erreur à montrer (sinon « Réessayer » resterait caché).
bool inactiveSectionOpen({required int total, required bool hasError}) =>
    total > 0 || hasError;

/// Colonne « Contenus » : compteur en mémoire, « — » si le cache des
/// contenus est absent (le menu Jeux ne charge pas `contents` : un 0 serait
/// trompeur).
String gameContentCountLabel({
  required bool contentsCached,
  required int count,
}) => contentsCached ? '$count' : '—';

// ── « Activer les jeux prêts » ──────────────────────────────────────────────

/// Titre du dialogue d'information quand l'aperçu ne compte aucun jeu prêt.
const String kNoReadyGamesTitle = 'Activer les jeux prêts';

/// Erreur de l'aperçu (avant le dialogue) : 403 → « Réservé au compte
/// principal. » (jeton sans le statut de compte principal) ; sinon le
/// message du serveur TEL QUEL (« Aperçu impossible », avec ou sans point,
/// v2 C-11).
String readyGamesErrorMessage({
  required bool forbidden,
  required String message,
}) => forbidden ? 'Réservé au compte principal.' : message;
