import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/colors.dart';
import '../../data/supabase_sync.dart';
import '../../domain/models/banned_channel.dart';
import '../../state/store_controller.dart';
import 'admin_data_table.dart';
import 'confirm_dialog.dart';

/// Panneau « 🚫 Chaînes bannies » (chantier B, migration 0064, contrat
/// §70.3), ouvert depuis le menu Chaîne YT (bouton « 🚫 Bannir »).
///
/// Contient :
///  - le formulaire de bannissement (URL ou handle + motif libre + nom
///    affiché optionnel) — la normalisation est faite côté serveur (EF
///    `channels/ban`) ; un ban réussi ouvre le rapport ([_BanReportDialog])
///    avec la purge de la file pending et les contenus publiés (retrait
///    MANUEL au clic, jamais automatique) ;
///  - la liste paginée des chaînes bannies (handle, nom, motif, date
///    JJ/MM/AAAA, auteur) avec retrait après confirmation.
///
/// Comme l'écran Chaînes YT hôte, ce panneau fait ses propres appels EF
/// (pas de dataset synchronisé) : états chargement / erreur / vide / données.
class BannedChannelsPanel extends StatefulWidget {
  const BannedChannelsPanel({super.key});

  /// Ouvre le panneau en dialog.
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const BannedChannelsPanel(),
    );
  }

  @override
  State<BannedChannelsPanel> createState() => _BannedChannelsPanelState();
}

class _BannedChannelsPanelState extends State<BannedChannelsPanel> {
  /// Taille de page demandée au serveur (le serveur borne à 100).
  static const int _pageSize = 10;

  List<BannedChannel> _items = <BannedChannel>[];
  int _total = 0;
  int _page = 0;

  bool _loading = false;
  String? _error;

  /// Identifiants des lignes en cours de retrait — une opération à la fois.
  final Set<int> _busyIds = <int>{};

  // Formulaire de bannissement.
  final TextEditingController _handleCtrl = TextEditingController();
  final TextEditingController _reasonCtrl = TextEditingController();
  final TextEditingController _nameCtrl = TextEditingController();
  bool _banning = false;
  String? _formMessage;
  bool _formError = false;

