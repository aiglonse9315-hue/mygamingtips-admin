import 'dart:convert';
import 'dart:html' as html;

import '../../domain/models/banned_user.dart';
import '../../domain/models/content.dart';
import '../../domain/models/game.dart';
import '../../domain/models/plus_user.dart';
import '../../domain/models/suggestion.dart';

/// Couche d'accès aux données du panneau admin (phase mock).
///
/// Les données initiales proviennent des assets JSON (`assets/seed/*.json`).
/// Toute modification est persistée dans le `localStorage` du navigateur.
class Store {
  static const String _kGames = 'mgt_admin_games';
  static const String _kContents = 'mgt_admin_contents';
  static const String _kSuggestions = 'mgt_admin_suggestions';
  static const String _kBanned = 'mgt_admin_banned';
  static const String _kPlus = 'mgt_admin_plus';
  static const String _kInitialized = 'mgt_admin_initialized';

  final String gamesSeed;
  final String contentsSeed;
  final String suggestionsSeed;
  final String bannedSeed;
  final String plusSeed;

  Store({
    required this.gamesSeed,
    required this.contentsSeed,
    required this.suggestionsSeed,
    required this.bannedSeed,
    required this.plusSeed,
  });

  /// Initialise le localStorage au 1er lancement à partir des seeds.
  void ensureInitialized() {
    if (html.window.localStorage[_kInitialized] != 'true') {
      html.window.localStorage[_kGames] = gamesSeed;
      html.window.localStorage[_kContents] = contentsSeed;
      html.window.localStorage[_kSuggestions] = suggestionsSeed;
      html.window.localStorage[_kBanned] = bannedSeed;
      html.window.localStorage[_kPlus] = plusSeed;
      html.window.localStorage[_kInitialized] = 'true';
    }
  }

  /// Restaure les données seed (bouton « Réinitialiser la démo »).
  void resetToSeed() {
    html.window.localStorage[_kGames] = gamesSeed;
    html.window.localStorage[_kContents] = contentsSeed;
    html.window.localStorage[_kSuggestions] = suggestionsSeed;
    html.window.localStorage[_kBanned] = bannedSeed;
    html.window.localStorage[_kPlus] = plusSeed;
    html.window.localStorage[_kInitialized] = 'true';
  }

  // ---------- Jeux ----------
  List<Game> loadGames() => _loadList(_kGames, Game.fromJson);
  void saveGames(List<Game> games) =>
      _saveList(_kGames, games.map((g) => g.toJson()).toList());

  // ---------- Contenus ----------
  List<Content> loadContents() => _loadList(_kContents, Content.fromJson);
  void saveContents(List<Content> contents) =>
      _saveList(_kContents, contents.map((c) => c.toJson()).toList());

  // ---------- Suggestions ----------
  List<Suggestion> loadSuggestions() =>
      _loadList(_kSuggestions, Suggestion.fromJson);
  void saveSuggestions(List<Suggestion> suggestions) =>
      _saveList(_kSuggestions, suggestions.map((s) => s.toJson()).toList());

  // ---------- Comptes bannis ----------
  List<BannedUser> loadBanned() => _loadList(_kBanned, BannedUser.fromJson);
  void saveBanned(List<BannedUser> banned) =>
      _saveList(_kBanned, banned.map((b) => b.toJson()).toList());

  // ---------- Utilisateurs Plus ----------
  List<PlusUser> loadPlus() => _loadList(_kPlus, PlusUser.fromJson);
  void savePlus(List<PlusUser> plus) =>
      _saveList(_kPlus, plus.map((n) => n.toJson()).toList());

  // ---------- Curseurs de sync incrémentale ----------
  //
  // Pour chaque dataset synchronisable, on persiste le curseur
  // `max(updated_at)` vu (moins une marge anti-désalignement d'horloge,
  // appliquée par le caller) ainsi que l'horodatage du fetch — ce dernier
  // sert à la règle des 24 h (au-delà, full sync de sécurité).
  // Clés : `mgt_admin_cursor_<name>` (ex. mgt_admin_cursor_contents).
  static const String _kCursorPrefix = 'mgt_admin_cursor_';

  /// Lit le curseur du dataset [name] : valeur ISO (`updated_at` max vu,
  /// marge déjà déduite) + horodatage du fetch. Null si absent/illisible.
  ({String value, DateTime fetchedAt})? loadCursor(String name) {
    final String? raw = html.window.localStorage['$_kCursorPrefix$name'];
    if (raw == null || raw.isEmpty) return null;
    try {
      final Map<String, dynamic> m = jsonDecode(raw) as Map<String, dynamic>;
      final String? value = m['v'] as String?;
      final DateTime? at = DateTime.tryParse(m['at'] as String? ?? '');
      if (value == null || value.isEmpty || at == null) return null;
      return (value: value, fetchedAt: at);
    } catch (_) {
      return null;
    }
  }

  /// Persiste le curseur du dataset [name].
  void saveCursor(String name, String value, DateTime fetchedAt) {
    html.window.localStorage['$_kCursorPrefix$name'] = jsonEncode(
      <String, String>{'v': value, 'at': fetchedAt.toUtc().toIso8601String()},
    );
  }

  /// Efface le curseur du dataset [name] (force une full sync au prochain
  /// chargement).
  void clearCursor(String name) {
    html.window.localStorage.remove('$_kCursorPrefix$name');
  }

  // ---------- Helpers ----------
  List<T> _loadList<T>(String key, T Function(Map<String, dynamic>) fromJson) {
    final String? raw = html.window.localStorage[key];
    if (raw == null || raw.isEmpty) return <T>[];
    final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => fromJson(e as Map<String, dynamic>)).toList();
  }

  void _saveList(String key, List<Map<String, dynamic>> data) {
    html.window.localStorage[key] = jsonEncode(data);
  }
}
