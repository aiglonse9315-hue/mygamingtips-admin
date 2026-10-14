import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../data/local_storage.dart';
import '../../data/supabase_key_headers.dart';
import '../../domain/jwt_payload.dart';
import 'login_messages.dart';

/// Service d'authentification du panneau admin.
///
/// ⚠️ AUCUN identifiant n'est stocké côté client. Les credentials sont
/// **vérifiés côté serveur** (Edge Function Supabase ou endpoint sécurisé).
/// Le front-end ne fait qu'envoyer login + mot de passe vers le backend, qui
/// renvoie (ou non) un jeton de session.
///
/// Bonnes pratiques intégrées côté client :
/// - **Aucun verrou local** (P4d L3, D14) : le serveur fait foi. Il compte
///   les essais, bloque et répond 429 avec un message qui donne la durée ;
///   le panneau l'affiche tel quel ([messageRefusConnexion]). L'ancien
///   verrou recopiait les seuils du serveur dans ce code, publié dans le
///   miroir PUBLIC du panneau. Seule protection gardée côté client : une
///   connexion à la fois (`AuthController.login`, bouton désactivé pendant
///   la requête).
/// - **Messages distincts** selon la réponse (401, 429, 503, 400, réseau),
///   classés par la fonction pure [messageRefusConnexion].
/// - **Journalisation locale** des tentatives (horodatage, succès/échec),
///   consultable depuis la console navigateur pour audit.
/// - **Stockage du jeton** : jamais les credentials, uniquement le jeton de
///   session (court terme, à valider côté serveur à chaque requête sensible).
/// - **Vérification d'expiration JWT côté client** : le jeton est décodé au
///   restore et son `exp` est contrôlé. Un timer auto-logout déconnecte dès
///   que le jeton expire (même sans activité). Le panneau ne suit QUE l'`exp`
///   du jeton, jamais une durée codée : le serveur émet des jetons de 2 h,
///   renouvelés à l'usage (`fresh_token`), et coupe la session d'un
///   administrateur humain 12 h après la connexion en plafonnant l'`exp`
///   (D2) — un jeton frais peut donc expirer AVANT `iat` + 2 h.
///
/// **Mode aperçu local (démo)** : activé UNIQUEMENT via le flag de compilation
/// `--dart-define=MGT_ADMIN_PREVIEW=true`. En production (sans ce flag), aucune
/// connexion n'est possible sans backend réel. Ce mode n'embarque AUCUN
/// identifiant : il délivre un jeton factice pour permettre de naviguer dans
/// l'interface avec les données de démonstration, le temps de déployer
/// l'Edge Function d'authentification (cf. GUIDE_DEPLOIEMENT.md §1.7bis).
///
/// Stockage par [browserLocalStorage] (`localStorage` du navigateur sur le
/// web, table en mémoire en VM) : plus de `dart:html` ici, le service se
/// teste en VM avec un client HTTP simulé ([client]).
class AuthService {
  AuthService({String? endpoint, this.client})
      : endpoint = endpoint ?? _configuredEndpoint() {
    // P4d L3 (D14) : le verrou local est retiré ; les clés qu'il laissait
    // dans le navigateur (compteur d'échecs, fin de blocage) sont effacées.
    for (final String cle in _kAnciennesClesVerrou) {
      browserLocalStorage.remove(cle);
    }
  }

  /// Mode aperçu local (démo) : activé au build via dart-define.
  /// En production ce flag vaut `false` → auth strict serveur obligatoire.
  static const bool previewMode =
      bool.fromEnvironment('MGT_ADMIN_PREVIEW', defaultValue: false);

  /// Clé PUBLIQUE Supabase (ancienne `anon`, puis publishable
  /// `sb_publishable_…` à l'étape 3b de tools/PLAN_SUPABASE_CLES.md).
  /// Publique par conception (RLS protège les données). Fournie via
  /// dart-define au build. Envoyée à admin-login dans l'en-tête `apikey`
  /// SEULEMENT ([supabaseKeyHeaders], étape 3a) : jamais en
  /// `Authorization: Bearer` (une clé publishable n'est pas un JWT) ;
  /// admin-login tourne sans « Verify JWT ».
  static const String anonKey =
      String.fromEnvironment('MGT_SUPABASE_ANON_KEY', defaultValue: '');

  /// URL du backend de vérification des identifiants admin.
  /// Doit être configurée côté serveur (Edge Function / API) — jamais codée
  /// en dur avec des credentials.
  final String endpoint;

  /// Client HTTP (tests : client simulé) ; null → client par défaut du
  /// paquet `http` (navigateur sur le web).
  final http.Client? client;

  static const String _kToken = 'mgt_admin_token';

  /// Clés de l'ancien verrou local (avant P4d L3), effacées au démarrage.
  static const List<String> _kAnciennesClesVerrou = <String>[
    'mgt_admin_lock_until',
    'mgt_admin_fail_count',
  ];