  int get _totalPages => (_total / _pageSize).ceil().clamp(1, 1 << 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(0);
    });
  }

  @override
  void dispose() {
    _handleCtrl.dispose();
    _reasonCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  /// Extrait un message d'erreur lisible (retire le préfixe « Exception: »).
  static String _errorMessage(Object e) {
    const prefix = 'Exception: ';
    final String msg = e.toString();
    return msg.startsWith(prefix) ? msg.substring(prefix.length) : msg;
  }

  /// Date au format JJ/MM/AAAA (contrat §70.3), heure locale.
  static String _fmtDate(DateTime? d) {
    if (d == null) return '—';
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.day)}/${two(l.month)}/${l.year}';
  }

  Future<void> _load(int page) async {
    final sync = context.read<StoreController>().sync;
    if (sync == null) {
      setState(() => _error = 'Mode démo : pas de connexion Supabase.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await sync.fetchBannedChannels(
        page: page,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _total = res.total;
        _page = page;
        _loading = false;
      });
    } on AdminAuthException {
      if (!mounted) return;
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _errorMessage(e);
        _loading = false;
      });
    }
  }

  // ── Bannissement ──

  Future<void> _ban() async {
    final store = context.read<StoreController>();
    final sync = store.sync;
    if (_banning || sync == null) return;
    final handleOrUrl = _handleCtrl.text.trim();
    final reason = _reasonCtrl.text.trim();
    if (handleOrUrl.isEmpty || reason.isEmpty) {
      setState(() {
        _formMessage = 'URL/handle et motif sont requis.';
        _formError = true;
      });
      return;
    }
    setState(() {
      _banning = true;
      _formMessage = null;
    });
    try {
      final report = await sync.banChannel(
        handleOrUrl: handleOrUrl,
        reason: reason,
        displayName: _nameCtrl.text.trim().isEmpty ? null : _nameCtrl.text,
      );
      if (!mounted) return;
      // Chantier B (fix revue I-002) : propage le ban aux bots vivants —
      // demande de sync TOTALE fire-and-forget (chantier C) ; les bots
      // rechargeront la liste noire au prochain cycle/démarrage.
      unawaited(store.requestTotalSync());
      setState(() => _banning = false);
      _handleCtrl.clear();
      _reasonCtrl.clear();
      _nameCtrl.clear();
      // Recharge la liste (la nouvelle chaîne est en tête — tri created_at
      // desc côté serveur) puis ouvre le rapport de bannissement.
      await _load(0);
      if (!mounted) return;
      await _BanReportDialog.show(context, report);
    } on AdminAuthException {
      if (!mounted) return;
      store.onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _banning = false;
        _formMessage = _errorMessage(e);
        _formError = true;
      });
    }
  }

  // ── Retrait d'un bannissement ──

  void _confirmUnban(BannedChannel channel) {
    showDialog<void>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: 'Débannir ${channel.displayHandle} ?',
        message:
            'La chaîne ${channel.displayHandle} ne sera plus bannie : '
            'les bots pourront de nouveau la proposer. Les suggestions déjà '
            'rejetées ne sont pas restaurées.',
        confirmLabel: 'Débannir',
        destructive: true,
        onConfirm: () => _unban(channel),
      ),
    );
  }

  Future<void> _unban(BannedChannel channel) async {
    final sync = context.read<StoreController>().sync;
    if (sync == null || _busyIds.contains(channel.id)) return;
    setState(() => _busyIds.add(channel.id));
    try {
      await sync.unbanChannel(channel.id);
      if (!mounted) return;
      // Chantier B (fix revue I-002) : propage le débannissement aux bots
      // vivants — sync totale fire-and-forget (chantier C), monté-guardée.
      unawaited(context.read<StoreController>().requestTotalSync());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Chaîne ${channel.displayHandle} débannie. Les bots '
            'synchroniseront la liste noire au prochain cycle.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
      // Reste sur une page valide si on vient d'y retirer la dernière ligne.
      final target = _items.length == 1 && _page > 0 ? _page - 1 : _page;
      await _load(target);
    } on AdminAuthException {
      if (!mounted) return;
      context.read<StoreController>().onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_errorMessage(e)),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyIds.remove(channel.id));
    }
  }

  // ── Construction ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.block_rounded,
                    size: 22,
                    color: AppColors.categoryVideo,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Chaînes YouTube bannies',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Actualiser',
                    onPressed: _loading ? null : () => _load(_page),
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  ),
                  IconButton(
                    tooltip: 'Fermer',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Bannir une chaîne rejette automatiquement ses suggestions en '
                'attente (motif « Chaîne bannie ») et les bots (Vision + '
                'Sentinelle) l\'écartent sans analyse. Les contenus déjà '
                'publiés sont signalés dans le rapport — retrait manuel.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              _buildBanForm(theme),
              const SizedBox(height: 12),
              Expanded(child: _buildBody(theme)),
              const SizedBox(height: 8),
              _buildPagination(theme),
            ],
          ),
        ),
      ),
    );
  }

  /// Formulaire d'ajout : URL/handle + motif + nom affiché (optionnel).
  Widget _buildBanForm(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.categoryVideo.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppColors.categoryVideo.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _handleCtrl,
                  enabled: !_banning,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'URL ou handle de la chaîne *',
                    hintText: 'https://youtube.com/@xxx ou @xxx',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _ban(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _nameCtrl,
                  enabled: !_banning,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Nom affiché (optionnel)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _reasonCtrl,
                  enabled: !_banning,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Motif *',
                    hintText: 'Ex. : contenus marqués guide — walkthroughs',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _ban(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.categoryVideo,
                ),
                onPressed: _banning ? null : _ban,
                icon: _banning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.block_rounded, size: 18),
                label: const Text('Bannir'),
              ),
            ],
          ),
          if (_formMessage != null) ...[
            const SizedBox(height: 6),
            Text(
              _formMessage!,
              style: TextStyle(
                fontSize: 12,
                color: _formError
                    ? AppColors.categoryVideo
                    : AppColors.neonGreen,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: TextStyle(color: Colors.orange.shade300),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _load(_page),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      );
    }
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          'Aucune chaîne bannie pour le moment.',
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      );
    }
    return SingleChildScrollView(
      child: AdminDataTable(
        columns: const ['Handle', 'Nom', 'Motif', 'Date', 'Par', 'Actions'],
        rows: [
          for (final c in _items)
            [
              Text(
                c.displayHandle,
                style: const TextStyle(fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
              Text(c.displayName ?? '—', overflow: TextOverflow.ellipsis),
              Tooltip(
                message: c.reason ?? '',
                child: Text(c.reason ?? '—', overflow: TextOverflow.ellipsis),
              ),
              Text(_fmtDate(c.createdAt)),
              Text(c.bannedBy ?? '—', overflow: TextOverflow.ellipsis),
              Align(
                alignment: Alignment.centerLeft,
                child: _busyIds.contains(c.id)
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        tooltip: 'Débannir cette chaîne',
                        onPressed: () => _confirmUnban(c),
                        icon: const Icon(Icons.undo_rounded, size: 18),
                        color: AppColors.categoryVideo,
                      ),
              ),
            ],
        ],
      ),
    );
  }

  /// Barre de pagination (même modèle que le menu Log).
  Widget _buildPagination(ThemeData theme) {
    if (_total == 0) return const SizedBox.shrink();
    final int firstRow = _page * _pageSize + 1;
    final int lastRow = ((_page + 1) * _pageSize).clamp(0, _total).toInt();
    return Row(
      children: [
        Text(
          '$firstRow–$lastRow sur $_total — page ${_page + 1}/$_totalPages',
          style: theme.textTheme.bodySmall,
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.first_page_rounded, size: 20),
          tooltip: 'Première page',
          onPressed: _page > 0 && !_loading ? () => _load(0) : null,
        ),
        IconButton(
          icon: const Icon(Icons.chevron_left_rounded, size: 20),
          tooltip: 'Page précédente',
          onPressed: _page > 0 && !_loading ? () => _load(_page - 1) : null,
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right_rounded, size: 20),
          tooltip: 'Page suivante',
          onPressed: _page + 1 < _totalPages && !_loading
              ? () => _load(_page + 1)
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.last_page_rounded, size: 20),
          tooltip: 'Dernière page',
          onPressed: _page + 1 < _totalPages && !_loading
              ? () => _load(_totalPages - 1)
              : null,
        ),
      ],
    );
  }
}

