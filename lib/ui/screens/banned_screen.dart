// ============================================================================
// Menu Admin « Comptes à bannir » — Détection des mauvais contributeurs
// ============================================================================
// Affiche les contributeurs dont le taux de rejet est élevé (≥ 10%) afin
// d'aider l'admin à identifier les comptes à bannir en masse.
//
// Données : `bad-contributors/list` (Edge Function service_role) →
//   { author_id, display_name, rejected_count, accepted_count,
//     total_count, rejection_rate, is_premium }
//
// Fonctionnalités :
//   - Pagination 100/page (sublist locale, pattern contents_screen.dart)
//   - Tri cliquable sur la colonne « % Rejets » (pattern contents_screen.dart)
//   - Sélection multiple (pattern scruteur_screen.dart : Set<String>)
//   - « Bannir sélection » et « Bannir la page » via store.banBatch()
//   - Badge Premium doré « PLUS » si is_premium == true
//   - Filtre : rejection_rate >= 10.0
//   - Recherche par nom d'utilisateur (pattern games_screen.dart)
// ============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/colors.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_data_table.dart';
import '../widgets/confirm_dialog.dart';

/// Menu « Comptes à bannir » : détection des mauvais contributeurs.
class BannedScreen extends StatefulWidget {
  const BannedScreen({super.key});

  @override
  State<BannedScreen> createState() => _BannedScreenState();
}

class _BannedScreenState extends State<BannedScreen> {
  /// Seuil de taux de rejet en dessous duquel un contributeur n'est pas
  /// affiché (10% par défaut — conforme au cahier des charges).
  static const double _minRejectionRate = 10.0;

  // ── Recherche ──
  String _search = '';
  final TextEditingController _searchCtrl = TextEditingController();

  // ── Sélection multiple (pattern scruteur_screen.dart) ──
  final Set<String> _selected = <String>{};

  // ── Tri des colonnes (pattern contents_screen.dart) ──
  // Par défaut : tri sur « % Rejets » décroissant (colonne 3) → les pires
  // contributeurs en premier.
  int? _sortColumnIndex = 3;
  bool _sortAscending = false;

  // ── Pagination (pattern contents_screen.dart) ──
  int _currentPage = 0;
  static const int _pageSize = 100;

