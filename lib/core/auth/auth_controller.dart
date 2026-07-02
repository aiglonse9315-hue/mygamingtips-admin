import 'package:flutter/foundation.dart';

import 'auth_service.dart';

/// Contrôleur d'authentification admin (Provider).
///
/// ⚠️ Ne contient AUCUN identifiant. Toute vérification est déléguée au
/// [AuthService] qui interroge le backend (cf. auth_service.dart). Le front-end
/// ne stocke qu'un jeton de session court terme.
class AuthController extends ChangeNotifier {
  AuthController(this._service);

  final AuthService _service;

  bool _loading = false;
  String? _error;

  bool get isAuthenticated => _service.isAuthenticated;
  bool get isLoading => _loading;
  String? get error => _error;

  /// Jeton de session admin (pour pousser dans SupabaseSync après login).
  String? get token => _service.token;

  /// Journal d'audit (consultable côté client pour transparence).
  List<AuthLogEntry> get auditLog => _service.log;

  /// Restaure la session éventuelle au démarrage.
  void restore() {
    _service.restore();
    notifyListeners();
  }

  /// Connexion admin : transmet les credentials au backend (jamais vérifiés
  /// localement). Renvoie true en cas de succès.
  Future<bool> login({
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
      notifyListeners();
    }
    return isAuthenticated;
  }

  void logout() {
    _service.logout();
    notifyListeners();
  }
}
