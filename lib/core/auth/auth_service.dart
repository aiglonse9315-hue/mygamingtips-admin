import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:http/http.dart' as http;

/// Service d'authentification du panneau admin.
///
/// ⚠️ AUCUN identifiant n'est stocké côté client. Les credentials sont
/// **vérifiés côté serveur** (Edge Function Supabase ou endpoint sécurisé).
/// Le front-end ne fait qu'envoyer login + mot de passe vers le backend, qui
/// renvoie (ou non) un jeton de session.
///
/// Bonnes pratiques intégrées côté client :
/// - **Limitation des tentatives** : blocage temporaire après N échecs
///   (protection contre le brute-force, complémentaire du rate-limiting serveur).
/// - **Journalisation locale** des tentatives (horodatage, succès/échec),
///   consultable depuis la console navigateur pour audit.
/// - **Stockage du jeton** : jamais les credentials, uniquement le jeton de
///   session (court terme, à valider côté serveur à chaque requête sensible).
///
/// **Mode aperçu local (démo)** : activé UNIQUEMENT via le flag de compilation
/// `--dart-define=MGT_ADMIN_PREVIEW=true`. En production (sans ce flag), aucune
/// connexion n'est possible sans backend réel. Ce mode n'embarque AUCUN
/// identifiant : il délivre un jeton factice pour permettre de naviguer dans
/// l'interface avec les données de démonstration, le temps de déployer
/// l'Edge Function d'authentification (cf. GUIDE_DEPLOIEMENT.md §1.7bis).
class AuthService {
  AuthService({String? endpoint})
      : endpoint = endpoint ?? _configuredEndpoint();

  /// Mode aperçu local (démo) : activé au build via dart-define.
  /// En production ce flag vaut `false` → auth strict serveur obligatoire.
  static const bool previewMode =
      bool.fromEnvironment('MGT_ADMIN_PREVIEW', defaultValue: false);

  /// Clé anon publique Supabase — requise par la passerelle Supabase sur
  /// TOUS les appels d'Edge Function (header Authorization). Publique par
  /// conception (RLS protège les données). Fournie via dart-define au build.
  static const String anonKey =
      String.fromEnvironment('MGT_SUPABASE_ANON_KEY', defaultValue: '');

  /// URL du backend de vérification des identifiants admin.
  /// Doit être configurée côté serveur (Edge Function / API) — jamais codée
  /// en dur avec des credentials.
  final String endpoint;

  static const String _kToken = 'mgt_admin_token';
  static const int _maxAttempts = 5;
  static const Duration _lockoutDuration = Duration(minutes: 2);

  String? _token;
  String? get token => _token;
  bool get isAuthenticated => _token != null;

  // --- Limitation des tentatives ---
  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  /// Liste des événements d'authentification (journal local d'audit).
  final List<AuthLogEntry> _log = <AuthLogEntry>[];
  List<AuthLogEntry> get log => List<AuthLogEntry>.unmodifiable(_log);

  /// Restaure la session éventuelle (jeton) au démarrage.
  void restore() {
    _token = html.window.localStorage[_kToken];
  }

