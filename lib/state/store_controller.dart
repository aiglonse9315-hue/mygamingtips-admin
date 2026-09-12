import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/store.dart';
import '../data/supabase_sync.dart';
import '../domain/models/banned_user.dart';
import '../domain/models/category.dart';
import '../domain/models/content.dart';
import '../domain/models/game.dart';
import '../domain/models/plus_user.dart';
import '../domain/models/suggestion.dart';

/// Détecte si une erreur provient d'un token admin expiré/invalide (HTTP 401).
bool _isAuthError(Object e) => e is AdminAuthException;

/// Datasets synchronisables indépendamment (chargement paresseux par menu).
///
/// Chaque écran déclare ses besoins via [StoreController.ensureDatasets] ;
/// seuls les datasets demandés (et pas encore chargés) sont fetchés. Les
/// resyncs post-action ne rechargent que les datasets impactés.
///
/// - [games] : catalogue des jeux (PostgREST anon).
/// - [contents] : contenus validés (PostgREST anon, le plus volumineux).
/// - [suggestionsNew] : suggestions jamais prises en charge (menu Suggestions).
/// - [sentinelleAnalyzing] : analyses Sentinelle en cours.
/// - [sentinelleAnalyzed] : suggestions analysées par Sentinelle.
/// - [scruteur] : suggestions du bot Scruteur (sites de guides).
/// - [gamesToCreate] : file « Jeux à créer ».
/// - [subscriptions] : abonnements Plus.
/// - [banned] : comptes bannis + mauvais contributeurs (menu Comptes à bannir).
enum SyncDataset {
  games,
  contents,
  suggestionsNew,
  sentinelleAnalyzing,
  sentinelleAnalyzed,
  scruteur,
  gamesToCreate,
  subscriptions,
  banned,
}

/// Contrôleur applicatif (Provider) gérant l'état du catalogue et des
/// suggestions.
///
/// **Mode aperçu local** (sans [SupabaseSync]) : tout est lu/écrit dans le
/// localStorage via [Store]. Idéal pour les démos.
///
/// **Mode production** (avec [SupabaseSync]) : les lectures viennent de
/// Supabase (PostgREST, anon key), les écritures passent par l'Edge Function
/// `admin-catalog` (service_role). Le localStorage sert de cache local.
///
/// ## Stratégie de synchronisation (v2 — robuste)
///
/// - Les écritures sont **attendues** (await) : l'UI attend la confirmation
///   serveur avant de considérer l'opération comme réussie.
/// - En cas d'échec serveur, on **annule** l'opération locale (rollback) et
///   on notifie l'utilisateur via [lastActionError].
/// - `syncFromSupabase` **fusionne** (merge) les données serveur avec les
///   entrées locales en attente, plutôt que de tout remplacer. Cela évite
///   qu'une écriture en cours soit perdue au refresh.
/// - Une garde anti-réentrance empêche deux sync concurrentes.
class StoreController extends ChangeNotifier {
  StoreController(this._store, {this.sync}) {
    _store.ensureInitialized();
    // En mode production (connecté à Supabase), on purge les données de démo
    // (IDs temporaires comme "s-1001", "g-...", "c-...") du localStorage pour
    // éviter qu'elles reviennent en boucle après suppression. Seul le contenu
    // réel de Supabase sera affiché.
    if (sync != null) {
      _purgeDemoData();
    }
    _reload();
    // Branche le sliding session : chaque écriture réussie renvoie un
    // fresh_token que le client propage au AuthService.
    sync?.onTokenRefreshed = (freshToken) {
      onTokenRefreshed?.call(freshToken);
    };
    // En mode production, on précharge les données PUBLIQUES (PostgREST anon,
    // pas besoin du token admin) : jeux + contenus. Les datasets sensibles
    // (suggestions, abonnements, bannis — Edge Function, token requis) sont
    // chargés à la demande par chaque écran via ensureDatasets, et au login.
    if (sync != null) {
      // sync async sans bloquer l'init ; _reload() a déjà chargé le cache.
      syncFromSupabase(
        datasets: const {SyncDataset.games, SyncDataset.contents},
      ).catchError((Object e) {
        debugPrint('syncFromSupabase initial échec: $e');
      });
    }
  }

  final Store _store;
  final SupabaseSync? sync;

  /// Indique si une synchronisation Supabase est en cours.
  bool isSyncing = false;

  /// Dernière erreur de synchronisation (null si OK).
  String? syncError;

  /// Dernière erreur d'action (ajout/suppression) — plus visible que syncError.
  /// Affichée dans une snackbar, puis effacée.
  String? lastActionError;

  /// Chaînage anti-réentrance pour syncFromSupabase (correctif I-004).
  ///
  /// Référence vers la passe de sync EN COURS (ou la dernière si elle vient de
  /// finir). Tout nouvel appel se chaîne APRÈS la fin réelle de cette Future —
  /// quelle que soit sa durée et sans propager son erreur — puis exécute sa
  /// propre passe. Remplace l'ancienne boucle d'attente comptée (~130 s) qui
  /// laissait repartir un appel si la sync dépassait le compteur → deux syncs
  /// concurrentes.
  Future<void>? _ongoingSync;

  /// Horodatage du dernier chargement réussi de chaque dataset (badge de
  /// fraîcheur par menu). Mis à jour à chaque sync réussie du dataset
  /// (full ou incrémentale) via [_markDatasetLoaded].
  final Map<SyncDataset, DateTime> _datasetLoadedAt = <SyncDataset, DateTime>{};

  /// Mode hors-ligne gracieux : passé à `true` quand une sync échoue sur une
  /// erreur de type réseau ([http.ClientException] — qui couvre le fetch
  /// navigateur ET les erreurs socket natives, déjà wrappées par package:http —
  /// ou [TimeoutException]) ; repassé à `false` dès qu'une requête réussit.
  bool _isOffline = false;

  /// Vrai quand la dernière sync a échoué sur une erreur réseau (données
  /// affichées = cache local). Notifié aux transitions uniquement.
  bool get isOffline => _isOffline;

  /// Erreur de type réseau ? Pas de dart:io (interdit côté web) :
  /// [http.ClientException] couvre le fetch navigateur (NetworkError) et les
  /// SocketException natives déjà encapsulées par package:http.
  static bool _isNetworkError(Object e) =>
      e is http.ClientException || e is TimeoutException;

  void _setOffline(bool value) {
    if (_isOffline == value) return;
    _isOffline = value;
    notifyListeners();
  }

  /// Marque un dataset comme chargé avec succès à l'instant présent.
  void _markDatasetLoaded(SyncDataset dataset) {
    _loadedDatasets.add(dataset);
    _datasetLoadedAt[dataset] = DateTime.now();
  }

  /// Horodatage de fraîcheur d'un ENSEMBLE de datasets (badge par menu) :
  /// le min des timestamps des datasets concernés — c'est le dataset le moins
  /// frais qui pilote l'affichage. `null` si l'un d'eux n'a jamais été chargé.
  DateTime? lastSyncFor(Set<SyncDataset> datasets) {
    if (datasets.isEmpty) return null;
    DateTime? min;
    for (final SyncDataset d in datasets) {
      final DateTime? t = _datasetLoadedAt[d];
      if (t == null) return null;
      if (min == null || t.isBefore(min)) min = t;
    }
    return min;
  }

  /// IDs de suggestions en cours de suppression/validation (« tombstones »,
  /// correctif 27/08/2026 — race sync vs action admin).
  ///
  /// Une sync EN VOL peut ramener un snapshot périmé contenant encore une
  /// ligne tout juste rejetée/acceptée (le fetch `analyzed` a été émis AVANT
  /// le commit serveur) : la ligne « réapparaissait » quelques secondes après
  /// sa suppression. Toute méthode qui retire une suggestion de façon
  /// optimiste ajoute son id ici ; [_doSyncFromSupabase] EXCLUT ces ids du
  /// snapshot entrant, puis purge de l'ensemble les ids confirmés absents du
  /// serveur. En cas d'échec de l'action (rollback), l'id est retiré.
  final Set<String> _pendingRemovalIds = <String>{};

  /// Datasets chargés avec succès dans cette session (chargement paresseux).
  /// Un dataset y figure dès que sa première sync (full ou incrémentale) a
  /// réussi ; [ensureDatasets] ne recharge pas ce qui y figure déjà.
  final Set<SyncDataset> _loadedDatasets = <SyncDataset>{};

  /// Datasets en cours de chargement (pour l'indicateur par écran).
  final Set<SyncDataset> _loadingDatasets = <SyncDataset>{};

  /// Datasets chargés avec succès dans cette session (lecture seule).
  Set<SyncDataset> get loadedDatasets =>
      Set<SyncDataset>.unmodifiable(_loadedDatasets);

  /// Ce dataset est-il en cours de chargement ?
  bool isDatasetLoading(SyncDataset dataset) =>
      _loadingDatasets.contains(dataset);

  // ── Curseurs de sync incrémentale (migration 0056) ──
  //
  // Pour chaque dataset à curseur, on persiste en localStorage le
  // `max(updated_at)` vu MOINS une marge de 5 s (anti-désalignement
  // d'horloge serveur/client), plus l'horodatage du fetch (règle des 24 h :
  // au-delà, full sync de sécurité du dataset).
  //
  // ⚠️ Un curseur PAR mode de suggestions (pas un curseur global
  // « suggestions ») : avec le chargement paresseux, les modes ne sont pas
  // toujours fetchés ensemble — un curseur partagé avancé par le mode « new »
  // pourrait dépasser l'updated_at d'une ligne modifiée dans un mode non
  // fetché, qui ne serait alors JAMAIS revue (trou de sync). Un curseur par
  // mode élimine ce risque.
  static const Duration _cursorSafetyMargin = Duration(seconds: 5);
  static const Duration _cursorMaxAge = Duration(hours: 24);

  /// Noms de curseur localStorage par dataset à curseur.
  static const Map<SyncDataset, String> _cursorNames = <SyncDataset, String>{
    SyncDataset.games: 'games',
    SyncDataset.contents: 'contents',
    SyncDataset.suggestionsNew: 'sug_new',
    SyncDataset.sentinelleAnalyzing: 'sug_analyzing',
    SyncDataset.sentinelleAnalyzed: 'sug_analyzed',
    SyncDataset.scruteur: 'sug_scruteur',
    SyncDataset.gamesToCreate: 'sug_gtc',
  };

  /// Curseur du journal cache_ops (created_at, indépendant des updated_at).
  static const String _cacheOpsCursorName = 'cacheops';

  /// Curseur valide (présent ET fetché il y a moins de 24 h) pour [dataset],
  /// ou null s'il faut une full sync.
  String? _validCursorFor(SyncDataset dataset) {
    final String? name = _cursorNames[dataset];
    if (name == null) return null; // dataset sans curseur (toujours full)
    final cursor = _store.loadCursor(name);
    if (cursor == null) return null;
    if (DateTime.now().toUtc().difference(cursor.fetchedAt.toUtc()) >
        _cursorMaxAge) {
      return null; // trop vieux → full sync de sécurité
    }
    return cursor.value;
  }

  /// Persiste le nouveau curseur d'un dataset : max(updated_at) vu moins la
  /// marge de 5 s. Sans [maxUpdatedAt] (aucune ligne modifiée), on conserve
  /// la valeur précédente mais on rafraîchit l'horodatage (règle des 24 h).
  void _saveCursorFor(SyncDataset dataset, DateTime? maxUpdatedAt) {
    final String? name = _cursorNames[dataset];
    if (name == null) return;
    final DateTime now = DateTime.now().toUtc();
    if (maxUpdatedAt != null) {
      final DateTime safe = maxUpdatedAt.toUtc().subtract(_cursorSafetyMargin);
      _store.saveCursor(name, safe.toIso8601String(), now);
    } else {
      final existing = _store.loadCursor(name);
      if (existing != null) {
        _store.saveCursor(name, existing.value, now);
      }
      // Sans valeur préalable ni ligne vue : pas de curseur — la prochaine
      // sync restera full (cas théorique : table vide).
    }
  }

  /// Dernier token admin connu (pour éviter les resync inutiles).
  String? _lastToken;

  /// Claims de session décodés du JWT admin courant (payload base64url).
  /// Relus à CHAQUE [updateAdminToken] — donc aussi après chaque fresh_token
  /// de la sliding session (qui porte les mêmes claims username/is_owner).
  bool _isOwner = false;
  String? _currentUsername;

  /// Vrai si la session courante appartient au compte principal (owner).
  /// Sert à conditionner les menus réservés (ex. « Log ») — le serveur reste
  /// la vraie barrière de sécurité (403 sur les routes owner-only).
  bool get isOwner => _isOwner;

  /// Identifiant du compte connecté (claim `username` du JWT), null sinon.
  String? get currentUsername => _currentUsername;

  /// Décode le payload JWT (segment du milieu, base64url + padding) et met
  /// à jour [_isOwner] / [_currentUsername]. Tolérant aux jetons malformés
  /// (mode aperçu, jeton factice) : les claims connus sont conservés.
  void _applySessionClaims(String? token) {
    if (token == null || token.isEmpty) {
      _isOwner = false;
      _currentUsername = null;
      return;
    }
    try {
      final parts = token.split('.');
      if (parts.length != 3) return;
      final b64 = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      final padded = b64.padRight((b64.length + 3) ~/ 4 * 4, '=');
      final claims = jsonDecode(utf8.decode(base64.decode(padded)))
          as Map<String, dynamic>;
      final owner = claims['is_owner'];
      if (owner is bool) _isOwner = owner;
      final user = claims['username'];
      if (user is String && user.isNotEmpty) _currentUsername = user;
    } catch (_) {
      // Jeton malformé → on conserve les claims déjà connus.
    }
  }

  /// Callback invoqué quand une écriture reçoit un 401 (token expiré/invalide).
  /// Le `admin_shell` s'y branche pour forcer le logout automatique.
  void Function()? onAuthError;

  /// Callback invoqué quand l'Edge Function renvoie un `fresh_token`
  /// (sliding session). Le `admin_shell` s'y branche pour rafraîchir le token.
  void Function(String freshToken)? onTokenRefreshed;

  /// Efface l'erreur de synchronisation affichée.
  void clearSyncError() {
    syncError = null;
    notifyListeners();
  }

  /// Efface la dernière erreur d'action.
  void clearActionError() {
    lastActionError = null;
    notifyListeners();
  }

  List<Game> _games = <Game>[];
  List<Content> _contents = <Content>[];
  List<Suggestion> _suggestions = <Suggestion>[];
  List<Suggestion> _sentinelleAnalyzing = <Suggestion>[];
  List<Suggestion> _sentinelleSuggestions = <Suggestion>[];
  List<Suggestion> _scruteurSuggestions = <Suggestion>[];
  List<Suggestion> _gamesToCreate = <Suggestion>[];
  List<BannedUser> _banned = <BannedUser>[];
  List<PlusUser> _plus = <PlusUser>[];

  /// Mauvais contributeurs (taux de rejet élevé) — menu « Comptes à bannir ».
  /// Données fraîches issues de `bad-contributors/list` (sync serveur).
  List<Map<String, dynamic>> _badContributors = <Map<String, dynamic>>[];

  List<Game> get games => List<Game>.unmodifiable(_games);
  List<Content> get contents => List<Content>.unmodifiable(_contents);
  List<Suggestion> get suggestions =>
      List<Suggestion>.unmodifiable(_suggestions);

