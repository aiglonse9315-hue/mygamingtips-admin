// Carte « Modération automatique » du tableau de bord, partie présentation
// (P4b-3, lot L5, T9, D1, conception §6.10, §7.1) : disjoncteur ouvert →
// carte et texte ROUGES avec la date en heure locale (valeur attendue
// construite par `toLocal()` et le même format, jamais un littéral : le
// poste est en UTC+7, la CI en UTC), interrupteur allumé / éteint,
// compteurs, erreur de lecture, rappels.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/core/theme/colors.dart';
import 'package:mgt_admin/domain/models/moderation.dart';
import 'package:mgt_admin/ui/widgets/moderation/moderation_alert_view.dart';

import 'support/widget_fixtures.dart';

const String _trippedIso = '2026-09-28T03:15:00+00:00';

String _two(int v) => v.toString().padLeft(2, '0');

/// Même conversion que l'écran : heure locale, JJ/MM/AAAA HH:mm.
String _expectedDate(String iso) {
  final DateTime d = DateTime.parse(iso).toLocal();
  return '${_two(d.day)}/${_two(d.month)}/${d.year} '
      '${_two(d.hour)}:${_two(d.minute)}';
}

ModerationSettings _settings({bool enabled = true, bool breaker = false}) =>
    ModerationSettings.fromJson(<String, dynamic>{
      'auto_ban_enabled': enabled,
      'max_auto_bans_per_hour': 3,
      'max_auto_bans_per_day': 10,
      'breaker_tripped_at': breaker ? _trippedIso : null,
      'breaker_reason': breaker ? 'plafond_heure' : null,
      'auto_bans_last_hour': 3,
      'auto_bans_last_day': 7,
      'review_queue_size': 4,
    })!;

Future<void> _pump(
  WidgetTester tester, {
  ModerationSettings? settings,
  bool loading = false,
  String? error,
  VoidCallback? onRefresh,
  VoidCallback? onOpen,
}) => pumpBody(
  tester,
  ModerationAlertView(
    settings: settings,
    loading: loading,
    error: error,
    onRefresh: onRefresh ?? () {},
    onOpen: onOpen ?? () {},
  ),
);

void main() {
  testWidgets('disjoncteur ouvert : carte et texte rouges, date locale', (
    WidgetTester tester,
  ) async {
    await _pump(tester, settings: _settings(enabled: false, breaker: true));
    final Finder banner = find.byKey(const Key('moderation-alert-breaker'));
    expect(
      shownText(tester, banner),
      '⛔ Disjoncteur déclenché le ${_expectedDate(_trippedIso)} '
      '(plafond horaire atteint) : le ban automatique est coupé.',
    );
    expect(tester.widget<Text>(banner).style!.color, AppColors.categoryVideo);
    expect(
      find.byKey(const Key('moderation-alert-breaker-card')),
      findsOneWidget,
    );
    expect(find.text('éteinte'), findsOneWidget);
  });

  testWidgets('allumée : pas de bandeau, file et compteurs', (
    WidgetTester tester,
  ) async {
    await _pump(tester, settings: _settings());
    expect(find.text('Modération automatique'), findsOneWidget);
    expect(find.text('allumée'), findsOneWidget);
    expect(find.byKey(const Key('moderation-alert-breaker')), findsNothing);
    expect(
      find.byKey(const Key('moderation-alert-breaker-card')),
      findsNothing,
    );
    expect(find.text('File de revue : 4 élément(s)'), findsOneWidget);
    expect(
      find.text('Bans automatiques : 3/3 (1 h) · 7/10 (24 h)'),
      findsOneWidget,
    );
  });

  testWidgets('éteinte sans disjoncteur : pastille « éteinte », pas rouge', (
    WidgetTester tester,
  ) async {
    await _pump(tester, settings: _settings(enabled: false));
    expect(find.text('éteinte'), findsOneWidget);
    expect(find.byKey(const Key('moderation-alert-breaker')), findsNothing);
  });

  testWidgets('erreur → « État de la modération illisible. » + ↻', (
    WidgetTester tester,
  ) async {
    int refresh = 0;
    await _pump(tester, error: 'Erreur serveur.', onRefresh: () => refresh++);
    expect(find.text('État de la modération illisible.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('moderation-alert-refresh')));
    expect(refresh, 1);
  });

  testWidgets('« Ouvrir la modération » appelle onOpen ; chargement', (
    WidgetTester tester,
  ) async {
    int open = 0;
    await _pump(tester, settings: _settings(), onOpen: () => open++);
    await tester.tap(find.text('Ouvrir la modération'));
    expect(open, 1);
    await _pump(tester, loading: true);
    expect(find.byKey(const Key('moderation-alert-refresh')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
