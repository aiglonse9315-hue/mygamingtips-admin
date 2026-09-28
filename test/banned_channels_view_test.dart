// Panneau des chaînes bannies — widgets de présentation (P4b-3, lot L8, T10,
// S-02, S-08, conception §6.12) : tableau (colonnes, état, clé révélée en
// chasse fixe, motif d'une ligne auto, boutons selon l'origine et le compte
// principal), formulaire (catégorie D4 entre le nom et le motif, motif
// obligatoire 1-500 points de code, envoi, remise à zéro), traduction d'un
// déban, rapport de ban selon `result` (retrait des publiés CONFIRMÉ, 401 →
// rapport fermé puis déconnexion).
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/banned_channels_rules.dart';
import 'package:mgt_admin/domain/models/ban_category.dart';
import 'package:mgt_admin/domain/models/banned_channel.dart';
import 'package:mgt_admin/domain/moderation_actions.dart';
import 'package:mgt_admin/ui/widgets/moderation/account_ban_widgets.dart';
import 'package:mgt_admin/ui/widgets/moderation/ban_channel_report_dialog.dart';
import 'package:mgt_admin/ui/widgets/moderation/banned_channels_view.dart';
import 'package:mgt_admin/ui/widgets/moderation/unpublish_section.dart';

import 'support/widget_fixtures.dart';

const List<BanCategory> _serverCategories = <BanCategory>[
  BanCategory(code: 'moderation', labelFr: 'Modération', autoAllowed: false),
  BanCategory(code: 'spam', labelFr: 'Spam', autoAllowed: false),
  BanCategory(code: 'abus', labelFr: 'Abus', autoAllowed: false),
  BanCategory(code: 'injection_ia', labelFr: 'Injection IA', autoAllowed: true),
  BanCategory(code: 'autre', labelFr: 'Autre', autoAllowed: false),
];

final BannedChannel _manual = BannedChannel(
  id: 1,
  handle: 'exemple',
  displayName: 'Chaîne Exemple',
  reason: 'Contenus hors sujet',
  bannedBy: 'admin-exemple',
  category: 'spam',
  createdAt: DateTime.utc(2026, 9, 28, 3, 15),
);

const BannedChannel _autoReview = BannedChannel(
  id: 2,
  handle: 'auto:UCexemple000000000000000',
  reason: 'Modération automatique (en revue)',
  bannedBy: 'bot-exemple',
  origin: 'auto',
  category: 'injection_ia',
  status: 'en_revue',
  banEventId: 42,
  manualEventId: 77,
);

const BannedChannel _autoConfirmed = BannedChannel(
  id: 3,
  handle: 'auto:rutube:abc123',
  reason: 'Modération automatique (en revue)',
  bannedBy: 'bot-exemple',
  platform: 'rutube',
  origin: 'auto',
  category: 'injection_ia',
  status: 'confirme',
  banEventId: 43,
);

const BannedChannel _converted = BannedChannel(
  id: 4,
  handle: 'auto:UCconverti0000000000000',
  reason: 'Bannissement manuel',
  origin: 'manual',
  category: 'autre',
  status: 'manuel',
  banEventId: 51,
);

Future<void> _pumpTable(
  WidgetTester tester, {
  required List<BannedChannel> channels,
  required bool isOwner,
  Set<int> busyIds = const <int>{},
  List<BannedChannel>? unbanned,
  List<(int, ReviewAction)>? actions,
}) => pumpBody(
  tester,
  BannedChannelsTable(
    channels: channels,
    isOwner: isOwner,
    busyIds: busyIds,
    categories: _serverCategories,
    onUnban: (BannedChannel c) => unbanned?.add(c),
    onAction: (BannedChannel c, ReviewAction a) => actions?.add((c.id, a)),
  ),
  width: 1200,
  size: const Size(1280, 1000),
);

IconButton _iconButton(WidgetTester tester, String key) =>
    tester.widget<IconButton>(find.byKey(Key(key)));