  bool _banning = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _toggleSelectAll(List<Map<String, dynamic>> pageRows) {
    setState(() {
      final allSelected =
          pageRows.isNotEmpty &&
          pageRows.every((r) => _selected.contains(r['author_id']));
      if (allSelected) {
        for (final r in pageRows) {
          _selected.remove(r['author_id']);
        }
      } else {
        for (final r in pageRows) {
          _selected.add(r['author_id'] as String);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final StoreController store = context.watch<StoreController>();

    // ── Filtre + recherche + tri ──
    List<Map<String, dynamic>> list = store.badContributors
        .where(
          (c) =>
              ((c['rejection_rate'] as num?)?.toDouble() ?? 0.0) >=
              _minRejectionRate,
        )
        .toList();

    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list
          .where(
            (c) =>
                (c['display_name'] as String? ?? '').toLowerCase().contains(
                  q,
                ) ||
                (c['author_id'] as String? ?? '').toLowerCase().contains(q),
          )
          .toList();
    }

    _applySort(list);

    // ── Pagination locale : découpe la liste filtrée+triée en pages de 100 ──
    final totalPages = (list.length / _pageSize).ceil();
    if (totalPages == 0) {
      _currentPage = 0;
    } else if (_currentPage >= totalPages) {
      _currentPage = totalPages - 1;
    }
    if (_currentPage < 0) _currentPage = 0;
    final startIndex = _currentPage * _pageSize;
    final endIndex = startIndex + _pageSize > list.length
        ? list.length
        : startIndex + _pageSize;
    final pageRows = startIndex >= list.length
        ? <Map<String, dynamic>>[]
        : list.sublist(startIndex, endIndex);

    // IDs de la page courante (pour « Bannir la page » et le statut du checkbox global).
    final pageIds = pageRows.map((r) => r['author_id'] as String).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // En-tête
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.block_rounded,
                  color: Colors.red,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Comptes à bannir',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${list.length} contributeur(s) avec ≥ ${_minRejectionRate.toStringAsFixed(0)}% de rejets. '
                      'Bannissez les comptes problématiques en masse.',
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Barre d'actions : recherche + boutons batch.
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() {
                    _search = v;
                    _currentPage = 0;
                  }),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Rechercher un contributeur…',
                    prefixIcon: const Icon(Icons.search_rounded),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Bannir la sélection.
              FilledButton.icon(
                onPressed: _selected.isEmpty || _banning
                    ? null
                    : () => _banSelection(store, _selected.toList()),
                icon: const Icon(Icons.block_rounded, size: 18),
                label: Text(
                  _selected.isEmpty
                      ? 'Bannir sélection'
                      : 'Bannir sélection (${_selected.length})',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              // Bannir la page courante.
              OutlinedButton.icon(
                onPressed: pageIds.isEmpty || _banning
                    ? null
                    : () => _banPage(store, pageIds),
                icon: const Icon(Icons.layers_rounded, size: 18),
                label: const Text('Bannir la page'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Ligne « Tout sélectionner » (sur la page courante) + pagination.
          if (list.isNotEmpty) ...[
            Row(
              children: [
                InkWell(
                  onTap: () => _toggleSelectAll(pageRows),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value:
                            pageRows.isNotEmpty &&
                            pageRows.every(
                              (r) => _selected.contains(r['author_id']),
                            ),
                        onChanged: (_) => _toggleSelectAll(pageRows),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      const Text(
                        'Tout sélectionner (page)',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (totalPages > 1) ...[
                  IconButton(
                    icon: const Icon(Icons.first_page_rounded),
                    onPressed: _currentPage > 0
                        ? () => setState(() => _currentPage = 0)
                        : null,
                    tooltip: 'Première page',
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: _currentPage > 0
                        ? () => setState(() => _currentPage--)
                        : null,
                    tooltip: 'Page précédente',
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Page ${_currentPage + 1} / $totalPages'
                    ' (${startIndex + 1}-$endIndex sur ${list.length})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: _currentPage < totalPages - 1
                        ? () => setState(() => _currentPage++)
                        : null,
                    tooltip: 'Page suivante',
                  ),
                  IconButton(
                    icon: const Icon(Icons.last_page_rounded),
                    onPressed: _currentPage < totalPages - 1
                        ? () => setState(() => _currentPage = totalPages - 1)
                        : null,
                    tooltip: 'Dernière page',
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
          ],

          // ── Tableau ──
          if (list.isEmpty)
            _EmptyHint(
              text: store.badContributors.isEmpty
                  ? 'Aucun mauvais contributeur détecté. '
                        'Lancez une synchronisation pour rafraîchir les données.'
                  : 'Aucun contributeur au-dessus du seuil de '
                        '${_minRejectionRate.toStringAsFixed(0)}% de rejets.',
            )
          else
            AdminDataTable(
              columns: const [
                '',
                'Utilisateur',
                'Total',
                'Rejets',
                '% Rejets',
                'Premium',
                'Actions',
              ],
              sortColumnIndex: _sortColumnIndex,
              sortAscending: _sortAscending,
              nonSortableColumns: const ['', 'Actions'],
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
              rows: pageRows.map((c) => _buildRow(store, c)).toList(),
            ),

          // Indicateur de traitement pendant le bannissement en masse.
          if (_banning) ...[
            const SizedBox(height: 16),
            const Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Bannissement en cours…',
                    style: TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
          ],

          if (store.lastActionError != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withValues(alpha: 0.4)),
              ),
              child: Text(
                '⚠️ ${store.lastActionError}',
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Construit une ligne du tableau pour un contributeur.
  List<Widget> _buildRow(StoreController store, Map<String, dynamic> c) {
    final authorId = c['author_id'] as String? ?? '';
    final displayName = c['display_name'] as String? ?? 'Inconnu';
    final total = c['total_count'] as int? ?? 0;
    final rejected = c['rejected_count'] as int? ?? 0;
    final rate = (c['rejection_rate'] as num?)?.toDouble() ?? 0.0;
    final isPremium = c['is_premium'] as bool? ?? false;
    final isBanned = store.isAuthorBanned(authorId);

    return <Widget>[
      // Checkbox de sélection.
      Checkbox(
        value: _selected.contains(authorId),
        onChanged: (_) => _toggleSelect(authorId),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      // Utilisateur (nom + ID tronqué).
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  displayName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              if (isBanned) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'BANNI',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: Colors.red,
                    ),
                  ),
                ),
              ],
            ],
          ),
          Text(
            authorId.length > 8 ? '${authorId.substring(0, 8)}…' : authorId,
            style: const TextStyle(
              fontSize: 10,
              color: Colors.grey,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
      // Total.
      Text(
        '$total',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).textTheme.bodySmall?.color,
        ),
      ),
      // Rejets.
      Text(
        '$rejected',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: rate >= 50 ? Colors.red : null,
        ),
      ),
      // % Rejets (couleur sémantique selon le taux).
      Text(
        '${rate.toStringAsFixed(1)}%',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: rate >= 50
              ? Colors.red
              : (rate >= 25 ? AppColors.categoryVideo : AppColors.plusGold),
        ),
      ),
      // Badge Premium.
      isPremium ? const _PremiumBadge() : const Text('—'),
      // Actions : bannir / débannir.
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: isBanned ? 'Débannir' : 'Bannir',
            icon: isBanned
                ? const Icon(
                    Icons.lock_open_rounded,
                    size: 20,
                    color: Colors.green,
                  )
                : const Icon(Icons.block_rounded, size: 20, color: Colors.red),
            onPressed: isBanned
                ? () => store.unban(authorId)
                : () => showDialog<void>(
                    context: context,
                    builder: (_) => ConfirmDialog(
                      title: 'Bannir $displayName ?',
                      message:
                          'Cet utilisateur ne pourra plus soumettre de '
                          'suggestions dans l\'application.',
                      confirmLabel: 'Bannir',
                      destructive: true,
                      onConfirm: () =>
                          store.banAuthorId(authorId, displayName: displayName),
                    ),
                  ),
          ),
        ],
      ),
    ];
  }

  /// Bannit une liste d'utilisateurs (sélection arbitraire).
  Future<void> _banSelection(
    StoreController store,
    List<String> userIds,
  ) async {
    await _banBatch(store, userIds, 'Bannir la sélection');
  }

  /// Bannit tous les utilisateurs de la page courante.
  Future<void> _banPage(StoreController store, List<String> userIds) async {
    await _banBatch(store, userIds, 'Bannir la page (${userIds.length})');
  }

  /// Exécute le bannissement en masse avec confirmation et feedback.
  Future<void> _banBatch(
    StoreController store,
    List<String> userIds,
    String actionLabel,
  ) async {
    // Exclut les utilisateurs déjà bannis pour ne pas bannir deux fois.
    final toBan = userIds.where((id) => !store.isAuthorBanned(id)).toList();
    if (toBan.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tous les utilisateurs sélectionnés sont déjà bannis.'),
        ),
      );
      _selected.clear();
      return;
    }

    // ConfirmDialog ferme lui-même le dialogue puis appelle onConfirm :
    // on effectue le bannissement directement dans le callback.
    showDialog<void>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: '$actionLabel ?',
        message:
            'Vous allez bannir ${toBan.length} compte(s). '
            'Ils ne pourront plus soumettre de suggestions.',
        confirmLabel: 'Bannir',
        destructive: true,
        onConfirm: () => _executeBanBatch(store, toBan),
      ),
    );
  }

  /// Exécute réellement le bannissement en masse (appelé après confirmation).
  Future<void> _executeBanBatch(
    StoreController store,
    List<String> toBan,
  ) async {
    setState(() => _banning = true);
    int count = 0;
    try {
      count = await store.banBatch(toBan);
    } finally {
      if (mounted) setState(() => _banning = false);
    }
    // Nettoie la sélection des comptes maintenant bannis.
    setState(() {
      for (final id in toBan) {
        _selected.remove(id);
      }
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            count > 0
                ? '$count compte(s) banni(s) avec succès.'
                : 'Aucun compte n\'a pu être banni (erreur serveur).',
          ),
          backgroundColor: count > 0 ? Colors.green : Colors.red,
        ),
      );
    }
  }

  /// Applique le tri sur [list] en place, selon la colonne et le sens choisis.
  /// Tri par défaut : « % Rejets » décroissant (pires contributeurs en tête).
  void _applySort(List<Map<String, dynamic>> list) {
    if (_sortColumnIndex == null) {
      list.sort((a, b) {
        final ra = (a['rejection_rate'] as num?)?.toDouble() ?? 0.0;
        final rb = (b['rejection_rate'] as num?)?.toDouble() ?? 0.0;
        return rb.compareTo(ra);
      });
      return;
    }

    int compare(Map<String, dynamic> a, Map<String, dynamic> b) {
      int cmp;
      switch (_sortColumnIndex) {
        case 1: // Utilisateur
          cmp = (a['display_name'] as String? ?? '').toLowerCase().compareTo(
            (b['display_name'] as String? ?? '').toLowerCase(),
          );
          break;
        case 2: // Total
          cmp = (a['total_count'] as int? ?? 0).compareTo(
            b['total_count'] as int? ?? 0,
          );
          break;
        case 3: // Rejets
          cmp = (a['rejected_count'] as int? ?? 0).compareTo(
            b['rejected_count'] as int? ?? 0,
          );
          break;
        case 4: // % Rejets
          cmp = ((a['rejection_rate'] as num?)?.toDouble() ?? 0.0).compareTo(
            (b['rejection_rate'] as num?)?.toDouble() ?? 0.0,
          );
          break;
        case 5: // Premium
          cmp = ((a['is_premium'] as bool? ?? false) ? 1 : 0).compareTo(
            (b['is_premium'] as bool? ?? false) ? 1 : 0,
          );
          break;
        default:
          cmp = 0;
      }
      return _sortAscending ? cmp : -cmp;
    }

    list.sort(compare);
  }
}

/// Badge doré « PLUS » pour les contributeurs premium.
class _PremiumBadge extends StatelessWidget {
  const _PremiumBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.plusGold.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt_rounded, size: 11, color: AppColors.plusGold),
          SizedBox(width: 3),
          Text(
            'PLUS',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              color: AppColors.plusGold,
            ),
          ),
        ],
      ),
    );
  }
}

/// Indice « liste vide » (pattern scruteur_screen.dart).
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.grey, fontSize: 13),
      ),
    );
  }
}
