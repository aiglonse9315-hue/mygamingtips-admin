import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/models/banned_user.dart';
import '../../domain/models/content.dart';
import '../../domain/models/game.dart';
import '../../domain/models/plus_user.dart';
import '../../domain/models/suggestion.dart';
import 'local_storage.dart';

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

  /// Marqueur : le cache contenus persisté est COMPLET (posé par la SEULE
  /// synchro des contenus, quand sa liste complète a été persistée —
  /// [markContentsComplete] ; retiré par tout [saveContents] qui échoue ou
  /// renonce). Sans lui, un curseur `contents`
  /// persisté ne vaut rien pour la session suivante (incident du 14/10 : un
  /// catalogue trop gros pour le localStorage, un curseur de moins de 24 h →
  /// la synchro incrémentale ne rapportait que les contenus récents).
  static const String _kContentsComplete = 'mgt_admin_contents_complet';

  final String gamesSeed;
  final String contentsSeed;
  final String suggestionsSeed;
  final String bannedSeed;
  final String plusSeed;

  /// Seuil au-delà duquel le cache contenus n'est PAS persisté (réglable
  /// pour les tests ; voir [_maxContentsCacheBytes]).
  final int maxContentsCacheBytes;

  Store({
    required this.gamesSeed,
    required this.contentsSeed,
    required this.suggestionsSeed,
    required this.bannedSeed,
    required this.plusSeed,
    this.maxContentsCacheBytes = _maxContentsCacheBytes,
  });

  /// Initialise le localStorage au 1er lancement à partir des seeds.
  void ensureInitialized() {
    if (browserLocalStorage[_kInitialized] != 'true') {
      browserLocalStorage[_kGames] = gamesSeed;
      browserLocalStorage[_kContents] = contentsSeed;
      browserLocalStorage[_kSuggestions] = suggestionsSeed;
      browserLocalStorage[_kBanned] = bannedSeed;
      browserLocalStorage[_kPlus] = plusSeed;
      browserLocalStorage[_kInitialized] = 'true';
    }
  }

  /// Restaure les données seed (bouton « Réinitialiser la démo »).
  void resetToSeed() {
    browserLocalStorage[_kGames] = gamesSeed;
    browserLocalStorage[_kContents] = contentsSeed;
    browserLocalStorage[_kSuggestions] = suggestionsSeed;
    browserLocalStorage[_kBanned] = bannedSeed;
    browserLocalStorage[_kPlus] = plusSeed;
    browserLocalStorage[_kInitialized] = 'true';
  }

  // ---------- Jeux ----------
  List<Game> loadGames() => _loadList(_kGames, Game.fromJson);
  void saveGames(List<Game> games) =>
      _saveList(_kGames, games.map((g) => g.toJson()).toList());

  // ---------- Contenus ----------
  List<Content> loadContents() => _loadList(_kContents, Content.fromJson);

  /// Seuil au-delà duquel le cache contenus n'est PAS persisté (~3,5 Mo).
  ///
  /// Le catalogue complet (~10 600 lignes JSON) dépasse le quota localStorage
  /// du navigateur (~5 Mo) : l'écriture levait une QuotaExceededError qui
  /// remontait jusqu'à `syncError` (« Sync partielle — contenus »). Le cache
  /// est un simple accélérateur : ne pas le persister n'empêche pas la sync
  /// (la prochaine session refait une full sync — garantie par le marqueur
  /// [_kContentsComplete], lu par [contentsCacheComplete]).
  static const int _maxContentsCacheBytes = 3500000;

  /// Vrai si le cache contenus persisté est complet : seul cas où un curseur
  /// `contents` persisté peut servir à une synchro incrémentale au démarrage.
  bool get contentsCacheComplete =>
      browserLocalStorage[_kContentsComplete] == 'true';

  /// Pose le marqueur de cache complet. Appelé par la synchro des contenus
  /// JUSTE APRÈS un [saveContents] réussi de sa liste complète (jamais par un
  /// autre enregistrement : une liste partielle — ex. purge des données de
  /// démo au démarrage, cache absent — ne doit pas passer pour complète).
  void markContentsComplete() {
    try {
      browserLocalStorage[_kContentsComplete] = 'true';
    } catch (_) {
      // Quota plein : sans marqueur, la session suivante refait une synchro
      // complète (sûr).
    }
  }

  /// Persiste le catalogue contenus, de façon TOLÉRANTE : si la sérialisation
  /// dépasse ~3,5 Mo, on n'écrit rien ; si le navigateur refuse l'écriture
  /// (QuotaExceededError ou autre), on avale l'erreur. Ne lève JAMAIS. Rend
  /// true si le cache est persisté ; sinon le marqueur ET l'ancien cache
  /// (périmé, et qui occupe le quota) sont retirés. Ne pose JAMAIS le
  /// marqueur (voir [markContentsComplete]).
  bool saveContents(List<Content> contents) {
    final String json =
        jsonEncode(contents.map((c) => c.toJson()).toList());
    if (json.length > maxContentsCacheBytes) {
      debugPrint(
        '[Store] cache contenus non persisté (trop volumineux : '
        '${json.length} caractères > $maxContentsCacheBytes) — la prochaine '
        'session refera une synchronisation complète.',
      );
      _oublierCacheContenus();
      return false;
    }
    try {
      browserLocalStorage[_kContents] = json;
      return true;
    } catch (e) {
      // QuotaExceededError (localStorage plein) ou refus du navigateur :
      // non bloquant, le cache sera simplement absent au prochain démarrage.
      debugPrint('[Store] cache contenus non persisté (quota) : $e');
      _oublierCacheContenus();
      return false;
    }
  }

  /// Retire le marqueur et l'ancien cache contenus (jamais d'exception).
  void _oublierCacheContenus() {
    try {
      browserLocalStorage.remove(_kContentsComplete);
      browserLocalStorage.remove(_kContents);
    } catch (_) {
      // Stockage indisponible : rien à retirer.
    }
  }

  // ---------- Suggestions ----------
  List<Suggestion> loadSuggestions() =>
      _loadList(_kSuggestions, Suggestion.fromJson);
  void saveSuggestions(List<Suggestion> suggestions) =>
      _saveList(_kSuggestions, suggestions.map((s) => s.toJson()).toList());

  // ---------- Comptes bannis ----------
  List<BannedUser> loadBanned() => _loadList(_kBanned, BannedUser.fromJson);
  void saveBanned(List<BannedUser> banned) =>
      _saveList(_kBanned, banned.map((b) => b.toJson()).toList());

  /// Efface la liste des bannis mise en cache (production : jamais de cache
  /// de ces textes de tiers — revue P4b-3, SEC-P4b3-01).
  void clearBanned() => browserLocalStorage.remove(_kBanned);

  // ---------- Utilisateurs Plus ----------
  // MODE APERÇU LOCAL uniquement : en production, la liste des abonnés n'est
  // jamais persistée (pagination serveur — migration 0085).
  List<PlusUser> loadPlus() => _loadList(_kPlus, PlusUser.fromJson);
  void savePlus(List<PlusUser> plus) =>
      _saveList(_kPlus, plus.map((n) => n.toJson()).toList());

  /// Efface la liste d'abonnés mise en cache par les versions précédentes du
  /// panneau (production — données réelles, périmées).
  void clearPlus() => browserLocalStorage.remove(_kPlus);

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
    final String? raw = browserLocalStorage['$_kCursorPrefix$name'];
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
    browserLocalStorage['$_kCursorPrefix$name'] = jsonEncode(<String, String>{
      'v': value,
      'at': fetchedAt.toUtc().toIso8601String(),
    });
  }

  /// Efface le curseur du dataset [name] (force une full sync au prochain
  /// chargement).
  void clearCursor(String name) {
    browserLocalStorage.remove('$_kCursorPrefix$name');
  }

  // ---------- Helpers ----------
  List<T> _loadList<T>(String key, T Function(Map<String, dynamic>) fromJson) {
    final String? raw = browserLocalStorage[key];
    if (raw == null || raw.isEmpty) return <T>[];
    final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => fromJson(e as Map<String, dynamic>)).toList();
  }

  void _saveList(String key, List<Map<String, dynamic>> data) {
    browserLocalStorage[key] = jsonEncode(data);
  }
}
