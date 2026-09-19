// Tests purs (VM) du chantier F1 — règles de calcul du menu « Analytics » :
// ventilation des frais au mois de paiement (§70.6) et calculs HT/TTC +
// frais Play Store (§70.3). Aucune dépendance Flutter ni dart:html.

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/analytics_calc.dart';
import 'package:mgt_admin/domain/analytics_export.dart';

void main() {
  group('HT/TTC (§70.6)', () {
    test('franchise en base → HT = TTC', () {
      expect(htFromTtc(120, 20, franchiseBase: true), 120);
      expect(htFromTtc(4.99, 20, franchiseBase: true), 4.99);
    });

    test('TVA 20 % → HT = TTC / 1,20', () {
      expect(htFromTtc(120, 20), closeTo(100, 1e-9));
      expect(htFromTtc(4.99, 20), closeTo(4.158333, 1e-4));
    });

    test('TVA 7 % (Thaïlande) → HT = TTC / 1,07', () {
      expect(htFromTtc(107, 7), closeTo(100, 1e-9));
    });

    test('TVA 0 % (Hong Kong) → HT = TTC', () {
      expect(htFromTtc(39.99, 0), 39.99);
    });
  });

  group('Frais Play Store (§70.3)', () {
    test('15 % → × 0,85', () {
      expect(netAfterPlayFee(100, 15), closeTo(85, 1e-9));
    });

    test('30 % → × 0,70', () {
      expect(netAfterPlayFee(100, 30), closeTo(70, 1e-9));
    });

    test('ordre documenté : frais Play déduits du TTC AVANT le HT', () {
      // 4,99 € TTC, frais 15 % → net Play 4,2415 €, puis TVA 20 % → HT.
      final net = netAfterPlayFee(4.99, 15);
      expect(net, closeTo(4.2415, 1e-9));
      expect(htFromTtc(net, 20), closeTo(3.53458, 1e-4));
    });
  });

  group('purchaseRate', () {
    test('division par zéro évitée', () {
      expect(purchaseRate(0, 0), 0);
      expect(purchaseRate(5, 0), 0);
    });

    test('actifs / comptes', () {
      expect(purchaseRate(10, 20), 0.5);
      expect(purchaseRate(10, 18), closeTo(0.5555, 1e-3));
    });
  });

  group('Ventilation des frais au mois de paiement (§70.6)', () {
    ExpenseEntry expense({
      String label = 'Test',
      String recurrence = 'monthly',
      DateTime? startedOn,
      DateTime? endedOn,
      bool active = true,
    }) =>
        ExpenseEntry(
          label: label,
          amount: 25,
          recurrence: recurrence,
          startedOn: startedOn ?? DateTime(2026, 7, 1),
          endedOn: endedOn,
          active: active,
        );

    test('once : uniquement le mois de début', () {
      final e = expense(recurrence: 'once');
      expect(expenseAppliesToMonth(e, 2026, 7), isTrue);
      expect(expenseAppliesToMonth(e, 2026, 8), isFalse);
      expect(expenseAppliesToMonth(e, 2027, 7), isFalse);
    });

    test('monthly : chaque mois entre début et fin (bornes incluses)', () {
      final e = expense(endedOn: DateTime(2026, 9, 15));
      expect(expenseAppliesToMonth(e, 2026, 6), isFalse); // avant début
      expect(expenseAppliesToMonth(e, 2026, 7), isTrue); // mois de début
      expect(expenseAppliesToMonth(e, 2026, 8), isTrue);
      expect(expenseAppliesToMonth(e, 2026, 9), isTrue); // mois de fin inclus
      expect(expenseAppliesToMonth(e, 2026, 10), isFalse); // après fin
    });

    test('monthly sans fin : tous les mois suivants', () {
      final e = expense();
      expect(expenseAppliesToMonth(e, 2026, 7), isTrue);
      expect(expenseAppliesToMonth(e, 2030, 1), isTrue);
      expect(expenseAppliesToMonth(e, 2026, 6), isFalse);
    });

    test('yearly : chaque année au mois de la 1re souscription', () {
      final e = expense(recurrence: 'yearly'); // début 07/2026
      expect(expenseAppliesToMonth(e, 2026, 7), isTrue);
      expect(expenseAppliesToMonth(e, 2027, 7), isTrue); // reconduction
      expect(expenseAppliesToMonth(e, 2027, 8), isFalse); // autre mois
      expect(expenseAppliesToMonth(e, 2025, 7), isFalse); // avant début
    });

    test('yearly avec fin : respecte ended_on', () {
      final e = expense(
        recurrence: 'yearly',
        endedOn: DateTime(2028, 3, 1), // fin mars 2028 → juillet 2028 exclu
      );
      expect(expenseAppliesToMonth(e, 2027, 7), isTrue);
      expect(expenseAppliesToMonth(e, 2028, 7), isFalse);
    });

    test('inactif : jamais ventilé', () {
      final e = expense(active: false);
      expect(expenseAppliesToMonth(e, 2026, 7), isFalse);
    });

    test('récurrence inconnue : fail-closed (jamais ventilée)', () {
      final e = ExpenseEntry(
        label: 'X',
        amount: 10,
        recurrence: 'weekly', // hors contrat DB
        startedOn: DateTime(2026, 7, 1),
      );
      expect(expenseAppliesToMonth(e, 2026, 7), isFalse);
    });

    test('expensesForMonth : filtre une liste mixte', () {
      final list = [
        expense(label: 'A'), // monthly 07/2026 → OK
        ExpenseEntry(
          label: 'B',
          amount: 25,
          recurrence: 'once',
          startedOn: DateTime(2026, 7, 1),
        ),
        ExpenseEntry(
          label: 'C',
          amount: 12,
          recurrence: 'yearly',
          startedOn: DateTime(2026, 9, 1),
        ),
      ];
      final sept = expensesForMonth(list, 2026, 9);
      expect(sept.map((e) => e.label), ['A', 'C']); // B (once 07) exclu
      final aout = expensesForMonth(list, 2026, 8);
      expect(aout.map((e) => e.label), ['A']);
    });
  });

  group('Totaux par devise (pas de conversion FX)', () {
    test('regroupe et arrondit par devise', () {
      final list = [
        ExpenseEntry(
          label: 'Supabase',
          amount: 25,
          recurrence: 'monthly',
          startedOn: DateTime(2026, 7, 1),
        ),
        ExpenseEntry(
          label: 'Kimi',
          amount: 8,
          recurrence: 'monthly',
          startedOn: DateTime(2026, 9, 1),
        ),
        ExpenseEntry(
          label: 'Domaine',
          amount: 12,
          currency: 'EUR',
          recurrence: 'monthly',
          startedOn: DateTime(2026, 9, 1),
        ),
      ];
      expect(expenseTotalsByCurrency(list, 2026, 8), {'USD': 25.0});
      expect(expenseTotalsByCurrency(list, 2026, 9), {
        'USD': 33.0,
        'EUR': 12.0,
      });
    });
  });

  group('Revenus mensuels (séries → graphique/export)', () {
    test('revenu = achats réels × prix catalogue, cumul ordonné', () {
      final buckets = [
        const SeriesBucket(key: '2026-07', monthlyPaid: 2, yearlyPaid: 1),
        const SeriesBucket(key: '2026-08'),
        const SeriesBucket(key: '2026-09', monthlyPaid: 1),
      ];
      final points = monthlyRevenues(
        buckets: buckets,
        monthlyPrice: 4.99,
        yearlyPrice: 39.99,
      );
      expect(points, hasLength(3));
      expect(points[0].monthlyRevenue, closeTo(9.98, 1e-9));
      expect(points[0].yearlyRevenue, closeTo(39.99, 1e-9));
      expect(points[0].cumulative, closeTo(49.97, 1e-9));
      expect(points[1].total, 0);
      expect(points[1].cumulative, closeTo(49.97, 1e-9)); // cumul stable
      expect(points[2].cumulative, closeTo(54.96, 1e-9));
    });

    test('les abonnements offerts ne comptent pas (monthly ≠ monthlyPaid)',
        () {
      // 5 souscriptions mensuelles dont 2 réelles → revenu sur 2 seulement.
      const b = SeriesBucket(key: '2026-09', monthly: 5, monthlyPaid: 2);
      final points = monthlyRevenues(
        buckets: [b],
        monthlyPrice: 4.99,
        yearlyPrice: 39.99,
      );
      expect(points[0].monthlyRevenue, closeTo(9.98, 1e-9));
    });
  });

  group('Config prix', () {
    const pricing = [
      PricingConfig(plan: 'monthly', priceTtc: 4.99),
      PricingConfig(plan: 'yearly', priceTtc: 39.99, playFeePct: 30),
      PricingConfig(plan: 'monthly', priceTtc: 99, active: false),
    ];

    test('priceForPlan : prix actif, 0 si inactif/absent', () {
      // La 1re ligne monthly active gagne ; la ligne inactive est ignorée.
      expect(priceForPlan(pricing, 'monthly'), 4.99);
      expect(priceForPlan(pricing, 'yearly'), 39.99);
      expect(priceForPlan(const [], 'monthly'), 0);
    });

    test('playFeeForPlan : taux du plan, 15 % par défaut', () {
      expect(playFeeForPlan(pricing, 'yearly'), 30);
      expect(playFeeForPlan(const [], 'monthly'), 15);
    });
  });

  group('Parsing JSON (réponses EF v76)', () {
    test('AnalyticsOverview.fromJson : sous-objets + défauts', () {
      final o = AnalyticsOverview.fromJson({
        'accounts_total': 18,
        'accounts_new': 3,
        'subscribers_active': {'total': 10, 'monthly': 8, 'yearly': 2},
        'subscribers_by_source': {'admin': 9, 'reward': 1},
        'new_subscriptions': {
          'total': 2,
          'monthly': 1,
          'yearly': 1,
          'paid': {'total': 0, 'monthly': 0, 'yearly': 0},
        },
        'revenue': {'estimated_ttc': 0.0, 'currency': 'EUR'},
      });
      expect(o.accountsTotal, 18);
      expect(o.subsActiveMonthly, 8);
      expect(o.subsBySource['admin'], 9);
      expect(o.newPaidTotal, 0);
      expect(o.revenueEstimatedTtc, 0);
    });

    test('AnalyticsOverview.fromJson : objet vide → zéros', () {
      final o = AnalyticsOverview.fromJson(const {});
      expect(o.accountsTotal, 0);
      expect(o.subsBySource, isEmpty);
      expect(o.currency, 'EUR');
    });

    test('SeriesBucket.fromJson', () {
      final b = SeriesBucket.fromJson({
        'key': '2026-09',
        'monthly': 3,
        'yearly': 1,
        'monthly_paid': 2,
        'yearly_paid': 0,
      });
      expect(b.key, '2026-09');
      expect(b.total, 4);
      expect(b.totalPaid, 2);
    });

    test('ExpenseEntry.fromJson : dates et ended_on nullable', () {
      final e = ExpenseEntry.fromJson({
        'id': 1,
        'label': 'Supabase Pro',
        'category': 'infra',
        'amount': 25,
        'currency': 'USD',
        'recurrence': 'monthly',
        'started_on': '2026-07-01',
        'ended_on': null,
        'active': true,
        'notes': null,
      });
      expect(e.id, 1);
      expect(e.startedOn, DateTime(2026, 7, 1));
      expect(e.endedOn, isNull);
      final e2 = ExpenseEntry.fromJson({
        'label': 'X',
        'amount': 1,
        'recurrence': 'once',
        'started_on': '2026-07-01',
        'ended_on': '2026-12-31',
      });
      expect(e2.endedOn, DateTime(2026, 12, 31));
    });
  });

  group('Formatage', () {
    test('formatMoney', () {
      expect(formatMoney(4.99, 'EUR'), '4,99 €');
      expect(formatMoney(25, 'USD'), '25,00 \$');
      expect(formatMoney(12, 'CHF'), '12,00 CHF');
    });

    test('formatMonthKey', () {
      expect(formatMonthKey('2026-09'), 'sept. 2026');
      expect(formatMonthKey('2026-01'), 'janv. 2026');
      expect(formatMonthKey('invalide'), 'invalide');
    });
  });

  group('Exports Excel (§70.6)', () {
    // DateTime n'est pas const-constructible → contexte en final.
    final ctx = ExportContext(
      pricing: const [
        PricingConfig(plan: 'monthly', priceTtc: 4.99),
        PricingConfig(plan: 'yearly', priceTtc: 39.99),
      ],
      tax: const TaxConfig(
        jurisdiction: 'france',
        label: 'France',
        vatRate: 20,
        franchiseBase: true,
      ),
      expenses: [
        ExpenseEntry(
          label: 'Supabase Pro',
          category: 'infra',
          amount: 25,
          recurrence: 'monthly',
          startedOn: DateTime(2026, 7, 1),
        ),
        ExpenseEntry(
          label: 'Play Console',
          category: 'store',
          amount: 25,
          recurrence: 'once',
          startedOn: DateTime(2026, 7, 1),
        ),
      ],
    );

    test('export mensuel : fichier xlsx non vide', () {
      final bytes = buildMonthlyExcel(
        year: 2026,
        month: 9,
        bucket: const SeriesBucket(key: '2026-09', monthlyPaid: 1),
        ctx: ctx,
      );
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(1000)); // zip xlsx réel
    });

    test('export annuel : 12 mois + synthèse, fichier non vide', () {
      final bytes = buildYearlyExcel(
        year: 2026,
        buckets: const [
          SeriesBucket(key: '2026-09', monthlyPaid: 2, yearlyPaid: 1),
        ],
        ctx: ctx,
      );
      expect(bytes, isNotNull);
      expect(bytes!.length, greaterThan(5000));
    });

    test('buildMonthAccount : ventilation + prix avec options', () {
      final acc = buildMonthAccount(
        year: 2026,
        month: 7,
        bucket: const SeriesBucket(key: '2026-07', monthlyPaid: 2),
        ctx: ctx,
      );
      // franchise_base → HT = TTC ; 2 × 4,99.
      expect(acc.monthlyRevenue, closeTo(9.98, 1e-9));
      // monthly Supabase + once Play Console → 50 USD en juillet.
      expect(acc.expenseTotals, {'USD': 50.0});
      // En août : seul le monthly reste.
      final accAug = buildMonthAccount(
        year: 2026,
        month: 8,
        bucket: const SeriesBucket(key: '2026-08'),
        ctx: ctx,
      );
      expect(accAug.expenseTotals, {'USD': 25.0});
    });

    test('exportPrice : frais Play déduits puis HT', () {
      const ctxFee = ExportContext(
        pricing: [PricingConfig(plan: 'monthly', priceTtc: 4.99)],
        tax: TaxConfig(
          jurisdiction: 'france',
          label: 'France',
          vatRate: 20,
        ),
        expenses: [],
        showHt: true,
        deductPlayFee: true,
      );
      // 4,99 × 0,85 = 4,2415 → HT / 1,20 = 3,53458 → arrondi 3,53.
      expect(exportPrice(ctxFee, 'monthly'), 3.53);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // Chantier F2 — événements d'usage + rétention (EF v77, migration 0067)
  // ─────────────────────────────────────────────────────────────────────────

  group('retentionPct (F2)', () {
    test('division par zéro évitée (cohorte vide)', () {
      expect(retentionPct(0, 0), 0);
      expect(retentionPct(5, 0), 0);
    });

    test('arrondi à 0,1 point', () {
      expect(retentionPct(1, 3), 33.3);
      expect(retentionPct(2, 3), 66.7);
      expect(retentionPct(10, 10), 100.0);
      expect(retentionPct(0, 42), 0);
    });
  });

  group('retentionBand (repères 40/20/10 %, §78)', () {
    test('bornes exactes', () {
      expect(retentionBand(40), RetentionBand.excellent);
      expect(retentionBand(41.2), RetentionBand.excellent);
      expect(retentionBand(39.9), RetentionBand.good);
      expect(retentionBand(20), RetentionBand.good);
      expect(retentionBand(19.9), RetentionBand.watch);
      expect(retentionBand(10), RetentionBand.watch);
      expect(retentionBand(9.9), RetentionBand.low);
      expect(retentionBand(0), RetentionBand.low);
    });
  });

  group('avgSessionsPerUserPerDay (F2)', () {
    test('aucun utilisateur actif → 0 (division par zéro évitée)', () {
      expect(avgSessionsPerUserPerDay(0, 0), 0);
      expect(avgSessionsPerUserPerDay(120, 0), 0);
    });

    test('sessions ÷ actifs ÷ 30 jours', () {
      // 900 sessions / 10 actifs / 30 j = 3 utilisations/utilisateur/jour.
      expect(avgSessionsPerUserPerDay(900, 10), closeTo(3.0, 1e-9));
      expect(avgSessionsPerUserPerDay(30, 30), closeTo(1 / 30, 1e-9));
    });
  });

  group('isCohortMeasurable (fenêtre écoulée pour TOUTE la cohorte)', () {
    // Cohorte du lundi 07/09/2026 → dernier inscrit possible : dimanche 13/09.
    final cohortStart = DateTime(2026, 9, 7); // un lundi

    test('D1 mesurable dès le 15/09 (13/09 + 1 jour, écoulé)', () {
      expect(isCohortMeasurable(cohortStart, 1, DateTime(2026, 9, 14)), isFalse);
      expect(isCohortMeasurable(cohortStart, 1, DateTime(2026, 9, 15)), isTrue);
    });

    test('D7 mesurable dès le 21/09, D30 dès le 14/10', () {
      expect(isCohortMeasurable(cohortStart, 7, DateTime(2026, 9, 20)), isFalse);
      expect(isCohortMeasurable(cohortStart, 7, DateTime(2026, 9, 21)), isTrue);
      expect(
        isCohortMeasurable(cohortStart, 30, DateTime(2026, 10, 13)),
        isFalse,
      );
      expect(
        isCohortMeasurable(cohortStart, 30, DateTime(2026, 10, 14)),
        isTrue,
      );
    });

    test('cohorte de la semaine courante : rien n\'est mesurable', () {
      expect(isCohortMeasurable(cohortStart, 1, DateTime(2026, 9, 8)), isFalse);
      expect(isCohortMeasurable(cohortStart, 7, DateTime(2026, 9, 12)), isFalse);
    });
  });

  group('Modèles F2 (fromJson tolérant)', () {
    test('ActivityDay : champs complets + défauts à 0', () {
      final d = ActivityDay.fromJson(const {
        'day': '2026-09-20',
        'dau': 5,
        'sessions': 12,
        'content_views': 34,
        'game_views': 8,
      });
      expect(d.day, '2026-09-20');
      expect(d.dau, 5);
      expect(d.sessions, 12);
      expect(d.contentViews, 34);
      expect(d.gameViews, 8);
      final empty = ActivityDay.fromJson(const {});
      expect(empty.day, '');
      expect(empty.dau, 0);
    });

    test('RetentionCohort : compteurs + pourcentages dérivés', () {
      final c = RetentionCohort.fromJson(const {
        'cohort_start': '2026-09-07',
        'size': 20,
        'd1': 9,
        'd7': 5,
        'd30': 2,
      });
      expect(c.cohortStart, DateTime(2026, 9, 7));
      expect(c.size, 20);
      expect(c.d1Pct, 45.0);
      expect(c.d7Pct, 25.0);
      expect(c.d30Pct, 10.0);
    });

    test('AnalyticsOverview : bloc usage (défaut 0 si absent)', () {
      final o = AnalyticsOverview.fromJson(const {
        'usage': {
          'dau_today': 3,
          'mau_30d': 18,
          'sessions_30d': 90,
          'active_users_30d': 15,
        },
      });
      expect(o.dauToday, 3);
      expect(o.mau30d, 18);
      expect(o.sessions30d, 90);
      expect(o.activeUsers30d, 15);
      // Sans bloc usage (EF v76 encore déployée) : pas d'erreur, 0 partout.
      final legacy = AnalyticsOverview.fromJson(const {});
      expect(legacy.dauToday, 0);
      expect(legacy.mau30d, 0);
    });
  });

  group('Libellés F2', () {
    test('formatCohortWeek : lundi de la semaine ISO', () {
      expect(formatCohortWeek(DateTime(2026, 9, 7)), '7 sept.');
      expect(formatCohortWeek(DateTime(2026, 1, 26)), '26 janv.');
    });

    test('formatDayLabel : JJ/MM depuis YYYY-MM-DD', () {
      expect(formatDayLabel('2026-09-20'), '20/09');
      expect(formatDayLabel('invalide'), 'invalide');
    });
  });
}
