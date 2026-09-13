/// Un compte administrateur du panneau (table `admin_users`, migration 0057),
/// tel que retourné par la route EF `admin-users/list`.
///
/// **Jamais de `password_hash`** : le serveur ne l'envoie pas et le modèle ne
/// le connaît pas. La route est réservée au compte principal (owner) —
/// 403 sinon.
class AdminUserAccount {
  const AdminUserAccount({
    required this.username,
    required this.isOwner,
    required this.active,
    this.createdAt,
    this.createdBy,
  });

  /// Identifiant de connexion du compte (unique).
  final String username;

  /// Vrai si c'est un compte principal (owner) — accès aux menus réservés
  /// (Log, Comptes).
  final bool isOwner;

  /// Vrai si le compte est actif. Un compte désactivé est révoqué
  /// immédiatement : le serveur re-vérifie `active=true` à chaque appel.
  final bool active;

  /// Date de création du compte (null si absente/invalide côté serveur).
  final DateTime? createdAt;

  /// Username du compte créateur (null pour le compte principal seedé).
  final String? createdBy;

  factory AdminUserAccount.fromJson(Map<String, dynamic> json) {
    return AdminUserAccount(
      username: json['username']?.toString() ?? '—',
      isOwner: json['is_owner'] == true,
      active: json['active'] == true,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      createdBy: json['created_by']?.toString(),
    );
  }
}
