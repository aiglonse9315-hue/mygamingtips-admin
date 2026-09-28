// Panneau des chaînes bannies — règles pures (P4b-3, lot L8, T10,
// conception §6.12) : colonnes, état (manuel / auto / converti / intention
// manuelle), plateforme, motif d'une ligne auto, fin de ligne selon
// l'origine et le compte principal, formulaire (motif 1-500 points de code),
// rapport selon `result`, issue d'un déban et d'une levée convertissante,
// page de repli.
// Aucune dépendance dart:html — exécuté en VM par `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/banned_channels_rules.dart';
import 'package:mgt_admin/domain/models/banned_channel.dart';
import 'package:mgt_admin/domain/moderation_actions.dart';

BannedChannel _manual({
  int id = 1,
  String handle = 'exemple',
  String? reason = 'Contenus hors sujet',
  String? displayName,
}) => BannedChannel(
  id: id,
  handle: handle,
  reason: reason,
  displayName: displayName,
  bannedBy: 'admin-exemple',
  createdAt: DateTime.utc(2026, 9, 28, 3, 15),
);

BannedChannel _auto({
  int id = 2,
  String key = 'UCexemple000000000000000',
  String platform = 'youtube',
  String status = 'en_revue',
  int? banEventId = 42,
  int? manualEventId,
}) => BannedChannel(
  id: id,
  handle: 'auto:$key',
  reason: 'Modération automatique (en revue)',
  bannedBy: 'bot-exemple',
  platform: platform,
  origin: 'auto',
  category: 'injection_ia',
  status: status,
  banEventId: banEventId,
  manualEventId: manualEventId,
);

BannedChannel _converted() => const BannedChannel(
  id: 3,
  handle: 'auto:rutube:abc123',
  reason: 'Bannissement manuel',
  platform: 'rutube',
  origin: 'manual',
  category: 'spam',
  status: 'manuel',
  banEventId: 50,
);

