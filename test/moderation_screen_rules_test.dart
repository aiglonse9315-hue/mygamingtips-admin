// Règles pures de l'écran « Modération » (P4b-3, lot L7, conception
// §6.2-§6.8) : pagination, cellules du journal et des refus (masquage, S-04),
// filtres, puces des refus, plafonds, messages des réglages, différences
// d'empreintes, purge des preuves, id de ligne pour la purge, actions d'une
// page bloquée. Aucune dépendance dart:html — exécuté en VM.
// Fixtures neutres ; caractères spéciaux construits par String.fromCharCode.

import 'package:flutter_test/flutter_test.dart';
import 'package:mgt_admin/domain/models/moderation.dart';
import 'package:mgt_admin/domain/moderation_actions.dart';
import 'package:mgt_admin/domain/moderation_screen_rules.dart';
import 'package:mgt_admin/domain/moderation_text.dart';

const String _uuid = '11111111-2222-4333-8444-555555555555';
final String _rlo = String.fromCharCode(0x202E);
final String _sha64a = 'a' * 64;
final String _sha64b = 'b' * 64;

BanEvent _event(Map<String, dynamic> extra) =>
    BanEvent.fromJson(<String, dynamic>{
      'id': 9,
      'target_kind': 'page',
      'action': 'refused',
      'origin': 'auto',
      'category': 'injection_ia',
      'actor_kind': 'detecteur',
      ...extra,
    })!;

ModerationSettings _settings(Map<String, dynamic> extra) =>
    ModerationSettings.fromJson(<String, dynamic>{
      'auto_ban_enabled': false,
      'max_auto_bans_per_hour': 3,
      'max_auto_bans_per_day': 10,
      ...extra,
    })!;

BlockedPage _page({String status = 'en_revue', int? banEventId = 4}) =>
    BlockedPage.fromJson(<String, dynamic>{
      'id': 1,
      'url': 'https://exemple.test/page',
      'status': status,
      'origin': 'auto',
      'category': 'injection_ia',
      'ban_event_id': banEventId,
    })!;

