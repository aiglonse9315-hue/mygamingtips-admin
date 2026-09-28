// Implémentation VM de `local_storage.dart` (tests `flutter test`) : table en
// mémoire, propre au processus, vide au lancement. Jamais utilisée par le
// panneau publié (le web choisit `local_storage_web.dart`).
final Map<String, String> _memory = <String, String>{};

/// Stockage en mémoire (les tests le vident avec `clear()`).
Map<String, String> get browserLocalStorage => _memory;
