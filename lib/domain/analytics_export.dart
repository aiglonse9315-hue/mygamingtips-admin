/// Chantier F1 — génération des exports comptables `.xlsx` (menu Analytics,
/// décision §70.6 : export mensuel + annuel, frais au MOIS DE PAIEMENT).
///
/// Pur Dart (package `excel`, aucune dépendance Flutter ni dart:html) :
/// testable en VM ; le téléchargement Blob est fait par l'écran.
///
/// Contenu d'un onglet mensuel :
///   - en-tête (juridiction fiscale, HT/TTC appliqué, frais Play déduits
///     ou non) ;
///   - revenus estimés du mois, détail par plan (achats RÉELS × prix
///     catalogue — les abonnements offerts source admin/reward sont exclus) ;
///   - frais de société ventilés au mois de paiement (monthly = chaque mois
///     entre started_on/ended_on ; yearly = mois de started_on.month ;
///     once = mois de started_on) ;
///   - solde net PAR DEVISE (aucune conversion FX — fidélité trésorerie) ;
///   - mention « document interne d'aide à la déclaration ».
/// L'export annuel = 12 onglets mensuels + onglet « Synthèse » (totaux par
/// mois + année, par catégorie de frais).
library;

import 'package:excel/excel.dart';

import 'analytics_calc.dart';

/// Contexte d'export : configuration au moment de la génération.
class ExportContext {
  /// Prix catalogue actifs (devise unique en pratique — EUR).
  final List<PricingConfig> pricing;

  /// Juridiction fiscale SÉLECTIONNÉE (projection perso, §70.6).
  final TaxConfig tax;

  /// Frais de société (tous — la ventilation filtre par mois).
  final List<ExpenseEntry> expenses;

  /// true → montants HT (sinon TTC).
  final bool showHt;

  /// true → frais Play Store déduits des revenus (option, défaut off).
  final bool deductPlayFee;

  const ExportContext({
    required this.pricing,
    required this.tax,
    required this.expenses,
    this.showHt = false,
    this.deductPlayFee = false,
  });
}

/// Détail chiffré d'un mois (une ligne de bucket `analytics/series` month).
class MonthAccount {
  final String monthKey; // 'YYYY-MM'
  final int paidMonthly;
  final int paidYearly;
  final double monthlyRevenue; // après options HT / frais Play
  final double yearlyRevenue;
  final List<ExpenseEntry> expenses; // ventilés au mois
  final Map<String, double> expenseTotals; // par devise

  const MonthAccount({
    required this.monthKey,
    required this.paidMonthly,
    required this.paidYearly,
    required this.monthlyRevenue,
    required this.yearlyRevenue,
    required this.expenses,
    required this.expenseTotals,
  });

  double get totalRevenue => round2(monthlyRevenue + yearlyRevenue);
}

/// Prix d'un plan après les options d'export (frais Play puis HT —
/// ordre documenté dans analytics_calc.dart).
double exportPrice(ExportContext ctx, String plan) {
  var price = priceForPlan(ctx.pricing, plan);
  if (ctx.deductPlayFee) {
    price = netAfterPlayFee(price, playFeeForPlan(ctx.pricing, plan));
  }
  if (ctx.showHt) {
    price = htFromTtc(price, ctx.tax.vatRate,
        franchiseBase: ctx.tax.franchiseBase);
  }
  return round2(price);
}

