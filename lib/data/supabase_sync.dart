import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import '../domain/ids.dart';
import '../domain/jwt_payload.dart';
import '../domain/models/admin_user_account.dart';
import '../domain/models/ban_category.dart';
import '../domain/models/banned_channel.dart';
import '../domain/models/banned_user.dart';
import '../domain/models/category.dart';
import '../domain/models/content.dart';
import '../domain/models/game.dart';
import '../domain/models/game_alias.dart';
import '../domain/models/log_entry.dart';
import '../domain/models/moderation.dart';
import '../domain/models/ready_games.dart';
import '../domain/models/suggestion.dart';
import '../domain/models/sync_status.dart';
import '../domain/models/trusted_channel.dart';
import '../domain/plus_paging.dart';
import '../domain/trusted_channels_paging.dart';
import 'supabase_key_headers.dart';

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

/// Exception levée quand le serveur refuse l'accès (HTTP 403) — compte
/// authentifié mais privilège insuffisant (ex. route réservée au compte
/// principal comme `logs/list`). Contrairement au 401, ce n'est PAS une
/// session expirée : pas de logout forcé, juste un message dédié côté UI.
class AdminForbiddenException implements Exception {
  const AdminForbiddenException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Réponse d'erreur de l'EF (statut ≥ 400 hors 401 / 403) : statut et corps
/// décodé CONSERVÉS (409 de modération : `result`, `ban_event_id`,
/// `distinct_contents`, `threshold` ; 400 de settings-set : `reasons`).
///
/// Porte aussi une réponse 2xx ILLISIBLE (corps non JSON, tableau, objet
/// attendu absent) : [statusCode] < 400, issue côté serveur inconnue
/// ([isUncertainFailure] vrai) → l'écran relit l'état.
class AdminApiException implements Exception {
  const AdminApiException(
    this.statusCode,
    this.message, {
    this.body = const <String, dynamic>{},
  });

  /// Statut HTTP de la réponse.
  final int statusCode;

  /// `body['error']` si texte non vide, sinon « Erreur serveur (HTTP <code>). »
  /// (texte français du serveur : c'est lui qui est affiché).
  final String message;

  /// Corps d'erreur complet (`{}` si non JSON).
  final Map<String, dynamic> body;

  /// `result` du corps d'erreur (409 de review-decide, profiles/unban,
  /// channels/unban) ; `null` quand la route n'en renvoie pas.
  String? get result =>
      body['result'] is String ? body['result'] as String : null;

  /// Événement du ban automatique (409 `auto_ban_use_review`).
  int? get banEventId => _int(body['ban_event_id']);

  /// 409 `below_threshold` : contenus distincts de la chaîne.
  int? get distinctContents => _int(body['distinct_contents']);

  /// 409 `below_threshold` : seuil (2).
  int? get threshold => _int(body['threshold']);

  /// Champs refusés (400 « Réglages invalides. ») — lecture tolérante :
  /// jamais de TypeError si `reasons` n'est pas une liste.
  List<String> get reasons {
    final Object? r = body['reasons'];
    return r is List ? r.whereType<String>().toList() : const <String>[];
  }

