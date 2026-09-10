import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/theme/colors.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_sidebar.dart';
import '../widgets/admin_topbar.dart';
import '../widgets/confirm_dialog.dart';
import 'abonnements_screen.dart';
import 'banned_screen.dart';
import 'contents_screen.dart';
import 'contributors_screen.dart';
import 'dashboard_screen.dart';
import 'games_screen.dart';
import 'limites_screen.dart';
import 'login_screen.dart';
import 'sentinelle_screen.dart';
import 'scruteur_screen.dart';
import 'suggestions_screen.dart';

/// Shell du panneau admin : sidebar + topbar + contenu (route courante).
///
/// Gère la navigation entre les 4 sections et le garde d'authentification :
/// si l'utilisateur n'est pas connecté, on affiche l'écran de login.
class AdminShell extends StatefulWidget {
  const AdminShell({super.key});

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  String _route = '/dashboard';
  bool _loadingAfterLogin = false;

  static const List<NavItem> _items = [
    NavItem('Dashboard', Icons.dashboard_rounded, '/dashboard'),
    NavItem('Jeux', Icons.sports_esports_rounded, '/games'),
    NavItem('Contenus', Icons.collections_bookmark_rounded, '/contents'),
    NavItem('Suggestions', Icons.inbox_rounded, '/suggestions'),
    NavItem('Sentinelle', Icons.smart_toy_rounded, '/sentinelle'),
    NavItem('Scruteur', Icons.travel_explore_rounded, '/scruteur'),
    NavItem('Abonnements', Icons.card_membership_rounded, '/abonnements'),
    NavItem('Contributeurs', Icons.groups_rounded, '/contributors'),
    NavItem('Comptes à bannir', Icons.block_rounded, '/banned'),
    NavItem('Limite', Icons.data_usage_rounded, '/limites'),
  ];

