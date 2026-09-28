// Tests purs (VM) des boutons et résultats de la modération (P4b-3, lot L3,
// conception §4.5) : actions par élément de file / ban auto actif / focus,
// traduction de review-decide (une assertion par ligne de la table §4.5),
// débans, bilan d'un lot, purge d'une chaîne, rejeu, pagination, plafonds,
// disjoncteur, empreintes ; plus le résultat commun des écritures
// (write_outcome.dart, §5).

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/moderation_actions.dart';
import 'package:mgt_admin/domain/write_outcome.dart';

const ReviewAction detail = ReviewAction.detail;
const ReviewAction confirm = ReviewAction.confirm;
const ReviewAction lift = ReviewAction.lift;
const ReviewAction apply = ReviewAction.apply;
const ReviewAction dismiss = ReviewAction.dismiss;
const ReviewAction purge = ReviewAction.purge;

const String replayMsg =
    "Réponse initiale perdue : l'opération a probablement déjà été faite au premier essai. "
    'État relu.';

/// Vérifie une ligne de la table §4.5.
void expectOutcome(
  DecisionOutcome o, {
  required OutcomeTone tone,
  required String message,
  required bool reload,
  required bool remove,
  bool offerPurge = false,
  bool uncertain = false,
}) {
  expect(o.tone, tone, reason: message);
  expect(o.message, message);
  expect(o.reloadQueue, reload, reason: message);
  expect(o.removeItem, remove, reason: message);
  expect(o.offerPurge, offerPurge, reason: message);
  expect(o.uncertain, uncertain, reason: message);
}

