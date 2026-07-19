import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/models/category.dart';
import '../domain/models/content.dart';
import '../domain/models/game.dart';
import '../domain/models/suggestion.dart';

/// Exception levée quand le token admin est expiré ou invalide (HTTP 401).
///
/// Permet au `StoreController` de détecter ce cas spécifique et de forcer le
/// logout automatique, plutôt que d'afficher une simple erreur d'action.
class AdminAuthException implements Exception {
  const AdminAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Synchronisation entre le panneau admin et Supabase.
///
/// **Lectures catalogue** (`games`, `contents`, `contributor_stats`) : via
/// l'API REST PostgREST (anon key suffit — données publiques par design).
/// **Lectures sensibles** (`suggestions`, résolution email → UUID) et
/// **écritures** : via l'Edge Function `admin-catalog` (service_role,
/// protégée par jeton JWT admin émis par `admin-login`).
///
/// Cette classe ne fait aucune persistance locale — c'est le `Store`
/// (localStorage) qui sert de cache. La stratégie est : lecture Supabase →
/// mise à jour du cache local → affichage.
class SupabaseSync {
  SupabaseSync({
    required this.supabaseUrl,
    required this.anonKey,
    required this.catalogEndpoint,
    required this.adminToken,
  });

  /// URL du projet Supabase (ex. https://xxx.supabase.co).
  final String supabaseUrl;

  /// Clé anon publique (lecture seule grâce à RLS).
  final String anonKey;

  /// URL de l'Edge Function admin-catalog.
  final String catalogEndpoint;

  /// Callback invoqué quand l'Edge Function renvoie un `fresh_token`
  /// (sliding session). Le client remplace son token courant pour prolonger
  /// la session de 15 min à chaque écriture réussie.
  void Function(String freshToken)? onTokenRefreshed;

  /// Jeton JWT admin (obtenu via admin-login, mis à jour après login).
  /// Vide tant que l'admin n'est pas connecté → les écritures échoueront.
  String adminToken;

  Map<String, String> get _anonHeaders => {
        'apikey': anonKey,
        'Authorization': 'Bearer $anonKey',
      };

  /// Headers pour les écritures via l'Edge Function admin-catalog.
  /// Stratégie pour franchir la passerelle Supabase SANS conflit de header :
  ///   - `Authorization: Bearer <anon_key>` → la passerelle exige ce header
  ///     (on y met l'anon key, ce qui suffit à franchir le gateway).
  ///   - `apikey: <anon_key>` → requis également par la passerelle.
  ///   - `X-Admin-Token: <jwt_admin>` → notre code Deno lit ce header
  ///     personnalisé (le header `Authorization` est réservé par la passerelle
  ///     pour l'auth Supabase Auth, on ne doit pas y mettre notre JWT admin).
  Map<String, String> get _adminHeaders => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $anonKey',
        'apikey': anonKey,
        'X-Admin-Token': adminToken,
      };

  /// Met à jour le jeton admin (appelé après un login réussi).
  void setAdminToken(String token) => adminToken = token;

  // ===========================================================================
  // LECTURES CATALOGUE (PostgREST — anon key, données publiques par design)
  // ===========================================================================

  /// Convertit une ligne Supabase (snake_case) vers le format camelCase
  /// attendu par les modèles admin (Game.fromJson attend 'coverUrl', etc.).
  static Map<String, dynamic> _camelRow(Map<String, dynamic> row) {
    final Map<String, dynamic> out = <String, dynamic>{};
    row.forEach((key, value) {
      switch (key) {
        case 'cover_url':
          out['coverUrl'] = value;
        case 'created_at':
          out['createdAt'] = value;
        case 'game_id':
          out['gameId'] = value;
        case 'title_source':
          out['titleSource'] = value;
        case 'title_admin':
          out['titleAdmin'] = value;
        case 'image_url':
          out['imageUrl'] = value;
        case 'published_at':
          out['publishedAt'] = value;
        case 'is_video':
          out['isVideo'] = value;
        case 'video_language':
          out['videoLanguage'] = value;
        case 'checked_at':
          out['checkedAt'] = value;
        case 'shared_text':
          out['sharedText'] = value;
        case 'shared_at':
          out['sharedAt'] = value;
        case 'author_id':
          out['authorId'] = value;
        case 'ai_recommendation':
          out['aiRecommendation'] = value;
        default:
          out[key] = value;
      }
    });
    return out;
  }