/// Calcule le détail d'un mois à partir de son bucket de série.
MonthAccount buildMonthAccount({
  required int year,
  required int month,
  required SeriesBucket bucket,
  required ExportContext ctx,
}) {
  final monthlyPrice = exportPrice(ctx, 'monthly');
  final yearlyPrice = exportPrice(ctx, 'yearly');
  final expenses = expensesForMonth(ctx.expenses, year, month);
  return MonthAccount(
    monthKey: bucket.key.isNotEmpty
        ? bucket.key
        : '$year-${month.toString().padLeft(2, '0')}',
    paidMonthly: bucket.monthlyPaid,
    paidYearly: bucket.yearlyPaid,
    monthlyRevenue: round2(bucket.monthlyPaid * monthlyPrice),
    yearlyRevenue: round2(bucket.yearlyPaid * yearlyPrice),
    expenses: expenses,
    expenseTotals: expenseTotalsByCurrency(ctx.expenses, year, month),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Écriture xlsx
// ─────────────────────────────────────────────────────────────────────────────

final CellStyle _titleStyle = CellStyle(bold: true, fontSize: 14);
final CellStyle _headStyle = CellStyle(bold: true);

void _title(Sheet sheet, String text) {
  sheet.appendRow([TextCellValue(text)]);
  final cell = sheet.cell(
    CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: sheet.maxRows - 1),
  );
  cell.cellStyle = _titleStyle;
}

void _headerRow(Sheet sheet, List<String> labels) {
  sheet.appendRow(labels.map(TextCellValue.new).toList());
  for (var c = 0; c < labels.length; c++) {
    sheet
        .cell(CellIndex.indexByColumnRow(
            columnIndex: c, rowIndex: sheet.maxRows - 1))
        .cellStyle = _headStyle;
  }
}

/// Ligne vide d'espacement (une cellule texte vide force l'avancée de
/// maxRows — appendRow([]) est un no-op dans excel 4.x).
void _blank(Sheet sheet) => sheet.appendRow([TextCellValue('')]);

String _moneyLine(double v) => v.toStringAsFixed(2);

/// Écrit l'en-tête commun (juridiction, HT/TTC, frais Play, note légale).
void _writeCommonHeader(Sheet sheet, ExportContext ctx, String scope) {
  _title(sheet, 'MyGamingTips — $scope');
  sheet.appendRow([
    TextCellValue('Document interne d\'aide à la déclaration — revenus '
        'ESTIMÉS catalogue (prix × achats réels), abonnements offerts exclus.'),
  ]);
  sheet.appendRow([
    TextCellValue('Juridiction (projection fiscale perso)'),
    TextCellValue(
      '${ctx.tax.label} — TVA ${ctx.tax.vatRate.toStringAsFixed(1)} %'
      '${ctx.tax.franchiseBase ? ' — franchise en base (HT = TTC)' : ''}',
    ),
  ]);
  sheet.appendRow([
    TextCellValue('Montants'),
    TextCellValue(ctx.showHt ? 'HT' : 'TTC'),
  ]);
  sheet.appendRow([
    TextCellValue('Frais Play Store déduits'),
    TextCellValue(ctx.deductPlayFee ? 'oui' : 'non'),
  ]);
  _blank(sheet);
}

/// Écrit la section « Revenus estimés » d'un mois. Retourne le total.
double _writeRevenueSection(Sheet sheet, MonthAccount acc, ExportContext ctx) {
  final currency =
      ctx.pricing.isNotEmpty ? ctx.pricing.first.currency : 'EUR';
  final monthlyPrice = exportPrice(ctx, 'monthly');
  final yearlyPrice = exportPrice(ctx, 'yearly');
  _title(sheet, 'REVENUS ESTIMÉS (${ctx.showHt ? 'HT' : 'TTC'}, $currency)');
  _headerRow(sheet, ['Plan', 'Achats réels', 'Prix unit.', 'Total', 'Devise']);
  sheet.appendRow([
    TextCellValue('Mensuel'),
    IntCellValue(acc.paidMonthly),
    DoubleCellValue(monthlyPrice),
    DoubleCellValue(acc.monthlyRevenue),
    TextCellValue(currency),
  ]);
  sheet.appendRow([
    TextCellValue('Annuel'),
    IntCellValue(acc.paidYearly),
    DoubleCellValue(yearlyPrice),
    DoubleCellValue(acc.yearlyRevenue),
    TextCellValue(currency),
  ]);
  sheet.appendRow([
    TextCellValue('TOTAL'),
    IntCellValue(acc.paidMonthly + acc.paidYearly),
    TextCellValue(''),
    DoubleCellValue(acc.totalRevenue),
    TextCellValue(currency),
  ]);
  _blank(sheet);
  return acc.totalRevenue;
}

/// Écrit la section « Frais de société » d'un mois (détail + totaux par
/// devise).
void _writeExpenseSection(Sheet sheet, MonthAccount acc) {
  _title(sheet, 'FRAIS DE SOCIÉTÉ (mois de paiement)');
  if (acc.expenses.isEmpty) {
    sheet.appendRow([TextCellValue('Aucun frais ce mois.')]);
  } else {
    _headerRow(
        sheet, ['Libellé', 'Catégorie', 'Récurrence', 'Montant', 'Devise']);
    for (final e in acc.expenses) {
      sheet.appendRow([
        TextCellValue(e.label),
        TextCellValue(e.category),
        TextCellValue(e.recurrence),
        DoubleCellValue(e.amount),
        TextCellValue(e.currency),
      ]);
    }
    acc.expenseTotals.forEach((currency, total) {
      sheet.appendRow([
        TextCellValue('TOTAL FRAIS'),
        TextCellValue(''),
        TextCellValue(''),
        DoubleCellValue(total),
        TextCellValue(currency),
      ]);
    });
  }
  _blank(sheet);
}

/// Écrit la section « Solde net » (par devise — pas de conversion FX).
void _writeNetSection(Sheet sheet, MonthAccount acc, ExportContext ctx) {
  final currency =
      ctx.pricing.isNotEmpty ? ctx.pricing.first.currency : 'EUR';
  _title(sheet, 'SOLDE NET PAR DEVISE');
  final expensesInPriceCurrency = acc.expenseTotals[currency] ?? 0;
  sheet.appendRow([
    TextCellValue(currency),
    TextCellValue(
      'revenus ${_moneyLine(acc.totalRevenue)} − frais '
      '${_moneyLine(expensesInPriceCurrency)}',
    ),
    DoubleCellValue(round2(acc.totalRevenue - expensesInPriceCurrency)),
  ]);
  acc.expenseTotals.forEach((c, total) {
    if (c == currency) return;
    sheet.appendRow([
      TextCellValue(c),
      TextCellValue('frais ${_moneyLine(total)} (pas de revenus $c — '
          'conversion FX non gérée, convertir au taux du jour)'),
      DoubleCellValue(round2(-total)),
    ]);
  });
}

Sheet _monthSheet(Excel excel, MonthAccount acc, ExportContext ctx) {
  final sheet = excel[acc.monthKey];
  _writeCommonHeader(sheet, ctx, 'Compta ${acc.monthKey}');
  _writeRevenueSection(sheet, acc, ctx);
  _writeExpenseSection(sheet, acc);
  _writeNetSection(sheet, acc, ctx);
  return sheet;
}

/// Export mensuel : un onglet « YYYY-MM ». [bucket] = série month du mois
/// (clé 'YYYY-MM' ; bucket vide accepté → revenus 0). Retourne les bytes
/// du fichier (null si encodage impossible).
List<int>? buildMonthlyExcel({
  required int year,
  required int month,
  required SeriesBucket bucket,
  required ExportContext ctx,
}) {
  final excel = Excel.createExcel();
  excel.delete('Sheet1');
  final acc =
      buildMonthAccount(year: year, month: month, bucket: bucket, ctx: ctx);
  _monthSheet(excel, acc, ctx);
  return excel.save();
}

/// Export annuel : 12 onglets « YYYY-MM » + onglet « Synthèse ».
/// [buckets] = série month de l'année (les mois manquants = revenus 0).
List<int>? buildYearlyExcel({
  required int year,
  required List<SeriesBucket> buckets,
  required ExportContext ctx,
}) {
  final excel = Excel.createExcel();
  excel.delete('Sheet1');

  final accounts = <MonthAccount>[];
  for (var m = 1; m <= 12; m++) {
    final key = '$year-${m.toString().padLeft(2, '0')}';
    final bucket = buckets.firstWhere(
      (b) => b.key == key,
      orElse: () => SeriesBucket(key: key),
    );
    final acc =
        buildMonthAccount(year: year, month: m, bucket: bucket, ctx: ctx);
    accounts.add(acc);
    _monthSheet(excel, acc, ctx);
  }

  // ── Onglet Synthèse ──
  final currency =
      ctx.pricing.isNotEmpty ? ctx.pricing.first.currency : 'EUR';
  final summary = excel['Synthèse'];
  _writeCommonHeader(summary, ctx, 'Compta $year — Synthèse annuelle');
  _title(summary, 'TOTAUX PAR MOIS');
  _headerRow(summary, [
    'Mois',
    'Revenus ($currency)',
    'Frais ($currency)',
    'Net ($currency)',
    'Cumul net ($currency)',
  ]);
  var cumulative = 0.0;
  var yearRevenue = 0.0;
  var yearExpensesPriceCurrency = 0.0;
  final yearExpensesOther = <String, double>{};
  for (final acc in accounts) {
    final expPc = acc.expenseTotals[currency] ?? 0;
    final net = round2(acc.totalRevenue - expPc);
    cumulative = round2(cumulative + net);
    yearRevenue = round2(yearRevenue + acc.totalRevenue);
    yearExpensesPriceCurrency = round2(yearExpensesPriceCurrency + expPc);
    acc.expenseTotals.forEach((c, v) {
      if (c == currency) return;
      yearExpensesOther[c] = round2((yearExpensesOther[c] ?? 0) + v);
    });
    summary.appendRow([
      TextCellValue(acc.monthKey),
      DoubleCellValue(acc.totalRevenue),
      DoubleCellValue(expPc),
      DoubleCellValue(net),
      DoubleCellValue(cumulative),
    ]);
  }
  summary.appendRow([
    TextCellValue('TOTAL $year'),
    DoubleCellValue(yearRevenue),
    DoubleCellValue(yearExpensesPriceCurrency),
    DoubleCellValue(round2(yearRevenue - yearExpensesPriceCurrency)),
    TextCellValue(''),
  ]);
  yearExpensesOther.forEach((c, v) {
    summary.appendRow([
      TextCellValue('Frais $c (non convertis)'),
      TextCellValue(''),
      DoubleCellValue(v),
      TextCellValue(''),
      TextCellValue(''),
    ]);
  });
  _blank(summary);

  // Totaux par catégorie de frais (année entière, par devise).
  _title(summary, 'FRAIS PAR CATÉGORIE (année $year)');
  _headerRow(summary, ['Catégorie', 'Total', 'Devise']);
  final byCategory = <String, double>{};
  for (var m = 1; m <= 12; m++) {
    for (final e in expensesForMonth(ctx.expenses, year, m)) {
      final k = '${e.category}|${e.currency}';
      byCategory[k] = round2((byCategory[k] ?? 0) + e.amount);
    }
  }
  if (byCategory.isEmpty) {
    summary.appendRow([TextCellValue('Aucun frais sur l\'année.')]);
  } else {
    final keys = byCategory.keys.toList()..sort();
    for (final k in keys) {
      final parts = k.split('|');
      summary.appendRow([
        TextCellValue(parts[0]),
        DoubleCellValue(byCategory[k]!),
        TextCellValue(parts[1]),
      ]);
    }
  }

  return excel.save();
}