  /// Délai d'attente de la réponse d'admin-login.
  static const Duration _kDelaiConnexion = Duration(seconds: 10);

  String? _token;
  String? get token => _token;

  /// Vrai si la session courante appartient au compte principal (owner).
  /// Capturé depuis la réponse de login (`is_owner`) ET confirmé/relu depuis
  /// le payload JWT à chaque rotation de token (sliding session) — reste
  /// donc vrai après un fresh_token. En mode aperçu : toujours vrai (démo).
  bool get isOwner => previewMode ? true : _isOwner;
  bool _isOwner = false;

  /// Identifiant du compte connecté (claim `username` du JWT / login).
  String? get username => previewMode ? 'aperçu' : _username;
  String? _username;

  /// Timer d'auto-logout : déconnecte automatiquement quand le JWT expire.
  Timer? _expiryTimer;

  /// Vrai uniquement si un jeton est présent ET non expiré.
  bool get isAuthenticated {
    if (_token == null) return false;
    // En mode aperçu, le jeton factice n'a pas de structure JWT → on accepte.
    if (previewMode) return true;
    return !_isTokenExpired(_token!);
  }

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
    final stored = browserLocalStorage[_kToken];
    if (stored == null || stored.isEmpty) {
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
      browserLocalStorage.remove(_kToken);
      _token = null;
      return;
    }
    _token = stored;
    // Relit les claims (is_owner, username) depuis le JWT restauré.
    _applyClaimsFromToken(stored);
    _scheduleAutoLogout(stored);
  }

  /// Ajoute une entrée au journal local d'audit.
  void _noter(bool success, String detail) {
    _log.add(
        AuthLogEntry(at: DateTime.now(), success: success, detail: detail));
  }

  /// Tente de connecter. Renvoie le résultat (succès + message éventuel).
  ///
  /// [username] / [password] sont transmis au backend ; aucune comparaison
  /// locale n'est effectuée. Chaque appel aux deux champs remplis envoie UNE
  /// requête : aucun compteur ni blocage local (le serveur fait foi : 429).
  /// Un champ vide n'envoie rien ([kMessageChampsRequis]).
  Future<AuthResult> login({
    required String username,
    required String password,
  }) async {
    // 0) Mode aperçu local (démo) : activé UNIQUEMENT au build via dart-define.
    if (previewMode) {
      _token = 'preview-token-${DateTime.now().millisecondsSinceEpoch}';
      browserLocalStorage[_kToken] = _token!;
      _noter(true, 'connexion en mode aperçu local (démo)');
      return const AuthResult(success: true);
    }

    // 1) Panneau construit sans adresse d'authentification (main.dart passe
    //    alors un endpoint vide) : aucune requête.
    if (endpoint.isEmpty) {
      _noter(false, 'endpoint d\'authentification non configuré');
      return const AuthResult(
          success: false, message: kMessageConfigurationRequise);
    }

    // 2) Champ vide (P4d L3, constat B01) : aucune requête. Sinon le serveur
    //    répond 400 (« Requête refusée par le serveur. », qui fait penser à
    //    une panne) et note une requête invalide pour un simple oubli
    //    (Entrée appuyée avant le remplissage automatique, par exemple).
    //    Un identifiant fait d'espaces compte comme vide ; le mot de passe
    //    n'est jamais retouché (seule la chaîne vide l'arrête) ; un
    //    identifiant non vide part tel quel.
    if (username.trim().isEmpty || password.isEmpty) {
      _noter(false, 'champ vide (rien envoyé)');
      return const AuthResult(success: false, message: kMessageChampsRequis);
    }

    // 3) Appel au backend de vérification.
    final http.Response response;
    try {
      final Uri uri = Uri.parse(endpoint);
      final Map<String, String> headers = {
        'Content-Type': 'application/json',
        ...supabaseKeyHeaders(anonKey),
      };
      final String body =
          jsonEncode({'username': username, 'password': password});
      final http.Client? injecte = client;
      response = await (injecte != null
              ? injecte.post(uri, headers: headers, body: body)
              : http.post(uri, headers: headers, body: body))
          .timeout(_kDelaiConnexion);
    } on TimeoutException {
      _noter(false, 'délai dépassé');
      return const AuthResult(
          success: false, message: kMessageServeurInjoignable);
    } on http.ClientException catch (e) {
      // Réseau coupé, DNS, CORS refusé par le navigateur : aucune réponse.
      _noter(false, 'serveur injoignable: ${e.message}');
      return const AuthResult(
          success: false, message: kMessageServeurInjoignable);
    } catch (e) {
      // Adresse illisible ou autre erreur de configuration.
      _noter(false, 'erreur: $e');
      return const AuthResult(
          success: false, message: kMessageConfigurationRequise);
    }

    // 4) Corps décodé en UTF-8 quel que soit l'en-tête (le message d'un 429
    //    porte des accents ; un octet invalide ne lève pas).
    final String corps = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode == 200) {
      final SuccesConnexion? succes = lireSuccesConnexion(corps);
      if (succes != null) {
        // Le panneau ne suit que l'`exp` du jeton : un jeton inutilisable
        // n'ouvre pas de session (sinon : connexion « réussie » suivie
        // d'une déconnexion immédiate, sans message). `exp` lisible mais
        // passé → horloge de l'appareil en avance ; illisible → réponse
        // inattendue.
        if (_isTokenExpired(succes.token)) {
          final bool expLisible =
              decodeJwtPayload(succes.token)?['exp'] is num;
          _noter(false, expLisible
              ? 'jeton reçu déjà expiré (horloge locale ?)'
              : 'jeton reçu illisible ou sans échéance');
          return AuthResult(
            success: false,
            message: expLisible
                ? kMessageJetonDejaExpire
                : kMessageReponseInattendue,
          );
        }
        _token = succes.token;
        browserLocalStorage[_kToken] = succes.token;
        // Capture le privilège owner : 1) depuis la réponse de login
        // (`is_owner`), 2) confirmé depuis le payload JWT (source de
        // vérité partagée avec les fresh_token de la sliding session).
        _isOwner = succes.isOwner;
        _username = username;
        _applyClaimsFromToken(succes.token);
        _noter(true, 'connexion réussie');
        _scheduleAutoLogout(succes.token);
        return const AuthResult(success: true);
      }
    }

    // 5) Refus : message selon le statut (401, 429 du serveur, 503, 400…).
    _noter(false, 'refus HTTP ${response.statusCode}');
    return AuthResult(
      success: false,
      message: messageRefusConnexion(response.statusCode, corps),
    );
  }

  void logout() {
    _token = null;
    _isOwner = false;
    _username = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    browserLocalStorage.remove(_kToken);
  }

  /// Remplace le token courant par un nouveau token frais (sliding session).
  ///
  /// Appelé automatiquement après chaque écriture réussie : l'Edge Function
  /// renvoie un `fresh_token`, nouveau jeton de 2 h (session glissante).
  /// Pour la session d'un administrateur humain, le serveur plafonne son
  /// `exp` 12 h après la connexion (D2) : le dernier jeton frais d'une
  /// telle session expire donc AVANT `iat` + 2 h.
  /// Le timer d'auto-logout est reprogrammé sur l'`exp` du nouveau jeton,
  /// seule échéance suivie par le panneau.
  void refreshToken(String freshToken) {
    _token = freshToken;
    browserLocalStorage[_kToken] = freshToken;
    // Les fresh_token portent aussi username/is_owner : on relit les claims
    // pour que le privilège owner reste exact après chaque rotation.
    _applyClaimsFromToken(freshToken);
    _scheduleAutoLogout(freshToken);
  }

  // ---------------------------------------------------------------------------
  // Vérification d'expiration JWT (côté client)
  // ---------------------------------------------------------------------------

  /// Décode le payload d'un JWT et vérifie son `exp`.
  /// Retourne `true` si le jeton est expiré (ou invalide).
  ///
  /// P4b-3 (T14) : le payload est lu par [decodeJwtPayload] (base64 standard
  /// du serveur ET base64url, Latin-1 de `btoa` accepté) — l'ancien décodage
  /// remplaçait `_` par `=` et refusait un nom de compte accentué.
  static bool _isTokenExpired(String jwt) {
    // Jeton malformé, SANS `exp`, `exp` illisible ou passé → expiré
    // (sécurité par défaut ; revue P4b-3, SEC-P4b3-07 : un jeton sans
    // échéance n'est plus accepté — le serveur pose toujours `exp`).
    return !isJwtUsable(jwt);
  }

  /// Relit les claims de session (`is_owner`, `username`) depuis le payload
  /// JWT (segment du milieu, [decodeJwtPayload]). Tolérant aux jetons
  /// malformés : en cas d'échec de décodage, les valeurs connues sont
  /// conservées.
  void _applyClaimsFromToken(String jwt) {
    final Map<String, dynamic>? claims = decodeJwtPayload(jwt);
    if (claims == null) return; // malformé → claims déjà connus conservés
    final owner = claims['is_owner'];
    if (owner is bool) _isOwner = owner;
    final user = claims['username'];
    if (user is String && user.isNotEmpty) _username = user;
  }

  /// Programme un timer qui déconnecte automatiquement à l'expiration du JWT.
  void _scheduleAutoLogout(String jwt) {
    _expiryTimer?.cancel();
    try {
      final Map<String, dynamic>? claims = decodeJwtPayload(jwt);
      if (claims == null) return;
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
