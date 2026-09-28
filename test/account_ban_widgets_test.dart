// Bans de COMPTES dans les listes (P4b-3, lot L6, T3, T15, conception
// §6.10, §6.11) : bouton de fin choisi d'après l'origine CONNUE avant le
// clic (ban manuel → « Débannir » ; ban automatique → « Lever… » pour le
// compte principal, désactivé avec explication pour un autre admin ;
// origine inconnue → « Débannir », le serveur tranche), sous-titre de la
// ligne (id court, catégorie, date locale ou « date inconnue », motif révélé
// ou « Sans motif »), pastilles « + ban manuel » et « auto ».
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/models/ban_category.dart';
import 'package:mgt_admin/domain/models/banned_user.dart';
import 'package:mgt_admin/ui/widgets/moderation/account_ban_widgets.dart';

import 'support/widget_fixtures.dart';

const String _uuid = '11111111-2222-4333-8444-555555555555';

BannedUser _manual({
  String? reason = 'Motif neutre',
  DateTime? bannedAt,
  String category = 'spam',
}) => BannedUser(
  id: _uuid,
  displayName: 'Compte Exemple',
  reason: reason,
  bannedAt: bannedAt,
  category: category,
);

BannedUser _auto({
  String status = 'en_revue',
  int? banEventId = 42,
  bool manualBanPresent = false,
}) => BannedUser(
  id: _uuid,
  displayName: 'Compte Auto',
  reason: 'Détecteur',
  category: 'injection_ia',
  origin: 'auto',
  status: status,
  banEventId: banEventId,
  manualBanPresent: manualBanPresent,
);

/// Le `IconButton` construit par l'`AccountUnbanIconButton` de clé [key].
Finder _iconButton(String key) => find.descendant(
  of: find.byKey(Key(key)),
  matching: find.byType(IconButton),
);

String _two(int v) => v.toString().padLeft(2, '0');

/// Même conversion que l'écran : heure locale, JJ/MM/AAAA HH:mm (le poste
/// est en UTC+7, la CI en UTC — jamais un littéral).
String _expectedDate(DateTime at) {
  final DateTime d = at.toLocal();
  return '${_two(d.day)}/${_two(d.month)}/${d.year} '
      '${_two(d.hour)}:${_two(d.minute)}';
}

