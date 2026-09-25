import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/store.dart';
import '../data/supabase_sync.dart';
import '../domain/analytics_calc.dart';
import '../domain/models/banned_user.dart';
import '../domain/models/category.dart';
import '../domain/models/content.dart';
import '../domain/models/game.dart';
import '../domain/models/game_alias.dart';
import '../domain/models/plus_user.dart';
import '../domain/models/suggestion.dart';
import '../domain/models/sync_status.dart';
import '../domain/plus_paging.dart';
import '../domain/title_cleaning.dart';

/// Détecte si une erreur provient d'un token admin expiré/invalide (HTTP 401).
bool _isAuthError(Object e) => e is AdminAuthException;

/// Datasets synchronisables indépendamment (chargement paresseux par menu).
///
/// Chaque écran déclare ses besoins via [StoreController.ensureDatasets] ;
/// seuls les datasets demandés (manquants OU périmés — chargés depuis plus
/// de 2 min) sont fetchés. Les resyncs post-action ne rechargent que les
/// datasets impactés.
///
/// - [games] : catalogue des jeux (PostgREST anon).
/// - [contents] : contenus validés (PostgREST anon, le plus volumineux).
/// - [suggestionsNew] : suggestions jamais prises en charge (menu Suggestions).
/// - [sentinelleAnalyzing] : analyses Sentinelle en cours.
/// - [sentinelleAnalyzed] : suggestions analysées par Sentinelle.
/// - [scruteur] : suggestions du bot Scruteur (sites de guides).
/// - [gamesToCreate] : file « Jeux à créer ».
/// - [banned] : comptes bannis + mauvais contributeurs (menu Comptes à bannir).
///
/// Les abonnements Plus ne sont PLUS un dataset synchronisé (migration 0085) :
/// pagination serveur à la demande ([StoreController.fetchPlusPage],
/// [StoreController.refreshPlusStats]) — jamais de chargement complet.
enum SyncDataset {
  games,
  contents,
  suggestionsNew,
  sentinelleAnalyzing,
  sentinelleAnalyzed,
  scruteur,
  gamesToCreate,
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

  /// D3.4 — dernière NOTICE d'action (avertissement LÉGER, ex. alias candidat
  /// non créé après une validation réussie) — affichée dans une snackbar
  /// orange, puis effacée. Distincte de [lastActionError] (rouge) : la
  /// validation elle-même a réussi.
  String? lastActionNotice;

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

  /// Seuil de fraîcheur d'un dataset (auto-refresh à l'arrivée sur un menu) :
  /// un dataset chargé depuis moins longtemps que cette durée est considéré
  /// frais et n'est PAS refetch (pas de tempête de requêtes en navigation
  /// rapide) ; au-delà, il est inclus dans la passe (sync incrémentale via
  /// curseurs — coût minime).
  static const Duration _datasetFreshness = Duration(minutes: 2);

  /// Ce dataset est-il chargé ET frais (< [_datasetFreshness]) ?
  /// Un dataset jamais chargé, ou sans horodatage, n'est jamais frais.
  bool _isFresh(SyncDataset dataset) {
    if (!_loadedDatasets.contains(dataset)) return false;
    final DateTime? t = _datasetLoadedAt[dataset];
    if (t == null) return false;
    return DateTime.now().difference(t) < _datasetFreshness;
  }

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
  /// réussi ; [ensureDatasets] ne recharge pas ce qui y figure déjà ET est
  /// encore frais (< [_datasetFreshness]).
  final Set<SyncDataset> _loadedDatasets = <SyncDataset>{};

  /// Datasets en cours de chargement (pour l'indicateur par écran).
  final Set<SyncDataset> _loadingDatasets = <SyncDataset>{};

  /// Datasets dont le fetch est EN VOL dans la passe courante (diagnostic du
  /// watchdog anti-spinner-infini : ce sont eux qui pendent si la passe ne
  /// finit pas). Alimenté par le `guard` de [_doSyncFromSupabase].
  final Set<SyncDataset> _inFlightDatasets = <SyncDataset>{};

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

  /// Suppression DÉFINITIVE d'un abonnement Plus : compte principal
  /// uniquement (l'EF renvoie 403 sinon) ; toujours permise en mode aperçu
  /// (liste locale).
  bool get canDeletePlus => sync == null || _isOwner;

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

  /// Signale une erreur de validation côté écran (snackbar rouge via le
  /// shell) — point d'entrée public pour les écrans (validation locale
  /// avant appel EF, ex. montant invalide dans un dialog Analytics).
  void reportActionError(String message) {
    lastActionError = message;
    notifyListeners();
  }

