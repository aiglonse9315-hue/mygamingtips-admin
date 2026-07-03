import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/auth/auth_controller.dart';
import 'core/auth/auth_service.dart';
import 'data/store.dart';
import 'data/supabase_sync.dart';
import 'state/store_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // NOTE : l'initialisation de Supabase au démarrage est désactivée pour le
  // panneau admin web car supabase_flutter provoque un crash "Null check
  // operator used on a null value" en environnement navigateur (incompatibilité
  // d'init JS). Le panneau admin fonctionne en mode aperçu local avec ses
  // données seed (localStorage) — pleinement utilisable pour la démo.
  // Le branchement Supabase de l'admin se fera via Edge Functions (service_role)
  // côté serveur lors du déploiement production (cf. GUIDE_DEPLOIEMENT.md §1.7bis).
  // Pour réactiver : décommenter les 2 lignes suivantes.
  // try {
  //   await AdminSupabaseConfig.init();
  // } catch (e) {
  //   print('Supabase init failed (mode démo local) : $e');
  // }

  // Chargement des données initiales (assets seed JSON).
  String gamesSeed;
  String contentsSeed;
  String suggestionsSeed;
  String bannedSeed;
  String plusSeed;
  try {
    gamesSeed = await rootBundle.loadString('assets/seed/games.json');
    contentsSeed = await rootBundle.loadString('assets/seed/contents.json');
    suggestionsSeed = await rootBundle.loadString('assets/seed/suggestions.json');
    bannedSeed = await rootBundle.loadString('assets/seed/banned.json');
    try {
      plusSeed = await rootBundle.loadString('assets/seed/plus_users.json');
    } catch (_) {
      plusSeed = '[]';
    }
  } catch (e) {
    // ignore: avoid_print
    print('Seed load failed : $e');
    gamesSeed = '[]';
    contentsSeed = '[]';
    suggestionsSeed = '[]';
    bannedSeed = '[]';
    plusSeed = '[]';
  }

  final Store store = Store(
    gamesSeed: gamesSeed,
    contentsSeed: contentsSeed,
    suggestionsSeed: suggestionsSeed,
    bannedSeed: bannedSeed,
    plusSeed: plusSeed,
  );

  // --- Branchement Supabase (mode production) ---
  // Si les variables de build sont présentes, on active la synchronisation
  // Supabase : les lectures se font via PostgREST (anon key suffit grâce aux
  // politiques RLS publiques), les écritures via l'Edge Function admin-catalog
  // (service_role, token admin fourni après login). Sinon, mode aperçu local.
  final String supabaseUrl =
      const String.fromEnvironment('MGT_SUPABASE_URL');
  final String supabaseAnonKey =
      const String.fromEnvironment('MGT_SUPABASE_ANON_KEY');
  final String catalogEndpoint =
      const String.fromEnvironment('MGT_ADMIN_CATALOG_ENDPOINT');
  SupabaseSync? supabaseSync;
  if (supabaseUrl.isNotEmpty &&
      supabaseAnonKey.isNotEmpty &&
      catalogEndpoint.isNotEmpty) {
    supabaseSync = SupabaseSync(
      supabaseUrl: supabaseUrl,
      anonKey: supabaseAnonKey,
      catalogEndpoint: catalogEndpoint,
      // Le token admin est mis à jour dynamiquement après login (cf. plus bas).
      adminToken: '',
    );
  }

  // Service d'authentification admin : l'endpoint de vérification est fourni
  // via la variable de build MGT_ADMIN_AUTH_ENDPOINT (cf. auth_service.dart et
  // GUIDE_DEPLOIEMENT.md). Aucun identifiant n'est embarqué côté client.
  // En cas d'absence, l'app démarre mais la connexion échouera avec un message
  // explicite (configuration serveur requise).
  AuthService authService;
  try {
    authService = AuthService();
  } catch (_) {
    // Endpoint non configuré : on passe un endpoint vide ; le login renverra
    // un message « configuration serveur requise » côté UI.
    authService = AuthService(endpoint: '');
  }

  final StoreController storeController =
      StoreController(store, sync: supabaseSync);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthController>(
          create: (_) => AuthController(authService)..restore(),
        ),
        ChangeNotifierProvider<StoreController>.value(
          value: storeController,
        ),
      ],
      child: const MgtAdminApp(),
    ),
  );
}
