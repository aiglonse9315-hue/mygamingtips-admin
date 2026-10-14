import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auth_service.dart';
import 'login_messages.dart' show kMessageSessionExpiree;

/// Contrôleur d'authentification admin (Provider).
///
/// ⚠️ Ne contient AUCUN identifiant. Toute vérification est déléguée au
/// [AuthService] qui interroge le backend (cf. auth_service.dart). Le front-end
/// ne stocke qu'un jeton de session court terme.
///
/// Le jeton JWT est vérifié côté client : son expiration (`exp`) est contrôlée
/// au restore et un timer auto-logout déconnecte automatiquement à l'expiration
/// (même sans activité de l'utilisateur).
///
/// P4d L3 (D14) : plus aucun verrou local (le serveur fait foi : 429). Seul
/// garde-fou client : UNE connexion à la fois — un 2e appel pendant qu'une
/// requête est en vol (double-clic, Entrée répétée) reçoit le résultat de
/// la première, sans 2e requête ni 2e essai compté par le serveur.
class AuthController extends ChangeNotifier {
  AuthController(this._service) {
    // Connexion du callback d'expiration : force le logout + notification UI.
    _service.onTokenExpired = _onTokenExpired;
  }

  final AuthService _service;

  bool _loading = false;
  String? _error;

  /// Connexion en vol (anti double-clic), null sinon.
  Future<bool>? _enCours;

  /// Vrai uniquement si un jeton valide (non expiré) est présent.
  bool get isAuthenticated => _service.isAuthenticated;
  bool get isLoading => _loading;
  String? get error => _error;

  /// Jeton de session admin (pour pousser dans SupabaseSync après login).
  /// Retourne `null` si le jeton a expiré (sécurité : ne jamais exposer un
  /// jeton expiré, même s'il est encore en mémoire).
  String? get token => isAuthenticated ? _service.token : null;

  /// Vrai si la session courante appartient au compte principal (owner).
  /// Sert à afficher les menus réservés (ex. « Log ») — le serveur reste la
  /// vraie barrière de sécurité (403 sur les routes owner-only).
  bool get isOwner => isAuthenticated && _service.isOwner;

  /// Identifiant du compte connecté (claim `username` du JWT), null sinon.
  String? get currentUsername => isAuthenticated ? _service.username : null;

  /// Journal d'audit (consultable côté client pour transparence).
  List<AuthLogEntry> get auditLog => _service.log;

  /// Appelé quand le timer d'auto-logout se déclenche (jeton expiré : `exp`
  /// atteint sans jeton frais, ou fin de la session d'un administrateur
  /// humain, que le serveur coupe 12 h après la connexion — D2). L'écran de
  /// connexion qui réapparaît dit pourquoi.
  void _onTokenExpired() {
    _error = kMessageSessionExpiree;
    notifyListeners();
  }

  /// Restaure la session éventuelle au démarrage.
  void restore() {
    _service.restore();
    notifyListeners();
  }

  /// Connexion admin : transmet les credentials au backend (jamais vérifiés
  /// localement). Renvoie true en cas de succès. Une connexion déjà en vol
  /// est rendue telle quelle (anti double-clic : aucune 2e requête).
  Future<bool> login({
    required String username,
    required String password,
  }) {
    final Future<bool>? enCours = _enCours;
    if (enCours != null) return enCours;
    // Connexion inscrite AVANT de démarrer : un appel reçu pendant la partie
    // synchrone (notification des écouteurs) reçoit déjà ce résultat.
    final Completer<bool> resultat = Completer<bool>();
    _enCours = resultat.future;
    resultat.complete(_login(username: username, password: password));
    return resultat.future;
  }

  Future<bool> _login({
    required String username,
    required String password,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _service.login(
        username: username,
        password: password,
      );
      if (!result.success) {
        _error = result.message;
      }
    } catch (e) {
      // Par exemple endpoint non configuré : message clair côté UI.
      _error = e.toString();
    } finally {
      _loading = false;
      _enCours = null; // toujours après une attente : l'inscription a eu lieu
      notifyListeners();
    }
    return isAuthenticated;
  }

  void logout() {
    _service.logout();
    notifyListeners();
  }

  /// Rafraîchit le token courant (sliding session).
  /// Appelé après chaque écriture réussie pour prolonger la session.
  void refreshToken(String freshToken) {
    _service.refreshToken(freshToken);
    notifyListeners();
  }
}
