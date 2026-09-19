// dart:html est le pattern déjà utilisé par le projet (logs_screen.dart,
// auth_service.dart, store.dart) pour Blob/localStorage — app Flutter Web
// uniquement.
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';

import '../../domain/analytics_calc.dart';
import '../../domain/analytics_export.dart';
import '../../state/store_controller.dart';
import '../widgets/confirm_dialog.dart';

/// Domaine public du site MyGamingTips, utilisé par le générateur de liens
/// UTM de la section « Acquisition ».
///
/// ⚠️ PLACEHOLDER (chantier F3, §70.5) : le site est EN CONSTRUCTION et son
/// domaine final n'apparaît ni dans PRODUCT.md ni dans le README. Remplacer
/// par le domaine définitif AVANT de diffuser des liens générés — le format
/// des liens est celui de docs/INSTRUCTIONS_SITE_LIEN_PLAYSTORE.md §4.
const String kSiteBaseUrl = 'https://www.mygamingtips.fr';

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

  // ── Acquisition (chantier F3 — EF v78, migration 0069) ──
  /// Toggle « Play Store : global / hors redirections site » (exclut
  /// play_store_via_site du graphique d'attribution).
  bool _acqExcludeSiteRedirects = false;

  /// Générateur de liens UTM : canal sélectionné + champ campagne.
  String _utmChannel = kUtmGeneratorChannels.first;
  final TextEditingController _utmCampaignCtrl = TextEditingController();

  @override
  void dispose() {
    _utmCampaignCtrl.dispose();
    super.dispose();
  }

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
  /// Chantier F2 : charge aussi l'activité quotidienne (période exacte) et
  /// les cohortes de rétention (8 semaines glissantes, indépendantes de la
  /// période).
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
      store.fetchAnalyticsActivity(from: _from, to: _to),
      store.fetchAnalyticsRetention(),
      // Chantier F3 : attribution des comptes + clics site → store.
      store.fetchAnalyticsAcquisition(from: _from, to: _to),
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
          // Chantier F2 (EF v77, migration 0067) : usage réel de l'app.
          _buildActivitySection(theme, store),
          const SizedBox(height: 16),
          _buildRetentionSection(theme, store),
          const SizedBox(height: 16),
          // Chantier F3 (EF v78, migration 0069) : attribution + liens UTM.
          _buildAcquisitionSection(theme, store),
          const SizedBox(height: 16),
          _buildClicksCard(theme, store),
          const SizedBox(height: 16),
          _buildUtmGeneratorCard(theme),
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
        // Chantier F2 (EF v77, migration 0067) : cartes d'usage RÉELLES —
        // avant F2, deux cartes grisées « — » occupaient ces emplacements.
        _KpiCard(
          label: 'DAU (aujourd\'hui)',
          value: o == null ? '…' : '${o.dauToday}',
          subtitle: 'utilisateurs actifs du jour (jour UTC)',
          tooltip:
              'Daily Active Users : comptes distincts ayant émis au moins '
              'un événement (session, contenu ou jeu) aujourd\'hui. '
              'Source : instrumentation de l\'app (chantier F2).',
        ),
        _KpiCard(
          label: 'MAU (30 j glissants)',
          value: o == null ? '…' : '${o.mau30d}',
          subtitle: 'utilisateurs distincts sur 30 jours',
          tooltip:
              'Monthly Active Users : comptes distincts ayant émis au moins '
              'un événement sur les 30 derniers jours glissants.',
        ),
        _KpiCard(
          label: 'Utilisations moyennes / utilisateur / jour',
          value: o == null
              ? '…'
              : avgSessionsPerUserPerDay(o.sessions30d, o.activeUsers30d)
                  .toStringAsFixed(1),
          subtitle: o == null
              ? null
              : '${o.sessions30d} sessions ÷ ${o.activeUsers30d} actifs ÷ 30 j',
          tooltip:
              'Sessions (ouvertures/reprises de l\'app) sur 30 jours '
              'glissants, divisées par les utilisateurs actifs de la même '
              'fenêtre puis par 30. Mesure l\'assiduité moyenne.',
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

  // ── Chantier F2 : activité quotidienne + rétention (EF v77, 0067) ──

  /// Message d'état vide commun aux sections F2 : l'instrumentation démarre
  /// avec la prochaine version de l'app, aucune donnée n'existe avant.
  static const String _f2EmptyMessage =
      'L\'instrumentation démarre avec la prochaine version de l\'app — '
      'aucune donnée pour l\'instant';

  Widget _buildActivitySection(ThemeData theme, StoreController store) {
    final days = store.analyticsActivity;
    final hasData = days.any(
      (d) =>
          d.dau > 0 || d.sessions > 0 || d.contentViews > 0 || d.gameViews > 0,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Activité quotidienne (usage réel de l\'app)',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Événements remontés par l\'app sur la période sélectionnée '
              '(jours calendaires UTC). L\'agrégat historique survit à la '
              'purge des événements bruts (90 jours).',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (!hasData)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(
                    _f2EmptyMessage,
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              SizedBox(height: 260, child: _activityChart(days)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _legendDot(Colors.cyan.shade300, 'Sessions'),
                _legendDot(Colors.purple.shade300, 'Contenus visionnés'),
                _legendDot(Colors.amber.shade300, 'Jeux consultés'),
                _legendDot(Colors.greenAccent.shade200, 'Utilisateurs actifs'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 4 courbes (sessions / contenus / jeux / utilisateurs actifs) sur la
  /// période. Les jours sans événement valent 0 (continuité des courbes).
  Widget _activityChart(List<ActivityDay> days) {
    final byDay = {for (final d in days) d.day: d};
    final n = _to.difference(_from).inDays + 1;
    final labels = <String>[];
    final sessions = <FlSpot>[];
    final contents = <FlSpot>[];
    final games = <FlSpot>[];
    final dau = <FlSpot>[];
    var maxY = 0.0;
    double y(int v) => v.toDouble();
    for (var i = 0; i < n; i++) {
      final date = _from.add(Duration(days: i));
      final key =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      labels.add(key);
      final d = byDay[key];
      sessions.add(FlSpot(i.toDouble(), y(d?.sessions ?? 0)));
      contents.add(FlSpot(i.toDouble(), y(d?.contentViews ?? 0)));
      games.add(FlSpot(i.toDouble(), y(d?.gameViews ?? 0)));
      dau.add(FlSpot(i.toDouble(), y(d?.dau ?? 0)));
      for (final v in [
        d?.sessions ?? 0,
        d?.contentViews ?? 0,
        d?.gameViews ?? 0,
        d?.dau ?? 0,
      ]) {
        if (v > maxY) maxY = v.toDouble();
      }
    }
    maxY = maxY <= 0 ? 1 : maxY * 1.2;
    // Un libellé d'axe toutes les ~N divisions pour rester lisible.
    final labelEvery = (n / 8).ceil();

    LineChartBarData line(List<FlSpot> spots, Color color) => LineChartBarData(
          spots: spots,
          isCurved: false,
          color: color,
          barWidth: 2,
          dotData: const FlDotData(show: false),
        );

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY,
        lineBarsData: [
          line(sessions, Colors.cyan.shade300),
          line(contents, Colors.purple.shade300),
          line(games, Colors.amber.shade300),
          line(dau, Colors.greenAccent.shade200),
        ],
        borderData: FlBorderData(show: false),
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        lineTouchData: const LineTouchData(enabled: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (value, meta) => Text(
                '${value.toInt()}',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= labels.length || i % labelEvery != 0) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    formatDayLabel(labels[i]),
                    style: const TextStyle(fontSize: 10),
                  ),
                );
              },
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
      ),
    );
  }

  Widget _buildRetentionSection(ThemeData theme, StoreController store) {
    final cohorts = store.analyticsRetention;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Rétention par cohorte (inscriptions hebdomadaires)',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Part des inscrits de la semaine revenus à J+1 / J+7 / J+30 '
              '(jour calendaire après l\'inscription). « — » = fenêtre pas '
              'encore écoulée pour toute la cohorte (taux non mesurable).',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (cohorts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(
                    _f2EmptyMessage,
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Semaine')),
                    DataColumn(label: Text('Inscrits'), numeric: true),
                    DataColumn(label: Text('D1 %'), numeric: true),
                    DataColumn(label: Text('D7 %'), numeric: true),
                    DataColumn(label: Text('D30 %'), numeric: true),
                  ],
                  rows: [
                    for (final c in cohorts)
                      DataRow(
                        cells: [
                          DataCell(Text(
                              'Sem. du ${formatCohortWeek(c.cohortStart)}')),
                          DataCell(Text('${c.size}')),
                          DataCell(
                              _retentionPctCell(c.cohortStart, 1, c.d1Pct)),
                          DataCell(
                              _retentionPctCell(c.cohortStart, 7, c.d7Pct)),
                          DataCell(
                              _retentionPctCell(c.cohortStart, 30, c.d30Pct)),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(height: 240, child: _retentionChart(cohorts)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  _legendDot(Colors.cyan.shade300, 'D1 %'),
                  _legendDot(Colors.purple.shade300, 'D7 %'),
                  _legendDot(Colors.amber.shade300, 'D30 %'),
                  _legendDash(
                      Colors.greenAccent.shade200, 'excellent ≥ 40 %'),
                  _legendDash(Colors.orange.shade300, 'bon ≥ 20 %'),
                  _legendDash(Colors.red.shade300, 'à surveiller ≥ 10 %'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Cellule de % colorée selon le niveau de rétention (« — » si la fenêtre
  /// de mesure n'est pas écoulée pour toute la cohorte).
  Widget _retentionPctCell(DateTime cohortStart, int offsetDays, double pct) {
    if (!isCohortMeasurable(cohortStart, offsetDays, DateTime.now())) {
      return const Text('—', style: TextStyle(color: Colors.grey));
    }
    final color = switch (retentionBand(pct)) {
      RetentionBand.excellent => Colors.greenAccent.shade200,
      RetentionBand.good => Colors.cyan.shade300,
      RetentionBand.watch => Colors.orange.shade300,
      RetentionBand.low => Colors.red.shade300,
    };
    return Text(
      '${pct.toStringAsFixed(1)} %',
      style: TextStyle(color: color, fontWeight: FontWeight.w600),
    );
  }

  /// Tirets de légende pour les lignes de référence horizontales.
  Widget _legendDash(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 14, height: 2, color: color),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  /// Courbes D1/D7/D30 par cohorte (de la plus ancienne à la plus récente)
  /// + lignes de référence horizontales à 40 % / 20 % / 10 % (repères
  /// produit : excellent / bon / à surveiller).
  Widget _retentionChart(List<RetentionCohort> cohorts) {
    // SQL retourne les cohortes les plus récentes d'abord → on inverse.
    final ordered = cohorts.reversed.toList();
    final today = DateTime.now();
    List<FlSpot> spots(int offsetDays, double Function(RetentionCohort) pct) {
      final result = <FlSpot>[];
      for (var i = 0; i < ordered.length; i++) {
        final c = ordered[i];
        if (!isCohortMeasurable(c.cohortStart, offsetDays, today)) continue;
        result.add(FlSpot(i.toDouble(), pct(c)));
      }
      return result;
    }

    final labelEvery = (ordered.length / 8).ceil();
    LineChartBarData line(List<FlSpot> s, Color color) => LineChartBarData(
          spots: s,
          isCurved: false,
          color: color,
          barWidth: 2,
          dotData: const FlDotData(show: true),
        );

    HorizontalLine refLine(double y, Color color, String label) =>
        HorizontalLine(
          y: y,
          color: color.withValues(alpha: 0.55),
          strokeWidth: 1,
          dashArray: [6, 4],
          label: HorizontalLineLabel(
            show: true,
            alignment: Alignment.topRight,
            style: TextStyle(fontSize: 10, color: color),
            labelResolver: (_) => label,
          ),
        );

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: 100,
        lineBarsData: [
          line(spots(1, (c) => c.d1Pct), Colors.cyan.shade300),
          line(spots(7, (c) => c.d7Pct), Colors.purple.shade300),
          line(spots(30, (c) => c.d30Pct), Colors.amber.shade300),
        ],
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            refLine(40, Colors.greenAccent.shade200, 'excellent ≥ 40 %'),
            refLine(20, Colors.orange.shade300, 'bon ≥ 20 %'),
            refLine(10, Colors.red.shade300, 'à surveiller ≥ 10 %'),
          ],
        ),
        borderData: FlBorderData(show: false),
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        lineTouchData: const LineTouchData(enabled: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: 20,
              getTitlesWidget: (value, meta) => Text(
                '${value.toInt()} %',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= ordered.length || i % labelEvery != 0) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    formatCohortWeek(ordered[i].cohortStart),
                    style: const TextStyle(fontSize: 10),
                  ),
                );
              },
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
      ),
    );
  }

  // ── Acquisition (chantier F3 — EF v78, migration 0069, §70.5) ──

  /// Copie [text] dans le presse-papiers + snackbar de confirmation.
  Future<void> _copyToClipboard(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copié dans le presse-papiers.')),
    );
  }

  /// Section « Acquisition » : bar chart des comptes par canal (first touch,
  /// global) + toggle « Play Store : global / hors redirections site ».
  Widget _buildAcquisitionSection(ThemeData theme, StoreController store) {
    final acq = store.analyticsAcquisition;
    // Toggle « hors redirections site » : exclut play_store_via_site (les
    // installs venues du site sans UTM externe — instructions §5).
    final exclude = _acqExcludeSiteRedirects ? 'play_store_via_site' : null;
    final global = acq?.firstGlobal ?? const <String, int>{};
    final period = acq?.firstPeriod ?? const <String, int>{};
    final entries = [
      for (final s in kAcquisitionSources)
        if (s != exclude && (global[s] ?? 0) > 0) MapEntry(s, global[s] ?? 0),
    ];
    final totalGlobal = acquisitionTotal(global, exclude: exclude);
    final totalPeriod = acquisitionTotal(period, exclude: exclude);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Acquisition — canaux des comptes (premier contact)',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Attribution via le Play Install Referrer lu par l\'app au 1er '
              'lancement (migration 0069). « Inconnu » = comptes créés avant '
              'l\'instrumentation ou installs iOS (pas de referrer).',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Play Store : global'),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Hors redirections site'),
                ),
              ],
              selected: {_acqExcludeSiteRedirects},
              onSelectionChanged: (s) =>
                  setState(() => _acqExcludeSiteRedirects = s.first),
            ),
            const SizedBox(height: 12),
            if (acq == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(
                    'Données d\'acquisition indisponibles (EF v78 non '
                    'déployée ou migration 0069 non appliquée).',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else if (entries.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(
                    'Aucun compte attribué pour l\'instant — '
                    'l\'instrumentation démarre avec la prochaine version de '
                    'l\'app.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else ...[
              SizedBox(height: 240, child: _acquisitionBarChart(entries)),
              const SizedBox(height: 8),
              Text(
                '$totalGlobal compte(s) au total'
                '${_acqExcludeSiteRedirects ? ' (hors redirections site)' : ''}'
                ' — dont $totalPeriod créé(s) sur la période sélectionnée.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Bar chart first-touch : une barre par canal présent (ordre fixe de
  /// [kAcquisitionSources]), valeur = comptes globaux.
  Widget _acquisitionBarChart(List<MapEntry<String, int>> entries) {
    final maxV = entries.fold<int>(0, (m, e) => e.value > m ? e.value : m);
    final maxY = (maxV <= 0 ? 1 : maxV * 1.25).toDouble();
    return BarChart(
      BarChartData(
        minY: 0,
        maxY: maxY,
        borderData: FlBorderData(show: false),
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final source = entries[group.x.toInt()].key;
              return BarTooltipItem(
                '${kAcquisitionSourceLabels[source] ?? source}\n'
                '${rod.toY.round()} compte(s)',
                const TextStyle(color: Colors.white, fontSize: 12),
              );
            },
          ),
        ),
        barGroups: [
          for (var i = 0; i < entries.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: entries[i].value.toDouble(),
                  width: 22,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                  color: entries[i].key == 'inconnu'
                      ? Colors.grey.shade600
                      : Colors.cyan.shade300,
                ),
              ],
            ),
        ],
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, meta) => v == meta.max
                  ? const SizedBox.shrink()
                  : Text(
                      v.round().toString(),
                      style: const TextStyle(fontSize: 10),
                    ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= entries.length) {
                  return const SizedBox.shrink();
                }
                final source = entries[i].key;
                // Libellés courts : le tooltip porte le libellé complet.
                final short = switch (source) {
                  'play_store_via_site' => 'PS via site',
                  'play_store' => 'Play Store',
                  'site_web' => 'Site',
                  'inconnu' => 'Inconnu',
                  _ => (kAcquisitionSourceLabels[source] ?? source),
                };
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(short, style: const TextStyle(fontSize: 10)),
                );
              },
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
      ),
    );
  }

  /// Carte « Redirections site → store » : clics du bouton « Télécharger »
  /// du site (EF publique acquisition-track) sur la période sélectionnée.
  Widget _buildClicksCard(ThemeData theme, StoreController store) {
    final acq = store.analyticsAcquisition;
    final clicks = acq?.clicks ?? const <AcquisitionClick>[];
    final total = acq?.clicksTotal ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Redirections site → Play Store',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Clics sur le bouton « Télécharger » du site sur la période '
              '(comptés par l\'endpoint public acquisition-track — aucune '
              'donnée personnelle).',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (acq == null)
              Text('Indisponible (EF v78 non déployée).',
                  style: theme.textTheme.bodySmall)
            else ...[
              Text(
                '$total clic(s) sur la période',
                style: theme.textTheme.titleLarge,
              ),
              if (acq.clicksTruncated)
                Text(
                  'Liste plafonnée (50 000 lignes) — total exact, détail '
                  'partiel.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.orange.shade300),
                ),
              if (clicks.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final c in clicks.take(5))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${kAcquisitionSourceLabels[c.source] ?? c.source} · '
                      '${c.campaign ?? '(sans campagne)'} — ${c.n}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                if (clicks.length > 5)
                  Text(
                    '… et ${clicks.length - 5} autre(s) combinaison(s).',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Générateur de liens UTM (instructions site §4) : produit le lien SITE à
  /// diffuser (le site propage les UTM vers le store) et le lien PLAY STORE
  /// direct avec referrer encodé. Mêmes bornes que l'EF acquisition-track
  /// pour la campagne ([A-Za-z0-9._~-], ≤ 120).
  Widget _buildUtmGeneratorCard(ThemeData theme) {
    final campaign = _utmCampaignCtrl.text.trim();
    final valid = isValidUtmCampaign(campaign);
    final siteLink = valid
        ? buildSiteUtmLink(
            siteBaseUrl: kSiteBaseUrl,
            channel: _utmChannel,
            campaign: campaign,
          )
        : null;
    final playLink = valid
        ? buildPlayStoreReferrerLink(
            channel: _utmChannel,
            campaign: campaign,
          )
        : null;

    Widget linkRow(String label, String? link) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  link ?? '—',
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              IconButton(
                onPressed:
                    link == null ? null : () => _copyToClipboard(link, label),
                icon: const Icon(Icons.copy_rounded, size: 18),
                tooltip: 'Copier',
              ),
            ],
          ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Générateur de liens UTM',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Diffusez le LIEN SITE (le site propage les UTM vers le Play '
              'Store). Le lien Play direct est un secours sans passage par '
              'le site. Campagne : lettres/chiffres et . _ ~ - uniquement.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Canal : '),
                    DropdownButton<String>(
                      value: _utmChannel,
                      items: [
                        for (final c in kUtmGeneratorChannels)
                          DropdownMenuItem(
                            value: c,
                            child: Text(kAcquisitionSourceLabels[c] ?? c),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _utmChannel = v);
                      },
                    ),
                  ],
                ),
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: _utmCampaignCtrl,
                    decoration: InputDecoration(
                      labelText: 'Campagne',
                      hintText: 'ex. lancement',
                      isDense: true,
                      errorText: campaign.isEmpty || valid
                          ? null
                          : 'Invalide ([A-Za-z0-9._~-], ≤ 120)',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            linkRow('Lien site (à diffuser)', siteLink),
            const SizedBox(height: 8),
            linkRow('Lien Play Store direct (secours)', playLink),
            const SizedBox(height: 8),
            Text(
              '⚠️ Domaine du site : placeholder ($kSiteBaseUrl) — à confirmer '
              'avant diffusion (le site est en construction).',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Colors.orange.shade300),
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
/// de définition. (Le mode grisé « placeholder » de F1 a disparu avec la
/// livraison F2 : toutes les cartes affichent des données réelles.)
class _KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final String? subtitle;
  final String tooltip;

  const _KpiCard({
    required this.label,
    required this.value,
    this.subtitle,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
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
                  color: Colors.cyan.shade300,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
