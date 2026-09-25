// Abonnés Plus — pagination SERVEUR (migration 0085, route EF
// `subscriptions/list`) : requête de page, lecture de la réponse, compteurs,
// équivalent local pour l'aperçu sans Supabase, indicateurs « Plus » des
// auteurs de suggestions.
//
// Demande propriétaire (25/09/2026) : plus de plafond à 100 000 abonnés —
// pagination à 100 par page, total exact, rien n'est chargé en entier.
// Logique PURE (aucune dépendance dart:html ni Flutter UI) : testée sur VM.

import 'package:flutter/foundation.dart';

import 'models/plus_user.dart';
import 'models/suggestion_author.dart';

/// Lignes par page de la liste des abonnés (demande propriétaire).
const int kPlusPageSize = 100;

/// Plafond d'une page côté serveur (route EF + RPC 0085).
const int kPlusMaxPageSize = 1000;

/// Longueur maximale de la recherche (caractères) — même borne côté EF/SQL.
const int kPlusSearchMaxLength = 100;

/// Clés de tri acceptées par le serveur (colonnes triables du tableau).
const Set<String> kPlusSortKeys = <String>{
  'display_name',
  'plan',
  'source',
  'status',
  'started_at',
};

/// Tri par défaut : plus récents d'abord (index de la migration 0085).
const String kPlusDefaultSort = 'started_at';

/// Une page d'abonnés + le total EXACT correspondant aux filtres.
typedef PlusPage = ({List<PlusUser> items, int total});

/// Requête d'une page d'abonnés : filtres, recherche, tri, pagination.
///
/// Les getters `effective*` / `normalized*` bornent et normalisent les
/// valeurs exactement comme le serveur (défense en profondeur : l'EF et la
/// RPC re-valident) — et servent aussi à l'aperçu local.
@immutable
class PlusPageQuery {
  const PlusPageQuery({
    this.page = 0,
    this.pageSize = kPlusPageSize,
    this.search = '',
    this.status,
    this.source,
    this.sort = kPlusDefaultSort,
    this.ascending = false,
  });

  /// Index de page (0 = première).
  final int page;

  /// Lignes par page (borné à [1, kPlusMaxPageSize]).
  final int pageSize;

  /// Pseudo (« contient », insensible à la casse) ou début d'identifiant.
  final String search;

  /// null = tous ; 'active' / 'inactive' (alias 'expired') — « Actif » =
  /// is_active, sens du badge Actif/Expiré.
  final String? status;

  /// null = toutes ; 'google' (source google*) ; 'admin' (« Manuel » : toutes
  /// les autres sources).
  final String? source;

  /// Colonne de tri ([kPlusSortKeys]) ; valeur inconnue = [kPlusDefaultSort].
  final String sort;

  /// Sens du tri.
  final bool ascending;

  int get effectivePage => page < 0 ? 0 : page;

  int get effectivePageSize => pageSize.clamp(1, kPlusMaxPageSize);

  /// Recherche rognée, tronquée à [kPlusSearchMaxLength] caractères (points
  /// de code : jamais de paire de substitution coupée).
  String get normalizedSearch {
    final String q = search.trim();
    if (q.runes.length <= kPlusSearchMaxLength) return q;
    return String.fromCharCodes(q.runes.take(kPlusSearchMaxLength));
  }

  String? get normalizedStatus => switch (status) {
    'active' => 'active',
    'inactive' || 'expired' => 'inactive',
    _ => null,
  };

  String? get normalizedSource => switch (source) {
    'google' => 'google',
    'admin' || 'manual' => 'admin',
    _ => null,
  };

  String get normalizedSort =>
      kPlusSortKeys.contains(sort) ? sort : kPlusDefaultSort;

  /// Corps JSON de la route EF `subscriptions/list`.
  Map<String, dynamic> toRequestBody() {
    final String q = normalizedSearch;
    return <String, dynamic>{
      'page': effectivePage,
      'pageSize': effectivePageSize,
      if (q.isNotEmpty) 'search': q,
      'status': ?normalizedStatus,
      'source': ?normalizedSource,
      'sort': normalizedSort,
      'ascending': ascending,
    };
  }
}

/// Lit la réponse de la route EF `subscriptions/list`
/// `{subscriptions: [...], total, page, pageSize}`. Une ligne sans
/// identifiant est ignorée ; `total` absent → nombre de lignes reçues.
PlusPage parsePlusPage(Map<String, dynamic> data) {
  final Object? rows = data['subscriptions'];
  final List<PlusUser> items = rows is List
      ? rows
            .whereType<Map<String, dynamic>>()
            .map(PlusUser.fromServerRow)
            .where((PlusUser u) => u.id.isNotEmpty)
            .toList()
      : <PlusUser>[];
  final Object? total = data['total'];
  return (items: items, total: total is num ? total.toInt() : items.length);
}

/// Nombre de pages pour [total] lignes (au moins 1, même sans résultat).
int plusPageCount(int total, int pageSize) {
  final int size = pageSize < 1 ? 1 : pageSize;
  if (total <= 0) return 1;
  return (total + size - 1) ~/ size;
}

