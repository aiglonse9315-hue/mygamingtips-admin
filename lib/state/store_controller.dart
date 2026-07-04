import 'package:flutter/foundation.dart';

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
    _reload();
    // Branche le sliding session : chaque écriture réussie renvoie un
    // fresh_token que le client propage au AuthService.
    sync?.onTokenRefreshed = (freshToken) {
      onTokenRefreshed?.call(freshToken);
    };
    // En mode production, on synchronise immédiatement avec Supabase.
    if (sync != null) {
      // sync async sans bloquer l'init ; _reload() a déjà chargé le cache.
      syncFromSupabase().catchError((Object e) {
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

  /// Garde anti-réentrance pour syncFromSupabase.
  bool _syncing = false;

  /// Dernier token admin connu (pour éviter les resync inutiles).
  String? _lastToken;

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
  List<Suggestion> _sentinelleSuggestions = <Suggestion>[];
  List<BannedUser> _banned = <BannedUser>[];
  List<PlusUser> _plus = <PlusUser>[];

  List<Game> get games => List<Game>.unmodifiable(_games);
  List<Content> get contents => List<Content>.unmodifiable(_contents);
  List<Suggestion> get suggestions =>
      List<Suggestion>.unmodifiable(_suggestions);

  /// Suggestions analysées par Sentinelle (menu Sentinelle dédié).
  List<Suggestion> get sentinelleSuggestions =>
      List<Suggestion>.unmodifiable(_sentinelleSuggestions);

  /// Suggestions Sentinelle avec verdict "recommended" ET confiance ≥ 0.9.
  /// Ce sont les suggestions "99% sûr" implémentables en 1 clic.
  List<Suggestion> get sentinelleTrusted => _sentinelleSuggestions
      .where((s) =>
          s.aiRecommendation != null &&
          s.aiRecommendation!.verdict == AiVerdict.recommended &&
          s.aiRecommendation!.confidence >= 0.9)
      .toList();

  /// Suggestions Sentinelle "à vérifier" (caution, reject, ou confiance < 0.9).
  List<Suggestion> get sentinelleToVerify => _sentinelleSuggestions
      .where((s) =>
          s.aiRecommendation == null ||
          s.aiRecommendation!.verdict != AiVerdict.recommended ||
          s.aiRecommendation!.confidence < 0.9)
      .toList();

  List<BannedUser> get banned => List<BannedUser>.unmodifiable(_banned);
  List<PlusUser> get plus => List<PlusUser>.unmodifiable(_plus);
  int get activePlusCount =>
      _plus.where((n) => n.active).length;

  /// L'auteur d'une suggestion est-il actuellement banni ?
  bool isAuthorBanned(String authorId) =>
      _banned.any((b) => b.id == authorId);

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
      // Resync pour garantir la cohérence avec le serveur.
      await syncFromSupabase();
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
          .where((c) =>
              c.gameId == gameId && c.category == category && c.validated)
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
      titleAdmin:
          titleAdmin?.trim().isEmpty == true ? null : titleAdmin?.trim(),
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
      _contents =
          _contents.map((c) => c.id == content.id ? created : c).toList();
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
        .map((c) =>
            c.id == content.id ? c.copyWith(titleAdmin: () => titleAdmin.trim()) : c)
        .toList();
    _store.saveContents(_contents);
    notifyListeners();
    if (sync == null) return;
    final updated = _contents.firstWhere((c) => c.id == content.id);
    try {
      await sync!.upsertContent(updated);
    } catch (e) {
      // Rollback.
      _contents = _contents.map((c) => c.id == content.id ? previous : c).toList();
      _store.saveContents(_contents);
      lastActionError = 'Titre non modifié (erreur serveur) : $e';
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
      await syncFromSupabase();
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
  List<Suggestion> get suggestionsByDate => List<Suggestion>.from(_suggestions)
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
        .map((s) => s.id == suggestion.id
            ? s.copyWith(status: SuggestionStatus.accepted)
            : s)
        .toList();
    _store.saveSuggestions(_suggestions);
    notifyListeners();

    if (sync == null) return;
    try {
      await sync!.acceptSuggestion(
        suggestionId: suggestion.id,
        gameId: gameId,
        category: category,
        titleAdmin: titleAdmin,
        isVideo: category == ContentCategory.video,
      );
      // Resync pour récupérer le contenu créé côté serveur.
      await syncFromSupabase();
    } catch (e) {
      // Rollback : la suggestion redevient pending.
      _suggestions = _suggestions
          .map((s) => s.id == suggestion.id
              ? s.copyWith(status: SuggestionStatus.pending)
              : s)
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
        .map((s) => s.id == suggestion.id
            ? s.copyWith(status: SuggestionStatus.rejected)
            : s)
        .toList();
    _store.saveSuggestions(_suggestions);
    notifyListeners();
    if (sync == null) return;
    try {
      await sync!.rejectSuggestion(suggestion.id);
    } catch (e) {
      // Rollback.
      _suggestions = _suggestions
          .map((s) => s.id == suggestion.id
              ? s.copyWith(status: previousStatus)
              : s)
          .toList();
      _store.saveSuggestions(_suggestions);
      lastActionError = 'Suggestion non rejetée (erreur serveur) : $e';
      notifyListeners();
    }
  }

  // ---------- Sentinelle (menu dédié) ----------

  /// Implémente une suggestion Sentinelle en 1 clic.
  ///
  /// Utilise le jeu et la catégorie suggérés par l'IA. Si l'IA n'a pas proposé
  /// de catégorie, on déduit 'video' si l'URL est YouTube, sinon 'links'.
  /// La suggestion est ensuite retirée de la liste Sentinelle.
  Future<void> acceptOneClick(Suggestion suggestion) async {
    final ai = suggestion.aiRecommendation;
    if (ai == null) {
      lastActionError = 'Pas d\'analyse IA pour cette suggestion.';
      notifyListeners();
      return;
    }

    // Détermine le jeu : on cherche un jeu existant dont le nom correspond
    // à la suggestion de l'IA, sinon on prend le premier jeu disponible.
    final suggestedName = ai.suggestedGame?.toLowerCase();
    Game? targetGame;
    if (suggestedName != null) {
      try {
        targetGame = _games.firstWhere(
          (g) => g.name.toLowerCase() == suggestedName,
        );
      } catch (_) {
        targetGame = _games.isNotEmpty ? _games.first : null;
      }
    } else if (_games.isNotEmpty) {
      targetGame = _games.first;
    }
    if (targetGame == null) {
      lastActionError = 'Aucun jeu dans le catalogue pour implémenter.';
      notifyListeners();
      return;
    }

    // Détermine la catégorie depuis la suggestion IA.
    final category = _categoryFromAi(ai.suggestedCategory, suggestion.url);

    // Retire la suggestion de la liste Sentinelle (optimiste).
    _sentinelleSuggestions = _sentinelleSuggestions
        .where((s) => s.id != suggestion.id)
        .toList();
    notifyListeners();

    if (sync == null) return;
    try {
      await sync!.acceptSuggestion(
        suggestionId: suggestion.id,
        gameId: targetGame.id,
        category: category,
        titleAdmin: _cleanTitle(suggestion),
        isVideo: category == ContentCategory.video,
      );
      // Resync pour récupérer le contenu créé côté serveur.
      await syncFromSupabase();
    } catch (e) {
      // Rollback : remet la suggestion dans Sentinelle.
      _sentinelleSuggestions = [..._sentinelleSuggestions, suggestion];
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Implémentation échouée (erreur serveur) : $e';
      notifyListeners();
    }
  }

  /// Rejette une suggestion Sentinelle (la retire du menu).
  Future<void> rejectSentinelle(Suggestion suggestion) async {
    // Retire la suggestion de la liste Sentinelle (optimiste).
    _sentinelleSuggestions = _sentinelleSuggestions
        .where((s) => s.id != suggestion.id)
        .toList();
    notifyListeners();
    if (sync == null) return;
    try {
      await sync!.rejectSuggestion(suggestion.id);
    } catch (e) {
      // Rollback : remet la suggestion dans Sentinelle.
      _sentinelleSuggestions = [..._sentinelleSuggestions, suggestion];
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Rejet Sentinelle échoué : $e';
      notifyListeners();
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

  // ---------- Bannissement ----------
  /// Bannit le compte auteur d'une suggestion (modération disciplinaire).
  Future<void> banAuthor(Suggestion suggestion, {String? reason}) async {
    if (isAuthorBanned(suggestion.author.id)) return;
    _banned = [..._banned, BannedUser.fromAuthor(suggestion.author, reason: reason)];
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
      )
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

  /// Bannit manuellement un compte (sans suggestion associée).
  /// Utilisé par le bouton « Bannir » du dashboard.
  void banManually({
    required String displayName,
    String? email,
    String? reason,
  }) {
    final id = 'manual-${DateTime.now().millisecondsSinceEpoch}';
    _banned = [
      ..._banned,
      BannedUser(
        id: id,
        displayName: displayName.trim(),
        email: email?.trim().isEmpty == true ? null : email?.trim(),
        bannedAt: DateTime.now(),
        reason: reason?.trim().isEmpty == true
            ? 'Banni manuellement'
            : reason!.trim(),
      )
    ];
    _store.saveBanned(_banned);
    notifyListeners();
    // Pas de sync Supabase : les bans manuels sans user_id valide ne
    // correspondent à aucun profil en base.
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
  /// - Mode production : synchronise depuis Supabase puis met à jour le cache.
  Future<void> refresh() async {
    if (sync != null) {
      await syncFromSupabase();
    } else {
      _reload();
      notifyListeners();
    }
  }

  /// Synchronise les données depuis Supabase (lectures PostgREST) et met à
  /// jour le cache localStorage.
  ///
  /// **Stratégie de fusion** : les données serveur remplacent les données
  /// locales **uniquement pour les entrées déjà synchronisées** (UUID valide).
  /// Les entrées locales en attente (ID temporaire) sont conservées jusqu'à
  /// confirmation de leur écriture.
  Future<void> syncFromSupabase() async {
    if (sync == null) return;
    // Garde anti-réentrance.
    if (_syncing) return;
    _syncing = true;
    isSyncing = true;
    // ⚠️ On NE remet pas syncError à null ici : cela effacerait une erreur
    // d'action récente. On l'efface seulement si la sync réussit.
    notifyListeners();
    try {
      final games = await sync!.fetchGames();
      final contents = await sync!.fetchContents();
      final suggestions = await sync!.fetchSuggestions();
      final sentinelleSuggestions = await sync!.fetchSentinelleSuggestions();

      // --- Fusion : conserve les entrées locales non encore synchronisées
      //     (ID temporaire) et ajoute les données serveur. ---
      final pendingGames = _games
          .where((g) => !_isUuid(g.id))
          .toList();
      _games = [...games, ...pendingGames]..sort(_byName);

      final pendingContents = _contents
          .where((c) => !_isUuid(c.id))
          .toList();
      _contents = [...contents, ...pendingContents];

      final pendingSuggestions = _suggestions
          .where((s) => !_isUuid(s.id))
          .toList();
      _suggestions = [...suggestions, ...pendingSuggestions];

      // Suggestions Sentinelle (analysées par IA, en attente de validation).
      _sentinelleSuggestions = sentinelleSuggestions;

      // Met à jour le cache local pour les lectures hors-ligne.
      _store.saveGames(_games);
      _store.saveContents(_contents);
      _store.saveSuggestions(_suggestions);
      // Sync réussie : on efface l'erreur de sync (pas l'erreur d'action).
      syncError = null;
    } catch (e) {
      syncError = e.toString();
    } finally {
      _syncing = false;
      isSyncing = false;
      notifyListeners();
    }
  }

  /// Vrai UUID Supabase ? (36 caractères, format xxxxxxxx-xxxx-...).
  static bool _isUuid(String id) =>
      id.length == 36 && RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false).hasMatch(id);

  /// Met à jour le jeton admin pour les écritures Supabase (appelé après
  /// login/logout).
  ///
  /// ⚠️ Ne resync QUE si le token a changé (évite les resync en boucle à
  /// chaque rebuild de l'UI).
  void updateAdminToken(String? token) {
    if (sync == null) return;
    if (token == _lastToken) return; // pas de changement → pas de resync
    _lastToken = token;
    if (token != null && token.isNotEmpty) {
      sync!.setAdminToken(token);
      // Re-sync pour récupérer les données à jour une fois connecté.
      syncFromSupabase();
    } else {
      sync!.setAdminToken('');
    }
  }

  static int _byName(Game a, Game b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
