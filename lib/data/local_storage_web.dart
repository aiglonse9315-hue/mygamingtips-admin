// Implémentation WEB de `local_storage.dart` : le `localStorage` du
// navigateur (`Storage` est une `Map<String, String>`). Seul fichier de la
// couche de données qui importe `dart:html` (choisi par import conditionnel,
// jamais importé directement).
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

/// `window.localStorage` du navigateur.
Map<String, String> get browserLocalStorage => html.window.localStorage;
