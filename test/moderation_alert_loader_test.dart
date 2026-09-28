// Chargement de la carte « Modération automatique » du tableau de bord
// (P4b-3, lot L6, T9, D1, conception §6.10) : lecture après la première
// image (jamais de minuterie), ↻ relit, 403 → la carte DISPARAÎT, 401 →
// déconnexion (`onAuthError`), autre erreur → « État de la modération
// illisible. » sans SnackBar, réglages déjà lus conservés.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/data/supabase_sync.dart'
    show AdminApiException, AdminAuthException, AdminForbiddenException;
import 'package:mgt_admin/domain/models/moderation.dart';
import 'package:mgt_admin/ui/widgets/moderation/moderation_alert_loader.dart';

import 'support/widget_fixtures.dart';

ModerationSettings _settings({bool enabled = false, int queue = 4}) =>
    ModerationSettings.fromJson(<String, dynamic>{
      'auto_ban_enabled': enabled,
      'max_auto_bans_per_hour': 3,
      'max_auto_bans_per_day': 10,
      'auto_bans_last_hour': 1,
      'auto_bans_last_day': 2,
      'review_queue_size': queue,
    })!;

Future<void> _pump(
  WidgetTester tester,
  Future<ModerationSettings> Function() load, {
  VoidCallback? onAuthError,
  VoidCallback? onOpen,
}) async {
  await pumpBody(
    tester,
    ModerationAlertLoader(
      load: load,
      onAuthError: onAuthError ?? () {},
      onOpen: onOpen ?? () {},
    ),
  );
  // Lecture lancée après la première image, puis réponse.
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('lecture au montage : état, file, compteurs ; « Ouvrir la '
      'modération » → onOpen', (WidgetTester tester) async {
    int loads = 0;
    int opened = 0;
    await _pump(tester, () async {
      loads++;
      return _settings(enabled: true);
    }, onOpen: () => opened++);
    expect(loads, 1);
    expect(find.text('Modération automatique'), findsOneWidget);
    expect(find.text('allumée'), findsOneWidget);
    expect(find.text('File de revue : 4 élément(s)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('moderation-alert-open')));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('↻ relit les réglages (aucune minuterie)', (
    WidgetTester tester,
  ) async {
    int loads = 0;
    await _pump(tester, () async {
      loads++;
      return _settings(queue: loads);
    });
    expect(find.text('File de revue : 1 élément(s)'), findsOneWidget);
    await tester.pump(const Duration(minutes: 5));
    expect(loads, 1, reason: 'pas de relecture périodique');
    await tester.tap(find.byKey(const Key('moderation-alert-refresh')));
    await tester.pump();
    await tester.pump();
    expect(loads, 2);
    expect(find.text('File de revue : 2 élément(s)'), findsOneWidget);
  });

  testWidgets('403 → la carte disparaît, sans déconnexion', (
    WidgetTester tester,
  ) async {
    int auth = 0;
    await _pump(
      tester,
      () async => throw const AdminForbiddenException('Réservé.'),
      onAuthError: () => auth++,
    );
    expect(find.text('Modération automatique'), findsNothing);
    expect(find.byType(Card), findsNothing);
    expect(auth, 0);
  });

  testWidgets('401 → onAuthError une fois, rien affiché', (
    WidgetTester tester,
  ) async {
    int auth = 0;
    await _pump(
      tester,
      () async => throw const AdminAuthException('Session expirée.'),
      onAuthError: () => auth++,
    );
    expect(auth, 1);
    expect(find.text('Modération automatique'), findsNothing);
  });

  testWidgets('401 reçu APRÈS le départ du tableau de bord → onAuthError '
      'quand même, sans exception (ARC-04)', (WidgetTester tester) async {
    int auth = 0;
    final Completer<ModerationSettings> pending =
        Completer<ModerationSettings>();
    await _pump(tester, () => pending.future, onAuthError: () => auth++);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // L'admin quitte le tableau de bord pendant la lecture.
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(const AdminAuthException('Session expirée.'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(auth, 1);
  });

  testWidgets('autre erreur → « État de la modération illisible. » + ↻ ; '
      'une relecture réussie l’efface', (WidgetTester tester) async {
    int loads = 0;
    await _pump(tester, () async {
      loads++;
      if (loads == 1) throw const AdminApiException(500, 'Erreur serveur.');
      return _settings();
    });
    expect(find.text('État de la modération illisible.'), findsOneWidget);
    expect(find.text('Erreur serveur.'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.byKey(const Key('moderation-alert-refresh')));
    await tester.pump();
    await tester.pump();
    expect(find.text('État de la modération illisible.'), findsNothing);
    expect(find.text('éteinte'), findsOneWidget);
  });

  testWidgets('erreur après une lecture réussie → réglages conservés + '
      'ligne d’erreur', (WidgetTester tester) async {
    int loads = 0;
    await _pump(tester, () async {
      loads++;
      if (loads == 2) throw const AdminApiException(502, 'Erreur serveur.');
      return _settings(queue: 7);
    });
    await tester.tap(find.byKey(const Key('moderation-alert-refresh')));
    await tester.pump();
    await tester.pump();
    expect(find.text('File de revue : 7 élément(s)'), findsOneWidget);
    expect(find.text('État de la modération illisible.'), findsOneWidget);
  });

  testWidgets('pendant la lecture : indicateur, pas de ↻ ; réponse → '
      'réglages affichés', (WidgetTester tester) async {
    final Completer<ModerationSettings> pending =
        Completer<ModerationSettings>();
    await _pump(tester, () => pending.future);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('moderation-alert-refresh')), findsNothing);
    expect(find.text('Chargement…'), findsOneWidget);
    pending.complete(_settings(queue: 9));
    await tester.pump();
    expect(find.text('File de revue : 9 élément(s)'), findsOneWidget);
    expect(find.byKey(const Key('moderation-alert-refresh')), findsOneWidget);
  });
}