  /// Suggestions marquées « Jeux à créer » (flag needs_game_creation).
  List<Suggestion> get gamesToCreate =>
      List<Suggestion>.unmodifiable(_gamesToCreate);

  /// Suggestions analysées par Sentinelle (menu Sentinelle dédié).
  List<Suggestion> get sentinelleSuggestions =>
      List<Suggestion>.unmodifiable(_sentinelleSuggestions);

  /// Suggestions en cours d'analyse par Sentinelle.
  List<Suggestion> get sentinelleAnalyzing =>
      List<Suggestion>.unmodifiable(_sentinelleAnalyzing);

  /// Suggestions Sentinelle "trusted" (implémentables en 1 clic).
  ///
  /// **Seuil de confiance conditionnel** :
  /// - FR/EN (langues natives) → seuil ≥ 0.90 (comportement historique).
  /// - Autres langues du pack 12 → seuil ≥ 0.95 (plus strict, car l'IA est
  ///   moins fiable hors FR/EN et l'utilisateur a demandé > 95% pour les
  ///   nouvelles langues).
  /// - Langue inconnue/absente → fallback conservateur 0.95.
  List<Suggestion> get sentinelleTrusted => _sentinelleSuggestions
      .where(
        (s) =>
            s.aiRecommendation != null &&
            s.aiRecommendation!.verdict == AiVerdict.recommended &&
            s.aiRecommendation!.confidence >=
                _trustThresholdFor(s.aiRecommendation!.youtubeLanguage),
      )
      .toList();

  /// Suggestions Sentinelle "à vérifier" (tout ce qui n'est pas trusted).
  List<Suggestion> get sentinelleToVerify => _sentinelleSuggestions
      .where(
        (s) =>
            s.aiRecommendation == null ||
            s.aiRecommendation!.verdict != AiVerdict.recommended ||
            s.aiRecommendation!.confidence <
                _trustThresholdFor(s.aiRecommendation?.youtubeLanguage),
      )
      .toList();

  /// Seuil de confiance requis pour qu'une suggestion soit "trusted".
  /// FR/EN = 0.90 (langues natives), autres = 0.95 (stricte).
  static double _trustThresholdFor(String? youtubeLanguage) {
    const nativeCodes = {'FR', 'EN'};
    final lang = youtubeLanguage?.toUpperCase().trim();
    if (lang == null || lang.isEmpty) return 0.95; // inconnu = strict
    return nativeCodes.contains(lang) ? 0.90 : 0.95;
  }

  // --- Scruteur (sites web de guides) ---
  // Contrairement à Sentinelle, le seuil est UNIFORME 0.95 (toutes langues).
  // Les suggestions source='scruteur' sont déjà jugées par l'IA au moment de
  // l'insertion ; l'admin valide ici en 1 clic → contents catégorie 'links'.

  /// Suggestions Scruteur brutes (source='scruteur', déjà jugées).
  List<Suggestion> get scruteurSuggestions =>
      List<Suggestion>.unmodifiable(_scruteurSuggestions);

  /// Suggestions Scruteur "95-100% pertinent" (confiance ≥ 0.95 uniforme).
  List<Suggestion> get scruteurTrusted => _scruteurSuggestions
      .where(
        (s) =>
            s.aiRecommendation != null &&
            s.aiRecommendation!.confidence >= kScruteurTrustThreshold,
      )
      .toList();

  /// Suggestions Scruteur "À vérifier" (confiance < 0.95).
  List<Suggestion> get scruteurToVerify => _scruteurSuggestions
      .where(
        (s) =>
            s.aiRecommendation == null ||
            s.aiRecommendation!.confidence < kScruteurTrustThreshold,
      )
      .toList();

  /// Seuil de confiance UNIFORME pour le Scruteur (toutes langues).
  static const double kScruteurTrustThreshold = 0.95;

  List<BannedUser> get banned => List<BannedUser>.unmodifiable(_banned);
  List<PlusUser> get plus => List<PlusUser>.unmodifiable(_plus);
  int get activePlusCount => _plus.where((n) => n.active).length;

  /// Mauvais contributeurs (taux de rejet élevé) pour le menu
  /// « Comptes à bannir ». Liste non modifiable (lecture seule côté UI).
  List<Map<String, dynamic>> get badContributors =>
      List<Map<String, dynamic>>.unmodifiable(_badContributors);

  /// L'auteur d'une suggestion est-il actuellement banni ?
  bool isAuthorBanned(String authorId) => _banned.any((b) => b.id == authorId);

  /// Un utilisateur est-il déjà abonné Plus (actif) ?
  bool isPlusUser(String userId) =>
      _plus.any((p) => p.id == userId && p.active);

  /// Ajoute un utilisateur en Plus directement depuis son user_id (UUID).
  /// Utilisé par le bouton "Plus" dans le menu Suggestions/Sentinelle.
  Future<void> addPlusByUserId({
    required String userId,
    required String displayName,
    String plan = 'monthly',
  }) async {
    if (isPlusUser(userId)) return; // déjà Plus
    // Ajout local optimiste.
    _plus = [
      ..._plus,
      PlusUser(
        id: userId,
        displayName: displayName,
        plan: plan,
        startedAt: DateTime.now(),
        active: true,
      ),
    ];
    _store.savePlus(_plus);
    notifyListeners();

    // Sync serveur (si l'UUID est valide).
    if (sync == null) return;
    if (userId.length != 36 || !userId.contains('-')) return;
    try {
      await sync!.upsertSubscription(
        userId: userId,
        plan: plan,
        isActive: true,
        startedAt: DateTime.now(),
      );
    } catch (e) {
      // Rollback.
      _plus = _plus.where((p) => p.id != userId).toList();
      _store.savePlus(_plus);
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Abonnement Plus non ajouté (erreur serveur) : $e';
      notifyListeners();
    }
  }

