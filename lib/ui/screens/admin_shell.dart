import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_controller.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_sidebar.dart';
import '../widgets/admin_topbar.dart';
import '../widgets/confirm_dialog.dart';
import 'contents_screen.dart';
import 'contributors_screen.dart';
import 'dashboard_screen.dart';
import 'games_screen.dart';
import 'login_screen.dart';
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

  static const List<NavItem> _items = [
    NavItem('Dashboard', Icons.dashboard_rounded, '/dashboard'),
    NavItem('Jeux', Icons.sports_esports_rounded, '/games'),
    NavItem('Contenus', Icons.collections_bookmark_rounded, '/contents'),
    NavItem('Suggestions', Icons.inbox_rounded, '/suggestions'),
    NavItem('Contributeurs', Icons.groups_rounded, '/contributors'),
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
    });
  }

  @override
  void dispose() {
    // Retire le listener proprement (store peut être déjà disposé en tests).
    try {
      final store = context.read<StoreController>();
      store.removeListener(_onStoreChanged);
      store.onAuthError = null;
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

  Widget _buildContent() {
    switch (_route) {
      case '/dashboard':
        return DashboardScreen(onOpenSuggestions: () => _go('/suggestions'));
      case '/games':
        return const GamesScreen();
      case '/contents':
        return const ContentsScreen();
      case '/suggestions':
        return const SuggestionsScreen();
      case '/contributors':
        return const ContributorsScreen();
      default:
        return DashboardScreen(onOpenSuggestions: () => _go('/suggestions'));
    }
  }

  void _go(String route) => setState(() => _route = route);

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
      return LoginScreen(onSuccess: () => setState(() {}));
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
          AdminSidebar(
            items: _items,
            current: _route,
            onSelected: _go,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AdminTopbar(
                  title: _title,
                  showReset: store.sync == null,
                  onRefresh:
                      store.sync != null ? () => store.refresh() : null,
                  isSyncing: store.isSyncing,
                  syncError: store.syncError,
                  onDismissError: () => store.clearSyncError(),
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