  /// Récupère tous les jeux (actifs ou non).
  /// Récupère les jeux par page.
  ///
  /// [page] : index de la page (0-based).
  /// [pageSize] : nombre de jeux par page (défaut 1000).
  Future<List<Game>> fetchGames({int page = 0, int pageSize = 1000}) async {
    final Uri uri = Uri.parse(
      '$supabaseUrl/rest/v1/games?select=*'
      '&limit=$pageSize&offset=${page * pageSize}',
    );
    final http.Response res = await http.get(uri, headers: _anonHeaders);
    if (res.statusCode != 200) {
      throw Exception('fetchGames échec ${res.statusCode}: ${res.body}');
    }
    final List<dynamic> rows = jsonDecode(res.body) as List<dynamic>;
    return rows
        .map((r) => Game.fromJson(_camelRow(r as Map<String, dynamic>)))
        .toList();
  }

  /// Récupère les contenus validés par page.
  ///
  /// [page] : index de la page (0-based).
  /// [pageSize] : nombre de contenus par page (défaut 1000 pour la rétrocompatibilité).
  Future<List<Content>> fetchContents({int page = 0, int pageSize = 1000}) async {
    final Uri uri = Uri.parse(
      '$supabaseUrl/rest/v1/contents?select=*&order=published_at.desc'
      '&limit=$pageSize&offset=${page * pageSize}',
    );
    final http.Response res = await http.get(uri, headers: _anonHeaders);
    if (res.statusCode != 200) {
      throw Exception('fetchContents échec ${res.statusCode}: ${res.body}');
    }
    final List<dynamic> rows = jsonDecode(res.body) as List<dynamic>;
    return rows
        .map((r) => Content.fromJson(_camelRow(r as Map<String, dynamic>)))
        .toList();
  }

  // ── Suggestions : lectures service_role (Phase 2 du durcissement RLS) ──
  // Les lectures suggestions/profils du panneau passent par la route
  // `suggestions/list` de l'Edge Function admin-catalog (service_role) au
  // lieu de PostgREST anon. Filtres et shape de retour strictement
  // identiques aux anciennes requêtes (embed `author` reconstitué côté
  // fonction) : aucun changement de comportement pour l'UI.

  /// Convertit les lignes suggestions (snake_case + embed `author`) en
  /// modèles [Suggestion]. Mapping identique à l'ancien embed PostgREST
  /// `author:profiles(id,display_name,avatar_preset)`.
  static List<Suggestion> _mapSuggestionRows(List<dynamic> rows) {
    return rows.map((r) {
      final row = r as Map<String, dynamic>;
      final authorData = row['author'];
      final Map<String, dynamic> authorObj = authorData is Map
          ? {
              'id': authorData['id'] ?? row['author_id'] ?? '',
              'displayName':
                  authorData['display_name'] ?? row['author_name'] ?? 'Inconnu',
              'avatarUrl': authorData['avatar_preset'],
            }
          : {
              'id': row['author_id'] ?? '',
              'displayName': row['author_name'] ?? 'Inconnu',
            };
      final Map<String, dynamic> mapped = _camelRow(row);
      mapped['author'] = authorObj;
      return Suggestion.fromJson(mapped);
    }).toList();
  }

  /// Lecture des suggestions par mode via la route service_role
  /// `suggestions/list` (pagination identique : page/pageSize 0-based).
  Future<List<Suggestion>> _fetchSuggestionsByMode(
    String mode, {
    int page = 0,
    int pageSize = 500,
  }) async {
    final Map<String, dynamic> data = await _post('suggestions/list', {
      'mode': mode,
      'page': page,
      'pageSize': pageSize,
    });
    return _mapSuggestionRows(data['suggestions'] as List? ?? []);
  }

  /// Récupère les suggestions VRAIMENT nouvelles : jamais prises en charge
  /// par Sentinelle (`sentinelle_started_at IS NULL` ET pas encore
  /// d'analyse IA). Ces suggestions apparaissent dans le menu "Suggestions".
  Future<List<Suggestion>> fetchSuggestions({int page = 0, int pageSize = 500}) =>
      _fetchSuggestionsByMode('new', page: page, pageSize: pageSize);

  /// Récupère les suggestions EN COURS d'analyse par Sentinelle
  /// (`sentinelle_started_at NOT NULL` MAIS `ai_recommendation IS NULL`).
  /// Ces suggestions apparaissent dans le menu "Sentinelle" → section
  /// "Analyse en cours" (Sentinelle travaille dessus).
  Future<List<Suggestion>> fetchSentinelleAnalyzing({int page = 0, int pageSize = 500}) =>
      _fetchSuggestionsByMode('analyzing', page: page, pageSize: pageSize);

