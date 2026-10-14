/// Entrée du journal d'activité du panneau admin (route EF `logs/list`).
///
/// Deux familles d'événements, discriminées par [type] :
/// - `auth` : connexions / tentatives de connexion au panneau ;
/// - `action` : opérations d'administration (écritures catalogue, bans, etc.).
///
/// Le serveur retourne les entrées triées par date DÉCROISSANTE. La route est
/// réservée au compte principal (owner) — 403 sinon.
///
/// Colonnes v2 (P4d, vue `admin_logs_all` v2 de 0098, rendues par
/// admin-catalog depuis L2) : [success], [ip], [ua], [sid]. Les archives
/// créées depuis 0098 les contiennent aussi (`logs/archive/download` les
/// rend quand l'archive les a). Lecture TOLÉRANTE : absentes (serveur
/// d'avant L2, archive d'avant 0098 — juillet à septembre 2026 —, route
/// qui ne les rend pas) ou d'un autre type → null, jamais une erreur.
class LogEntry {
  const LogEntry({
    required this.type,
    required this.at,
    required this.username,
    required this.action,
    required this.detail,
    this.success,
    this.ip,
    this.ua,
    this.sid,
  });

  /// `auth` ou `action`.
  final String type;

  /// Horodatage de l'événement (null si absent/invalide côté serveur).
  final DateTime? at;

  /// Compte admin à l'origine de l'événement — pour une connexion ratée,
  /// le login TAPÉ (texte NON FIABLE : `UntrustedLine` à l'affichage).
  final String username;

  /// Libellé court de l'événement (ex. `login`, `games/upsert`).
  final String action;

  /// Détail libre de l'événement (peut être long / multi-lignes ; texte NON
  /// FIABLE).
  final String detail;

  /// Issue d'une connexion : vrai = réussie, faux = ratée ou bloquée ; null
  /// pour une action, une archive d'avant 0098 ou un serveur d'avant L2.
  final bool? success;

  /// IP notée par le serveur (normalisée depuis L2 : IPv4, IPv6 ou
  /// « unknown ») ; null si absente.
  final String? ip;

  /// User-agent coupé par le serveur (texte NON FIABLE, choisi par le
  /// client) ; null si absent.
  final String? ua;

  /// Identifiant de la session (tiré au hasard à la connexion réussie) ;
  /// null pour une ligne sans session.
  final String? sid;

  /// Vrai pour une entrée de la famille « connexions ».
  bool get isAuth => type == 'auth';

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      type: json['type']?.toString() ?? 'action',
      at: DateTime.tryParse(json['at']?.toString() ?? ''),
      username: json['username']?.toString() ?? '—',
      action: json['action']?.toString() ?? '',
      detail: json['detail']?.toString() ?? '',
      success: json['success'] is bool ? json['success'] as bool : null,
      ip: _text(json['ip']),
      ua: _text(json['ua']),
      sid: _text(json['sid']),
    );
  }

  /// Texte ou null (toute autre valeur : colonne absente pour le panneau).
  static String? _text(Object? v) => v is String ? v : null;
}

/// Page du journal (`logs/list`) : lignes, [total] (lignes VISIBLES, filtre
/// compris), [masquees] (lignes cachées par le filtre « activité normale »,
/// 0 si le serveur ne l'envoie pas) et [filtreApplique] (vrai SEULEMENT si
/// le filtre du serveur a tourné ; faux si absent : serveur d'avant L2 ou
/// filtre en échec → tout est affiché).
class LogPage {
  const LogPage({
    required this.items,
    required this.total,
    this.masquees = 0,
    this.filtreApplique = false,
  });

  final List<LogEntry> items;
  final int total;
  final int masquees;
  final bool filtreApplique;

  /// Lecture tolérante de `{logs, total, masquees, filtre_applique}` (la
  /// présence de la liste `logs` est vérifiée par l'appelant). Un compte
  /// absent ou négatif ne casse rien : `total` → nombre de lignes reçues,
  /// `masquees` → 0.
  static LogPage fromJson(Map<String, dynamic> j) {
    final Object? raw = j['logs'];
    final List<LogEntry> items = raw is List
        ? raw
              .whereType<Map<String, dynamic>>()
              .map(LogEntry.fromJson)
              .toList(growable: false)
        : const <LogEntry>[];
    return LogPage(
      items: items,
      total: _count(j['total']) ?? items.length,
      masquees: _count(j['masquees']) ?? 0,
      filtreApplique: j['filtre_applique'] == true,
    );
  }

  static int? _count(Object? v) => v is num && v >= 0 ? v.toInt() : null;
}
