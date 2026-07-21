import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/colors.dart';
import '../../domain/models/plus_user.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_data_table.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/stat_card.dart' show StatusBadge;
import 'dashboard_screen.dart' show AddPlusUserDialog;

/// Gestion des abonnements Plus : tableau complet avec filtres et bannissement.
class AbonnementsScreen extends StatefulWidget {
  const AbonnementsScreen({super.key});

  @override
  State<AbonnementsScreen> createState() => _AbonnementsScreenState();
}

class _AbonnementsScreenState extends State<AbonnementsScreen> {
  String _search = '';
  final TextEditingController _searchCtrl = TextEditingController();
  String? _sourceFilter; // null = tous, 'google', 'admin'
  String? _statusFilter; // null = tous, 'active', 'expired'

  // Tri
  int? _sortColumnIndex;
  bool _sortAscending = true;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.watch<StoreController>();
    List<PlusUser> list = List.from(store.plus);

    // Filtre source.
    if (_sourceFilter == 'google') {
      list = list.where((u) => u.isGoogle).toList();
    } else if (_sourceFilter == 'admin') {
      list = list.where((u) => !u.isGoogle).toList();
    }

    // Filtre statut.
    if (_statusFilter == 'active') {
      list = list.where((u) => u.active).toList();
    } else if (_statusFilter == 'expired') {
      list = list.where((u) => !u.active).toList();
    }

    // Recherche.
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list
          .where((u) =>
              u.displayName.toLowerCase().contains(q) ||
              (u.email?.toLowerCase().contains(q) ?? false) ||
              u.id.toLowerCase().contains(q))
          .toList();
    }

    // Tri.
    _applySort(list);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Abonnements Plus',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              FilledButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AddPlusUserDialog(),
                ),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Ajouter'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${store.activePlusCount} actif(s) • ${list.length} affiché(s) sur ${store.plus.length} au total',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
          const SizedBox(height: 16),
          // Recherche.
          TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _search = v),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Rechercher un abonné…',
              prefixIcon: const Icon(Icons.search_rounded),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 16),
          // Filtres.
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _FilterChip(
                label: 'Source',
                value: _sourceFilter == null
                    ? 'Tous'
                    : _sourceFilter == 'google'
                        ? 'Google'
                        : 'Manuel',
                items: const ['Google', 'Manuel'],
                values: const ['google', 'admin'],
                selectedValue: _sourceFilter,
                onChanged: (v) => setState(() => _sourceFilter = v),
              ),
              _FilterChip(
                label: 'Statut',
                value: _statusFilter == null
                    ? 'Tous'
                    : _statusFilter == 'active'
                        ? 'Actif'
                        : 'Expiré',
                items: const ['Actif', 'Expiré'],
                values: const ['active', 'expired'],
                selectedValue: _statusFilter,
                onChanged: (v) => setState(() => _statusFilter = v),
              ),
            ],
          ),
          const SizedBox(height: 16),
          AdminDataTable(
            columns: const [
              'Utilisateur',
              'Email',
              'Formule',
              'Source',
              'Statut',
              'Début',
              'Actions'
            ],
            sortColumnIndex: _sortColumnIndex,
            sortAscending: _sortAscending,
            nonSortableColumns: const ['Email', 'Actions'],
            onSort: (colIdx) {
              setState(() {
                if (_sortColumnIndex == colIdx) {
                  _sortAscending = !_sortAscending;
                } else {
                  _sortColumnIndex = colIdx;
                  _sortAscending = true;
                }
              });
            },
            rows: list
                .map((u) => [
                      // Utilisateur (pseudo + UID tronqué — l'abonnement est
                      // lié à l'UID Supabase, le pseudo peut changer).
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(u.displayName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 13)),
                          Text(
                            u.id.length > 8
                                ? '${u.id.substring(0, 8)}…'
                                : u.id,
                            style: const TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                                fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                      // Email.
                      Text(u.email ?? '—',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color)),
                      // Formule (badge).
                      _PlanBadge(plan: u.plan),
                      // Source (badge).
                      _SourceBadge(isGoogle: u.isGoogle, isVerified: u.isVerified),
                      // Statut.
                      u.active
                          ? const StatusBadge(label: 'Actif', color: Colors.green)
                          : const StatusBadge(
                              label: 'Expiré', color: Colors.grey),
                      // Début.
                      Text(_formatDate(u.startedAt),
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color)),
                      // Actions.
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Suspendre / Réactiver.
                          IconButton(
                            tooltip: u.active ? 'Suspendre' : 'Réactiver',
                            icon: Icon(
                              u.active
                                  ? Icons.pause_circle_outline_rounded
                                  : Icons.play_circle_outline_rounded,
                              size: 20,
                              color: u.active
                                  ? AppColors.plusGold
                                  : Colors.green,
                            ),
                            onPressed: () => store.togglePlusUser(u),
                          ),
                          // Changer formule (sauf Google).
                          if (!u.isGoogle)
                            PopupMenuButton<String>(
                              tooltip: 'Changer la formule',
                              icon: const Icon(Icons.swap_horiz_rounded,
                                  size: 20),
                              onSelected: (plan) => store.setPlusPlan(u, plan),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'monthly', child: Text('Mensuel')),
                                PopupMenuItem(
                                    value: 'yearly', child: Text('Annuel')),
                              ],
                            ),
                          // Bannir.
                          IconButton(
                            tooltip: 'Bannir',
                            icon: const Icon(Icons.block_rounded,
                                size: 20, color: Colors.red),
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => ConfirmDialog(
                                title: 'Bannir ${u.displayName} ?',
                                message:
                                    'Cet utilisateur ne pourra plus soumettre '
                                    'de suggestions dans l\'application.',
                                confirmLabel: 'Bannir',
                                destructive: true,
                                onConfirm: () {
                                  store.banAuthorId(u.id,
                                      displayName: u.displayName);
                                },
                              ),
                            ),
                          ),
                          // Supprimer.
                          IconButton(
                            tooltip: 'Supprimer',
                            icon: const Icon(Icons.delete_outline_rounded,
                                size: 20, color: AppColors.categoryVideo),
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => ConfirmDialog(
                                title: 'Supprimer ${u.displayName} ?',
                                message:
                                    'L\'abonnement sera retiré de la liste '
                                    'et désactivé côté serveur.',
                                confirmLabel: 'Supprimer',
                                destructive: true,
                                onConfirm: () => store.deletePlusUser(u.id),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ])
                .toList(),
          ),
        ],
      ),
    );
  }

  void _applySort(List<PlusUser> list) {
    if (_sortColumnIndex == null) {
      list.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      return;
    }
    int compare(PlusUser a, PlusUser b) {
      int cmp;
      switch (_sortColumnIndex) {
        case 0: // Utilisateur
          cmp = a.displayName
              .toLowerCase()
              .compareTo(b.displayName.toLowerCase());
          break;
        case 2: // Formule
          cmp = a.plan.compareTo(b.plan);
          break;
        case 3: // Source
          cmp = a.source.compareTo(b.source);
          break;
        case 4: // Statut
          cmp = (a.active ? 1 : 0).compareTo(b.active ? 1 : 0);
          break;
        case 5: // Début
          cmp = a.startedAt.compareTo(b.startedAt);
          break;
        default:
          cmp = 0;
      }
      return _sortAscending ? cmp : -cmp;
    }

    list.sort(compare);
  }

  static String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// Badge coloré pour la formule (Mensuel / Annuel).