void main() {
  group('accountUnbanControl', () {
    test('origine inconnue (entrée absente) → « Débannir » simple', () {
      final AccountUnbanControl c = accountUnbanControl(null, isOwner: false);
      expect(c.action, AccountUnbanAction.unbanConfirm);
      expect(c.label, 'Débannir');
      expect(c.tooltip, 'Débannir');
      expect(c.enabled, isTrue);
    });

    test('ban manuel → « Débannir (ban manuel) », owner ou non', () {
      for (final bool owner in <bool>[true, false]) {
        final AccountUnbanControl c = accountUnbanControl(
          _manual(),
          isOwner: owner,
        );
        expect(c.action, AccountUnbanAction.unbanConfirm, reason: '$owner');
        expect(c.label, 'Débannir');
        expect(c.tooltip, kUnbanManualTooltip);
        expect(c.tooltip, 'Débannir (ban manuel)');
      }
    });

    test('ban auto en revue, compte principal → « Lever… »', () {
      final AccountUnbanControl c = accountUnbanControl(_auto(), isOwner: true);
      expect(c.action, AccountUnbanAction.liftAuto);
      expect(c.label, 'Lever…');
      expect(c.tooltip, 'Lever (ban automatique en revue)');
      expect(c.enabled, isTrue);
    });

    test('ban auto confirmé, compte principal → infobulle « confirmé »', () {
      final AccountUnbanControl c = accountUnbanControl(
        _auto(status: 'confirme'),
        isOwner: true,
      );
      expect(c.action, AccountUnbanAction.liftAuto);
      expect(c.tooltip, 'Lever (ban automatique confirmé)');
    });

    test('ban auto, autre admin → désactivé avec explication', () {
      final AccountUnbanControl c = accountUnbanControl(
        _auto(),
        isOwner: false,
      );
      expect(c.action, AccountUnbanAction.reservedToOwner);
      expect(c.enabled, isFalse);
      expect(
        c.tooltip,
        'Bannissement automatique : levée réservée au compte principal '
        '(menu Modération).',
      );
    });

    test(
      'ban auto sans événement connu → « Débannir » (le 409 le donnera)',
      () {
        final AccountUnbanControl c = accountUnbanControl(
          _auto(banEventId: null),
          isOwner: true,
        );
        expect(c.action, AccountUnbanAction.unbanConfirm);
        expect(c.label, 'Débannir');
      },
    );
  });

  group('bannedAccountSubtitle', () {
    test('id court · catégorie · date locale · motif', () {
      final DateTime at = DateTime.utc(2026, 9, 28, 3, 15);
      expect(
        bannedAccountSubtitle(_manual(bannedAt: at)),
        '11111111… · Spam · ${_expectedDate(at)} · Motif neutre',
      );
    });

    test('date absente → « date inconnue » ; motif absent / blanc → « Sans '
        'motif »', () {
      expect(
        bannedAccountSubtitle(_manual(reason: null)),
        '11111111… · Spam · date inconnue · Sans motif',
      );
      expect(
        bannedAccountSubtitle(_manual(reason: '   ')),
        endsWith('· Sans motif'),
      );
    });

    test('catégorie : liste du serveur, sinon repli, sinon Injection IA', () {
      expect(
        bannedAccountSubtitle(
          _manual(category: 'abus'),
          categories: const <BanCategory>[
            BanCategory(
              code: 'abus',
              labelFr: 'Abus (serveur)',
              autoAllowed: false,
            ),
          ],
        ),
        contains('· Abus (serveur) ·'),
      );
      expect(bannedAccountSubtitle(_auto()), contains('· Injection IA ·'));
    });

    test('motif : caractères cachés rendus visibles, sauts de ligne sur une '
        'ligne', () {
      final String rlo = String.fromCharCode(0x202E);
      final String s = bannedAccountSubtitle(_manual(reason: 'a${rlo}b\nc'));
      expect(s, isNot(contains(rlo)));
      expect(s, contains('⟦U+202E⟧'));
      expect(s, isNot(contains('\n')));
    });
  });

  group('BannedAccountTile', () {
    testWidgets('ban manuel : statut « Manuel », « Débannir » → onUnban', (
      WidgetTester tester,
    ) async {
      int unban = 0;
      int lift = 0;
      await pumpBody(
        tester,
        BannedAccountTile(
          entry: _manual(),
          isOwner: true,
          onUnban: () => unban++,
          onLift: () => lift++,
        ),
      );
      expect(find.text('Manuel'), findsOneWidget);
      expect(find.text('+ ban manuel'), findsNothing);
      expect(find.text('Débannir'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ban-row-action-$_uuid')));
      await tester.pump();
      expect(unban, 1);
      expect(lift, 0);
    });

    testWidgets('ban auto en revue + ban manuel, owner : « Lever… » → onLift', (
      WidgetTester tester,
    ) async {
      int unban = 0;
      int lift = 0;
      await pumpBody(
        tester,
        BannedAccountTile(
          entry: _auto(manualBanPresent: true),
          isOwner: true,
          onUnban: () => unban++,
          onLift: () => lift++,
        ),
      );
      expect(find.text('Auto — en revue'), findsOneWidget);
      expect(find.text('+ ban manuel'), findsOneWidget);
      expect(find.text('Lever…'), findsOneWidget);
      expect(find.byIcon(Icons.gavel_rounded), findsOneWidget);
      await tester.tap(find.byKey(const Key('ban-row-action-$_uuid')));
      await tester.pump();
      expect(lift, 1);
      expect(unban, 0);
    });

    testWidgets('ban auto, autre admin : « Débannir » désactivé + infobulle', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      await pumpBody(
        tester,
        BannedAccountTile(
          entry: _auto(status: 'confirme'),
          isOwner: false,
          onUnban: () => calls++,
          onLift: () => calls++,
        ),
      );
      expect(find.text('Auto — confirmé'), findsOneWidget);
      final Finder button = find.byKey(const Key('ban-row-action-$_uuid'));
      final ButtonStyleButton b = tester.widget<ButtonStyleButton>(button);
      expect(b.onPressed, isNull);
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(calls, 0);
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is Tooltip && w.message == kAutoBanReservedTooltip,
        ),
        findsOneWidget,
      );
    });

    testWidgets('nom révélé sur une ligne (U+202E en jeton)', (
      WidgetTester tester,
    ) async {
      final String rlo = String.fromCharCode(0x202E);
      await pumpBody(
        tester,
        BannedAccountTile(
          entry: BannedUser(id: _uuid, displayName: 'nom${rlo}x'),
          isOwner: true,
          onUnban: () {},
          onLift: () {},
        ),
      );
      expect(find.text('nom⟦U+202E⟧x'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('AccountUnbanIconButton', () {
    testWidgets('manuel → cadenas, onUnban ; auto owner → marteau, onLift', (
      WidgetTester tester,
    ) async {
      final List<String> calls = <String>[];
      await pumpBody(
        tester,
        Row(
          children: <Widget>[
            AccountUnbanIconButton(
              key: const Key('manuel'),
              control: accountUnbanControl(_manual(), isOwner: true),
              onUnban: () => calls.add('unban-manuel'),
              onLift: () => calls.add('lift-manuel'),
            ),
            AccountUnbanIconButton(
              key: const Key('auto'),
              control: accountUnbanControl(_auto(), isOwner: true),
              onUnban: () => calls.add('unban-auto'),
              onLift: () => calls.add('lift-auto'),
            ),
          ],
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('manuel')),
          matching: find.byIcon(Icons.lock_open_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('auto')),
          matching: find.byIcon(Icons.gavel_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(_iconButton('manuel'));
      await tester.tap(_iconButton('auto'));
      await tester.pump();
      expect(calls, <String>['unban-manuel', 'lift-auto']);
      expect(
        tester.widget<IconButton>(_iconButton('manuel')).tooltip,
        'Débannir (ban manuel)',
      );
    });

    testWidgets('ban auto vu par un autre admin → désactivé ; ligne occupée '
        '(rappel nul) → désactivé', (WidgetTester tester) async {
      await pumpBody(
        tester,
        Row(
          children: <Widget>[
            AccountUnbanIconButton(
              key: const Key('reserve'),
              control: accountUnbanControl(_auto(), isOwner: false),
              onUnban: () {},
              onLift: () {},
            ),
            AccountUnbanIconButton(
              key: const Key('occupe'),
              control: accountUnbanControl(_manual(), isOwner: true),
              onUnban: null,
              onLift: null,
            ),
          ],
        ),
      );
      final IconButton reserved = tester.widget<IconButton>(
        _iconButton('reserve'),
      );
      expect(reserved.onPressed, isNull);
      expect(reserved.tooltip, kAutoBanReservedTooltip);
      expect(
        tester.widget<IconButton>(_iconButton('occupe')).onPressed,
        isNull,
      );
    });
  });

  testWidgets('AutoBanPill : « auto » + statut en infobulle', (
    WidgetTester tester,
  ) async {
    await pumpBody(tester, const AutoBanPill(status: 'en_revue'));
    expect(find.text('auto'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Tooltip && w.message == 'Auto — en revue',
      ),
      findsOneWidget,
    );
  });
}
