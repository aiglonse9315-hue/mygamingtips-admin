/// Ligne du journal des TENTATIVES (route EF `logs/attempts`, P4d L2 —
/// compte principal seul) : accès refusés au serveur d'administration.
///
/// Le [libelle] est rendu en FRANÇAIS par le serveur : le panneau l'affiche
/// tel quel et n'interprète AUCUN code (le dépôt du panneau est public). Le
/// [genre] brut n'est gardé que pour l'export CSV.
///
/// Textes NON FIABLES (choisis par celui qui a fait la requête) : [route],
/// [username], [ua], [detail] — `UntrustedLine` à l'affichage, cellule
/// neutralisée à l'export.
class SecurityAttempt {
  const SecurityAttempt({
    required this.at,
    required this.lastAt,
    required this.occurrences,
    required this.genre,
    required this.libelle,
    required this.route,
    required this.username,
    required this.ip,
    required this.ua,
    required this.detail,
  });

  /// Première occurrence (null si absente/invalide).
  final DateTime? at;

  /// Dernière occurrence d'une ligne regroupée (null si absente/invalide).
  final DateTime? lastAt;

  /// Nombre d'occurrences regroupées dans la ligne (1 si absent/invalide).
  final int occurrences;

  /// Code brut du serveur (export CSV seulement, jamais interprété).
  final String? genre;

  /// Libellé français rendu par le serveur ('' si absent).
  final String libelle;

  final String? route;
  final String? username;
  final String? ip;
  final String? ua;
  final String? detail;

  /// Ligne regroupée (plusieurs occurrences).
  bool get isGrouped => occurrences > 1;

  /// « dernière : … » s'affiche : regroupée ET dernière date différente de
  /// la première.
  bool get showLastAt {
    final DateTime? first = at;
    final DateTime? last = lastAt;
    return isGrouped &&
        first != null &&
        last != null &&
        !last.isAtSameMomentAs(first);
  }

  factory SecurityAttempt.fromJson(Map<String, dynamic> j) {
    final Object? n = j['occurrences'];
    return SecurityAttempt(
      at: _date(j['at']),
      lastAt: _date(j['last_at']),
      occurrences: n is num && n >= 1 ? n.toInt() : 1,
      genre: _text(j['genre']),
      libelle: _text(j['libelle']) ?? '',
      route: _text(j['route']),
      username: _text(j['username']),
      ip: _text(j['ip']),
      ua: _text(j['ua']),
      detail: _text(j['detail']),
    );
  }

  static String? _text(Object? v) => v is String ? v : null;

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse(v) : null;
}

/// Page du journal des tentatives (`{tentatives, total}` ; la présence de la
/// liste est vérifiée par l'appelant).
class SecurityAttemptPage {
  const SecurityAttemptPage({required this.items, required this.total});

  final List<SecurityAttempt> items;
  final int total;

  static SecurityAttemptPage fromJson(Map<String, dynamic> j) {
    final Object? raw = j['tentatives'];
    final List<SecurityAttempt> items = raw is List
        ? raw
              .whereType<Map<String, dynamic>>()
              .map(SecurityAttempt.fromJson)
              .toList(growable: false)
        : const <SecurityAttempt>[];
    final Object? total = j['total'];
    return SecurityAttemptPage(
      items: items,
      total: total is num && total >= 0 ? total.toInt() : items.length,
    );
  }
}
