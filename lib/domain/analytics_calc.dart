/// Chantier F1 (menu « Analytics ») — modèles légers + fonctions PURES de
/// calcul (décisions §70.3 / §70.6).
///
/// ⚠️ Ce fichier est volontairement SANS dépendance Flutter ni dart:html :
/// il est testable en VM (`dart test` / `flutter test`) et réutilisable
/// par l'écran Analytics ET par le générateur d'exports Excel.
///
/// Règles métier implémentées :
/// - Revenus = ESTIMATION catalogue (prix × achats réels) — aucun montant
///   réel n'est stocké sur les abonnements (à date : 0 achat Play réel,
///   les abonnements offerts source admin/reward sont exclus du CA).
/// - HT = TTC / (1 + taux) ; SAUF franchise en base (HT = TTC, §70.6).
/// - Frais Play Store : déduits du TTC AVANT conversion HT (Play prélève sa
///   commission sur le prix payé par l'utilisateur, puis gère la TVA) —
///   ordre documenté : net = TTC × (1 − fee), puis HT = net / (1 + taux).
/// - Ventilation des frais au MOIS DE PAIEMENT (fidélité trésorerie §70.6) :
///   monthly = chaque mois entre started_on et ended_on (ou sans fin) ;
///   yearly  = chaque année au mois de started_on.month ;
///   once    = uniquement le mois de started_on.
library;

// ─────────────────────────────────────────────────────────────────────────────
// Modèles (miroirs des tables de la migration 0066)
// ─────────────────────────────────────────────────────────────────────────────

/// Prix catalogue d'un plan Plus (table `pricing_config`).
class PricingConfig {
  final int? id;
  final String plan; // 'monthly' | 'yearly'
  final double priceTtc;
  final String currency; // code ISO 4217 (ex. 'EUR')
  final double playFeePct; // frais Play Store en % (15 ou 30)
  final bool active;

  const PricingConfig({
    this.id,
    required this.plan,
    required this.priceTtc,
    this.currency = 'EUR',
    this.playFeePct = 15,
    this.active = true,
  });

  factory PricingConfig.fromJson(Map<String, dynamic> json) => PricingConfig(
        id: (json['id'] as num?)?.toInt(),
        plan: (json['plan'] as String?) ?? 'monthly',
        priceTtc: (json['price_ttc'] as num?)?.toDouble() ?? 0,
        currency: (json['currency'] as String?) ?? 'EUR',
        playFeePct: (json['play_fee_pct'] as num?)?.toDouble() ?? 15,
        active: (json['active'] as bool?) ?? true,
      );
}

/// Juridiction fiscale de projection (table `tax_config` — §70.6).
class TaxConfig {
  final String jurisdiction; // 'france' | 'thailande' | 'hongkong'
  final String label;
  final double vatRate; // en % (20 / 7 / 0)
  final bool franchiseBase; // true → HT = TTC (franchise en base de TVA)
  final bool active;

  const TaxConfig({
    required this.jurisdiction,
    required this.label,
    required this.vatRate,
    this.franchiseBase = false,
    this.active = true,
  });

  factory TaxConfig.fromJson(Map<String, dynamic> json) => TaxConfig(
        jurisdiction: (json['jurisdiction'] as String?) ?? 'france',
        label: (json['label'] as String?) ?? '',
        vatRate: (json['vat_rate'] as num?)?.toDouble() ?? 0,
        franchiseBase: (json['franchise_base'] as bool?) ?? false,
        active: (json['active'] as bool?) ?? true,
      );
}

/// Frais de société (table `company_expenses` — §70.6).
class ExpenseEntry {
  final int? id;
  final String label;
  final String category;
  final double amount;
  final String currency;
  final String recurrence; // 'monthly' | 'yearly' | 'once'
  final DateTime startedOn; // date seule (heures ignorées)
  final DateTime? endedOn; // null = sans fin
  final bool active;
  final String? notes;

  const ExpenseEntry({
    this.id,
    required this.label,
    this.category = 'divers',
    required this.amount,
    this.currency = 'USD',
    required this.recurrence,
    required this.startedOn,
    this.endedOn,
    this.active = true,
    this.notes,
  });