class _PlanBadge extends StatelessWidget {
  const _PlanBadge({required this.plan});
  final String plan;

  @override
  Widget build(BuildContext context) {
    final bool isYearly = plan == 'yearly';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: (isYearly ? AppColors.plusGold : AppColors.plus)
            .withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isYearly ? 'Annuel' : 'Mensuel',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: isYearly ? AppColors.plusGold : AppColors.plus,
        ),
      ),
    );
  }
}

/// Badge coloré pour la source (Google vérifié / Google / Manuel).
class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.isGoogle, this.isVerified = false});
  final bool isGoogle;

  /// `true` = abonnement vérifié côté serveur auprès de Google Play
  /// (source `google_verified`, Phase 4.1) : badge distinct "Google ✓".
  final bool isVerified;

  @override
  Widget build(BuildContext context) {
    final Color color = isGoogle ? Colors.green : Colors.blue;
    final String label =
        isVerified ? 'Google ✓' : (isGoogle ? 'Google' : 'Manuel');
    final IconData icon = isVerified
        ? Icons.verified_rounded
        : (isGoogle ? Icons.shopping_cart_rounded : Icons.person_rounded);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Menu déroulant de filtre (identique à contents_screen.dart).
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.value,
    required this.items,
    required this.values,
    required this.selectedValue,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> items;
  final List<String> values;
  final String? selectedValue;
  final ValueChanged<String?> onChanged;

  static const String _allValue = '__all__';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).canvasColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label : ',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                  fontWeight: FontWeight.w700)),
          PopupMenuButton<String>(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(value,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
                const Icon(Icons.arrow_drop_down_rounded, size: 18),
              ],
            ),
            onSelected: (v) {
              onChanged(v == _allValue ? null : v);
            },
            itemBuilder: (_) => [
              const PopupMenuItem<String>(
                  value: _allValue, child: Text('Tous')),
              ...List.generate(
                  items.length,
                  (i) =>
                      PopupMenuItem(value: values[i], child: Text(items[i]))),
            ],
          ),
        ],
      ),
    );
  }
}
