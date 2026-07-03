import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/models/category.dart';
import '../domain/models/content.dart';
import '../domain/models/game.dart';
import '../domain/models/suggestion.dart';

/// Synchronisation entre le panneau admin et Supabase.
///
/// **Lectures** : via l'API REST PostgREST (anon key suffit grâce aux
/// politiques RLS publiques en lecture sur `games` et `contents` validés).
/// **Écritures** : via l'Edge Function `admin-catalog` (service_role,
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
  // LECTURES (PostgREST — anon key)
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
  Future<List<Game>> fetchGames() async {
    final Uri uri = Uri.parse('$supabaseUrl/rest/v1/games?select=*');
    final http.Response res = await http.get(uri, headers: _anonHeaders);
    if (res.statusCode != 200) {
      throw Exception('fetchGames échec ${res.statusCode}: ${res.body}');
    }
    final List<dynamic> rows = jsonDecode(res.body) as List<dynamic>;
    return rows
        .map((r) => Game.fromJson(_camelRow(r as Map<String, dynamic>)))
        .toList();
  }

  /// Récupère tous les contenus validés.
  Future<List<Content>> fetchContents() async {
    final Uri uri = Uri.parse(
      '$supabaseUrl/rest/v1/contents?select=*&order=published_at.desc',
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

  /// Récupère toutes les suggestions (tous statuts) avec le profil auteur.
  ///
  /// La table `suggestions` ne stocke que `author_id` (UUID) ; on utilise la
  /// fonction de jointure PostgREST pour récupérer le profil (displayName,
  /// avatar) via la FK `author_id → profiles.id`.
  Future<List<Suggestion>> fetchSuggestions() async {
    final Uri uri = Uri.parse(
      '$supabaseUrl/rest/v1/suggestions'
      '?select=*,author:profiles(id,display_name,avatar_preset)'
      '&order=shared_at.desc',
    );
    final http.Response res = await http.get(uri, headers: _anonHeaders);
    if (res.statusCode != 200) {
      throw Exception(
          'fetchSuggestions échec ${res.statusCode}: ${res.body}');
    }
    final List<dynamic> rows = jsonDecode(res.body) as List<dynamic>;
    return rows.map((r) {
      final row = r as Map<String, dynamic>;
      // Construit l'objet author attendu par Suggestion.fromJson.
      final authorData = row['author'];
      final Map<String, dynamic> authorObj = authorData is Map
          ? {
              'id': authorData['id'] ?? row['author_id'] ?? '',
              'displayName':
                  authorData['display_name'] ?? 'Inconnu',
              'avatarUrl': authorData['avatar_preset'],
            }
          : {
              'id': row['author_id'] ?? '',
              'displayName': 'Inconnu',
            };
      final Map<String, dynamic> mapped = _camelRow(row);
      mapped['author'] = authorObj;
      return Suggestion.fromJson(mapped);
    }).toList();
  }

  /// Récupère le top 20 des contributeurs (par suggestions acceptées).
  ///
  /// Utilise la vue `contributor_stats` jointe à `profiles`.
  Future<List<Map<String, dynamic>>> fetchTopContributors(
      {int limit = 20}) async {
    final Uri uri = Uri.parse(
      '$supabaseUrl/rest/v1/contributor_stats'
      '?select=accepted_count,author:profiles(id,display_name,avatar_preset)'
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
      final author = row['author'] as Map<String, dynamic>?;
      return <String, dynamic>{
        'userId': author?['id'] ?? '',
        'displayName': author?['display_name'] ?? 'Inconnu',
        'avatarPreset': author?['avatar_preset'],
        'acceptedCount': row['accepted_count'] ?? 0,
      };
    }).toList();
  }

  /// Recherche un profil par email (pour l'ajout d'abonné Plus par email).
  ///
  /// Retourne l'UUID du profil trouvé, ou null si introuvable.
  /// Note : la table `profiles` ne contient pas `email` par défaut — cette
  /// méthode utilise une jointure avec `auth.users` via PostgREST si la FK
  /// existe, sinon retourne null.
  Future<String?> findProfileByEmail(String email) async {
    try {
      final Uri uri = Uri.parse(
        '$supabaseUrl/rest/v1/rpc/find_profile_by_email?email=${Uri.encodeComponent(email)}',
      );
      final http.Response res = await http.get(uri, headers: _anonHeaders);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data is String && data.isNotEmpty) return data;
        if (data is Map) return data['id'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
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
      throw Exception(data['error'] ?? 'Erreur serveur (${res.statusCode})');
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
    return Game.fromJson(data['game'] as Map<String, dynamic>);
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
    });
    return Content.fromJson(data['content'] as Map<String, dynamic>);
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
  }) async {
    await _post('suggestions/accept', {
      'id': suggestionId,
      'game_id': gameId,
      'category': category.name,
      'title_admin': titleAdmin,
      'is_video': isVideo,
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
  }) async {
    await _post('subscriptions/upsert', {
      'user_id': userId,
      'plan': plan,
      'is_active': isActive,
      'started_at': startedAt?.toIso8601String(),
      'expires_at': expiresAt?.toIso8601String(),
    });
  }
}
