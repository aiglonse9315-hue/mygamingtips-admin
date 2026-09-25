import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/colors.dart';
import '../../data/supabase_sync.dart' show AdminAuthException;
import '../../domain/models/plus_user.dart';
import '../../domain/plus_paging.dart';
import '../../state/store_controller.dart';
import '../widgets/admin_data_table.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/stat_card.dart' show StatusBadge;
import 'dashboard_screen.dart' show AddPlusUserDialog;

/// Gestion des abonnements Plus : tableau paginé CÔTÉ SERVEUR (100 lignes par
/// page, total exact — migration 0085) avec recherche, filtres, tri et
/// bannissement. Aucun plafond de volume : seule la page affichée transite
/// (demande propriétaire du 25/09/2026 — fin de la limite des 100 000).
class AbonnementsScreen extends StatefulWidget {
  const AbonnementsScreen({super.key});

  @override
  State<AbonnementsScreen> createState() => _AbonnementsScreenState();
}

class _AbonnementsScreenState extends State<AbonnementsScreen> {
  /// Lignes par page (serveur).
  static const int _pageSize = kPlusPageSize;

  /// Délai entre la dernière frappe et la recherche serveur.
  static const Duration _searchDebounce = Duration(milliseconds: 350);

  /// Clé de tri serveur des colonnes triables du tableau (index de colonne).
  static const Map<int, String> _sortKeyByColumn = <int, String>{
    0: 'display_name',
    2: 'plan',
    3: 'source',
    4: 'status',
    5: 'started_at',
  };

  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  String _search = '';
  String? _sourceFilter; // null = tous, 'google', 'admin'
  String? _statusFilter; // null = tous, 'active', 'inactive'

  // Tri (null = défaut serveur : plus récents d'abord).
  int? _sortColumnIndex;
  bool _sortAscending = true;

  // Page courante (réponse serveur).
  List<PlusUser> _items = <PlusUser>[];
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  bool _loadedOnce = false;
  String? _error;

  /// Lignes dont une action est en cours (boutons grisés, pas de double clic).
  final Set<String> _busy = <String>{};

  /// Numéro du dernier chargement : seule la réponse la plus récente est
  /// affichée (frappes rapides, clics de pagination successifs).
  int _loadSeq = 0;

  /// Dernière [StoreController.plusRevision] prise en compte.
  int _seenRevision = 0;

  StoreController? _store;