  factory ExpenseEntry.fromJson(Map<String, dynamic> json) => ExpenseEntry(
        id: (json['id'] as num?)?.toInt(),
        label: (json['label'] as String?) ?? '',
        category: (json['category'] as String?) ?? 'divers',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        currency: (json['currency'] as String?) ?? 'USD',
        recurrence: (json['recurrence'] as String?) ?? 'monthly',
        startedOn: DateTime.tryParse((json['started_on'] as String?) ?? '') ??
            DateTime(1970),
        endedOn: json['ended_on'] == null
            ? null
            : DateTime.tryParse(json['ended_on'] as String),
        active: (json['active'] as bool?) ?? true,
        notes: json['notes'] as String?,
      );
}

/// Bucket temporel retourné par la route EF `analytics/series`.
class SeriesBucket {
  final String key; // 'YYYY-MM-DD' (day) ou 'YYYY-MM' (month)
  final int monthly; // nouvelles souscriptions mensuelles (toutes sources)
  final int yearly; // nouvelles souscriptions annuelles (toutes sources)
  final int monthlyPaid; // achats RÉELS mensuels (source ∉ admin/reward)
  final int yearlyPaid; // achats RÉELS annuels

  const SeriesBucket({
    required this.key,
    this.monthly = 0,
    this.yearly = 0,
    this.monthlyPaid = 0,
    this.yearlyPaid = 0,
  });

  int get total => monthly + yearly;
  int get totalPaid => monthlyPaid + yearlyPaid;

  factory SeriesBucket.fromJson(Map<String, dynamic> json) => SeriesBucket(
        key: (json['key'] as String?) ?? '',
        monthly: (json['monthly'] as num?)?.toInt() ?? 0,
        yearly: (json['yearly'] as num?)?.toInt() ?? 0,
        monthlyPaid: (json['monthly_paid'] as num?)?.toInt() ?? 0,
        yearlyPaid: (json['yearly_paid'] as num?)?.toInt() ?? 0,
      );
}

/// Vue agrégée retournée par la route EF `analytics/overview`.
class AnalyticsOverview {
  final int accountsTotal;
  final int accountsNew; // comptes créés sur la période
  final int subsActiveTotal;
  final int subsActiveMonthly;
  final int subsActiveYearly;
  final Map<String, int> subsBySource; // actifs par source
  final int newSubsTotal; // nouvelles souscriptions sur la période
  final int newSubsMonthly;
  final int newSubsYearly;
  final int newPaidTotal; // achats réels sur la période
  final int newPaidMonthly;
  final int newPaidYearly;
  final double revenueEstimatedTtc; // achats réels × prix catalogue
  final String currency;

  // ── Bloc `usage` (EF v77, migration 0067 — chantier F2) ──
  final int dauToday; // utilisateurs actifs du jour (jour UTC)
  final int mau30d; // utilisateurs actifs sur 30 jours glissants
  final int sessions30d; // session_start sur 30 jours glissants
  final int activeUsers30d; // utilisateurs distincts sur 30 jours glissants

  const AnalyticsOverview({
    this.accountsTotal = 0,
    this.accountsNew = 0,
    this.subsActiveTotal = 0,
    this.subsActiveMonthly = 0,
    this.subsActiveYearly = 0,
    this.subsBySource = const {},
    this.newSubsTotal = 0,
    this.newSubsMonthly = 0,
    this.newSubsYearly = 0,
    this.newPaidTotal = 0,
    this.newPaidMonthly = 0,
    this.newPaidYearly = 0,
    this.revenueEstimatedTtc = 0,
    this.currency = 'EUR',
    this.dauToday = 0,
    this.mau30d = 0,
    this.sessions30d = 0,
    this.activeUsers30d = 0,
  });

