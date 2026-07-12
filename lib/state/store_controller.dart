import 'dart:async';

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
  List<Suggestion> _sentinelleAnalyzing = <Suggestion>[];
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

  /// Suggestions en cours d'analyse par Sentinelle.
  List<Suggestion> get sentinelleAnalyzing =>
      List<Suggestion>.unmodifiable(_sentinelleAnalyzing);

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

  /// Met à jour un contenu (titre + URL). Attend la confirmation serveur.
  Future<void> updateContent(Content content, {
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
        .map((c) => c.id == content.id
            ? c.copyWith(
                titleAdmin: () => titleAdmin.trim(),
                url: () => url.trim(),
                category: category,
                publishedAt: publishedAt,
                gameId: gameId,
                videoLanguage: videoLanguage,
              )
            : c)
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
      if (_isAuthError(e)) {
        onAuthError?.call();
        return;
      }
      lastActionError = 'Contenu non modifié (erreur serveur) : $e';
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
    // Si l'ID n'est pas un vrai UUID (donnée de démo locale), on s'arrête :
    // pas besoin d'appeler le serveur, la suppression locale suffit.
    if (sync == null || !_isUuid(suggestion.id)) return;
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
  /// Utilise le jeu et la catégorie suggérés par l'IA. **Si le jeu suggéré
  /// n'existe pas dans le catalogue, il est créé automatiquement** puis le
  /// contenu y est rattaché. La suggestion est ensuite retirée de la liste
  /// Sentinelle.
  Future<void> acceptOneClick(Suggestion suggestion) async {
    final ai = suggestion.aiRecommendation;
    if (ai == null) {
      lastActionError = 'Pas d\'analyse IA pour cette suggestion.';
      notifyListeners();
      return;
    }

    // Détermine la catégorie depuis la suggestion IA.
    final category = _categoryFromAi(ai.suggestedCategory, suggestion.url);

    // Détermine le jeu cible :
    // 1. Cherche un jeu existant dont le nom correspond exactement.
    // 2. Sinon, cherche un jeu dont le nom contient la suggestion (ex: "fortnite" dans "Fortnite Battle Royale").
    // 3. Sinon, CRÉE le jeu automatiquement depuis la suggestion IA.
    final suggestedName = ai.suggestedGame;
    Game? targetGame;

    if (suggestedName != null && suggestedName.trim().isNotEmpty) {
      final lower = suggestedName.toLowerCase();
      try {
        // Recherche exacte (insensible à la casse).
        targetGame = _games.firstWhere(
          (g) => g.name.toLowerCase() == lower,
        );
      } catch (_) {
        try {
          // Recherche partielle (contient).
          targetGame = _games.firstWhere(
            (g) => g.name.toLowerCase().contains(lower) ||
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

    // Retire la suggestion de la liste Sentinelle (optimiste).
    _sentinelleSuggestions = _sentinelleSuggestions
        .where((s) => s.id != suggestion.id)
        .toList();
    notifyListeners();

    // Si l'ID n'est pas un vrai UUID (donnée de démo locale), on s'arrête.
    if (sync == null || !_isUuid(suggestion.id)) return;
    try {
      await sync!.acceptSuggestion(
        suggestionId: suggestion.id,
        gameId: targetGame.id,
        category: category,
        titleAdmin: _titleForInsertion(suggestion),
        isVideo: category == ContentCategory.video,
        publishedAt: _dateForInsertion(suggestion),
      );
      // Resync pour récupérer le contenu créé côté serveur + le nouveau jeu.
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
    // Si l'ID n'est pas un vrai UUID (donnée de démo locale), on s'arrête.
    if (sync == null || !_isUuid(suggestion.id)) return;
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

  /// Détermine le meilleur titre pour l'insertion d'un contenu.
  ///
  /// Priorité :
  /// 1. Titre réel YouTube (récupéré par Sentinelle via l'API YouTube)
  /// 2. Texte partagé nettoyé (sans URL)
  /// 3. URL brute
  static String _titleForInsertion(Suggestion s) {
    // 1. Titre YouTube réel (le plus fiable).
    final ytTitle = s.aiRecommendation?.youtubeTitle;
    if (ytTitle != null && ytTitle.trim().isNotEmpty) {
      return ytTitle.trim();
    }
    // 2. Fallback : texte partagé nettoyé.
    return _cleanTitle(s);
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
    final suggestions =
        _store.loadSuggestions().where((s) => _isUuid(s.id)).toList();
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
  ///
  /// **Anti-réentrance** : si un sync est déjà en cours, on ATTEND qu'il
  /// termine au lieu de retourner immédiatement (évite le spinner bloqué).
  /// **Timeout** : si une requête ne répond pas en 15s, on abandonne et on
  /// débloque l'UI (évite le spinner infini).
  Future<void> syncFromSupabase() async {
    if (sync == null) return;
    // Garde anti-réentrance : si un sync est déjà en cours, on attend qu'il
    // termine (au lieu de retourner silencieusement et laisser l'UI croire
    // qu'un sync est en cours alors qu'il ne se passe rien).
    if (_syncing) {
      // Attend que le sync en cours se termine (avec un timeout de sécurité).
      int attempts = 0;
      while (_syncing && attempts < 150) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        attempts++;
      }
      return;
    }
    _syncing = true;
    isSyncing = true;
    // ⚠️ On NE remet pas syncError à null ici : cela effacerait une erreur
    // d'action récente. On l'efface seulement si la sync réussit.
    notifyListeners();
    try {
      // Timeout global de 15s : si une requête pend, on abandonne proprement.
      await _doSyncFromSupabase().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw TimeoutException('Synchronisation Supabase expirée (15s).');
        },
      );
    } catch (e) {
      syncError = e.toString();
    } finally {
      _syncing = false;
      isSyncing = false;
      notifyListeners();
    }
  }

  /// Effectue réellement la sync (sans la garde ni le timeout — appelé par
  /// [syncFromSupabase]).
  Future<void> _doSyncFromSupabase() async {
    // Pagination : récupère jusqu'à 10 000 jeux par pages de 1000
    // (dépasse la limite par défaut de 1000 lignes de PostgREST).
    const int maxGames = 10000;
    const int gamesPageSize = 1000;
    final allGames = <Game>[];
    for (var page = 0; page * gamesPageSize < maxGames; page++) {
      final batch = await sync!.fetchGames(page: page, pageSize: gamesPageSize);
      allGames.addAll(batch);
      if (batch.length < gamesPageSize) break; // Fin des données.
    }
    final games = allGames;

    // Pagination : récupère jusqu'à 10 000 contenus par pages de 1000
    // (dépasse la limite par défaut de 1000 lignes de PostgREST).
    // Le plafond de 10 000 protège le navigateur contre une surcharge
    // mémoire : si vous dépassez 10 000 contenus validés, seuls les 10 000
    // plus récents seront chargés.
    const int maxContents = 10000;
    const int contentsPageSize = 1000;
    final allContents = <Content>[];
    for (var page = 0; page * contentsPageSize < maxContents; page++) {
      final batch =
          await sync!.fetchContents(page: page, pageSize: contentsPageSize);
      allContents.addAll(batch);
      if (batch.length < contentsPageSize) break; // Fin des données.
    }
    final contents = allContents;

    // Pagination : récupère toutes les suggestions par pages de 500.
    final allSuggestions = <Suggestion>[];
    final allAnalyzing = <Suggestion>[];
    final allSentinelle = <Suggestion>[];

    for (var page = 0; ; page++) {
      final batch = await sync!.fetchSuggestions(page: page, pageSize: 500);
      allSuggestions.addAll(batch);
      if (batch.length < 500) break;
    }
    for (var page = 0; ; page++) {
      final batch = await sync!.fetchSentinelleAnalyzing(page: page, pageSize: 500);
      allAnalyzing.addAll(batch);
      if (batch.length < 500) break;
    }
    for (var page = 0; ; page++) {
      final batch = await sync!.fetchSentinelleSuggestions(page: page, pageSize: 500);
      allSentinelle.addAll(batch);
      if (batch.length < 500) break;
    }

    final suggestions = allSuggestions;
    final sentinelleAnalyzing = allAnalyzing;
    final sentinelleSuggestions = allSentinelle;

    // Récupère les abonnements Plus depuis Supabase (table subscriptions).
    List<Map<String, dynamic>> serverPlus = [];
    try {
      serverPlus = await sync!.fetchSubscriptions();
    } catch (e) {
      // Non critique : si la récupération échoue, on garde le cache local.
      debugPrint('fetchSubscriptions échec: $e');
    }

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

    // Suggestions Sentinelle : en cours d'analyse + analysées.
    _sentinelleAnalyzing = sentinelleAnalyzing;
    _sentinelleSuggestions = sentinelleSuggestions;

    // Abonnés Plus : fusionne serveur + locaux (non UUID = démo).
    // On remplace les abonnés serveur (UUID) par la dernière version serveur,
    // et on conserve les abonnés locaux (démo) non synchronisables.
    final localOnlyPlus = _plus.where((p) => !_isUuid(p.id)).toList();
    _plus = [
      ...serverPlus.map((m) => PlusUser(
            id: m['id'] as String,
            displayName: m['displayName'] as String? ?? 'Inconnu',
            plan: m['plan'] as String? ?? 'monthly',
            startedAt: DateTime.tryParse(m['startedAt'] as String? ?? '') ??
                DateTime.now(),
            active: m['active'] as bool? ?? false,
          )),
      ...localOnlyPlus,
    ];
    _store.savePlus(_plus);

    // Met à jour le cache local pour les lectures hors-ligne.
    _store.saveGames(_games);
    _store.saveContents(_contents);
    _store.saveSuggestions(_suggestions);
    // Sync réussie : on efface l'erreur de sync (pas l'erreur d'action).
    syncError = null;
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