  @override
  void initState() {
    super.initState();
    final StoreController store = context.read<StoreController>();
    _store = store;
    _seenRevision = store.plusRevision;
    store.addListener(_onStoreChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      store.refreshPlusStats();
      _load(0);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _store?.removeListener(_onStoreChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  int get _totalPages => plusPageCount(_total, _pageSize);

  bool get _hasFilters =>
      _search.isNotEmpty || _sourceFilter != null || _statusFilter != null;

  PlusPageQuery _queryFor(int page) => PlusPageQuery(
    page: page,
    pageSize: _pageSize,
    search: _search,
    status: _statusFilter,
    source: _sourceFilter,
    sort: _sortKeyByColumn[_sortColumnIndex] ?? kPlusDefaultSort,
    ascending: _sortColumnIndex != null && _sortAscending,
  );

  /// Écriture d'abonnement réussie (ici, au dashboard ou via « Ajouter ») ou
  /// « Actualiser » → recharge la page courante.
  void _onStoreChanged() {
    final StoreController? store = _store;
    if (store == null || !mounted) return;
    if (store.plusRevision == _seenRevision) return;
    _seenRevision = store.plusRevision;
    _load(_page);
  }

  /// Charge la page [page] avec les filtres et le tri courants. Si cette page
  /// n'existe plus (ex. dernier abonné de la dernière page désactivé avec le
  /// filtre « Actif »), recule sur la dernière page existante.
  Future<void> _load(int page) async {
    final StoreController store = context.read<StoreController>();
    final int seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final PlusPage res = await store.fetchPlusPage(_queryFor(page));
      if (!mounted || seq != _loadSeq) return;
      final int lastPage = plusPageCount(res.total, _pageSize) - 1;
      if (res.items.isEmpty && page > lastPage) {
        unawaited(_load(lastPage));
        return;
      }
      setState(() {
        _items = res.items;
        _total = res.total;
        _page = page;
        _loading = false;
        _loadedOnce = true;
      });
    } on AdminAuthException {
      // Logout forcé déjà déclenché par le StoreController.
      if (mounted && seq == _loadSeq) setState(() => _loading = false);
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Recherche serveur, lancée 350 ms après la dernière frappe (retour
  /// page 1).
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_searchDebounce, () {
      final String q = value.trim();
      if (!mounted || q == _search) return;
      _search = q;
      _load(0);
    });
  }

  void _setSourceFilter(String? value) {
    if (value == _sourceFilter) return;
    setState(() => _sourceFilter = value);
    _load(0);
  }

  void _setStatusFilter(String? value) {
    if (value == _statusFilter) return;
    setState(() => _statusFilter = value);
    _load(0);
  }

  void _onSort(int columnIndex) {
    setState(() {
      if (_sortColumnIndex == columnIndex) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumnIndex = columnIndex;
        _sortAscending = true;
      }
    });
    _load(0);
  }

  /// Exécute une action sur la ligne [u] (boutons de la ligne grisés pendant
  /// l'appel). Une écriture d'abonnement réussie recharge la page via
  /// [StoreController.plusRevision] ; [reload] force le rechargement pour
  /// les actions qui ne touchent pas l'abonnement (ban / déban).
  Future<void> _runRowAction(
    PlusUser u,
    Future<void> Function() action, {
    bool reload = false,
  }) async {
    if (_busy.contains(u.id)) return;
    setState(() => _busy.add(u.id));
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _busy.remove(u.id));
        if (reload) _load(_page);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final PlusStats? stats = context.select<StoreController, PlusStats?>(
      (StoreController s) => s.plusStats,
    );
    final Color? muted = Theme.of(context).textTheme.bodySmall?.color;

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
            _summaryLine(stats),
            style: TextStyle(fontSize: 12, color: muted),
          ),
          const SizedBox(height: 16),
          // Recherche (serveur, anti-rebond 350 ms).
          TextField(
            controller: _searchCtrl,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              isDense: true,
              hintText:
                  'Rechercher un abonné (pseudo ou début d\'identifiant)…',
              prefixIcon: const Icon(Icons.search_rounded),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Filtres (serveur).
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
                onChanged: _setSourceFilter,
              ),
              _FilterChip(
                label: 'Statut',
                value: _statusFilter == null
                    ? 'Tous'
                    : _statusFilter == 'active'
                    ? 'Actif'
                    : 'Expiré',
                items: const ['Actif', 'Expiré'],
                values: const ['active', 'inactive'],
                selectedValue: _statusFilter,
                onChanged: _setStatusFilter,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _tableArea(context),
        ],
      ),
    );
  }

  /// Ligne de synthèse : compteurs globaux (+ résultats des filtres).
  String _summaryLine(PlusStats? stats) {
    final String counts = stats == null
        ? 'Compteurs en cours de chargement…'
        : '${formatCount(stats.active)} actif(s) • '
              '${formatCount(stats.total)} au total';
    if (!_loadedOnce || !_hasFilters) return counts;
    return '$counts • ${formatCount(_total)} correspondant(s) aux filtres';
  }

  /// Zone tableau : premier chargement / erreur / vide / page + pagination.
  Widget _tableArea(BuildContext context) {
    if (!_loadedOnce) {
      if (_error != null) return _errorBanner();
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) ...[_errorBanner(), const SizedBox(height: 12)],
        _pageBar(),
        const SizedBox(height: 8),
        SizedBox(
          height: 2,
          child: _loading ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        const SizedBox(height: 8),
        if (_items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                _hasFilters
                    ? 'Aucun abonné pour ces filtres.'
                    : 'Aucun abonné Plus.',
              ),
            ),
          )
        else
          _table(context),
        if (_totalPages > 1) ...[const SizedBox(height: 12), _pageBar()],
      ],
    );
  }

  Widget _errorBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 18, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Chargement des abonnés impossible : $_error',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: _loading ? null : () => _load(_page),
            child: const Text('Réessayer'),
          ),
        ],
      ),
    );
  }

  /// Barre de pagination (total serveur exact).
  Widget _pageBar() {
    final int firstRow = _total == 0 ? 0 : _page * _pageSize + 1;
    final int lastRow = math.min((_page + 1) * _pageSize, _total);
    final bool canBack = _page > 0 && !_loading;
    final bool canForward = _page < _totalPages - 1 && !_loading;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.first_page_rounded),
          onPressed: canBack ? () => _load(0) : null,
          tooltip: 'Première page',
        ),
        IconButton(
          icon: const Icon(Icons.chevron_left_rounded),
          onPressed: canBack ? () => _load(_page - 1) : null,
          tooltip: 'Page précédente',
        ),
        const SizedBox(width: 8),
        Text(
          'Page ${formatCount(_page + 1)} / ${formatCount(_totalPages)}'
          ' (${formatCount(firstRow)}-${formatCount(lastRow)} sur '
          '${formatCount(_total)})',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.chevron_right_rounded),
          onPressed: canForward ? () => _load(_page + 1) : null,
          tooltip: 'Page suivante',
        ),
        IconButton(
          icon: const Icon(Icons.last_page_rounded),
          onPressed: canForward ? () => _load(_totalPages - 1) : null,
          tooltip: 'Dernière page',
        ),
      ],
    );
  }

  Widget _table(BuildContext context) {
    final StoreController store = context.read<StoreController>();
    final Color? muted = Theme.of(context).textTheme.bodySmall?.color;
    return AdminDataTable(
      columns: const [
        'Utilisateur',
        'Email',
        'Formule',
        'Source',
        'Statut',
        'Début',
        'Actions',
      ],
      sortColumnIndex: _sortColumnIndex,
      sortAscending: _sortAscending,
      nonSortableColumns: const ['Email', 'Actions'],
      onSort: _onSort,
      rows: _items.map((PlusUser u) {
        final bool busy = _busy.contains(u.id);
        return <Widget>[
          // Utilisateur (pseudo + UID tronqué — l'abonnement est lié à l'UID
          // Supabase, le pseudo peut changer).
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      u.displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  // Badge BANNI (is_banned fourni par la ligne serveur).
                  if (u.isBanned) ...[
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
                u.id.length > 8 ? '${u.id.substring(0, 8)}…' : u.id,
                style: const TextStyle(
                  fontSize: 10,
                  color: Colors.grey,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          // Email.
          Text(u.email ?? '—', style: TextStyle(fontSize: 12, color: muted)),
          // Formule (badge).
          _PlanBadge(plan: u.plan),
          // Source (badge).
          _SourceBadge(isGoogle: u.isGoogle, isVerified: u.isVerified),
          // Statut (« Actif » = is_active).
          u.active
              ? const StatusBadge(label: 'Actif', color: Colors.green)
              : const StatusBadge(label: 'Expiré', color: Colors.grey),
          // Début (+ échéance éventuelle : Google Play, récompenses).
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatDate(u.startedAt),
                style: TextStyle(fontSize: 12, color: muted),
              ),
              if (u.expiresAt != null)
                Text(
                  'fin : ${_formatDate(u.expiresAt!)}',
                  style: TextStyle(fontSize: 10, color: muted),
                ),
            ],
          ),
          // Actions.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Suspendre / Réactiver (seul le statut change ; une échéance
              // déjà passée est effacée à la réactivation).
              IconButton(
                tooltip: u.active ? 'Suspendre' : 'Réactiver',
                icon: Icon(
                  u.active
                      ? Icons.pause_circle_outline_rounded
                      : Icons.play_circle_outline_rounded,
                  size: 20,
                  color: u.active ? AppColors.plusGold : Colors.green,
                ),
                onPressed: busy
                    ? null
                    : () => _runRowAction(u, () => store.togglePlusUser(u)),
              ),
              // Changer la formule (sauf Google : gérée par Google Play).
              if (!u.isGoogle)
                PopupMenuButton<String>(
                  tooltip: 'Changer la formule',
                  enabled: !busy,
                  icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                  onSelected: (String plan) =>
                      _runRowAction(u, () => store.setPlusPlan(u, plan)),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'monthly', child: Text('Mensuel')),
                    PopupMenuItem(value: 'yearly', child: Text('Annuel')),
                  ],
                ),
              // Bannir / Débannir selon le statut de la ligne.
              IconButton(
                tooltip: u.isBanned ? 'Débannir' : 'Bannir',
                icon: u.isBanned
                    ? const Icon(
                        Icons.lock_open_rounded,
                        size: 20,
                        color: Colors.green,
                      )
                    : const Icon(
                        Icons.block_rounded,
                        size: 20,
                        color: Colors.red,
                      ),
                onPressed: busy
                    ? null
                    : () {
                        if (u.isBanned) {
                          _runRowAction(
                            u,
                            () => store.unban(u.id),
                            reload: true,
                          );
                          return;
                        }
                        showDialog<void>(
                          context: context,
                          builder: (_) => ConfirmDialog(
                            title: 'Bannir ${u.displayName} ?',
                            message:
                                'Cet utilisateur ne pourra plus soumettre '
                                'de suggestions dans l\'application.',
                            confirmLabel: 'Bannir',
                            destructive: true,
                            onConfirm: () => _runRowAction(
                              u,
                              () => store.banAuthorId(
                                u.id,
                                displayName: u.displayName,
                              ),
                              reload: true,
                            ),
                          ),
                        );
                      },
              ),
              // « Supprimer » = désactiver côté serveur (aucune ligne
              // effacée) : sans objet pour un abonnement déjà inactif.
              if (u.active)
                IconButton(
                  tooltip: 'Supprimer (désactive l\'abonnement)',
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: AppColors.categoryVideo,
                  ),
                  onPressed: busy
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) => ConfirmDialog(
                            title: 'Supprimer ${u.displayName} ?',
                            message:
                                'L\'abonnement sera désactivé côté serveur '
                                '(statut Expiré). La ligne reste consultable '
                                'dans la liste : aucune donnée n\'est effacée.',
                            confirmLabel: 'Supprimer',
                            destructive: true,
                            onConfirm: () => _runRowAction(
                              u,
                              () => store.deletePlusUser(u.id),
                            ),
                          ),
                        ),
                ),
            ],
          ),
        ];
      }).toList(),
    );
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
        color: (isYearly ? AppColors.plusGold : AppColors.plus).withValues(
          alpha: 0.16,
        ),
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
    final String label = isVerified
        ? 'Google ✓'
        : (isGoogle ? 'Google' : 'Manuel');
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
          Icon(icon, size: 12, color: color),
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
          Text(
            '$label : ',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
              fontWeight: FontWeight.w700,
            ),
          ),
          PopupMenuButton<String>(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Icon(Icons.arrow_drop_down_rounded, size: 18),
              ],
            ),
            onSelected: (v) {
              onChanged(v == _allValue ? null : v);
            },
            itemBuilder: (_) => [
              const PopupMenuItem<String>(
                value: _allValue,
                child: Text('Tous'),
              ),
              ...List.generate(
                items.length,
                (i) => PopupMenuItem(value: values[i], child: Text(items[i])),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