void main() {
  group('boutons', () {
    test('actionsForQueueItem : 3 types + inconnu', () {
      expect(actionsForQueueItem('ban_en_revue'), <ReviewAction>[
        detail,
        confirm,
        lift,
      ]);
      expect(actionsForQueueItem('a_examiner'), <ReviewAction>[
        detail,
        apply,
        dismiss,
      ]);
      expect(actionsForQueueItem('refus_a_revoir'), <ReviewAction>[
        detail,
        apply,
        dismiss,
      ]);
      expect(actionsForQueueItem('autre'), <ReviewAction>[detail]);
      expect(actionsForQueueItem(''), <ReviewAction>[detail]);
    });

    test(
      'actionsForActiveAutoBan : en revue, confirmé (purge pour une chaîne), manuel, non owner',
      () {
        expect(
          actionsForActiveAutoBan(
            status: 'en_revue',
            targetKind: 'account',
            isOwner: true,
          ),
          <ReviewAction>[detail, confirm, lift],
        );
        expect(
          actionsForActiveAutoBan(
            status: 'en_revue',
            targetKind: 'channel',
            isOwner: true,
          ),
          <ReviewAction>[detail, confirm, lift],
        );
        expect(
          actionsForActiveAutoBan(
            status: 'confirme',
            targetKind: 'account',
            isOwner: true,
          ),
          <ReviewAction>[detail, lift],
        );
        expect(
          actionsForActiveAutoBan(
            status: 'confirme',
            targetKind: 'page',
            isOwner: true,
          ),
          <ReviewAction>[detail, lift],
        );
        expect(
          actionsForActiveAutoBan(
            status: 'confirme',
            targetKind: 'channel',
            isOwner: true,
          ),
          <ReviewAction>[detail, lift, purge],
        );
        expect(
          actionsForActiveAutoBan(
            status: 'manuel',
            targetKind: 'account',
            isOwner: true,
          ),
          isEmpty,
        );
        expect(
          actionsForActiveAutoBan(
            status: 'en_revue',
            targetKind: 'channel',
            isOwner: false,
          ),
          isEmpty,
        );
        expect(
          actionsForActiveAutoBan(
            status: 'confirme',
            targetKind: 'channel',
            isOwner: false,
          ),
          isEmpty,
        );
      },
    );

    test('unbanPathFor', () {
      expect(
        unbanPathFor(origin: 'manual', isOwner: true),
        UnbanPath.confirmManual,
      );
      expect(
        unbanPathFor(origin: 'manual', isOwner: false),
        UnbanPath.confirmManual,
      );
      expect(unbanPathFor(origin: 'auto', isOwner: true), UnbanPath.liftAuto);
      expect(
        unbanPathFor(origin: 'auto', isOwner: false),
        UnbanPath.autoReservedToOwner,
      );
    });

    test('actionsForFocus : statut en revue / confirmé / inconnu', () {
      expect(
        actionsForFocus(
          const ModerationFocus(
            eventId: 7,
            status: 'en_revue',
            targetKind: 'account',
          ),
          isOwner: true,
        ),
        <ReviewAction>[detail, confirm, lift],
      );
      expect(
        actionsForFocus(
          const ModerationFocus(
            eventId: 7,
            status: 'confirme',
            targetKind: 'channel',
          ),
          isOwner: true,
        ),
        <ReviewAction>[detail, lift, purge],
      );
      expect(
        actionsForFocus(const ModerationFocus(eventId: 7), isOwner: true),
        <ReviewAction>[detail],
      );
      expect(
        actionsForFocus(
          const ModerationFocus(eventId: 7, targetKind: 'channel'),
          isOwner: true,
        ),
        <ReviewAction>[detail],
      );
    });

    test('ModerationFocus : égalité par valeur', () {
      expect(
        const ModerationFocus(eventId: 1, status: 'en_revue'),
        const ModerationFocus(eventId: 1, status: 'en_revue'),
      );
      expect(
        const ModerationFocus(eventId: 1) == const ModerationFocus(eventId: 2),
        isFalse,
      );
    });

    test('purgeLookupEventId', () {
      expect(purgeLookupEventId('confirm', itemId: 5, resultEventId: 9), 5);
      expect(purgeLookupEventId('apply', itemId: 5, resultEventId: 9), 9);
      expect(purgeLookupEventId('apply', itemId: 5), isNull);
      expect(purgeLookupEventId('lift', itemId: 5, resultEventId: 9), isNull);
    });

    test('pageAfterRemoval', () {
      // Page vidée non première → page précédente.
      expect(
        pageAfterRemoval(page: 2, itemsLeftOnPage: 0, total: 100, pageSize: 50),
        1,
      );
      // Première page vidée → reste 0.
      expect(
        pageAfterRemoval(page: 0, itemsLeftOnPage: 0, total: 0, pageSize: 50),
        0,
      );
      // Page non vide → inchangée.
      expect(
        pageAfterRemoval(page: 3, itemsLeftOnPage: 4, total: 154, pageSize: 50),
        3,
      );
      // Jamais au-delà de la dernière page d'après le total.
      expect(
        pageAfterRemoval(page: 5, itemsLeftOnPage: 0, total: 60, pageSize: 50),
        1,
      );
      expect(
        pageAfterRemoval(page: 3, itemsLeftOnPage: 0, total: 0, pageSize: 50),
        0,
      );
    });
  });

  group('outcomeFromResult (table §4.5)', () {
    test('confirmed : purge proposée pour une chaîne seulement', () {
      expectOutcome(
        outcomeFromResult(result: 'confirmed', targetKind: 'channel'),
        tone: OutcomeTone.success,
        message: 'Bannissement confirmé.',
        reload: true,
        remove: true,
        offerPurge: true,
      );
      expectOutcome(
        outcomeFromResult(result: 'confirmed', targetKind: 'account'),
        tone: OutcomeTone.success,
        message: 'Bannissement confirmé.',
        reload: true,
        remove: true,
      );
    });

    test('already_confirmed (+ rejeu → message de rejeu)', () {
      expectOutcome(
        outcomeFromResult(result: 'already_confirmed', targetKind: 'channel'),
        tone: OutcomeTone.success,
        message: 'Déjà confirmé.',
        reload: true,
        remove: true,
        offerPurge: true,
      );
      expectOutcome(
        outcomeFromResult(result: 'already_confirmed', targetKind: 'account'),
        tone: OutcomeTone.success,
        message: 'Déjà confirmé.',
        reload: true,
        remove: true,
      );
      expectOutcome(
        outcomeFromResult(
          result: 'already_confirmed',
          targetKind: 'channel',
          replayed: true,
        ),
        tone: OutcomeTone.info,
        message: replayMsg,
        reload: true,
        remove: true,
        offerPurge: true,
      );
    });

    test('lifted sans / avec ban manuel restant', () {
      expectOutcome(
        outcomeFromResult(result: 'lifted', targetKind: 'account'),
        tone: OutcomeTone.success,
        message:
            'Bannissement levé. Les partages antérieurs sont exemptés du ban automatique.',
        reload: true,
        remove: true,
      );
      expectOutcome(
        outcomeFromResult(
          result: 'lifted',
          targetKind: 'account',
          stillBanned: 'manuel',
        ),
        tone: OutcomeTone.warning,
        message: 'Ban automatique levé ; le ban MANUEL reste en vigueur.',
        reload: true,
        remove: true,
      );
    });

    test('already_lifted', () {
      expectOutcome(
        outcomeFromResult(result: 'already_lifted'),
        tone: OutcomeTone.success,
        message: 'Déjà levé.',
        reload: true,
        remove: true,
      );
      expectOutcome(
        outcomeFromResult(result: 'already_lifted', replayed: true),
        tone: OutcomeTone.info,
        message: replayMsg,
        reload: true,
        remove: true,
      );
    });

    test('applied : purge proposée pour une chaîne seulement', () {
      expectOutcome(
        outcomeFromResult(result: 'applied', targetKind: 'channel'),
        tone: OutcomeTone.success,
        message: 'Bannissement appliqué (statut confirmé).',
        reload: true,
        remove: true,
        offerPurge: true,
      );
      expectOutcome(
        outcomeFromResult(result: 'applied', targetKind: 'page'),
        tone: OutcomeTone.success,
        message: 'Bannissement appliqué (statut confirmé).',
        reload: true,
        remove: true,
      );
    });

    test('already_banned', () {
      expectOutcome(
        outcomeFromResult(result: 'already_banned', targetKind: 'channel'),
        tone: OutcomeTone.info,
        message: 'Cible déjà bannie : demande close.',
        reload: true,
        remove: true,
      );
      expectOutcome(
        outcomeFromResult(result: 'already_banned', replayed: true),
        tone: OutcomeTone.info,
        message: replayMsg,
        reload: true,
        remove: true,
      );
    });

    test('refused + profil_absent / exempte_apres_levee', () {
      expectOutcome(
        outcomeFromResult(
          result: 'refused',
          reasons: const <String>['profil_absent'],
        ),
        tone: OutcomeTone.info,
        message: 'Rien appliqué : profil supprimé. Demande close.',
        reload: true,
        remove: true,
      );
      expectOutcome(
        outcomeFromResult(
          result: 'refused',
          reasons: const <String>['exempte_apres_levee'],
        ),
        tone: OutcomeTone.info,
        message:
            "Rien appliqué : partage antérieur à une levée ou une mise à l'écart. Demande close.",
        reload: true,
        remove: true,
      );
      // Raison non prévue : libellé lisible (repli).
      expectOutcome(
        outcomeFromResult(result: 'refused', reasons: const <String>['xyz']),
        tone: OutcomeTone.info,
        message: 'Rien appliqué : Raison inconnue (xyz). Demande close.',
        reload: true,
        remove: true,
      );
    });

    test('dismissed (N = group_size ?? 1)', () {
      expectOutcome(
        outcomeFromResult(result: 'dismissed', groupSize: 3),
        tone: OutcomeTone.success,
        message:
            'Demande écartée (3 événement(s) du groupe). Partages antérieurs exemptés.',
        reload: true,
        remove: true,
      );
      expect(
        outcomeFromResult(result: 'dismissed').message,
        'Demande écartée (1 événement(s) du groupe). Partages antérieurs exemptés.',
      );
    });

    test('already_resolved', () {
      expectOutcome(
        outcomeFromResult(result: 'already_resolved', previous: 'dismiss'),
        tone: OutcomeTone.info,
        message: 'Déjà traitée (précédemment : écartée).',
        reload: true,
        remove: true,
      );
      expect(
        outcomeFromResult(
          result: 'already_resolved',
          previous: 'already_banned',
        ).message,
        'Déjà traitée (précédemment : close (déjà banni)).',
      );
      expect(
        outcomeFromResult(result: 'already_resolved', replayed: true).message,
        replayMsg,
      );
    });

    test('autre résultat 200', () {
      expectOutcome(
        outcomeFromResult(result: 'quelque_chose'),
        tone: OutcomeTone.warning,
        message: 'Résultat inattendu : quelque_chose. État relu.',
        reload: true,
        remove: false,
      );
    });

    test('résultat normal reçu après un rejeu : message inchangé', () {
      expectOutcome(
        outcomeFromResult(
          result: 'confirmed',
          targetKind: 'channel',
          replayed: true,
        ),
        tone: OutcomeTone.success,
        message: 'Bannissement confirmé.',
        reload: true,
        remove: true,
        offerPurge: true,
      );
    });
  });

  group('outcomeFromError (table §4.5)', () {
    test('409 not_applicable', () {
      expectOutcome(
        outcomeFromError(
          statusCode: 409,
          result: 'not_applicable',
          message: 'serveur',
        ),
        tone: OutcomeTone.warning,
        message: "Décision non applicable à cet élément : l'état a changé.",
        reload: true,
        remove: false,
      );
    });

    test('409 ban_not_active', () {
      expectOutcome(
        outcomeFromError(
          statusCode: 409,
          result: 'ban_not_active',
          message: 'serveur',
        ),
        tone: OutcomeTone.warning,
        message: "Ce bannissement n'est plus actif.",
        reload: true,
        remove: true,
      );
    });

    test('409 below_threshold', () {
      expectOutcome(
        outcomeFromError(
          statusCode: 409,
          result: 'below_threshold',
          distinctContents: 1,
          threshold: 2,
          message: 'serveur',
        ),
        tone: OutcomeTone.warning,
        message:
            'Seuil non atteint : 1/2 contenus distincts de cette chaîne sur 90 jours. Rien '
            "n'a été appliqué ; la demande reste dans la file (vous pouvez l'écarter).",
        reload: false,
        remove: false,
      );
      expect(
        outcomeFromError(
          statusCode: 409,
          result: 'below_threshold',
          message: 'x',
        ).message,
        startsWith('Seuil non atteint : 0/2 contenus'),
      );
    });

    test('409 sans code connu → message du serveur, état relu', () {
      expectOutcome(
        outcomeFromError(statusCode: 409, message: 'Conflit.'),
        tone: OutcomeTone.warning,
        message: 'Conflit.',
        reload: true,
        remove: false,
      );
    });

    test('404', () {
      expectOutcome(
        outcomeFromError(statusCode: 404, result: 'not_found', message: 'x'),
        tone: OutcomeTone.warning,
        message: 'Événement introuvable.',
        reload: true,
        remove: true,
      );
    });

    test('403', () {
      expectOutcome(
        outcomeFromError(statusCode: 403, message: 'x'),
        tone: OutcomeTone.error,
        message: 'Réservé au compte principal.',
        reload: false,
        remove: false,
      );
    });

    test('400 → message du serveur', () {
      expectOutcome(
        outcomeFromError(
          statusCode: 400,
          message: 'reason trop long (500 max).',
        ),
        tone: OutcomeTone.error,
        message: 'reason trop long (500 max).',
        reload: false,
        remove: false,
      );
    });

    test('incertain → état relu, prioritaire sur le statut', () {
      const String msg =
          "Réponse du serveur non reçue : l'état a été relu, vérifiez le résultat.";
      expectOutcome(
        outcomeFromError(statusCode: null, message: 'x', uncertain: true),
        tone: OutcomeTone.warning,
        message: msg,
        reload: true,
        remove: false,
        uncertain: true,
      );
      expectOutcome(
        outcomeFromError(statusCode: 502, message: 'x', uncertain: true),
        tone: OutcomeTone.warning,
        message: msg,
        reload: true,
        remove: false,
        uncertain: true,
      );
    });
  });

  group('débans', () {
    test('unbanOutcomeFromResult', () {
      expect(unbanOutcomeFromResult('lifted').kind, UnbanKind.lifted);
      expect(unbanOutcomeFromResult('not_banned').kind, UnbanKind.notBanned);
      expect(unbanOutcomeFromResult('not_found').kind, UnbanKind.notFound);
      final UnbanOutcome odd = unbanOutcomeFromResult('bizarre');
      expect(odd.kind, UnbanKind.failure);
      expect(odd.message, 'Résultat inattendu : bizarre.');
    });

    test('rejeu (INF-01) : « n’était plus banni » → message de rejeu ; une '
        'levée reste une levée', () {
      final UnbanOutcome replayed = unbanOutcomeFromResult(
        'not_banned',
        replayed: true,
      );
      expect(replayed.kind, UnbanKind.notBanned);
      expect(
        unbanMessage(replayed, name: 'Joueur', channel: false),
        kReplayNoticeMessage,
      );
      expect(
        unbanMessage(
          unbanOutcomeFromResult('not_banned'),
          name: 'Joueur',
          channel: false,
        ),
        "Joueur n'était plus banni.",
      );
      expect(
        unbanMessage(
          unbanOutcomeFromResult('lifted', replayed: true),
          name: 'Joueur',
          channel: false,
        ),
        'Joueur débanni.',
      );
    });

    test('unbanOutcomeFromError : 409 → autoBan(42), 404, autre', () {
      final UnbanOutcome auto = unbanOutcomeFromError(
        statusCode: 409,
        result: 'auto_ban_use_review',
        banEventId: 42,
        message: 'x',
      );
      expect(auto.kind, UnbanKind.autoBan);
      expect(auto.banEventId, 42);
      final UnbanOutcome nf = unbanOutcomeFromError(
        statusCode: 404,
        message: 'x',
      );
      expect(nf.kind, UnbanKind.notFound);
      expect(nf.message, 'Profil introuvable.');
      final UnbanOutcome other = unbanOutcomeFromError(
        statusCode: 409,
        result: 'autre',
        message: 'Conflit.',
      );
      expect(other.kind, UnbanKind.failure);
      expect(other.message, 'Conflit.');
      expect(
        unbanOutcomeFromError(statusCode: 500, message: 'Erreur.').kind,
        UnbanKind.failure,
      );
    });

    test('unbanMessage', () {
      expect(
        unbanMessage(
          const UnbanOutcome(UnbanKind.lifted),
          name: 'Alice',
          channel: false,
        ),
        'Alice débanni.',
      );
      expect(
        unbanMessage(
          const UnbanOutcome(UnbanKind.lifted),
          name: '@abc',
          channel: true,
        ),
        'Chaîne @abc débannie.',
      );
      expect(
        unbanMessage(
          const UnbanOutcome(UnbanKind.notBanned),
          name: 'Alice',
          channel: false,
        ),
        "Alice n'était plus banni.",
      );
      expect(
        unbanMessage(
          const UnbanOutcome(UnbanKind.notFound),
          name: '@abc',
          channel: true,
        ),
        'Chaîne déjà débannie.',
      );
      expect(
        unbanMessage(
          unbanOutcomeFromError(statusCode: 404, message: 'x'),
          name: 'A',
          channel: false,
        ),
        'Profil introuvable.',
      );
      expect(
        unbanMessage(
          const UnbanOutcome(UnbanKind.autoBan, banEventId: 3),
          name: 'A',
          channel: false,
        ),
        'Bannissement automatique : levée réservée au compte principal (menu Modération).',
      );
      expect(
        unbanMessage(
          const UnbanOutcome(UnbanKind.failure, message: 'Erreur.'),
          name: 'A',
          channel: false,
        ),
        'Erreur.',
      );
    });
  });

  group('lot de bans, purge', () {
    test('banBatchSummary', () {
      const BanBatchReport r = BanBatchReport(
        applied: 3,
        alreadyBanned: 1,
        errors: <({String id, String message})>[
          (id: 'a', message: 'Profil introuvable.'),
          (id: 'b', message: 'Erreur serveur (HTTP 502).'),
        ],
      );
      expect(
        banBatchSummary(r),
        '3 compte(s) banni(s), 1 déjà banni(s), 2 erreur(s).',
      );
      expect(r.stoppedBySession, isFalse);
      expect(
        const BanBatchReport(stoppedBySession: true).stoppedBySession,
        isTrue,
      );
      expect(
        banBatchSummary(const BanBatchReport()),
        '0 compte(s) banni(s), 0 déjà banni(s), 0 erreur(s).',
      );
    });

    test('purgePreviewText', () {
      expect(
        purgePreviewText(5, 3, 2, 4),
        '5 suggestion(s) en attente seront rejetées (motif « Chaîne bannie ») : 3 trouvée(s) '
        'par détection, 2 par identifiant de chaîne. 4 contenu(s) déjà publié(s) (liste '
        'ci-dessous ; retrait manuel).',
      );
      expect(
        purgePreviewText(5, null, null, 0),
        '5 suggestion(s) en attente seront rejetées (motif « Chaîne bannie »). '
        'Aucun contenu déjà publié.',
      );
      expect(
        purgePreviewText(0, 0, 0, 0),
        'Aucune suggestion en attente à rejeter. Aucun contenu déjà publié.',
      );
    });

    test('purgeResultText', () {
      expect(
        purgeResultText(4, 5),
        '4 suggestion(s) rejetée(s) sur 5 en attente.',
      );
    });

    test('replayNotice', () {
      expect(replayNotice(replayed: true, result: 'already_banned'), replayMsg);
      expect(replayNotice(replayed: true, count: 0), replayMsg);
      expect(replayNotice(replayed: true, count: 3), isNull);
      expect(replayNotice(replayed: true, result: 'purged', count: 3), isNull);
      expect(replayNotice(replayed: false, result: 'already_banned'), isNull);
      expect(replayNotice(replayed: false, count: 0), isNull);
    });
  });

  group('réglages', () {
    test('ceilingsPatch : seulement les plafonds modifiés', () {
      expect(
        ceilingsPatch(oldHour: 3, oldDay: 10, newHour: 3, newDay: 10),
        isEmpty,
      );
      expect(
        ceilingsPatch(oldHour: 3, oldDay: 10, newHour: 5, newDay: 10),
        <String, int>{'max_auto_bans_per_hour': 5},
      );
      expect(
        ceilingsPatch(oldHour: 3, oldDay: 10, newHour: 3, newDay: 0),
        <String, int>{'max_auto_bans_per_day': 0},
      );
      expect(
        ceilingsPatch(oldHour: 3, oldDay: 10, newHour: 4, newDay: 20),
        <String, int>{'max_auto_bans_per_hour': 4, 'max_auto_bans_per_day': 20},
      );
    });

    test('ceilingIncreases : baisse seule → aucune hausse ; 3 → 100', () {
      expect(
        ceilingIncreases(oldHour: 3, oldDay: 10, newHour: 3, newDay: 10),
        isEmpty,
      );
      expect(
        ceilingIncreases(oldHour: 3, oldDay: 10, newHour: 1, newDay: 5),
        isEmpty,
      );
      expect(
        ceilingIncreases(oldHour: 3, oldDay: 10, newHour: 100, newDay: 10),
        <String>['par heure : 3 → 100'],
      );
      expect(
        ceilingIncreases(oldHour: 3, oldDay: 10, newHour: 2, newDay: 50),
        <String>['par jour : 10 → 50'],
      );
    });

    test('rearmWarning', () {
      const String warn =
          'Un plafond est déjà atteint : le disjoncteur se redéclenchera au prochain ban '
          "éligible. Relevez d'abord le plafond.";
      final ({String counters, String? warning}) full = rearmWarning(
        hour: 3,
        maxHour: 3,
        day: 7,
        maxDay: 10,
      );
      expect(full.counters, '3/3 (1 h) · 7/10 (24 h)');
      expect(full.warning, warn);
      expect(
        rearmWarning(hour: 2, maxHour: 3, day: 7, maxDay: 10).warning,
        isNull,
      );
      expect(
        rearmWarning(hour: 0, maxHour: 0, day: 0, maxDay: 0).warning,
        warn,
      );
      expect(
        rearmWarning(hour: 1, maxHour: 3, day: 10, maxDay: 10).warning,
        warn,
      );
    });

    test('rulesDiff', () {
      final ({List<String> added, List<String> removed}) d = rulesDiff(
        <String>['b', 'a', 'c'],
        <String>['c', 'e', 'd', 'b'],
      );
      expect(d.added, <String>['d', 'e']);
      expect(d.removed, <String>['a']);
      final ({List<String> added, List<String> removed}) same = rulesDiff(
        <String>['a'],
        <String>['a'],
      );
      expect(same.added, isEmpty);
      expect(same.removed, isEmpty);
    });
  });

  group('WriteOutcome', () {
    test('ok, failed, sessionExpired', () {
      const WriteOutcome ok = WriteOutcome.ok();
      expect(ok.ok, isTrue);
      expect(ok.message, isNull);
      expect(ok.notice, isNull);
      expect(ok.sessionExpired, isFalse);
      expect(
        const WriteOutcome.ok(notice: 'Déjà banni.').notice,
        'Déjà banni.',
      );

      const WriteOutcome ko = WriteOutcome.failed('Profil introuvable.');
      expect(ko.ok, isFalse);
      expect(ko.message, 'Profil introuvable.');
      expect(ko.uncertain, isFalse);
      expect(ko.sessionExpired, isFalse);
      expect(const WriteOutcome.failed('x', uncertain: true).uncertain, isTrue);

      const WriteOutcome expired = WriteOutcome.sessionExpired();
      expect(expired.ok, isFalse);
      expect(expired.sessionExpired, isTrue);
      expect(expired.message, isNull);
    });
  });
}
