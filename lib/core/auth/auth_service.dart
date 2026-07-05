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
/// - **Vérification d'expiration JWT côté client** : le jeton est décodé au
///   restore et son `exp` est contrôlé. Un timer auto-logout déconnecte dès
///   que le jeton expire (même sans activité).
///
/// **Mode aperçu local (démo)** : activé UNIQUEMENT via le flag de compilation
/// `--dart-define=MGT_ADMIN_PREVIEW=true`. En production (sans ce flag), aucune
/// connexion n'est possible sans backend réel. Ce mode n'embarque AUCUN
/// identifiant : il délivre un jeton factice pour permettre de naviguer dans
/// l'interface avec les données de démonstration, le temps de déployer
/// l'Edge Function d'authentification (cf. GUIDE_DEPLOIEMENT.md §1.7bis).
class AuthService {
  AuthService({String? endpoint})
      : endpoint = endpoint ?? _configuredEndpoint() {
    // Restaure le verrou de sécurité au démarrage (persistant en localStorage).
    final lockRaw = html.window.localStorage[_kLockUntil];
    if (lockRaw != null) {
      final lockTime = DateTime.tryParse(lockRaw);
      if (lockTime != null && DateTime.now().isBefore(lockTime)) {
        _lockedUntil = lockTime;
      } else {
        // Verrou expiré → on nettoie.
        html.window.localStorage.remove(_kLockUntil);
        html.window.localStorage.remove(_kFailCount);
      }
    }
    final failRaw = html.window.localStorage[_kFailCount];
    if (failRaw != null) {
      _failedAttempts = int.tryParse(failRaw) ?? 0;
    }
  }

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
  static const String _kLockUntil = 'mgt_admin_lock_until';
  static const String _kFailCount = 'mgt_admin_fail_count';
  static const int _maxAttempts = 3;
  static const Duration _lockoutDuration = Duration(minutes: 5);

  String? _token;
  String? get token => _token;

  /// Timer d'auto-logout : déconnecte automatiquement quand le JWT expire.
  Timer? _expiryTimer;

  /// Vrai uniquement si un jeton est présent ET non expiré.
  bool get isAuthenticated {
    if (_token == null) return false;
    // En mode aperçu, le jeton factice n'a pas de structure JWT → on accepte.
    if (previewMode) return true;
    return !_isTokenExpired(_token!);
  }

  // --- Limitation des tentatives ---
  int _failedAttempts = 0;
  DateTime? _lockedUntil;

  /// Liste des événements d'authentification (journal local d'audit).
  final List<AuthLogEntry> _log = <AuthLogEntry>[];
  List<AuthLogEntry> get log => List<AuthLogEntry>.unmodifiable(_log);

  /// Callback invoqué quand le jeton expire (pour forcer le logout côté UI).
  void Function()? onTokenExpired;

  /// Restaure la session éventuelle (jeton) au démarrage.
  ///
  /// ⚠️ Vérifie l'expiration du JWT : un jeton expiré est immédiatement
  /// purgé du localStorage (l'utilisateur devra se reconnecter).
  void restore() {
    final stored = html.window.localStorage[_kToken];
    if (stored == null || stored.isEmpty) {
      _token = null;
      return;
    }
    // Si le compte est actuellement bloqué (trop d'échecs), on purge le token.
    if (_lockedUntil != null && DateTime.now().isBefore(_lockedUntil!)) {
      html.window.localStorage.remove(_kToken);
      _token = null;
      return;
    }
    // En mode aperçu, le jeton factice n'est pas un JWT → on accepte tel quel.
    if (previewMode) {
      _token = stored;
      return;
    }
    // Vérifie l'expiration : si expiré, on purge (pas de session fantôme).
    if (_isTokenExpired(stored)) {
      html.window.localStorage.remove(_kToken);
      _token = null;
      return;
    }
    _token = stored;
    _scheduleAutoLogout(stored);
  }