void main() {
  test('colonnes du tableau (§6.12)', () {
    expect(kBannedChannelColumns, <String>[
      'Chaîne',
      'Plateforme',
      'État',
      'Catégorie',
      'Motif',
      'Date',
      'Par',
      'Actions',
    ]);
  });

  test('texte d\'aide réécrit', () {
    expect(
      kBannedChannelsHelp,
      'Bannir une chaîne rejette ses suggestions en attente (motif « Chaîne '
      'bannie ») ; les contenus déjà publiés sont signalés dans le rapport '
      '(retrait manuel). Les lignes « Auto » viennent du ban automatique : '
      'seul le compte principal peut les confirmer, les lever ou purger leurs '
      'suggestions.',
    );
  });

  group('cellules', () {
    test('état : manuel, auto en revue / confirmé, converti', () {
      expect(channelStateLabel(_manual()), 'Manuel');
      expect(channelStateLabel(_auto()), 'Auto — en revue');
      expect(channelStateLabel(_auto(status: 'confirme')), 'Auto — confirmé');
      expect(channelStateLabel(_converted()), "Manuel (issu d'un ban auto)");
      expect(channelStateStatus(_auto(status: 'confirme')), 'confirme');
      expect(channelStateStatus(_converted()), 'manuel');
      expect(channelStateStatus(_manual()), 'manuel');
    });

    test('clé technique auto:… (auto ou convertie) → chasse fixe', () {
      expect(isChannelKeyRow(_manual()), isFalse);
      expect(isChannelKeyRow(_auto()), isTrue);
      expect(isChannelKeyRow(_converted()), isTrue);
    });

    test('plateforme : colonne, sinon forme de la clé (base sans colonne)', () {
      expect(channelPlatformLabel(_manual()), 'YouTube');
      expect(channelPlatformLabel(_auto()), 'YouTube');
      expect(channelPlatformLabel(_converted()), 'RUTUBE');
      expect(channelPlatformLabel(_auto(key: 'rutube:x1')), 'RUTUBE');
      expect(channelPlatformLabel(_auto(key: 'bili:x2')), 'bilibili');
      expect(
        channelPlatformLabel(_auto(key: 'bili:x2', platform: 'bilibili')),
        'bilibili',
      );
    });

    test('motif : l\'ÉTAT pour une ligne auto (le motif serveur reste « en '
        'revue » après confirmation) ; sinon le motif, « — » s\'il manque', () {
      expect(channelReasonText(_auto(status: 'confirme')), 'Auto — confirmé');
      expect(channelReasonText(_auto()), 'Auto — en revue');
      expect(channelReasonText(_manual()), 'Contenus hors sujet');
      expect(channelReasonText(_converted()), 'Bannissement manuel');
      expect(channelReasonText(_manual(reason: null)), '—');
      expect(channelReasonText(_manual(reason: '   ')), '—');
    });

    test('infobulle de la chaîne : clé révélée + nom affiché révélé', () {
      final String rlo = String.fromCharCode(0x202E);
      final String zwsp = String.fromCharCode(0x200B);
      final String tip = channelCellTooltip(
        _manual(handle: 'ab${rlo}cd', displayName: ' Nom${zwsp}X '),
      );
      expect(tip, contains('⟦U+202E⟧'));
      expect(tip, isNot(contains(rlo)));
      expect(tip, contains('\nNom affiché : Nom⟦U+200B⟧X'));
      expect(tip, isNot(contains(zwsp)));
      expect(channelCellTooltip(_manual()), '@exemple');
      expect(channelCellTooltip(_auto()), 'YouTube · UCexemple000000000000000');
    });
  });

  group('fin de ligne', () {
    test('manuelle et convertie → Débannir (compte principal ou non)', () {
      for (final bool owner in <bool>[true, false]) {
        expect(
          channelRowControl(_manual(), isOwner: owner),
          const ChannelRowControl(ChannelRowAction.unban),
        );
        expect(
          channelRowControl(_converted(), isOwner: owner),
          const ChannelRowControl(ChannelRowAction.unban),
        );
      }
    });

    test('auto + autre admin → Débannir désactivé', () {
      expect(
        channelRowControl(_auto(), isOwner: false),
        const ChannelRowControl(ChannelRowAction.reservedToOwner),
      );
      expect(
        channelRowControl(_auto(status: 'confirme'), isOwner: false).action,
        ChannelRowAction.reservedToOwner,
      );
    });

    test('détail d’une ligne auto pour un autre admin : AUCUN bouton de '
        'décision (le panneau passe le statut réel, SEC-P4b3-06)', () {
      for (final String status in <String>['en_revue', 'confirme']) {
        expect(
          channelRowControl(_auto(status: status), isOwner: false).actions,
          isEmpty,
        );
      }
    });

    test('auto + compte principal : en revue → Détail, Confirmer, Lever ; '
        'confirmé → Détail, Lever, Purger', () {
      expect(
        channelRowControl(_auto(), isOwner: true),
        const ChannelRowControl(
          ChannelRowAction.review,
          actions: <ReviewAction>[
            ReviewAction.detail,
            ReviewAction.confirm,
            ReviewAction.lift,
          ],
        ),
      );
      expect(
        channelRowControl(_auto(status: 'confirme'), isOwner: true),
        const ChannelRowControl(
          ChannelRowAction.review,
          actions: <ReviewAction>[
            ReviewAction.detail,
            ReviewAction.lift,
            ReviewAction.purge,
          ],
        ),
      );
    });

    test('auto sans événement → Débannir (le 409 porte l\'événement) ; '
        'statut inconnu → Détail seulement', () {
      expect(
        channelRowControl(_auto(banEventId: null), isOwner: true),
        const ChannelRowControl(ChannelRowAction.unban),
      );
      expect(
        channelRowControl(_auto(status: 'bizarre'), isOwner: true),
        const ChannelRowControl(
          ChannelRowAction.review,
          actions: <ReviewAction>[ReviewAction.detail],
        ),
      );
    });
  });

  group('formulaire', () {
    test('URL / handle et motif requis', () {
      expect(channelBanFormError('', 'motif'), kChannelBanRequiredMessage);
      expect(channelBanFormError('@exemple', ''), kChannelBanRequiredMessage);
      expect(channelBanFormError('  ', '  '), kChannelBanRequiredMessage);
      expect(kChannelBanRequiredMessage, 'URL/handle et motif sont requis.');
    });

    test('motif : 500 points de code (émojis compris) valide, 501 refusé, '
        'caractère interdit refusé, espaces autour ignorés', () {
      final String emoji = String.fromCharCode(0x1F600);
      final String ok = '${'a' * 400}${emoji * 100}';
      expect(ok.runes.length, 500);
      expect(ok.length, 600, reason: '2 unités UTF-16 par émoji');
      expect(channelBanFormError('@exemple', ok), isNull);
      expect(channelBanFormError('@exemple', '  $ok  '), isNull);
      expect(
        channelBanFormError('@exemple', 'a' * 501),
        'Motif trop long : 501/500 caractères.',
      );
      expect(
        channelBanFormError('@exemple', 'a${String.fromCharCode(0)}b'),
        'Motif invalide : caractère interdit (U+0000 ou demi-paire).',
      );
      expect(
        channelBanFormError('@exemple', 'a${String.fromCharCode(0xD800)}b'),
        'Motif invalide : caractère interdit (U+0000 ou demi-paire).',
      );
      expect(channelBanFormError('@exemple', 'Motif'), isNull);
    });
  });

  group('rapport de ban', () {
    test('forme selon result (inconnu → applied)', () {
      expect(banReportKind('applied'), BanReportKind.applied);
      expect(banReportKind('updated'), BanReportKind.updated);
      expect(banReportKind('auto_en_revue'), BanReportKind.autoInReview);
      expect(banReportKind('autre'), BanReportKind.applied);
    });

    test('titres', () {
      expect(
        banReportTitle(BanReportKind.applied, '@exemple'),
        '🚫 @exemple bannie',
      );
      expect(
        banReportTitle(BanReportKind.updated, '@exemple'),
        '@exemple : bannissement mis à jour',
      );
      expect(
        banReportTitle(BanReportKind.autoInReview, 'YouTube · UCx'),
        'Chaîne déjà bannie automatiquement',
      );
      final String rlo = String.fromCharCode(0x202E);
      final String t = banReportTitle(BanReportKind.applied, '@ab${rlo}cd');
      expect(t, '🚫 @ab⟦U+202E⟧cd bannie');
    });

    test('texte auto_en_revue (C-09) : statut de la ligne auto', () {
      expect(
        banReportAutoText('en_revue'),
        'Cette chaîne est déjà bannie par le ban automatique (En revue). Une '
        'intention manuelle est enregistrée pour cette chaîne (la première '
        'saisie est conservée) ; elle restera en vigueur si le ban '
        "automatique est levé. Aucune suggestion n'a été purgée ici.",
      );
      expect(banReportAutoText('confirme'), contains('(Confirmé).'));
      expect(banReportAutoText('en_revue'), contains('(En revue).'));
    });

    test('textes du rapport manuel', () {
      expect(
        banReportPurgedText(3),
        '3 suggestion(s) en file rejetée(s) (motif : Chaîne bannie).',
      );
      expect(
        banReportPublishedHeader(2),
        "⚠️ 2 contenu(s) de cette chaîne sont déjà PUBLIÉS dans l'app :",
      );
      expect(banReportMoreText(5), '… et 5 autre(s).');
      expect(kBanReportUpdatedText, 'Motif et catégorie remplacés.');
    });

    test('libellé d\'un contenu publié : titre, URL, id, « — »', () {
      expect(
        publishedItemLabel(<String, dynamic>{'title': 'T', 'url': 'u'}),
        'T',
      );
      expect(
        publishedItemLabel(<String, dynamic>{'title': ' ', 'url': 'u'}),
        'u',
      );
      expect(publishedItemLabel(<String, dynamic>{'id': 'c9'}), 'c9');
      expect(publishedItemLabel(<String, dynamic>{'title': 7}), '—');
    });

    test('« Retirer aussi… » : jamais pour auto_en_revue, jamais à 0', () {
      expect(banReportOffersUnpublish(BanReportKind.applied, 2), isTrue);
      expect(banReportOffersUnpublish(BanReportKind.updated, 1), isTrue);
      expect(banReportOffersUnpublish(BanReportKind.applied, 0), isFalse);
      expect(banReportOffersUnpublish(BanReportKind.autoInReview, 3), isFalse);
    });
  });

  group('déban et levée', () {
    test('déban : levé (synchro des bots), déjà débannie, échec ; rien pour '
        'le ban auto et la session expirée', () {
      final lifted = channelUnbanFeedback(
        const UnbanOutcome(UnbanKind.lifted),
        name: '@exemple',
      )!;
      expect(
        lifted.message,
        'Chaîne @exemple débannie. Les bots synchroniseront la liste noire au '
        'prochain cycle.',
      );
      expect(lifted.tone, OutcomeTone.success);
      expect(lifted.totalSync, isTrue);

      final notFound = channelUnbanFeedback(
        const UnbanOutcome(UnbanKind.notFound, message: 'Profil introuvable.'),
        name: '@exemple',
      )!;
      expect(notFound.message, 'Chaîne déjà débannie.');
      expect(notFound.tone, OutcomeTone.info);
      expect(notFound.totalSync, isFalse);

      final failure = channelUnbanFeedback(
        const UnbanOutcome(UnbanKind.failure, message: 'Compte admin inactif.'),
        name: '@exemple',
      )!;
      expect(failure.message, 'Compte admin inactif.');
      expect(failure.tone, OutcomeTone.error);

      expect(
        channelUnbanFeedback(
          const UnbanOutcome(UnbanKind.autoBan, banEventId: 42),
          name: '@exemple',
        ),
        isNull,
      );
      expect(
        channelUnbanFeedback(
          const UnbanOutcome(UnbanKind.sessionExpired),
          name: '@exemple',
        ),
        isNull,
      );
    });

    test(
      'levée avec still_banned → la ligne devient manuelle (non retirée)',
      () {
        final DecisionOutcome base = outcomeFromResult(
          result: 'lifted',
          targetKind: 'channel',
          stillBanned: 'manuel',
        );
        final DecisionOutcome o = channelDecisionOutcome(
          base,
          result: 'lifted',
          stillBanned: 'manuel',
        );
        expect(o.message, kChannelLiftStillBannedMessage);
        expect(o.message, contains('la ligne devient manuelle'));
        expect(o.tone, OutcomeTone.warning);
        expect(o.reloadQueue, isTrue);
        expect(o.removeItem, isFalse);
        expect(o.offerPurge, isFalse);
      },
    );

    test('autres issues inchangées', () {
      final DecisionOutcome lifted = outcomeFromResult(
        result: 'lifted',
        targetKind: 'channel',
      );
      expect(
        identical(channelDecisionOutcome(lifted, result: 'lifted'), lifted),
        isTrue,
      );
      final DecisionOutcome confirmed = outcomeFromResult(
        result: 'confirmed',
        targetKind: 'channel',
      );
      final DecisionOutcome c = channelDecisionOutcome(
        confirmed,
        result: 'confirmed',
      );
      expect(identical(c, confirmed), isTrue);
      expect(c.offerPurge, isTrue, reason: 'purge proposée après confirmation');
      final DecisionOutcome err = outcomeFromError(
        statusCode: 403,
        message: 'Accès réservé au compte principal.',
      );
      expect(
        channelDecisionOutcome(err).message,
        'Réservé au compte principal.',
      );
    });
  });

  test('page de repli quand la page revient vide', () {
    expect(
      channelsPageFallback(page: 2, itemCount: 3, total: 23, pageSize: 10),
      isNull,
    );
    expect(
      channelsPageFallback(page: 0, itemCount: 0, total: 0, pageSize: 10),
      isNull,
    );
    expect(
      channelsPageFallback(page: 3, itemCount: 0, total: 25, pageSize: 10),
      2,
    );
    expect(
      channelsPageFallback(page: 5, itemCount: 0, total: 12, pageSize: 10),
      1,
    );
    expect(
      channelsPageFallback(page: 2, itemCount: 0, total: 0, pageSize: 10),
      0,
    );
  });
}
