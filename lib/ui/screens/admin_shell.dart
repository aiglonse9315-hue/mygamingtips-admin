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
import 'admin_users_screen.dart';
import 'analytics_screen.dart';
import 'banned_screen.dart';
import 'contents_screen.dart';
import 'contributors_screen.dart';
import 'dashboard_screen.dart';
import 'games_screen.dart';
import 'limites_screen.dart';
import 'login_screen.dart';
import 'logs_screen.dart';
import 'sentinelle_screen.dart';
import 'scruteur_screen.dart';
import 'suggestions_screen.dart';
import 'trusted_channels_screen.dart';

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
    NavItem('Chaînes YT', Icons.video_library_outlined, '/channels'),
    NavItem('Contenus', Icons.collections_bookmark_rounded, '/contents'),
    NavItem('Suggestions', Icons.inbox_rounded, '/suggestions'),
    NavItem('Sentinelle', Icons.smart_toy_rounded, '/sentinelle'),
    NavItem('Scruteur', Icons.travel_explore_rounded, '/scruteur'),
    NavItem('Abonnements', Icons.card_membership_rounded, '/abonnements'),
    NavItem('Analytics', Icons.bar_chart_rounded, '/analytics'),
    NavItem('Contributeurs', Icons.groups_rounded, '/contributors'),
    NavItem('Comptes à bannir', Icons.block_rounded, '/banned'),
    NavItem('Limite', Icons.data_usage_rounded, '/limites'),
  ];

  /// Menu « Log » — réservé au compte principal (owner). L'entrée n'existe
  /// pas du tout dans la navigation pour les autres comptes (le serveur
  /// applique la vraie sécurité : 403 sur `logs/list` sinon).
  static const NavItem _logsItem =
      NavItem('Log', Icons.receipt_long_rounded, '/logs');

  /// Menu « Comptes » — réservé au compte principal (owner), même règle que
  /// [_logsItem] (le serveur applique la vraie sécurité : 403 sur
  /// `admin-users/*` sinon). Gestion de la révocation « téléphone perdu ».
  static const NavItem _comptesItem =
      NavItem('Comptes', Icons.manage_accounts_rounded, '/comptes');

  /// Items de navigation effectifs : [_items] + « Log » et « Comptes » si (et
  /// seulement si) la session courante est owner.
  static List<NavItem> _navItems({required bool isOwner}) =>
      isOwner ? [..._items, _logsItem, _comptesItem] : _items;

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
  String? _lastSeenActionNotice;

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
    // D3.4 — notice d'action (avertissement LÉGER, orange) : ex. alias
    // candidat non créé après une validation réussie. Distincte de l'erreur
    // rouge : l'opération principale a abouti.
    final notice = store.lastActionNotice;
    if (notice != null && notice != _lastSeenActionNotice && mounted) {
      _lastSeenActionNotice = notice;
      store.clearActionNotice();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(notice),
          backgroundColor: Colors.orange.shade800,
          duration: const Duration(seconds: 6),
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

  String _titleFor(List<NavItem> items) {
    return items.firstWhere((i) => i.route == _route).label;
  }

  /// Datasets alimentant le menu courant (badge de fraîcheur). Doit refléter
  /// les besoins déclarés dans [_buildContent]. `null` pour les écrans sans
  /// dataset synchronisé (Contributeurs, Limite, Abonnements — pagination
  /// serveur, toujours à jour) → pas de badge.
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
          child: DashboardScreen(
            onOpenSuggestions: () => _go('/suggestions'),
            onOpenAbonnements: () => _go('/abonnements'),
          ),
        );
      case '/games':
        return const _DatasetGate(
          datasets: {SyncDataset.games},
          child: GamesScreen(),
        );
      case '/channels':
        // Fetch direct (pattern Contributeurs) : pas de _DatasetGate, pas de
        // dataset synchronisé → pas de badge de fraîcheur pour cette route.
        return const TrustedChannelsScreen();
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
        // Pagination SERVEUR (migration 0085) : l'écran charge lui-même sa
        // page de 100 abonnés — plus de chargement complet ni de _DatasetGate.
        return const AbonnementsScreen();
      case '/analytics':
        // Fetch direct (pattern Contributeurs/Limite) : pas de _DatasetGate,
        // AUCUN dataset synchronisé → ce menu ne déclenche PAS de full sync
        // du catalogue (agrégats calculés par l'EF v76, fraîcheur au clic).
        return const AnalyticsScreen();
      case '/contributors':
        return const ContributorsScreen();
      case '/banned':
        return const _DatasetGate(
          datasets: {SyncDataset.banned},
          child: BannedScreen(),
        );
      case '/limites':
        return const LimitesScreen();
      case '/logs':
        return const LogsScreen();
      case '/comptes':
        return const AdminUsersScreen();
      default:
        return _DatasetGate(
          datasets: StoreController.dashboardDatasets,
          child: DashboardScreen(
            onOpenSuggestions: () => _go('/suggestions'),
            onOpenAbonnements: () => _go('/abonnements'),
          ),
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

    // Menu dynamique : « Log » et « Comptes » n'existent que pour le compte
    // principal (owner). Garde-fou : si la route courante n'est plus dans le
    // menu (ex. logout d'un compte owner puis login d'un compte non owner
    // sur /logs ou /comptes), on rebascule sur le dashboard.
    final List<NavItem> items = _navItems(isOwner: auth.isOwner);
    if (!items.any((i) => i.route == _route)) {
      _route = '/dashboard';
    }

    return Scaffold(
      body: Row(
        children: [
          AdminSidebar(items: items, current: _route, onSelected: _go),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AdminTopbar(
                  title: _titleFor(items),
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
                  onSyncTotal: store.sync != null
                      ? () => store.requestTotalSync()
                      : null,
                  syncTotalBusy: store.syncTotalRequesting,
                  syncTotalBadge: store.sync != null
                      ? const _SyncTotalBadge()
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

/// Badge « Sync totale » de la topbar (chantier C — migration 0063) :
///  - 🟠 « Sync demandée à HH:MM — en attente de Vision » tant que la
///    demande « chaude » (< 24 h) n'a reçu AUCUN acquittement ;
///  - 🟢 « Sync effectuée (machine-id, HH:MM) » dès le premier ack —
///    masqué ~1 h après ;
///  - invisible sinon (aucune demande, ou demande expirée > 24 h).
/// Tooltip : machine complète + rapport (compteurs) si disponible.
///
/// Un [Timer] de 60 s force un rebuild léger (le masquage ~1 h / expiration
/// 24 h vieillit sans nouvel événement store) — disposé proprement.
class _SyncTotalBadge extends StatefulWidget {
  const _SyncTotalBadge();

  @override
  State<_SyncTotalBadge> createState() => _SyncTotalBadgeState();
}

class _SyncTotalBadgeState extends State<_SyncTotalBadge> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {}); // masquage ~1 h / 24 h vieillit seul
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  static String _hhmm(DateTime dt) {
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  /// Résumé compact du rapport posté par le bot (compteurs), pour tooltip.
  static String? _reportSummary(Map<String, dynamic>? report) {
    if (report == null) return null;
    int? asInt(Map<String, dynamic>? m, String key) {
      final v = m?[key];
      return v is num ? v.toInt() : null;
    }

    final aliases = report['aliases'];
    final channels = report['channels'];
    final translations = report['translations'];
    final errors = report['errors'];
    final a = aliases is Map<String, dynamic> ? aliases : null;
    final c = channels is Map<String, dynamic> ? channels : null;
    final t = translations is Map<String, dynamic> ? translations : null;
    final errCount = errors is List ? errors.length : 0;
    final parts = <String>[
      if (a != null)
        'alias : ${asInt(a, 'remote_loaded') ?? '?'} distants'
            ', +${asInt(a, 'const_added') ?? 0} const poussés',
      if (c != null)
        'chaînes : ${asInt(c, 'remote_loaded') ?? '?'} distantes'
            ', +${asInt(c, 'extras_pushed') ?? 0} extras poussés',
      if (t != null) 'traductions : ${asInt(t, 'games') ?? '?'} jeux',
      'erreurs : $errCount',
    ];
    return parts.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<StoreController>();
    final status = store.syncRequestPending;
    final req = status?.request;
    if (req == null) return const SizedBox.shrink();
    final acks = status!.acks;

    if (acks.isNotEmpty) {
      // 🟢 Ack reçu — affiché ~1 h puis masqué. (acks triés par acked_at
      // ascendant côté EF → le dernier est le plus récent.)
      final last = acks.last;
      if (DateTime.now().difference(last.ackedAt) >
          const Duration(hours: 1)) {
        return const SizedBox.shrink();
      }
      const color = AppColors.categoryGuide; // vert du thème
      final shortId = last.machineId.length > 8
          ? last.machineId.substring(0, 8)
          : last.machineId;
      final summary = _reportSummary(last.report);
      return Tooltip(
        message: 'Machine ${last.machineId}\n'
            'Acquittée à ${_hhmm(last.ackedAt)}'
            '${acks.length > 1 ? ' — ${acks.length} machine(s)' : ''}'
            '${summary != null ? '\n\nRapport :\n$summary' : ''}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_rounded, size: 14, color: color),
              const SizedBox(width: 6),
              Text(
                'Sync effectuée ($shortId, ${_hhmm(last.ackedAt)})',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 🟠 En attente : demande « chaude » (< 24 h) sans aucun ack.
    if (DateTime.now().difference(req.createdAt) >
        const Duration(hours: 24)) {
      return const SizedBox.shrink();
    }
    final color = Colors.orange.shade700;
    return Tooltip(
      message: 'Demande posée'
          '${req.requestedBy != null ? ' par ${req.requestedBy}' : ''} '
          'à ${_hhmm(req.createdAt)} — exécutée par Vision.exe au démarrage '
          '/ au prochain cycle (ou via son bouton « 🔄 Sync »), puis '
          'acquittée ici. Statut relu toutes les 60 s tant qu\'elle est '
          'sans ack.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hourglass_top_rounded, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              'Sync demandée à ${_hhmm(req.createdAt)} — en attente de Vision',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