BanChannelReport _report({
  String result = 'applied',
  BannedChannel? banned,
  int purged = 2,
  int published = 2,
}) => BanChannelReport(
  banned: banned ?? _manual,
  purged: purged,
  published: <Map<String, dynamic>>[
    for (int i = 0; i < published; i++)
      <String, dynamic>{
        'id': 'c$i',
        'title': 'Vidéo $i',
        'url': 'https://exemple.test/$i',
      },
  ],
  publishedVia: 'suggestions-accepted',
  result: result,
);

void main() {
  group('BannedChannelsTable', () {
    testWidgets('colonnes, état, catégorie, motif d\'une ligne auto', (
      WidgetTester tester,
    ) async {
      await _pumpTable(
        tester,
        channels: <BannedChannel>[
          _manual,
          _autoReview,
          _autoConfirmed,
          _converted,
        ],
        isOwner: true,
      );
      for (final String col in kBannedChannelColumns) {
        expect(find.text(col), findsOneWidget, reason: col);
      }
      // Chaîne : libellé + nom affiché ; plateforme.
      expect(find.text('@exemple'), findsOneWidget);
      expect(find.text('Chaîne Exemple'), findsOneWidget);
      expect(find.text('YouTube · UCexemple000000000000000'), findsOneWidget);
      expect(find.text('RUTUBE · rutube:abc123'), findsOneWidget);
      expect(find.text('RUTUBE'), findsOneWidget);
      // État.
      expect(
        shownText(
          tester,
          find.byKey(const ValueKey<String>('ban-channel-state-1')),
        ),
        'Manuel',
      );
      expect(
        shownText(
          tester,
          find.byKey(const ValueKey<String>('ban-channel-state-2')),
        ),
        'Auto — en revue',
      );
      expect(
        shownText(
          tester,
          find.byKey(const ValueKey<String>('ban-channel-state-3')),
        ),
        'Auto — confirmé',
      );
      expect(
        shownText(
          tester,
          find.byKey(const ValueKey<String>('ban-channel-state-4')),
        ),
        "Manuel (issu d'un ban auto)",
      );
      // Intention manuelle sur la ligne auto 2 seulement.
      expect(
        find.byKey(const ValueKey<String>('ban-channel-intent-2')),
        findsOneWidget,
      );
      expect(find.text('+ intention manuelle'), findsOneWidget);
      // Catégorie.
      expect(find.text('Spam'), findsOneWidget);
      expect(find.text('Injection IA'), findsNWidgets(2));
      expect(find.text('Autre'), findsOneWidget);
      // Motif : l'état pour une ligne auto, jamais « … (en revue) » d'une
      // ligne confirmée.
      expect(
        shownText(
          tester,
          find.byKey(const ValueKey<String>('ban-channel-reason-3')),
        ),
        'Auto — confirmé',
      );
      expect(find.text('Modération automatique (en revue)'), findsNothing);
      expect(
        shownText(
          tester,
          find.byKey(const ValueKey<String>('ban-channel-reason-1')),
        ),
        'Contenus hors sujet',
      );
      expect(
        shownText(
          tester,
          find.byKey(const ValueKey<String>('ban-channel-reason-4')),
        ),
        'Bannissement manuel',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('clé en chasse fixe, caractères cachés révélés', (
      WidgetTester tester,
    ) async {
      final String rlo = String.fromCharCode(0x202E);
      await _pumpTable(
        tester,
        channels: <BannedChannel>[
          BannedChannel(
            id: 9,
            handle: 'auto:UCab${rlo}cd',
            origin: 'auto',
            status: 'en_revue',
            banEventId: 5,
            bannedBy: 'bot${rlo}x',
          ),
          _manual,
        ],
        isOwner: true,
      );
      final Finder label = find.byKey(
        const ValueKey<String>('ban-channel-label-9'),
      );
      expect(shownText(tester, label), 'YouTube · UCab⟦U+202E⟧cd');
      final Text keyText = tester.widget<Text>(
        find.descendant(of: label, matching: find.byType(Text)),
      );
      expect(keyText.style?.fontFamily, 'monospace');
      final Text handleText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('ban-channel-label-1')),
          matching: find.byType(Text),
        ),
      );
      expect(handleText.style?.fontFamily, isNot('monospace'));
      expect(find.text('bot⟦U+202E⟧x'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is Text && (w.data ?? '').contains(rlo),
        ),
        findsNothing,
      );
    });

    testWidgets('compte principal : manuel → Débannir ; auto en revue → '
        'Détail, Confirmer, Lever ; confirmé → Détail, Lever, Purger', (
      WidgetTester tester,
    ) async {
      final List<BannedChannel> unbanned = <BannedChannel>[];
      final List<(int, ReviewAction)> actions = <(int, ReviewAction)>[];
      await _pumpTable(
        tester,
        channels: <BannedChannel>[
          _manual,
          _autoReview,
          _autoConfirmed,
          _converted,
        ],
        isOwner: true,
        unbanned: unbanned,
        actions: actions,
      );
      expect(_iconButton(tester, 'ban-channel-1-unban').onPressed, isNotNull);
      expect(
        _iconButton(tester, 'ban-channel-1-unban').tooltip,
        'Débannir cette chaîne',
      );
      expect(_iconButton(tester, 'ban-channel-4-unban').onPressed, isNotNull);
      expect(find.byKey(const Key('ban-channel-2-unban')), findsNothing);
      for (final String k in <String>[
        'ban-channel-2-detail',
        'ban-channel-2-confirm',
        'ban-channel-2-lift',
        'ban-channel-3-detail',
        'ban-channel-3-lift',
        'ban-channel-3-purge',
      ]) {
        expect(find.byKey(ValueKey<String>(k)), findsOneWidget, reason: k);
      }
      expect(
        find.byKey(const ValueKey<String>('ban-channel-2-purge')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('ban-channel-3-confirm')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('ban-channel-1-unban')));
      await tester.tap(
        find.byKey(const ValueKey<String>('ban-channel-2-confirm')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('ban-channel-3-purge')),
      );
      await tester.pump();
      expect(unbanned.map((BannedChannel c) => c.id), <int>[1]);
      expect(actions, <(int, ReviewAction)>[
        (2, ReviewAction.confirm),
        (3, ReviewAction.purge),
      ]);
    });

    testWidgets('autre admin : ligne auto → Débannir DÉSACTIVÉ avec '
        'explication ; ligne manuelle inchangée', (WidgetTester tester) async {
      await _pumpTable(
        tester,
        channels: <BannedChannel>[_manual, _autoReview, _autoConfirmed],
        isOwner: false,
      );
      for (final int id in <int>[2, 3]) {
        final IconButton b = _iconButton(tester, 'ban-channel-$id-unban');
        expect(b.onPressed, isNull);
        expect(b.tooltip, kAutoBanReservedTooltip);
      }
      expect(
        kAutoBanReservedTooltip,
        'Bannissement automatique : levée réservée au compte principal (menu '
        'Modération).',
      );
      expect(find.text('Confirmer'), findsNothing);
      expect(find.text('Lever'), findsNothing);
      expect(find.text('Purger'), findsNothing);
      expect(_iconButton(tester, 'ban-channel-1-unban').onPressed, isNotNull);
    });

    testWidgets('ligne occupée : boutons désactivés + indicateur', (
      WidgetTester tester,
    ) async {
      await _pumpTable(
        tester,
        channels: <BannedChannel>[_manual, _autoReview],
        isOwner: true,
        busyIds: <int>{1, 2},
      );
      expect(find.byKey(const Key('ban-channel-1-unban')), findsNothing);
      final ButtonStyleButton confirm = tester.widget<ButtonStyleButton>(
        find.byKey(const ValueKey<String>('ban-channel-2-confirm')),
      );
      expect(confirm.onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    });
  });

  group('ChannelBanForm', () {
    Future<List<ChannelBanRequest>> pumpForm(
      WidgetTester tester, {
      Future<String?> Function(ChannelBanRequest r)? submit,
      List<BanCategory> categories = _serverCategories,
    }) async {
      final List<ChannelBanRequest> sent = <ChannelBanRequest>[];
      await pumpBody(
        tester,
        ChannelBanForm(
          categories: categories,
          submit: (ChannelBanRequest r) async {
            sent.add(r);
            return submit == null ? null : await submit(r);
          },
        ),
        width: 1100,
        size: const Size(1280, 1000),
      );
      return sent;
    }

    testWidgets('« Catégorie » entre « Nom affiché » et « Motif * » ; 4 '
        'catégories, défaut « Modération », jamais « Injection IA »', (
      WidgetTester tester,
    ) async {
      await pumpForm(tester);
      final Offset name = tester.getTopLeft(
        find.byKey(const Key('ban-channel-name')),
      );
      final Offset category = tester.getTopLeft(
        find.byKey(const Key('ban-category-dropdown')),
      );
      final Offset reason = tester.getTopLeft(
        find.byKey(const Key('ban-channel-reason')),
      );
      expect(category.dx, greaterThan(name.dx));
      expect(reason.dy, greaterThan(category.dy));
      expect(find.text('Motif *'), findsOneWidget);
      expect(find.text('Catégorie'), findsOneWidget);
      expect(find.text('Modération'), findsOneWidget);
      final List<String?> codes = tester
          .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .items!
          .map((DropdownMenuItem<String> i) => i.value)
          .toList();
      expect(codes, <String>['moderation', 'spam', 'abus', 'autre']);
      expect(find.text('Injection IA'), findsNothing);
      expect(find.text('0/500'), findsOneWidget);
    });

    testWidgets('champs requis : rien n\'est envoyé', (
      WidgetTester tester,
    ) async {
      final List<ChannelBanRequest> sent = await pumpForm(tester);
      await tester.tap(find.byKey(const Key('ban-channel-submit')));
      await tester.pump();
      expect(sent, isEmpty);
      expect(
        shownText(tester, find.byKey(const Key('ban-channel-error'))),
        'URL/handle et motif sont requis.',
      );
      await tester.enterText(find.byKey(const Key('ban-channel-handle')), '@x');
      await tester.enterText(
        find.byKey(const Key('ban-channel-reason')),
        '   ',
      );
      await tester.tap(find.byKey(const Key('ban-channel-submit')));
      await tester.pump();
      expect(sent, isEmpty);
    });

    testWidgets('motif de 501 points de code refusé localement', (
      WidgetTester tester,
    ) async {
      final List<ChannelBanRequest> sent = await pumpForm(tester);
      await tester.enterText(find.byKey(const Key('ban-channel-handle')), '@x');
      await tester.enterText(
        find.byKey(const Key('ban-channel-reason')),
        'a' * 501,
      );
      await tester.pump();
      expect(find.text('501/500'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ban-channel-submit')));
      await tester.pump();
      expect(sent, isEmpty);
      expect(
        shownText(tester, find.byKey(const Key('ban-channel-error'))),
        'Motif trop long : 501/500 caractères.',
      );
    });

    testWidgets('envoi : champs coupés, nom vide → null, catégorie choisie ; '
        'succès → formulaire vidé, catégorie remise au défaut', (
      WidgetTester tester,
    ) async {
      final List<ChannelBanRequest> sent = await pumpForm(tester);
      await tester.enterText(
        find.byKey(const Key('ban-channel-handle')),
        '  https://youtube.com/@exemple  ',
      );
      await tester.enterText(find.byKey(const Key('ban-channel-name')), '   ');
      await tester.enterText(
        find.byKey(const Key('ban-channel-reason')),
        '  Motif de test  ',
      );
      await tester.tap(find.byKey(const Key('ban-category-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spam').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ban-channel-submit')));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(sent.single.handleOrUrl, 'https://youtube.com/@exemple');
      expect(sent.single.reason, 'Motif de test');
      expect(sent.single.displayName, isNull);
      expect(sent.single.category, 'spam');
      expect(find.byKey(const Key('ban-channel-error')), findsNothing);
      final TextField handle = tester.widget<TextField>(
        find.byKey(const Key('ban-channel-handle')),
      );
      expect(handle.controller!.text, isEmpty);
      final TextField reason = tester.widget<TextField>(
        find.byKey(const Key('ban-channel-reason')),
      );
      expect(reason.controller!.text, isEmpty);
      expect(find.text('Modération'), findsOneWidget);
      expect(find.text('Spam'), findsNothing);
    });

    testWidgets('échec : message du serveur, champs gardés ; bouton '
        'désactivé pendant l\'envoi', (WidgetTester tester) async {
      final Completer<String?> pending = Completer<String?>();
      final List<ChannelBanRequest> sent = await pumpForm(
        tester,
        submit: (_) => pending.future,
      );
      await tester.enterText(
        find.byKey(const Key('ban-channel-handle')),
        '@exemple',
      );
      await tester.enterText(
        find.byKey(const Key('ban-channel-name')),
        ' Nom affiché ',
      );
      await tester.enterText(find.byKey(const Key('ban-channel-reason')), 'M');
      await tester.tap(find.byKey(const Key('ban-channel-submit')));
      await tester.pump();
      expect(sent.single.displayName, 'Nom affiché');
      expect(sent.single.category, 'moderation');
      final FilledButton busy = tester.widget<FilledButton>(
        find.byKey(const Key('ban-channel-submit')),
      );
      expect(busy.onPressed, isNull);
      pending.complete(
        'handle/url invalide : handle YouTube (@xxx) ou URL de chaîne attendu.',
      );
      await tester.pumpAndSettle();
      expect(
        shownText(tester, find.byKey(const Key('ban-channel-error'))),
        'handle/url invalide : handle YouTube (@xxx) ou URL de chaîne attendu.',
      );
      final TextField handle = tester.widget<TextField>(
        find.byKey(const Key('ban-channel-handle')),
      );
      expect(handle.controller!.text, '@exemple');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('ban-channel-submit')))
            .onPressed,
        isNotNull,
      );
    });
  });

  group('runChannelUnban', () {
    test('lifted / not_found', () async {
      expect(
        (await runChannelUnban(
          () async => (result: 'lifted', replayed: false),
        )).kind,
        UnbanKind.lifted,
      );
      final UnbanOutcome notFound = await runChannelUnban(
        () async => (result: 'not_found', replayed: false),
      );
      expect(notFound.kind, UnbanKind.notFound);
      expect(notFound.replayed, isFalse);
    });

    test('not_found obtenu par un REJEU → message de rejeu, propagation aux '
        'bots (INF-01)', () async {
      final UnbanOutcome o = await runChannelUnban(
        () async => (result: 'not_found', replayed: true),
      );
      expect(o.kind, UnbanKind.notFound);
      expect(o.replayed, isTrue);
      final ({String message, OutcomeTone tone, bool totalSync})? f =
          channelUnbanFeedback(o, name: '@exemple');
      expect(f!.message, kReplayNoticeMessage);
      expect(f.tone, OutcomeTone.warning);
      expect(f.totalSync, isTrue);
    });

    test(
      '409 auto_ban_use_review → ban automatique avec l\'événement',
      () async {
        final UnbanOutcome o = await runChannelUnban(
          () async => throw const AdminApiException(
            409,
            'Chaîne bannie automatiquement : levée par le compte principal '
            'depuis la modération.',
            body: <String, dynamic>{
              'result': 'auto_ban_use_review',
              'ban_event_id': 42,
            },
          ),
        );
        expect(o.kind, UnbanKind.autoBan);
        expect(o.banEventId, 42);
      },
    );

    test(
      '401 → session expirée ; 403, 5xx, réseau → échec avec message',
      () async {
        expect(
          (await runChannelUnban(
            () async => throw const AdminAuthException('Session expirée'),
          )).kind,
          UnbanKind.sessionExpired,
        );
        final UnbanOutcome forbidden = await runChannelUnban(
          () async =>
              throw const AdminForbiddenException('Compte admin inactif.'),
        );
        expect(forbidden.kind, UnbanKind.failure);
        expect(forbidden.message, 'Compte admin inactif.');
        final UnbanOutcome server = await runChannelUnban(
          () async =>
              throw const AdminApiException(502, 'Erreur serveur (HTTP 502).'),
        );
        expect(server.kind, UnbanKind.failure);
        expect(server.message, 'Erreur serveur (HTTP 502).');
        final UnbanOutcome other = await runChannelUnban(
          () async => throw Exception('coupure'),
        );
        expect(other.kind, UnbanKind.failure);
        expect(other.message, 'coupure');
      },
    );
  });

  group('BanChannelReportDialog', () {
    Future<DialogProbe<void>> openReport(
      WidgetTester tester,
      BanChannelReport report, {
      Future<UnpublishResult> Function()? unpublish,
      VoidCallback? onAuthError,
    }) async {
      final DialogProbe<void> probe = await openDialog<void>(
        tester,
        (_) => BanChannelReportDialog(
          report: report,
          unpublish:
              unpublish ??
              () async => (
                deleted: 0,
                removed: const <Map<String, dynamic>>[],
                replayed: false,
              ),
          onAuthError: onAuthError ?? () {},
        ),
      );
      await tester.pumpAndSettle();
      return probe;
    }

    testWidgets('applied : titre, purge, publiés révélés, retrait CONFIRMÉ '
        'puis bilan du serveur', (WidgetTester tester) async {
      int calls = 0;
      await openReport(
        tester,
        _report(),
        unpublish: () async {
          calls++;
          return (
            deleted: 2,
            removed: <Map<String, dynamic>>[
              <String, dynamic>{'id': 'c0', 'title': 'Vidéo 0'},
              <String, dynamic>{'id': 'c1', 'title': 'Vidéo 1'},
            ],
            replayed: false,
          );
        },
      );
      expect(
        shownText(tester, find.byKey(const Key('ban-channel-report-title'))),
        '🚫 @exemple bannie',
      );
      expect(
        find.text(
          '2 suggestion(s) en file rejetée(s) (motif : Chaîne bannie).',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('ban-channel-report-updated')), findsNothing);
      expect(
        find.text(
          "⚠️ 2 contenu(s) de cette chaîne sont déjà PUBLIÉS dans l'app :",
        ),
        findsOneWidget,
      );
      expect(find.text('• Vidéo 0'), findsOneWidget);
      expect(find.text('Retirer aussi ces 2 contenus publiés'), findsOneWidget);
      await tester.tap(find.byKey(const Key('moderation-unpublish-button')));
      await tester.pumpAndSettle();
      expect(calls, 0, reason: 'confirmation rouge d\'abord');
      expect(
        find.text('Supprimer définitivement 2 contenu(s) publié(s) ?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Supprimer'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(
        shownText(
          tester,
          find.byKey(const Key('moderation-unpublish-summary')),
        ),
        '✅ 2 contenu(s) publié(s) retiré(s) de @exemple.',
      );
    });

    testWidgets('updated : titre « mis à jour » + « Motif et catégorie '
        'remplacés. » + même rapport', (WidgetTester tester) async {
      await openReport(tester, _report(result: 'updated', published: 1));
      expect(
        shownText(tester, find.byKey(const Key('ban-channel-report-title'))),
        '@exemple : bannissement mis à jour',
      );
      expect(find.text('Motif et catégorie remplacés.'), findsOneWidget);
      expect(find.text('Retirer aussi ces 1 contenus publiés'), findsOneWidget);
    });

    testWidgets('auto_en_revue : texte neutre, AUCUN bouton de retrait', (
      WidgetTester tester,
    ) async {
      await openReport(
        tester,
        _report(
          result: 'auto_en_revue',
          banned: _autoConfirmed,
          purged: 0,
          published: 2,
        ),
      );
      expect(
        shownText(tester, find.byKey(const Key('ban-channel-report-title'))),
        'Chaîne déjà bannie automatiquement',
      );
      expect(
        shownText(tester, find.byKey(const Key('ban-channel-report-auto'))),
        banReportAutoText('confirme'),
      );
      expect(banReportAutoText('confirme'), contains('(Confirmé)'));
      expect(
        find.byKey(const Key('moderation-unpublish-button')),
        findsNothing,
      );
      expect(find.byKey(const Key('ban-channel-report-purged')), findsNothing);
    });

    testWidgets('sans contenu publié ; plus de 20 publiés → « … et N '
        'autre(s). »', (WidgetTester tester) async {
      await openReport(tester, _report(published: 0));
      expect(
        find.text('Aucun contenu publié connu pour cette chaîne.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('moderation-unpublish-button')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('ban-channel-report-close')));
      await tester.pumpAndSettle();

      await openReport(tester, _report(published: 25));
      expect(find.text('… et 5 autre(s).'), findsOneWidget);
      expect(
        find.text('Retirer aussi ces 25 contenus publiés'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('401 pendant le retrait → rapport FERMÉ puis onAuthError', (
      WidgetTester tester,
    ) async {
      int authErrors = 0;
      final DialogProbe<void> probe = await openReport(
        tester,
        _report(),
        unpublish: () async =>
            throw const AdminAuthException('Session expirée'),
        onAuthError: () => authErrors++,
      );
      await tester.tap(find.byKey(const Key('moderation-unpublish-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Supprimer'));
      await tester.pumpAndSettle();
      expect(authErrors, 1);
      expect(probe.closed, isTrue);
      expect(find.byType(BanChannelReportDialog), findsNothing);
    });

    testWidgets('retrait en cours : rapport NON fermable (Fermer désactivé, '
        'barrière sans effet), puis 401 → fermé et onAuthError (ARC-02)', (
      WidgetTester tester,
    ) async {
      int authErrors = 0;
      final Completer<UnpublishResult> pending = Completer<UnpublishResult>();
      final DialogProbe<void> probe = await openReport(
        tester,
        _report(),
        unpublish: () => pending.future,
        onAuthError: () => authErrors++,
      );
      await tester.tap(find.byKey(const Key('moderation-unpublish-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Supprimer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final Finder close = find.byKey(const Key('ban-channel-report-close'));
      expect(tester.widget<FilledButton>(close).onPressed, isNull);
      await tester.tap(close, warnIfMissed: false);
      await tester.tapAt(const Offset(5, 5)); // barrière
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(probe.closed, isFalse);
      expect(find.byType(BanChannelReportDialog), findsOneWidget);

      pending.completeError(const AdminAuthException('Session expirée'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(authErrors, 1);
      expect(probe.closed, isTrue);
      expect(find.byType(BanChannelReportDialog), findsNothing);
    });

    testWidgets('retrait terminé : bilan affiché, « Fermer » de nouveau '
        'actif (ARC-02)', (WidgetTester tester) async {
      final Completer<UnpublishResult> pending = Completer<UnpublishResult>();
      final DialogProbe<void> probe = await openReport(
        tester,
        _report(),
        unpublish: () => pending.future,
      );
      await tester.tap(find.byKey(const Key('moderation-unpublish-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Supprimer'));
      await tester.pump();
      pending.complete((
        deleted: 2,
        removed: const <Map<String, dynamic>>[],
        replayed: false,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('moderation-unpublish-summary')),
        findsOneWidget,
      );
      final Finder close = find.byKey(const Key('ban-channel-report-close'));
      expect(tester.widget<FilledButton>(close).onPressed, isNotNull);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(probe.closed, isTrue);
    });

    testWidgets('titre : caractères cachés révélés', (
      WidgetTester tester,
    ) async {
      final String rlo = String.fromCharCode(0x202E);
      await openReport(
        tester,
        _report(
          banned: BannedChannel(id: 8, handle: 'ab${rlo}cd'),
          published: 0,
        ),
      );
      expect(
        shownText(tester, find.byKey(const Key('ban-channel-report-title'))),
        '🚫 @ab⟦U+202E⟧cd bannie',
      );
    });
  });
}
