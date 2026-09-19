// dart:html est le pattern déjà utilisé par le projet (logs_screen.dart,
// auth_service.dart, store.dart) pour Blob/localStorage — app Flutter Web
// uniquement.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/analytics_calc.dart';
import '../../domain/analytics_export.dart';
import '../../state/store_controller.dart';
import '../widgets/confirm_dialog.dart';

/// Écran « Analytics » (chantier F1 — migration 0066, EF v76, décisions
/// §70.3 / §70.6).
///
/// Indicateurs d'abonnements et de revenus ESTIMÉS (prix catalogue × achats
/// réels — les abonnements offerts source admin/reward sont exclus du CA) +
/// administration des prix, de la fiscalité de projection et des frais de
/// société, et exports comptables Excel (mensuel / annuel).
///
/// Chargement direct via le StoreController (pattern Contributeurs/Limite) :
/// AUCUN dataset synchronisé ici — ce menu ne déclenche PAS de full sync du
/// catalogue (les 15k contenus restent hors de cet écran).
///
/// Toutes les périodes sont calculées dans le FUSEAU LOCAL du navigateur
/// (documenté dans l'UI).
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  // ── Période (fuseau local — from à 00:00:00, to à 23:59:59.999) ──
  late DateTime _from;
  late DateTime _to;
  String _shortcut = '30 jours';

  // ── Options d'affichage des montants ──
  bool _showHt = false; // toggle TTC/HT (jamais les deux)
  String _jurisdiction = 'france';
  bool _deductPlayFee = false; // option « déduire les frais Play » (défaut off)

  // ── Exports comptables ──
  late int _exportYear;
  late int _exportMonth;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _applyRange(_daysAgo(29), _endOfDay(now), '30 jours');
    _exportYear = now.year;
    _exportMonth = now.month;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  static DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime _endOfDay(DateTime d) =>
      DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

  static DateTime _daysAgo(int n) =>
      _startOfDay(DateTime.now().subtract(Duration(days: n)));

  void _applyRange(DateTime from, DateTime to, String shortcut) {
    _from = _startOfDay(from);
    _to = _endOfDay(to);
    _shortcut = shortcut;
  }

  /// Premier chargement : configs (prix/taxes/frais) + données de la période.
  Future<void> _loadAll() async {
    final store = context.read<StoreController>();
    await Future.wait([store.fetchAnalyticsConfigs(), _reloadData()]);
  }

  /// Recharge overview + séries pour la période courante.
  ///
  /// Les séries sont en granularité MENSUELLE sur les mois calendaires
  /// couvrant la période (from étendu au 1er du mois, to au dernier jour) :
  /// le graphique « Revenus mensuels » affiche des mois complets, libellés
  /// « sept. 2026 » (documenté dans le sous-titre de la carte).
  Future<void> _reloadData() async {
    final store = context.read<StoreController>();
    final seriesFrom = DateTime(_from.year, _from.month, 1);
    final seriesTo = _endOfDay(DateTime(_to.year, _to.month + 1, 0));
    await Future.wait([
      store.fetchAnalyticsOverview(from: _from, to: _to),
      store.fetchAnalyticsSeries(
        from: seriesFrom,
        to: seriesTo,
        granularity: 'month',
      ),
    ]);
  }

  void _onShortcut(String label, DateTime from, DateTime to) {
    setState(() => _applyRange(from, to, label));
    _reloadData();
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isFrom) {
        _applyRange(picked, _to.isBefore(picked) ? picked : _to, 'custom');
      } else {
        _applyRange(_from.isAfter(picked) ? picked : _from, picked, 'custom');
      }
    });
    await _reloadData();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Options de calcul partagées (écran + exports — même formule, cf.
  // analytics_export.dart).
  // ─────────────────────────────────────────────────────────────────────────

  ExportContext _exportContext(StoreController store) {
    final taxes = store.taxConfigs.where((t) => t.active).toList();
    final tax = taxes.firstWhere(
      (t) => t.jurisdiction == _jurisdiction,
      orElse: () => taxes.isNotEmpty
          ? taxes.first
          : const TaxConfig(
              jurisdiction: 'france',
              label: 'France (défaut)',
              vatRate: 20,
              franchiseBase: true,
            ),
    );
    return ExportContext(
      pricing: store.pricingConfigs,
      tax: tax,
      expenses: store.companyExpenses,
      showHt: _showHt,
      deductPlayFee: _deductPlayFee,
    );
  }

  /// Revenus estimés de la période avec les options courantes (frais Play,
  /// HT) — recalculés depuis les achats réels × prix catalogue (même formule
  /// que les exports Excel pour garantir la cohérence).
  double _displayRevenue(StoreController store) {
    final o = store.analyticsOverview;
    if (o == null) return 0;
    final ctx = _exportContext(store);
    return round2(
      o.newPaidMonthly * exportPrice(ctx, 'monthly') +
          o.newPaidYearly * exportPrice(ctx, 'yearly'),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Exports Excel
  // ─────────────────────────────────────────────────────────────────────────

  static void _downloadXlsx(List<int> bytes, String filename) {
    final blob = html.Blob([
      bytes,
    ], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', filename)
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  Future<void> _exportMonthXlsx() async {
    if (_exporting) return;
    final store = context.read<StoreController>();
    setState(() => _exporting = true);
    try {
      // Série mensuelle du seul mois choisi (données fraîches).
      await store.fetchAnalyticsSeries(
        from: DateTime(_exportYear, _exportMonth, 1),
        to: _endOfDay(DateTime(_exportYear, _exportMonth + 1, 0)),
        granularity: 'month',
      );
      if (!mounted) return;
      final key = '$_exportYear-${_exportMonth.toString().padLeft(2, '0')}';
      final bucket = store.analyticsSeries.firstWhere(
        (b) => b.key == key,
        orElse: () => SeriesBucket(key: key),
      );
      final bytes = buildMonthlyExcel(
        year: _exportYear,
        month: _exportMonth,
        bucket: bucket,
        ctx: _exportContext(store),
      );
      if (bytes == null) throw Exception('encodage xlsx échoué');
      _downloadXlsx(bytes, 'compta_mygamingtips_$key.xlsx');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export $key généré.')));
      // Restaure la série affichée par le graphique (écrasée par l'export).
      await _reloadData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export impossible : $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportYearXlsx() async {
    if (_exporting) return;
    final store = context.read<StoreController>();
    setState(() => _exporting = true);
    try {
      await store.fetchAnalyticsSeries(
        from: DateTime(_exportYear, 1, 1),
        to: _endOfDay(DateTime(_exportYear, 12, 31)),
        granularity: 'month',
      );
      if (!mounted) return;
      final bytes = buildYearlyExcel(
        year: _exportYear,
        buckets: store.analyticsSeries,
        ctx: _exportContext(store),
      );
      if (bytes == null) throw Exception('encodage xlsx échoué');
      _downloadXlsx(bytes, 'compta_mygamingtips_$_exportYear.xlsx');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export $_exportYear généré (12 onglets + synthèse).'),
        ),
      );
      await _reloadData();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export impossible : $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = context.watch<StoreController>();
    final o = store.analyticsOverview;

    if (store.sync == null) {
      return const Center(
        child: Text('Mode démo : pas de connexion Supabase.'),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(theme, store),
          const SizedBox(height: 16),
          _buildPeriodSelector(theme),
          if (store.analyticsError != null) ...[
            const SizedBox(height: 12),
            Text(
              store.analyticsError!,
              style: TextStyle(color: Colors.orange.shade300),
            ),
          ],
          const SizedBox(height: 20),
          _buildKpiCards(theme, store, o),
          const SizedBox(height: 16),
          _buildAmountOptions(theme, store),
          const SizedBox(height: 16),
          _buildCharts(theme, store),
          const SizedBox(height: 16),
          _buildPricingSection(theme, store),
          const SizedBox(height: 16),
          // Frais de société + exports comptables (qui exposent les frais) :
          // donnée financière RÉSERVÉE au compte principal — l'EF renvoie
          // 403 sur expenses/* pour un compte secondaire (garde owner v76).
          // On masque donc les deux sections : message propre, jamais
          // d'erreur rouge. KPI + graphiques restent visibles à tout admin.
          if (store.isOwner) ...[
            _buildExpensesSection(theme, store),
            const SizedBox(height: 16),
            _buildExportsSection(theme, store),
          ] else
            _buildOwnerOnlyFinanceCard(theme),
          const SizedBox(height: 20),
          Text(
            'Document interne d\'aide à la déclaration — revenus estimés '
            'catalogue (prix × achats réels). Aucun montant réel n\'est '
            'stocké en base.',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, StoreController store) {
    return Row(
      children: [
        Text(
          'Analytics — abonnements & revenus estimés',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(width: 12),
        if (store.analyticsLoading)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          IconButton(
            onPressed: _loadAll,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Recharger les indicateurs',
          ),
      ],
    );
  }

  // ── a) Sélecteur de période ──

  Widget _buildPeriodSelector(ThemeData theme) {
    final now = DateTime.now();
    final shortcuts = <String, (DateTime, DateTime)>{
      "Aujourd'hui": (_startOfDay(now), now),
      '7 jours': (_daysAgo(6), now),
      '30 jours': (_daysAgo(29), now),
      'Mois en cours': (DateTime(now.year, now.month, 1), now),
      'Mois précédent': (
        DateTime(now.year, now.month - 1, 1),
        DateTime(now.year, now.month, 0),
      ),
      'Année en cours': (DateTime(now.year, 1, 1), now),
    };
    String fmt(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final e in shortcuts.entries)
                  ChoiceChip(
                    label: Text(e.key),
                    selected: _shortcut == e.key,
                    onSelected: (_) =>
                        _onShortcut(e.key, e.value.$1, e.value.$2),
                  ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _pickDate(isFrom: true),
                  icon: const Icon(Icons.calendar_today_rounded, size: 16),
                  label: Text('Du ${fmt(_from)}'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _pickDate(isFrom: false),
                  icon: const Icon(Icons.calendar_today_rounded, size: 16),
                  label: Text('au ${fmt(_to)}'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Périodes calculées dans le fuseau local de ce navigateur '
              '(from = 00:00:00, to = 23:59:59 inclus).',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  // ── b) Cartes KPI ──

  Widget _buildKpiCards(
    ThemeData theme,
    StoreController store,
    AnalyticsOverview? o,
  ) {
    final currency = o?.currency ?? 'EUR';
    final revenue = _displayRevenue(store);
    final rate = o == null
        ? 0.0
        : purchaseRate(o.subsActiveTotal, o.accountsTotal);
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        _KpiCard(
          label: 'Abonnés Plus actifs',
          value: o == null ? '…' : '${o.subsActiveTotal}',
          subtitle: o == null
              ? null
              : 'dont ${o.subsActiveMonthly} mensuels · '
                    '${o.subsActiveYearly} annuels',
          tooltip:
              'Comptes dont l\'abonnement est actif (is_active et non '
              'expiré) à l\'instant présent — offerts (admin/reward) inclus.',
        ),
        _KpiCard(
          label: 'Revenus de la période',
          value: o == null ? '…' : formatMoney(revenue, currency),
          subtitle: o == null
              ? null
              : o.newPaidTotal == 0
              ? 'Aucun achat réel sur la période '
                    '(${o.newSubsTotal} offerts exclus)'
              : '${o.newPaidTotal} achat(s) réel(s) '
                    '(${o.newPaidMonthly} mensuels · ${o.newPaidYearly} annuels)',
          tooltip:
              'Estimation catalogue : achats RÉELS de la période '
              '(source hors admin/reward) × prix catalogue, avant frais Play '
              'Store. Les abonnements offerts ne comptent pas.',
        ),
        _KpiCard(
          label: 'Purchase rate',
          value: o == null ? '…' : '${(rate * 100).toStringAsFixed(1)} %',
          subtitle: o == null
              ? null
              : '${o.subsActiveTotal} abonnés / ${o.accountsTotal} comptes',
          tooltip:
              'Part des comptes ayant un abonnement Plus actif : '
              'abonnés actifs ÷ comptes totaux (toutes sources confondues).',
        ),
        _KpiCard(
          label: 'Nouveaux comptes',
          value: o == null ? '…' : '${o.accountsNew}',
          subtitle: o == null ? null : '${o.accountsTotal} comptes au total',
          tooltip:
              'Comptes créés pendant la période sélectionnée '
              '(profiles.created_at).',
        ),
        const _KpiCard(
          label: 'DAU',
          value: '—',
          disabled: true,
          tooltip:
              'Utilisateurs actifs quotidiens — disponibles après '
              'instrumentation de l\'app (chantier F2).',
        ),
        const _KpiCard(
          label: 'MAU',
          value: '—',
          disabled: true,
          tooltip:
              'Utilisateurs actifs mensuels — disponibles après '
              'instrumentation de l\'app (chantier F2).',
        ),
      ],
    );
  }

  // ── c) Options montants : HT/TTC + juridiction + frais Play ──

  Widget _buildAmountOptions(ThemeData theme, StoreController store) {
    final taxes = store.taxConfigs.where((t) => t.active).toList();
    final playFee = playFeeForPlan(store.pricingConfigs, 'monthly');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 24,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('TTC')),
                ButtonSegment(value: true, label: Text('HT')),
              ],
              selected: {_showHt},
              onSelectionChanged: (s) => setState(() => _showHt = s.first),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Juridiction : '),
                DropdownButton<String>(
                  value: taxes.any((t) => t.jurisdiction == _jurisdiction)
                      ? _jurisdiction
                      : (taxes.isNotEmpty ? taxes.first.jurisdiction : null),
                  items: taxes
                      .map(
                        (t) => DropdownMenuItem(
                          value: t.jurisdiction,
                          child: Text(
                            '${t.label} (${t.vatRate.toStringAsFixed(1)} %)',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _jurisdiction = v);
                  },
                ),
                IconButton(
                  // taxes/set est owner-only (EF v76) : désactivé pour un
                  // compte secondaire (la LECTURE des taux reste visible).
                  onPressed: taxes.isEmpty || !store.isOwner
                      ? null
                      : () => _editTaxes(store),
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  tooltip: store.isOwner
                      ? 'Modifier les taux de TVA (tax_config)'
                      : 'Réservé au compte principal',
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _deductPlayFee,
                  onChanged: (v) => setState(() => _deductPlayFee = v ?? false),
                ),
                Text(
                  'Déduire les frais Play (${playFee.toStringAsFixed(0)} %)',
                ),
              ],
            ),
            Text(
              'Revenus = estimation catalogue (prix × abonnements), avant '
              'frais Play Store. HT = TTC ÷ (1 + taux), sauf franchise en '
              'base (HT = TTC).',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  // ── d) Graphiques ──

  Widget _buildCharts(ThemeData theme, StoreController store) {
    final ctx = _exportContext(store);
    final points = monthlyRevenues(
      buckets: store.analyticsSeries,
      monthlyPrice: exportPrice(ctx, 'monthly'),
      yearlyPrice: exportPrice(ctx, 'yearly'),
    );
    final o = store.analyticsOverview;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 900;
        final revenueChart = _revenueChartCard(theme, store, points, ctx);
        final pieCard = _splitPieCard(theme, o);
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: revenueChart),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: pieCard),
            ],
          );
        }
        return Column(
          children: [revenueChart, const SizedBox(height: 16), pieCard],
        );
      },
    );
  }

  Widget _revenueChartCard(
    ThemeData theme,
    StoreController store,
    List<MonthlyRevenuePoint> points,
    ExportContext ctx,
  ) {
    final currency = ctx.pricing.isNotEmpty
        ? ctx.pricing.first.currency
        : 'EUR';
    final hasData = points.any((p) => p.total > 0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Revenus mensuels (${_showHt ? 'HT' : 'TTC'}, $currency)',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Achats réels × prix catalogue, par mois calendaire couvrant '
              'la période — abonnements offerts exclus.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (!hasData)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(
                    'Aucun achat réel sur la période — les abonnements '
                    'offerts (admin/reward) ne comptent pas dans les revenus.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              SizedBox(height: 260, child: _revenueChart(points)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _legendDot(Colors.cyan.shade300, 'Mensuel'),
                _legendDot(Colors.purple.shade300, 'Annuel'),
                _legendDot(Colors.amber.shade300, 'Cumul (ligne)'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  /// Barres mensuel/annuel + ligne de cumul superposée (même échelle).
  Widget _revenueChart(List<MonthlyRevenuePoint> points) {
    var maxY = 0.0;
    for (final p in points) {
      if (p.total > maxY) maxY = p.total;
      if (p.cumulative > maxY) maxY = p.cumulative;
    }
    maxY = maxY <= 0 ? 1 : maxY * 1.2;

    final groups = <BarChartGroupData>[
      for (var i = 0; i < points.length; i++)
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: points[i].monthlyRevenue,
              color: Colors.cyan.shade300,
              width: 10,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(3),
              ),
            ),
            BarChartRodData(
              toY: points[i].yearlyRevenue,
              color: Colors.purple.shade300,
              width: 10,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(3),
              ),
            ),
          ],
        ),
    ];

    final bottomTitles = AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 30,
        getTitlesWidget: (value, meta) {
          final i = value.toInt();
          if (i < 0 || i >= points.length) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              formatMonthKey(points[i].month).split(' ').first,
              style: const TextStyle(fontSize: 10),
            ),
          );
        },
      ),
    );
    final leftTitles = AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 44,
        getTitlesWidget: (value, meta) => Text(
          value >= 1000
              ? '${(value / 1000).toStringAsFixed(1)}k'
              : '${value.toInt()}',
          style: const TextStyle(fontSize: 10),
        ),
      ),
    );

    return Stack(
      children: [
        BarChart(
          BarChartData(
            maxY: maxY,
            barGroups: groups,
            borderData: FlBorderData(show: false),
            gridData: const FlGridData(show: true, drawVerticalLine: false),
            titlesData: FlTitlesData(
              leftTitles: leftTitles,
              bottomTitles: bottomTitles,
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
            ),
          ),
        ),
        // Ligne de cumul (même échelle maxY, sans axes ni grille propres).
        IgnorePointer(
          child: LineChart(
            LineChartData(
              maxY: maxY,
              minY: 0,
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    for (var i = 0; i < points.length; i++)
                      FlSpot(i.toDouble(), points[i].cumulative),
                  ],
                  isCurved: false,
                  color: Colors.amber.shade300,
                  barWidth: 2,
                  dotData: const FlDotData(show: true),
                ),
              ],
              borderData: FlBorderData(show: false),
              gridData: const FlGridData(show: false),
              titlesData: const FlTitlesData(show: false),
              lineTouchData: const LineTouchData(enabled: false),
            ),
          ),
        ),
      ],
    );
  }

  Widget _splitPieCard(ThemeData theme, AnalyticsOverview? o) {
    final total = o == null ? 0 : o.subsActiveTotal;
    final monthly = o?.subsActiveMonthly ?? 0;
    final yearly = o?.subsActiveYearly ?? 0;
    String pct(int v) =>
        total == 0 ? '0 %' : '${(v / total * 100).toStringAsFixed(0)} %';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Répartition des abonnements actifs',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Stock d\'abonnés actifs (toutes sources).'
              '${o != null && o.subsBySource.isNotEmpty ? ' Sources : ${o.subsBySource.entries.map((e) => '${e.key} ${e.value}').join(' · ')}.' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              child: total == 0
                  ? const Center(child: Text('Aucun abonné actif.'))
                  : PieChart(
                      PieChartData(
                        sectionsSpace: 2,
                        centerSpaceRadius: 42,
                        sections: [
                          PieChartSectionData(
                            value: monthly.toDouble(),
                            title: 'Mensuel\n${pct(monthly)}',
                            color: Colors.cyan.shade300,
                            radius: 70,
                            titleStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                          PieChartSectionData(
                            value: yearly.toDouble(),
                            title: 'Annuel\n${pct(yearly)}',
                            color: Colors.purple.shade300,
                            radius: 70,
                            titleStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              children: [
                _legendDot(Colors.cyan.shade300, 'Mensuel ($monthly)'),
                _legendDot(Colors.purple.shade300, 'Annuel ($yearly)'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Prix catalogue (pricing_config) ──

  Widget _buildPricingSection(ThemeData theme, StoreController store) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Prix catalogue (base des estimations)',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Montants À AJUSTER tant que les prix Play Console ne sont pas '
              'finalisés — toute estimation de revenus en dépend.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Plan')),
                  DataColumn(label: Text('Prix TTC'), numeric: true),
                  DataColumn(label: Text('Devise')),
                  DataColumn(label: Text('Frais Play'), numeric: true),
                  DataColumn(label: Text('')),
                ],
                rows: [
                  for (final p in store.pricingConfigs)
                    DataRow(
                      cells: [
                        DataCell(
                          Text(p.plan == 'monthly' ? 'Mensuel' : 'Annuel'),
                        ),
                        DataCell(Text(p.priceTtc.toStringAsFixed(2))),
                        DataCell(Text(p.currency)),
                        DataCell(Text('${p.playFeePct.toStringAsFixed(0)} %')),
                        DataCell(
                          IconButton(
                            icon: const Icon(Icons.edit_rounded, size: 18),
                            tooltip: store.isOwner
                                ? 'Modifier ce prix'
                                : 'Réservé au compte principal',
                            // pricing/set est owner-only (EF v76) : désactivé
                            // pour un compte secondaire (évite un 403 rouge).
                            onPressed: store.isOwner
                                ? () => _editPricing(store, p)
                                : null,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editPricing(StoreController store, PricingConfig p) async {
    final priceCtrl = TextEditingController(
      text: p.priceTtc.toStringAsFixed(2),
    );
    final feeCtrl = TextEditingController(
      text: p.playFeePct.toStringAsFixed(0),
    );
    final currencyCtrl = TextEditingController(text: p.currency);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Prix — ${p.plan == 'monthly' ? 'Mensuel' : 'Annuel'}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: priceCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Prix TTC',
                hintText: '4.99',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: currencyCtrl,
              decoration: const InputDecoration(
                labelText: 'Devise (ISO 4217)',
                hintText: 'EUR',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: feeCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Frais Play Store (%)',
                hintText: '15 ou 30',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final price = double.tryParse(priceCtrl.text.replaceAll(',', '.'));
    final fee = double.tryParse(feeCtrl.text.replaceAll(',', '.'));
    final currency = currencyCtrl.text.trim().toUpperCase();
    if (price == null || price < 0 || fee == null || fee < 0 || fee > 100) {
      store.reportActionError('Prix/frais invalides — rien enregistré.');
      return;
    }
    await store.setPricing(
      plan: p.plan,
      priceTtc: price,
      currency: currency,
      playFeePct: fee,
    );
    if (!mounted) return;
    await _reloadData(); // les montants affichés dépendent des prix
  }

  // ── Fiscalité (tax_config) ──

  Future<void> _editTaxes(StoreController store) async {
    final taxes = store.taxConfigs;
    final controllers = <String, TextEditingController>{
      for (final t in taxes)
        t.jurisdiction: TextEditingController(
          text: t.vatRate.toStringAsFixed(1),
        ),
    };
    final franchises = <String, bool>{
      for (final t in taxes) t.jurisdiction: t.franchiseBase,
    };
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Juridictions fiscales (projection perso)'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final t in taxes)
                  Row(
                    children: [
                      Expanded(child: Text(t.label)),
                      SizedBox(
                        width: 80,
                        child: TextField(
                          controller: controllers[t.jurisdiction],
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(suffixText: '%'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Column(
                        children: [
                          Checkbox(
                            value: franchises[t.jurisdiction],
                            onChanged: (v) => setDialogState(
                              () => franchises[t.jurisdiction] = v ?? false,
                            ),
                          ),
                          const Text(
                            'franchise',
                            style: TextStyle(fontSize: 10),
                          ),
                        ],
                      ),
                    ],
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    for (final t in taxes) {
      final rate = double.tryParse(
        controllers[t.jurisdiction]!.text.replaceAll(',', '.'),
      );
      if (rate == null || rate < 0 || rate > 100) {
        store.reportActionError(
          'Taux invalide pour ${t.label} — ligne ignorée.',
        );
        continue;
      }
      await store.setTax(
        jurisdiction: t.jurisdiction,
        vatRate: rate,
        franchiseBase: franchises[t.jurisdiction],
      );
    }
  }

  // ── e) Frais de société (company_expenses) ──

  /// Carte affichée aux comptes admin SECONDAIRES à la place des sections
  /// « Frais de société » et « Exports comptables » : ces données
  /// financières sont réservées au compte principal (l'EF renvoie 403 sur
  /// `expenses/*` sinon). Message neutre — pas d'erreur, pas de CRUD.
  Widget _buildOwnerOnlyFinanceCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.lock_outline_rounded, color: Colors.grey.shade400),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Section réservée au compte principal',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Les frais de société et les exports comptables sont '
                    'réservés au compte principal. Les indicateurs et '
                    'graphiques ci-dessus restent accessibles à tous les '
                    'comptes admin.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpensesSection(ThemeData theme, StoreController store) {
    String fmtDate(DateTime? d) => d == null
        ? '—'
        : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Frais de société', style: theme.textTheme.titleMedium),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => _editExpense(store, null),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Ajouter'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Ventilation au mois de paiement dans les exports : mensuel = '
              'chaque mois entre début et fin ; annuel = mois de la 1re '
              'souscription ; ponctuel = mois de début.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Libellé')),
                  DataColumn(label: Text('Catégorie')),
                  DataColumn(label: Text('Montant'), numeric: true),
                  DataColumn(label: Text('Récurrence')),
                  DataColumn(label: Text('Début')),
                  DataColumn(label: Text('Fin')),
                  DataColumn(label: Text('Actif')),
                  DataColumn(label: Text('')),
                ],
                rows: [
                  for (final e in store.companyExpenses)
                    DataRow(
                      cells: [
                        DataCell(Text(e.label)),
                        DataCell(Text(e.category)),
                        DataCell(
                          Text('${e.amount.toStringAsFixed(2)} ${e.currency}'),
                        ),
                        DataCell(
                          Text(switch (e.recurrence) {
                            'monthly' => 'Mensuel',
                            'yearly' => 'Annuel',
                            'once' => 'Ponctuel',
                            _ => e.recurrence,
                          }),
                        ),
                        DataCell(Text(fmtDate(e.startedOn))),
                        DataCell(Text(fmtDate(e.endedOn))),
                        DataCell(
                          Switch(
                            value: e.active,
                            onChanged: (v) => store.upsertExpense(
                              ExpenseEntry(
                                id: e.id,
                                label: e.label,
                                category: e.category,
                                amount: e.amount,
                                currency: e.currency,
                                recurrence: e.recurrence,
                                startedOn: e.startedOn,
                                endedOn: e.endedOn,
                                active: v,
                                notes: e.notes,
                              ),
                            ),
                          ),
                        ),
                        DataCell(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_rounded, size: 18),
                                tooltip: 'Modifier',
                                onPressed: () => _editExpense(store, e),
                              ),
                              if (e.id != null)
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_rounded,
                                    size: 18,
                                  ),
                                  tooltip: 'Supprimer',
                                  onPressed: () => showDialog<void>(
                                    context: context,
                                    builder: (_) => ConfirmDialog(
                                      title: 'Supprimer ce frais ?',
                                      message:
                                          '« ${e.label} » sera retiré des '
                                          'exports comptables futurs.',
                                      confirmLabel: 'Supprimer',
                                      destructive: true,
                                      onConfirm: () => context
                                          .read<StoreController>()
                                          .deleteExpense(e.id!),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editExpense(StoreController store, ExpenseEntry? e) async {
    final labelCtrl = TextEditingController(text: e?.label ?? '');
    final categoryCtrl = TextEditingController(text: e?.category ?? 'divers');
    final amountCtrl = TextEditingController(
      text: e == null ? '' : e.amount.toStringAsFixed(2),
    );
    final currencyCtrl = TextEditingController(text: e?.currency ?? 'USD');
    final notesCtrl = TextEditingController(text: e?.notes ?? '');
    var recurrence = e?.recurrence ?? 'monthly';
    var startedOn = e?.startedOn ?? DateTime.now();
    DateTime? endedOn = e?.endedOn;
    var active = e?.active ?? true;

    String fmt(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(e == null ? 'Ajouter un frais' : 'Modifier le frais'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: labelCtrl,
                    decoration: const InputDecoration(labelText: 'Libellé'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: categoryCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Catégorie',
                      hintText: 'infra / saas / store / domaine…',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: amountCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Montant',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 90,
                        child: TextField(
                          controller: currencyCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Devise',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: recurrence,
                    decoration: const InputDecoration(labelText: 'Récurrence'),
                    items: const [
                      DropdownMenuItem(
                        value: 'monthly',
                        child: Text('Mensuel'),
                      ),
                      DropdownMenuItem(value: 'yearly', child: Text('Annuel')),
                      DropdownMenuItem(value: 'once', child: Text('Ponctuel')),
                    ],
                    onChanged: (v) =>
                        setDialogState(() => recurrence = v ?? 'monthly'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: dialogContext,
                            initialDate: startedOn,
                            firstDate: DateTime(2020),
                            lastDate: DateTime(DateTime.now().year + 5),
                          );
                          if (d != null) {
                            setDialogState(() => startedOn = d);
                          }
                        },
                        icon: const Icon(
                          Icons.calendar_today_rounded,
                          size: 16,
                        ),
                        label: Text('Début : ${fmt(startedOn)}'),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () async {
                          final d = await showDatePicker(
                            context: dialogContext,
                            initialDate: endedOn ?? startedOn,
                            firstDate: startedOn,
                            lastDate: DateTime(DateTime.now().year + 10),
                          );
                          if (d != null) setDialogState(() => endedOn = d);
                        },
                        icon: const Icon(Icons.event_rounded, size: 16),
                        label: Text(
                          endedOn == null
                              ? 'Fin : —'
                              : 'Fin : ${fmt(endedOn!)}',
                        ),
                      ),
                      if (endedOn != null)
                        IconButton(
                          onPressed: () => setDialogState(() => endedOn = null),
                          icon: const Icon(Icons.clear_rounded, size: 16),
                          tooltip: 'Sans fin',
                        ),
                    ],
                  ),
                  Row(
                    children: [
                      Checkbox(
                        value: active,
                        onChanged: (v) =>
                            setDialogState(() => active = v ?? true),
                      ),
                      const Text('Actif (inclus dans les exports)'),
                    ],
                  ),
                  TextField(
                    controller: notesCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optionnel)',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;

    final amount = double.tryParse(amountCtrl.text.replaceAll(',', '.'));
    if (labelCtrl.text.trim().isEmpty || amount == null || amount < 0) {
      store.reportActionError('Libellé/montant invalides — rien enregistré.');
      return;
    }
    await store.upsertExpense(
      ExpenseEntry(
        id: e?.id,
        label: labelCtrl.text.trim(),
        category: categoryCtrl.text.trim().isEmpty
            ? 'divers'
            : categoryCtrl.text.trim(),
        amount: amount,
        currency: currencyCtrl.text.trim().toUpperCase(),
        recurrence: recurrence,
        startedOn: startedOn,
        endedOn: endedOn,
        active: active,
        notes: notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
      ),
    );
  }

  // ── f) Exports comptables ──

  Widget _buildExportsSection(ThemeData theme, StoreController store) {
    final now = DateTime.now();
    final years = [for (var y = 2026; y <= now.year + 1; y++) y];
    const monthLabels = [
      'janvier',
      'février',
      'mars',
      'avril',
      'mai',
      'juin',
      'juillet',
      'août',
      'septembre',
      'octobre',
      'novembre',
      'décembre',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Exports comptables (Excel .xlsx)',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Revenus estimés du mois (détail par plan) − frais ventilés au '
              'mois de paiement = solde net par devise. Juridiction et '
              'HT/TTC appliqués = options ci-dessus au moment de l\'export.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<int>(
                  value: _exportMonth,
                  items: [
                    for (var m = 1; m <= 12; m++)
                      DropdownMenuItem(
                        value: m,
                        child: Text(monthLabels[m - 1]),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _exportMonth = v);
                  },
                ),
                DropdownButton<int>(
                  value: _exportYear,
                  items: [
                    for (final y in years)
                      DropdownMenuItem(value: y, child: Text('$y')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _exportYear = v);
                  },
                ),
                FilledButton.icon(
                  onPressed: _exporting ? null : _exportMonthXlsx,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(
                    _exporting
                        ? 'Génération…'
                        : 'Export du mois '
                              '(${_exportMonth.toString().padLeft(2, '0')}/$_exportYear)',
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _exporting ? null : _exportYearXlsx,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(
                    'Export année $_exportYear (12 onglets + synthèse)',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Carte KPI du menu Analytics (style aligné sur _countCard de
/// limites_screen : fond noir 25 %, bord blanc 10 %, radius 8) + infobulle
/// de définition. [disabled] = carte grisée « disponible après F2 ».
class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final String? subtitle;
  final String tooltip;
  final bool disabled;

  const _KpiCard({
    required this.label,
    required this.value,
    this.subtitle,
    required this.tooltip,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final opacity = disabled ? 0.45 : 1.0;
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: opacity,
        child: SizedBox(
          width: 240,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: disabled ? Colors.grey : Colors.cyan.shade300,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
                if (disabled) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'chantier F2',
                    style: TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