  /// Tente de connecter. Renvoie le résultat (succès + message éventuel).
  ///
  /// [username] / [password] sont transmis au backend ; aucune comparaison
  /// locale n'est effectuée.
  Future<AuthResult> login({
    required String username,
    required String password,
  }) async {
    // 0) Mode aperçu local (démo) : activé UNIQUEMENT au build via dart-define.
    //    Aucun identifiant n'est vérifié ni stocké — on délivre un jeton
    //    factice pour permettre de naviguer dans l'interface. En production,
    //    ce bloc est désactivé (previewMode = false) → auth serveur stricte.
    if (previewMode) {
      _token = 'preview-token-${DateTime.now().millisecondsSinceEpoch}';
      html.window.localStorage[_kToken] = _token!;
      _log.add(AuthLogEntry(
          at: DateTime.now(),
          success: true,
          detail: 'connexion en mode aperçu local (démo)'));
      return const AuthResult(success: true);
    }

    // 1) Blocage temporaire si trop d'échecs récents.
    if (_lockedUntil != null && DateTime.now().isBefore(_lockedUntil!)) {
      final remaining = _lockedUntil!.difference(DateTime.now());
      _log.add(AuthLogEntry(
        at: DateTime.now(),
        success: false,
        detail: 'refusé (compte bloqué, ${remaining.inSeconds}s restantes)',
      ));
      return AuthResult(
        success: false,
        message: 'Trop de tentatives. Réessayez dans '
            '${remaining.inSeconds} secondes.',
      );
    }

    try {
      // 2) Appel au backend de vérification.
      // Le header Authorization (anon key) est requis par la passerelle
      // Supabase sur tous les appels d'Edge Function, même publiques.
      final Map<String, String> headers = {
        'Content-Type': 'application/json',
        if (anonKey.isNotEmpty) 'Authorization': 'Bearer $anonKey',
      };
      final response = await http.post(
        Uri.parse(endpoint),
        headers: headers,
        body: jsonEncode({'username': username, 'password': password}),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final token = body['token'] as String?;
        if (token != null && token.isNotEmpty) {
          _token = token;
          html.window.localStorage[_kToken] = token;
          _failedAttempts = 0;
          _lockedUntil = null;
          _log.add(AuthLogEntry(
              at: DateTime.now(), success: true, detail: 'connexion réussie'));
          return const AuthResult(success: true);
        }
      }

      // 3) Échec : incrémenter le compteur (brute-force protection).
      _failedAttempts += 1;
      if (_failedAttempts >= _maxAttempts) {
        _lockedUntil = DateTime.now().add(_lockoutDuration);
        _log.add(AuthLogEntry(
            at: DateTime.now(),
            success: false,
            detail: 'blocage déclenché ($_failedAttempts échecs)'));
      }
      _log.add(AuthLogEntry(
          at: DateTime.now(), success: false, detail: 'identifiants invalides'));
      return AuthResult(
          success: false,
          message: _failedAttempts >= _maxAttempts
              ? 'Trop de tentatives. Compte bloqué temporairement.'
              : 'Identifiants incorrects.');
    } on TimeoutException {
      _log.add(AuthLogEntry(
          at: DateTime.now(), success: false, detail: 'timeout backend'));
      return const AuthResult(
          success: false, message: 'Le serveur ne répond pas. Réessayez.');
    } catch (e) {
      _log.add(AuthLogEntry(
          at: DateTime.now(), success: false, detail: 'erreur: $e'));
      return const AuthResult(
          success: false,
          message: 'Configuration serveur requise pour l\'authentification.');
    }
  }

  void logout() {
    _token = null;
    html.window.localStorage.remove(_kToken);
    _failedAttempts = 0;
    _lockedUntil = null;
  }

  /// Récupère l'endpoint depuis les variables de build/Dart-define.
  /// Lance une erreur explicite si non configuré (aucune valeur par défaut
  /// contenant des credentials).
  static String _configuredEndpoint() {
    const endpoint =
        String.fromEnvironment('MGT_ADMIN_AUTH_ENDPOINT', defaultValue: '');
    if (endpoint.isEmpty) {
      throw StateError(
        'L\'endpoint d\'authentification admin n\'est pas configuré. '
        'Définissez MGT_ADMIN_AUTH_ENDPOINT (cf. GUIDE_DEPLOIEMENT.md). '
        'Les identifiants admin sont vérifiés côté serveur uniquement.',
      );
    }
    return endpoint;
  }
}

/// Résultat d'une tentative de connexion.
class AuthResult {
  final bool success;
  final String? message;
  const AuthResult({required this.success, this.message});
}

/// Entrée du journal d'audit (authentification).
class AuthLogEntry {
  final DateTime at;
  final bool success;
  final String detail;
  const AuthLogEntry({
    required this.at,
    required this.success,
    required this.detail,
  });

  @override
  String toString() =>
      '[${at.toIso8601String()}] ${success ? "OK" : "ÉCHEC"} — $detail';
}
