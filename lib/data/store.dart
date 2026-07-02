import 'dart:convert';
import 'dart:html' as html;

import '../../domain/models/banned_user.dart';
import '../../domain/models/content.dart';
import '../../domain/models/game.dart';
import '../../domain/models/nitro_user.dart';
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
  static const String _kNitro = 'mgt_admin_nitro';
  static const String _kInitialized = 'mgt_admin_initialized';

  final String gamesSeed;
  final String contentsSeed;
  final String suggestionsSeed;
  final String bannedSeed;
  final String nitroSeed;

  Store({
    required this.gamesSeed,
    required this.contentsSeed,
    required this.suggestionsSeed,
    required this.bannedSeed,
    required this.nitroSeed,
  });

  /// Initialise le localStorage au 1er lancement à partir des seeds.
  void ensureInitialized() {
    if (html.window.localStorage[_kInitialized] != 'true') {
      html.window.localStorage[_kGames] = gamesSeed;
      html.window.localStorage[_kContents] = contentsSeed;
      html.window.localStorage[_kSuggestions] = suggestionsSeed;
      html.window.localStorage[_kBanned] = bannedSeed;
      html.window.localStorage[_kNitro] = nitroSeed;
      html.window.localStorage[_kInitialized] = 'true';
    }
  }

  /// Restaure les données seed (bouton « Réinitialiser la démo »).
  void resetToSeed() {
    html.window.localStorage[_kGames] = gamesSeed;
    html.window.localStorage[_kContents] = contentsSeed;
    html.window.localStorage[_kSuggestions] = suggestionsSeed;
    html.window.localStorage[_kBanned] = bannedSeed;
    html.window.localStorage[_kNitro] = nitroSeed;
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

  // ---------- Utilisateurs Nitro ----------
  List<NitroUser> loadNitro() => _loadList(_kNitro, NitroUser.fromJson);
  void saveNitro(List<NitroUser> nitro) =>
      _saveList(_kNitro, nitro.map((n) => n.toJson()).toList());

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
