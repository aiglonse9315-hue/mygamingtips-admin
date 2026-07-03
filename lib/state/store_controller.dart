import 'package:flutter/foundation.dart';

import '../data/store.dart';
import '../data/supabase_sync.dart';
import '../domain/models/banned_user.dart';
import '../domain/models/category.dart';
import '../domain/models/content.dart';
import '../domain/models/game.dart';
import '../domain/models/plus_user.dart';
import '../domain/models/suggestion.dart';

/// Contrôleur applicatif (Provider) gérant l'état du catalogue et des
/// suggestions.
///
/// **Mode aperçu local** (sans [SupabaseSync]) : tout est lu/écrit dans le
/// localStorage via [Store]. Idéal pour les démos.
///
/// **Mode production** (avec [SupabaseSync]) : les lectures viennent de
/// Supabase (PostgREST, anon key), les écritures passent par l'Edge Function
/// `admin-catalog` (service_role). Le localStorage sert de cache local.
class StoreController extends ChangeNotifier {
  StoreController(this._store, {this.sync}) {
    _store.ensureInitialized();
    _reload();
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

  /// Efface l'erreur de synchronisation affichée.
  void clearSyncError() {
    syncError = null;
    notifyListeners();
  }

  List<Game> _games = <Game>[];
  List<Content> _contents = <Content>[];
  List<Suggestion> _suggestions = <Suggestion>[];
  List<BannedUser> _banned = <BannedUser>[];
  List<PlusUser> _plus = <PlusUser>[];

  List<Game> get games => List<Game>.unmodifiable(_games);
  List<Content> get contents => List<Content>.unmodifiable(_contents);
  List<Suggestion> get suggestions =>
      List<Suggestion>.unmodifiable(_suggestions);
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

  void addGame({
    required String name,
    String? publisher,
    String? coverUrl,
    bool active = true,
  }) {
    final Game game = Game(
      id: 'g-${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim(),
      publisher: publisher?.trim().isEmpty == true ? null : publisher?.trim(),
      coverUrl: coverUrl?.trim().isEmpty == true ? null : coverUrl?.trim(),
      active: active,
      createdAt: DateTime.now(),
    );
    _games = [..._games, game]..sort(_byName);
    _store.saveGames(_games);
    notifyListeners();
    // Sync Supabase (optimiste) : on pousse le jeu créé.
    _syncGame(game);
  }

  void updateGame(Game game) {
    _games = _games.map((g) => g.id == game.id ? game : g).toList()
      ..sort(_byName);
    _store.saveGames(_games);
    notifyListeners();
    _syncGame(game);
  }

  void toggleGameActive(Game game) {
    updateGame(game.copyWith(active: !game.active));
  }

  void deleteGame(String id) {
    _games = _games.where((g) => g.id != id).toList();
    // On supprime aussi les contenus liés (cohérence référentielle).
    _contents = _contents.where((c) => c.gameId != id).toList();
    _store.saveGames(_games);
    _store.saveContents(_contents);
    notifyListeners();
    // Sync Supabase : supprime le jeu (cascade contenus côté serveur).
    // La suppression attend la confirmation serveur, puis resync pour
    // garantir la cohérence (en cas d'ID temporaire non encore remplacé).
    _syncDeleteGame(id);
  }

  /// Pousse un jeu vers Supabase (upsert) en arrière-plan.
  Future<void> _syncGame(Game game) async {
    if (sync == null) return;
    try {
      final created = await sync!.upsertGame(game);
      // Remplace l'ID temporaire par l'ID serveur (UUID).
      _games = _games.map((g) => g.id == game.id ? created : g).toList()
        ..sort(_byName);
      _store.saveGames(_games);
      notifyListeners();
    } catch (e) {
      syncError = 'Jeu non synchronisé: $e';
      notifyListeners();
    }
  }

  Future<void> _syncDeleteGame(String id) async {
    if (sync == null) return;
    try {
      await sync!.deleteGame(id);
      // La suppression a réussi côté serveur : on resync pour garantir
      // la cohérence (le cache local est écrasé par l'état serveur réel).
      await syncFromSupabase();
    } catch (e) {
      syncError = 'Suppression jeu non synchronisée: $e';
      // En cas d'échec (ex: ID temporaire), on resync aussi pour révéler
      // l'état réel (le jeu réapparaît s'il n'a pas pu être supprimé).
      await syncFromSupabase();
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

  void addContent({
    required String gameId,
    required ContentCategory category,
    required String url,
    String? titleAdmin,
    String? imageUrl,
  }) {
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
    _syncContent(content);
  }

  void updateContentTitle(Content content, String titleAdmin) {
    _contents = _contents
        .map((c) =>
            c.id == content.id ? c.copyWith(titleAdmin: () => titleAdmin.trim()) : c)
        .toList();
    _store.saveContents(_contents);
    notifyListeners();
    final updated = _contents.firstWhere((c) => c.id == content.id);
    _syncContent(updated);
  }

  void deleteContent(String id) {
    _contents = _contents.where((c) => c.id != id).toList();
    _store.saveContents(_contents);
    notifyListeners();
    // Sync Supabase : supprime le contenu, puis resync pour garantir la
    // cohérence (le cache local est écrasé par l'état serveur réel).
    _syncDeleteContent(id);
  }

  /// Pousse un contenu vers Supabase (upsert) en arrière-plan.
  Future<void> _syncContent(Content content) async {
    if (sync == null) return;
    try {
      final created = await sync!.upsertContent(content);
      _contents = _contents.map((c) => c.id == content.id ? created : c).toList();
      _store.saveContents(_contents);
      notifyListeners();
    } catch (e) {
      syncError = 'Contenu non synchronisé: $e';
      notifyListeners();
    }
  }

  Future<void> _syncDeleteContent(String id) async {
    if (sync == null) return;
    try {
      await sync!.deleteContent(id);
      // Resync pour garantir la cohérence avec le serveur.
      await syncFromSupabase();
    } catch (e) {
      syncError = 'Suppression contenu non synchronisée: $e';
      // En cas d'échec (ex: ID temporaire), on resync pour révéler l'état réel.
      await syncFromSupabase();
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
  void acceptSuggestion({
    required Suggestion suggestion,
    required String gameId,
    required ContentCategory category,
    required String titleAdmin,
    String? imageUrl,
  }) {
    addContent(
      gameId: gameId,
      category: category,
      url: suggestion.url,
      titleAdmin: titleAdmin,
      imageUrl: imageUrl,
    );
    _suggestions = _suggestions
        .map((s) => s.id == suggestion.id
            ? s.copyWith(status: SuggestionStatus.accepted)
            : s)
        .toList();
    _store.saveSuggestions(_suggestions);
    notifyListeners();
    // Sync Supabase : crée le contenu + marque la suggestion acceptée.
    _syncAcceptSuggestion(
      suggestion: suggestion,
      gameId: gameId,
      category: category,
      titleAdmin: titleAdmin,
    );
  }

  void rejectSuggestion(Suggestion suggestion) {
    _suggestions = _suggestions
        .map((s) => s.id == suggestion.id
            ? s.copyWith(status: SuggestionStatus.rejected)
            : s)
        .toList();
    _store.saveSuggestions(_suggestions);
    notifyListeners();
    _syncRejectSuggestion(suggestion.id);
  }

  Future<void> _syncAcceptSuggestion({
    required Suggestion suggestion,
    required String gameId,
    required ContentCategory category,
    required String titleAdmin,
  }) async {
    if (sync == null) return;
    try {
      await sync!.acceptSuggestion(
        suggestionId: suggestion.id,
        gameId: gameId,
        category: category,
        titleAdmin: titleAdmin,
        isVideo: category == ContentCategory.video,
      );
    } catch (e) {
      syncError = 'Suggestion non acceptée côté serveur: $e';
      notifyListeners();
    }
  }

  Future<void> _syncRejectSuggestion(String suggestionId) async {
    if (sync == null) return;
    try {
      await sync!.rejectSuggestion(suggestionId);
    } catch (e) {
      syncError = 'Suggestion non rejetée côté serveur: $e';
      notifyListeners();
    }
  }

  // ---------- Bannissement ----------
  /// Bannit le compte auteur d'une suggestion (modération disciplinaire).
  void banAuthor(Suggestion suggestion, {String? reason}) {
    if (isAuthorBanned(suggestion.author.id)) return;
    _banned = [..._banned, BannedUser.fromAuthor(suggestion.author, reason: reason)];
    _store.saveBanned(_banned);
    notifyListeners();
    _syncBan(suggestion.author.id, reason: reason);
  }

  /// Bannit directement un auteur identifié (depuis un id).
  void banAuthorId(String authorId, {String? displayName}) {
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
    _syncBan(authorId, reason: 'Banni manuellement');
  }

  void unban(String id) {
    _banned = _banned.where((b) => b.id != id).toList();
    _store.saveBanned(_banned);
    notifyListeners();
    _syncUnban(id);
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

  /// Pousse un ban vers Supabase (uniquement si l'ID est un UUID valide,
  /// c'est-à-dire un vrai user_id — pas un ID manuel fictif).
  Future<void> _syncBan(String userId, {String? reason}) async {
    if (sync == null) return;
    // Les UUID Supabase font 36 caractères (format xxxxxxxx-xxxx-...).
    // Les IDs manuels commencent par 'manual-' et ne sont pas en base.
    if (userId.length != 36 || !userId.contains('-')) return;
    try {
      await sync!.banUser(userId, reason: reason);
    } catch (e) {
      syncError = 'Ban non synchronisé: $e';
      notifyListeners();
    }
  }

  Future<void> _syncUnban(String userId) async {
    if (sync == null) return;
    if (userId.length != 36 || !userId.contains('-')) return;
    try {
      await sync!.unbanUser(userId);
    } catch (e) {
      syncError = 'Levée de ban non synchronisée: $e';
      notifyListeners();
    }
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
  void togglePlusUser(PlusUser user) {
    _plus = _plus
        .map((n) => n.id == user.id ? n.copyWith(active: !n.active) : n)
        .toList();
    _store.savePlus(_plus);
    notifyListeners();
    _syncPlusToggle(user);
  }

  /// Change la formule d'un utilisateur Plus.
  void setPlusPlan(PlusUser user, String plan) {
    _plus = _plus
        .map((n) => n.id == user.id ? n.copyWith(plan: plan) : n)
        .toList();
    _store.savePlus(_plus);
    notifyListeners();
    _syncPlusToggle(user.copyWith(plan: plan));
  }

  void deletePlusUser(String id) {
    _plus = _plus.where((n) => n.id != id).toList();
    _store.savePlus(_plus);
    notifyListeners();
  }

  /// Pousse l'état d'un abonnement vers Supabase (uniquement si l'ID est un
  /// UUID valide, c'est-à-dire un vrai user_id).
  Future<void> _syncPlusToggle(PlusUser user) async {
    if (sync == null) return;
    if (user.id.length != 36 || !user.id.contains('-')) return;
    try {
      await sync!.upsertSubscription(
        userId: user.id,
        plan: user.plan,
        isActive: user.active,
        startedAt: user.startedAt,
      );
    } catch (e) {
      syncError = 'Abonnement non synchronisé: $e';
      notifyListeners();
    }
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
  /// jour le cache localStorage. Les erreurs sont capturées et exposées via
  /// [syncError] sans planter l'UI (le cache local reste affiché).
  Future<void> syncFromSupabase() async {
    if (sync == null) return;
    isSyncing = true;
    syncError = null;
    notifyListeners();
    try {
      final games = await sync!.fetchGames();
      final contents = await sync!.fetchContents();
      final suggestions = await sync!.fetchSuggestions();
      _games = games..sort(_byName);
      _contents = contents;
      _suggestions = suggestions;
      // Met à jour le cache local pour les lectures hors-ligne.
      _store.saveGames(_games);
      _store.saveContents(_contents);
      _store.saveSuggestions(_suggestions);
    } catch (e) {
      syncError = e.toString();
    } finally {
      isSyncing = false;
      notifyListeners();
    }
  }

  /// Met à jour le jeton admin pour les écritures Supabase (appelé après
  /// login/logout). Déclenche une sync des écritures en attente si un token
  /// valide est fourni.
  void updateAdminToken(String? token) {
    if (sync == null) return;
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