  /// Récupère les suggestions DÉJÀ analysées par Sentinelle (avec
  /// `ai_recommendation` non null). Ces suggestions apparaissent dans le menu
  /// "Sentinelle" où l'admin peut les implémenter en 1 clic ou les vérifier.
  Future<List<Suggestion>> fetchSentinelleSuggestions({int page = 0, int pageSize = 500}) =>
      _fetchSuggestionsByMode('analyzed', page: page, pageSize: pageSize);

  /// Récupère les suggestions marquées « Jeux à créer » : le flag
  /// `needs_game_creation` est vrai dans `ai_recommendation`, le statut est
  /// pending, et l'auteur n'est pas Vision.
  Future<List<Suggestion>> fetchGamesToCreate({int page = 0, int pageSize = 500}) =>
      _fetchSuggestionsByMode('games-to-create', page: page, pageSize: pageSize);

  /// Supprime une entrée « Jeux à créer » (marque la suggestion rejected).
  Future<void> deleteGameToCreateEntry(String suggestionId) async {
    await _post('games-to-create/delete', {'id': suggestionId});
  }

  /// Supprime un lot d'entrées « Jeux à créer ».
  Future<void> deleteGamesToCreateBatch(List<String> suggestionIds) async {
    await _post('games-to-create/delete-batch', {'ids': suggestionIds});
  }

  /// Récupère le top 20 des contributeurs (par suggestions acceptées).
  ///
  /// Utilise la vue `contributor_stats` qui inclut désormais `display_name`
  /// directement (pour Vision et les contributeurs sans profil lié).
  Future<List<Map<String, dynamic>>> fetchTopContributors(
      {int limit = 20}) async {
    final Uri uri = Uri.parse(
      '$supabaseUrl/rest/v1/contributor_stats'
      '?select=accepted_count,total_accepted_count,display_name,author_id'
      '&order=accepted_count.desc'
      '&limit=$limit',
    );
    final http.Response res = await http.get(uri, headers: _anonHeaders);
    if (res.statusCode != 200) {
      throw Exception(
          'fetchTopContributors échec ${res.statusCode}: ${res.body}');
    }
    final List<dynamic> rows = jsonDecode(res.body) as List<dynamic>;
    return rows.map((r) {
      final row = r as Map<String, dynamic>;
      final name = (row['display_name'] as String?) ?? 'Inconnu';
      return <String, dynamic>{
        'userId': row['author_id'] as String? ?? '',
        'displayName': name,
        'avatarPreset': null,
        'acceptedCount': row['accepted_count'] ?? 0,
        'totalAcceptedCount': row['total_accepted_count'],
        'isVision': name.toLowerCase() == 'vision',
      };
    }).toList();
  }

