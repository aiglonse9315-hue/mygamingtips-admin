/// Entrée du journal d'activité du panneau admin (route EF `logs/list`).
///
/// Deux familles d'événements, discriminées par [type] :
/// - `auth` : connexions / tentatives de connexion au panneau ;
/// - `action` : opérations d'administration (écritures catalogue, bans, etc.).
///
/// Le serveur retourne les entrées triées par date DÉCROISSANTE. La route est
/// réservée au compte principal (owner) — 403 sinon.
class LogEntry {
  const LogEntry({
    required this.type,
    required this.at,
    required this.username,
    required this.action,
    required this.detail,
  });

  /// `auth` ou `action`.
  final String type;

  /// Horodatage de l'événement (null si absent/invalide côté serveur).
  final DateTime? at;

  /// Compte admin à l'origine de l'événement.
  final String username;

  /// Libellé court de l'événement (ex. `login`, `games/upsert`).
  final String action;

  /// Détail libre de l'événement (peut être long / multi-lignes).
  final String detail;

  /// Vrai pour une entrée de la famille « connexions ».
  bool get isAuth => type == 'auth';

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      type: json['type']?.toString() ?? 'action',
      at: DateTime.tryParse(json['at']?.toString() ?? ''),
      username: json['username']?.toString() ?? '—',
      action: json['action']?.toString() ?? '',
      detail: json['detail']?.toString() ?? '',
    );
  }
}