  bool get isConflict => statusCode == 409;
  bool get isNotFound => statusCode == 404;
  bool get isServerError => statusCode >= 500;

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  /// Le message seul (plus de préfixe « Exception: »).
  @override
  String toString() => message;
}

/// Échec dont l'issue côté serveur est INCONNUE (coupure, délai dépassé,
/// 5xx après rejeux, réponse illisible) : l'écriture a pu aboutir → relire.
bool isUncertainFailure(Object e) =>
    e is http.ClientException ||
    e is TimeoutException ||
    (e is AdminApiException && (e.statusCode >= 500 || e.statusCode < 400));

/// Message lisible d'une erreur quelconque (sans « Exception: »).
String errorText(Object e) {
  final String s = e.toString();
  return s.startsWith('Exception: ') ? s.substring(11) : s;
}

/// Réponse décodée + nombre de tentatives (1 = pas de rejeu). Un rejeu
/// signifie que la 1re réponse a été PERDUE (coupure, délai, 5xx) : la 1re
/// tentative a pu agir côté serveur.
typedef PostResult = ({Map<String, dynamic> data, int attempts});

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
    List<Duration>? retryDelays,
  }) : retryDelays = retryDelays ?? defaultRetryDelays;

  /// URL du projet Supabase (ex. https://xxx.supabase.co).
  final String supabaseUrl;

  /// Clé PUBLIQUE (ancienne `anon` ou publishable `sb_publishable_…` ;
  /// lecture seule grâce à RLS), envoyée seulement dans `apikey`
  /// ([supabaseKeyHeaders]).
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

  /// Timeout appliqué à CHAQUE requête HTTP (30 s). Remplace l'ancien
  /// timeout global de 15 s qui tuait toute la sync dès qu'une page
  /// traînait : ici, seule la requête fautive échoue, et le budget global
  /// est géré par le StoreController (120 s full / 45 s incrémental).
  static const Duration requestTimeout = Duration(seconds: 30);

  /// Headers des lectures PostgREST : la clé publique dans `apikey`
  /// SEULEMENT (étape 3a, voir supabase_key_headers.dart) ; la passerelle
  /// fournit le rôle `anon` à PostgREST.
  Map<String, String> get _anonHeaders => supabaseKeyHeaders(anonKey);

  /// Headers pour les appels à l'Edge Function admin-catalog :
  ///   - `apikey: <clé publique>` (seul en-tête de clé, étape 3a) ;
  ///   - `X-Admin-Token: <jwt_admin>` → notre code Deno lit ce header
  ///     personnalisé (le header `Authorization` est réservé à Supabase Auth,
  ///     on n'y met ni la clé publique ni notre JWT admin).
  /// admin-catalog tourne sans « Verify JWT » : la passerelle n'exige aucun
  /// `Authorization`.
  Map<String, String> get _adminHeaders => {
    'Content-Type': 'application/json',
    ...supabaseKeyHeaders(anonKey),
    'X-Admin-Token': adminToken,
  };

  /// Met à jour le jeton admin (appelé après un login réussi).
  void setAdminToken(String token) => adminToken = token;

  /// Jeton admin utilisable : JWT lisible dont l'`exp` est dans le futur
  /// ([isJwtUsable]). Sans lui, aucun appel à admin-catalog ne part (journal
  /// du 12/10/2026 : 401 en série d'un vieil onglet, appels du démarrage
  /// avant la connexion).
  bool get hasUsableAdminToken => isJwtUsable(adminToken);

  // ===========================================================================
  // RETRY ANTI MICRO-COUPURES (10/09/2026)
  // ===========================================================================
  // En cas de micro-coupure réseau (ClientException — fréquent en connexion
  // instable à l'étranger), de timeout, ou de 5xx transitoire (cold start
  // d'Edge Function / gateway), on retente automatiquement au lieu d'échouer
  // immédiatement. JAMAIS de retry sur 4xx (400 logique, 401 auth) : ces
  // erreurs sont définitives et le retry serait contre-productif.
  // Les routes EF d'écriture sont idempotentes (skip non-pending, pas de
  // doublon) → rejouer une écriture dont la réponse s'est perdue est sûr.
  // P4b-3 (T2) : délais INJECTABLES (les tests passent des délais nuls) ;
  // le nombre de tentatives est exposé aux écritures de modération (rejeu
  // visible, voir [PostResult]).

  /// Délais par défaut entre les tentatives (immédiate, +2 s, +4 s).
  static const List<Duration> defaultRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  /// Délais entre les tentatives (une tentative de plus que de délais).
  final List<Duration> retryDelays;

  /// Exécute [call] avec retry automatique (3 tentatives max par défaut :
  /// immédiate, +2 s, +4 s) sur erreur réseau transitoire ou 5xx.
  Future<http.Response> _withRetry(
    Future<http.Response> Function() call,
  ) async => (await _withRetryCounted(call)).$1;

  /// Comme [_withRetry], et rend aussi le NOMBRE de tentatives faites
  /// (1 = pas de rejeu). Rejoue `ClientException`, `TimeoutException` et
  /// tout statut ≥ 500 ; jamais un 4xx (définitif).
  Future<(http.Response, int)> _withRetryCounted(
    Future<http.Response> Function() call,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(retryDelays[attempt - 1]);
      }
      try {
        final res = await call();
        // 5xx = transitoire (cold start, gateway) → retente si possible.
        if (res.statusCode >= 500 && attempt < retryDelays.length) continue;
        return (res, attempt + 1);
      } on http.ClientException catch (e) {
        lastError = e; // NetworkError (fetch navigateur avorté, coupure)
      } on TimeoutException catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? Exception('Requête échouée après retries');
  }


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
        case 'release_date':
          out['releaseDate'] = value;
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
        case 'manual_date':
          out['manualDate'] = value;
        case 'manual_check':
          out['manualCheck'] = value;
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

  /// Max de la colonne `updated_at` (migration 0056) parmi des lignes brutes
  /// snake_case. Sert au curseur de sync incrémentale. Null si aucune ligne
  /// ou colonne absente.
  static DateTime? _maxUpdatedAt(List<dynamic> rows) {
    DateTime? max;
    for (final r in rows) {
      if (r is! Map) continue;
      final DateTime? t = DateTime.tryParse(
        (r as Map<String, dynamic>)['updated_at']?.toString() ?? '',
      );
      if (t != null && (max == null || t.isAfter(max))) max = t;
    }
    return max;
  }

  /// Récupère les jeux par page.
  ///
  /// [page] : index de la page (0-based).
  /// [pageSize] : nombre de jeux par page (défaut 1000).
  /// [since] : curseur incrémental optionnel (ISO 8601) — ne retourne que les
  /// lignes `updated_at >= since` (migration 0056, filtre PostgREST direct).
  ///
  /// Retourne les modèles + le max `updated_at` de la page (curseur).
  Future<({List<Game> items, DateTime? maxUpdatedAt})> fetchGames({
    int page = 0,
    int pageSize = 1000,
    String? since,
  }) async {
    final Uri uri = Uri.parse(
      '$supabaseUrl/rest/v1/games?select=*'
      '${since != null ? '&updated_at=gte.$since' : ''}'
      // Tri déterministe obligatoire : la pagination par offset SANS ORDER BY
      // n'est pas stable en Postgres (revue I-002) — une ligne manquée en
      // full sync ne serait rattrapée qu'au bout de 24 h.
      '&order=id.asc'
      '&limit=$pageSize&offset=${page * pageSize}',
    );
    final http.Response res = await _withRetry(
      () => http.get(uri, headers: _anonHeaders).timeout(requestTimeout),
    );
    if (res.statusCode != 200) {
      throw Exception('fetchGames échec ${res.statusCode}: ${res.body}');
    }
    final List<dynamic> rows = jsonDecode(res.body) as List<dynamic>;
    return (
      items: rows
          .map((r) => Game.fromJson(_camelRow(r as Map<String, dynamic>)))
          .toList(),
      maxUpdatedAt: _maxUpdatedAt(rows),
    );
  }

  /// Récupère les contenus validés par page.
  ///
  /// [page] : index de la page (0-based).
  /// [pageSize] : nombre de contenus par page (défaut 1000 pour la rétrocompatibilité).
  /// [since] : curseur incrémental optionnel (ISO 8601) — ne retourne que les
  /// lignes `updated_at >= since` (migration 0056).
  ///
  /// Retourne les modèles + le max `updated_at` de la page (curseur).
  Future<({List<Content> items, DateTime? maxUpdatedAt})> fetchContents({
    int page = 0,
    int pageSize = 1000,
    String? since,
  }) async {
    final Uri uri = Uri.parse(
      // Tiebreaker id.asc : published_at.desc seul n'est PAS déterministe
      // (beaucoup de contenus partagent le même timestamp) → risque de lignes
      // manquées/dupliquées entre pages (revue I-002).
      '$supabaseUrl/rest/v1/contents?select=*&order=published_at.desc,id.asc'
      '${since != null ? '&updated_at=gte.$since' : ''}'
      '&limit=$pageSize&offset=${page * pageSize}',
    );
    final http.Response res = await _withRetry(
      () => http.get(uri, headers: _anonHeaders).timeout(requestTimeout),
    );
    if (res.statusCode != 200) {
      throw Exception('fetchContents échec ${res.statusCode}: ${res.body}');
    }
    final List<dynamic> rows = jsonDecode(res.body) as List<dynamic>;
    return (
      items: rows
          .map((r) => Content.fromJson(_camelRow(r as Map<String, dynamic>)))
          .toList(),
      maxUpdatedAt: _maxUpdatedAt(rows),
    );
  }

  /// Compte les lignes d'une table via une requête HEAD avec
  /// `Prefer: count=exact` — PostgREST renvoie le total dans le header
  /// `content-range: */N` SANS transférer aucune ligne (0 egress utile).
  ///
  /// [filter] : filtre PostgREST optionnel (ex. `active=eq.true`).
  /// Retourne -1 si le comptage est indisponible (table protégée par RLS
  /// pour l'anon key, header absent, etc.).
  Future<int> fetchTableCount(String table, {String? filter}) async {
    try {
      final Uri uri = Uri.parse(
        '$supabaseUrl/rest/v1/$table?select=*'
        '${filter != null ? '&$filter' : ''}',
      );
      final http.Response res = await _withRetry(
        () => http
            .head(uri, headers: {..._anonHeaders, 'Prefer': 'count=exact'})
            .timeout(requestTimeout),
      );
      if (res.statusCode >= 300) return -1;
      final String contentRange = res.headers['content-range'] ?? '';
      final int slash = contentRange.indexOf('/');
      if (slash < 0) return -1;
      return int.tryParse(contentRange.substring(slash + 1).trim()) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  // ── Suggestions : lectures service_role (Phase 2 du durcissement RLS) ──
  // Les lectures suggestions/profils du panneau passent par la route
  // `suggestions/list` de l'Edge Function admin-catalog (service_role) au
  // lieu de PostgREST anon. Filtres et shape de retour strictement
  // identiques aux anciennes requêtes (embed `author` reconstitué côté
  // fonction) : aucun changement de comportement pour l'UI.

  /// Convertit les lignes suggestions (snake_case + embed `author`) en
  /// modèles [Suggestion]. Mapping identique à l'ancien embed PostgREST
  /// `author:profiles(id,display_name,avatar_preset)`, plus l'indicateur
  /// `author_is_plus` (auteur abonné Plus actif — migration 0085 ; absent
  /// d'une EF antérieure → false).
  static List<Suggestion> mapSuggestionRows(List<dynamic> rows) {
    return rows.map((r) {
      final row = r as Map<String, dynamic>;
      final authorData = row['author'];
      final bool isPlus = row['author_is_plus'] == true;
      final Map<String, dynamic> authorObj = authorData is Map
          ? {
              'id': authorData['id'] ?? row['author_id'] ?? '',
              'displayName':
                  authorData['display_name'] ?? row['author_name'] ?? 'Inconnu',
              'avatarUrl': authorData['avatar_preset'],
              'isPlus': isPlus,
            }
          : {
              'id': row['author_id'] ?? '',
              'displayName': row['author_name'] ?? 'Inconnu',
              'isPlus': isPlus,
            };
      final Map<String, dynamic> mapped = _camelRow(row);
      mapped['author'] = authorObj;
      return Suggestion.fromJson(mapped);
    }).toList();
  }

  /// Lecture des suggestions par mode via la route service_role
  /// `suggestions/list` (pagination identique : page/pageSize 0-based).
  ///
  /// [since] : curseur incrémental optionnel (ISO 8601, migration 0056 /
  /// EF v63) — l'EF ne retourne que les lignes `updated_at >= since`
  /// EN PLUS du filtre de mode. Rétro-compatible (paramètre ignoré si absent).
  ///
  /// Retourne les modèles + le max `updated_at` de la page (curseur).
  Future<({List<Suggestion> items, DateTime? maxUpdatedAt})>
  _fetchSuggestionsByMode(
    String mode, {
    int page = 0,
    int pageSize = 500,
    String? since,
  }) async {
    final Map<String, dynamic> data = await _post('suggestions/list', {
      'mode': mode,
      'page': page,
      'pageSize': pageSize,
      'since': ?since,
    });
    final List<dynamic> rows = data['suggestions'] as List? ?? [];
    return (items: mapSuggestionRows(rows), maxUpdatedAt: _maxUpdatedAt(rows));
  }

  /// Récupère les suggestions VRAIMENT nouvelles : jamais prises en charge
  /// par Sentinelle (`sentinelle_started_at IS NULL` ET pas encore
  /// d'analyse IA). Ces suggestions apparaissent dans le menu "Suggestions".
  Future<({List<Suggestion> items, DateTime? maxUpdatedAt})> fetchSuggestions({
    int page = 0,
    int pageSize = 500,
    String? since,
  }) => _fetchSuggestionsByMode(
    'new',
    page: page,
    pageSize: pageSize,
    since: since,
  );

  /// Récupère les suggestions EN COURS d'analyse par Sentinelle
  /// (`sentinelle_started_at NOT NULL` MAIS `ai_recommendation IS NULL`).
  /// Ces suggestions apparaissent dans le menu "Sentinelle" → section
  /// "Analyse en cours" (Sentinelle travaille dessus).
  Future<({List<Suggestion> items, DateTime? maxUpdatedAt})>
  fetchSentinelleAnalyzing({int page = 0, int pageSize = 500, String? since}) =>
      _fetchSuggestionsByMode(
        'analyzing',
        page: page,
        pageSize: pageSize,
        since: since,
      );

  /// Récupère les suggestions DÉJÀ analysées par Sentinelle (avec
  /// `ai_recommendation` non null). Ces suggestions apparaissent dans le menu
  /// "Sentinelle" où l'admin peut les implémenter en 1 clic ou les vérifier.
  Future<({List<Suggestion> items, DateTime? maxUpdatedAt})>
  fetchSentinelleSuggestions({
    int page = 0,
    int pageSize = 500,
    String? since,
  }) => _fetchSuggestionsByMode(
    'analyzed',
    page: page,
    pageSize: pageSize,
    since: since,
  );

  /// Récupère les suggestions découvertes par le bot Scruteur (sites web de
  /// guides) : source='scruteur', déjà jugées par l'IA (ai_recommendation
  /// présent), en attente de validation. Apparaissent dans le menu "Scruteur".
  Future<({List<Suggestion> items, DateTime? maxUpdatedAt})>
  fetchScruteurSuggestions({int page = 0, int pageSize = 500, String? since}) =>
      _fetchSuggestionsByMode(
        'scruteur',
        page: page,
        pageSize: pageSize,
        since: since,
      );

  /// Récupère les suggestions marquées « Jeux à créer » : le flag
  /// `needs_game_creation` est vrai dans `ai_recommendation`, le statut est
  /// pending, et l'auteur n'est pas Vision.
  Future<({List<Suggestion> items, DateTime? maxUpdatedAt})>
  fetchGamesToCreate({int page = 0, int pageSize = 500, String? since}) =>
      _fetchSuggestionsByMode(
        'games-to-create',
        page: page,
        pageSize: pageSize,
        since: since,
      );

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
  Future<List<Map<String, dynamic>>> fetchTopContributors({
    int limit = 20,
  }) async {
    final Uri uri = Uri.parse(
      '$supabaseUrl/rest/v1/contributor_stats'
      '?select=accepted_count,total_accepted_count,display_name,author_id'
      '&order=accepted_count.desc'
      '&limit=$limit',
    );
    final http.Response res = await _withRetry(
      () => http.get(uri, headers: _anonHeaders).timeout(requestTimeout),
    );
    if (res.statusCode != 200) {
      throw Exception(
        'fetchTopContributors échec ${res.statusCode}: ${res.body}',
      );
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
  /// Retourne l'UUID du profil trouvé, ou null si introuvable OU en cas
  /// d'erreur (sauf 401, relancé pour le logout forcé). Enveloppe de
  /// [lookupProfileIdByEmail] (P4b-3) : même route, e-mail en minuscules.
  Future<String?> findProfileByEmail(String email) async {
    try {
      return await lookupProfileIdByEmail(email);
    } on AdminAuthException {
      // 401 = session expirée → on laisse remonter pour le logout forcé.
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// Résolution STRICTE e-mail → UUID de profil (route service_role
  /// `profiles/find-by-email` ; le RPC SQL est exécuté côté fonction).
  ///
  /// L'e-mail est envoyé rogné et en MINUSCULES : `find_profile_by_email`
  /// compare exactement (0007_find_profile_by_email.sql:16-26) et GoTrue
  /// stocke les e-mails en minuscules. Rend l'UUID, ou `null` = introuvable ;
  /// TOUTE erreur remonte (contrairement à [findProfileByEmail]) — une
  /// erreur SQL arrive en 400 « Recherche par email échouée ».
  Future<String?> lookupProfileIdByEmail(String email) async {
    // Route service_role (Phase 2) : fonctionne quel que soit l'état des
    // grants sur le RPC SQL `find_profile_by_email` (révoqué en Phase 3).
    final Map<String, dynamic> data = await _post('profiles/find-by-email', {
      'email': email.trim().toLowerCase(),
    });
    final Object? id = data['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  // ===========================================================================
  // COMPTEURS (pour la pagination)
  // ===========================================================================

  /// Compte le nombre total de suggestions par catégorie (pour la pagination).
  Future<int> countSuggestions({String? filter}) async {
    var query = '$supabaseUrl/rest/v1/suggestions?select=id';
    if (filter != null) query += '&$filter';
    final res = await _withRetry(
      () => http
          .get(
            Uri.parse(query),
            headers: {..._anonHeaders, 'Prefer': 'count=exact'},
          )
          .timeout(requestTimeout),
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

  /// Appel d'une route de l'EF (forme courte : la réponse décodée seule).
  Future<Map<String, dynamic>> _post(
    String route,
    Map<String, dynamic> body,
  ) async => (await _postWithMeta(route, body)).data;

  /// Appel d'une route de l'EF, TOLÉRANT (P4b-3, T1). Ordre : rejeux →
  /// décodage tolérant → statut → corps.
  ///   - 401 → [AdminAuthException] (logout forcé par le StoreController) ;
  ///   - 403 → [AdminForbiddenException] (privilège insuffisant, pas de
  ///     logout) ;
  ///   - tout autre statut ≥ 400 → [AdminApiException] avec le statut et le
  ///     corps décodé CONSERVÉS (`{}` si le corps n'est pas du JSON : page
  ///     HTML de passerelle, corps vide…) ;
  ///   - 2xx dont le corps n'est pas un objet JSON → [AdminApiException]
  ///     « Réponse illisible du serveur (HTTP <code>). » (issue inconnue).
  /// Le `fresh_token` (sliding session) est toujours retiré des données et
  /// transmis à [onTokenRefreshed] seulement si c'est un JWT lisible dont
  /// l'`exp` est dans le futur ([isJwtUsable]) ET si le jeton courant est
  /// encore celui envoyé (sinon : fin de session, déconnexion ou autre compte
  /// connecté pendant la requête — relecture du 12/10/2026) ; sinon le jeton
  /// courant reste.
  /// Rend aussi le nombre de tentatives (rejeu visible, [PostResult]).
  /// Jeton vide, illisible ou expiré ([hasUsableAdminToken]) →
  /// [AdminAuthException] SANS requête (même suite qu'un 401), vérifié à
  /// CHAQUE tentative : un rejeu (5xx, coupure) ne repart pas avec un jeton
  /// vidé entre-temps (fin de session, déconnexion).
  Future<PostResult> _postWithMeta(
    String route,
    Map<String, dynamic> body,
  ) async {
    String sentToken = '';
    final (http.Response res, int attempts) = await _withRetryCounted(() {
      if (!hasUsableAdminToken) {
        throw const AdminAuthException('Session expirée');
      }
      sentToken = adminToken;
      return http
          .post(
            Uri.parse('$catalogEndpoint/$route'),
            headers: _adminHeaders,
            body: jsonEncode(body),
          )
          .timeout(requestTimeout);
    });
    Map<String, dynamic>? data;
    try {
      final Object? d = jsonDecode(res.body);
      if (d is Map) data = Map<String, dynamic>.from(d);
    } on FormatException {
      data = null; // page HTML de passerelle, corps vide, octets invalides…
    }
    if (res.statusCode >= 400) {
      final Object? err = data?['error'];
      final String msg = err is String && err.trim().isNotEmpty
          ? err
          : 'Erreur serveur (HTTP ${res.statusCode}).';
      // 401 = token admin expiré ou invalide → exception spécialisée pour
      // permettre au StoreController de forcer le logout.
      if (res.statusCode == 401) {
        throw AdminAuthException(err is String ? err : 'Session expirée');
      }
      // 403 = compte authentifié mais privilège insuffisant (ex. logs/list
      // réservé au compte principal). Pas de logout : message dédié côté UI.
      if (res.statusCode == 403) {
        throw AdminForbiddenException(
          err is String ? err : 'Accès refusé (403)',
        );
      }
      throw AdminApiException(
        res.statusCode,
        msg,
        body: data ?? const <String, dynamic>{},
      );
    }
    if (data == null) {
      throw AdminApiException(
        res.statusCode,
        'Réponse illisible du serveur (HTTP ${res.statusCode}).',
      );
    }
    // Sliding session : si la réponse contient un fresh_token, on notifie
    // le client pour qu'il remplace son token (prolongation 15 min).
    // v2 (S-15) puis revue P4b-3 (SEC-P4b3-07) : seulement si c'est un JWT
    // au payload lisible dont l'`exp` est dans le futur ([isJwtUsable]) —
    // un jeton sans échéance ne remplace jamais le jeton courant.
    final Object? fresh = data['fresh_token'];
    if (fresh is String && isJwtUsable(fresh) && adminToken == sentToken) {
      onTokenRefreshed?.call(fresh);
    }
    // Retire le fresh_token des données pour ne pas polluer les modèles.
    data.remove('fresh_token');
    return (data: data, attempts: attempts);
  }

  /// Erreur « objet attendu absent » d'une réponse 2xx (issue inconnue →
  /// l'écran relit l'état). Le statut d'une réponse de succès de l'EF est
  /// toujours 200 (`jsonWithFreshToken`).
  static AdminApiException _unreadable() =>
      const AdminApiException(200, 'Réponse illisible du serveur.');

  /// Enregistre un NOUVEAU jeu (création seulement : id temporaire
  /// `g-<ms>` ou absent — les 6 clés sont envoyées, accepté par
  /// games_body.ts:80-87). Une MISE À JOUR passe par [patchGame] (envoi
  /// partiel) : un UUID ici réécrirait les 6 champs depuis le cache.
  Future<Game> upsertGame(Game game) async {
    assert(
      !isUuid(game.id),
      'upsertGame : création seulement (mise à jour → patchGame)',
    );
    final data = await _post('games', {
      'id': game.id,
      'name': game.name,
      'publisher': game.publisher,
      'cover_url': game.coverUrl,
      'release_date': game.releaseDate,
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

  /// Clés modifiables d'un jeu existant (route `games`, games_body.ts).
  static const Set<String> _gamePatchKeys = <String>{
    'name',
    'publisher',
    'cover_url',
    'release_date',
    'active',
  };

  /// Met à jour un jeu EXISTANT par envoi PARTIEL (route `games`, v95) :
  /// corps `{id, ...patch}` — clé présente = écrite (une valeur `null` est
  /// ENVOYÉE et vaut effacement), clé absente = inchangée. [patch] non vide,
  /// clés ⊂ {name, publisher, cover_url, release_date, active} (en snake_case)
  /// ; une autre clé est ignorée (jamais envoyée). [id] : UUID.
  ///
  /// Rend la ligne serveur à jour. Erreurs : 400 (validations de
  /// games_body.ts), 404 « Jeu introuvable. » ([AdminApiException.isNotFound]).
  Future<Game> patchGame(String id, Map<String, Object?> patch) async {
    assert(isUuid(id), 'patchGame : id UUID attendu');
    assert(patch.isNotEmpty, 'patchGame : patch vide');
    assert(
      patch.keys.every(_gamePatchKeys.contains),
      'patchGame : clé non prévue',
    );
    final Map<String, dynamic> data = await _post('games', <String, dynamic>{
      for (final MapEntry<String, Object?> e in patch.entries)
        if (_gamePatchKeys.contains(e.key)) e.key: e.value,
      'id': id,
    });
    final Object? row = data['game'];
    if (row is! Map) throw _unreadable();
    return Game.fromJson(_camelRow(Map<String, dynamic>.from(row)));
  }

  /// Taille de page de [fetchAllGames] (plafond serveur : 1000).
  static const int kGamesListPageSize = 500;

  /// Une page de TOUS les jeux, actifs ET inactifs (route `games/list`,
  /// v95 — la lecture anon est filtrée par la RLS sur `active = true`).
  /// Corps STRICT `{page, pageSize, active?}` (`active` absent = tous).
  /// Lignes illisibles (id ou nom non texte) ignorées ; `games` absent →
  /// réponse illisible (jamais une liste vide supposée).
  Future<({List<Game> games, int total})> fetchGamesList({
    int page = 0,
    int pageSize = kGamesListPageSize,
    bool? active,
  }) async {
    final Map<String, dynamic> data = await _post('games/list', {
      'page': page,
      'pageSize': pageSize.clamp(1, 1000),
      'active': ?active,
    });
    final Object? rows = data['games'];
    if (rows is! List) throw _unreadable();
    final List<Game> games = <Game>[
      for (final Object? r in rows)
        if (r is Map && r['id'] is String && r['name'] is String)
          Game.fromJson(_camelRow(Map<String, dynamic>.from(r))),
    ];
    final Object? total = data['total'];
    return (games: games, total: total is num ? total.toInt() : games.length);
  }

  /// Tous les jeux (filtrés par [active] s'il est donné) : pages de 500 tant
  /// que `(page + 1) * 500 < total` (garde : 100 pages).
  Future<List<Game>> fetchAllGames({bool? active}) async {
    final List<Game> out = <Game>[];
    for (var page = 0; page < 100; page++) {
      final r = await fetchGamesList(
        page: page,
        pageSize: kGamesListPageSize,
        active: active,
      );
      out.addAll(r.games);
      if (r.games.isEmpty || (page + 1) * kGamesListPageSize >= r.total) {
        break;
      }
    }
    return out;
  }

  /// Aperçu de « Activer les jeux prêts » (route `games/activate-ready`,
  /// `{dry_run: true}`, compte principal) : jeux INACTIFS ayant au moins
  /// 10 contenus validés (aperçu NON borné). 403 hors compte principal ;
  /// 500 « Aperçu impossible » (avec ou sans point).
  Future<ReadyGamesPreview> previewReadyGames() async {
    final Map<String, dynamic> data = await _post('games/activate-ready', {
      'dry_run': true,
    });
    return ReadyGamesPreview.fromJson(data) ?? (throw _unreadable());
  }

  /// Plafond serveur d'une activation (games_body.ts : 1 à 500 ids).
  static const int kActivateReadyMaxIds = 500;

  /// Active les jeux prêts choisis (route `games/activate-ready`,
  /// `{dry_run: false, ids}`, compte principal) : 1 à 500 UUID. Bilan
  /// `activated` / `skipped` (`already_active`, `below_threshold`,
  /// `not_found`) + [ActivateReadyResult.replayed].
  Future<ActivateReadyResult> activateReadyGames(List<String> ids) async {
    assert(
      ids.isNotEmpty && ids.length <= kActivateReadyMaxIds,
      'activateReadyGames : 1 à 500 identifiants',
    );
    assert(ids.every(isUuid), 'activateReadyGames : UUID attendus');
    final PostResult r = await _postWithMeta('games/activate-ready', {
      'dry_run': false,
      'ids': ids,
    });
    return ActivateReadyResult.fromJson(r.data, replayed: r.attempts > 1) ??
        (throw _unreadable());
  }

  // ── Traductions de titres de jeux (table game_translations) ──

  /// Récupère toutes les traductions de titres de jeux via la route
  /// `games/translations-list` (service_role).
  ///
  /// Retourne un map `{game_id: {lang: title}}`. Sert au dialog d'édition
  /// des traductions : un seul appel récupère tout, puis le caller filtre
  /// par gameId.
  Future<Map<String, Map<String, String>>> fetchAllTranslations() async {
    final Map<String, dynamic> data = await _post(
      'games/translations-list',
      <String, dynamic>{},
    );
    final List<dynamic> rows = data['translations'] as List? ?? [];
    final Map<String, Map<String, String>> byGame =
        <String, Map<String, String>>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final gameId = row['game_id'];
      final lang = row['lang'];
      final title = row['title'];
      if (gameId is! String || lang is! String || title is! String) continue;
      final gameMap = byGame.putIfAbsent(gameId, () => <String, String>{});
      gameMap[lang.toUpperCase()] = title;
    }
    return byGame;
  }

  /// Récupère les traductions d'UN seul jeu via PostgREST anon
  /// (`{LANG: title}`). §137 : UNE traduction par langue — la colonne
  /// `alt_titles` (migration 0080) n'est plus lue (les autres noms du jeu
  /// sont des ALIAS, table `game_aliases`).
  ///
  /// Contrairement à [fetchAllTranslations] (qui charge tout et peut être
  /// limité par la pagination), cette méthode ne récupère que les 12 lignes
  /// max du jeu concerné — aucun cutoff possible.
  Future<Map<String, String>> fetchTranslationsForGame(String gameId) async {
    final titles = <String, String>{};
    final res = await _withRetry(
      () => http
          .get(
            Uri.parse(
              '$supabaseUrl/rest/v1/game_translations'
              '?select=lang,title&game_id=eq.$gameId',
            ),
            headers: _anonHeaders,
          )
          .timeout(requestTimeout),
    );
    if (res.statusCode != 200) return titles;
    final List<dynamic> rows = jsonDecode(res.body) as List? ?? [];
    for (final row in rows) {
      if (row is! Map) continue;
      final lang = row['lang'];
      final title = row['title'];
      if (lang is! String || title is! String) continue;
      titles[lang.toUpperCase()] = title;
    }
    return titles;
  }

  /// Récupère TOUTES les traductions de titres via PostgREST anon
  /// (pagination 1000/page — même protocole que le GameTranslationsLoader
  /// des bots) — D1.4. Retourne `{game_id: {lang: title}}`.
  ///
  /// Sert au cache de traductions du StoreController (nettoyage local des
  /// titres d'insertion Sentinelle). BEST-EFFORT : retourne null en cas
  /// d'erreur (réseau, statut non 200, parsing) — l'appelant garde alors un
  /// cache vide (comportement antérieur, jamais de fetch par titre).
  Future<Map<String, Map<String, String>>?> fetchGameTranslationsAll() async {
    final out = <String, Map<String, String>>{};
    const int pageSize = 1000;
    try {
      for (var page = 0;; page++) {
        final res = await _withRetry(
          () => http
              .get(
                Uri.parse(
                  '$supabaseUrl/rest/v1/game_translations'
                  '?select=game_id,lang,title'
                  '&limit=$pageSize&offset=${page * pageSize}',
                ),
                headers: _anonHeaders,
              )
              .timeout(requestTimeout),
        );
        if (res.statusCode != 200) return null;
        final List<dynamic> rows = jsonDecode(res.body) as List? ?? [];
        for (final row in rows) {
          if (row is! Map) continue;
          final gameId = row['game_id'];
          final lang = row['lang'];
          final title = row['title'];
          if (gameId is! String || lang is! String || title is! String) {
            continue;
          }
          out.putIfAbsent(gameId, () => {})[lang.toUpperCase().trim()] = title;
        }
        if (rows.length < pageSize) break;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Sauvegarde (upsert batch) les traductions du titre d'un jeu via la route
  /// `games/translate` (service_role).
  ///
  /// [gameId] doit être un UUID valide. [translations] est un map
  /// `{LANG: title}` — les entrées vides sont ignorées côté caller (filtre
  /// avant l'appel) pour ne pas insérer de titres vides.
  ///
  /// §137 : `alt_titles` n'est plus JAMAIS envoyé (colonne laissée intacte
  /// en base ; les autres noms du jeu se saisissent dans les alias).
  ///
  /// Retourne `true` en cas de succès, `false` sinon.
  Future<bool> updateGameTranslations(
    String gameId,
    Map<String, String> translations,
  ) async {
    try {
      debugPrint(
        '[Sync] updateGameTranslations: gameId=$gameId, '
        '${translations.length} langues',
      );
      final data = await _post('games/translate', {
        'game_id': gameId,
        'translations': translations,
      });
      debugPrint('[Sync] updateGameTranslations succès: ${data['ok']}');
      return true;
    } on AdminAuthException {
      rethrow;
    } catch (e) {
      debugPrint('[Sync] updateGameTranslations ERREUR: $e');
      return false;
    }
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

  /// Met à jour les dates d'un contenu SAISIES MANUELLEMENT par l'admin
  /// (« Publié le » et/ou « Ajouté le »). Passe manual:true → l'EF pose
  /// manual_date=true : le bot Check ne tentera plus de retrouver ces dates
  /// (migration 0053).
  Future<void> updateContentDates(
    String id, {
    DateTime? publishedAt,
    DateTime? createdAt,
  }) async {
    await _post('contents/update-date', {
      'id': id,
      if (publishedAt != null)
        'published_at': publishedAt.toUtc().toIso8601String(),
      if (createdAt != null) 'created_at': createdAt.toUtc().toIso8601String(),
      'manual': true,
    });
  }

  /// Marque un contenu comme vérifié MANUELLEMENT par l'admin
  /// (checked_at=now + manual_check=true) — le bot Check l'exclut
  /// définitivement de toutes ses phases (migration 0053).
  Future<void> markContentCheckedManual(String id) async {
    await _post('contents/mark-checked', {
      'ids': [id],
      'manual': true,
    });
  }

  Future<void> acceptSuggestion({
    required String suggestionId,
    required String gameId,
    required ContentCategory category,
    required String titleAdmin,
    bool isVideo = false,
    DateTime? publishedAt,
    String? videoLanguage,
  }) async {
    await _post('suggestions/accept', {
      'id': suggestionId,
      'game_id': gameId,
      'category': category.name,
      'title_admin': titleAdmin,
      'is_video': isVideo,
      if (publishedAt != null) 'published_at': publishedAt.toIso8601String(),
      // Langue du contenu : pour les liens du Scruteur (catégorie 'links'),
      // transmet la langue détectée de la page web. L'EF v46 l'insère dans
      // contents.video_language. Les vidéos YouTube ne l'envoient pas (null).
      'video_language': ?videoLanguage,
    });
  }

  Future<void> rejectSuggestion(String suggestionId) async {
    await _post('suggestions/reject', {'id': suggestionId});
  }

  /// Valide un LOT de suggestions Sentinelle en un seul appel EF
  /// (`suggestions/accept-batch`, 27/08/2026). Remplace N appels
  /// [acceptSuggestion] + N resyncs complets par 1 appel par chunk de 100.
  ///
  /// [items] : une map par suggestion avec les clés `id`, `game_id`,
  /// `category` ('video'|'guides'|'links'), `title_admin`, `is_video`,
  /// et optionnellement `published_at` (ISO) / `video_language`.
  ///
  /// Retourne la réponse EF : `{ok: [ids], skipped: [{id, reason}],
  /// failed: [{id, error}]}`. L'EF est idempotente : rejouer un lot déjà
  /// validé est sans effet (skip non-pending, pas de doublon de contenu).
  Future<Map<String, dynamic>> acceptSuggestionsBatch(
    List<Map<String, dynamic>> items,
  ) async {
    return await _post('suggestions/accept-batch', {'items': items});
  }

  /// Rejette un LOT de suggestions Sentinelle en un seul appel EF
  /// (`suggestions/reject-batch`, 28/08/2026) — « Tout supprimer » /
  /// « Rejeter la sélection » du tableau « À vérifier ». Remplace N appels
  /// [rejectSuggestion] par 1 appel par chunk de 100.
  ///
  /// Même effet métier que le rejet unitaire : status 'rejected', sans
  /// suppression de ligne ni journal cache_ops (l'URL reste en cache
  /// anti-doublons). L'EF est idempotente : rejouer un lot déjà rejeté est
  /// sans effet (skip non-pending/introuvable).
  ///
  /// Retourne la réponse EF : `{ok: [ids], skipped: [{id, reason}],
  /// failed: [{id, error}]}`.
  Future<Map<String, dynamic>> rejectSuggestionsBatch(List<String> ids) async {
    return await _post('suggestions/reject-batch', {'ids': ids});
  }

  /// Débloque les suggestions stuck en "Analyse en cours" depuis > 10 min.
  /// Retourne le nombre de suggestions débloquées ET leurs ids (l'EF v71+
  /// renvoie `ids` — utilisé par le retrait optimiste du board « Analyses
  /// en cours », correctif F3 ; liste vide si l'EF est plus ancienne).
  Future<({int unlocked, List<String> ids})> unlockStuckSuggestions({
    int timeoutMinutes = 10,
  }) async {
    final data = await _post('suggestions/unlock-stuck', {
      'timeout_minutes': timeoutMinutes,
    });
    return (
      unlocked: (data['unlocked'] as int?) ?? 0,
      ids:
          (data['ids'] as List<dynamic>?)?.whereType<String>().toList() ??
          const <String>[],
    );
  }

  /// Compte les suggestions en "Analyse en cours" (optionnel : stuck seulement).
  Future<int> fetchAnalyzingCount({bool stuckOnly = false}) async {
    final data = await _post('suggestions/analyzing-count', {
      'stuck_only': stuckOnly,
    });
    return (data['count'] as int?) ?? 0;
  }

  /// Ban MANUEL d'un compte (route `profiles/ban`, v95) : corps
  /// `{user_id, reason, category?}` — `reason: null` gardé (accepté),
  /// `category` absente = défaut serveur `moderation`. Rend `applied` |
  /// `already_banned` + l'événement + [ManualBanResult.replayed]. Erreurs
  /// `{error}` SANS `result` (404 « Profil introuvable. », 400
  /// « category inconnue. »).
  Future<ManualBanResult> banUser(
    String userId, {
    String? reason,
    String? category,
  }) async {
    final PostResult r = await _postWithMeta('profiles/ban', {
      'user_id': userId,
      'reason': reason,
      'category': ?category,
    });
    return ManualBanResult.fromJson(r.data, replayed: r.attempts > 1);
  }

  /// Levée MANUELLE d'un ban de compte (route `profiles/unban`) : rend
  /// `lifted` | `not_banned`. Un ban AUTOMATIQUE (en revue ou confirmé)
  /// arrive en [AdminApiException] 409 `result: auto_ban_use_review` avec
  /// [AdminApiException.banEventId] (levée par le compte principal depuis la
  /// modération).
  Future<ManualUnbanResult> unbanUser(String userId) async {
    // Rejeu visible (revue P4b-3, INF-01) : [ManualUnbanResult.replayed].
    final PostResult r = await _postWithMeta('profiles/unban', {
      'user_id': userId,
    });
    return ManualUnbanResult.fromJson(r.data, replayed: r.attempts > 1);
  }

  /// Crée ou modifie un abonnement Plus (route EF `subscriptions/upsert`).
  ///
  /// Sémantique « champs FOURNIS uniquement » (migration 0085) : seuls les
  /// paramètres non nuls sont envoyés, et l'EF ne modifie QUE ceux-là sur un
  /// abonnement existant — suspendre ou changer la formule n'efface plus
  /// l'échéance d'un abonnement Google Play. [clearExpiry] envoie
  /// `expires_at: null` explicite (« sans échéance ») ; la source n'est
  /// jamais envoyée (jamais modifiée par l'EF). [plan] est obligatoire pour
  /// CRÉER un abonnement.
  Future<void> upsertSubscription({
    required String userId,
    String? plan,
    bool? isActive,
    DateTime? startedAt,
    DateTime? expiresAt,
    bool clearExpiry = false,
  }) async {
    await _post(
      'subscriptions/upsert',
      subscriptionUpsertBody(
        userId: userId,
        plan: plan,
        isActive: isActive,
        startedAt: startedAt,
        expiresAt: expiresAt,
        clearExpiry: clearExpiry,
      ),
    );
  }

  /// Corps de `subscriptions/upsert` : uniquement les champs à modifier
  /// (voir [upsertSubscription]). Dates en UTC ISO 8601.
  static Map<String, dynamic> subscriptionUpsertBody({
    required String userId,
    String? plan,
    bool? isActive,
    DateTime? startedAt,
    DateTime? expiresAt,
    bool clearExpiry = false,
  }) {
    return <String, dynamic>{
      'user_id': userId,
      'plan': ?plan,
      'is_active': ?isActive,
      'started_at': ?startedAt?.toUtc().toIso8601String(),
      if (expiresAt != null)
        'expires_at': expiresAt.toUtc().toIso8601String()
      else if (clearExpiry)
        'expires_at': null,
    };
  }

  /// Une page d'abonnés Plus (route EF `subscriptions/list`, pagination
  /// SERVEUR — migration 0085) : filtres, recherche et tri appliqués en SQL,
  /// total EXACT correspondant aux filtres. Aucun plafond de volume : seule
  /// la page demandée transite (100 lignes par défaut, 1 000 max).
  ///
  /// [status] : 'active' | 'inactive' (null = tous) ; [source] : 'google' |
  /// 'admin' (« Manuel », null = toutes) ; [sort] : display_name | plan |
  /// source | status | started_at (défaut : plus récents d'abord).
  /// Les exceptions sont PROPAGÉES (AdminAuthException incluse).
  Future<PlusPage> fetchSubscriptionsPage({
    int page = 0,
    int pageSize = kPlusPageSize,
    String? search,
    String? status,
    String? source,
    String? sort,
    bool ascending = false,
  }) async {
    final PlusPageQuery query = PlusPageQuery(
      page: page,
      pageSize: pageSize,
      search: search ?? '',
      status: status,
      source: source,
      sort: sort ?? kPlusDefaultSort,
      ascending: ascending,
    );
    final Map<String, dynamic> data = await _post(
      'subscriptions/list',
      query.toRequestBody(),
    );
    return parsePlusPage(data);
  }

  /// Compteurs des abonnés (route EF `subscriptions/stats`, migration 0085) :
  /// total, actifs (is_active), répartition par formule / source — sans
  /// charger la liste. Exceptions propagées.
  Future<PlusStats> fetchSubscriptionStats() async {
    final Map<String, dynamic> data = await _post(
      'subscriptions/stats',
      <String, dynamic>{},
    );
    return PlusStats.fromJson(data);
  }

  /// Supprime DÉFINITIVEMENT l'abonnement de [userId] (route EF
  /// `subscriptions/delete`, compte principal uniquement — 403 sinon).
  /// Retourne false si aucun abonnement n'existait déjà plus. Exceptions
  /// propagées.
  Future<bool> deleteSubscription(String userId) async {
    final Map<String, dynamic> data = await _post(
      'subscriptions/delete',
      <String, dynamic>{'user_id': userId},
    );
    return data['deleted'] == true;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ANALYTICS + CONFIG (EF v76, migration 0066 — chantier F1, §70.3/§70.6)
  // Retourne le JSON BRUT des routes (parsing en modèles côté
  // StoreController via domain/analytics_calc.dart).
  // ─────────────────────────────────────────────────────────────────────────

  /// Vue agrégée du menu Analytics {from, to} (bornes fuseau LOCAL du
  /// panneau, sérialisées en ISO 8601 complet — le fuseau est documenté
  /// dans l'UI de l'écran).
  Future<Map<String, dynamic>> fetchAnalyticsOverview({
    required DateTime from,
    required DateTime to,
  }) =>
      _post('analytics/overview', {
        'from': from.toIso8601String(),
        'to': to.toIso8601String(),
      });

  /// Séries temporelles des souscriptions {from, to, granularity}.
  Future<Map<String, dynamic>> fetchAnalyticsSeries({
    required DateTime from,
    required DateTime to,
    required String granularity, // 'day' | 'month'
  }) =>
      _post('analytics/series', {
        'from': from.toIso8601String(),
        'to': to.toIso8601String(),
        'granularity': granularity,
      });

  /// Activité quotidienne réelle {from, to} (EF v77, migration 0067) :
  /// [{day, dau, sessions, content_views, game_views}].
  Future<Map<String, dynamic>> fetchAnalyticsActivity({
    required DateTime from,
    required DateTime to,
  }) =>
      _post('analytics/activity', {
        'from': from.toIso8601String(),
        'to': to.toIso8601String(),
      });

  /// Cohortes hebdomadaires de rétention (EF v77) : weeks borné 4-26
  /// côté serveur ; retourne {weeks, cohorts: [{cohort_start, size, d1, d7,
  /// d30, d1_pct, d7_pct, d30_pct}]}.
  Future<Map<String, dynamic>> fetchAnalyticsRetention({int weeks = 8}) =>
      _post('analytics/retention', {'weeks': weeks});

  /// Attribution d'acquisition {from, to} (EF v78, migration 0069 — chantier
  /// F3, §70.5) : {first_period, first_global, clicks: [{source, campaign,
  /// n}], clicks_total, clicks_truncated}.
  Future<Map<String, dynamic>> fetchAnalyticsAcquisition({
    required DateTime from,
    required DateTime to,
  }) =>
      _post('analytics/acquisition', {
        'from': from.toIso8601String(),
        'to': to.toIso8601String(),
      });

  Future<List<Map<String, dynamic>>> fetchPricing() async {
    final data = await _post('pricing/list', <String, dynamic>{});
    final list = data['pricing'] as List? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> setPricing({
    required String plan,
    required double priceTtc,
    String? currency,
    double? playFeePct,
    bool? active,
  }) =>
      _post('pricing/set', {
        'plan': plan,
        'price_ttc': priceTtc,
        'currency': ?currency,
        'play_fee_pct': ?playFeePct,
        'active': ?active,
      });

  Future<List<Map<String, dynamic>>> fetchTaxes() async {
    final data = await _post('taxes/list', <String, dynamic>{});
    final list = data['taxes'] as List? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  Future<void> setTax({
    required String jurisdiction,
    required double vatRate,
    bool? franchiseBase,
    String? label,
    bool? active,
  }) =>
      _post('taxes/set', {
        'jurisdiction': jurisdiction,
        'vat_rate': vatRate,
        'franchise_base': ?franchiseBase,
        'label': ?label,
        'active': ?active,
      });

  Future<List<Map<String, dynamic>>> fetchExpenses() async {
    final data = await _post('expenses/list', <String, dynamic>{});
    final list = data['expenses'] as List? ?? [];
    return list.cast<Map<String, dynamic>>();
  }

  /// Crée (id null) ou met à jour (id fourni) un frais de société.
  Future<void> upsertExpense(Map<String, dynamic> body) =>
      _post('expenses/upsert', body);

  Future<void> deleteExpense(int id) =>
      _post('expenses/delete', {'id': id});

  /// Coûts mensuels des moteurs de recherche des bots (plan Scruteur V3
  /// Phase 2b — table `usage_monthly`, remontée par Vision.exe au changement
  /// de mois). Réservé owner (comme expenses/*) : 24 derniers mois max.
  Future<List<Map<String, dynamic>>> fetchUsageMonthly() async {
    final data = await _post('usage-monthly/list', <String, dynamic>{});
    final list = data['rows'] as List? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  // ===========================================================================
  // ANNUAIRE DE SITES (routes EF annuaire/* — plan Scruteur V3 §4.4, EF v85)
  // ===========================================================================
  // Répertoire des domaines découverts par le Scruteur (statuts : candidat,
  // actif, ignore, bot_protected). Chargement LAZY STRICT côté store : aucun
  // appel au démarrage ni à l'ouverture du menu — uniquement au clic sur le
  // bouton « 📂 Annuaire » de l'en-tête Scruteur (exigence propriétaire).
  // Les lignes sont retournées BRUTES (snake_case) : id, root_domain, status,
  // trust_tier, tags[], langs[], frequence, search_method,
  // search_url_template, feed_url, feed_type, feed_langs[], sitemap_url,
  // sample_url, jeux_detectes[], source, sentinelle_id, updated_at.

  /// Liste paginée de l'annuaire (route EF `annuaire/list`).
  ///
  /// [page] : index de la page (0-based) ; [pageSize] 50 recommandé (tri
  /// serveur par `frequence` desc). [status] filtre optionnel
  /// ('candidat' | 'actif' | 'ignore' | 'bot_protected').
  ///
  /// Retourne les lignes de la page + le total serveur (pagination). Les
  /// exceptions sont PROPAGÉES (AdminAuthException incluse) : c'est le
  /// StoreController qui gère (logout forcé / reportActionError).
  Future<({List<Map<String, dynamic>> rows, int total})> fetchAnnuaire({
    int page = 0,
    int pageSize = 50,
    String? status,
  }) async {
    final Map<String, dynamic> data = await _post('annuaire/list', {
      'page': page,
      'pageSize': pageSize,
      // Élément null-aware : omis quand status est null (= tous statuts).
      'status': ?status,
    });
    final List<dynamic> rows = data['rows'] as List? ?? [];
    return (
      rows: rows.whereType<Map<String, dynamic>>().toList(),
      total: (data['total'] as num?)?.toInt() ?? rows.length,
    );
  }

  /// Crée ou met à jour une entrée de l'annuaire (route EF
  /// `annuaire/upsert`). Clé métier : `root_domain`. Seuls les champs
  /// présents dans [body] sont modifiés (le serveur conserve la valeur
  /// existante des colonnes absentes) : status, trust_tier, tags[], langs[],
  /// search_method, feed_url, source ('auto' | 'manuel')…
  Future<void> upsertAnnuaire(Map<String, dynamic> body) =>
      _post('annuaire/upsert', body);

  /// Supprime une entrée de l'annuaire (route EF `annuaire/delete`).
  Future<void> deleteAnnuaireEntry(String id) =>
      _post('annuaire/delete', {'id': id});

  /// TOUS les comptes bannis, enrichis (route `profiles/banned-list` sans
  /// pagination, v95) : catégorie, origine, statut, événement du ban, ban
  /// manuel présent, date. Tout admin. `banned` absent ou non liste →
  /// [AdminApiException] (RV-10 : jamais une liste vide supposée — l'appelant
  /// REMPLACE sa liste locale par la réponse) ; éléments sans `id` texte non
  /// vide ignorés.
  Future<List<BannedUser>> fetchBannedList() async {
    final Map<String, dynamic> data = await _post(
      'profiles/banned-list',
      <String, dynamic>{},
    );
    final Object? rows = data['banned'];
    if (rows is! List) throw _unreadable();
    return <BannedUser>[
      for (final Object? r in rows)
        if (r is Map && r['id'] is String && (r['id'] as String).isNotEmpty)
          BannedUser.fromServer(Map<String, dynamic>.from(r)),
    ];
  }

  /// Récupère la liste des mauvais contributeurs depuis Supabase (via Edge
  /// Function `bad-contributors/list`).
  ///
  /// Retourne une liste de maps avec : author_id, display_name,
  /// rejected_count, accepted_count, total_count, rejection_rate, is_premium.
  /// Sert au menu « Comptes à bannir » : détecte les contributeurs dont le
  /// taux de rejet est élevé.
  Future<List<Map<String, dynamic>>> fetchBadContributors() async {
    final data = await _post('bad-contributors/list', <String, dynamic>{});
    final c = data['contributors'] as List? ?? [];
    return c.map((m) {
      final row = m as Map<String, dynamic>;
      return <String, dynamic>{
        'author_id': row['author_id'],
        'display_name': row['display_name'] ?? 'Inconnu',
        'rejected_count': row['rejected_count'] ?? 0,
        'accepted_count': row['accepted_count'] ?? 0,
        'total_count': row['total_count'] ?? 0,
        'rejection_rate': (row['rejection_rate'] as num?)?.toDouble() ?? 0.0,
        'is_premium': row['is_premium'] ?? false,
      };
    }).toList();
  }

  /// Lit le journal `cache_ops` (route EF `cache-ops/list`, migrations
  /// 0051/0052) et retourne les URLs RETIRÉES (`op='remove'`) depuis
  /// [since] — sert à la sync incrémentale des contenus : un retrait serveur
  /// ( suppression de contenu, quel qu'en soit l'outil) doit être répercuté
  /// localement, faute de quoi la ligne supprimée resterait visible dans le
  /// cache du panneau.
  ///
  /// [since] : curseur ISO 8601 sur `cache_ops.created_at` (indépendant des
  /// curseurs `updated_at` de games/contents/suggestions).
  ///
  /// Retourne les URLs retirées (comparaison exacte côté caller) + le max
  /// `created_at` vu (prochain curseur).
  ///
  /// ⚠️ La route v63 ne sélectionne que `url, op, created_at` (pas la colonne
  /// `src`) : on filtre donc sur `op='remove'` seul. Un « remove » portant sur
  /// une URL de suggestion ne matchera aucun contenu local — sans effet.
  Future<({Set<String> removedUrls, DateTime? maxCreatedAt})>
  fetchRemovedContentUrls({String? since}) async {
    final Set<String> urls = <String>{};
    DateTime? maxCreated;
    const int pageSize = 1000; // plafond côté EF
    for (var page = 0; page < 100; page++) {
      final Map<String, dynamic> data = await _post('cache-ops/list', {
        'page': page,
        'pageSize': pageSize,
        'since': ?since,
      });
      final List<dynamic> ops = data['ops'] as List? ?? [];
      for (final o in ops) {
        if (o is! Map) continue;
        final row = o as Map<String, dynamic>;
        if (row['op'] == 'remove') {
          final String? url = row['url']?.toString();
          if (url != null && url.isNotEmpty) urls.add(url);
        }
        final DateTime? t = DateTime.tryParse(
          row['created_at']?.toString() ?? '',
        );
        if (t != null && (maxCreated == null || t.isAfter(maxCreated))) {
          maxCreated = t;
        }
      }
      if (ops.length < pageSize) break; // fin du journal
    }
    return (removedUrls: urls, maxCreatedAt: maxCreated);
  }

  // ===========================================================================
  // JOURNAL D'ACTIVITÉ (route EF `logs/list` — réservée au compte principal)
  // ===========================================================================

  /// Récupère une page du journal d'activité admin (connexions + actions),
  /// triée par date DÉCROISSANTE côté serveur.
  ///
  /// [page] : index de la page (0-based).
  /// [pageSize] : lignes par page (≤ 500 côté serveur — borné ici par sécurité).
  /// [source] : `all` | `auth` (connexions) | `actions`.
  ///
  /// Retourne les entrées de la page + le total serveur (pour la pagination).
  /// Lève [AdminForbiddenException] (403) si le compte n'est pas le compte
  /// principal, [AdminAuthException] (401) si la session a expiré.
  Future<({List<LogEntry> items, int total})> fetchLogs({
    int page = 0,
    int pageSize = 100,
    String source = 'all',
  }) async {
    final Map<String, dynamic> data = await _post('logs/list', {
      'page': page,
      'pageSize': pageSize.clamp(1, 500),
      'source': source,
    });
    final List<dynamic> rows = data['logs'] as List? ?? [];
    return (
      items: rows
          .whereType<Map<String, dynamic>>()
          .map(LogEntry.fromJson)
          .toList(),
      total: (data['total'] as num?)?.toInt() ?? rows.length,
    );
  }

  // ===========================================================================
  // ARCHIVES MENSUELLES DU JOURNAL (routes EF logs/archives/* — owner-only)
  // ===========================================================================
  // En fin de mois, le serveur déplace les logs du mois écoulé dans une table
  // d'archive. Ces routes (réservées au compte principal, comme logs/list)
  // permettent de lister, télécharger et supprimer ces archives.

  /// Liste les archives mensuelles du journal d'activité.
  ///
  /// Retourne une liste de maps brutes : `table_name`, `period_label`,
  /// `rows_count`, `created_at`. Lève [AdminForbiddenException] (403) si le
  /// compte n'est pas owner, [AdminAuthException] (401) si session expirée.
  Future<List<Map<String, dynamic>>> fetchLogArchives() async {
    final Map<String, dynamic> data = await _post(
      'logs/archives/list',
      <String, dynamic>{},
    );
    final List<dynamic> rows = data['archives'] as List? ?? [];
    return rows.whereType<Map<String, dynamic>>().toList();
  }

  /// Télécharge le contenu COMPLET d'une archive (toutes ses lignes,
  /// sous forme de [LogEntry] — même shape que `logs/list`).
  Future<List<LogEntry>> downloadLogArchive(String table) async {
    final Map<String, dynamic> data = await _post('logs/archive/download', {
      'table': table,
    });
    final List<dynamic> rows = data['logs'] as List? ?? [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(LogEntry.fromJson)
        .toList();
  }

  /// Supprime DÉFINITIVEMENT une archive (action IRRÉVERSIBLE côté serveur).
  /// L'UI doit exiger une confirmation explicite avant cet appel.
  Future<void> deleteLogArchive(String table) async {
    await _post('logs/archive/delete', {'table': table});
  }

  // ===========================================================================
  // COMPTES ADMIN (routes EF admin-users/* — owner-only)
  // ===========================================================================

  /// Liste les comptes administrateurs — **réservé au compte principal
  /// (owner)**. Ne contient JAMAIS de hash de mot de passe (le serveur ne
  /// l'envoie pas). Lève [AdminForbiddenException] (403) si le compte n'est
  /// pas owner, [AdminAuthException] (401) si la session a expiré.
  Future<List<AdminUserAccount>> fetchAdminUsers() async {
    final Map<String, dynamic> data = await _post(
      'admin-users/list',
      <String, dynamic>{},
    );
    final List<dynamic> rows = data['users'] as List? ?? [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(AdminUserAccount.fromJson)
        .toList();
  }

  /// Active ou désactive un compte administrateur (révocation immédiate :
  /// le serveur re-vérifie `active=true` à chaque appel). Le serveur refuse
  /// l'auto-désactivation du compte courant et la désactivation du dernier
  /// compte principal actif (erreur 400 avec message explicite).
  Future<void> setAdminUserActive(String username, bool active) async {
    await _post('admin-users/set-active', {
      'username': username,
      'active': active,
    });
  }

  // ===========================================================================
  // CHAÎNES YOUTUBE DE CONFIANCE (routes EF trusted-channels/*)
  // ===========================================================================

  /// Une page du tableau « Chaînes YT » (route EF `trusted-channels/list`
  /// en mode page — migration 0088) : les chaînes des [gamesPerPage] jeux
  /// (5 par défaut, 50 max) de la page [page], recherche [search] appliquée
  /// en SQL (handle, nom de chaîne ou nom du jeu « contient »), totaux
  /// exacts de jeux et de chaînes.
  /// Les exceptions sont PROPAGÉES (AdminAuthException incluse).
  Future<TrustedChannelsPage> fetchTrustedChannelsPage({
    String search = '',
    int page = 0,
    int gamesPerPage = kTrustedGamesPerPage,
  }) async {
    final Map<String, dynamic> data = await _post(
      'trusted-channels/list',
      trustedPageRequestBody(
        search: search,
        page: page,
        gamesPerPage: gamesPerPage,
      ),
    );
    return parseTrustedChannelsPage(
      data,
      search: search,
      page: page,
      gamesPerPage: gamesPerPage,
    );
  }

  /// Jeux (identifiants) déjà liés au handle [handle], casse ignorée, sur
  /// toute la table (route EF `trusted-channels/handle-games`, migration
  /// 0088) : lus à l'ouverture du dialog « Ajouter un jeu », hors des pages
  /// de la liste (une chaîne peut être liée à plus de 100 jeux).
  /// Les exceptions sont PROPAGÉES (AdminAuthException incluse).
  Future<List<String>> fetchTrustedChannelGameIds(String handle) async {
    final Map<String, dynamic> data = await _post(
      'trusted-channels/handle-games',
      <String, dynamic>{'handle': handle.trim()},
    );
    final Object? ids = data['game_ids'];
    return ids is List
        ? ids.whereType<String>().where((id) => id.isNotEmpty).toList()
        : const <String>[];
  }

  /// Liste toutes les chaînes YouTube de confiance (tous jeux confondus),
  /// avec le nom du jeu dénormalisé (`game_name`) par le serveur.
  Future<List<TrustedChannel>> fetchTrustedChannels() async {
    final Map<String, dynamic> data = await _post(
      'trusted-channels/list',
      <String, dynamic>{},
    );
    final List<dynamic> rows = data['channels'] as List? ?? [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(TrustedChannel.fromJson)
        .toList();
  }

  /// Crée ou met à jour une chaîne de confiance. Sans [id], le serveur crée
  /// une nouvelle ligne (c'est ainsi qu'une même chaîne est liée à un autre
  /// jeu) ; avec [id], la ligne existante est mise à jour.
  ///
  /// Retourne la ligne serveur à jour ([TrustedChannel]).
  Future<TrustedChannel> upsertTrustedChannel({
    String? id,
    required String gameId,
    required String channelHandle,
    String? channelName,
    String? channelId,
    List<String>? langs,
    bool? active,
    String? source,
  }) async {
    final Map<String, dynamic> data = await _post('trusted-channels/upsert', {
      // Valeurs null-aware : l'entrée est omise quand la valeur est null
      // (le serveur conserve alors la valeur existante de la colonne).
      'id': ?id,
      'game_id': gameId,
      'channel_handle': channelHandle,
      'channel_name': ?channelName,
      'channel_id': ?channelId,
      'langs': ?langs,
      'active': ?active,
      'source': ?source,
    });
    return TrustedChannel.fromJson(data['channel'] as Map<String, dynamic>);
  }

  /// Supprime une chaîne de confiance (la ligne seule : la chaîne YouTube
  /// et le jeu ne sont pas touchés).
  Future<void> deleteTrustedChannel(String id) async {
    await _post('trusted-channels/delete', {'id': id});
  }

  // ===========================================================================
  // CHAÎNES YOUTUBE BANNIES (routes EF channels/* — chantier B, migration
  // 0064, contrat §70.3)
  // ===========================================================================

  /// Liste paginée des chaînes bannies (route EF `channels/banned-list`).
  ///
  /// [page] : index de la page (0-based) ; [pageSize] borné à 100 côté
  /// serveur. Retourne les entrées de la page + le total serveur.
  Future<({List<BannedChannel> items, int total})> fetchBannedChannels({
    int page = 0,
    int pageSize = 20,
  }) async {
    final Map<String, dynamic> data = await _post('channels/banned-list', {
      'page': page,
      'pageSize': pageSize.clamp(1, 100),
    });
    final List<dynamic> rows = data['channels'] as List? ?? [];
    return (
      items: rows
          .whereType<Map<String, dynamic>>()
          .map(BannedChannel.fromJson)
          .toList(),
      total: (data['total'] as num?)?.toInt() ?? rows.length,
    );
  }

  /// Bannit une chaîne YouTube (route EF `channels/ban`) : [handleOrUrl]
  /// accepte un handle nu (avec ou sans '@') ou une URL de chaîne
  /// (…/@xxx, …/channel/UC…, …/c/…) — la normalisation est faite côté
  /// serveur. La file pending de la chaîne est purgée automatiquement
  /// (motif « Chaîne bannie ») ; le rapport liste les contenus déjà
  /// publiés (retrait manuel via [unpublishByChannel]).
  ///
  /// v95 : [category] facultative (absente = défaut serveur `moderation`) ;
  /// [BanChannelReport.result] = `applied` | `updated` | `auto_en_revue`
  /// (chaîne déjà bannie automatiquement et en revue : rien purgé).
  Future<BanChannelReport> banChannel({
    required String handleOrUrl,
    required String reason,
    String? displayName,
    String? category,
  }) async {
    final Map<String, dynamic> data = await _post('channels/ban', {
      'handle': handleOrUrl,
      'reason': reason,
      if (displayName != null && displayName.trim().isNotEmpty)
        'display_name': displayName.trim(),
      'category': ?category,
    });
    return BanChannelReport.fromJson(data);
  }

  /// Lève un bannissement MANUEL (route EF `channels/unban`) — [id] =
  /// bigserial de la ligne `banned_channels`. Rend `lifted` | `not_found`
  /// (déjà levée) ; `lifted` si l'EF (antérieure) ne renvoie pas `result` ;
  /// `replayed` = réponse obtenue après un rejeu (revue P4b-3, INF-01).
  /// Une entrée AUTOMATIQUE arrive en [AdminApiException] 409
  /// `auto_ban_use_review` avec [AdminApiException.banEventId].
  Future<({String result, bool replayed})> unbanChannel(int id) async {
    final PostResult r = await _postWithMeta('channels/unban', {'id': id});
    final Object? result = r.data['result'];
    return (
      result: result is String && result.isNotEmpty ? result : 'lifted',
      replayed: r.attempts > 1,
    );
  }

  /// Retire les contenus DÉJÀ publiés d'une chaîne (route EF
  /// `contents/unpublish-by-channel`) — appelé UNIQUEMENT au clic manuel
  /// du rapport de bannissement (jamais automatique, contrat §70.3).
  /// Retourne le nombre de contenus supprimés, leur liste {id,title,url}
  /// (renvoyés par le serveur) et `replayed` (réponse obtenue après un
  /// rejeu : un bilan nul peut alors masquer une suppression faite au
  /// premier essai).
  Future<({int deleted, List<Map<String, dynamic>> removed, bool replayed})>
  unpublishByChannel(String handle) async {
    final PostResult r = await _postWithMeta('contents/unpublish-by-channel', {
      'handle': handle,
    });
    final Object? deleted = r.data['deleted'];
    final Object? removed = r.data['removed'];
    return (
      deleted: deleted is num ? deleted.toInt() : 0,
      removed: removed is List
          ? removed.whereType<Map<String, dynamic>>().toList()
          : const <Map<String, dynamic>>[],
      replayed: r.attempts > 1,
    );
  }

  /// Aperçu (`apply: false`) ou application (`apply: true`) de la purge d'une
  /// chaîne bannie AUTOMATIQUEMENT et confirmée (route `channels/purge-auto`,
  /// compte principal) : corps strict `{id, dry_run}` — `dry_run` TOUJOURS
  /// explicite. [id] = `banned_channels.id`.
  ///
  /// Erreurs `{error}` SANS `result` (distinguer par statut, afficher
  /// [AdminApiException.message]) : 403, 404 « Chaîne bannie introuvable. »,
  /// 409 « Purge réservée aux chaînes bannies automatiquement. » ou
  /// « Confirmez d'abord le bannissement (file de revue). ».
  Future<PurgeAutoResult> purgeAutoChannel({
    required int id,
    required bool apply,
  }) async {
    final PostResult r = await _postWithMeta('channels/purge-auto', {
      'id': id,
      'dry_run': !apply,
    });
    return PurgeAutoResult.fromJson(r.data, replayed: r.attempts > 1);
  }

  /// Ligne `banned_channels` dont `ban_event_id == banEventId`, cherchée dans
  /// `channels/banned-list` (pages de 100, tri le plus récent d'abord) sur
  /// au plus [maxPages] pages ; `null` si absente. Sert de repli quand
  /// `channel_row_id` manque (base sans 0096) et après l'`apply` d'une tête
  /// de chaîne (ligne créée à l'instant → page 0).
  Future<BannedChannel?> findBannedChannelByEventId(
    int banEventId, {
    int maxPages = 5,
  }) async {
    const int pageSize = 100;
    for (var p = 0; p < maxPages; p++) {
      final ({List<BannedChannel> items, int total}) res =
          await fetchBannedChannels(page: p, pageSize: pageSize);
      for (final BannedChannel c in res.items) {
        if (c.banEventId == banEventId) return c;
      }
      if (res.items.isEmpty || (p + 1) * pageSize >= res.total) break;
    }
    return null;
  }

  // ===========================================================================
  // ALIAS DE NOMS DE JEUX (routes EF games/aliases/*)
  // ===========================================================================

  /// Liste les alias d'un jeu (noms raccourcis, acronymes, noms
  /// communautaires) utilisés par Vision/Sentinelle pour le matching des
  /// titres YouTube.
  Future<List<GameAlias>> fetchGameAliases(String gameId) async {
    final Map<String, dynamic> data = await _post('games/aliases/list', {
      'game_id': gameId,
    });
    final List<dynamic> rows = data['aliases'] as List? ?? [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(GameAlias.fromJson)
        .toList();
  }

  /// TOUS les alias de TOUS les jeux (route EF `games/aliases/list-all`,
  /// v72), avec le nom du jeu — sert au bouton « Synchroniser les alias
  /// connus » (diff base ↔ alias en dur du panneau) : une seule requête
  /// au lieu d'une par jeu.
  Future<List<AliasAllEntry>> fetchGameAliasesAll() async {
    final Map<String, dynamic> data =
        await _post('games/aliases/list-all', {});
    final List<dynamic> rows = data['aliases'] as List? ?? [];
    return [
      for (final r in rows.whereType<Map<String, dynamic>>())
        AliasAllEntry(
          gameId: r['game_id'] as String,
          gameName: r['game_name'] as String?,
          alias: GameAlias.fromJson(r),
        ),
    ];
  }

  /// Remplace TOUTE la liste des alias d'un jeu (les alias absents de
  /// [aliases] sont supprimés côté serveur). Chaque entrée est un map
  /// `{alias: <saisi>, alias_norm: <forme normalisée>}` — la normalisation
  /// est calculée côté panneau (StoreController.normalizeGameAlias) pour
  /// rester identique au matching des bots. §137 : listes construites par
  /// lib/domain/game_alias_payload.dart (forme clé d'alias Unicode, jamais
  /// de clé sans lettre — refusée aussi par l'EF).
  ///
  /// Retourne le nombre d'alias enregistrés (`count` du serveur).
  Future<int> setGameAliases(
    String gameId,
    List<Map<String, String>> aliases,
  ) async {
    final Map<String, dynamic> data = await _post('games/aliases/set', {
      'game_id': gameId,
      'aliases': aliases,
    });
    return (data['count'] as num?)?.toInt() ?? aliases.length;
  }

  // ===========================================================================
  // SYNC TOTALE BDD → LOCAL (routes EF sync/*, migration 0063 — chantier C)
  // ===========================================================================

  /// Pose (ou ré-horodate) LA demande de sync totale « chaude » (route EF
  /// `sync/request`) — sémantique anti-pile-up côté serveur : une demande de
  /// moins de 24 h est ré-horodatée, sinon nouvelle ligne. Retourne la
  /// demande résultante.
  Future<SyncRequestInfo> requestTotalSync() async {
    final Map<String, dynamic> data = await _post('sync/request', {});
    return SyncRequestInfo.fromJson(
      (data['request'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  /// Lit la dernière demande de sync et TOUS ses acquittements par machine
  /// (route EF `sync/status`) — alimente le badge d'attente de la topbar et
  /// le polling 60 s (actif uniquement tant qu'une demande reste sans ack).
  Future<SyncStatusResult> fetchSyncStatus() async {
    final Map<String, dynamic> data = await _post('sync/status', {});
    final rawRequest = data['request'];
    final List<dynamic> rawAcks = data['acks'] as List? ?? const [];
    return SyncStatusResult(
      request: rawRequest is Map<String, dynamic>
          ? SyncRequestInfo.fromJson(rawRequest)
          : null,
      acks: [
        for (final a in rawAcks.whereType<Map<String, dynamic>>())
          SyncAckInfo.fromJson(a),
      ],
    );
  }

  // ===========================================================================
  // MODÉRATION (routes EF moderation/* — migration 0094, P4b-3)
  // ===========================================================================
  // Corps JSON EXACTS : les routes strictes (review-detail, review-decide,
  // events-list, settings-set, evidence-purge) refusent toute clé inconnue
  // et settings-set refuse une clé PRÉSENTE à null → éléments null-aware
  // (`'k': ?v`) pour omettre une clé nulle. `pageSize` en camelCase, le
  // reste en snake_case. Les messages d'erreur affichés sont ceux du serveur
  // ([AdminApiException.message]) ; seuls les 409 de review-decide portent
  // `result`.

  /// Catégories de bannissement (route `moderation/categories`, tout admin),
  /// dans l'ordre serveur ; liste vide si `categories` est absente ou
  /// illisible (l'appelant se replie sur `kManualBanCategoriesFallback`).
  Future<List<BanCategory>> fetchBanCategories() async {
    final Map<String, dynamic> data = await _post(
      'moderation/categories',
      <String, dynamic>{},
    );
    final Object? rows = data['categories'];
    if (rows is! List) return const <BanCategory>[];
    return rows
        .map(BanCategory.fromJson)
        .whereType<BanCategory>()
        .toList(growable: false);
  }

  /// Une page de la file de revue (route `moderation/review-list`, compte
  /// principal) : corps `{page, pageSize}` (pageSize borné 1-100). 403 hors
  /// compte principal. `items` absent → réponse illisible (jamais une file
  /// vide supposée).
  Future<ReviewQueuePage> fetchReviewList({
    int page = 0,
    int pageSize = 50,
  }) async {
    final Map<String, dynamic> data = await _post('moderation/review-list', {
      'page': page,
      'pageSize': pageSize.clamp(1, 100),
    });
    if (data['items'] is! List) throw _unreadable();
    return ReviewQueuePage.fromJson(data);
  }

  /// Détail d'un événement et sa preuve (route `moderation/review-detail`,
  /// compte principal) : corps `{event_id}`. 404 « Événement introuvable. ».
  Future<ReviewDetail> fetchReviewDetail(int eventId) async {
    final Map<String, dynamic> data = await _post('moderation/review-detail', {
      'event_id': eventId,
    });
    return ReviewDetail.fromJson(data) ?? (throw _unreadable());
  }

  /// Décision de revue (route `moderation/review-decide`, compte principal) :
  /// corps `{event_id, decision, reason?}` — [reason] = motif DÉJÀ normalisé
  /// (lot L3, `normalizeReviewReason`), omis s'il est nul (obligatoire pour
  /// `lift`). 200 : les 7 clés + [ReviewDecideResult.replayed] ; 409 avec
  /// `result` (`not_applicable`, `ban_not_active`, `below_threshold` +
  /// `distinct_contents` / `threshold`).
  Future<ReviewDecideResult> reviewDecide(
    int eventId,
    ReviewDecision decision, {
    String? reason,
  }) async {
    final PostResult r = await _postWithMeta('moderation/review-decide', {
      'event_id': eventId,
      'decision': decision.code,
      'reason': ?reason,
    });
    return ReviewDecideResult.fromJson(r.data, replayed: r.attempts > 1);
  }

  /// Journal des événements (route `moderation/events-list`, compte
  /// principal) : corps `{page, pageSize, target_kind?, target_key?,
  /// action?}` (pageSize borné 1-100). [targetKey] rogné ; vide après rognage
  /// → clé ABSENTE (l'EF accepterait `''` et filtrerait `target_key = ''`).
  /// `items` absent → réponse illisible.
  Future<EventsPage> fetchEvents({
    int page = 0,
    int pageSize = 50,
    String? targetKind,
    String? targetKey,
    String? action,
  }) async {
    final String? trimmed = targetKey?.trim();
    final String? key = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    final Map<String, dynamic> data = await _post('moderation/events-list', {
      'page': page,
      'pageSize': pageSize.clamp(1, 100),
      'target_kind': ?targetKind,
      'target_key': ?key,
      'action': ?action,
    });
    if (data['items'] is! List) throw _unreadable();
    return EventsPage.fromJson(data);
  }

  /// Réglages de la modération automatique (route `moderation/settings-get`,
  /// compte principal). `settings` illisible → [AdminApiException]
  /// « Réponse illisible du serveur. ».
  Future<ModerationSettings> fetchModerationSettings() async {
    final Map<String, dynamic> data = await _post(
      'moderation/settings-get',
      <String, dynamic>{},
    );
    return ModerationSettings.fromJson(data['settings']) ??
        (throw _unreadable());
  }

  /// Modifie les réglages (route `moderation/settings-set`, compte
  /// principal) : SEULES les clés non nulles sont envoyées (au moins une) ;
  /// [allowedRulesSha256] REMPLACE toute la liste (`[]` = plus aucune
  /// empreinte autorisée). Rend les réglages relus ; `settings: null` →
  /// réponse illisible. 400 du parseur `{error}` SANS `reasons` (« Rien à
  /// modifier. », bornes…).
  Future<ModerationSettings> updateModerationSettings({
    bool? autoBanEnabled,
    int? maxPerHour,
    int? maxPerDay,
    List<String>? allowedRulesSha256,
  }) async {
    assert(
      autoBanEnabled != null ||
          maxPerHour != null ||
          maxPerDay != null ||
          allowedRulesSha256 != null,
      'updateModerationSettings : au moins un réglage à modifier',
    );
    final Map<String, dynamic> data = await _post('moderation/settings-set', {
      'auto_ban_enabled': ?autoBanEnabled,
      'max_auto_bans_per_hour': ?maxPerHour,
      'max_auto_bans_per_day': ?maxPerDay,
      'allowed_rules_sha256': ?allowedRulesSha256,
    });
    return ModerationSettings.fromJson(data['settings']) ??
        (throw _unreadable());
  }

  /// Aperçu (`apply: false`) ou purge (`apply: true`) des preuves de plus de
  /// [olderThanDays] jours (route `moderation/evidence-purge`, compte
  /// principal) : corps `{older_than_days, dry_run}` — `dry_run` TOUJOURS
  /// explicite (absent = aperçu côté serveur). 400 « older_than_days : 30 à
  /// 3650. ».
  Future<EvidencePurgeResult> purgeEvidence({
    required int olderThanDays,
    required bool apply,
  }) async {
    final PostResult r = await _postWithMeta('moderation/evidence-purge', {
      'older_than_days': olderThanDays,
      'dry_run': !apply,
    });
    return EvidencePurgeResult.fromJson(r.data, replayed: r.attempts > 1);
  }

  /// Pages web bloquées (route `moderation/blocked-pages/list`, tout admin) :
  /// corps `{page, pageSize}` (pageSize borné 1-500). `pages` absent →
  /// réponse illisible.
  Future<BlockedPagesPage> fetchBlockedPages({
    int page = 0,
    int pageSize = 100,
  }) async {
    final Map<String, dynamic> data = await _post(
      'moderation/blocked-pages/list',
      {'page': page, 'pageSize': pageSize.clamp(1, 500)},
    );
    if (data['pages'] is! List) throw _unreadable();
    return BlockedPagesPage.fromJson(data);
  }
}