  /// Recherche un profil par email (pour l'ajout d'abonné Plus par email).
  ///
  /// Retourne l'UUID du profil trouvé, ou null si introuvable.
  /// Passe par la route service_role `profiles/find-by-email` de l'Edge
  /// Function admin-catalog (le RPC SQL est exécuté côté fonction).
  Future<String?> findProfileByEmail(String email) async {
    try {
      // Route service_role (Phase 2) : fonctionne quel que soit l'état des
      // grants sur le RPC SQL `find_profile_by_email` (révoqué en Phase 3).
      final Map<String, dynamic> data =
          await _post('profiles/find-by-email', {'email': email});
      final id = data['id'];
      return id is String && id.isNotEmpty ? id : null;
    } on AdminAuthException {
      // 401 = session expirée → on laisse remonter pour le logout forcé.
      rethrow;
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // COMPTEURS (pour la pagination)
  // ===========================================================================

  /// Compte le nombre total de suggestions par catégorie (pour la pagination).
  Future<int> countSuggestions({String? filter}) async {
    var query = '$supabaseUrl/rest/v1/suggestions?select=id';
    if (filter != null) query += '&$filter';
    final res = await http.get(
      Uri.parse(query),
      headers: {..._anonHeaders, 'Prefer': 'count=exact'},
    );
    if (res.statusCode == 200) {
      final range = res.headers['content-range'];
      if (range != null) {
        final parts = range.split('/');
        if (parts.length == 2) {
          return int.tryParse(parts[1]) ?? 0;
        }
      }
      return (jsonDecode(res.body) as List).length;
    }
    return 0;
  }

  // ===========================================================================
  // ÉCRITURES (Edge Function admin-catalog — service_role)
  // ===========================================================================

  Future<Map<String, dynamic>> _post(
    String route,
    Map<String, dynamic> body,
  ) async {
    final http.Response res = await http.post(
      Uri.parse('$catalogEndpoint/$route'),
      headers: _adminHeaders,
      body: jsonEncode(body),
    );
    final Map<String, dynamic> data =
        jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode >= 400) {
      // 401 = token admin expiré ou invalide → exception spécialisée pour
      // permettre au StoreController de forcer le logout.
      if (res.statusCode == 401) {
        throw AdminAuthException(
          data['error']?.toString() ?? 'Session expirée',
        );
      }
      throw Exception(data['error'] ?? 'Erreur serveur (${res.statusCode})');
    }
    // Sliding session : si la réponse contient un fresh_token, on notifie
    // le client pour qu'il remplace son token (prolongation 15 min).
    final freshToken = data['fresh_token'];
    if (freshToken is String && freshToken.isNotEmpty) {
      onTokenRefreshed?.call(freshToken);
      // Retire le fresh_token des données pour ne pas polluer les modèles.
      data.remove('fresh_token');
    }
    return data;
  }

  Future<Game> upsertGame(Game game) async {
    final data = await _post('games', {
      'id': game.id,
      'name': game.name,
      'publisher': game.publisher,
      'cover_url': game.coverUrl,
      'active': game.active,
    });
    // L'Edge Function renvoie la ligne Supabase brute (snake_case) → on
    // convertit en camelCase avant de la passer au modèle.
    final row = data['game'] as Map<String, dynamic>;
    return Game.fromJson(_camelRow(row));
  }

  Future<void> deleteGame(String id) async {
    await _post('games/delete', {'id': id});
  }

  Future<Content> upsertContent(Content content) async {
    final data = await _post('contents', {
      'id': content.id,
      'game_id': content.gameId,
      'category': content.category.name,
      'url': content.url,
      'title_source': content.titleAdmin,
      'title_admin': content.titleAdmin,
      'image_url': content.imageUrl,
      'validated': content.validated,
      'is_video': content.isVideo,
      'video_language': content.videoLanguage,
    });
    // L'Edge Function renvoie la ligne Supabase brute (snake_case) → on
    // convertit en camelCase avant de la passer au modèle.
    final row = data['content'] as Map<String, dynamic>;
    return Content.fromJson(_camelRow(row));
  }

  Future<void> deleteContent(String id) async {
    await _post('contents/delete', {'id': id});
  }

  Future<void> acceptSuggestion({
    required String suggestionId,
    required String gameId,
    required ContentCategory category,
    required String titleAdmin,
    bool isVideo = false,
    DateTime? publishedAt,
  }) async {
    await _post('suggestions/accept', {
      'id': suggestionId,
      'game_id': gameId,
      'category': category.name,
      'title_admin': titleAdmin,
      'is_video': isVideo,
      if (publishedAt != null) 'published_at': publishedAt.toIso8601String(),
    });
  }

  Future<void> rejectSuggestion(String suggestionId) async {
    await _post('suggestions/reject', {'id': suggestionId});
  }

  Future<void> banUser(String userId, {String? reason}) async {
    await _post('profiles/ban', {'user_id': userId, 'reason': reason});
  }

  Future<void> unbanUser(String userId) async {
    await _post('profiles/unban', {'user_id': userId});
  }

  Future<void> upsertSubscription({
    required String userId,
    required String plan,
    bool isActive = true,
    DateTime? startedAt,
    DateTime? expiresAt,
    String source = 'admin',
  }) async {
    await _post('subscriptions/upsert', {
      'user_id': userId,
      'plan': plan,
      'is_active': isActive,
      'started_at': startedAt?.toIso8601String(),
      'expires_at': expiresAt?.toIso8601String(),
      'source': source,
    });
  }

  /// Récupère tous les abonnements depuis Supabase (via Edge Function).
  ///
  /// Retourne une liste de maps avec : user_id, plan, is_active, started_at,
  /// expires_at, displayName (du profil joint).
  Future<List<Map<String, dynamic>>> fetchSubscriptions() async {
    final data = await _post('subscriptions/list', {});
    final subs = data['subscriptions'] as List? ?? [];
    return subs.map((s) {
      final m = s as Map<String, dynamic>;
      return <String, dynamic>{
        'id': m['user_id'] as String,
        'plan': (m['plan'] as String?) ?? 'monthly',
        'active': (m['is_active'] as bool?) ?? false,
        'startedAt': m['started_at'] as String?,
        'expiresAt': m['expires_at'] as String?,
        'displayName': m['display_name'] as String? ?? 'Inconnu',
        'source': (m['source'] as String?) ?? 'admin',
      };
    }).toList();
  }
}