  /// Efface la dernière notice d'action (avertissement léger, D3.4).
  void clearActionNotice() {
    lastActionNotice = null;
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

  /// Abonnés Plus du MODE APERÇU LOCAL uniquement (sans Supabase). En
  /// production, la liste n'est JAMAIS chargée en entier ni persistée
  /// (migration 0085) : pages serveur via [fetchPlusPage].
  List<PlusUser> _plus = <PlusUser>[];

  /// Compteurs des abonnés (route `subscriptions/stats`) — null tant que non
  /// chargés.
  PlusStats? _plusStats;

  /// Numéro de la dernière demande de compteurs (seule la plus récente est
  /// appliquée — demandes concurrentes possibles après des écritures).
  int _plusStatsSeq = 0;

  /// Incrémenté à chaque écriture d'abonnement réussie et à chaque
  /// « Actualiser » : les écrans paginés (menu Abonnements, accordéon du
  /// dashboard) rechargent alors leur page courante.
  int _plusRevision = 0;

  /// Indicateurs « abonné Plus actif » des auteurs de suggestions (badge
  /// PLUS / bouton « Plus ») — voir [isPlusUser].
  final PlusFlags _plusFlags = PlusFlags();

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

  /// Compteurs des abonnés Plus (total, actifs…) — null tant que non chargés
  /// (voir [refreshPlusStats]).
  PlusStats? get plusStats => _plusStats;

  /// Révision des abonnements : change après chaque écriture réussie et à
  /// chaque « Actualiser » — les écrans paginés rechargent leur page.
  int get plusRevision => _plusRevision;

  /// Mauvais contributeurs (taux de rejet élevé) pour le menu
  /// « Comptes à bannir ». Liste non modifiable (lecture seule côté UI).
  List<Map<String, dynamic>> get badContributors =>
      List<Map<String, dynamic>>.unmodifiable(_badContributors);

  /// L'auteur d'une suggestion est-il actuellement banni ?
  bool isAuthorBanned(String authorId) => _banned.any((b) => b.id == authorId);

  /// Un utilisateur est-il abonné Plus ACTIF (is_active) ?
  ///
  /// Production : indicateur `author_is_plus` des suggestions lues, corrigé
  /// par le résultat des actions de la session — la liste complète des
  /// abonnés n'est plus chargée (migration 0085). Inconnu → false.
  /// Aperçu local : liste locale.
  bool isPlusUser(String userId) {
    if (sync == null) return _plus.any((p) => p.id == userId && p.active);
    return _plusFlags.isPlus(userId);
  }

  /// Ajoute un utilisateur en Plus directement depuis son user_id (UUID).
  /// Utilisé par le bouton "Plus" dans le menu Suggestions/Sentinelle : sans
  /// effet s'il est déjà connu comme abonné actif. Voir [grantPlus].
  Future<bool> addPlusByUserId({
    required String userId,
    required String displayName,
    String plan = 'monthly',
  }) async {
    if (isPlusUser(userId)) return true; // déjà Plus
    return grantPlus(userId: userId, displayName: displayName, plan: plan);
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

  /// Répartition par langue des contenus validés d'un jeu (tooltip de la
  /// cellule « Contenus » du tableau des jeux — chantier G).
  ///
  /// Calcul 100 % EN MÉMOIRE (groupBy sur `_contents` déjà chargés — AUCUNE
  /// requête réseau, egress nul). Les codes `videoLanguage` sont normalisés
  /// en majuscules. Un code HORS des 12 langues `kSupportedLanguages` (ex.
  /// « NL » tagué par un bot) reste compté dans [byLang] : l'UI l'affiche
  /// en ligne fourre-tout « 🌐 Autre (CODE) » (I-001) pour que la somme du
  /// tooltip corresponde au compteur affiché.
  /// [noLang] compte les contenus validés sans langue taguée (video_language
  /// NULL — contenus non vidéo ou pré-taggants) : affiché en dernière ligne
  /// du tooltip pour que la somme corresponde au compteur affiché.
  ({Map<String, int> byLang, int noLang}) contentCountByLangFor(String gameId) {
    final byLang = <String, int>{};
    var noLang = 0;
    for (final c in _contents) {
      if (c.gameId != gameId || !c.validated) continue;
      final lang = c.videoLanguage?.trim().toUpperCase() ?? '';
      if (lang.isEmpty) {
        noLang++;
      } else {
        byLang[lang] = (byLang[lang] ?? 0) + 1;
      }
    }
    return (byLang: byLang, noLang: noLang);
  }

  /// Ajoute un jeu. En mode production, attend la confirmation serveur.
  /// En cas d'échec, le jeu est retiré (rollback) et l'erreur est notifiée.
  Future<void> addGame({
    required String name,
    String? publisher,
    String? coverUrl,
    String? releaseDate,
    bool active = true,
  }) async {
    final Game game = Game(
      id: 'g-${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim(),
      publisher: publisher?.trim().isEmpty == true ? null : publisher?.trim(),
      coverUrl: coverUrl?.trim().isEmpty == true ? null : coverUrl?.trim(),
      releaseDate:
          releaseDate?.trim().isEmpty == true ? null : releaseDate?.trim(),
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
  /// peut être limitée par la pagination à 1000 lignes). Inclut les AUTRES
  /// NOMS par langue (§119).
  Future<({Map<String, String> titles, Map<String, List<String>> altTitles})>
      loadTranslationsForGame(String gameId) async {
    const empty = (
      titles: <String, String>{},
      altTitles: <String, List<String>>{},
    );
    if (sync == null) return empty;
    try {
      return await sync!.fetchTranslationsForGame(gameId);
    } on AdminAuthException {
      rethrow;
    } catch (e) {
      debugPrint('loadTranslationsForGame échoué: $e');
      return empty;
    }
  }

  /// Sauvegarde les traductions du titre d'un jeu. [translations] contient
  /// uniquement les langues non vides (filtrées par le caller) ;
  /// [altTitles] leurs AUTRES NOMS (§119 — liste vide = effacés).
  ///
  /// Pas de mise à jour du `Game` en mémoire : les traductions ne sont pas
  /// affichées dans la liste principale des jeux. En cas d'échec serveur,
  /// `lastActionError` est positionnée (le dialog affiche l'erreur).
  Future<bool> updateGameTranslations(
    Game game,
    Map<String, String> translations, {
    Map<String, List<String>>? altTitles,
  }) async {
    if (sync == null) {
      lastActionError = 'Mode aperçu : traductions non persistées.';
      notifyListeners();
      return false;
    }
    try {
      final ok = await sync!.updateGameTranslations(game.id, translations,
          altTitles: altTitles);
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
  ///
  /// [aliasCandidateChecked] : D3.4 — vrai quand la case « Ajouter cet alias
  /// à la base à la validation » du panneau Sentinelle est cochée (défaut).
  /// L'alias candidat est créé en best-effort APRÈS succès, uniquement si le
  /// jeu choisi dans le dialogue EST celui du candidat ; un échec produit
  /// une notice légère mais la validation reste faite.
  Future<void> acceptSuggestion({
    required Suggestion suggestion,
    required String gameId,
    required ContentCategory category,
    required String titleAdmin,
    String? imageUrl,
    bool aliasCandidateChecked = false,
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
      // D3.4 — alias candidat coché (panneau Sentinelle « À vérifier »,
      // transmis via le dialogue) : création best-effort APRÈS succès. La
      // garde « jeu choisi == jeu du candidat » est dans
      // [_createAliasCandidate] ; échec = notice légère, validation faite.
      final candidate = suggestion.aiRecommendation?.aliasCandidate;
      if (aliasCandidateChecked && candidate != null) {
        Game? game;
        for (final g in _games) {
          if (g.id == gameId) {
            game = g;
            break;
          }
        }
        if (game != null) {
          final aliasError = await _createAliasCandidate(
            game: game,
            candidate: candidate,
          );
          if (aliasError != null) {
            lastActionNotice = '⚠️ Contenu validé, mais $aliasError.';
            notifyListeners();
          }
        }
      }
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
  ///
  /// [aliasCandidateChecked] : D3.4 — vrai quand la case « Ajouter cet alias
  /// à la base à la validation » est cochée (défaut) sur la ligne. L'alias
  /// candidat est alors créé en best-effort APRÈS succès de l'acceptation ;
  /// un échec produit une notice légère mais la validation reste faite.
  Future<void> acceptOneClick(
    Suggestion suggestion, {
    String? gameOverride,
    String? categoryOverride,
    String? titleOverride,
    bool aliasCandidateChecked = false,
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
      // D3.4 — alias candidat coché : création best-effort APRÈS succès de
      // l'acceptation. Un échec ici ne doit JAMAIS invalider la validation
      // (déjà faite) → notice légère uniquement (la création est re-jouable
      // via le dialog d'alias du jeu).
      final candidate = ai.aliasCandidate;
      if (aliasCandidateChecked && candidate != null) {
        final aliasError = await _createAliasCandidate(
          game: targetGame,
          candidate: candidate,
        );
        if (aliasError != null) {
          lastActionNotice = '⚠️ Contenu validé, mais $aliasError.';
          notifyListeners();
        }
      }
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
  ///
  /// [aliasCandidateCheckedIds] : D3.4 — ids des suggestions dont l'alias
  /// candidat est COCHÉ (défaut) dans le panneau. Pour chaque item validé,
  /// l'alias est créé en best-effort APRÈS succès du lot (UNE requête
  /// list-all pour tout le lot) ; les échecs produisent une notice légère
  /// agrégée — les validations restent faites.
  Future<int> acceptSentinelleBatch(
    List<Suggestion> items, {
    Map<String, String>? gameOverrides,
    Map<String, String>? categoryOverrides,
    Map<String, String>? titleOverrides,
    Set<String>? aliasCandidateCheckedIds,
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
          aliasCandidateChecked:
              aliasCandidateCheckedIds?.contains(s.id) ?? false,
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
    // D3.4 — couples (jeu résolu, alias candidat) des items COCHÉS, pour la
    // création best-effort post-validation (phase 4).
    final aliasCandidates = <String, (Game, AiAliasCandidate)>{};
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
      // D3.4 — mémorise le candidat SEULEMENT si la case est cochée.
      final candidate = ai.aliasCandidate;
      if (candidate != null &&
          (aliasCandidateCheckedIds?.contains(s.id) ?? false)) {
        aliasCandidates[s.id] = (targetGame, candidate);
      }
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
    final validatedIds = <String>{};
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
        validatedIds.addAll(ok);
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

    // ── D3.4 — alias candidats COCHÉS des items VALIDÉS : création
    //    best-effort APRÈS succès du lot (UNE requête list-all pour tout le
    //    lot, cache mutable par jeu). Un échec ici ne doit JAMAIS invalider
    //    les validations (déjà faites) → notice légère agrégée uniquement.
    final toCreate = aliasCandidates.entries
        .where((e) => validatedIds.contains(e.key))
        .toList();
    if (toCreate.isNotEmpty) {
      try {
        final aliasesByGame = await _fetchGameAliasesByGame();
        final aliasErrors = <String>[];
        for (final e in toCreate) {
          final (game, candidate) = e.value;
          final err = await _createAliasCandidate(
            game: game,
            candidate: candidate,
            aliasesByGame: aliasesByGame,
          );
          if (err != null) aliasErrors.add(err);
        }
        if (aliasErrors.isNotEmpty) {
          lastActionNotice = '⚠️ Validations effectuées, mais '
              '${aliasErrors.length} alias candidat(s) non créé(s) : '
              '${aliasErrors.first}';
        }
      } catch (e) {
        lastActionNotice = '⚠️ Validations effectuées, mais la création des '
            'alias candidats a échoué ($e).';
      }
    }
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
      final result = await sync!.unlockStuckSuggestions();
      final int unlocked = result.unlocked;
      if (unlocked > 0) {
        // Correctif F3 (chantier Sentinelle) : retrait OPTIMISTE immédiat
        // des ids débloqués du board « Analyses en cours » — l'admin voit
        // les lignes disparaître sans attendre la resync (AC5).
        if (result.ids.isNotEmpty) {
          // Cas nominal : l'EF (v71+) renvoie les ids exacts débloqués.
          final Set<String> unlockedIds = result.ids.toSet();
          _sentinelleAnalyzing = _sentinelleAnalyzing
              .where((s) => !unlockedIds.contains(s.id))
              .toList();
        } else {
          // Repli (EF ancienne révision sans `ids`) : critère miroir de
          // l'EF — sentinelle_started_at posé depuis > 10 min (les entrées
          // d'analyzing n'ont par définition pas encore de verdict).
          final DateTime cutoff = DateTime.now().subtract(
            const Duration(minutes: 10),
          );
          _sentinelleAnalyzing = _sentinelleAnalyzing.where((s) {
            final DateTime? started = s.sentinelleStartedAt;
            return started == null || started.isAfter(cutoff);
          }).toList();
        }
        notifyListeners();
        // ⚠️ PAS de tombstone (_pendingRemovalIds) ici : les lignes ne sont
        // pas supprimées, elles CHANGENT de mode (analyzing → new) — un
        // tombstone les exclurait du delta « new » entrant et les
        // masquerait du menu Suggestions.
        // Resync ciblée en filet de sécurité : la fusion multi-modes de la
        // sync incrémentale confirme le retrait optimiste et fait
        // réapparaître les lignes dans « new ».
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
    final game = gameName?.trim();
    final translated = (game == null || game.isEmpty)
        ? null
        : _gameTranslationsCache[_normalizeGameName(game)];
    // §123 — titre PROPOSÉ par Sentinelle (toutes plateformes : nettoyé avec
    // les alias distants et les noms traduits, domaine du site pour une page
    // web) : affiché tel quel ; re-nettoyé seulement si l'admin a choisi un
    // AUTRE jeu que celui de l'analyse.
    // §125 — nom de la chaîne (YouTube, bilibili, RUTUBE) retiré s'il est
    // détaché ; appliqué AUSSI au titre proposé : les analyses d'avant §125
    // l'y ont laissé (sans effet sur un titre déjà nettoyé).
    final channel = s.aiRecommendation?.channelName;
    final proposed = s.aiRecommendation?.proposedTitle?.trim();
    if (proposed != null && proposed.isNotEmpty) {
      final aiGame = s.aiRecommendation?.suggestedGame?.trim() ?? '';
      if (game == null ||
          game.isEmpty ||
          _normalizeGameName(game) == _normalizeGameName(aiGame)) {
        return _stripChannelName(proposed, channel,
            gameName: (game == null || game.isEmpty) ? aiGame : game);
      }
      return _cleanTitleForInsertion(proposed,
          gameName: game, translatedNames: translated, channelName: channel);
    }
    // Analyse d'avant §123 :
    // 1. Titre YouTube réel (le plus fiable).
    final ytTitle = s.aiRecommendation?.youtubeTitle;
    final base = (ytTitle != null && ytTitle.trim().isNotEmpty)
        ? ytTitle.trim()
        // 2. Fallback : texte partagé nettoyé.
        : _cleanTitle(s);
    // §123 : entités HTML décodées même sans jeu (« &#039; » → « ' »).
    final cleaned = (game == null || game.isEmpty)
        ? _stripChannelName(_decodeHtmlEntities(base), channel)
        // D1.4 — titres traduits du jeu (cache best-effort du StoreController ;
        // null si non chargé — comportement antérieur inchangé).
        : _cleanTitleForInsertion(base,
            gameName: game, translatedNames: translated, channelName: channel);
    // §123 (A) — page web : domaine du site dans le titre.
    return isVideoPlatformUrl(s.url)
        ? cleaned
        : webTitleWithDomain(cleaned, s.url);
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

  // ── Nettoyage des titres d'insertion (règles 11/09 + 12/09/2026, §123) ──
  // Code PUR dans lib/domain/title_cleaning.dart (§123 : testable en VM,
  // sans dart:html — test/title_clean_test.dart). Délégations privées : le
  // reste du contrôleur est inchangé. ⚠️ Toute évolution de
  // GameMatcher._aliases (tools/vision) doit être reportée dans
  // TitleCleaning.gameAliases (et dans tools/sentinelle/lib/game_matcher.dart).

  /// Alias connus → nom canonique normalisé ([TitleCleaning.gameAliases]).
  static const Map<String, String> _gameAliases = TitleCleaning.gameAliases;

  /// Nom de jeu normalisé AVEC résolution d'alias.
  static String _normalizeGameName(String name) =>
      TitleCleaning.normalizeGameName(name);

  /// Forme CLÉ d'un nom ou d'un alias (sans résolution d'alias).
  static String _normalizeGameNameNoAlias(String name) =>
      TitleCleaning.normalizeGameNameNoAlias(name);

  /// Titre nettoyé pour insertion ([TitleCleaning.cleanTitleForInsertion]).
  static String _cleanTitleForInsertion(String title,
          {String? gameName,
          List<String>? translatedNames,
          String? channelName}) =>
      TitleCleaning.cleanTitleForInsertion(title,
          gameName: gameName,
          translatedNames: translatedNames,
          channelName: channelName);

  /// §125 — nom de la chaîne retiré s'il est détaché
  /// ([TitleCleaning.stripChannelName]).
  static String _stripChannelName(String title, String? channelName,
          {String? gameName}) =>
      TitleCleaning.stripChannelName(title, channelName, gameName: gameName);

  /// §123 (G) — entités HTML décodées (« &#039; » → « ' »).
  static String _decodeHtmlEntities(String s) =>
      TitleCleaning.decodeHtmlEntities(s);

  /// §123 — URL d'une plateforme VIDÉO (YouTube, bilibili, RUTUBE, Twitch).
  static bool isVideoPlatformUrl(String url) =>
      TitleCleaning.isVideoPlatformUrl(url);

  /// §123 (A) — titre d'une PAGE WEB : titre + domaine du site.
  static String webTitleWithDomain(String cleanedTitle, String url) =>
      TitleCleaning.webTitleWithDomain(cleanedTitle, url);

  /// Normalise un alias de jeu pour la persistance (colonne `alias_norm` de
  /// `game_aliases`) : forme CLÉ de l'alias, SANS résolution vers le nom
  /// canonique (révision B-001 — `normalizeGameAlias('d4')` doit donner
  /// `'d4'`, PAS `'diablo 4'` : les bots comparent les titres normalisés
  /// à ces CLÉS, une alias_norm canonique serait une ligne inerte).
  /// Utilisé par le dialog d'alias du menu Jeux et le bouton
  /// « Synchroniser les alias connus ».
  static String normalizeGameAlias(String alias) =>
      _normalizeGameNameNoAlias(alias);

  /// D3.4 — Charge TOUS les alias en UNE requête et les groupe par jeu
  /// (game_id → liste MUTABLE, mise à jour localement après chaque création
  /// réussie pour rester cohérent en validation en lot sans re-fetch).
  Future<Map<String, List<GameAlias>>> _fetchGameAliasesByGame() async {
    final remote = await sync!.fetchGameAliasesAll();
    final byGame = <String, List<GameAlias>>{};
    for (final e in remote) {
      byGame.putIfAbsent(e.gameId, () => <GameAlias>[]).add(e.alias);
    }
    return byGame;
  }

  /// D3.4 — Crée l'alias candidat COCHÉ d'une suggestion validée
  /// (best-effort, à appeler APRÈS succès de l'acceptation) : union des
  /// alias existants du jeu + {alias: candidat, alias_norm: forme CLÉ via
  /// [normalizeGameAlias] (B-001 — jamais la forme canonique résolue)}.
  /// L'EF `games/aliases/set` (remplacement complet recevant l'union) loge
  /// déjà l'action côté serveur.
  ///
  /// GARDES (jamais de création anarchique) :
  /// - le jeu effectivement validé doit ÊTRE celui du candidat (si l'admin a
  ///   choisi un autre jeu via override, le candidat ne s'applique plus) ;
  /// - alias vide ou forme clé vide → sans-op ;
  /// - alias déjà présent (dédup par alias_norm) → sans-op.
  ///
  /// [aliasesByGame] : cache mutable par jeu (UNE requête list-all par lot) ;
  /// null → fetch frais (validation unitaire).
  /// Retourne null si OK/sans-op, sinon un message d'erreur (la validation
  /// reste faite — avertissement léger côté UI).
  Future<String?> _createAliasCandidate({
    required Game game,
    required AiAliasCandidate candidate,
    Map<String, List<GameAlias>>? aliasesByGame,
  }) async {
    if (sync == null) return null;
    // Garde « jeu validé == jeu du candidat » (comparaison normalisée AVEC
    // résolution d'alias, comme le matching des bots).
    if (_normalizeGameName(game.name) != _normalizeGameName(candidate.game)) {
      return null;
    }
    final alias = candidate.alias.trim();
    if (alias.isEmpty) return null;
    final norm = normalizeGameAlias(alias);
    if (norm.isEmpty) return null;
    try {
      final byGame = aliasesByGame ?? await _fetchGameAliasesByGame();
      final existing =
          byGame.putIfAbsent(game.id, () => <GameAlias>[]);
      // Union dédup : l'alias existe déjà (même forme clé) → rien à faire.
      if (existing.any((a) => a.aliasNorm == norm)) return null;
      final payload = <Map<String, String>>[
        for (final a in existing) {'alias': a.alias, 'alias_norm': a.aliasNorm},
        {'alias': alias, 'alias_norm': norm},
      ];
      await sync!.setGameAliases(game.id, payload);
      // Cache local à jour (id inconnu côté client — non utilisé pour la
      // persistance, la base étant la source de vérité).
      existing.add(GameAlias(id: '', alias: alias, aliasNorm: norm));
      return null;
    } catch (e) {
      return 'alias « $alias » → ${game.name} non créé ($e)';
    }
  }

  /// Alias connus en dur ([_gameAliases]) dont la cible canonique correspond
  /// au jeu [gameName] (ex. « Diablo 4 » → « d4 », « diablo iv »).
  ///
  /// Même logique de correspondance que [_cleanTitleForInsertion] (comparaison
  /// sur la valeur canonique normalisée), SANS son filtre de longueur : les
  /// acronymes courts (« d4 », « wf », « la », « sc ») sont justement des
  /// alias utiles en base. Les entrées d'identité (clé == canonique, ex.
  /// « diablo 4 » → « diablo 4 ») sont exclues : le nom canonique est déjà
  /// matché directement, l'enregistrer comme alias n'ajouterait rien.
  ///
  /// Sert au bouton « Importer les alias connus » du dialog d'alias.
  static List<String> knownAliasesFor(String gameName) {
    final canonical = _normalizeGameName(gameName);
    if (canonical.isEmpty) return const <String>[];
    return [
      for (final entry in _gameAliases.entries)
        if (entry.value == canonical && entry.key != canonical) entry.key,
    ];
  }

  /// Synchronise les alias connus en dur ([_gameAliases]) vers la base
  /// (`game_aliases`) pour TOUS les jeux du catalogue — bouton
  /// « Synchroniser les alias connus » du menu Jeux (v72, passation §67).
  ///
  /// Sémantique UNION (ajout seul, JAMAIS de suppression) : pour chaque jeu,
  /// les alias locaux manquants en base sont AJOUTÉS aux alias existants
  /// (qu'ils soient manuels ou déjà synchronisés). Les alias supprimés de
  /// la map locale restent donc en base — la maintenance fine (ajout/retrait
  /// unitaire) se fait par le dialog Alias du jeu concerné, la base étant
  /// désormais la source de vérité des bots.
  ///
  /// [onProgress] reçoit un message par étape (jeu traité) pour l'UI.
  /// Retourne le résumé : nombre de jeux poussés, d'alias ajoutés, de jeux
  /// déjà à jour et d'alias locaux orphelins (canonical sans jeu en base).
  Future<KnownAliasesSyncReport> syncKnownGameAliases({
    void Function(String message)? onProgress,
  }) async {
    if (sync == null) {
      throw Exception('Mode aperçu : synchronisation indisponible.');
    }
    // 1) État actuel de la base en UNE requête (game_id → alias).
    final remote = await sync!.fetchGameAliasesAll();
    final remoteByGame = <String, List<GameAlias>>{};
    for (final e in remote) {
      remoteByGame.putIfAbsent(e.gameId, () => []).add(e.alias);
    }
    // 2) Parcourt le catalogue ; pousse les jeux dont des alias locaux
    //    manquent en base (comparaison sur alias_norm).
    var pushed = 0, added = 0, upToDate = 0;
    final orphanCanonicals = <String>{};
    final coveredCanonicals = <String>{};
    for (final game in games) {
      final known = knownAliasesFor(game.name);
      if (known.isEmpty) continue;
      coveredCanonicals.add(_normalizeGameName(game.name));
      final existingNorms = {
        for (final a in remoteByGame[game.id] ?? const <GameAlias>[]) a.aliasNorm,
      };
      final missing = known
          .map((a) => (display: a, norm: normalizeGameAlias(a)))
          .where((e) => !existingNorms.contains(e.norm))
          .toList();
      if (missing.isEmpty) {
        upToDate++;
        continue;
      }
      // Union : conservés (forme affichée d'origine) + manquants (forme
      // normalisée locale comme affichage — même comportement que le
      // bouton « Importer les alias connus » du dialog).
      final payload = <Map<String, String>>[
        for (final a in remoteByGame[game.id] ?? const <GameAlias>[])
          {'alias': a.alias, 'alias_norm': a.aliasNorm},
        for (final m in missing) {'alias': m.display, 'alias_norm': m.norm},
      ];
      onProgress?.call('${game.name} : +${missing.length} alias');
      await sync!.setGameAliases(game.id, payload);
      pushed++;
      added += missing.length;
    }
    // 3) Alias locaux dont le jeu canonical n'est pas au catalogue
    //    (ex. « stalker 2 » pas encore ajouté) — signalés, ignorés.
    for (final canonical in _gameAliases.values.toSet()) {
      if (!coveredCanonicals.contains(canonical)) orphanCanonicals.add(canonical);
    }
    return KnownAliasesSyncReport(
      gamesPushed: pushed,
      aliasesAdded: added,
      gamesUpToDate: upToDate,
      orphanCanonicals: orphanCanonicals.toList()..sort(),
    );
  }

  // ── D1.4 — cache des traductions de titres pour le nettoyage local ──

  /// Cache nom de jeu normalisé → titres traduits (table game_translations),
  /// utilisé par [_cleanTitleForInsertion] via [_titleForInsertion].
  /// Chargé UNE fois par session en best-effort ([_loadGameTranslationsCache])
  /// — l'admin ne recalcule les titres que pour le pré-remplissage et la
  /// validation : le titre stocké en base est déjà nettoyé par les bots
  /// (vision/CLI), cette couche aligne juste le calcul local.
  static Map<String, List<String>> _gameTranslationsCache = const {};

  /// Une seule tentative de chargement par session (best-effort).
  static bool _gameTranslationsCacheTried = false;

  /// Charge (best-effort, PostgREST anon paginé) les traductions de titres
  /// de jeux dans [_gameTranslationsCache] — D1.4. Appelée en fire-and-
  /// forget à la fin du sync du catalogue ([_syncGames]) ; un échec laisse
  /// le cache vide (nettoyage sans traductions = comportement antérieur).
  Future<void> _loadGameTranslationsCache() async {
    if (_gameTranslationsCacheTried || sync == null) return;
    _gameTranslationsCacheTried = true;
    try {
      final all = await sync!.fetchGameTranslationsAll();
      if (all == null) return;
      final byName = <String, List<String>>{};
      for (final g in _games) {
        final titles = all[g.id]?.values.toList();
        if (titles != null && titles.isNotEmpty) {
          byName[_normalizeGameName(g.name)] = titles;
        }
      }
      _gameTranslationsCache = byName;
      _bumpTitleCleaningRevision();
    } catch (_) {
      // Best-effort : sans traductions, le nettoyage reste celui d'avant.
    }
  }

  /// §123 — une seule tentative de chargement des alias de la base par
  /// session (best-effort).
  static bool _remoteAliasesTried = false;

  /// §123 — charge les alias de la base (`game_aliases`, UNE requête
  /// `games/aliases/list-all`) dans la couche distante du nettoyage des
  /// titres ([TitleCleaning.setRemoteAliases]) : les titres recalculés par
  /// le panneau retirent alors les mêmes alias que Sentinelle (« GTA 5 »).
  /// Fire-and-forget à la fin du sync du catalogue ; un échec laisse les
  /// seuls alias codés en dur (comportement antérieur).
  Future<void> _loadRemoteAliasesForTitles() async {
    if (_remoteAliasesTried || sync == null) return;
    _remoteAliasesTried = true;
    try {
      final all = await sync!.fetchGameAliasesAll();
      TitleCleaning.setRemoteAliases([
        for (final e in all)
          if ((e.gameName ?? '').trim().isNotEmpty)
            (aliasNorm: e.alias.aliasNorm, gameName: e.gameName!),
      ]);
      _bumpTitleCleaningRevision();
    } catch (_) {
      // Best-effort : sans la base, alias codés en dur seulement.
    }
  }

  /// Révision des références du nettoyage des titres (noms traduits, alias
  /// de la base), chargées APRÈS le premier affichage : les tableaux
  /// Sentinelle recalculent alors les titres pré-remplis que l'admin n'a
  /// pas modifiés (texte affiché == texte appliqué à la validation).
  int get titleCleaningRevision => _titleCleaningRevision;
  int _titleCleaningRevision = 0;

  void _bumpTitleCleaningRevision() {
    _titleCleaningRevision++;
    notifyListeners();
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

  // ---------- Utilisateurs Plus (pagination serveur — migration 0085) ----------
  //
  // La liste des abonnés n'est plus JAMAIS chargée en entier ni persistée en
  // localStorage (demande propriétaire du 25/09/2026 : plus de plafond à
  // 100 000 abonnés) : chaque écran demande SA page au serveur (100 lignes,
  // total exact) et les compteurs via `subscriptions/stats`. Les écritures
  // portent sur UNE ligne et n'envoient QUE les champs modifiés ; en cas de
  // succès, [plusRevision] change (les écrans rechargent leur page) et les
  // compteurs sont relus. Mode aperçu local (sans Supabase) : même contrat,
  // appliqué à la liste locale [_plus].

  /// Page d'abonnés pour [query] (filtres, recherche, tri appliqués côté
  /// serveur). Les erreurs sont PROPAGÉES (l'écran les affiche) ; un 401
  /// déclenche en plus le logout forcé.
  Future<PlusPage> fetchPlusPage(PlusPageQuery query) async {
    if (sync == null) return applyPlusQueryLocally(_plus, query);
    try {
      return await sync!.fetchSubscriptionsPage(
        page: query.effectivePage,
        pageSize: query.effectivePageSize,
        search: query.normalizedSearch,
        status: query.normalizedStatus,
        source: query.normalizedSource,
        sort: query.normalizedSort,
        ascending: query.ascending,
      );
    } on AdminAuthException {
      onAuthError?.call();
      rethrow;
    }
  }

  /// Relit les compteurs des abonnés ([plusStats]). Non bloquant : un échec
  /// conserve les compteurs précédents (log console) ; un 401 déclenche le
  /// logout forcé. Demandes concurrentes : seule la plus récente s'applique.
  Future<void> refreshPlusStats() async {
    final int seq = ++_plusStatsSeq;
    if (sync == null) {
      _plusStats = PlusStats.fromUsers(_plus);
      notifyListeners();
      return;
    }
    try {
      final PlusStats stats = await sync!.fetchSubscriptionStats();
      if (seq != _plusStatsSeq) return; // réponse d'une demande périmée
      _plusStats = stats;
      notifyListeners();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      debugPrint('subscriptions/stats échec (non critique) : $e');
    }
  }

  /// Une écriture d'abonnement a réussi (ou « Actualiser ») : les écrans
  /// paginés rechargent leur page via [plusRevision], compteurs relus.
  void _bumpPlusRevision() {
    _plusRevision++;
    notifyListeners();
    unawaited(refreshPlusStats());
  }

  /// Persiste la liste locale — MODE APERÇU uniquement (en production, la
  /// liste des abonnés ne touche jamais le localStorage).
  void _savePreviewPlus() {
    if (sync == null) _store.savePlus(_plus);
  }

  /// Échec d'une écriture d'abonnement : 401 → logout forcé ; sinon erreur
  /// visible (snackbar rouge du shell). Retourne toujours false.
  bool _plusWriteFailed(Object e, String message) {
    if (_isAuthError(e)) {
      onAuthError?.call();
      return false;
    }
    lastActionError = '$message : $e';
    notifyListeners();
    return false;
  }

  /// Ajoute manuellement un utilisateur Plus en MODE APERÇU (identifiant
  /// fictif, aucun appel serveur — en production, voir [grantPlus]).
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
    _savePreviewPlus();
    _bumpPlusRevision();
  }

  /// Accorde (ou réaccorde) un abonnement Plus MANUEL à [userId] : actif,
  /// formule [plan], début maintenant, SANS échéance — effet historique de
  /// « Ajouter » et du bouton « Plus ». La source n'est pas modifiée (une
  /// nouvelle ligne prend 'admin'). Retourne false en cas d'échec (erreur
  /// signalée via [lastActionError]).
  Future<bool> grantPlus({
    required String userId,
    required String displayName,
    String plan = 'monthly',
  }) async {
    if (sync == null) {
      _plus = [
        ..._plus.where((PlusUser p) => p.id != userId),
        PlusUser(
          id: userId,
          displayName: displayName,
          plan: plan,
          startedAt: DateTime.now(),
          active: true,
        ),
      ];
      _savePreviewPlus();
      _bumpPlusRevision();
      return true;
    }
    if (!_isUuid(userId)) {
      reportActionError(
        'Abonnement Plus non ajouté : identifiant utilisateur invalide.',
      );
      return false;
    }
    // Badge PLUS optimiste (bouton « Plus » des suggestions), annulé en cas
    // d'échec.
    final bool? previous = _plusFlags.sessionValue(userId);
    _plusFlags.setSessionValue(userId, true);
    notifyListeners();
    try {
      await sync!.upsertSubscription(
        userId: userId,
        plan: plan,
        isActive: true,
        startedAt: DateTime.now(),
        clearExpiry: true,
      );
      _bumpPlusRevision();
      return true;
    } catch (e) {
      _plusFlags.setSessionValue(userId, previous);
      notifyListeners();
      return _plusWriteFailed(e, 'Abonnement Plus non ajouté (erreur serveur)');
    }
  }

  /// Suspend / réactive un abonnement : n'envoie QUE `is_active` — formule,
  /// date de début, source et échéance future (Google Play) sont conservées.
  /// Seule exception : à la RÉACTIVATION, une échéance DÉJÀ PASSÉE est
  /// effacée, sinon l'abonnement resterait expiré pour l'app et Analytics.
  Future<bool> togglePlusUser(PlusUser user) async {
    final bool newActive = !user.active;
    if (sync == null) {
      _plus = _plus
          .map((PlusUser n) => n.id == user.id ? n.copyWith(active: newActive) : n)
          .toList();
      _savePreviewPlus();
      _bumpPlusRevision();
      return true;
    }
    if (!_isUuid(user.id)) return false;
    try {
      await sync!.upsertSubscription(
        userId: user.id,
        isActive: newActive,
        clearExpiry: newActive && user.isExpiredAt(),
      );
      _plusFlags.setSessionValue(user.id, newActive);
      _bumpPlusRevision();
      return true;
    } catch (e) {
      return _plusWriteFailed(e, 'Abonnement non modifié (erreur serveur)');
    }
  }

  /// Change la formule : n'envoie QUE `plan` (statut, dates et source
  /// inchangés).
  Future<bool> setPlusPlan(PlusUser user, String plan) async {
    if (plan == user.plan) return true;
    if (sync == null) {
      _plus = _plus
          .map((PlusUser n) => n.id == user.id ? n.copyWith(plan: plan) : n)
          .toList();
      _savePreviewPlus();
      _bumpPlusRevision();
      return true;
    }
    if (!_isUuid(user.id)) return false;
    try {
      await sync!.upsertSubscription(userId: user.id, plan: plan);
      _bumpPlusRevision();
      return true;
    } catch (e) {
      return _plusWriteFailed(e, 'Formule non modifiée (erreur serveur)');
    }
  }

  /// « Supprimer » un abonné = suppression DÉFINITIVE de son abonnement
  /// (demande du propriétaire du 25/09/2026 ; avant : simple désactivation).
  /// Compte principal uniquement (vérifié par l'EF, 403 sinon) ; l'UI
  /// demande une double confirmation ([DeletePlusUserDialog]). La ligne
  /// disparaît de la liste et des statistiques ; l'utilisateur perd Plus.
  /// Aperçu local : la ligne est retirée de la liste.
  Future<bool> deletePlusUser(String id) async {
    if (sync == null) {
      _plus = _plus.where((PlusUser n) => n.id != id).toList();
      _savePreviewPlus();
      _bumpPlusRevision();
      return true;
    }
    if (!_isUuid(id)) return false;
    try {
      await sync!.deleteSubscription(id);
      _plusFlags.setSessionValue(id, false);
      _bumpPlusRevision();
      return true;
    } catch (e) {
      return _plusWriteFailed(e, 'Abonnement non supprimé (erreur serveur)');
    }
  }

  // ---------- Divers ----------
  void resetDemo() {
    _store.resetToSeed();
    _reload();
    _bumpPlusRevision(); // notifie + recharge les écrans d'abonnés
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
    // Migration 0085 : la liste des abonnés n'est plus mise en cache — on
    // efface celle qu'avaient persistée les versions précédentes du panneau
    // (données réelles d'utilisateurs, périmées).
    _store.clearPlus();
  }

  void _reload() {
    _games = _store.loadGames()..sort(_byName);
    _contents = _store.loadContents();
    _suggestions = _store.loadSuggestions();
    _banned = _store.loadBanned();
    // Aperçu local uniquement : en production, pas de liste d'abonnés.
    _plus = sync == null ? _store.loadPlus() : <PlusUser>[];
    // Indicateurs « Plus » des auteurs déjà en cache (badge PLUS immédiat).
    _plusFlags.absorbAuthors(_suggestions.map((Suggestion s) => s.author));
  }

  /// Recharge le catalogue depuis la source active.
  ///
  /// - Mode aperçu : relit le localStorage.
  /// - Mode production : full sync de TOUS les datasets (bouton « Actualiser »
  ///   global — comportement historique conservé, curseurs ignorés). Les
  ///   écrans d'abonnés (pagination serveur) rechargent aussitôt leur page
  ///   et les compteurs, sans attendre la fin de la synchro.
  Future<void> refresh() async {
    if (sync != null) {
      _bumpPlusRevision();
      await syncFromSupabase(forceFull: true);
    } else {
      _reload();
      _bumpPlusRevision(); // notifie + recharge les écrans d'abonnés
    }
  }

  /// Datasets nécessaires au dashboard (chargés au login). Les abonnés Plus
  /// n'en font plus partie (migration 0085) : compteurs et 10 derniers
  /// abonnés sont lus à la demande par le dashboard.
  static const Set<SyncDataset> dashboardDatasets = <SyncDataset>{
    SyncDataset.games,
    SyncDataset.contents,
    SyncDataset.suggestionsNew,
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

  /// Garantit que les datasets [needed] sont chargés (chargement paresseux)
  /// ET raisonnablement frais (auto-refresh à l'arrivée sur un menu).
  ///
  /// Fetch ce qui est manquant dans cette session (ou n'a jamais réussi) OU
  /// périmé (chargé depuis plus de [_datasetFreshness]). Un dataset chargé
  /// depuis moins de [_datasetFreshness] n'est pas refetch (pas de tempête de
  /// requêtes en navigation rapide). Comportement : l'écran affiche
  /// immédiatement le cache local ; la sync incrémentale part en fond et
  /// l'UI se met à jour dès qu'elle arrive. Appelé par chaque écran à son
  /// montage.
  ///
  /// Si [needed] contient un dataset de suggestions, la demande est élargie
  /// aux 5 modes AVANT le calcul du manquant/périmé (correctif I-001) : les
  /// modes frais restent ignorés (skipAlreadyLoaded conserve son sens, devenu
  /// « skip si chargé ET frais »).
  Future<void> ensureDatasets(Set<SyncDataset> needed) async {
    if (sync == null) return;
    final Set<SyncDataset> wanted = _expandSuggestionModes(needed);
    final Set<SyncDataset> toFetch = wanted
        .where((SyncDataset d) => !_isFresh(d))
        .toSet();
    if (toFetch.isEmpty) return;
    await syncFromSupabase(datasets: toFetch, skipAlreadyLoaded: true);
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
  /// sync précédente), ignore les datasets entre-temps chargés ET frais
  /// (< 2 min) — seul ce qui manque encore ou est périmé est rechargé
  /// (usage interne d'ensureDatasets).
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
          // Correctif F1 (chantier Sentinelle) : l'attente de la passe
          // précédente est BORNÉE à 60 s. Une Future Dart n'est pas
          // annulable : si la passe précédente pend (réseau/base), cette
          // attente — hors de tout watchdog — bloquait la nouvelle passe
          // indéfiniment, AVANT même que son propre filet de sécurité
          // (budget + watchdog) soit armé.
          await previous.timeout(const Duration(seconds: 60));
        } on TimeoutException {
          // Attente expirée : on ABANDONNE proprement la nouvelle passe —
          // rien n'a été démarré (isSyncing / _loadingDatasets intacts).
          // Correctif I-001 (revue chantier Sentinelle) : la passe
          // précédente TOURNE ENCORE — on RÉ-ENCHAÎNE _ongoingSync dessus
          // AVANT de rendre la main. Sans cela, le finally ci-dessous (test
          // identical()) libérerait la chaîne et un retry utilisateur
          // démarrerait une VRAIE passe en parallèle de l'orpheline — dont
          // le finally écraserait alors isSyncing / _loadingDatasets de la
          // nouvelle.
          //
          // Correctif B-001 (revue chantier Sentinelle) : le ré-enchaînement
          // seul ne protège que les appels FUTURS. Un waiter DÉJÀ chaîné
          // sur le `current` de CETTE invocation (previous = current) voit
          // son `await current.timeout(60 s)` compléter NORMALEMENT dès le
          // return ci-dessous (le catch avale l'exception) : il démarrerait
          // sa _syncPass PENDANT que l'orpheline tourne encore (budget
          // jusqu'à 120 s en full sync) et les deux finally se
          // clobbereraient isSyncing / _loadingDatasets. On RÉ-ATTEND donc
          // l'orpheline jusqu'à sa fin RÉELLE avant de rendre la main.
          // Cette ré-attente ne peut pas pendre indéfiniment : l'orpheline
          // est TOUJOURS bornée par son propre .timeout(budget 45/120 s)
          // dans [_syncPass] (+ watchdog à budget + 60 s) — y compris si
          // elle a été filtrée à vide par skipAlreadyLoaded (return
          // immédiat, Future complétée aussitôt) — et le message syncError
          // posé ci-dessous assure déjà l'information utilisateur pendant
          // l'attente. Ainsi le `current` abandonné ne complète QU'AVEC
          // l'orpheline : tout waiter déjà chaîné dessus ne démarre sa
          // passe qu'après la fin RÉELLE de l'orpheline — plus aucune
          // passe parallèle possible, les finally ne se chevauchent plus.
          // Quatre chemins vérifiés :
          // 1) timeout simple : la chaîne reste scellée derrière la passe
          //    orpheline, qui reste bornée par son propre budget (45/120 s)
          //    — tout appel suivant attend de nouveau sa fin (60 s max) ;
          // 2) double timeout : la ré-assignation renvoie la même Future —
          //    idempotent, la chaîne converge dès que l'orpheline finit ;
          // 3) orpheline DÉJÀ finie au moment du ré-enchaînement : sans
          //    danger. Son propre finally ne peut pas avoir libéré la
          //    chaîne AVANT (à cet instant _ongoingSync vaut `current`,
          //    pas `previous`), et quand il court APRÈS, il voit
          //    _ongoingSync == previous et libère — état correct puisque
          //    plus rien ne tourne. Dans l'intervalle, _ongoingSync pointe
          //    vers une Future terminée que l'appel suivant résout
          //    immédiatement (await sur Future complétée = micro-tâche) ;
          // 4) waiter DÉJÀ chaîné sur le `current` abandonné (B-001) —
          //    interleaving à 3 appels : O orpheline en full sync (budget
          //    120 s) → A timeout à 60 s → B chaîné sur current_A AVANT le
          //    timeout de A (previous_B = current_A). Sans la ré-attente,
          //    current_A complétait au return de A et B démarrait sa passe
          //    en parallèle de O. Avec : current_A ne complète qu'à la fin
          //    RÉELLE de O — B démarre alors APRÈS O si O finit dans sa
          //    fenêtre de 60 s, sinon timeout à son tour et
          //    ré-enchaînement sur current_A (converge comme 2). Jamais de
          //    passe parallèle, jamais de finally qui se chevauchent.
          _ongoingSync = previous;
          syncError = 'Synchronisation déjà en cours : la passe précédente '
              'n\'a pas répondu en 60 s — elle se termine en arrière-plan, '
              'réessayez dans un instant.';
          notifyListeners();
          // B-001 : ne rendre la main QU'AVEC l'orpheline (bornée — voir
          // le pavé ci-dessus), pour sceller aussi les waiters DÉJÀ
          // chaînés sur le `current` abandonné.
          try {
            await previous;
          } catch (_) {}
          return;
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
    // Correctif F1 (chantier Sentinelle) : TOUT le corps — prologue compris —
    // est dans le try/finally. Avant, `isSyncing = true` était posé AVANT le
    // try : une exception du prologue (filtre _isFresh, localStorage corrompu
    // dans loadCursor, parsing de curseur) laissait isSyncing à true
    // DÉFINITIVEMENT et sans watchdog armé → spinner bloqué. Désormais le
    // finally libère l'UI QUELLE QUE SOIT l'issue.
    bool passFinished = false;
    // Armé après le calcul du budget ; reste null si le prologue lève avant
    // (le finally doit alors simplement sauter le cancel).
    Timer? watchdog;
    try {
      if (skipAlreadyLoaded) {
        // « Skip si chargé ET frais » : un dataset périmé (> 2 min) reste dans
        // la passe (auto-refresh à l'arrivée sur un menu).
        wanted = wanted.where((SyncDataset d) => !_isFresh(d)).toSet();
        if (wanted.isEmpty) return;
      }
      isSyncing = true;
      _loadingDatasets.addAll(wanted);
      // ⚠️ On NE remet pas syncError à null ici : cela effacerait une erreur
      // d'action récente. On l'efface seulement si la sync réussit.
      notifyListeners();
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
      // ── Watchdog anti-spinner-infini ──
      // Une Future Dart n'est pas annulable : si un fetch de dataset pend
      // côté réseau/base, le timeout global ne fait échouer que l'await
      // EXTÉRIEUR et le finally ci-dessous devrait quand même libérer
      // isSyncing. Si, malgré tout, la passe n'est pas terminée budget +
      // 60 s après son démarrage, ce Timer force la libération de l'UI
      // (spinner, indicateurs par écran), nomme les datasets encore en vol
      // et bascule en mode hors-ligne. Filet de sécurité conservé : il est
      // désormais redondant avec le finally global, mais reste utile si le
      // event loop lui-même est obstrué.
      final Duration watchdogDelay = budget + const Duration(seconds: 60);
      watchdog = Timer(watchdogDelay, () {
        if (passFinished) return;
        final List<String> pending = _inFlightDatasets.isNotEmpty
            ? _inFlightDatasets.map((SyncDataset d) => d.name).toList()
            : wanted.map((SyncDataset d) => d.name).toList();
        isSyncing = false;
        _loadingDatasets.clear();
        syncError =
            'Synchronisation bloquée (watchdog ${watchdogDelay.inSeconds} s) — '
            'datasets sans réponse : ${pending.join(', ')}. '
            'Données affichées = cache local ; réessayez avec Actualiser.';
        // Des requêtes encore en vol = blocage de type réseau → badge hors-ligne.
        if (_inFlightDatasets.isNotEmpty) _setOffline(true);
        notifyListeners();
        debugPrint(
          '[sync] WATCHDOG déclenché après ${watchdogDelay.inSeconds} s — '
          'passe non terminée. Datasets en vol : ${pending.join(', ')} '
          '(wanted: ${wanted.map((SyncDataset d) => d.name).join(', ')}).',
        );
      });
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
        // Timeout du budget global, coupure réseau OU exception du prologue
        // (curseur/localStorage) → erreur visible ; badge hors-ligne si
        // c'est une erreur de type réseau.
        if (_isNetworkError(e)) _setOffline(true);
        syncError = e.toString();
      }
    } finally {
      passFinished = true;
      watchdog?.cancel(); // fin normale de la passe → watchdog désarmé
      isSyncing = false;
      _loadingDatasets.clear();
      notifyListeners();
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Polling léger « Analyses en cours » (F2 — chantier Sentinelle)
  // ─────────────────────────────────────────────────────────────────────

  /// Timer du polling léger du board « Analyses en cours », actif uniquement
  /// pendant que le menu Sentinelle est ouvert. Null quand arrêté.
  Timer? _analyzingPollingTimer;

  // ── Compteurs d'échecs CONSÉCUTIFS du tick (I-004 / R4+R5, revue
  // chantier Sentinelle) ──

  /// Échecs RÉSEAU consécutifs. Un échec non-réseau (l'EF a RÉPONDU : 500,
  /// parsing…) prouve que le réseau fonctionne → il remet ce compteur à
  /// zéro ; tout succès aussi.
  int _analyzingPollNetFailures = 0;

  /// Échecs NON-réseau consécutifs (EF 500, parsing…). Symétrique : un
  /// échec réseau interrompt la série ; tout succès la remet à zéro.
  int _analyzingPollOtherFailures = 0;

  /// « Déjà signalé » : true une fois les 3 échecs non-réseau consécutifs
  /// surfacés dans [syncError] — empêche de réécrire la bannière à chaque
  /// tick ; réarmé au premier succès.
  bool _analyzingPollErrorSignaled = false;

  /// Démarre le polling léger du board « Analyses en cours » (toutes les
  /// 30 s) — appelé à l'ouverture du menu Sentinelle (initState).
  ///
  /// Idempotent : un second appel ne crée PAS de doublon. Chaque tick
  /// resynchronise UNIQUEMENT le dataset [SyncDataset.sentinelleAnalyzing],
  /// en REMPLACEMENT COMPLET (toujours — voir _syncSuggestionMode : une ligne
  /// qui quitte ce mode n'apparaît dans aucun delta incrémental) et SANS
  /// passe globale : pas d'`isSyncing`, pas de spinner global, aucun impact
  /// sur les autres boards.
  void startAnalyzingPolling() {
    if (_analyzingPollingTimer != null) return; // déjà actif
    _analyzingPollingTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _analyzingPollingTick(),
    );
  }

  /// Arrête le polling « Analyses en cours » (sortie du menu Sentinelle).
  /// Idempotent : sans timer actif, ne fait rien.
  void stopAnalyzingPolling() {
    _analyzingPollingTimer?.cancel();
    _analyzingPollingTimer = null;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Sync totale BDD → Local (chantier C — migration 0063, décision §70.1)
  // ─────────────────────────────────────────────────────────────────────

  /// Dernière demande de sync totale connue + ses acquittements par machine
  /// (alimente le badge de la topbar). Null tant qu'aucune demande n'a été
  /// posée ni lue dans cette session.
  SyncStatusResult? syncRequestPending;

  /// true pendant l'appel EF `sync/request` (spinner bref du bouton — l'EF
  /// est quasi instantanée ; le bouton reste cliquable).
  bool syncTotalRequesting = false;

  /// Timer du polling `sync/status` (60 s) — actif SEULEMENT tant qu'une
  /// demande « chaude » (< 24 h) n'a reçu AUCUN acquittement. Null sinon.
  Timer? _syncStatusPollingTimer;

  /// Garde anti-recouvrement du tick (un appel EF en vol en bloque un autre).
  bool _syncStatusPollInFlight = false;

  /// Demande une sync TOTALE BDD→local (bouton « 🔄 Sync totale » de la
  /// topbar) : pose/ré-horodate la demande côté serveur (anti-pile-up géré
  /// par l'EF), rafraîchit le statut, puis démarre le polling 60 s tant
  /// qu'aucune machine n'a acquitté. Erreur → [syncError] (bannière topbar).
  Future<void> requestTotalSync() async {
    if (sync == null || syncTotalRequesting) return;
    syncTotalRequesting = true;
    notifyListeners();
    try {
      await sync!.requestTotalSync();
      // Rafraîchit immédiatement le statut : la demande vient d'être posée,
      // elle est forcément « chaude » et sans ack → badge 🟠 + polling.
      syncRequestPending = await sync!.fetchSyncStatus();
      _startSyncStatusPolling();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      syncError = 'La demande de sync totale a échoué : $e';
    } finally {
      syncTotalRequesting = false;
      notifyListeners();
    }
  }

  /// Lecture ONE-SHOT de `sync/status` au login (fix revue I-002) : sans
  /// elle, [syncRequestPending] n'était alimenté qu'au clic sur le bouton
  /// ou à un tick de polling — une demande « chaude » sans ack posée dans
  /// une session PRÉCÉDENTE restait invisible à l'ouverture du panneau.
  /// Best-effort : ne bloque pas le login ; 401 → [onAuthError] ; toute
  /// autre erreur → console seulement. Démarre ensuite le polling 60 s
  /// si la demande est « chaude » et sans ack (gardes existantes de
  /// [_startSyncStatusPolling]).
  Future<void> _initSyncStatusBadge() async {
    if (sync == null) return;
    try {
      syncRequestPending = await sync!.fetchSyncStatus();
      notifyListeners();
      _startSyncStatusPolling();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      debugPrint('[sync] lecture initiale sync/status échouée : $e');
    }
  }

  /// Démarre le polling `sync/status` (toutes les 60 s) — UNIQUEMENT si une
  /// demande « chaude » (< 24 h) est en attente sans AUCUN ack (en pratique :
  /// au moins une machine Vision manquante). Idempotent : jamais de doublon
  /// (même garde que [startAnalyzingPolling]).
  void _startSyncStatusPolling() {
    if (_syncStatusPollingTimer != null) return; // déjà actif
    final req = syncRequestPending?.request;
    final awaitingAck = req != null &&
        (syncRequestPending?.acks.isEmpty ?? true) &&
        DateTime.now().difference(req.createdAt) <= const Duration(hours: 24);
    if (!awaitingAck) return;
    _syncStatusPollingTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _syncStatusPollingTick(),
    );
  }

  /// Arrête le polling `sync/status`. Idempotent : sans timer actif, ne
  /// fait rien. Jamais de fuite : appelé dès ack reçu, demande expirée,
  /// 401, ou dispose du store.
  void _stopSyncStatusPolling() {
    _syncStatusPollingTimer?.cancel();
    _syncStatusPollingTimer = null;
  }

  /// Un tick de polling : relit `sync/status`, met à jour [syncRequestPending]
  /// et ARRÊTE le timer dès qu'au moins une machine a acquitté ou que la
  /// demande a plus de 24 h. Ne lève JAMAIS d'exception : un échec réseau/EF
  /// est tracé en console seulement (retry au prochain tick — pas de spam
  /// [syncError] pour un rafraîchissement de fond).
  Future<void> _syncStatusPollingTick() async {
    if (sync == null || _syncStatusPollInFlight) return;
    _syncStatusPollInFlight = true;
    try {
      final status = await sync!.fetchSyncStatus();
      syncRequestPending = status;
      notifyListeners();
      final req = status.request;
      final expired = req == null ||
          DateTime.now().difference(req.createdAt) > const Duration(hours: 24);
      if (status.acks.isNotEmpty || expired) {
        _stopSyncStatusPolling();
      }
    } on AdminAuthException {
      _stopSyncStatusPolling();
      onAuthError?.call();
    } catch (e) {
      debugPrint(
        '[sync] polling sync/status échoué (retry au prochain tick) : $e',
      );
    } finally {
      _syncStatusPollInFlight = false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Menu « Analytics » (chantier F1 — migration 0066, EF v76, §70.3/§70.6)
  // ─────────────────────────────────────────────────────────────────────
  // État MINIMAL, sans polling ni dataset synchronisé : l'écran déclenche
  // les fetches à l'ouverture et au changement de période (pattern
  // Contributeurs/Limite). AUCUN full sync contents/games ici : les
  // agrégats (comptes, abonnements) sont calculés par l'EF.

  /// Dernière vue agrégée `analytics/overview` (null = jamais chargée).
  AnalyticsOverview? analyticsOverview;

  /// Dernière série `analytics/series` (buckets jour ou mois).
  List<SeriesBucket> analyticsSeries = const [];

  /// Dernière activité quotidienne `analytics/activity` (chantier F2 — EF
  /// v77, migration 0067). Vide si l'instrumentation n'a encore rien remonté.
  List<ActivityDay> analyticsActivity = const [];

  /// Dernières cohortes de rétention `analytics/retention` (chantier F2).
  List<RetentionCohort> analyticsRetention = const [];

  /// Dernière vue `analytics/acquisition` (chantier F3 — EF v78, migration
  /// 0069) : comptes par canal (first touch) + clics site → store.
  /// null = jamais chargée (ou EF v78 non déployée — la section affiche
  /// alors son état vide).
  AcquisitionStats? analyticsAcquisition;

  /// Prix catalogue (pricing_config) — alimenté par overview ET pricing/list.
  List<PricingConfig> pricingConfigs = const [];

  /// Juridictions fiscales (tax_config).
  List<TaxConfig> taxConfigs = const [];

  /// Frais de société (company_expenses).
  List<ExpenseEntry> companyExpenses = const [];

  /// Coûts mensuels des moteurs de recherche des bots (usage_monthly —
  /// plan V3 Phase 2b). Réservé owner (comme les frais de société).
  List<Map<String, dynamic>> usageMonthly = const [];

  /// true pendant un fetch analytics (spinner de l'écran).
  bool analyticsLoading = false;

  /// Dernière erreur de lecture analytics (affichée par l'écran, pas de
  /// snackbar : la lecture est l'état principal de l'écran).
  String? analyticsError;

  /// Charge la vue agrégée + le prix catalogue pour la période [from, to].
  Future<void> fetchAnalyticsOverview({
    required DateTime from,
    required DateTime to,
  }) async {
    if (sync == null) return;
    analyticsLoading = true;
    analyticsError = null;
    notifyListeners();
    try {
      final data = await sync!.fetchAnalyticsOverview(from: from, to: to);
      analyticsOverview = AnalyticsOverview.fromJson(data);
      final pricingRaw = data['pricing'] as List? ?? [];
      pricingConfigs = pricingRaw
          .map((e) => PricingConfig.fromJson(e as Map<String, dynamic>))
          .toList();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      analyticsError = 'Chargement des indicateurs impossible : $e';
    } finally {
      analyticsLoading = false;
      notifyListeners();
    }
  }

  /// Charge les séries temporelles (graphiques + exports).
  Future<void> fetchAnalyticsSeries({
    required DateTime from,
    required DateTime to,
    required String granularity,
  }) async {
    if (sync == null) return;
    analyticsLoading = true;
    analyticsError = null;
    notifyListeners();
    try {
      final data = await sync!.fetchAnalyticsSeries(
        from: from,
        to: to,
        granularity: granularity,
      );
      final raw = data['buckets'] as List? ?? [];
      analyticsSeries = raw
          .map((e) => SeriesBucket.fromJson(e as Map<String, dynamic>))
          .toList();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      analyticsError = 'Chargement des séries impossible : $e';
    } finally {
      analyticsLoading = false;
      notifyListeners();
    }
  }

  /// Charge l'activité quotidienne réelle (chantier F2 — EF v77) sur la
  /// période [from, to]. Sans spinner propre : suit l'état partagé
  /// [analyticsLoading] (convention existante overview/series, cf. §78).
  Future<void> fetchAnalyticsActivity({
    required DateTime from,
    required DateTime to,
  }) async {
    if (sync == null) return;
    try {
      final data = await sync!.fetchAnalyticsActivity(from: from, to: to);
      final raw = data['days'] as List? ?? [];
      analyticsActivity = raw
          .map((e) => ActivityDay.fromJson(e as Map<String, dynamic>))
          .toList();
      notifyListeners();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      analyticsError = 'Chargement de l\'activité impossible : $e';
      notifyListeners();
    }
  }

  /// Charge les cohortes hebdomadaires de rétention (chantier F2 — EF v77).
  /// [weeks] est borné 4-26 côté serveur.
  Future<void> fetchAnalyticsRetention({int weeks = 8}) async {
    if (sync == null) return;
    try {
      final data = await sync!.fetchAnalyticsRetention(weeks: weeks);
      final raw = data['cohorts'] as List? ?? [];
      analyticsRetention = raw
          .map((e) => RetentionCohort.fromJson(e as Map<String, dynamic>))
          .toList();
      notifyListeners();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      analyticsError = 'Chargement de la rétention impossible : $e';
      notifyListeners();
    }
  }

  /// Charge l'attribution d'acquisition (chantier F3 — EF v78) sur la
  /// période [from, to]. Sans spinner propre : suit l'état partagé
  /// [analyticsLoading] (convention existante, cf. §78). DÉFENSIF : si la
  /// route n'existe pas encore (EF v78 non déployée), la section affiche
  /// son état vide sans bloquer le reste de l'écran.
  Future<void> fetchAnalyticsAcquisition({
    required DateTime from,
    required DateTime to,
  }) async {
    if (sync == null) return;
    try {
      final data = await sync!.fetchAnalyticsAcquisition(from: from, to: to);
      analyticsAcquisition = AcquisitionStats.fromJson(data);
      notifyListeners();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      analyticsError = 'Chargement de l\'acquisition impossible : $e';
      notifyListeners();
    }
  }

  /// Charge les 3 tables de config (prix, fiscalité, frais) en parallèle.
  ///
  /// Les frais de société sont RÉSERVÉS au compte principal (l'EF renvoie
  /// 403 sur `expenses/*` sinon) : un compte secondaire n'appelle pas la
  /// route — la section correspondante est masquée dans l'UI et aucune
  /// erreur ne doit remonter (ni rouge, ni orange).
  Future<void> fetchAnalyticsConfigs() async {
    if (sync == null) return;
    try {
      final results = await Future.wait([
        sync!.fetchPricing(),
        sync!.fetchTaxes(),
        if (isOwner)
          sync!.fetchExpenses()
        else
          Future.value(const <Map<String, dynamic>>[]),
        if (isOwner)
          sync!.fetchUsageMonthly()
        else
          Future.value(const <Map<String, dynamic>>[]),
      ]);
      pricingConfigs = results[0]
          .map((e) => PricingConfig.fromJson(e))
          .toList();
      taxConfigs = results[1].map((e) => TaxConfig.fromJson(e)).toList();
      companyExpenses = results[2]
          .map((e) => ExpenseEntry.fromJson(e))
          .toList();
      usageMonthly = results[3];
      notifyListeners();
    } on AdminAuthException {
      onAuthError?.call();
    } on AdminForbiddenException {
      // Filet de sécurité (ex. claims is_owner périmés) : jamais d'erreur
      // affichée pour une section que le compte ne doit de toute façon
      // pas voir — on se contente d'une liste de frais vide.
      companyExpenses = const [];
      usageMonthly = const [];
      notifyListeners();
    } catch (e) {
      analyticsError = 'Chargement de la configuration impossible : $e';
      notifyListeners();
    }
  }

  /// Met à jour le prix catalogue d'un plan (EF pricing/set) puis resync
  /// la liste locale. Erreur → [lastActionError] (snackbar rouge).
  Future<void> setPricing({
    required String plan,
    required double priceTtc,
    String? currency,
    double? playFeePct,
    bool? active,
  }) async {
    if (sync == null) return;
    try {
      await sync!.setPricing(
        plan: plan,
        priceTtc: priceTtc,
        currency: currency,
        playFeePct: playFeePct,
        active: active,
      );
      pricingConfigs = (await sync!.fetchPricing())
          .map((e) => PricingConfig.fromJson(e))
          .toList();
      notifyListeners();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      lastActionError = 'Prix non enregistré (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Met à jour une juridiction fiscale (EF taxes/set) puis resync locale.
  Future<void> setTax({
    required String jurisdiction,
    required double vatRate,
    bool? franchiseBase,
    String? label,
    bool? active,
  }) async {
    if (sync == null) return;
    try {
      await sync!.setTax(
        jurisdiction: jurisdiction,
        vatRate: vatRate,
        franchiseBase: franchiseBase,
        label: label,
        active: active,
      );
      taxConfigs = (await sync!.fetchTaxes())
          .map((e) => TaxConfig.fromJson(e))
          .toList();
      notifyListeners();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      lastActionError = 'Fiscalité non enregistrée (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Crée ou met à jour un frais de société (EF expenses/upsert) puis
  /// resync la liste locale.
  Future<void> upsertExpense(ExpenseEntry expense) async {
    if (sync == null) return;
    String two(int v) => v.toString().padLeft(2, '0');
    String dateOnly(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
    try {
      await sync!.upsertExpense({
        if (expense.id != null) 'id': expense.id,
        'label': expense.label,
        'category': expense.category,
        'amount': expense.amount,
        'currency': expense.currency,
        'recurrence': expense.recurrence,
        'started_on': dateOnly(expense.startedOn),
        'ended_on': expense.endedOn == null ? null : dateOnly(expense.endedOn!),
        'active': expense.active,
        'notes': expense.notes,
      });
      companyExpenses = (await sync!.fetchExpenses())
          .map((e) => ExpenseEntry.fromJson(e))
          .toList();
      notifyListeners();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      lastActionError = 'Frais non enregistré (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Supprime un frais de société (EF expenses/delete) puis resync locale.
  Future<void> deleteExpense(int id) async {
    if (sync == null) return;
    try {
      await sync!.deleteExpense(id);
      companyExpenses = (await sync!.fetchExpenses())
          .map((e) => ExpenseEntry.fromJson(e))
          .toList();
      notifyListeners();
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      lastActionError = 'Frais non supprimé (erreur serveur) : $e';
      notifyListeners();
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // ANNUAIRE DE SITES (menu Scruteur — plan Scruteur V3 §4.4, EF v85)
  // ─────────────────────────────────────────────────────────────────────
  // État LAZY STRICT : RIEN n'est chargé au démarrage ni à l'ouverture du
  // menu Scruteur — uniquement au clic sur le bouton « 📂 Annuaire » de
  // l'en-tête de l'écran (exigence propriétaire). Pas de polling, pas de
  // persistance locale : l'annuaire vit uniquement en mémoire, le temps du
  // dialog. Les lignes restent BRUTES (snake_case, colonnes de l'EF).

  /// Lignes de la vue courante de l'annuaire (page + filtre courants).
  List<Map<String, dynamic>> annuaireRows = const [];

  /// Total serveur de la vue courante (toutes pages du filtre en cours) —
  /// sert à la pagination du dialog.
  int annuaireTotal = 0;

  /// Total TOUT STATUT confondu — alimente le badge « (N sites) » du bouton
  /// d'en-tête. Mis à jour UNIQUEMENT par les chargements non filtrés, pour
  /// ne pas être écrasé par le total de l'onglet « Protégés anti-bot ».
  int annuaireTotalAll = 0;

  /// Page courante (0-based) de la vue affichée dans le dialog.
  int annuairePage = 0;

  /// Filtre statut de la vue courante : null = tous statuts (onglet
  /// « Annuaire »), 'bot_protected' = onglet « Protégés anti-bot ».
  String? annuaireStatus;

  /// true pendant un fetch annuaire (spinner du dialog).
  bool annuaireLoading = false;

  /// true dès qu'un premier chargement a abouti — condition d'affichage du
  /// badge « (N sites) » du bouton d'en-tête (lazy load strict : aucun appel
  /// réseau avant le premier clic).
  bool annuaireEverLoaded = false;

  /// Charge une page de l'annuaire (EF annuaire/list, 50/page, tri serveur
  /// par `frequence` desc). Gardes : sync null ou fetch déjà en vol.
  Future<void> loadAnnuaire({int page = 0, String? status}) async {
    if (sync == null || annuaireLoading) return;
    annuaireLoading = true;
    notifyListeners();
    try {
      final result = await sync!.fetchAnnuaire(page: page, status: status);
      annuaireRows = result.rows;
      annuaireTotal = result.total;
      annuairePage = page;
      annuaireStatus = status;
      annuaireEverLoaded = true;
      if (status == null) annuaireTotalAll = result.total;
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      reportActionError('Annuaire non chargé (erreur serveur) : $e');
    } finally {
      annuaireLoading = false;
      notifyListeners();
    }
  }

  /// Change le statut d'une entrée (✅ activer / ⚪ ignorer / Re-tester un
  /// domaine protégé → candidat) puis recharge la vue courante.
  Future<void> annuaireSetStatus(
    Map<String, dynamic> row,
    String newStatus,
  ) async {
    if (sync == null) return;
    try {
      await sync!.upsertAnnuaire({
        'root_domain': row['root_domain'],
        'status': newStatus,
      });
      // Si la ligne QUITTE le filtre courant (ex. Re-tester depuis l'onglet
      // « Protégés anti-bot ») et que c'était la dernière de la page, on
      // recule d'une page pour ne pas afficher une page vide.
      final bool quitteFiltre =
          annuaireStatus != null && annuaireStatus != newStatus;
      final int page =
          quitteFiltre && annuaireRows.length <= 1 && annuairePage > 0
              ? annuairePage - 1
              : annuairePage;
      await loadAnnuaire(page: page, status: annuaireStatus);
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      reportActionError(
          'Statut annuaire non enregistré (erreur serveur) : $e');
    }
  }

  /// Supprime une entrée de l'annuaire puis recharge la vue courante.
  Future<void> annuaireDelete(String id) async {
    if (sync == null) return;
    try {
      await sync!.deleteAnnuaireEntry(id);
      // Dernière ligne de la page supprimée → recule d'une page.
      final int page = annuaireRows.length <= 1 && annuairePage > 0
          ? annuairePage - 1
          : annuairePage;
      await loadAnnuaire(page: page, status: annuaireStatus);
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      reportActionError(
          'Entrée annuaire non supprimée (erreur serveur) : $e');
    }
  }

  /// Ajoute MANUELLEMENT un domaine à l'annuaire (statut actif, source
  /// 'manuel') puis recharge la vue courante. [domain] est normalisé :
  /// lowercase, sans schéma (« https:// ») ni chemin (« /… »).
  Future<void> annuaireAdd(String domain) async {
    if (sync == null) return;
    String d = domain.trim().toLowerCase();
    d = d.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), ''); // schéma
    d = d.split('/').first; // chemin / query éventuels
    if (d.isEmpty) {
      reportActionError('Domaine invalide : « ${domain.trim()} »');
      return;
    }
    try {
      await sync!.upsertAnnuaire({
        'root_domain': d,
        'status': 'actif',
        'source': 'manuel',
      });
      await loadAnnuaire(page: annuairePage, status: annuaireStatus);
    } on AdminAuthException {
      onAuthError?.call();
    } catch (e) {
      reportActionError('Domaine non ajouté (erreur serveur) : $e');
    }
  }

  @override
  void dispose() {
    // Filet de sécurité : le store vit racine de l'app (jamais disposé en
    // pratique), mais si cela arrivait, les timers ne doivent pas survivre.
    stopAnalyzingPolling();
    _stopSyncStatusPolling();
    super.dispose();
  }

  /// Un tick de polling : resync incrémentale du SEUL dataset analyzing.
  ///
  /// Tick IGNORÉ si une passe globale est en cours ([isSyncing]) ou si le
  /// dataset analyzing est déjà en vol ([_inFlightDatasets]). Le tick tourne
  /// AUSSI en mode hors-ligne : c'est le SEUL agent d'auto-récupération du
  /// badge (I-004 / R4). Cette méthode ne lève JAMAIS d'exception : un échec
  /// est tracé en console ; il ne bascule hors-ligne qu'après 3 échecs
  /// RÉSEAU consécutifs et n'écrit [syncError] qu'après 3 échecs NON-réseau
  /// consécutifs, une seule fois (voir le catch ci-dessous) ; le prochain
  /// tick réessaiera.
  Future<void> _analyzingPollingTick() async {
    // I-004 / R4 : plus de garde isOffline — un passage hors-ligne gelait
    // badge ET polling jusqu'à une action manuelle, sans aucune possibilité
    // d'auto-récupération. Désormais le tick continue de sonder hors-ligne
    // et _setOffline(true) n'est armé qu'au franchissement du seuil (déjà
    // idempotent en interne : pas de _setOffline répété).
    if (sync == null || isSyncing) return;
    if (_inFlightDatasets.contains(SyncDataset.sentinelleAnalyzing)) return;
    _inFlightDatasets.add(SyncDataset.sentinelleAnalyzing);
    try {
      final List<Suggestion> before = _sentinelleAnalyzing;
      await _syncSuggestionMode(
        SyncDataset.sentinelleAnalyzing,
        sync!.fetchSentinelleAnalyzing,
        forceFull: false,
        // Ensemble jetable : la purge des tombstones reste réservée aux
        // passes complètes des 5 modes (voir _doSyncFromSupabase).
        fullModeSyncs: <SyncDataset>{},
      );
      // Succès : remise à zéro des compteurs d'échecs consécutifs et
      // réarmement du flag « déjà signalé ».
      _analyzingPollNetFailures = 0;
      _analyzingPollOtherFailures = 0;
      _analyzingPollErrorSignaled = false;
      _setOffline(false); // au moins une requête a abouti → en ligne
      // Le dataset analyzing est TOUJOURS remplacé (référence neuve à chaque
      // tick — voir _syncSuggestionMode) : on ne notifie que si le CONTENU a
      // réellement changé, sinon l'écran se reconstruirait toutes les 30 s
      // pour rien.
      if (!_sameAnalyzingContent(before, _sentinelleAnalyzing)) {
        notifyListeners();
      }
    } on AdminAuthException {
      // 401 pendant une lecture service_role → logout forcé (comme partout).
      onAuthError?.call();
    } catch (e) {
      if (_isNetworkError(e)) {
        // R4 : un échec réseau ISOLÉ (transitoire) ne bascule plus en
        // hors-ligne — cela gelait badge + polling jusqu'à action manuelle.
        // Seuil : 3 échecs réseau CONSÉCUTIFS. Un échec non-réseau prouve
        // que le réseau répond → il interrompt la série (remise à zéro).
        _analyzingPollNetFailures++;
        _analyzingPollOtherFailures = 0;
        if (_analyzingPollNetFailures >= 3) _setOffline(true);
      } else {
        // R5 / AC6 : après 3 échecs NON-réseau consécutifs (EF 500,
        // parsing…), l'erreur est surfacée via syncError — visible et
        // exploitable — mais UNE seule fois (flag « déjà signalé », réarmé
        // au premier succès) : un rafraîchissement de fond ne doit ni
        // écraser une erreur d'action à chaque tick, ni spammer la
        // bannière. Un échec réseau interrompt la série (remise à zéro).
        _analyzingPollOtherFailures++;
        _analyzingPollNetFailures = 0;
        if (_analyzingPollOtherFailures >= 3 &&
            !_analyzingPollErrorSignaled) {
          _analyzingPollErrorSignaled = true;
          syncError = 'Le rafraîchissement automatique des « Analyses en '
              'cours » échoue ($_analyzingPollOtherFailures échecs '
              'consécutifs) : $e';
          notifyListeners();
        }
      }
      debugPrint(
        '[sync] polling analyzing échoué (retry au prochain tick) : $e',
      );
    } finally {
      _inFlightDatasets.remove(SyncDataset.sentinelleAnalyzing);
    }
  }

  /// Compare le CONTENU de deux listes « Analyse en cours » (ids + statut +
  /// horodatage de début d'analyse), ordre indifférent. Utilisé par le tick
  /// de polling : le dataset analyzing étant toujours remplacé (référence
  /// neuve), seule cette comparaison évite un rebuild gratuit toutes les 30 s.
  static bool _sameAnalyzingContent(
    List<Suggestion> a,
    List<Suggestion> b,
  ) {
    if (a.length != b.length) return false;
    String key(Suggestion s) =>
        '${s.id}|${s.status.name}|${s.sentinelleStartedAt?.toIso8601String() ?? ''}';
    final Set<String> ka = a.map(key).toSet();
    return b.every((s) => ka.contains(key(s)));
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

    const Map<SyncDataset, String> labels = <SyncDataset, String>{
      SyncDataset.games: 'jeux',
      SyncDataset.contents: 'contenus',
      SyncDataset.suggestionsNew: 'suggestions (nouvelles)',
      SyncDataset.sentinelleAnalyzing: 'sentinelle (analyse en cours)',
      SyncDataset.sentinelleAnalyzed: 'sentinelle (analysées)',
      SyncDataset.scruteur: 'scruteur',
      SyncDataset.gamesToCreate: 'jeux à créer',
      SyncDataset.banned: 'comptes à bannir',
    };

    /// Exécute un job de dataset en isolant son erreur : un dataset en échec
    /// n'annule pas les autres ; le détail est consolidé et remonté dans
    /// [syncError] (jamais avalé). Seul le 401 remonte immédiatement
    /// (logout forcé).
    ///
    /// Pilote aussi le mode hors-ligne gracieux : un job réussi repasse
    /// [isOffline] à false ; un job en échec sur erreur réseau le passe à
    /// true (détection par les résultats des requêtes, sans connectivity_plus).
    ///
    /// Diagnostic (watchdog anti-spinner-infini) : trace le début/fin de
    /// chaque fetch dans la console et maintient [_inFlightDatasets] — si une
    /// passe pend, ces logs révèlent exactement quel dataset est bloqué.
    Future<void> guard(SyncDataset dataset, Future<void> Function() job) async {
      final String label = labels[dataset]!;
      final Stopwatch chrono = Stopwatch()..start();
      _inFlightDatasets.add(dataset);
      debugPrint('[sync] début $label');
      try {
        await job();
        _setOffline(false); // au moins une requête a abouti → en ligne
      } on AdminAuthException {
        rethrow;
      } catch (e) {
        if (_isNetworkError(e)) _setOffline(true);
        errors.add('$label : $e');
      } finally {
        chrono.stop();
        _inFlightDatasets.remove(dataset);
        final double secs = chrono.elapsedMilliseconds / 1000;
        debugPrint('[sync] fin $label (${secs.toStringAsFixed(1)} s)');
      }
    }

    // Datasets indépendants → fetchés EN PARALLÈLE (Future.wait).
    await Future.wait(<Future<void>>[
      if (datasets.contains(SyncDataset.games))
        guard(
          SyncDataset.games,
          () => _syncGames(forceFull: forceFull),
        ),
      if (datasets.contains(SyncDataset.contents))
        guard(
          SyncDataset.contents,
          () => _syncContents(forceFull: forceFull),
        ),
      if (datasets.contains(SyncDataset.suggestionsNew))
        guard(
          SyncDataset.suggestionsNew,
          () => _syncSuggestionMode(
            SyncDataset.suggestionsNew,
            sync!.fetchSuggestions,
            forceFull: forceFull,
            fullModeSyncs: fullModeSyncs,
          ),
        ),
      if (datasets.contains(SyncDataset.sentinelleAnalyzing))
        guard(
          SyncDataset.sentinelleAnalyzing,
          () => _syncSuggestionMode(
            SyncDataset.sentinelleAnalyzing,
            sync!.fetchSentinelleAnalyzing,
            forceFull: forceFull,
            fullModeSyncs: fullModeSyncs,
          ),
        ),
      if (datasets.contains(SyncDataset.sentinelleAnalyzed))
        guard(
          SyncDataset.sentinelleAnalyzed,
          () => _syncSuggestionMode(
            SyncDataset.sentinelleAnalyzed,
            sync!.fetchSentinelleSuggestions,
            forceFull: forceFull,
            fullModeSyncs: fullModeSyncs,
          ),
        ),
      if (datasets.contains(SyncDataset.scruteur))
        guard(
          SyncDataset.scruteur,
          () => _syncSuggestionMode(
            SyncDataset.scruteur,
            sync!.fetchScruteurSuggestions,
            forceFull: forceFull,
            fullModeSyncs: fullModeSyncs,
          ),
        ),
      if (datasets.contains(SyncDataset.gamesToCreate))
        guard(
          SyncDataset.gamesToCreate,
          () => _syncSuggestionMode(
            SyncDataset.gamesToCreate,
            sync!.fetchGamesToCreate,
            forceFull: forceFull,
            fullModeSyncs: fullModeSyncs,
          ),
        ),
      if (datasets.contains(SyncDataset.banned))
        guard(SyncDataset.banned, _syncBanned),
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

  /// Garde ANTI-BOUCLE de la pagination spéculative ([_fetchPaged] sans
  /// total connu) : jeux en incrémental ou quand le comptage HEAD échoue,
  /// files de suggestions (pages de 500). Ce n'est PAS un plafond métier :
  /// avec un total connu (full sync jeux/contenus), toutes les pages sont
  /// lues. Relevée de 100 000 à 1 000 000 (25/09/2026) : le comptage de
  /// secours n'avait plus de raison de tronquer à 100 000 ; le temps reste
  /// borné par le budget de synchro (45/120 s).
  static const int _kRunawayGuardItems = 1000000;

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
        maxItems: _kRunawayGuardItems,
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
        maxItems: _kRunawayGuardItems,
      );
      maxUp = r.maxUpdatedAt;
      final pendingGames = _games.where((g) => !_isUuid(g.id)).toList();
      _games = [...r.items, ...pendingGames]..sort(_byName);
    }
    _saveCursorFor(SyncDataset.games, maxUp);
    _markDatasetLoaded(SyncDataset.games);
    _store.saveGames(_games);
    // D1.4 — charge (best-effort, fire-and-forget, une fois par session) les
    // traductions de titres pour le nettoyage local des titres d'insertion.
    unawaited(_loadGameTranslationsCache());
    // §123 — idem pour les alias de la base (même retrait que Sentinelle).
    unawaited(_loadRemoteAliasesForTitles());
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
  ///
  /// ⚠️ Le mode `sentinelleAnalyzing` est TOUJOURS synchronisé en
  /// REMPLACEMENT COMPLET (jamais en incrémental) : une ligne qui QUITTE ce
  /// mode (Sentinelle a rendu son verdict → elle bascule sur un autre board)
  /// ne matche plus le filtre « analyzing » côté serveur — elle n'apparaît
  /// donc dans AUCUN delta de ce mode, et la fusion incrémentale ne la
  /// retirerait JAMAIS de la liste locale (le board « Analyse en cours »
  /// s'allongerait indéfiniment). Coût nul : Sentinelle analyse un contenu
  /// à la fois, le dataset tient en quelques lignes — l'économie du curseur
  /// est sans objet ici.
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
    final bool fullReplace =
        forceFull || dataset == SyncDataset.sentinelleAnalyzing;
    final String? cursor = fullReplace ? null : _validCursorFor(dataset);
    final r = await _fetchPaged<Suggestion>(
      (p) => fetcher(page: p, pageSize: pageSize, since: cursor),
      pageSize,
      maxItems: _kRunawayGuardItems,
    );
    // ── Tombstones : une ligne tout juste rejetée/acceptée peut encore
    //    figurer dans le snapshot entrant (fetch émis AVANT le commit
    //    serveur). On EXCLUT ces ids des listes entrantes, en full comme en
    //    incrémental (le filtre reste actif jusqu'à la purge par un full
    //    sync des 5 modes).
    final List<Suggestion> items = r.items
        .where((s) => !_pendingRemovalIds.contains(s.id))
        .toList();
    // Indicateurs « abonné Plus » des auteurs (author_is_plus, migration
    // 0085) : badge PLUS / bouton « Plus » sans liste complète des abonnés.
    _plusFlags.absorbAuthors(r.items.map((Suggestion s) => s.author));
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
        // Badge de sync totale (I-002) : une demande « chaude » sans ack
        // d'une session précédente doit être visible dès l'ouverture du
        // panneau — one-shot best-effort, ne bloque pas le login.
        unawaited(_initSyncStatusBadge());
      }
    } else {
      sync!.setAdminToken('');
    }
  }

  static int _byName(Game a, Game b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// Résumé d'une synchronisation des alias connus vers la base (bouton
/// « Synchroniser les alias connus » du menu Jeux — v72, passation §67).
@immutable
class KnownAliasesSyncReport {
  const KnownAliasesSyncReport({
    required this.gamesPushed,
    required this.aliasesAdded,
    required this.gamesUpToDate,
    required this.orphanCanonicals,
  });

  /// Jeux pour lesquels des alias ont été poussés.
  final int gamesPushed;

  /// Nombre total d'alias ajoutés en base.
  final int aliasesAdded;

  /// Jeux avec alias locaux déjà tous présents en base (rien à faire).
  final int gamesUpToDate;

  /// Noms canoniques locaux dont AUCUN jeu du catalogue ne correspond
  /// (alias ignorés — ex. jeu pas encore ajouté au catalogue).
  final List<String> orphanCanonicals;
}