  /// Temps restant de blocage (null si non bloqué).
  Duration? get lockRemaining {
    if (_lockedUntil == null) return null;
    final remaining = _lockedUntil!.difference(DateTime.now());
    return remaining.isNegative ? null : remaining;
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
          // Réinitialise le compteur d'échecs après succès.
          _failedAttempts = 0;
          _lockedUntil = null;
          html.window.localStorage.remove(_kLockUntil);
          html.window.localStorage.remove(_kFailCount);
          _log.add(AuthLogEntry(
              at: DateTime.now(), success: true, detail: 'connexion réussie'));
          _scheduleAutoLogout(token);
          return const AuthResult(success: true);
        }
      }

      // 3) Échec : incrémenter le compteur (brute-force protection).
      _failedAttempts += 1;
      html.window.localStorage[_kFailCount] = _failedAttempts.toString();
      if (_failedAttempts >= _maxAttempts) {
        _lockedUntil = DateTime.now().add(_lockoutDuration);
        // Persiste le verrou pour qu'il survive aux rafraîchissements.
        html.window.localStorage[_kLockUntil] =
            _lockedUntil!.toIso8601String();
        _log.add(AuthLogEntry(
            at: DateTime.now(),
            success: false,
            detail: 'blocage déclenché ($_failedAttempts échecs)'));
      }
      _log.add(AuthLogEntry(
          at: DateTime.now(), success: false, detail: 'identifiants invalides'));

      // Message adaptatif avec compte à rebours.
      final remaining = _lockedUntil?.difference(DateTime.now());
      return AuthResult(
          success: false,
          message: _failedAttempts >= _maxAttempts
              ? (remaining != null && remaining.inMinutes > 0
                  ? 'Trop de tentatives. Compte bloqué pendant ${remaining.inMinutes} min ${remaining.inSeconds % 60} s.'
                  : 'Trop de tentatives. Compte bloqué pendant ${remaining?.inSeconds ?? 300} secondes.')
              : 'Identifiants incorrects. (${_maxAttempts - _failedAttempts} tentative(s) restante(s))');
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
    _expiryTimer?.cancel();
    _expiryTimer = null;
    html.window.localStorage.remove(_kToken);
    _failedAttempts = 0;
    _lockedUntil = null;
  }

  /// Remplace le token courant par un nouveau token frais (sliding session).
  ///
  /// Appelé automatiquement après chaque écriture réussie : l'Edge Function
  /// renvoie un `fresh_token` qui prolonge la session de 15 min. Le timer
  /// d'auto-logout est reprogrammé en conséquence.
  void refreshToken(String freshToken) {
    _token = freshToken;
    html.window.localStorage[_kToken] = freshToken;
    _scheduleAutoLogout(freshToken);
  }

  // ---------------------------------------------------------------------------
  // Vérification d'expiration JWT (côté client)
  // ---------------------------------------------------------------------------

  /// Décode le payload d'un JWT et vérifie son `exp`.
  /// Retourne `true` si le jeton est expiré (ou invalide).
  static bool _isTokenExpired(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return true;
      // Le payload est en base64url (partie 1).
      final payload = _decodeBase64Url(parts[1]);
      final claims = jsonDecode(payload) as Map<String, dynamic>;
      final exp = claims['exp'];
      if (exp == null) return false; // pas d'exp → on accepte (rare)
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return now >= (exp as num).toInt();
    } catch (_) {
      // Jeton malformé → on le considère comme expiré (sécurité par défaut).
      return true;
    }
  }

  /// Décode une chaîne base64url en texte (payload JWT).
  static String _decodeBase64Url(String b64url) {
    // Ajoute le padding manquant si nécessaire.
    final padded = b64url.replaceAll('-', '+').replaceAll('_', '=');
    final normalized = padded.padRight((padded.length + 3) ~/ 4 * 4, '=');
    return utf8.decode(base64.decode(normalized));
  }

  /// Programme un timer qui déconnecte automatiquement à l'expiration du JWT.
  void _scheduleAutoLogout(String jwt) {
    _expiryTimer?.cancel();
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return;
      final payload = _decodeBase64Url(parts[1]);
      final claims = jsonDecode(payload) as Map<String, dynamic>;
      final exp = claims['exp'];
      if (exp == null) return;
      final expDate =
          DateTime.fromMillisecondsSinceEpoch((exp as num).toInt() * 1000);
      final delay = expDate.difference(DateTime.now());
      if (delay.isNegative) {
        // Déjà expiré → logout immédiat.
        logout();
        onTokenExpired?.call();
        return;
      }
      // Timer qui se déclenche à l'expiration.
      _expiryTimer = Timer(delay, () {
        logout();
        onTokenExpired?.call();
      });
    } catch (_) {
      // Jeton malformé → on ignore (le getter isAuthenticated gérera l'expiration).
    }
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
