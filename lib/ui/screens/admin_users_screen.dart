import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/theme/colors.dart';
import '../../data/supabase_sync.dart';
import '../../domain/models/admin_user_account.dart';
import '../../state/store_controller.dart';
import '../widgets/confirm_dialog.dart';

/// Écran « Comptes » — gestion des comptes administrateurs, **réservé au
/// compte principal (owner)**.
///
/// Cas d'usage principal : « téléphone perdu » — désactiver un compte révoque
/// son accès IMMÉDIATEMENT (le serveur re-vérifie `active=true` en base à
/// chaque appel, cf. `verifyAdminToken`), y compris sur l'application mobile.
///
/// Les données viennent des routes Edge Function `admin-users/list` et
/// `admin-users/set-active`. La vraie sécurité est serveur (403 si le compte
/// n'est pas owner ; 400 si auto-désactivation ou dernier owner actif) : cet
/// écran ne fait qu'afficher les états chargement / erreur / 403 / vide /
/// données, et désactive le bouton sur le compte courant.
class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  List<AdminUserAccount> _users = <AdminUserAccount>[];

  bool _loading = false;
  bool _forbidden = false;
  String? _error;

  /// Username du compte en cours d'activation/désactivation (indicateur par
  /// ligne, une seule opération à la fois).
  String? _busyUsername;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Charge la liste des comptes via la route EF `admin-users/list`.
  Future<void> _load() async {
    final sync = context.read<StoreController>().sync;
    if (sync == null) {
      setState(() => _error = 'Mode démo : pas de connexion Supabase.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _forbidden = false;
    });
    try {
      final users = await sync.fetchAdminUsers();
      if (!mounted) return;
      setState(() {
        _users = users;
        _loading = false;
      });
    } on AdminForbiddenException {
      // 403 : compte non owner — le serveur a tranché, message dédié.
      if (!mounted) return;
      setState(() {
        _forbidden = true;
        _loading = false;
      });
    } on AdminAuthException {
      // 401 : session expirée → logout forcé (même règle que les écritures).
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _errorMessage(e);
        _loading = false;
      });
      // Si la liste est déjà affichée, elle reste visible : l'erreur de
      // rafraîchissement est signalée par SnackBar, pas en pleine page.
      if (_users.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Rafraîchissement échoué : ${_errorMessage(e)}'),
            backgroundColor: Colors.orange.shade700,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Demande confirmation puis active/désactive [user] via la route EF
  /// `admin-users/set-active`, puis recharge la liste.
  void _confirmToggle(AdminUserAccount user) {
    final bool disabling = user.active;
    showDialog<void>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: disabling
            ? 'Désactiver ${user.username} ?'
            : 'Réactiver ${user.username} ?',
        message: disabling
            ? 'L\'accès admin de ce compte sera révoqué immédiatement, '
                'y compris sur l\'application mobile.'
            : 'Ce compte retrouvera immédiatement son accès admin, '
                'y compris sur l\'application mobile.',
        confirmLabel: disabling ? 'Désactiver' : 'Réactiver',
        destructive: disabling,
        onConfirm: () => _toggle(user, active: !disabling),
      ),
    );
  }

  Future<void> _toggle(AdminUserAccount user, {required bool active}) async {
    final sync = context.read<StoreController>().sync;
    if (sync == null || _busyUsername != null) return;
    setState(() => _busyUsername = user.username);
    try {
      await sync.setAdminUserActive(user.username, active);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(active
              ? 'Compte ${user.username} réactivé.'
              : 'Compte ${user.username} désactivé — accès révoqué '
                  'immédiatement.'),
          duration: const Duration(seconds: 4),
        ),
      );
      await _load();
    } on AdminAuthException {
      if (!mounted) return;
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      // 400 métier (auto-désactivation, dernier owner actif) ou erreur
      // réseau : le message du serveur est affiché (sans préfixe technique).
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_errorMessage(e)),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyUsername = null);
    }
  }

  /// Extrait un message d'erreur lisible : retire le préfixe « Exception: »
  /// produit par le `toString()` des exceptions Dart.
  static String _errorMessage(Object e) {
    const prefix = 'Exception: ';
    final String msg = e.toString();
    return msg.startsWith(prefix) ? msg.substring(prefix.length) : msg;
  }

  static String _formatDate(DateTime? date) {
    if (date == null) return 'date inconnue';
    final d = date.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHelpCard(theme),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Rafraîchir'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  /// Encart d'aide « téléphone perdu » en tête d'écran.
  Widget _buildHelpCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.neonCyan.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.neonCyan.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.phonelink_erase_rounded,
              size: 20, color: AppColors.neonCyan),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Téléphone perdu ? Désactivez le compte concerné : son accès '
              'est révoqué immédiatement.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    // État 403 : réservé au compte principal.
    if (_forbidden) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded,
                size: 40, color: theme.textTheme.bodySmall?.color),
            const SizedBox(height: 12),
            Text('Réservé au compte principal.',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Accès réservé au compte principal. La gestion des comptes '
              'admin n\'est possible qu\'avec le compte propriétaire '
              '(contrôle appliqué côté serveur).',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    // État erreur (hors 403) — pleine page SEULEMENT s'il n'y a rien à
    // montrer ; sinon la liste reste visible (l'erreur a été signalée par
    // SnackBar au moment du rafraîchissement).
    if (_error != null && _users.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: Colors.orange.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 18, color: Colors.orange.shade300),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _error!,
                      style: TextStyle(color: Colors.orange.shade300),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      );
    }

    // État chargement initial (aucune donnée à montrer).
    if (_loading && _users.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }

    // État vide (ne devrait pas arriver : le compte courant existe).
    if (_users.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.manage_accounts_rounded,
                size: 40, color: theme.textTheme.bodySmall?.color),
            const SizedBox(height: 12),
            Text('Aucun compte administrateur.',
                style: theme.textTheme.titleMedium),
          ],
        ),
      );
    }

    // Liste des comptes (refresh par tirer + bouton en tête d'écran).
    final String? currentUsername =
        context.read<AuthController>().currentUsername;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _users.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) =>
            _buildUserCard(theme, _users[index], currentUsername),
      ),
    );
  }

  /// Carte d'un compte : username, badges « Principal » / Actif-Désactivé,
  /// date de création + créateur, bouton Activer/Désactiver.
  Widget _buildUserCard(
    ThemeData theme,
    AdminUserAccount user,
    String? currentUsername,
  ) {
    final bool isSelf =
        currentUsername != null && user.username == currentUsername;
    final bool busy = _busyUsername == user.username;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(
              user.isOwner
                  ? Icons.shield_rounded
                  : Icons.person_outline_rounded,
              size: 28,
              color: user.active
                  ? (user.isOwner
                      ? AppColors.neonViolet
                      : AppColors.neonCyan)
                  : theme.textTheme.bodySmall?.color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        user.username,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (user.isOwner)
                        _badge('Principal', AppColors.neonViolet),
                      _badge(
                        user.active ? 'Actif' : 'Désactivé',
                        user.active
                            ? AppColors.categoryGuide
                            : AppColors.categoryVideo,
                      ),
                      if (isSelf) _badge('Vous', AppColors.neonCyan),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Créé le ${_formatDate(user.createdAt)}'
                    '${user.createdBy != null ? ' · par ${user.createdBy}' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              OutlinedButton.icon(
                // Le bouton est désactivé sur son propre compte (le serveur
                // refuse aussi l'auto-désactivation — double garde).
                onPressed: isSelf ? null : () => _confirmToggle(user),
                icon: Icon(
                  user.active
                      ? Icons.block_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 16,
                ),
                label: Text(user.active ? 'Désactiver' : 'Activer'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: user.active
                      ? AppColors.categoryVideo
                      : AppColors.categoryGuide,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