  factory AnalyticsOverview.fromJson(Map<String, dynamic> json) {
    final active = json['subscribers_active'] as Map<String, dynamic>? ?? {};
    final fresh = json['new_subscriptions'] as Map<String, dynamic>? ?? {};
    final paid = fresh['paid'] as Map<String, dynamic>? ?? {};
    final revenue = json['revenue'] as Map<String, dynamic>? ?? {};
    final usage = json['usage'] as Map<String, dynamic>? ?? {};
    final bySource = <String, int>{};
    (json['subscribers_by_source'] as Map<String, dynamic>? ?? {})
        .forEach((k, v) {
      bySource[k] = (v as num?)?.toInt() ?? 0;
    });
    return AnalyticsOverview(
      accountsTotal: (json['accounts_total'] as num?)?.toInt() ?? 0,
      accountsNew: (json['accounts_new'] as num?)?.toInt() ?? 0,
      subsActiveTotal: (active['total'] as num?)?.toInt() ?? 0,
      subsActiveMonthly: (active['monthly'] as num?)?.toInt() ?? 0,
      subsActiveYearly: (active['yearly'] as num?)?.toInt() ?? 0,
      subsBySource: bySource,
      newSubsTotal: (fresh['total'] as num?)?.toInt() ?? 0,
      newSubsMonthly: (fresh['monthly'] as num?)?.toInt() ?? 0,
      newSubsYearly: (fresh['yearly'] as num?)?.toInt() ?? 0,
      newPaidTotal: (paid['total'] as num?)?.toInt() ?? 0,
      newPaidMonthly: (paid['monthly'] as num?)?.toInt() ?? 0,
      newPaidYearly: (paid['yearly'] as num?)?.toInt() ?? 0,
      revenueEstimatedTtc:
          (revenue['estimated_ttc'] as num?)?.toDouble() ?? 0,
      currency: (revenue['currency'] as String?) ?? 'EUR',
      dauToday: (usage['dau_today'] as num?)?.toInt() ?? 0,
      mau30d: (usage['mau_30d'] as num?)?.toInt() ?? 0,
      sessions30d: (usage['sessions_30d'] as num?)?.toInt() ?? 0,
      activeUsers30d: (usage['active_users_30d'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Point du graphique « Revenus mensuels » (barres par plan + cumul).
class MonthlyRevenuePoint {
  final String month; // 'YYYY-MM'
  final double monthlyRevenue; // barre « mensuel »
  final double yearlyRevenue; // barre « annuel »
  final double cumulative; // ligne cumul

  const MonthlyRevenuePoint({
    required this.month,
    required this.monthlyRevenue,
    required this.yearlyRevenue,
    required this.cumulative,
  });

  double get total => monthlyRevenue + yearlyRevenue;
}

// ─────────────────────────────────────────────────────────────────────────────
// Calculs fiscaux / frais Play (§70.3 / §70.6)
// ─────────────────────────────────────────────────────────────────────────────

/// HT à partir d'un montant TTC. Franchise en base → HT = TTC (pas de TVA
/// collectée, 1re année FR) ; sinon HT = TTC / (1 + taux/100).
double htFromTtc(double ttc, double vatRatePct, {bool franchiseBase = false}) {
  if (franchiseBase) return ttc;
  return ttc / (1 + vatRatePct / 100);
}

/// Montant après déduction des frais Play Store (ex. 15 % → × 0,85).
double netAfterPlayFee(double amount, double playFeePct) {
  return amount * (1 - playFeePct / 100);
}

/// Arrondi monétaire à 2 décimales (évite les 4,9899999… flottants).
double round2(double v) => (v * 100).roundToDouble() / 100;

/// Taux de conversion (abonnés actifs / comptes totaux), en [0, 1].
/// 0 si aucun compte (division par zéro évitée).
double purchaseRate(int activeSubscribers, int totalAccounts) {
  if (totalAccounts <= 0) return 0;
  return activeSubscribers / totalAccounts;
}

// ─────────────────────────────────────────────────────────────────────────────
// Ventilation des frais au MOIS DE PAIEMENT (§70.6 — fidélité trésorerie)
// ─────────────────────────────────────────────────────────────────────────────

/// Compare (year, month) à une date : -1 si le mois est AVANT la date,
/// 0 si même mois, +1 si après (jour du mois ignoré volontairement).
int _compareMonth(int year, int month, DateTime date) {
  if (year != date.year) return year < date.year ? -1 : 1;
  if (month != date.month) return month < date.month ? -1 : 1;
  return 0;
}

/// Un frais [e] est-il payé pendant le mois (year, month) ?
///
/// - inactif → jamais ;
/// - `once` → uniquement le mois de `startedOn` ;
/// - `monthly` → chaque mois de `startedOn` à `endedOn` (inclus, sans fin si
///   null) ;
/// - `yearly` → chaque année au mois de `startedOn.month`, de `startedOn` à
///   `endedOn` (inclus, sans fin si null).
bool expenseAppliesToMonth(ExpenseEntry e, int year, int month) {
  if (!e.active) return false;
  final afterStart = _compareMonth(year, month, e.startedOn) >= 0;
  final beforeEnd = e.endedOn == null || _compareMonth(year, month, e.endedOn!) <= 0;
  switch (e.recurrence) {
    case 'once':
      return _compareMonth(year, month, e.startedOn) == 0;
    case 'monthly':
      return afterStart && beforeEnd;
    case 'yearly':
      return month == e.startedOn.month && afterStart && beforeEnd;
    default:
      return false; // récurrence inconnue : jamais ventilée (fail-closed)
  }
}

/// Frais actifs payés pendant le mois (year, month), dans l'ordre d'entrée.
List<ExpenseEntry> expensesForMonth(
  List<ExpenseEntry> expenses,
  int year,
  int month,
) =>
    expenses.where((e) => expenseAppliesToMonth(e, year, month)).toList();

/// Total des frais par devise pour un mois donné (ex. {'USD': 45.0}).
/// Pas de conversion FX : les devises restent séparées (fidélité
/// trésorerie — l'export affiche le solde net PAR DEVISE).
Map<String, double> expenseTotalsByCurrency(
  List<ExpenseEntry> expenses,
  int year,
  int month,
) {
  final totals = <String, double>{};
  for (final e in expensesForMonth(expenses, year, month)) {
    totals[e.currency] = round2((totals[e.currency] ?? 0) + e.amount);
  }
  return totals;
}

// ─────────────────────────────────────────────────────────────────────────────
// Séries → revenus mensuels (graphiques + exports)
// ─────────────────────────────────────────────────────────────────────────────

/// Convertit des buckets `analytics/series` (granularity 'month') en points
/// de revenus estimés : revenu du mois = achats réels × prix catalogue,
/// cumul = somme depuis le début de la série. Entrée triée par `key` ;
/// le cumul est calculé dans l'ordre fourni.
List<MonthlyRevenuePoint> monthlyRevenues({
  required List<SeriesBucket> buckets,
  required double monthlyPrice,
  required double yearlyPrice,
}) {
  final points = <MonthlyRevenuePoint>[];
  var cumulative = 0.0;
  for (final b in buckets) {
    final m = round2(b.monthlyPaid * monthlyPrice);
    final y = round2(b.yearlyPaid * yearlyPrice);
    cumulative = round2(cumulative + m + y);
    points.add(MonthlyRevenuePoint(
      month: b.key,
      monthlyRevenue: m,
      yearlyRevenue: y,
      cumulative: cumulative,
    ));
  }
  return points;
}

/// Prix d'un plan dans la liste de config (0 si absent/inactif).
double priceForPlan(List<PricingConfig> pricing, String plan) {
  for (final p in pricing) {
    if (p.plan == plan && p.active) return p.priceTtc;
  }
  return 0;
}

/// Frais Play du plan (15 % par défaut si absent).
double playFeeForPlan(List<PricingConfig> pricing, String plan) {
  for (final p in pricing) {
    if (p.plan == plan && p.active) return p.playFeePct;
  }
  return 15;
}

/// Formate un montant pour l'UI (ex. « 4,99 € » / « 25 $»).
/// Devise inconnue → suffixe brut (« 12,00 CHF »).
String formatMoney(double amount, String currency) {
  final s = round2(amount).toStringAsFixed(2).replaceAll('.', ',');
  return switch (currency) {
    'EUR' => '$s €',
    'USD' => '$s \$',
    _ => '$s $currency',
  };
}

/// Formate une clé mois 'YYYY-MM' en libellé court FR (« sept. 2026 »).
String formatMonthKey(String key) {
  const months = [
    'janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin',
    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.',
  ];
  final parts = key.split('-');
  if (parts.length < 2) return key;
  final m = int.tryParse(parts[1]);
  if (m == null || m < 1 || m > 12) return key;
  return '${months[m - 1]} ${parts[0]}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Chantier F2 — événements d'usage (EF v77, migration 0067)
// ─────────────────────────────────────────────────────────────────────────────

/// Un jour d'activité (route EF `analytics/activity`).
class ActivityDay {
  final String day; // 'YYYY-MM-DD' (jour calendaire UTC côté serveur)
  final int dau; // utilisateurs distincts du jour
  final int sessions; // events session_start
  final int contentViews; // events content_viewed
  final int gameViews; // events game_viewed

  const ActivityDay({
    required this.day,
    this.dau = 0,
    this.sessions = 0,
    this.contentViews = 0,
    this.gameViews = 0,
  });

  factory ActivityDay.fromJson(Map<String, dynamic> json) => ActivityDay(
        day: (json['day'] as String?) ?? '',
        dau: (json['dau'] as num?)?.toInt() ?? 0,
        sessions: (json['sessions'] as num?)?.toInt() ?? 0,
        contentViews: (json['content_views'] as num?)?.toInt() ?? 0,
        gameViews: (json['game_views'] as num?)?.toInt() ?? 0,
      );
}

/// Une cohorte hebdomadaire d'inscription (route EF `analytics/retention`).
///
/// [d1]/[d7]/[d30] = nombre d'inscrits de la semaine ayant AU MOINS un event
/// au jour calendaire inscription + N. Les pourcentages sont des getters
/// calculés depuis les compteurs (source de vérité unique côté client — la
/// formule est testée, cf. analytics_calc_test.dart).
class RetentionCohort {
  final DateTime cohortStart; // lundi de la semaine ISO d'inscription
  final int size; // inscrits de la semaine
  final int d1;
  final int d7;
  final int d30;

  const RetentionCohort({
    required this.cohortStart,
    required this.size,
    this.d1 = 0,
    this.d7 = 0,
    this.d30 = 0,
  });

  double get d1Pct => retentionPct(d1, size);
  double get d7Pct => retentionPct(d7, size);
  double get d30Pct => retentionPct(d30, size);

  factory RetentionCohort.fromJson(Map<String, dynamic> json) =>
      RetentionCohort(
        cohortStart:
            DateTime.tryParse((json['cohort_start'] as String?) ?? '') ??
                DateTime(1970),
        size: (json['size'] as num?)?.toInt() ?? 0,
        d1: (json['d1'] as num?)?.toInt() ?? 0,
        d7: (json['d7'] as num?)?.toInt() ?? 0,
        d30: (json['d30'] as num?)?.toInt() ?? 0,
      );
}

/// Pourcentage de retournés (arrondi à 0,1 pt). 0 si cohorte vide.
double retentionPct(int retained, int size) {
  if (size <= 0) return 0;
  return (retained / size * 1000).round() / 10;
}

/// Utilisations moyennes par utilisateur actif et par jour, sur 30 jours
/// glissants (sessions ÷ utilisateurs actifs ÷ 30). 0 si aucun actif.
double avgSessionsPerUserPerDay(int sessions30d, int activeUsers30d) {
  if (activeUsers30d <= 0) return 0;
  return sessions30d / activeUsers30d / 30;
}

/// Niveau qualitatif d'un taux de rétention (repères produit, §78 :
/// lignes de référence 40 % / 20 % / 10 % du graphique de rétention).
enum RetentionBand { excellent, good, watch, low }

/// Classe un pourcentage de rétention : excellent ≥ 40 %, bon ≥ 20 %,
/// à surveiller ≥ 10 %, faible sinon.
RetentionBand retentionBand(double pct) {
  if (pct >= 40) return RetentionBand.excellent;
  if (pct >= 20) return RetentionBand.good;
  if (pct >= 10) return RetentionBand.watch;
  return RetentionBand.low;
}

/// Vrai si TOUS les inscrits de la cohorte ont eu le temps d'atteindre
/// J+[offsetDays] ET que ce jour est entièrement écoulé : la semaine court
/// jusqu'à cohortStart + 6 jours, le dernier inscrit atteint J+N à
/// cohortStart + 6 + N, et le taux n'est complet qu'à partir du lendemain.
/// En deçà, le taux affiché serait sous-estimé (une partie de la cohorte
/// n'a pas encore eu sa chance) → l'UI affiche « — ».
bool isCohortMeasurable(DateTime cohortStart, int offsetDays, DateTime today) {
  final deadline = DateTime(
    cohortStart.year,
    cohortStart.month,
    cohortStart.day + 6 + offsetDays,
  );
  final t = DateTime(today.year, today.month, today.day);
  return t.isAfter(deadline);
}

/// Libellé court d'une cohorte (« 14 sept. » = lundi de la semaine).
String formatCohortWeek(DateTime cohortStart) {
  const months = [
    'janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin',
    'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.',
  ];
  return '${cohortStart.day} ${months[cohortStart.month - 1]}';
}

/// Libellé d'axe jour « JJ/MM » depuis une clé 'YYYY-MM-DD'.
String formatDayLabel(String day) {
  final parts = day.split('-');
  if (parts.length != 3) return day;
  return '${parts[2]}/${parts[1]}';
}