  @override
  void initState() {
    super.initState();
    // Écoute les erreurs d'action (ajout/suppression) pour afficher un snackbar.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final store = context.read<StoreController>();
      store.addListener(_onStoreChanged);
      // Connexion du callback de logout auto sur 401 (token expiré).
      store.onAuthError = _onAuthError;
      // Connexion du sliding session : rafraîchit le token après chaque écriture.
      store.onTokenRefreshed = (freshToken) {
        context.read<AuthController>().refreshToken(freshToken);
      };
    });
  }

  @override
  void dispose() {
    // Retire le listener proprement (store peut être déjà disposé en tests).
    try {
      final store = context.read<StoreController>();
      store.removeListener(_onStoreChanged);
      store.onAuthError = null;
      store.onTokenRefreshed = null;
    } catch (_) {}
    super.dispose();
  }

  String? _lastSeenActionError;

  void _onStoreChanged() {
    final store = context.read<StoreController>();
    final err = store.lastActionError;
    if (err != null && err != _lastSeenActionError && mounted) {
      _lastSeenActionError = err;
      // Efface l'erreur côté contrôleur (le snackbar suffit).
      store.clearActionError();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'OK',
            textColor: Colors.white,
            onPressed: () {},
          ),
        ),
      );
    }
  }

  /// Appelé quand une écriture reçoit un 401 (token admin expiré/invalide).
  /// Force le logout et notifie l'utilisateur.
  void _onAuthError() {
    if (!mounted) return;
    final auth = context.read<AuthController>();
    auth.logout();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Session expirée. Veuillez vous reconnecter.'),
        backgroundColor: Colors.orange.shade700,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  String get _title {
    return _items.firstWhere((i) => i.route == _route).label;
  }

  /// Datasets alimentant le menu courant (badge de fraîcheur). Doit refléter
  /// les besoins déclarés dans [_buildContent]. `null` pour les écrans sans
  /// dataset synchronisé (Contributeurs, Limite) → pas de badge.
  static Set<SyncDataset>? _datasetsForRoute(String route) => switch (route) {
    '/dashboard' => StoreController.dashboardDatasets,
    '/games' => const {SyncDataset.games},
    '/contents' => const {SyncDataset.contents, SyncDataset.games},
    '/suggestions' => const {SyncDataset.suggestionsNew, SyncDataset.games},
    '/sentinelle' => const {
      SyncDataset.sentinelleAnalyzing,
      SyncDataset.sentinelleAnalyzed,
      SyncDataset.gamesToCreate,
      SyncDataset.games,
    },
    '/scruteur' => const {SyncDataset.scruteur, SyncDataset.games},
    '/abonnements' => const {SyncDataset.subscriptions},
    '/banned' => const {SyncDataset.banned},
    _ => null,
  };

  Widget _buildContent() {
    // Chargement paresseux : chaque écran est enveloppé dans un
    // [_DatasetGate] qui déclare ses besoins au montage — seuls les
    // datasets requis et pas encore chargés sont fetchés.
    switch (_route) {
      case '/dashboard':
        return _DatasetGate(
          datasets: StoreController.dashboardDatasets,
          child: DashboardScreen(onOpenSuggestions: () => _go('/suggestions')),
        );
      case '/games':
        return const _DatasetGate(
          datasets: {SyncDataset.games},
          child: GamesScreen(),
        );
      case '/contents':
        return const _DatasetGate(
          datasets: {SyncDataset.contents, SyncDataset.games},
          child: ContentsScreen(),
        );
      case '/suggestions':
        return const _DatasetGate(
          datasets: {SyncDataset.suggestionsNew, SyncDataset.games},
          child: SuggestionsScreen(),
        );
      case '/sentinelle':
        return const _DatasetGate(
          datasets: {
            SyncDataset.sentinelleAnalyzing,
            SyncDataset.sentinelleAnalyzed,
            SyncDataset.gamesToCreate,
            SyncDataset.games,
          },
          child: SentinelleScreen(),
        );
      case '/scruteur':
        return const _DatasetGate(
          datasets: {SyncDataset.scruteur, SyncDataset.games},
          child: ScruteurScreen(),
        );
      case '/abonnements':
        return const _DatasetGate(
          datasets: {SyncDataset.subscriptions},
          child: AbonnementsScreen(),
        );
      case '/contributors':
        return const ContributorsScreen();
      case '/banned':
        return const _DatasetGate(
          datasets: {SyncDataset.banned},
          child: BannedScreen(),
        );
      case '/limites':
        return const LimitesScreen();
      default:
        return _DatasetGate(
          datasets: StoreController.dashboardDatasets,
          child: DashboardScreen(onOpenSuggestions: () => _go('/suggestions')),
        );
    }
  }

  void _go(String route) => setState(() => _route = route);

  /// Charge les datasets du dashboard après login puis masque l'écran de
  /// chargement.
  ///
  /// Garantit que les données locales sont synchronisées avec le serveur AVANT
  /// que l'admin ne voie le dashboard (évite les données obsolètes du cache).
  /// Chargement paresseux : seuls les datasets du dashboard sont fetchés ici ;
  /// les autres menus chargent les leurs à l'ouverture.
  Future<void> _doPostLoginRefresh(
    StoreController store,
    AuthController auth,
  ) async {
    // Pousse le token pour autoriser les écritures.
    store.updateAdminToken(auth.token);
    // Charge les datasets du dashboard (paresseux : skip si déjà chargés).
    // Les menus lourds chargent leurs datasets à l'ouverture.
    await store.ensureDatasets(StoreController.dashboardDatasets);
    // Masque l'écran de chargement.
    if (mounted) setState(() => _loadingAfterLogin = false);
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth = context.watch<AuthController>();
    final StoreController store = context.read<StoreController>();

    // Garde d'authentification.
    if (!auth.isAuthenticated) {
      // Au logout : on purge le token admin côté sync pour bloquer les écritures.
      if (store.sync != null) {
        store.updateAdminToken(null);
      }
      _loadingAfterLogin = false;
      return LoginScreen(
        onSuccess: () {
          // Après un login réussi : force un refresh complet avant d'afficher
          // le dashboard. On affiche un écran de chargement pendant ce temps.
          setState(() => _loadingAfterLogin = true);
          _doPostLoginRefresh(store, auth);
        },
      );
    }

    // Écran de chargement pendant le refresh post-login.
    if (_loadingAfterLogin) {
      return const _LoadingScreen();
    }

    // Au login : on pousse le jeton admin vers le StoreController pour
    // autoriser les écritures Supabase (post-frame pour éviter un rebuild
    // pendant le build).
    if (store.sync != null && auth.token != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        store.updateAdminToken(auth.token);
      });
    }

    return Scaffold(
      body: Row(
        children: [
          AdminSidebar(items: _items, current: _route, onSelected: _go),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AdminTopbar(
                  title: _title,
                  showReset: store.sync == null,
                  onRefresh: store.sync != null ? () => store.refresh() : null,
                  isSyncing: store.isSyncing,
                  syncError: store.syncError,
                  onDismissError: () => store.clearSyncError(),
                  titleTrailing:
                      store.sync != null && _datasetsForRoute(_route) != null
                      ? _FreshnessBadge(datasets: _datasetsForRoute(_route)!)
                      : null,
                  statusBadge: store.sync != null
                      ? const _OfflineBadge()
                      : null,
                  onReset: () => showDialog<void>(
                    context: context,
                    builder: (_) => ConfirmDialog(
                      title: 'Réinitialiser les données de démo ?',
                      message:
                          'Toutes vos modifications (jeux, contenus, '
                          'suggestions) seront effacées et remplacées par '
                          'les données initiales.',
                      confirmLabel: 'Réinitialiser',
                      destructive: true,
                      onConfirm: () =>
                          context.read<StoreController>().resetDemo(),
                    ),
                  ),
                  onLogout: () => auth.logout(),
                ),
                Expanded(
                  child: Container(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: _buildContent(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Écran de chargement affiché pendant le refresh post-login.
///
/// Garantit que les données sont synchronisées avec le serveur avant que
/// l'admin ne voie le dashboard, évitant les données obsolètes du cache
/// (ex: nouveau menu Sentinelle pas encore visible).
class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 20),
            Text(
              'Synchronisation des données…',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Déclare les besoins en données d'un écran (chargement paresseux).
///
/// Au montage, appelle [StoreController.ensureDatasets] : seuls les datasets
/// pas encore chargés dans la session sont fetchés depuis Supabase. Le widget
/// enfant s'affiche immédiatement avec le cache local ; les données fraîches
/// arrivent via le listener Provider (le spinner global de la topbar indique
/// la sync en cours).
class _DatasetGate extends StatefulWidget {
  const _DatasetGate({required this.datasets, required this.child});

  final Set<SyncDataset> datasets;
  final Widget child;

  @override
  State<_DatasetGate> createState() => _DatasetGateState();
}

class _DatasetGateState extends State<_DatasetGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<StoreController>().ensureDatasets(widget.datasets);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Badge de fraîcheur des données du menu courant (point coloré + texte).
///
/// - Vert « à jour » si la donnée la moins fraîche du menu a < 15 min.
/// - Orange « il y a X min / X h » au-delà.
/// - Gris « jamais » si un dataset du menu n'a pas encore été chargé.
///
/// Le texte vieillit tout seul : un [Timer] périodique de 60 s force un
/// rebuild léger (disposé proprement). Le widget écoute le [StoreController]
/// via Provider, donc il se met aussi à jour à chaque sync réussie.
class _FreshnessBadge extends StatefulWidget {
  const _FreshnessBadge({required this.datasets});

  final Set<SyncDataset> datasets;

  @override
  State<_FreshnessBadge> createState() => _FreshnessBadgeState();
}

class _FreshnessBadgeState extends State<_FreshnessBadge> {
  /// Seuil « à jour » : 15 minutes.
  static const Duration _freshThreshold = Duration(minutes: 15);

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {}); // le texte « il y a X min » vieillit
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.watch<StoreController>();
    final DateTime? lastSync = store.lastSyncFor(widget.datasets);

    final Color color;
    final String label;
    if (lastSync == null) {
      color = Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey;
      label = 'jamais';
    } else {
      final Duration age = DateTime.now().difference(lastSync);
      if (age < _freshThreshold) {
        color = AppColors.categoryGuide;
        label = 'à jour';
      } else {
        color = Colors.orange.shade700;
        final int minutes = age.inMinutes;
        label = minutes < 60
            ? 'il y a $minutes min'
            : 'il y a ${age.inHours} h';
      }
    }

    return Tooltip(
      message: 'Fraîcheur des données du menu (dernière synchronisation)',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Badge « Hors ligne — données du cache » (coin haut-droit de la topbar).
///
/// Visible UNIQUEMENT quand [StoreController.isOffline] est vrai (dernière
/// sync échouée sur erreur réseau). Discret mais visible (ambre).
class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge();

  @override
  Widget build(BuildContext context) {
    final bool isOffline = context.watch<StoreController>().isOffline;
    if (!isOffline) return const SizedBox.shrink();
    final Color amber = Colors.orange.shade700;
    return Tooltip(
      message:
          'Connexion au serveur impossible — les données affichées '
          'proviennent du cache local',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: amber.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: amber.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 14, color: amber),
            const SizedBox(width: 6),
            Text(
              'Hors ligne — données du cache',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: amber,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