/// Rapport affiché après un bannissement réussi (contrat §70.3) :
///  - « X suggestions en file rejetées (motif : Chaîne bannie) » ;
///  - si des contenus de la chaîne sont déjà publiés : la liste + bouton
///    « Retirer aussi ces N contenus publiés » (retrait MANUEL — route EF
///    `contents/unpublish-by-channel`) puis compte-rendu.
class _BanReportDialog extends StatefulWidget {
  const _BanReportDialog({required this.report});

  final BanChannelReport report;

  static Future<void> show(BuildContext context, BanChannelReport report) {
    return showDialog<void>(
      context: context,
      builder: (_) => _BanReportDialog(report: report),
    );
  }

  @override
  State<_BanReportDialog> createState() => _BanReportDialogState();
}

class _BanReportDialogState extends State<_BanReportDialog> {
  bool _unpublishing = false;
  int? _deleted;

  static String _errorMessage(Object e) {
    const prefix = 'Exception: ';
    final String msg = e.toString();
    return msg.startsWith(prefix) ? msg.substring(prefix.length) : msg;
  }

  Future<void> _unpublish() async {
    final store = context.read<StoreController>();
    final sync = store.sync;
    if (_unpublishing || sync == null) return;
    setState(() => _unpublishing = true);
    try {
      final res = await sync.unpublishByChannel(widget.report.banned.handle);
      if (!mounted) return;
      setState(() {
        _unpublishing = false;
        _deleted = res.deleted;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${res.deleted} contenu(s) publié(s) retiré(s) de '
            '${widget.report.banned.displayHandle}.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } on AdminAuthException {
      if (!mounted) return;
      store.onAuthError?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _unpublishing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_errorMessage(e)),
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = widget.report;
    final published = report.published;
    return AlertDialog(
      title: Text('🚫 ${report.banned.displayHandle} bannie'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${report.purged} suggestion(s) en file rejetée(s) '
                '(motif : Chaîne bannie).',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 6),
              Text(
                'Les bots synchroniseront la liste noire au prochain cycle.',
                style: theme.textTheme.bodySmall,
              ),
              if (published.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '⚠️ ${published.length} contenu(s) de cette chaîne '
                        'sont déjà PUBLIÉS dans l\'app :',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final c in published.take(20))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            '• ${c['title'] ?? c['url'] ?? ''}',
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (published.length > 20)
                        Text(
                          '… et ${published.length - 20} autre(s).',
                          style: theme.textTheme.bodySmall,
                        ),
                      const SizedBox(height: 8),
                      if (_deleted == null)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.categoryVideo,
                          ),
                          onPressed: _unpublishing ? null : _unpublish,
                          icon: _unpublishing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 18,
                                ),
                          label: Text(
                            'Retirer aussi ces ${published.length} contenus '
                            'publiés',
                          ),
                        )
                      else
                        Text(
                          '✅ ${_deleted!} contenu(s) publié(s) retiré(s).',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: AppColors.neonGreen,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
              ] else ...[
                const SizedBox(height: 12),
                Text(
                  'Aucun contenu publié connu pour cette chaîne.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}