  // ---------- Jeux ----------
  Game? gameById(String id) {
    for (final Game g in _games) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// Nombre de contenus validés par jeu (pour le tableau des jeux).
  int contentCountFor(String gameId) =>
      _contents.where((c) => c.gameId == gameId && c.validated).length;

  /// Ajoute un jeu. En mode production, attend la confirmation serveur.
  /// En cas d'échec, le jeu est retiré (rollback) et l'erreur est notifiée.
  Future<void> addGame({
    required String name,
    String? publisher,
    String? coverUrl,
    bool active = true,
  }) async {
    final Game game = Game(
      id: 'g-${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim(),
      publisher: publisher?.trim().isEmpty == true ? null : publisher?.trim(),
      coverUrl: coverUrl?.trim().isEmpty == true ? null : coverUrl?.trim(),
      active: active,
      createdAt: DateTime.now(),
    );
    // Ajout optimiste local.
    _games = [..._games, game]..sort(_byName);
    _store.saveGames(_games);
    notifyListeners();

    // Sync Supabase : attend la confirmation.
    if (sync == null) return;
    try {
      final created = await sync!.upsertGame(game);
      // Remplace l'ID temporaire par l'ID serveur (UUID).
      _games = _games.map((g) => g.id == game.id ? created : g).toList()
        ..sort(_byName);
      _store.saveGames(_games);
      notifyListeners();
    } catch (e) {
      // Rollback : retire le jeu qui n'a pas pu être synchronisé.
      _games = _games.where((g) => g.id != game.id).toList();
      _store.saveGames(_games);
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Jeu non ajouté (erreur serveur) : $e';
      notifyListeners();
    }
  }

  Future<void> updateGame(Game game) async {
    final Game? previous = gameById(game.id);
    _games = _games.map((g) => g.id == game.id ? game : g).toList()
      ..sort(_byName);
    _store.saveGames(_games);
    notifyListeners();
    if (sync == null) return;
    try {
      await sync!.upsertGame(game);
    } catch (e) {
      // Rollback vers l'état précédent.
      if (previous != null) {
        _games = _games.map((g) => g.id == game.id ? previous : g).toList()
          ..sort(_byName);
        _store.saveGames(_games);
      }
      lastActionError = 'Jeu non modifié (erreur serveur) : $e';
      notifyListeners();
    }
  }

  void toggleGameActive(Game game) {
    updateGame(game.copyWith(active: !game.active));
  }

  // ── Traductions de titres de jeux (table game_translations) ──

  /// Charge toutes les traductions depuis le serveur et retourne le sous-map
  /// pour [gameId] (`{lang: title}`). Retourne un map vide si aucune
  /// traduction n'existe pour ce jeu, ou en cas d'erreur serveur (non
  /// bloquante : l'UI affiche le nom du jeu par défaut).
  ///
  /// Utilisé par le dialog d'édition des traductions pour pré-remplir les
  /// champs au démarrage.
  ///
  /// Lit directement les traductions du jeu via PostgREST anon (12 lignes max)
  /// plutôt que de charger toutes les traductions via l'Edge Function (qui
  /// peut être limitée par la pagination à 1000 lignes).
  Future<Map<String, String>> loadTranslationsForGame(String gameId) async {
    if (sync == null) return <String, String>{};
    try {
      return await sync!.fetchTranslationsForGame(gameId);
    } on AdminAuthException {
      rethrow;
    } catch (e) {
      debugPrint('loadTranslationsForGame échoué: $e');
      return <String, String>{};
    }
  }

  /// Sauvegarde les traductions du titre d'un jeu. [translations] contient
  /// uniquement les langues non vides (filtrées par le caller).
  ///
  /// Pas de mise à jour du `Game` en mémoire : les traductions ne sont pas
  /// affichées dans la liste principale des jeux. En cas d'échec serveur,
  /// `lastActionError` est positionnée (le dialog affiche l'erreur).
  Future<bool> updateGameTranslations(
    Game game,
    Map<String, String> translations,
  ) async {
    if (sync == null) {
      lastActionError = 'Mode aperçu : traductions non persistées.';
      notifyListeners();
      return false;
    }
    try {
      final ok = await sync!.updateGameTranslations(game.id, translations);
      if (!ok) {
        lastActionError = 'Traductions non enregistrées (erreur serveur).';
        notifyListeners();
      }
      return ok;
    } on AdminAuthException {
      // 401 = token expiré → logout forcé par admin_shell.
      onAuthError?.call();
      return false;
    } catch (e) {
      lastActionError = 'Traductions non enregistrées (erreur serveur) : $e';
      notifyListeners();
      return false;
    }
  }

  /// Supprime un jeu. Attend la confirmation serveur, puis resync.
  Future<void> deleteGame(String id) async {
    final List<Game> backupGames = List<Game>.from(_games);
    final List<Content> backupContents = List<Content>.from(_contents);
    _games = _games.where((g) => g.id != id).toList();
    _contents = _contents.where((c) => c.gameId != id).toList();
    _store.saveGames(_games);
    _store.saveContents(_contents);
    notifyListeners();
    if (sync == null) return;
    try {
      await sync!.deleteGame(id);
      // Resync ciblé : jeux + contenus (le jeu et ses contenus ont disparu).
      // Full sync des 2 datasets : les suppressions ne sont pas visibles en
      // incrémental (updated_at ne signale pas les DELETE).
      await syncFromSupabase(
        datasets: const {SyncDataset.games, SyncDataset.contents},
        forceFull: true,
      );
    } catch (e) {
      // Rollback : le jeu n'a pas pu être supprimé, on le restaure.
      _games = backupGames..sort(_byName);
      _contents = backupContents;
      _store.saveGames(_games);
      _store.saveContents(_contents);
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Jeu non supprimé (erreur serveur) : $e';
      notifyListeners();
    }
  }

  // ---------- Contenus ----------
  List<Content> contentsOf(String gameId, ContentCategory category) =>
      _contents
          .where(
            (c) => c.gameId == gameId && c.category == category && c.validated,
          )
          .toList()
        ..sort((a, b) => b.publishedAt.compareTo(a.publishedAt));

  /// Ajoute un contenu. Attend la confirmation serveur.
  Future<void> addContent({
    required String gameId,
    required ContentCategory category,
    required String url,
    String? titleAdmin,
    String? imageUrl,
  }) async {
    final bool isVideo = category == ContentCategory.video;
    final Content content = Content(
      id: 'c-${DateTime.now().millisecondsSinceEpoch}',
      gameId: gameId,
      category: category,
      url: url.trim(),
      titleAdmin: titleAdmin?.trim().isEmpty == true
          ? null
          : titleAdmin?.trim(),
      imageUrl: imageUrl?.trim().isEmpty == true ? null : imageUrl?.trim(),
      publishedAt: DateTime.now(),
      validated: true,
      isVideo: isVideo,
    );
    _contents = [..._contents, content];
    _store.saveContents(_contents);
    notifyListeners();
    if (sync == null) return;
    try {
      final created = await sync!.upsertContent(content);
      _contents = _contents
          .map((c) => c.id == content.id ? created : c)
          .toList();
      _store.saveContents(_contents);
      notifyListeners();
    } catch (e) {
      // Rollback.
      _contents = _contents.where((c) => c.id != content.id).toList();
      _store.saveContents(_contents);
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Contenu non ajouté (erreur serveur) : $e';
      notifyListeners();
    }
  }

  Future<void> updateContentTitle(Content content, String titleAdmin) async {
    final Content previous = _contents.firstWhere(
      (c) => c.id == content.id,
      orElse: () => content,
    );
    _contents = _contents
        .map(
          (c) => c.id == content.id
              ? c.copyWith(titleAdmin: () => titleAdmin.trim())
              : c,
        )
        .toList();
    _store.saveContents(_contents);
    notifyListeners();
    if (sync == null) return;
    final updated = _contents.firstWhere((c) => c.id == content.id);
    try {
      await sync!.upsertContent(updated);
    } catch (e) {
      // Rollback.
      _contents = _contents
          .map((c) => c.id == content.id ? previous : c)
          .toList();
      _store.saveContents(_contents);
      lastActionError = 'Titre non modifié (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Met à jour un contenu (titre + URL). Attend la confirmation serveur.
  Future<void> updateContent(
    Content content, {
    required String titleAdmin,
    required String url,
    ContentCategory? category,
    DateTime? publishedAt,
    String? gameId,
    String? videoLanguage,
  }) async {
    final Content previous = _contents.firstWhere(
      (c) => c.id == content.id,
      orElse: () => content,
    );
    _contents = _contents
        .map(
          (c) => c.id == content.id
              ? c.copyWith(
                  titleAdmin: () => titleAdmin.trim(),
                  url: () => url.trim(),
                  category: category,
                  publishedAt: publishedAt,
                  gameId: gameId,
                  videoLanguage: videoLanguage,
                )
              : c,
        )
        .toList();
    _store.saveContents(_contents);
    notifyListeners();
    if (sync == null) return;
    final updated = _contents.firstWhere((c) => c.id == content.id);
    try {
      await sync!.upsertContent(updated);
    } catch (e) {
      // Rollback.
      _contents = _contents
          .map((c) => c.id == content.id ? previous : c)
          .toList();
      _store.saveContents(_contents);
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Contenu non modifié (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Met à jour les dates d'un contenu saisies MANUELLEMENT par l'admin
  /// (« Publié le » / « Ajouté le »). Update optimiste + appel EF
  /// (manual:true → manual_date=true : le bot Check ne retouchera plus
  /// jamais ces dates — migration 0053).
  Future<void> updateContentDates(
    Content content, {
    DateTime? publishedAt,
    DateTime? createdAt,
  }) async {
    // Normalisation : showDatePicker renvoie minuit HEURE LOCALE ; stocké en
    // UTC, le jour peut décaler d'un jour à l'affichage. On force midi UTC,
    // le jour affiché reste alors celui choisi quel que soit le fuseau.
    DateTime? noonUtc(DateTime? d) =>
        d == null ? null : DateTime.utc(d.year, d.month, d.day, 12);
    publishedAt = noonUtc(publishedAt);
    createdAt = noonUtc(createdAt);
    final Content previous = _contents.firstWhere(
      (c) => c.id == content.id,
      orElse: () => content,
    );
    _contents = _contents
        .map(
          (c) => c.id == content.id
              ? c.copyWith(
                  publishedAt: publishedAt,
                  createdAt: createdAt,
                  manualDate: true,
                )
              : c,
        )
        .toList();
    _store.saveContents(_contents);
    notifyListeners();
    if (sync == null) return;
    try {
      await sync!.updateContentDates(
        content.id,
        publishedAt: publishedAt,
        createdAt: createdAt,
      );
    } catch (e) {
      // Rollback.
      _contents = _contents
          .map((c) => c.id == content.id ? previous : c)
          .toList();
      _store.saveContents(_contents);
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Dates non modifiées (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Marque un contenu comme vérifié MANUELLEMENT (checked_at=now +
  /// manual_check=true). Le bot Check ne le reprendra plus jamais, dans
  /// aucune de ses phases (migration 0053).
  Future<void> markContentChecked(Content content) async {
    final Content previous = _contents.firstWhere(
      (c) => c.id == content.id,
      orElse: () => content,
    );
    _contents = _contents
        .map(
          (c) => c.id == content.id
              ? c.copyWith(checkedAt: DateTime.now().toUtc(), manualCheck: true)
              : c,
        )
        .toList();
    _store.saveContents(_contents);
    notifyListeners();
    if (sync == null) return;
    try {
      await sync!.markContentCheckedManual(content.id);
    } catch (e) {
      // Rollback.
      _contents = _contents
          .map((c) => c.id == content.id ? previous : c)
          .toList();
      _store.saveContents(_contents);
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Check manuel non enregistré (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Supprime un contenu. Attend la confirmation serveur.
  Future<void> deleteContent(String id) async {
    final List<Content> backup = List<Content>.from(_contents);
    _contents = _contents.where((c) => c.id != id).toList();
    _store.saveContents(_contents);
    notifyListeners();
    if (sync == null) return;
    try {
      await sync!.deleteContent(id);
      // Resync ciblé contenus, en FULL : un DELETE n'est pas visible via le
      // curseur updated_at (la ligne a disparu, pas été modifiée).
      await syncFromSupabase(
        datasets: const {SyncDataset.contents},
        forceFull: true,
      );
    } catch (e) {
      // Rollback.
      _contents = backup;
      _store.saveContents(_contents);
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Contenu non supprimé (erreur serveur) : $e';
      notifyListeners();
    }
  }

  // ---------- Suggestions ----------
  /// Suggestions triées par date de partage (du plus récent au plus ancien).
  List<Suggestion> get suggestionsByDate =>
      List<Suggestion>.from(_suggestions)
        ..sort((a, b) => b.sharedAt.compareTo(a.sharedAt));

  int get pendingSuggestionsCount =>
      _suggestions.where((s) => s.status == SuggestionStatus.pending).length;

  /// Valide une suggestion : crée un contenu validé et marque la suggestion
  /// acceptée. C'est le cœur du workflow de modération.
  ///
  /// ⚠️ Une seule écriture serveur : la route `/suggestions/accept` crée
  /// elle-même le contenu côté serveur. On NE fait pas d'addContent séparé
  /// (sinon double insertion).
  Future<void> acceptSuggestion({
    required Suggestion suggestion,
    required String gameId,
    required ContentCategory category,
    required String titleAdmin,
    String? imageUrl,
  }) async {
    // Marque la suggestion comme acceptée localement (optimiste).
    _suggestions = _suggestions
        .map(
          (s) => s.id == suggestion.id
              ? s.copyWith(status: SuggestionStatus.accepted)
              : s,
        )
        .toList();
    _store.saveSuggestions(_suggestions);
    notifyListeners();

    // Si l'ID n'est pas un vrai UUID (donnée de démo locale), on s'arrête.
    if (sync == null || !_isUuid(suggestion.id)) return;
    try {
      await sync!.acceptSuggestion(
        suggestionId: suggestion.id,
        gameId: gameId,
        category: category,
        titleAdmin: titleAdmin,
        isVideo: category == ContentCategory.video,
        publishedAt: _dateForInsertion(suggestion),
      );
      // Resync ciblé : la suggestion quitte « new » + le contenu créé
      // côté serveur apparaît dans le delta (updated_at bumpé par l'EF).
      await syncFromSupabase(
        datasets: const {SyncDataset.suggestionsNew, SyncDataset.contents},
      );
    } catch (e) {
      // Rollback : la suggestion redevient pending.
      _suggestions = _suggestions
          .map(
            (s) => s.id == suggestion.id
                ? s.copyWith(status: SuggestionStatus.pending)
                : s,
          )
          .toList();
      _store.saveSuggestions(_suggestions);
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Suggestion non validée (erreur serveur) : $e';
      notifyListeners();
    }
  }

  Future<void> rejectSuggestion(Suggestion suggestion) async {
    final SuggestionStatus previousStatus = suggestion.status;
    _suggestions = _suggestions
        .map(
          (s) => s.id == suggestion.id
              ? s.copyWith(status: SuggestionStatus.rejected)
              : s,
        )
        .toList();
    _store.saveSuggestions(_suggestions);
    notifyListeners();
    // Si l'ID n'est pas un vrai UUID (donnée de démo locale), on s'arrête :
    // pas besoin d'appeler le serveur, la suppression locale suffit.
    if (sync == null || !_isUuid(suggestion.id)) return;
    try {
      await sync!.rejectSuggestion(suggestion.id);
    } catch (e) {
      // Rollback.
      _suggestions = _suggestions
          .map(
            (s) =>
                s.id == suggestion.id ? s.copyWith(status: previousStatus) : s,
          )
          .toList();
      _store.saveSuggestions(_suggestions);
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Suggestion non rejetée (erreur serveur) : $e';
      notifyListeners();
    }
  }

  // ---------- Sentinelle (menu dédié) ----------

  /// Implémente une suggestion Sentinelle en 1 clic.
  ///
  /// Utilise le jeu et la catégorie suggérés par l'IA, sauf si l'admin les a
  /// modifiés dans les colonnes « Jeu IA » / « Catégorie »
  /// ([gameOverride] / [categoryOverride]). **Si le jeu suggéré
  /// n'existe pas dans le catalogue, il est créé automatiquement** puis le
  /// contenu y est rattaché. La suggestion est ensuite retirée de la liste
  /// Sentinelle.
  ///
  /// [gameOverride] : nom du jeu choisi par l'admin dans la colonne « Jeu IA »
  /// (section 99% sûr). S'il est fourni et non vide, il remplace le jeu proposé
  /// par l'IA : le jeu est recherché dans le catalogue (et créé s'il n'existe
  /// pas), puis la suggestion lui est rattachée.
  ///
  /// [categoryOverride] : catégorie choisie par l'admin dans la colonne
  /// « Catégorie » (section 99% sûr) — 'video', 'guides' ou 'links'. Si elle
  /// est fournie et non vide, elle prime sur la catégorie suggérée par l'IA.
  ///
  /// [titleOverride] : titre pour insertion modifié par l'admin dans la
  /// colonne « Titre pour insertion ». S'il est fourni et non vide après
  /// trim, il devient le `title_admin` envoyé au serveur (sinon le titre
  /// calculé par [_titleForInsertion] est conservé).
  Future<void> acceptOneClick(
    Suggestion suggestion, {
    String? gameOverride,
    String? categoryOverride,
    String? titleOverride,
  }) async {
    final ai = suggestion.aiRecommendation;
    if (ai == null) {
      lastActionError = 'Pas d\'analyse IA pour cette suggestion.';
      notifyListeners();
      return;
    }

    // Détermine la catégorie : le choix de l'admin (colonne « Catégorie »)
    // prime sur la suggestion IA. [_categoryFromAi] mappe 'video'/'guides'/
    // 'links' vers l'enum et conserve son fallback URL pour toute autre
    // valeur.
    final categoryChoice = categoryOverride?.trim();
    final category = (categoryChoice != null && categoryChoice.isNotEmpty)
        ? _categoryFromAi(categoryChoice, suggestion.url)
        : _categoryFromAi(ai.suggestedCategory, suggestion.url);

    // Détermine le jeu cible :
    // 0. Si l'admin a choisi un jeu dans la colonne « Jeu IA », c'est lui qui
    //    prime (sinon on utilise le jeu proposé par l'IA).
    // 1. Cherche un jeu existant dont le nom correspond exactement.
    // 2. Sinon, cherche un jeu dont le nom contient la suggestion (ex: "fortnite" dans "Fortnite Battle Royale").
    // 3. Sinon, CRÉE le jeu automatiquement depuis la suggestion IA.
    final override = gameOverride?.trim();
    final suggestedName = (override != null && override.isNotEmpty)
        ? override
        : ai.suggestedGame;
    Game? targetGame;

    if (suggestedName != null && suggestedName.trim().isNotEmpty) {
      final lower = suggestedName.toLowerCase();
      try {
        // Recherche exacte (insensible à la casse).
        targetGame = _games.firstWhere((g) => g.name.toLowerCase() == lower);
      } catch (_) {
        try {
          // Recherche partielle (contient).
          targetGame = _games.firstWhere(
            (g) =>
                g.name.toLowerCase().contains(lower) ||
                lower.contains(g.name.toLowerCase()),
          );
        } catch (_) {
          // Le jeu n'existe pas → on le crée.
          targetGame = null;
        }
      }
    }

    // Si toujours pas de jeu, on en crée un nouveau depuis la suggestion IA.
    if (targetGame == null) {
      if (suggestedName == null || suggestedName.trim().isEmpty) {
        lastActionError =
            'L\'IA n\'a pas pu identifier le jeu. Utilisez « Ajouter manuellement ».';
        notifyListeners();
        return;
      }
      // Crée le jeu (await pour récupérer le vrai UUID).
      await addGame(name: suggestedName.trim());
      // Récupère le jeu fraîchement créé (par son nom).
      try {
        targetGame = _games.firstWhere(
          (g) => g.name.toLowerCase() == suggestedName.toLowerCase(),
        );
      } catch (_) {
        lastActionError = 'Création du jeu échouée. Réessaie.';
        notifyListeners();
        return;
      }
    }

    // Retire la suggestion de la liste Sentinelle (optimiste) + tombstone
    // anti-race (une sync en vol ne doit pas la ramener avant le commit).
    _pendingRemovalIds.add(suggestion.id);
    _sentinelleSuggestions = _sentinelleSuggestions
        .where((s) => s.id != suggestion.id)
        .toList();
    notifyListeners();

    // Si l'ID n'est pas un vrai UUID (donnée de démo locale), on s'arrête.
    if (sync == null || !_isUuid(suggestion.id)) {
      _pendingRemovalIds.remove(suggestion.id);
      return;
    }
    try {
      await sync!.acceptSuggestion(
        suggestionId: suggestion.id,
        gameId: targetGame.id,
        category: category,
        titleAdmin: _effectiveTitle(suggestion, titleOverride,
            gameName: suggestedName),
        isVideo: category == ContentCategory.video,
        publishedAt: _dateForInsertion(suggestion),
      );
      // Resync ciblé : la suggestion quitte « analyzed » + contenu créé +
      // nouveau jeu éventuel (addGame a déjà inséré l'UUID localement, la
      // sync games confirme). Le tombstone reste actif jusqu'au prochain
      // full sync des 5 modes (Actualiser ou curseur > 24 h).
      await syncFromSupabase(
        datasets: const {
          SyncDataset.sentinelleAnalyzed,
          SyncDataset.contents,
          SyncDataset.games,
        },
      );
    } catch (e) {
      // Rollback : remet la suggestion dans Sentinelle + retire le tombstone.
      _pendingRemovalIds.remove(suggestion.id);
      _sentinelleSuggestions = [..._sentinelleSuggestions, suggestion];
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Implémentation échouée (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Valide un LOT de suggestions « 99% sûr » en un appel EF par chunk
  /// (correctif 27/08/2026 — « Tout valider » : ~3 s/item → ~1 appel/100).
  ///
  /// Réplique la résolution d'[acceptOneClick] pour chaque item (catégorie :
  /// choix admin > IA ; jeu : override admin > nom IA, recherché dans le
  /// catalogue puis créé s'il est absent), puis envoie les ids à l'EF
  /// `suggestions/accept-batch` par chunks de 100, avec UNE SEULE
  /// [syncFromSupabase] à la fin (le tableau est figé pendant l'opération :
  /// un seul notifyListeners au retrait optimiste, puis à la fin).
  ///
  /// L'EF est idempotente : un échec réseau peut être retenté sans doublon.
  /// Les items en échec sont RÉINSÉRÉS dans la liste (rollback partiel) avec
  /// un message d'erreur explicite ; les items « skipped » (déjà validés)
  /// ne sont pas restaurés.
  ///
  /// Retourne le nombre de suggestions effectivement validées.
  ///
  /// [titleOverrides] : titres pour insertion modifiés par l'admin (key =
  /// suggestion ID) — colonne « Titre pour insertion ». Un override non vide
  /// après trim devient le `title_admin` envoyé ; sinon le titre calculé par
  /// [_titleForInsertion] est conservé.
  Future<int> acceptSentinelleBatch(
    List<Suggestion> items, {
    Map<String, String>? gameOverrides,
    Map<String, String>? categoryOverrides,
    Map<String, String>? titleOverrides,
    void Function(int validated, int total)? onProgress,
  }) async {
    if (items.isEmpty) return 0;

    // Mode démo (pas de sync) : repli sur le chemin unitaire existant.
    if (sync == null) {
      var done = 0;
      for (final s in items) {
        await acceptOneClick(
          s,
          gameOverride: gameOverrides?[s.id],
          categoryOverride: categoryOverrides?[s.id],
          titleOverride: titleOverrides?[s.id],
        );
        done++;
        onProgress?.call(done, items.length);
      }
      return done;
    }

    // ── Phase 1 : résolution locale des jeux/catégories (aucune écriture
    //    distante sauf création de jeu, rare) — même logique qu'acceptOneClick.
    final payload = <Map<String, dynamic>>[];
    final byId = <String, Suggestion>{for (final s in items) s.id: s};
    for (final s in items) {
      final ai = s.aiRecommendation;
      if (ai == null) continue; // pas d'analyse IA → ignoré (reste en liste)
      final categoryChoice = categoryOverrides?[s.id]?.trim();
      final category = (categoryChoice != null && categoryChoice.isNotEmpty)
          ? _categoryFromAi(categoryChoice, s.url)
          : _categoryFromAi(ai.suggestedCategory, s.url);
      final override = gameOverrides?[s.id]?.trim();
      final suggestedName = (override != null && override.isNotEmpty)
          ? override
          : ai.suggestedGame;
      if (suggestedName == null || suggestedName.trim().isEmpty) continue;
      final lower = suggestedName.toLowerCase();
      Game? targetGame;
      for (final g in _games) {
        if (g.name.toLowerCase() == lower) {
          targetGame = g;
          break;
        }
      }
      targetGame ??= _games.cast<Game?>().firstWhere(
        (g) =>
            g!.name.toLowerCase().contains(lower) ||
            lower.contains(g.name.toLowerCase()),
        orElse: () => null,
      );
      if (targetGame == null) {
        // Crée le jeu (réutilise le chemin existant addGame + resync UUID).
        await addGame(name: suggestedName.trim());
        try {
          targetGame = _games.firstWhere(
            (g) => g.name.toLowerCase() == suggestedName.toLowerCase(),
          );
        } catch (_) {
          continue; // création échouée → l'item reste en liste
        }
      }
      payload.add({
        'id': s.id,
        'game_id': targetGame.id,
        'category': category.name,
        'title_admin': _effectiveTitle(s, titleOverrides?[s.id],
            gameName: suggestedName),
        'is_video': category == ContentCategory.video,
        if (_dateForInsertion(s) != null)
          'published_at': _dateForInsertion(s)!.toIso8601String(),
      });
    }
    if (payload.isEmpty) {
      lastActionError =
          'Aucune suggestion validable (analyse IA ou jeu manquant).';
      notifyListeners();
      return 0;
    }

    // ── Phase 2 : retrait optimiste UNIQUE + tombstones anti-race.
    final ids = payload.map((p) => p['id'] as String).toSet();
    _pendingRemovalIds.addAll(ids);
    _sentinelleSuggestions = _sentinelleSuggestions
        .where((s) => !ids.contains(s.id))
        .toList();
    notifyListeners();

    // ── Phase 3 : appels EF par chunks de 100 (plafond côté EF).
    var validated = 0;
    final failedIds = <String>[];
    String? firstError;
    const chunkSize = 100;
    for (var start = 0; start < payload.length; start += chunkSize) {
      final chunk = payload.sublist(
        start,
        (start + chunkSize) > payload.length
            ? payload.length
            : start + chunkSize,
      );
      try {
        final res = await sync!.acceptSuggestionsBatch(chunk);
        final ok = (res['ok'] as List? ?? []).cast<String>();
        validated += ok.length;
        final failed = (res['failed'] as List? ?? []);
        for (final f in failed) {
          final fid = (f as Map)['id']?.toString();
          if (fid != null) failedIds.add(fid);
          firstError ??= (f as Map)['error']?.toString();
        }
        onProgress?.call(validated, payload.length);
      } catch (e) {
        // Chunk entier en échec (réseau / 401) : ses items sont à rollback.
        if (_isAuthError(e)) {
          onAuthError?.call();
        }
        firstError ??= e.toString();
        failedIds.addAll(chunk.map((p) => p['id'] as String));
      }
    }

    // ── Phase 4 : rollback partiel des échecs + UNE sync finale.
    if (failedIds.isNotEmpty) {
      final failedSet = failedIds.toSet();
      _pendingRemovalIds.removeAll(failedSet);
      final restored = items.where((s) => failedSet.contains(s.id)).toList();
      _sentinelleSuggestions = [..._sentinelleSuggestions, ...restored];
      lastActionError =
          'Validation en lot : ${failedIds.length} échec(s) — $firstError. '
          'Les lignes concernées ont été restaurées (réessayez).';
    }
    // Resync ciblée : les suggestions validées quittent « analyzed », les
    // contenus créés apparaissent dans le delta contents, les jeux créés en
    // phase 1 sont confirmés. Les tombstones restent actifs jusqu'au
    // prochain full sync des 5 modes (Actualiser ou curseur > 24 h).
    await syncFromSupabase(
      datasets: const {
        SyncDataset.sentinelleAnalyzed,
        SyncDataset.contents,
        SyncDataset.games,
      },
    );
    notifyListeners();
    return validated;
  }

  /// contenu catégorie 'links' (is_video=false) avec la langue détectée.
  ///
  /// Contrairement à [acceptOneClick] (Sentinelle) qui DEVINE le jeu depuis
  /// le titre de la vidéo, le Scruteur demande explicitement le [gameId]
  /// cible : un site de guides peut couvrir plusieurs jeux, et l'admin doit
  /// choisir à quel jeu l'associer (l'UI propose un sélecteur). Le bot
  /// Scruteur ne stocke pas de gameId dans la suggestion.
  ///
  /// [videoLanguage] : langue détectée de la page (depuis ai_recommendation).
  ///   Transmise à l'EF pour remplir contents.video_language.
  Future<void> acceptScruteurOneClick(
    Suggestion suggestion, {
    required String gameId,
    String? videoLanguage,
  }) async {
    final ai = suggestion.aiRecommendation;
    // La catégorie est TOUJOURS 'links' pour le Scruteur (sites web).
    final category = ContentCategory.links;

    // Retire la suggestion de la liste Scruteur (optimiste) + tombstone.
    _pendingRemovalIds.add(suggestion.id);
    _scruteurSuggestions = _scruteurSuggestions
        .where((s) => s.id != suggestion.id)
        .toList();
    notifyListeners();

    if (sync == null || !_isUuid(suggestion.id)) {
      _pendingRemovalIds.remove(suggestion.id);
      return;
    }
    try {
      await sync!.acceptSuggestion(
        suggestionId: suggestion.id,
        gameId: gameId,
        category: category,
        titleAdmin: _cleanTitle(suggestion),
        isVideo: false,
        publishedAt: ai?.youtubePublishedAt, // date du site si trouvée
        videoLanguage: videoLanguage,
      );
      // Resync ciblée : la suggestion quitte « scruteur » + contenu créé.
      await syncFromSupabase(
        datasets: const {SyncDataset.scruteur, SyncDataset.contents},
      );
    } catch (e) {
      _pendingRemovalIds.remove(suggestion.id);
      _scruteurSuggestions = [..._scruteurSuggestions, suggestion];
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Implémentation échouée (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Rejette une suggestion Scruteur (la retire du menu).
  Future<void> rejectScruteur(Suggestion suggestion) async {
    _pendingRemovalIds.add(suggestion.id);
    _scruteurSuggestions = _scruteurSuggestions
        .where((s) => s.id != suggestion.id)
        .toList();
    notifyListeners();
    if (sync == null || !_isUuid(suggestion.id)) {
      _pendingRemovalIds.remove(suggestion.id);
      return;
    }
    try {
      await sync!.rejectSuggestion(suggestion.id);
      // Resync ciblée : la suggestion quitte « scruteur ».
      await syncFromSupabase(datasets: const {SyncDataset.scruteur});
    } catch (e) {
      _pendingRemovalIds.remove(suggestion.id);
      _scruteurSuggestions = [..._scruteurSuggestions, suggestion];
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Rejet échoué (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Débloque les suggestions stuck en "Analyse en cours" (> 10 min sans verdict).
  /// Les suggestions redeviennent "nouvelles" et seront reprises par le bot.
  Future<int> unlockStuckSuggestions() async {
    if (sync == null) return 0;
    try {
      final unlocked = await sync!.unlockStuckSuggestions();
      if (unlocked > 0) {
        // Resync ciblée : les suggestions débloquées quittent « analyzing »
        // et redeviennent « new » (changement de mode → couvert par la
        // fusion multi-modes de la sync incrémentale).
        await syncFromSupabase(
          datasets: const {
            SyncDataset.sentinelleAnalyzing,
            SyncDataset.suggestionsNew,
          },
        );
      }
      return unlocked;
    } catch (e) {
      if (_isAuthError(e)) {
        onAuthError?.call();
        return 0;
      }
      lastActionError = 'Déblocage échoué : $e';
      notifyListeners();
      return 0;
    }
  }

  Future<void> rejectSentinelle(Suggestion suggestion) async {
    // Retire la suggestion de la liste Sentinelle (optimiste) + tombstone
    // anti-race (une sync en vol ne doit pas la ramener).
    _pendingRemovalIds.add(suggestion.id);
    _sentinelleSuggestions = _sentinelleSuggestions
        .where((s) => s.id != suggestion.id)
        .toList();
    notifyListeners();
    // Si l'ID n'est pas un vrai UUID (donnée de démo locale), on s'arrête.
    if (sync == null || !_isUuid(suggestion.id)) {
      _pendingRemovalIds.remove(suggestion.id);
      return;
    }
    try {
      await sync!.rejectSuggestion(suggestion.id);
      // L'id reste dans _pendingRemovalIds jusqu'à ce qu'une sync confirme
      // son absence serveur (purge dans _doSyncFromSupabase).
    } catch (e) {
      // Rollback : remet la suggestion dans Sentinelle + retire le tombstone.
      _pendingRemovalIds.remove(suggestion.id);
      _sentinelleSuggestions = [..._sentinelleSuggestions, suggestion];
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Rejet Sentinelle échoué : $e';
      notifyListeners();
    }
  }

  /// Rejette EN LOT des suggestions Sentinelle (28/08/2026, route EF
  /// `suggestions/reject-batch`) — « Tout supprimer » / « Rejeter la
  /// sélection » du tableau « À vérifier ».
  ///
  /// Même effet métier que [rejectSentinelle] (status 'rejected', SANS
  /// journal cache_ops : l'URL d'un refusé reste en cache anti-doublons),
  /// mais en 1 appel EF par chunk de 100 + UNE sync finale, sur le modèle
  /// d'[acceptSentinelleBatch] (tombstones anti-race + rollback partiel).
  ///
  /// Retourne le nombre de suggestions rejetées (hors échecs restaurés).
  Future<int> rejectSentinelleBatch(
    List<Suggestion> items, {
    void Function(int rejected, int total)? onProgress,
  }) async {
    if (items.isEmpty) return 0;

    // Mode démo (pas de sync) : repli sur le chemin unitaire existant.
    if (sync == null) {
      var done = 0;
      for (final s in items) {
        await rejectSentinelle(s);
        done++;
        onProgress?.call(done, items.length);
      }
      return done;
    }

    // Sépare les vrais UUID (distants) des ids locaux de démo : ces derniers
    // sont simplement retirés de la liste locale, comme le rejet unitaire
    // qui s'arrête avant l'appel EF quand l'id n'est pas un UUID.
    final remote = items.where((s) => _isUuid(s.id)).toList();
    final localOnly = items.where((s) => !_isUuid(s.id)).toList();
    if (localOnly.isNotEmpty) {
      final localIds = localOnly.map((s) => s.id).toSet();
      _sentinelleSuggestions = _sentinelleSuggestions
          .where((s) => !localIds.contains(s.id))
          .toList();
    }
    if (remote.isEmpty) {
      notifyListeners();
      onProgress?.call(items.length, items.length);
      return items.length;
    }

    // ── Phase 1 : retrait optimiste UNIQUE + tombstones anti-race.
    final ids = remote.map((s) => s.id).toSet();
    _pendingRemovalIds.addAll(ids);
    _sentinelleSuggestions = _sentinelleSuggestions
        .where((s) => !ids.contains(s.id))
        .toList();
    notifyListeners();

    // ── Phase 2 : appels EF par chunks de 100 (plafond côté EF).
    var rejected = 0;
    final failedIds = <String>[];
    String? firstError;
    const chunkSize = 100;
    final idList = remote.map((s) => s.id).toList();
    for (var start = 0; start < idList.length; start += chunkSize) {
      final chunk = idList.sublist(
        start,
        (start + chunkSize) > idList.length ? idList.length : start + chunkSize,
      );
      try {
        final res = await sync!.rejectSuggestionsBatch(chunk);
        final ok = (res['ok'] as List? ?? []).cast<String>();
        rejected += ok.length;
        // Les « skipped » (déjà rejected/accepted, introuvables) ne sont PAS
        // rollbackés : l'effet métier est déjà atteint ou sans objet — le
        // tombstone reste jusqu'à la purge par la sync finale.
        final failed = (res['failed'] as List? ?? []);
        for (final f in failed) {
          if (f is Map) {
            final fid = f['id']?.toString();
            if (fid != null) failedIds.add(fid);
            firstError ??= f['error']?.toString();
          }
        }
        onProgress?.call(rejected + localOnly.length, items.length);
      } catch (e) {
        // Chunk entier en échec (réseau / 401) : ses items sont à rollback.
        if (_isAuthError(e)) {
          onAuthError?.call();
        }
        firstError ??= e.toString();
        failedIds.addAll(chunk);
      }
    }

    // ── Phase 3 : rollback partiel des échecs + UNE sync finale.
    if (failedIds.isNotEmpty) {
      final failedSet = failedIds.toSet();
      _pendingRemovalIds.removeAll(failedSet);
      final restored = remote.where((s) => failedSet.contains(s.id)).toList();
      _sentinelleSuggestions = [..._sentinelleSuggestions, ...restored];
      lastActionError =
          'Suppression en lot : ${failedIds.length} échec(s) — $firstError. '
          'Les lignes concernées ont été restaurées (réessayez).';
    }
    // Resync ciblée : les suggestions rejetées quittent « analyzed ».
    // Les tombstones restent actifs jusqu'au prochain full sync des 5 modes.
    await syncFromSupabase(datasets: const {SyncDataset.sentinelleAnalyzed});
    notifyListeners();
    return rejected + localOnly.length;
  }

  // ── « Jeux à créer » ──

  /// Crée un nouveau jeu puis ajoute le contenu depuis une suggestion
  /// « Jeux à créer ». Le [gameName] est le nom saisi par l'admin (pré-rempli
  /// avec le suggestedGame de l'IA).
  ///
  /// [categoryOverride] : catégorie explicitement choisie par l'admin dans le
  /// tableau « Jeux à créer » ('video' | 'guides' | 'links'). Prioritaire sur
  /// la proposition de l'IA — la catégorie affichée dans le dropdown est
  /// exactement celle qui sera insérée.
  ///
  /// [titleOverride] : titre pour insertion modifié par l'admin dans la
  /// colonne « Titre pour insertion ». S'il est fourni et non vide après
  /// trim, il devient le `title_admin` envoyé (sinon titre calculé).
  Future<void> acceptGameToCreate(
    Suggestion suggestion,
    String gameName, {
    String? categoryOverride,
    String? titleOverride,
  }) async {
    final trimmed = gameName.trim();
    if (trimmed.isEmpty) {
      lastActionError = 'Le nom du jeu est requis.';
      notifyListeners();
      return;
    }

    // Retrait optimiste de la liste « Jeux à créer » + tombstone anti-race.
    _pendingRemovalIds.add(suggestion.id);
    _gamesToCreate = _gamesToCreate
        .where((s) => s.id != suggestion.id)
        .toList();
    notifyListeners();

    if (sync == null || !_isUuid(suggestion.id)) {
      _pendingRemovalIds.remove(suggestion.id);
      return;
    }

    // 1. Si le jeu existe déjà dans le catalogue (l'admin a saisi le nom
    // d'un jeu existant), on l'utilise directement — pas de doublon ni de
    // création inutile.
    Game? targetGame;
    for (final g in _games) {
      if (g.name.toLowerCase() == trimmed.toLowerCase()) {
        targetGame = g;
        break;
      }
    }

    // 2. Sinon, crée le jeu (addGame crée + resync l'UUID réel), puis
    // retrouve le jeu fraîchement créé.
    if (targetGame == null) {
      await addGame(name: trimmed);
      try {
        targetGame = _games.firstWhere(
          (g) => g.name.toLowerCase() == trimmed.toLowerCase(),
        );
      } catch (_) {
        lastActionError = 'Création du jeu échouée.';
        _pendingRemovalIds.remove(suggestion.id);
        _gamesToCreate = [..._gamesToCreate, suggestion];
        notifyListeners();
        return;
      }
    }

    // 3. Catégorie effective : choix de l'admin (dropdown) prioritaire sur
    // la proposition de l'IA.
    final ai = suggestion.aiRecommendation;
    final effectiveCategory = _categoryFromAi(
      categoryOverride ?? ai?.suggestedCategory,
      suggestion.url,
    );

    // 4. Accepte la suggestion (crée le contenu + marque accepted).
    try {
      await sync!.acceptSuggestion(
        suggestionId: suggestion.id,
        gameId: targetGame.id,
        category: effectiveCategory,
        titleAdmin: _effectiveTitle(suggestion, titleOverride,
            gameName: trimmed),
        isVideo: effectiveCategory == ContentCategory.video,
        publishedAt: _dateForInsertion(suggestion),
      );
      // Resync ciblée : la suggestion quitte « Jeux à créer » + contenu
      // créé + jeu créé/confirmé.
      await syncFromSupabase(
        datasets: const {
          SyncDataset.gamesToCreate,
          SyncDataset.contents,
          SyncDataset.games,
        },
      );
    } catch (e) {
      _pendingRemovalIds.remove(suggestion.id);
      _gamesToCreate = [..._gamesToCreate, suggestion];
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Création du contenu échouée : $e';
      notifyListeners();
    }
  }

  /// Supprime une entrée « Jeux à créer » (marque rejected).
  Future<void> rejectGameToCreate(Suggestion suggestion) async {
    _pendingRemovalIds.add(suggestion.id);
    _gamesToCreate = _gamesToCreate
        .where((s) => s.id != suggestion.id)
        .toList();
    notifyListeners();
    if (sync == null || !_isUuid(suggestion.id)) {
      _pendingRemovalIds.remove(suggestion.id);
      return;
    }
    try {
      await sync!.deleteGameToCreateEntry(suggestion.id);
    } catch (e) {
      _pendingRemovalIds.remove(suggestion.id);
      _gamesToCreate = [..._gamesToCreate, suggestion];
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Suppression échouée : $e';
      notifyListeners();
    }
  }

  /// Supprime un lot d'entrées « Jeux à créer ».
  Future<void> rejectGamesToCreateBatch(List<Suggestion> items) async {
    final ids = items.map((s) => s.id).toSet();
    _pendingRemovalIds.addAll(ids);
    _gamesToCreate = _gamesToCreate.where((s) => !ids.contains(s.id)).toList();
    notifyListeners();
    if (sync == null) {
      _pendingRemovalIds.removeAll(ids);
      return;
    }
    final uuidIds = items.where((s) => _isUuid(s.id)).map((s) => s.id).toList();
    if (uuidIds.isEmpty) {
      _pendingRemovalIds.removeAll(ids);
      return;
    }
    try {
      await sync!.deleteGamesToCreateBatch(uuidIds);
    } catch (e) {
      _pendingRemovalIds.removeAll(ids);
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Suppression par lot échouée : $e';
      notifyListeners();
    }
  }

  /// Accepte toutes les suggestions « Jeux à créer » (crée les jeux + contenus).
  ///
  /// [gameNameOverrides] : noms de jeux modifiés par l'admin dans le tableau
  /// (key = suggestion ID). Prioritaires sur le `suggestedGame` de l'IA.
  /// [categoryOverrides] : catégories choisies par l'admin dans le tableau
  /// (key = suggestion ID, 'video' | 'guides' | 'links').
  /// [titleOverrides] : titres pour insertion modifiés par l'admin (key =
  /// suggestion ID) — prioritaires sur le titre calculé.
  Future<void> acceptAllGamesToCreate(
    List<Suggestion> items, {
    Map<String, String>? gameNameOverrides,
    Map<String, String>? categoryOverrides,
    Map<String, String>? titleOverrides,
  }) async {
    for (final s in items) {
      final overrideName = gameNameOverrides?[s.id]?.trim();
      final gameName = (overrideName != null && overrideName.isNotEmpty)
          ? overrideName
          : (s.aiRecommendation?.suggestedGame ?? '');
      if (gameName.trim().isNotEmpty) {
        await acceptGameToCreate(
          s,
          gameName,
          categoryOverride: categoryOverrides?[s.id],
          titleOverride: titleOverrides?[s.id],
        );
      }
    }
  }

  /// Catégorie déduite depuis la suggestion IA ou l'URL.
  static ContentCategory _categoryFromAi(String? suggested, String url) {
    switch (suggested?.toLowerCase()) {
      case 'video':
        return ContentCategory.video;
      case 'guides':
      case 'guide':
        return ContentCategory.guides;
      case 'links':
      case 'link':
        return ContentCategory.links;
      default:
        if (url.contains('youtube') || url.contains('youtu.be')) {
          return ContentCategory.video;
        }
        return ContentCategory.links;
    }
  }

  /// Nettoie le texte partagé pour en faire un titre propre.
  static String _cleanTitle(Suggestion s) {
    final shared = s.sharedText;
    if (shared != null && shared.trim().isNotEmpty) {
      final cleaned = shared.replaceAll(RegExp(r'https?://[^\s]+'), '').trim();
      return cleaned.isEmpty ? shared : cleaned;
    }
    return s.url;
  }

  /// Détermine le meilleur titre pour l'insertion d'un contenu.
  ///
  /// Priorité :
  /// 1. Titre réel YouTube (récupéré par Sentinelle via l'API YouTube)
  /// 2. Texte partagé nettoyé (sans URL)
  /// 3. URL brute
  ///
  /// Si [gameName] est fourni (flux Sentinelle : jeu effectif = override
  /// admin ?? suggestedGame de l'IA), le titre est nettoyé via
  /// [_cleanTitleForInsertion] (hashtags + mentions du jeu — règle
  /// 12/09/2026). Sans [gameName], comportement historique inchangé.
  static String _titleForInsertion(Suggestion s, {String? gameName}) {
    // 1. Titre YouTube réel (le plus fiable).
    final ytTitle = s.aiRecommendation?.youtubeTitle;
    final base = (ytTitle != null && ytTitle.trim().isNotEmpty)
        ? ytTitle.trim()
        // 2. Fallback : texte partagé nettoyé.
        : _cleanTitle(s);
    final game = gameName?.trim();
    if (game == null || game.isEmpty) return base;
    return _cleanTitleForInsertion(base, gameName: game);
  }

  /// Titre d'insertion effectif : l'override saisi par l'admin (colonne
  /// « Titre pour insertion » des tableaux Sentinelle) prime sur le titre
  /// calculé, sauf s'il est vide après trim (champ effacé = titre calculé).
  /// [gameName] = jeu effectif (override admin ?? suggestedGame IA), utilisé
  /// pour retirer les mentions du jeu du titre calculé (règle 12/09/2026).
  static String _effectiveTitle(Suggestion s, String? titleOverride,
      {String? gameName}) {
    final override = titleOverride?.trim();
    return (override != null && override.isNotEmpty)
        ? override
        : _titleForInsertion(s, gameName: gameName);
  }

  /// Titre calculé pour l'insertion d'un contenu (titre YouTube IA sinon
  /// texte partagé nettoyé). Exposé à l'UI Sentinelle pour pré-remplir les
  /// champs « Titre pour insertion » éditables des 3 tableaux.
  /// [gameName] = jeu effectif : ses mentions sont retirées du titre
  /// (règle 12/09/2026).
  String titleForInsertion(Suggestion s, {String? gameName}) =>
      _titleForInsertion(s, gameName: gameName);

  // ── Nettoyage des titres d'insertion (règles 11/09 + 12/09/2026) ──
  // COPIE AUTONOME de SentinelleRunner.cleanTitleForInsertion (tools/vision)
  // et de GameMatcher (normalize + alias) : l'admin ne peut pas importer
  // tools/vision. ⚠️ Toute évolution de GameMatcher._aliases doit être
  // reportée ici (et dans tools/sentinelle/lib/game_matcher.dart).
  //
  // ⚠️ Les titres DÉJÀ en base avec le nom du jeu ne sont PAS rétro-
  // modifiés : l'admin les édite à la main via le champ « Titre pour
  // insertion ».

  /// Variantes accentuées par lettre ASCII, pour la comparaison insensible
  /// aux accents de [_cleanTitleForInsertion].
  static const Map<String, String> _accentVariants = {
    'a': 'àâäãåā',
    'e': 'éèêëē',
    'i': 'îïíìī',
    'o': 'ôöõòóōø',
    'u': 'ùûüúū',
    'y': 'ýÿ',
    'c': 'ç',
    'n': 'ñ',
  };

  /// Alias connus → nom canonique normalisé. Copie de GameMatcher._aliases
  /// (tools/vision/lib/game_matcher.dart) — clés et valeurs déjà normalisées.
  static const Map<String, String> _gameAliases = {
    'd4': 'diablo 4',
    'diablo iv': 'diablo 4',
    'diablo 4': 'diablo 4',
    'poe': 'path of exile',
    'poe 2': 'path of exile 2',
    'poe2': 'path of exile 2',
    'path of exile 2': 'path of exile 2',
    'lol': 'league of legends',
    'league of legends': 'league of legends',
    'tft': 'league of legends teamfight tactics',
    'teamfight tactics': 'league of legends teamfight tactics',
    'tft set': 'league of legends teamfight tactics',
    'lol tft': 'league of legends teamfight tactics',
    'league of legends tft': 'league of legends teamfight tactics',
    'league of legends teamfight tactics': 'league of legends teamfight tactics',
    'bo7': 'call of duty black ops 7',
    'black ops 7': 'call of duty black ops 7',
    'cod bo7': 'call of duty black ops 7',
    'call of duty black ops 7': 'call of duty black ops 7',
    'oni': 'oxygen not included',
    'oxygen not included': 'oxygen not included',
    'oxygene not included': 'oxygen not included',
    'oxygène not included': 'oxygen not included',
    'sc': 'star citizen',
    'wf': 'warframe',
    'la': 'lost ark',
    'drg': 'deep rock galactic',
    'total war warhammer 3': 'total war warhammer 3',
    'warhammer 3': 'total war warhammer 3',
    'mortal shell 2': 'mortal shell 2',
    'mortal shell ii': 'mortal shell 2',
    'dc universe online': 'dc universe online',
    'dcuo': 'dc universe online',
    'the blood of dawnwalker': 'the blood of dawnwalker',
    'the blood of dawnwalker eclipse edition': 'the blood of dawnwalker',
    'the legend of zelda breath of the wild':
        'the legend of zelda breath of the wild',
    'botw': 'the legend of zelda breath of the wild',
    'breath of the wild': 'the legend of zelda breath of the wild',
    'the legend of zelda tears of the kingdom':
        'the legend of zelda tears of the kingdom',
    'totk': 'the legend of zelda tears of the kingdom',
    'tears of the kingdom': 'the legend of zelda tears of the kingdom',
    'metal gear solid 5 the phantom pain':
        'metal gear solid 5 the phantom pain',
    'mgsv': 'metal gear solid 5 the phantom pain',
    'resident evil requiem': 'resident evil requiem',
    'resident evil 9 requiem': 'resident evil requiem',
    'reanimal': 'reanimal',
    's t a l k e r 2': 's t a l k e r 2',
    'stalker 2': 's t a l k e r 2',
    'stalker 2 heart of chornobyl': 's t a l k e r 2',
    'call of duty b o 7': 'call of duty black ops 7',
    'senuas saga hellblade 2': 'senuas saga hellblade 2',
    'hellblade 2': 'senuas saga hellblade 2',
    'hellblade 2 senuas saga': 'senuas saga hellblade 2',
    'death stranding 2 on the beach': 'death stranding 2 on the beach',
    'death stranding 2': 'death stranding 2 on the beach',
    'assassins creed black flag resynced':
        'assassins creed black flag resynced',
    'ac black flag resynced': 'assassins creed black flag resynced',
  };

  /// Conversion des chiffres romains courants en chiffres arabes (copie de
  /// GameMatcher._romanToArabic). « I » seul est volontairement exclu.
  static const Map<String, String> _romanToArabic = {
    'ii': '2',
    'iii': '3',
    'iv': '4',
    'v': '5',
    'vi': '6',
    'vii': '7',
    'viii': '8',
    'ix': '9',
    'x': '10',
    'xi': '11',
    'xii': '12',
  };

  /// Chiffre romain en limite de mot (copie de GameMatcher._romanPattern).
  static final RegExp _romanPattern = RegExp(
    r'(^|[^a-z0-9])(viii|vii|xii|iii|xi|ix|vi|iv|ii|x|v)(?![a-z0-9])',
  );

  /// Jeux pour lesquels les HASHTAGS sont conservés dans les titres
  /// (12/09/2026 — Roblox : les hashtags différencient ses jeux/modes
  /// internes ; même règle côté bots, voir passation §56).
  static const Set<String> _keepHashtagsGames = {'roblox'};

  /// Normalise un nom de jeu pour la comparaison (copie fidèle de
  /// GameMatcher.normalize : minuscules, accents, romains → arabes,
  /// suffixes d'édition, apostrophes, ponctuation, puis résolution d'alias).
  static String _normalizeGameName(String name) {
    var n = name.toLowerCase().trim();

    // Suppression des accents.
    n = n.replaceAll('é', 'e');
    n = n.replaceAll('è', 'e');
    n = n.replaceAll('ê', 'e');
    n = n.replaceAll('ë', 'e');
    n = n.replaceAll('à', 'a');
    n = n.replaceAll('â', 'a');
    n = n.replaceAll('ä', 'a');
    n = n.replaceAll('ã', 'a');
    n = n.replaceAll('å', 'a');
    n = n.replaceAll('î', 'i');
    n = n.replaceAll('ï', 'i');
    n = n.replaceAll('í', 'i');
    n = n.replaceAll('ì', 'i');
    n = n.replaceAll('ô', 'o');
    n = n.replaceAll('ö', 'o');
    n = n.replaceAll('õ', 'o');
    n = n.replaceAll('ò', 'o');
    n = n.replaceAll('ó', 'o');
    n = n.replaceAll('ù', 'u');
    n = n.replaceAll('û', 'u');
    n = n.replaceAll('ü', 'u');
    n = n.replaceAll('ú', 'u');
    n = n.replaceAll('ý', 'y');
    n = n.replaceAll('ÿ', 'y');
    n = n.replaceAll('ā', 'a');
    n = n.replaceAll('ē', 'e');
    n = n.replaceAll('ī', 'i');
    n = n.replaceAll('ō', 'o');
    n = n.replaceAll('ū', 'u');
    n = n.replaceAll('ç', 'c');
    n = n.replaceAll('ñ', 'n');
    n = n.replaceAll('æ', 'ae');
    n = n.replaceAll('œ', 'oe');
    n = n.replaceAll('ø', 'o');
    n = n.replaceAll('ð', 'd');
    n = n.replaceAll('þ', 'th');

    // Chiffres romains → arabes (en limite de mot).
    n = n.replaceAllMapped(
      _romanPattern,
      (m) => '${m.group(1)}${_romanToArabic[m.group(2)]!}',
    );

    // Suffixes d'édition courants.
    const suffixesToRemove = [
      ': wild hunt',
      ': enhanced edition',
      ' game of the year edition',
      ' goty edition',
      ' definitive edition',
      ' complete edition',
      ' standard edition',
      ' deluxe edition',
      ' ultimate edition',
    ];
    for (final suffix in suffixesToRemove) {
      if (n.endsWith(suffix)) {
        n = n.substring(0, n.length - suffix.length).trim();
      }
    }

    // Apostrophes → RIEN (pas d'espace) : « Assassin's » → « assassins ».
    n = n.replaceAll("'", '');
    n = n.replaceAll('’', '');

    // Ponctuation → espaces, puis espaces multiples → un seul.
    n = n.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    n = n.replaceAll(RegExp(r'\s+'), ' ').trim();

    // Résolution d'alias.
    return _gameAliases[n] ?? n;
  }

  /// Construit la regex de détection d'une forme NORMALISÉE de nom de jeu
  /// (cf. [_cleanTitleForInsertion]) dans un titre brut :
  /// - mots joints par `[\W_]+` → « Prince of Persia The Lost Crown »
  ///   matche « Prince of Persia: The Lost Crown » ou « ... - The ... » ;
  /// - chaque lettre matche ses variantes accentuées ([_accentVariants]) ;
  /// - une apostrophe optionnelle est admise entre les lettres →
  ///   « Assassin's » matche la forme normalisée « assassins » ;
  /// - limites de mot Unicode des deux côtés → jamais de retrait à
  ///   l'intérieur d'un mot plus long (« la » dans « large »).
  /// Retourne null si la forme est inexploitable (vide).
  static RegExp? _gameMentionPattern(String normalizedForm) {
    final words =
        normalizedForm.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return null;
    final buffer = StringBuffer();
    var first = true;
    for (final word in words) {
      if (!first) buffer.write(r'[\W_]+');
      first = false;
      for (final unit in word.codeUnits) {
        final ch = String.fromCharCode(unit);
        final variants = _accentVariants[ch];
        final escaped = RegExp.escape(ch);
        buffer.write(variants != null ? '[$escaped$variants]' : escaped);
        // Apostrophe optionnelle (droite U+0027 ou typographique U+2019).
        buffer.write("['’]?");
      }
    }
    return RegExp(
      '(^|[^\\p{L}\\p{N}])$buffer(?![\\p{L}\\p{N}])',
      caseSensitive: false,
      unicode: true,
    );
  }

  /// Nettoie un titre avant insertion (copie autonome de
  /// SentinelleRunner.cleanTitleForInsertion, tools/vision) :
  /// (a) retire les hashtags (règle 11/09/2026) ;
  /// (b) retire TOUTES les mentions du jeu [gameName] — nom canonique ET
  ///     chaque alias connu pointant vers lui (règle 12/09/2026 : le contenu
  ///     est déjà associé au jeu dans l'app, répéter le nom est inutile) ;
  /// (c) nettoie les artefacts du retrait (espaces multiples, séparateurs
  ///     orphelins en bordure, séparateurs doublés au milieu) ;
  /// (d) garde-fou : si le résultat fait moins de 3 caractères ou est vide,
  ///     retourne le titre seulement dé-hashtagué (jamais de titre vide).
  static String _cleanTitleForInsertion(String title, {String? gameName}) {
    // (a) Hashtags — SAUF pour les jeux d'exception (12/09/2026 : Roblox
    // contient de nombreux jeux/modes en son sein, les hashtags les
    // différencient — même règle que les bots, cf. _keepHashtagsGames).
    final game = gameName?.trim();
    final keepHashtags = game != null &&
        _keepHashtagsGames.contains(_normalizeGameName(game));
    final withoutHashtags = keepHashtags
        ? title.replaceAll(RegExp(r'\s+'), ' ').trim()
        : title
            .replaceAll(RegExp(r'#\S+'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

    if (game == null || game.isEmpty) return withoutHashtags;

    // (b) Formes à retirer : nom canonique normalisé + alias connus dont la
    //     cible == ce canonique. Alias < 3 caractères exclus (« sc », « la »,
    //     « wf », « d4 ») : trop courts, risque de découper un mot courant.
    final canonical = _normalizeGameName(game);
    if (canonical.isEmpty) return withoutHashtags;
    final forms = <String>{canonical};
    for (final entry in _gameAliases.entries) {
      if (entry.value == canonical && entry.key.length >= 3) {
        forms.add(entry.key);
      }
    }

    // Retrait sur le titre dé-hashtagué (accents conservés), insensible à
    // la casse, aux accents et à la ponctuation. Formes les plus longues
    // d'abord pour éviter les retraits partiels.
    var result = withoutHashtags;
    final sorted = forms.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final form in sorted) {
      final pattern = _gameMentionPattern(form);
      if (pattern == null) continue;
      // Le caractère de limite avant la mention (groupe 1) est réinséré.
      result = result.replaceAllMapped(pattern, (m) => m.group(1) ?? '');
    }

    // (c) Nettoyage post-retrait.
    result = result.replaceAll(RegExp(r'\s+'), ' ');
    // Séparateurs doublés au milieu (« - - » → « - », « - : » → « - »).
    result = result.replaceAllMapped(
      RegExp(r'\s*([-–:|•])(?:\s*[-–:|•])+\s*'),
      (m) => ' ${m.group(1)} ',
    );
    // Séparateurs orphelins en bordure (« - Ep 1 » → « Ep 1 »).
    result = result.replaceAll(RegExp(r'^[\s\-–:|•]+'), '');
    result = result.replaceAll(RegExp(r'[\s\-–:|•]+$'), '');
    result = result.trim();

    // (d) Garde-fou : jamais de titre vide ou quasi vide en base.
    if (result.length < 3) return withoutHashtags;
    return result;
  }

  /// Détermine la date de publication pour l'insertion d'un contenu.
  ///
  /// Priorité :
  /// 1. Date de publication YouTube (récupérée par Sentinelle)
  /// 2. null (la base utilisera now() par défaut)
  static DateTime? _dateForInsertion(Suggestion s) {
    return s.aiRecommendation?.youtubePublishedAt;
  }

  // ---------- Bannissement ----------
  /// Bannit le compte auteur d'une suggestion (modération disciplinaire).
  Future<void> banAuthor(Suggestion suggestion, {String? reason}) async {
    if (isAuthorBanned(suggestion.author.id)) return;
    _banned = [
      ..._banned,
      BannedUser.fromAuthor(suggestion.author, reason: reason),
    ];
    _store.saveBanned(_banned);
    notifyListeners();
    if (sync == null) return;
    try {
      await sync!.banUser(suggestion.author.id, reason: reason);
    } catch (e) {
      // Rollback.
      _banned = _banned.where((b) => b.id != suggestion.author.id).toList();
      _store.saveBanned(_banned);
      lastActionError = 'Bannissement échoué (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Bannit directement un auteur identifié (depuis un id).
  Future<void> banAuthorId(String authorId, {String? displayName}) async {
    if (isAuthorBanned(authorId)) return;
    _banned = [
      ..._banned,
      BannedUser(
        id: authorId,
        displayName: displayName ?? authorId,
        bannedAt: DateTime.now(),
        reason: 'Banni manuellement',
      ),
    ];
    _store.saveBanned(_banned);
    notifyListeners();
    if (sync == null) return;
    try {
      await sync!.banUser(authorId, reason: 'Banni manuellement');
    } catch (e) {
      _banned = _banned.where((b) => b.id != authorId).toList();
      _store.saveBanned(_banned);
      lastActionError = 'Bannissement échoué (erreur serveur) : $e';
      notifyListeners();
    }
  }

  Future<void> unban(String id) async {
    _banned = _banned.where((b) => b.id != id).toList();
    _store.saveBanned(_banned);
    notifyListeners();
    if (sync == null) return;
    try {
      await sync!.unbanUser(id);
    } catch (e) {
      // Rollback : on ne peut pas reconstruire l'entrée exacte, donc on resync.
      lastActionError = 'Levée de ban échouée : $e';
      notifyListeners();
    }
  }

  /// Bannit un lot d'utilisateurs (menu « Comptes à bannir »).
  ///
  /// Boucle sur [userIds] en appelant `banAuthorId` pour chaque identifiant.
  /// Les utilisateurs déjà bannis sont ignorés (garde fourni par banAuthorId).
  /// [reason] est appliqué à tous (information locale uniquement — la raison
  /// envoyée au serveur reste « Banni manuellement » pour cohérence avec
  /// banAuthorId).
  ///
  /// Retourne le nombre d'utilisateurs réellement bannis (excluant ceux qui
  /// l'étaient déjà). En cas d'erreur serveur sur un utilisateur, on continue
  /// le lot (meilleur effort) et on consolide l'erreur dans lastActionError.
  Future<int> banBatch(List<String> userIds, {String? reason}) async {
    if (userIds.isEmpty) return 0;
    int count = 0;
    for (final id in userIds) {
      if (isAuthorBanned(id)) continue; // déjà banni → on saute
      await banAuthorId(id);
      if (!isAuthorBanned(id)) {
        // banAuthorId a rollback (erreur serveur) → on signale et on continue.
        continue;
      }
      count++;
    }
    return count;
  }

  /// Synchronise les mauvais contributeurs depuis le serveur
  /// (`bad-contributors/list`). Met à jour `_badContributors` et notifie.
  ///
  /// Non critique : en cas d'échec, on garde le cache précédent.
  Future<void> syncBadContributors() async {
    if (sync == null) return;
    try {
      _badContributors = await sync!.fetchBadContributors();
      notifyListeners();
    } catch (e) {
      debugPrint('fetchBadContributors échec: $e');
    }
  }

  /// Bannit manuellement un compte (sans suggestion associée).
  /// Utilisé par le bouton « Bannir » du dashboard.
  /// Bannit manuellement un utilisateur par email.
  ///
  /// Résout l'email → UUID via `findProfileByEmail`, puis appelle
  /// `banUser` sur Supabase pour réellement activer le ban côté base.
  /// Si l'email n'est pas trouvé, on garde quand même une trace locale
  /// pour information, mais le ban ne sera pas effectif côté mobile.
  Future<void> banManually({
    required String displayName,
    String? email,
    String? reason,
  }) async {
    final cleanReason = reason?.trim().isEmpty == true
        ? 'Banni manuellement'
        : reason!.trim();

    // Tente de résoudre l'email → UUID pour un vrai ban côté base.
    String? userId;
    if (email != null && email.trim().isNotEmpty && sync != null) {
      userId = await sync!.findProfileByEmail(email.trim());
    }

    if (userId != null && sync != null) {
      // UUID trouvé → on bannit vraiment côté Supabase.
      await sync!.banUser(userId, reason: cleanReason);
    }

    // Ajoute à la liste locale (avec le vrai UUID si trouvé, sinon un ID temp).
    final id = userId ?? 'manual-${DateTime.now().millisecondsSinceEpoch}';
    _banned = [
      ..._banned,
      BannedUser(
        id: id,
        displayName: displayName.trim(),
        email: email?.trim().isEmpty == true ? null : email?.trim(),
        bannedAt: DateTime.now(),
        reason: cleanReason,
      ),
    ];
    _store.saveBanned(_banned);
    notifyListeners();
  }

  // ---------- Utilisateurs Plus ----------
  /// Ajoute manuellement un utilisateur Plus (depuis le dashboard admin).
  void addPlusUser({
    required String displayName,
    required String email,
    required String plan,
  }) {
    final PlusUser user = PlusUser(
      id: 'nu-${DateTime.now().millisecondsSinceEpoch}',
      displayName: displayName.trim(),
      email: email.trim().isEmpty ? null : email.trim(),
      plan: plan,
      startedAt: DateTime.now(),
      active: true,
    );
    _plus = [..._plus, user];
    _store.savePlus(_plus);
    notifyListeners();
    // Pas de sync Supabase automatique : l'ID est fictif. La gestion réelle
    // des abonnements se fera via Google Play Billing (Phase 3).
  }

  /// Active/désactive un abonnement Plus.
  Future<void> togglePlusUser(PlusUser user) async {
    final bool previousActive = user.active;
    _plus = _plus
        .map((n) => n.id == user.id ? n.copyWith(active: !n.active) : n)
        .toList();
    _store.savePlus(_plus);
    notifyListeners();
    if (sync == null) return;
    if (user.id.length != 36 || !user.id.contains('-')) return;
    try {
      await sync!.upsertSubscription(
        userId: user.id,
        plan: user.plan,
        isActive: !previousActive,
        startedAt: user.startedAt,
      );
    } catch (e) {
      // Rollback.
      _plus = _plus
          .map((n) => n.id == user.id ? n.copyWith(active: previousActive) : n)
          .toList();
      _store.savePlus(_plus);
      lastActionError = 'Abonnement non modifié (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Change la formule d'un utilisateur Plus.
  Future<void> setPlusPlan(PlusUser user, String plan) async {
    final String previousPlan = user.plan;
    _plus = _plus
        .map((n) => n.id == user.id ? n.copyWith(plan: plan) : n)
        .toList();
    _store.savePlus(_plus);
    notifyListeners();
    if (sync == null) return;
    if (user.id.length != 36 || !user.id.contains('-')) return;
    try {
      await sync!.upsertSubscription(
        userId: user.id,
        plan: plan,
        isActive: user.active,
        startedAt: user.startedAt,
      );
    } catch (e) {
      // Rollback.
      _plus = _plus
          .map((n) => n.id == user.id ? n.copyWith(plan: previousPlan) : n)
          .toList();
      _store.savePlus(_plus);
      lastActionError = 'Formule non modifiée (erreur serveur) : $e';
      notifyListeners();
    }
  }

  void deletePlusUser(String id) {
    // Désactive côté serveur AVANT de supprimer localement.
    final user = _plus.where((n) => n.id == id).firstOrNull;
    if (user != null && sync != null) {
      sync!.upsertSubscription(userId: id, plan: user.plan, isActive: false);
    }
    _plus = _plus.where((n) => n.id != id).toList();
    _store.savePlus(_plus);
    notifyListeners();
  }

  // ---------- Divers ----------
  void resetDemo() {
    _store.resetToSeed();
    _reload();
    notifyListeners();
  }

  /// Purge les données de démo (IDs temporaires non-UUID) du localStorage.
  ///
  /// En mode production, les données de démo (assets/seed) n'ont pas leur
  /// place : elles ont des IDs temporaires ("s-1001", "g-...", "c-...") qui
  /// font échouer les appels serveur et reviennent en boucle après suppression.
  /// On ne conserve que les données avec un vrai UUID (synchronisées).
  void _purgeDemoData() {
    final games = _store.loadGames().where((g) => _isUuid(g.id)).toList();
    _store.saveGames(games);
    final contents = _store.loadContents().where((c) => _isUuid(c.id)).toList();
    _store.saveContents(contents);
    final suggestions = _store
        .loadSuggestions()
        .where((s) => _isUuid(s.id))
        .toList();
    _store.saveSuggestions(suggestions);
  }

  void _reload() {
    _games = _store.loadGames()..sort(_byName);
    _contents = _store.loadContents();
    _suggestions = _store.loadSuggestions();
    _banned = _store.loadBanned();
    _plus = _store.loadPlus();
  }

  /// Recharge le catalogue depuis la source active.
  ///
  /// - Mode aperçu : relit le localStorage.
  /// - Mode production : full sync de TOUS les datasets (bouton « Actualiser »
  ///   global — comportement historique conservé, curseurs ignorés).
  Future<void> refresh() async {
    if (sync != null) {
      await syncFromSupabase(forceFull: true);
    } else {
      _reload();
      notifyListeners();
    }
  }

  /// Datasets nécessaires au dashboard (chargés au login).
  static const Set<SyncDataset> dashboardDatasets = <SyncDataset>{
    SyncDataset.games,
    SyncDataset.contents,
    SyncDataset.suggestionsNew,
    SyncDataset.subscriptions,
    SyncDataset.banned,
  };

  /// Les 5 modes de suggestions (correctif I-001).
  ///
  /// Une suggestion n'existe que dans UN mode à la fois ; quand elle change de
  /// mode (ex. prise en charge Sentinelle), elle quitte le delta incrémental
  /// du mode d'origine. Si les modes sont fetchés séparément, la ligne reste
  /// affichée en « stale » dans le board d'origine jusqu'au full sync 24 h.
  /// Pour garantir que [_mergeSuggestionsIncremental] voit tous les
  /// déplacements, toute demande contenant UN de ces datasets est élargie
  /// aux 5 dans la même passe (coût minime en incrémental).
  static const Set<SyncDataset> suggestionDatasets = <SyncDataset>{
    SyncDataset.suggestionsNew,
    SyncDataset.sentinelleAnalyzing,
    SyncDataset.sentinelleAnalyzed,
    SyncDataset.scruteur,
    SyncDataset.gamesToCreate,
  };

  /// Élargit [wanted] aux 5 modes de suggestions si l'un d'eux est demandé
  /// (correctif I-001 — voir [suggestionDatasets]).
  static Set<SyncDataset> _expandSuggestionModes(Set<SyncDataset> wanted) {
    if (wanted.any(suggestionDatasets.contains)) {
      return <SyncDataset>{...wanted, ...suggestionDatasets};
    }
    return wanted;
  }

  /// Garantit que les datasets [needed] sont chargés (chargement paresseux).
  ///
  /// Ne fetch que ce qui n'est pas déjà chargé dans cette session (ou qui n'a
  /// jamais réussi). Appelé par chaque écran à son montage.
  ///
  /// Si [needed] contient un dataset de suggestions, la demande est élargie
  /// aux 5 modes AVANT le calcul du manquant (correctif I-001) : les modes
  /// déjà chargés restent ignorés (skipAlreadyLoaded conserve son sens).
  Future<void> ensureDatasets(Set<SyncDataset> needed) async {
    if (sync == null) return;
    final Set<SyncDataset> wanted = _expandSuggestionModes(needed);
    final Set<SyncDataset> missing = wanted.difference(_loadedDatasets);
    if (missing.isEmpty) return;
    await syncFromSupabase(datasets: missing, skipAlreadyLoaded: true);
  }

  /// Synchronise les données depuis Supabase et met à jour le cache
  /// localStorage.
  ///
  /// [datasets] : sous-ensemble à charger (défaut : tous — comportement
  /// historique). Chaque dataset est fetché indépendamment, EN PARALLÈLE,
  /// avec isolation d'erreur : un dataset en échec n'annule pas les autres
  /// et est nommé dans [syncError]. Si le set contient UN dataset de
  /// suggestions, il est élargi aux 5 modes (correctif I-001 — voir
  /// [suggestionDatasets]).
  ///
  /// [forceFull] : ignore les curseurs incrémentaux (bouton « Actualiser »).
  /// [skipAlreadyLoaded] : au moment où la passe DÉMARRE (après l'éventuelle
  /// sync précédente), ignore les datasets entre-temps chargés — seul ce qui
  /// manque encore est rechargé (usage interne d'ensureDatasets).
  ///
  /// **Stratégie de fusion** : les données serveur remplacent les données
  /// locales **uniquement pour les entrées déjà synchronisées** (UUID valide).
  /// Les entrées locales en attente (ID temporaire) sont conservées jusqu'à
  /// confirmation de leur écriture.
  ///
  /// **Sync incrémentale** (migration 0056) : si un curseur valide (< 24 h)
  /// existe pour un dataset, seules les lignes `updated_at >= curseur` sont
  /// fetchées puis fusionnées par id. Sinon, full sync du dataset.
  ///
  /// **Anti-réentrance (correctif I-004)** : chaînage de Future via
  /// [_ongoingSync] — chaque appel attend la fin RÉELLE de la passe
  /// précédente (quelle que soit sa durée, sans jamais repartir sur un
  /// compteur) puis exécute sa propre passe. L'erreur de la passe précédente
  /// n'est pas propagée à la suivante. Pas de boucle de polling.
  /// **Timeouts** : 30 s par requête HTTP (dans [SupabaseSync]) + budget
  /// global de 120 s (au moins une full sync) ou 45 s (tout en incrémental).
  Future<void> syncFromSupabase({
    Set<SyncDataset>? datasets,
    bool forceFull = false,
    bool skipAlreadyLoaded = false,
  }) async {
    if (sync == null) return;
    // I-001 : un dataset de suggestions demandé → les 5 modes dans la même
    // passe. L'élargissement est capturé à l'appel ; le filtre
    // skipAlreadyLoaded est appliqué au DÉMARRAGE de la passe (dans
    // [_syncPass]), pour ne recharger que ce qui manque encore.
    final Set<SyncDataset> wanted = _expandSuggestionModes(
      datasets ?? SyncDataset.values.toSet(),
    );
    // I-004 : chaînage APRÈS la fin réelle de la sync précédente. La passe
    // précédente ne remonte jamais d'erreur (elle est isolée dans
    // [_syncPass]), mais le try/catch est conservé par sécurité : une erreur
    // du passé ne doit JAMAIS empêcher la passe suivante.
    final Future<void>? previous = _ongoingSync;
    final Future<void> current = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      await _syncPass(
        wanted,
        forceFull: forceFull,
        skipAlreadyLoaded: skipAlreadyLoaded,
      );
    }();
    _ongoingSync = current;
    try {
      await current;
    } finally {
      // Ne libère le verrou que si aucune passe plus récente ne s'est chaînée.
      if (identical(_ongoingSync, current)) _ongoingSync = null;
    }
  }

  /// Exécute UNE passe de sync pour [wanted] (appelée par [syncFromSupabase]
  /// une fois la passe précédente terminée). Isole toutes les erreurs dans
  /// [syncError] : cette méthode ne remonte jamais d'exception.
  Future<void> _syncPass(
    Set<SyncDataset> wanted, {
    required bool forceFull,
    required bool skipAlreadyLoaded,
  }) async {
    if (skipAlreadyLoaded) {
      wanted = wanted.difference(_loadedDatasets);
      if (wanted.isEmpty) return;
    }
    isSyncing = true;
    _loadingDatasets.addAll(wanted);
    // ⚠️ On NE remet pas syncError à null ici : cela effacerait une erreur
    // d'action récente. On l'efface seulement si la sync réussit.
    notifyListeners();
    try {
      // Budget global : 45 s si TOUS les datasets à curseur demandés ont un
      // curseur valide (sync purement incrémentale), 120 s sinon (au moins
      // une full sync paginée — ex. 10k+ contenus).
      final bool incrementalOnly =
          !forceFull &&
          wanted.every(
            (SyncDataset d) =>
                !_cursorNames.containsKey(d) || _validCursorFor(d) != null,
          );
      final Duration budget = incrementalOnly
          ? const Duration(seconds: 45)
          : const Duration(seconds: 120);
      await _doSyncFromSupabase(wanted, forceFull: forceFull).timeout(
        budget,
        onTimeout: () {
          throw TimeoutException(
            'Synchronisation Supabase expirée (${budget.inSeconds} s) — '
            'datasets : ${wanted.map((d) => d.name).join(', ')}.',
          );
        },
      );
    } catch (e) {
      if (_isAuthError(e)) {
        // 401 détecté pendant une lecture service_role (suggestions) → même
        // traitement que pour les écritures : logout forcé.
        onAuthError?.call();
      } else {
        // Timeout du budget global ou coupure réseau → badge hors-ligne.
        if (_isNetworkError(e)) _setOffline(true);
        syncError = e.toString();
      }
    } finally {
      isSyncing = false;
      _loadingDatasets.clear();
      notifyListeners();
    }
  }

  /// Effectue réellement la sync (sans la garde ni le timeout — appelé par
  /// [syncFromSupabase]). Ne fetch QUE les [datasets] demandés, en parallèle,
  /// avec isolation d'erreur par dataset.
  Future<void> _doSyncFromSupabase(
    Set<SyncDataset> datasets, {
    required bool forceFull,
  }) async {
    final List<String> errors = <String>[];
    // Modes suggestions ayant bénéficié d'une FULL sync dans cette passe
    // (condition de purge des tombstones — voir plus bas).
    final Set<SyncDataset> fullModeSyncs = <SyncDataset>{};

    /// Exécute un job de dataset en isolant son erreur : un dataset en échec
    /// n'annule pas les autres ; le détail est consolidé et remonté dans
    /// [syncError] (jamais avalé). Seul le 401 remonte immédiatement
    /// (logout forcé).
    ///
    /// Pilote aussi le mode hors-ligne gracieux : un job réussi repasse
    /// [isOffline] à false ; un job en échec sur erreur réseau le passe à
    /// true (détection par les résultats des requêtes, sans connectivity_plus).
    Future<void> guard(String label, Future<void> Function() job) async {
      try {
        await job();
        _setOffline(false); // au moins une requête a abouti → en ligne
      } on AdminAuthException {
        rethrow;
      } catch (e) {
        if (_isNetworkError(e)) _setOffline(true);
        errors.add('$label : $e');
      }
    }

    const Map<SyncDataset, String> labels = <SyncDataset, String>{
      SyncDataset.games: 'jeux',
      SyncDataset.contents: 'contenus',
      SyncDataset.suggestionsNew: 'suggestions (nouvelles)',
      SyncDataset.sentinelleAnalyzing: 'sentinelle (analyse en cours)',
      SyncDataset.sentinelleAnalyzed: 'sentinelle (analysées)',
      SyncDataset.scruteur: 'scruteur',
      SyncDataset.gamesToCreate: 'jeux à créer',
      SyncDataset.subscriptions: 'abonnements',
      SyncDataset.banned: 'comptes à bannir',
    };

    // Datasets indépendants → fetchés EN PARALLÈLE (Future.wait).
    await Future.wait(<Future<void>>[
      if (datasets.contains(SyncDataset.games))
        guard(
          labels[SyncDataset.games]!,
          () => _syncGames(forceFull: forceFull),
        ),
      if (datasets.contains(SyncDataset.contents))
        guard(
          labels[SyncDataset.contents]!,
          () => _syncContents(forceFull: forceFull),
        ),
      if (datasets.contains(SyncDataset.suggestionsNew))
        guard(
          labels[SyncDataset.suggestionsNew]!,
          () => _syncSuggestionMode(
            SyncDataset.suggestionsNew,
            sync!.fetchSuggestions,
            forceFull: forceFull,
            fullModeSyncs: fullModeSyncs,
          ),
        ),
      if (datasets.contains(SyncDataset.sentinelleAnalyzing))
        guard(
          labels[SyncDataset.sentinelleAnalyzing]!,
          () => _syncSuggestionMode(
            SyncDataset.sentinelleAnalyzing,
            sync!.fetchSentinelleAnalyzing,
            forceFull: forceFull,
            fullModeSyncs: fullModeSyncs,
          ),
        ),
      if (datasets.contains(SyncDataset.sentinelleAnalyzed))
        guard(
          labels[SyncDataset.sentinelleAnalyzed]!,
          () => _syncSuggestionMode(
            SyncDataset.sentinelleAnalyzed,
            sync!.fetchSentinelleSuggestions,
            forceFull: forceFull,
            fullModeSyncs: fullModeSyncs,
          ),
        ),
      if (datasets.contains(SyncDataset.scruteur))
        guard(
          labels[SyncDataset.scruteur]!,
          () => _syncSuggestionMode(
            SyncDataset.scruteur,
            sync!.fetchScruteurSuggestions,
            forceFull: forceFull,
            fullModeSyncs: fullModeSyncs,
          ),
        ),
      if (datasets.contains(SyncDataset.gamesToCreate))
        guard(
          labels[SyncDataset.gamesToCreate]!,
          () => _syncSuggestionMode(
            SyncDataset.gamesToCreate,
            sync!.fetchGamesToCreate,
            forceFull: forceFull,
            fullModeSyncs: fullModeSyncs,
          ),
        ),
      if (datasets.contains(SyncDataset.subscriptions))
        guard(labels[SyncDataset.subscriptions]!, _syncSubscriptions),
      if (datasets.contains(SyncDataset.banned))
        guard(labels[SyncDataset.banned]!, _syncBanned),
    ]);

    // ── Purge des tombstones (correctif 27/08/2026) ──
    // Un id est retiré de _pendingRemovalIds quand sa disparition serveur est
    // CONFIRMÉE, c.-à-d. absent de TOUTES les listes fraîches. Cela exige un
    // snapshot complet des 5 modes en FULL sync : en sync incrémentale ou
    // partielle, les listes non rafraîchies ne prouvent rien → on conserve
    // le filtre (le prochain full sync — bouton Actualiser ou curseur > 24 h —
    // purgera). Inchangé par le correctif I-001 : la condition exige toujours
    // les 5 modes EN FULL (fullModeSyncs), pas seulement leur présence dans
    // la passe.
    if (_pendingRemovalIds.isNotEmpty &&
        suggestionDatasets.every(datasets.contains) &&
        suggestionDatasets.every(fullModeSyncs.contains)) {
      final Set<String> stillVisible = <String>{
        for (final s in _suggestions) s.id,
        for (final s in _sentinelleAnalyzing) s.id,
        for (final s in _sentinelleSuggestions) s.id,
        for (final s in _scruteurSuggestions) s.id,
        for (final s in _gamesToCreate) s.id,
      };
      _pendingRemovalIds.removeWhere((id) => !stillVisible.contains(id));
    }

    if (errors.isNotEmpty) {
      // Erreurs isolées par dataset, jamais avalées : détail dans syncError.
      throw Exception('Sync partielle — ${errors.join(' | ')}');
    }

    // Sync réussie : on efface l'erreur de sync (pas l'erreur d'action).
    syncError = null;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Jobs de sync par dataset (appelés en parallèle par _doSyncFromSupabase)
  // ─────────────────────────────────────────────────────────────────────

  /// Pagination parallèle par chunks de 3 pages (Future.wait).
  ///
  /// - Si [totalCount] est fourni (count HEAD `Prefer: count=exact`), le
  ///   nombre de pages est connu : on les fetch toutes par groupes de 3.
  /// - Sinon (suggestions via EF : pas de count par mode), chunks
  ///   SPÉCULATIFS de 3 pages : on s'arrête dès qu'une page du chunk n'est
  ///   pas pleine (les pages suivantes du chunk, déjà fetchées, sont vides
  ///   ou partielles au-delà de la fin — les absorber est sans effet).
  ///
  /// Retourne toutes les lignes + le max `updated_at` vu (curseur).
  Future<({List<T> items, DateTime? maxUpdatedAt})> _fetchPaged<T>(
    Future<({List<T> items, DateTime? maxUpdatedAt})> Function(int page)
    fetchPage,
    int pageSize, {
    int? totalCount,
    int maxItems = 500000,
  }) async {
    final List<T> items = <T>[];
    DateTime? maxUp;
    void absorb(({List<T> items, DateTime? maxUpdatedAt}) r) {
      items.addAll(r.items);
      final DateTime? m = r.maxUpdatedAt;
      if (m != null && (maxUp == null || m.isAfter(maxUp!))) maxUp = m;
    }

    if (totalCount != null && totalCount >= 0) {
      final int totalPages = (totalCount + pageSize - 1) ~/ pageSize;
      for (var start = 0; start < totalPages; start += 3) {
        final int end = (start + 3 > totalPages) ? totalPages : start + 3;
        final results = await Future.wait(
          <Future<({List<T> items, DateTime? maxUpdatedAt})>>[
            for (var p = start; p < end; p++) fetchPage(p),
          ],
        );
        for (final r in results) {
          absorb(r);
        }
      }
    } else {
      for (var start = 0; start * pageSize < maxItems; start += 3) {
        final results = await Future.wait(
          <Future<({List<T> items, DateTime? maxUpdatedAt})>>[
            for (var p = start; p < start + 3; p++) fetchPage(p),
          ],
        );
        var allFull = true;
        for (final r in results) {
          absorb(r);
          if (r.items.length < pageSize) allFull = false;
        }
        if (!allFull) break; // fin des données
      }
    }
    return (items: items, maxUpdatedAt: maxUp);
  }

  /// Dataset `games` : full (count HEAD + pages ∥) ou incrémental
  /// (`updated_at >= curseur`, upsert par id).
  Future<void> _syncGames({required bool forceFull}) async {
    const int pageSize = 1000;
    final String? cursor = forceFull
        ? null
        : _validCursorFor(SyncDataset.games);
    DateTime? maxUp;
    if (cursor != null) {
      final r = await _fetchPaged<Game>(
        (p) => sync!.fetchGames(page: p, pageSize: pageSize, since: cursor),
        pageSize,
        maxItems: 100000,
      );
      maxUp = r.maxUpdatedAt;
      if (r.items.isNotEmpty) {
        final Map<String, Game> byId = <String, Game>{
          for (final g in _games) g.id: g,
        };
        for (final g in r.items) {
          byId[g.id] = g; // upsert par id
        }
        _games = byId.values.toList()..sort(_byName);
      }
    } else {
      final int count = await sync!.fetchTableCount('games');
      final r = await _fetchPaged<Game>(
        (p) => sync!.fetchGames(page: p, pageSize: pageSize),
        pageSize,
        totalCount: count,
        maxItems: 100000,
      );
      maxUp = r.maxUpdatedAt;
      final pendingGames = _games.where((g) => !_isUuid(g.id)).toList();
      _games = [...r.items, ...pendingGames]..sort(_byName);
    }
    _saveCursorFor(SyncDataset.games, maxUp);
    _markDatasetLoaded(SyncDataset.games);
    _store.saveGames(_games);
  }

  /// Dataset `contents` : full (count HEAD + pages ∥) ou incrémental
  /// (`updated_at >= curseur`, upsert par id + retraits via cache_ops).
  Future<void> _syncContents({required bool forceFull}) async {
    const int pageSize = 1000;
    final String? cursor = forceFull
        ? null
        : _validCursorFor(SyncDataset.contents);
    DateTime? maxUp;
    if (cursor != null) {
      final r = await _fetchPaged<Content>(
        (p) => sync!.fetchContents(page: p, pageSize: pageSize, since: cursor),
        pageSize,
      );
      maxUp = r.maxUpdatedAt;
      if (r.items.isNotEmpty) {
        final Map<String, Content> byId = <String, Content>{
          for (final c in _contents) c.id: c,
        };
        for (final c in r.items) {
          byId[c.id] = c; // upsert par id
        }
        _contents = byId.values.toList();
      }
      // Suppressions serveur : journal cache_ops (op='remove') → retrait des
      // contenus locaux dont l'URL correspond (comparaison exacte).
      await _applyCacheOpsRemovals();
    } else {
      final int count = await sync!.fetchTableCount('contents');
      final r = await _fetchPaged<Content>(
        (p) => sync!.fetchContents(page: p, pageSize: pageSize),
        pageSize,
        totalCount: count,
      );
      maxUp = r.maxUpdatedAt;
      final pendingContents = _contents.where((c) => !_isUuid(c.id)).toList();
      _contents = [...r.items, ...pendingContents];
      // Le snapshot complet reflète déjà tout le journal cache_ops → on
      // avance le curseur du journal pour ne pas rejouer d'anciens 'remove'
      // au prochain passage incrémental (sinon un contenu supprimé puis
      // recréé à la MÊME URL serait retiré localement à tort — revue I-003).
      _store.saveCursor(
        _cacheOpsCursorName,
        DateTime.now().toUtc().subtract(_cursorSafetyMargin).toIso8601String(),
        DateTime.now().toUtc(),
      );
    }
    _saveCursorFor(SyncDataset.contents, maxUp);
    _markDatasetLoaded(SyncDataset.contents);
    _store.saveContents(_contents);
  }

  /// Applique les retraits du journal cache_ops aux contenus locaux.
  /// Non critique : un échec ne bloque pas la sync contenus (le prochain
  /// passage rattrapera, le curseur cache_ops n'ayant pas avancé).
  Future<void> _applyCacheOpsRemovals() async {
    try {
      final cached = _store.loadCursor(_cacheOpsCursorName);
      final bool valid =
          cached != null &&
          DateTime.now().toUtc().difference(cached.fetchedAt.toUtc()) <=
              _cursorMaxAge;
      final r = await sync!.fetchRemovedContentUrls(
        since: valid ? cached.value : null,
      );
      if (r.removedUrls.isNotEmpty) {
        _contents = _contents
            .where((c) => !r.removedUrls.contains(c.url))
            .toList();
      }
      if (r.maxCreatedAt != null) {
        _store.saveCursor(
          _cacheOpsCursorName,
          r.maxCreatedAt!
              .toUtc()
              .subtract(_cursorSafetyMargin)
              .toIso8601String(),
          DateTime.now().toUtc(),
        );
      }
    } on AdminAuthException {
      rethrow; // 401 → logout forcé
    } catch (e) {
      debugPrint('cache-ops/list échec (non critique): $e');
    }
  }

  /// Dataset suggestions d'un mode : full (remplacement de la liste) ou
  /// incrémental (`since` propagé à l'EF v63, fusion multi-modes par id).
  Future<void> _syncSuggestionMode(
    SyncDataset dataset,
    Future<({List<Suggestion> items, DateTime? maxUpdatedAt})> Function({
      int page,
      int pageSize,
      String? since,
    })
    fetcher, {
    required bool forceFull,
    required Set<SyncDataset> fullModeSyncs,
  }) async {
    const int pageSize = 500;
    final String? cursor = forceFull ? null : _validCursorFor(dataset);
    final r = await _fetchPaged<Suggestion>(
      (p) => fetcher(page: p, pageSize: pageSize, since: cursor),
      pageSize,
      maxItems: 100000,
    );
    // ── Tombstones : une ligne tout juste rejetée/acceptée peut encore
    //    figurer dans le snapshot entrant (fetch émis AVANT le commit
    //    serveur). On EXCLUT ces ids des listes entrantes, en full comme en
    //    incrémental (le filtre reste actif jusqu'à la purge par un full
    //    sync des 5 modes).
    final List<Suggestion> items = r.items
        .where((s) => !_pendingRemovalIds.contains(s.id))
        .toList();
    if (cursor != null) {
      _mergeSuggestionsIncremental(dataset, items);
    } else {
      _setSuggestionModeList(dataset, items);
      fullModeSyncs.add(dataset);
    }
    _saveCursorFor(dataset, r.maxUpdatedAt);
    _markDatasetLoaded(dataset);
    _store.saveSuggestions(_suggestions);
  }

  /// Fusion incrémentale d'un delta de suggestions dans la liste du mode
  /// [dataset].
  ///
  /// ⚠️ Piège des changements de mode : une suggestion n'existe que dans UN
  /// mode à la fois. Une ligne qui CHANGE de mode (ex. Sentinelle la prend
  /// en charge → quitte « new » pour « analyzing ») apparaît dans le delta
  /// du NOUVEAU mode : on retire donc son id de TOUTES les autres listes
  /// avant de l'insérer dans la bonne. Une ligne ayant quitté TOUS les modes
  /// (acceptée/rejetée ailleurs) n'apparaît dans aucun delta : couverte par
  /// les tombstones pour les actions locales + par la full sync de sécurité
  /// (curseur > 24 h ou bouton Actualiser).
  void _mergeSuggestionsIncremental(
    SyncDataset dataset,
    List<Suggestion> changed,
  ) {
    if (changed.isEmpty) return;
    final Set<String> changedIds = changed.map((s) => s.id).toSet();
    bool notChanged(Suggestion s) => !changedIds.contains(s.id);
    if (dataset != SyncDataset.suggestionsNew) {
      _suggestions = _suggestions.where(notChanged).toList();
    }
    if (dataset != SyncDataset.sentinelleAnalyzing) {
      _sentinelleAnalyzing = _sentinelleAnalyzing.where(notChanged).toList();
    }
    if (dataset != SyncDataset.sentinelleAnalyzed) {
      _sentinelleSuggestions = _sentinelleSuggestions
          .where(notChanged)
          .toList();
    }
    if (dataset != SyncDataset.scruteur) {
      _scruteurSuggestions = _scruteurSuggestions.where(notChanged).toList();
    }
    if (dataset != SyncDataset.gamesToCreate) {
      _gamesToCreate = _gamesToCreate.where(notChanged).toList();
    }
    // Upsert dans la liste cible.
    final Map<String, Suggestion> byId = <String, Suggestion>{
      for (final s in _suggestionListFor(dataset)) s.id: s,
    };
    for (final s in changed) {
      byId[s.id] = s;
    }
    _setSuggestionModeList(dataset, byId.values.toList());
  }

  /// Liste locale d'un mode de suggestions.
  List<Suggestion> _suggestionListFor(SyncDataset dataset) => switch (dataset) {
    SyncDataset.suggestionsNew => _suggestions,
    SyncDataset.sentinelleAnalyzing => _sentinelleAnalyzing,
    SyncDataset.sentinelleAnalyzed => _sentinelleSuggestions,
    SyncDataset.scruteur => _scruteurSuggestions,
    SyncDataset.gamesToCreate => _gamesToCreate,
    _ => const <Suggestion>[],
  };

  /// Remplace la liste d'un mode (full sync). Pour `suggestionsNew`, les
  /// entrées locales non synchronisées (ID temporaire) sont conservées.
  void _setSuggestionModeList(SyncDataset dataset, List<Suggestion> items) {
    switch (dataset) {
      case SyncDataset.suggestionsNew:
        final pendingSuggestions = _suggestions
            .where((s) => !_isUuid(s.id))
            .toList();
        _suggestions = [...items, ...pendingSuggestions];
      case SyncDataset.sentinelleAnalyzing:
        _sentinelleAnalyzing = items;
      case SyncDataset.sentinelleAnalyzed:
        _sentinelleSuggestions = items;
      case SyncDataset.scruteur:
        _scruteurSuggestions = items;
      case SyncDataset.gamesToCreate:
        _gamesToCreate = items;
      default:
        break;
    }
  }

  /// Dataset `subscriptions` (Edge Function, pas de curseur : petit volume).
  /// Fusion serveur + locaux non synchronisables (ID non UUID = démo).
  Future<void> _syncSubscriptions() async {
    final List<Map<String, dynamic>> serverPlus = await sync!
        .fetchSubscriptions();
    final localOnlyPlus = _plus.where((p) => !_isUuid(p.id)).toList();
    _plus = [
      ...serverPlus.map(
        (m) => PlusUser(
          id: m['id'] as String,
          displayName: m['displayName'] as String? ?? 'Inconnu',
          plan: m['plan'] as String? ?? 'monthly',
          startedAt:
              DateTime.tryParse(m['startedAt'] as String? ?? '') ??
              DateTime.now(),
          active: m['active'] as bool? ?? false,
          source: m['source'] as String? ?? 'admin',
        ),
      ),
      ...localOnlyPlus,
    ];
    _store.savePlus(_plus);
    _markDatasetLoaded(SyncDataset.subscriptions);
  }

  /// Dataset `banned` : utilisateurs bannis + mauvais contributeurs (menu
  /// « Comptes à bannir »). Sous-fetchs non critiques : en cas d'échec de
  /// l'un, on garde le cache précédent de celui-ci sans annuler l'autre.
  Future<void> _syncBanned() async {
    // Bannis : la liste serveur (source de vérité) remplace les entrées
    // synchronisées ; les bannis locaux non UUID (démo / manuels non
    // synchronisables) sont conservés. Sans cette sync, un utilisateur banni
    // depuis un autre menu n'apparaîtrait pas comme banni ici.
    try {
      final bannedData = await sync!.fetchBannedUsers();
      final serverBanned = bannedData
          .map(
            (b) => BannedUser(
              id: b['id'] as String,
              displayName: b['displayName'] as String? ?? 'Inconnu',
              bannedAt: DateTime.now(),
              reason: b['reason'] as String?,
            ),
          )
          .toList();
      final localOnlyBanned = _banned.where((b) => !_isUuid(b.id)).toList();
      _banned = [...localOnlyBanned, ...serverBanned];
      _store.saveBanned(_banned);
    } on AdminAuthException {
      rethrow;
    } catch (e) {
      debugPrint('fetchBanned échec: $e');
    }
    // Mauvais contributeurs : non critique, cache conservé en cas d'échec.
    try {
      _badContributors = await sync!.fetchBadContributors();
    } on AdminAuthException {
      rethrow;
    } catch (e) {
      debugPrint('fetchBadContributors échec: $e');
    }
    _markDatasetLoaded(SyncDataset.banned);
  }

  /// Vrai UUID Supabase ? (36 caractères, format xxxxxxxx-xxxx-...).
  static bool _isUuid(String id) =>
      id.length == 36 &&
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(id);

  /// Met à jour le jeton admin pour les écritures Supabase (appelé après
  /// login/logout ET après chaque écriture via le fresh_token de la sliding
  /// session).
  ///
  /// ⚠️ Ne resync QUE sur un VRAI login (transition « pas de token » →
  /// « token valide »). Une simple ROTATION du token (fresh_token renvoyé
  /// par l'EF après chaque écriture) ne doit PAS déclencher de resync
  /// global — sinon chaque édition rechargeait toute la base (jeux +
  /// contenus + suggestions + abonnements...), d'où le lag de 5-6 s et le
  /// double refresh observés dans le menu Contenus (fix 28/08/2026).
  void updateAdminToken(String? token) {
    if (sync == null) return;
    if (token == _lastToken) return; // pas de changement → pas de resync
    final hadToken = _lastToken != null && _lastToken!.isNotEmpty;
    final hasToken = token != null && token.isNotEmpty;
    _lastToken = token;
    // Relit is_owner / username depuis le JWT (login ET fresh_token : la
    // route /logs affichée côté owner doit rester exacte après rotation).
    _applySessionClaims(token);
    if (hasToken) {
      sync!.setAdminToken(token);
      // Resync uniquement au login (hadToken == false). Sur rotation, les
      // données locales sont déjà à jour (updates optimistes des écritures).
      // Chargement paresseux : au login on ne charge que les datasets du
      // dashboard ; les menus lourds (Sentinelle, Scruteur…) déclenchent
      // le leur à l'ouverture via ensureDatasets.
      if (!hadToken) {
        ensureDatasets(dashboardDatasets);
      }
    } else {
      sync!.setAdminToken('');
    }
  }

  static int _byName(Game a, Game b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