/// Comparateur miroir du tri SQL de `admin_subscriptions_page` : clé
/// primaire [sort] dans le sens demandé, puis début d'abonnement décroissant,
/// puis identifiant croissant (ordre total → pages stables).
int Function(PlusUser, PlusUser) plusComparator(String sort, bool ascending) {
  return (PlusUser a, PlusUser b) {
    int primary;
    switch (sort) {
      case 'display_name':
        primary = a.displayName.toLowerCase().compareTo(
          b.displayName.toLowerCase(),
        );
      case 'plan':
        primary = a.plan.compareTo(b.plan);
      case 'source':
        primary = a.source.compareTo(b.source);
      case 'status':
        primary = (a.active ? 1 : 0).compareTo(b.active ? 1 : 0);
      default:
        primary = a.startedAt.compareTo(b.startedAt);
    }
    if (!ascending) primary = -primary;
    if (primary != 0) return primary;
    final int recentFirst = b.startedAt.compareTo(a.startedAt);
    if (recentFirst != 0) return recentFirst;
    return a.id.compareTo(b.id);
  };
}

/// Équivalent LOCAL de la route `subscriptions/list` (mode aperçu sans
/// Supabase) : mêmes filtres, recherche, tri et découpage que le serveur.
PlusPage applyPlusQueryLocally(List<PlusUser> all, PlusPageQuery query) {
  final String q = query.normalizedSearch.toLowerCase();
  final bool idPrefix = q.isNotEmpty && RegExp(r'^[0-9a-f-]+$').hasMatch(q);
  final String? status = query.normalizedStatus;
  final String? source = query.normalizedSource;
  final List<PlusUser> list = all.where((PlusUser u) {
    if (status == 'active' && !u.active) return false;
    if (status == 'inactive' && u.active) return false;
    if (source == 'google' && !u.isGoogle) return false;
    if (source == 'admin' && u.isGoogle) return false;
    if (q.isEmpty) return true;
    return u.displayName.toLowerCase().contains(q) ||
        (idPrefix && u.id.toLowerCase().startsWith(q));
  }).toList()..sort(plusComparator(query.normalizedSort, query.ascending));
  final int total = list.length;
  final int start = query.effectivePage * query.effectivePageSize;
  if (start >= total) return (items: <PlusUser>[], total: total);
  final int end = start + query.effectivePageSize;
  return (items: list.sublist(start, end > total ? total : end), total: total);
}

/// Compteurs des abonnés (route EF `subscriptions/stats`) : total, actifs
/// (is_active), répartition par formule et par source (toutes lignes).
@immutable
class PlusStats {
  const PlusStats({
    this.total = 0,
    this.active = 0,
    this.byPlan = const <String, int>{},
    this.bySource = const <String, int>{},
  });

  final int total;
  final int active;
  final Map<String, int> byPlan;
  final Map<String, int> bySource;

  /// Lecture tolérante `{total, active, by_plan, by_source}` (champs absents
  /// ou mal typés → 0 / vide).
  factory PlusStats.fromJson(Map<String, dynamic> json) => PlusStats(
    total: _asInt(json['total']),
    active: _asInt(json['active']),
    byPlan: _asCounts(json['by_plan']),
    bySource: _asCounts(json['by_source']),
  );

  /// Compteurs calculés sur une liste locale (mode aperçu).
  factory PlusStats.fromUsers(Iterable<PlusUser> users) {
    int total = 0;
    int active = 0;
    final Map<String, int> byPlan = <String, int>{};
    final Map<String, int> bySource = <String, int>{};
    for (final PlusUser u in users) {
      total++;
      if (u.active) active++;
      byPlan[u.plan] = (byPlan[u.plan] ?? 0) + 1;
      bySource[u.source] = (bySource[u.source] ?? 0) + 1;
    }
    return PlusStats(
      total: total,
      active: active,
      byPlan: byPlan,
      bySource: bySource,
    );
  }

  static int _asInt(Object? v) => v is num ? v.toInt() : 0;

  static Map<String, int> _asCounts(Object? v) {
    if (v is! Map) return const <String, int>{};
    final Map<String, int> out = <String, int>{};
    v.forEach((Object? key, Object? value) {
      if (key is String) out[key] = _asInt(value);
    });
    return out;
  }
}

/// Indicateurs « abonné Plus actif » par utilisateur (badge PLUS / bouton
/// « Plus » des suggestions) — SANS la liste complète des abonnés.
///
/// Deux sources : l'indicateur serveur `author_is_plus` de chaque suggestion
/// lue, et le résultat CONFIRMÉ des actions admin de la session (qui prime :
/// une suggestion lue juste avant l'action porte un indicateur périmé).
/// Utilisateur inconnu → false.
class PlusFlags {
  final Map<String, bool> _server = <String, bool>{};
  final Map<String, bool> _session = <String, bool>{};

  /// Enregistre l'indicateur serveur de [userId].
  void absorb(String userId, bool isPlus) {
    if (userId.isEmpty) return;
    _server[userId] = isPlus;
  }

  /// Enregistre les indicateurs des auteurs de suggestions lues.
  void absorbAuthors(Iterable<SuggestionAuthor> authors) {
    for (final SuggestionAuthor a in authors) {
      absorb(a.id, a.isPlus);
    }
  }

  /// Valeur posée par une action de la session pour [userId] (null = aucune).
  bool? sessionValue(String userId) => _session[userId];

  /// Pose (ou retire, avec null) la valeur de session de [userId] — sert à
  /// l'affichage optimiste puis au retour arrière en cas d'échec serveur.
  void setSessionValue(String userId, bool? isPlus) {
    if (isPlus == null) {
      _session.remove(userId);
    } else {
      _session[userId] = isPlus;
    }
  }

  /// [userId] est-il abonné Plus actif ?
  bool isPlus(String userId) => _session[userId] ?? _server[userId] ?? false;
}

/// Entier au format français (espace fine insécable entre les milliers).
String formatCount(int v) {
  final String digits = v.abs().toString();
  final StringBuffer buf = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(' ');
    buf.write(digits[i]);
  }
  return buf.toString();
}