void main() {
  group('libellés fixes', () {
    test('5 onglets aux libellés exacts, dans l’ordre', () {
      expect(kModerationTabLabels, <String>[
        'File de revue',
        'Refus',
        'Réglages',
        'Pages bloquées',
        'Journal',
      ]);
      expect(kModerationTabLabels[kQueueTabIndex], 'File de revue');
      expect(kModerationTabLabels[kSettingsTabIndex], 'Réglages');
      expect(kModerationScreenTitle, 'Modération des bans automatiques');
      expect(kModerationDemoMessage, 'Mode démo : pas de connexion Supabase.');
      expect(kQueueEmptyMessage, 'File vide : aucune décision en attente.');
      expect(
        kPurgeRowNotFoundMessage,
        'Ligne de chaîne introuvable : purgez depuis Chaînes YT → Bannir.',
      );
    });
  });

  group('pagination', () {
    test('totalPages : au moins 1, arrondi supérieur', () {
      expect(totalPages(0, 50), 1);
      expect(totalPages(50, 50), 1);
      expect(totalPages(51, 50), 2);
      expect(totalPages(120, 50), 3);
      expect(totalPages(10, 0), 1);
    });

    test('« Page X / N (a–b sur T) » et forme courte', () {
      expect(
        paginationLabel(page: 0, pageSize: 50, total: 120),
        'Page 1 / 3 (1–50 sur 120)',
      );
      expect(
        paginationLabel(page: 2, pageSize: 50, total: 120),
        'Page 3 / 3 (101–120 sur 120)',
      );
      expect(
        paginationLabel(page: 0, pageSize: 50, total: 0),
        'Page 1 / 1 (0 sur 0)',
      );
      expect(
        paginationLabel(page: 1, pageSize: 100, total: 150, range: false),
        'Page 2 / 2',
      );
    });
  });

  group('cellules des événements (§6.5, §6.8)', () {
    test('clé masquée : hôte RÉVÉLÉ (U+202E → jeton) + 8 hex', () {
      final BanEvent e = _event(<String, dynamic>{
        'target_key': null,
        'target_key_masked': true,
        'target_host': 'exemple.test$_rlo',
        'target_key_sha256': 'abcdef0123456789$_sha64a'.substring(0, 64),
      });
      final String t = eventTargetText(e);
      expect(t, 'exemple.test⟦U+202E⟧ · empreinte abcdef01…');
      expect(t.contains(_rlo), isFalse);
    });

    test('clé masquée sans hôte ni empreinte', () {
      final BanEvent e = _event(<String, dynamic>{'target_key_masked': true});
      expect(eventTargetText(e), 'hôte inconnu · empreinte —');
    });

    test('compte → id court ; chaîne → clé ; clé absente → « — »', () {
      expect(
        eventTargetText(
          _event(<String, dynamic>{
            'target_kind': 'account',
            'target_key': _uuid,
          }),
        ),
        '11111111…',
      );
      expect(
        eventTargetText(
          _event(<String, dynamic>{
            'target_kind': 'channel',
            'target_key': 'UCexemple',
          }),
        ),
        'UCexemple',
      );
      expect(eventTargetText(_event(<String, dynamic>{})), '—');
    });

    test('clé de page non masquée : révélée et bornée à 60', () {
      final String long = 'https://exemple.test/${'x' * 200}';
      final String t = eventTargetText(
        _event(<String, dynamic>{'target_key': long}),
      );
      expect(t.runes.length, lessThanOrEqualTo(61));
      expect(t.endsWith('…'), isTrue);
    });

    test('libellé de cible des dialogues', () {
      expect(
        eventTargetLabel(
          _event(<String, dynamic>{
            'target_kind': 'account',
            'target_key': _uuid,
          }),
        ),
        'Compte 11111111…',
      );
      expect(
        eventTargetLabel(
          _event(<String, dynamic>{
            'target_kind': 'channel',
            'target_key': 'UCexemple',
            'platform': 'youtube',
          }),
        ),
        'YouTube · UCexemple',
      );
      expect(
        eventTargetLabel(
          _event(<String, dynamic>{
            'target_key': 'https://exemple.test/a$_rlo',
          }),
        ),
        'https://exemple.test/a⟦U+202E⟧',
      );
    });

    test('groupe, liens, acteur, motif', () {
      final BanEvent head = _event(<String, dynamic>{});
      final BanEvent member = _event(<String, dynamic>{
        'group_event_id': 3,
        'ref_event_id': 2,
        'actor_kind': 'revue',
        'actor_username': 'compte$_rlo',
        'note': 'motif\nsur deux lignes',
      });
      expect(eventGroupText(head), 'tête');
      expect(eventGroupText(member), 'membre de #3');
      expect(eventLinksText(head), '—');
      expect(eventLinksText(member), 'réf. #2 · groupe #3');
      expect(eventActorText(head), 'Détecteur');
      expect(
        eventActorText(member),
        'Revue (compte principal) · compte⟦U+202E⟧',
      );
      expect(eventNoteText(head), '—');
      expect(eventNoteText(member), 'motif⏎sur deux lignes');
    });

    test('« Détecteur seulement » masque les refus de la revue', () {
      final List<BanEvent> items = <BanEvent>[
        _event(<String, dynamic>{'id': 1}),
        _event(<String, dynamic>{'id': 2, 'actor_kind': 'revue'}),
        _event(<String, dynamic>{'id': 3}),
      ];
      expect(filterDetectorOnly(items, true).map((BanEvent e) => e.id), <int>[
        1,
        3,
      ]);
      expect(filterDetectorOnly(items, false), same(items));
    });
  });

  group('refus des 24 h', () {
    test('tri par nombre décroissant, puis libellé ; zéros ignorés', () {
      final List<RefusalCount> r = refusalCounts(<String, int>{
        'hote_ugc': 1,
        'source_non_utilisateur': 4,
        'texte_absent': 0,
        'url_invalide': 1,
      });
      expect(r.map((RefusalCount x) => x.code), <String>[
        'source_non_utilisateur',
        'hote_ugc',
        'url_invalide',
      ]);
      expect(
        refusalChipText(r.first),
        "Partage d'un bot : pas de ban de compte : 4",
      );
      expect(refusalCounts(const <String, int>{}), isEmpty);
    });

    test('code inconnu : libellé de repli', () {
      final List<RefusalCount> r = refusalCounts(<String, int>{'xyz': 2});
      expect(refusalChipText(r.single), 'Raison inconnue (xyz) : 2');
    });
  });

  group('filtres du journal (§6.8)', () {
    test('clé exacte : coupée, UUID en minuscules, vide → null (C-12)', () {
      expect(normalizeEventKeyFilter('   '), isNull);
      expect(normalizeEventKeyFilter(''), isNull);
      expect(normalizeEventKeyFilter('  ${_uuid.toUpperCase()} '), _uuid);
      expect(normalizeEventKeyFilter(' UCExemple '), 'UCExemple');
    });

    test('choix : Tous + 3 cibles ; Toutes + 9 actions', () {
      expect(kEventTargetKindChoices.first, (null, 'Tous'));
      expect(kEventTargetKindChoices.length, 4);
      final List<(String?, String)> a = eventActionChoices();
      expect(a.first, (null, 'Toutes'));
      expect(a.length, 10);
      expect(a.map(((String?, String) x) => x.$1), contains('lift'));
    });
  });

  group('réglages (§6.6)', () {
    test('pastilles et sous-titres de l’interrupteur', () {
      expect(autoBanPillLabel(true), 'Ban automatique : allumé');
      expect(autoBanPillLabel(false), 'Ban automatique : éteint');
      expect(queueSizePillLabel(4), 'File : 4');
      expect(autoBanSubtitle(false), startsWith('Éteint : '));
      expect(autoBanSubtitle(true), startsWith('Allumé : '));
    });

    test('texte « Allumer » avec les plafonds', () {
      final String t = turnOnText(maxPerHour: 3, maxPerDay: 10);
      expect(t, contains('dans la limite de 3/heure et 10/jour.'));
      expect(t, contains('SANS intervention humaine'));
    });

    test('disjoncteur : encart avec et sans événement, réarmement', () {
      expect(
        breakerBoxText(
          date: '28/09/2026 10:15',
          reason: 'plafond_heure',
          eventId: 42,
        ),
        'Disjoncteur déclenché le 28/09/2026 10:15 : plafond horaire atteint '
        '(événement #42). Le ban automatique a été coupé.',
      );
      expect(
        breakerBoxText(date: 'd', reason: 'plafond_jour'),
        'Disjoncteur déclenché le d : plafond journalier atteint. '
        'Le ban automatique a été coupé.',
      );
      expect(
        rearmText(date: 'd', reason: 'plafond_heure'),
        startsWith('Disjoncteur déclenché le d : plafond horaire atteint.'),
      );
      expect(viewEventLabel(42), "Voir l'événement #42");
    });

    test('compteurs, seuil des chaînes, dernière modification', () {
      final ModerationSettings s = _settings(<String, dynamic>{
        'auto_bans_last_hour': 1,
        'auto_bans_last_day': 2,
        'chain_threshold': 2,
        'chain_window_days': 90,
      });
      expect(
        settingsCountersText(s),
        "Bans automatiques : 1 dans l'heure (plafond 3), 2 sur 24 h "
        '(plafond 10)',
      );
      expect(
        chainThresholdText(s),
        'Seuil des chaînes : 2 contenus distincts sur 90 jours',
      );
      expect(updatedByText('disjoncteur'), 'le disjoncteur');
      expect(updatedByText(null), '—');
      expect(updatedByText('compte$_rlo'), 'compte⟦U+202E⟧');
      expect(
        lastModifiedText(date: 'd', by: 'disjoncteur'),
        'Dernière modification : d par le disjoncteur',
      );
    });

    test('erreur 400 : champs traduits seulement si la liste est non vide', () {
      expect(
        settingsErrorText('max_auto_bans_per_hour : 0 à 100.', const []),
        'max_auto_bans_per_hour : 0 à 100.',
      );
      expect(
        settingsErrorText('Réglages invalides.', <String>[
          'max_auto_bans_per_hour',
          'zzz',
        ]),
        'Réglages invalides. (Plafond par heure, zzz)',
      );
    });
  });

  group('plafonds', () {
    test('parseCeiling : bornes, format', () {
      expect(parseCeiling('0', max: 100).value, 0);
      expect(parseCeiling(' 100 ', max: 100).value, 100);
      expect(parseCeiling('101', max: 100).error, 'Entier de 0 à 100 attendu.');
      expect(parseCeiling('', max: 100).value, isNull);
      expect(parseCeiling('-1', max: 100).value, isNull);
      expect(parseCeiling('1.5', max: 1000).value, isNull);
      expect(parseCeiling('1000', max: 1000).value, 1000);
    });

    test('avertissement sous un plafond à 0', () {
      expect(ceilingWarning('0'), kCeilingZeroWarning);
      expect(ceilingWarning('3'), isNull);
      expect(ceilingWarning('x'), isNull);
    });

    test('confirmation de hausse', () {
      final List<String> incs = ceilingIncreases(
        oldHour: 3,
        oldDay: 10,
        newHour: 100,
        newDay: 10,
      );
      expect(
        ceilingIncreaseText(incs),
        'par heure : 3 → 100. Plus de bans automatiques pourront être posés '
        'sans vous avant que le disjoncteur ne coupe.',
      );
    });
  });

  group('empreintes autorisées', () {
    test('sameRulesList : ordre, casse et espaces ignorés', () {
      expect(
        sameRulesList(
          <String>[_sha64a, _sha64b],
          <String>[' ${_sha64b.toUpperCase()}', _sha64a],
        ),
        isTrue,
      );
      expect(sameRulesList(<String>[_sha64a], <String>[_sha64b]), isFalse);
      expect(sameRulesList(const <String>[], const <String>[]), isTrue);
      expect(sameRulesList(<String>[_sha64a], const <String>[]), isFalse);
    });

    test('différences : ajoutées / retirées, 8 hex', () {
      expect(rulesDiffLines(<String>[_sha64a], <String>[_sha64b]), <String>[
        '1 ajoutée(s) :',
        '+ bbbbbbbb…',
        '1 retirée(s) :',
        '− aaaaaaaa…',
      ]);
      expect(rulesDiffLines(<String>[_sha64a], const <String>[]), <String>[
        kRulesEmptyListWarning,
        '1 retirée(s) :',
        '− aaaaaaaa…',
      ]);
      expect(rulesCounterText(3), '3/50');
      expect(shortSha('abc'), 'abc');
    });
  });

  group('preuves anciennes', () {
    test('aperçu, bouton, confirmation, bilan et rejeu à 0 (UX-02)', () {
      expect(
        evidencePreviewText(4),
        '4 preuve(s) seraient supprimées (les éléments encore dans la file '
        "sont exclus ; le nombre peut changer à l'application).",
      );
      expect(evidencePurgeButtonLabel(4), 'Purger 4 preuve(s)');
      expect(
        evidencePurgeConfirmTitle(4),
        'Supprimer définitivement 4 preuve(s) ?',
      );
      expect(
        evidencePurgedText(
          const EvidencePurgeResult(result: 'purged', count: 4),
        ),
        '4 preuve(s) supprimée(s).',
      );
      expect(
        evidencePurgedText(
          const EvidencePurgeResult(result: 'purged', count: 0, replayed: true),
        ),
        kReplayNoticeMessage,
      );
    });
  });

  group('purge d’une chaîne après décision (§6.4 e)', () {
    test('channel_row_id seulement pour une confirmation', () {
      expect(purgeRowIdFromItem(decision: 'confirm', channelRowId: 12), 12);
      expect(purgeRowIdFromItem(decision: 'confirm'), isNull);
      expect(purgeRowIdFromItem(decision: 'confirm', channelRowId: 0), isNull);
      expect(purgeRowIdFromItem(decision: 'apply', channelRowId: 12), isNull);
    });
  });

  group('pages bloquées (§6.7)', () {
    test('actions selon le statut ; sans événement → aucune', () {
      expect(blockedPageActions(_page(), isOwner: true), <ReviewAction>[
        ReviewAction.detail,
        ReviewAction.confirm,
        ReviewAction.lift,
      ]);
      expect(
        blockedPageActions(_page(status: 'confirme'), isOwner: true),
        <ReviewAction>[ReviewAction.detail, ReviewAction.lift],
      );
      expect(
        blockedPageActions(_page(banEventId: null), isOwner: true),
        isEmpty,
      );
      expect(blockedPageActions(_page(), isOwner: false), isEmpty);
    });

    test('aide de l’onglet', () {
      expect(
        kBlockedPagesHelp,
        'Pages bloquées par le ban automatique (URL exacte, jamais un site '
        "entier). Aucun blocage manuel n'existe.",
      );
      // L'URL affichée en cellule est révélée (aucun caractère caché).
      expect(
        oneLinePreview('https://exemple.test/$_rlo').contains(_rlo),
        isFalse,
      );
    });
  });
}
