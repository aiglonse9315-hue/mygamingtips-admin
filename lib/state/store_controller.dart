import 'package:flutter/foundation.dart';

import '../data/store.dart';
import '../data/supabase_sync.dart';
import '../domain/models/banned_user.dart';
import '../domain/models/category.dart';
import '../domain/models/content.dart';
import '../domain/models/game.dart';
import '../domain/models/nitro_user.dart';
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

  List<Game> _games = <Game>[];
  List<Content> _contents = <Content>[];
  List<Suggestion> _suggestions = <Suggestion>[];
  List<BannedUser> _banned = <BannedUser>[];
  List<NitroUser> _nitro = <NitroUser>[];

  List<Game> get games => List<Game>.unmodifiable(_games);
  List<Content> get contents => List<Content>.unmodifiable(_contents);
  List<Suggestion> get suggestions =>
      List<Suggestion>.unmodifiable(_suggestions);
  List<BannedUser> get banned => List<BannedUser>.unmodifiable(_banned);
  List<NitroUser> get nitro => List<NitroUser>.unmodifiable(_nitro);
  int get activeNitroCount =>
      _nitro.where((n) => n.active).length;

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
  }

  void updateGame(Game game) {
    _games = _games.map((g) => g.id == game.id ? game : g).toList()
      ..sort(_byName);
    _store.saveGames(_games);
    notifyListeners();
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
  }

  void updateContentTitle(Content content, String titleAdmin) {
    _contents = _contents
        .map((c) =>
            c.id == content.id ? c.copyWith(titleAdmin: () => titleAdmin.trim()) : c)
        .toList();
    _store.saveContents(_contents);
    notifyListeners();
  }

  void deleteContent(String id) {
    _contents = _contents.where((c) => c.id != id).toList();
    _store.saveContents(_contents);
    notifyListeners();
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
  }) {
    addContent(
      gameId: gameId,
      category: category,
      url: suggestion.url,
      titleAdmin: titleAdmin,
      imageUrl: null,
    );
    _suggestions = _suggestions
        .map((s) => s.id == suggestion.id
            ? s.copyWith(status: SuggestionStatus.accepted)
            : s)
        .toList();
    _store.saveSuggestions(_suggestions);
    notifyListeners();
  }

  void rejectSuggestion(Suggestion suggestion) {
    _suggestions = _suggestions
        .map((s) => s.id == suggestion.id
            ? s.copyWith(status: SuggestionStatus.rejected)
            : s)
        .toList();
    _store.saveSuggestions(_suggestions);
    notifyListeners();
  }

  // ---------- Bannissement ----------
  /// Bannit le compte auteur d'une suggestion (modération disciplinaire).
  void banAuthor(Suggestion suggestion, {String? reason}) {
    if (isAuthorBanned(suggestion.author.id)) return;
    _banned = [..._banned, BannedUser.fromAuthor(suggestion.author, reason: reason)];
    _store.saveBanned(_banned);
    notifyListeners();
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
  }

  void unban(String id) {
    _banned = _banned.where((b) => b.id != id).toList();
    _store.saveBanned(_banned);
    notifyListeners();
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
  }

  // ---------- Utilisateurs Nitro ----------
  /// Ajoute manuellement un utilisateur Nitro (depuis le dashboard admin).
  void addNitroUser({
    required String displayName,
    required String email,
    required String plan,
  }) {
    final NitroUser user = NitroUser(
      id: 'nu-${DateTime.now().millisecondsSinceEpoch}',
      displayName: displayName.trim(),
      email: email.trim().isEmpty ? null : email.trim(),
      plan: plan,
      startedAt: DateTime.now(),
      active: true,
    );
    _nitro = [..._nitro, user];
    _store.saveNitro(_nitro);
    notifyListeners();
  }

  /// Active/désactive un abonnement Nitro.
  void toggleNitroUser(NitroUser user) {
    _nitro = _nitro
        .map((n) => n.id == user.id ? n.copyWith(active: !n.active) : n)
        .toList();
    _store.saveNitro(_nitro);
    notifyListeners();
  }

  /// Change la formule d'un utilisateur Nitro.
  void setNitroPlan(NitroUser user, String plan) {
    _nitro = _nitro
        .map((n) => n.id == user.id ? n.copyWith(plan: plan) : n)
        .toList();
    _store.saveNitro(_nitro);
    notifyListeners();
  }

  void deleteNitroUser(String id) {
    _nitro = _nitro.where((n) => n.id != id).toList();
    _store.saveNitro(_nitro);
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
    _nitro = _store.loadNitro();
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
