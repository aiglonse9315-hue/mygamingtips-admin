// Stockage clé → texte persistant du panneau (P4b-3, revue TST-01).
//
// Web (le panneau) : `window.localStorage` du navigateur. VM
// (`flutter test`) : une table EN MÉMOIRE, vide au lancement. L'import
// conditionnel isole `dart:html` dans `local_storage_web.dart` : `Store`
// (et donc `StoreController`) n'importent plus `dart:html` et se testent en
// VM. Le comportement web est inchangé (mêmes clés, mêmes valeurs).
export 'local_storage_memory.dart'
    if (dart.library.html) 'local_storage_web.dart';
