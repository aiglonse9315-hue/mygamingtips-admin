// Tests purs (VM) des libellés de la modération (P4b-3, lot L3, conception
// §4.4) : 61 codes de raison, tables des types, cibles, actions, acteurs,
// statuts, plateformes, disjoncteur, champs, décisions antérieures, jeux
// ignorés, niveaux ; replis pour un code inconnu ou absent. La parité avec
// la migration 0094 est vérifiée par
// supabase/tests/parity/panel_labels_parity_test.ts.

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/moderation_labels.dart';

/// Les 61 codes de la conception §4.4 (51 `array_append` + 10 littéraux).
const List<String> _expectedCodes = <String>[
  'action_introuvable',
  'action_incoherente',
  'action_non_eligible',
  'plusieurs_bans_eligibles',
  'fondement_absent',
  'fondement_invalide',
  'statut_non_pending',
  'source_incoherente',
  'url_invalide',
  'plateforme_incoherente',
  'texte_absent',
  'texte_trop_long',
  'oracle_present',
  'version_detecteur_refusee',
  'empreinte_incoherente',
  'empreinte_non_reconnue_client',
  'bans_suspendus',
  'etat_regles_refuse',
  'regle_reponse',
  'id_regle_inconnu',
  'detections_absentes',
  'fondement_non_bannissable',
  'fondement_sans_consigne_ou_cible',
  'demande_hors_bornes',
  'source_non_utilisateur',
  'auteur_absent',
  'auteur_incoherent',
  'titre_non_lu',
  'texte_page_partiel',
  'langue_differente',
  'langue_contenu_inconnue',
  'fondement_hors_texte_partage',
  'plateforme_non_video',
  'cle_chaine_invalide',
  'contenu_id_absent',
  'contenu_id_ambigu',
  'contenu_id_incoherent',
  'fondement_hors_createur',
  'plateforme_non_web',
  'cle_page_invalide',
  'hote_ugc',
  'fondement_hors_titre_page',
  'analyse_non_marquee',
  'empreinte_non_autorisee',
  'empreinte_brute_differente',
  'detection_createur_site',
  'detection_utilisateur',
  'page_avec_requete',
  'page_hote_different',
  'page_publiee',
  'hote_avec_contenus',
  'auto_ban_desactive',
  'disjoncteur_declenche',
  'plafond_heure',
  'plafond_jour',
  'exempte_apres_levee',
  'profil_absent',
  'role_refuse',
  'acteur_inactif',
  'categorie_non_auto',
  'action_inconnue',
];

void main() {
  group('raisons', () {
    test('61 codes, exactement ceux de la conception', () {
      expect(_expectedCodes.toSet().length, 61);
      expect(kReasonLabels.length, 61);
      expect(kReasonLabels.keys.toSet(), _expectedCodes.toSet());
    });

    test('chaque libellé est non vide et distinct de son code', () {
      for (final MapEntry<String, String> e in kReasonLabels.entries) {
        expect(e.value.trim(), isNotEmpty, reason: e.key);
        expect(e.value, isNot(e.key), reason: e.key);
        expect(reasonLabel(e.key), e.value);
      }
    });

    test('libellés choisis (conception §4.4)', () {
      expect(
        reasonLabel('hote_ugc'),
        "Site de contenus d'utilisateurs (jamais bloqué)",
      );
      expect(
        reasonLabel('texte_trop_long'),
        'Texte partagé trop long (plus de 20 000 caractères)',
      );
      expect(
        reasonLabel('exempte_apres_levee'),
        "Partage antérieur à une levée ou une mise à l'écart",
      );
      expect(reasonLabel('profil_absent'), 'Profil supprimé');
      expect(reasonLabel('plafond_heure'), 'Plafond horaire atteint');
    });

    test('code inconnu → « Raison inconnue (xyz) » ; absent → « — »', () {
      expect(reasonLabel('xyz'), 'Raison inconnue (xyz)');
      expect(reasonLabel(null), '—');
      expect(reasonLabel(''), '—');
    });

    test('reasonLabels garde l’ordre reçu', () {
      expect(reasonLabels(<String>['plafond_jour', 'xyz']), <String>[
        'Plafond journalier atteint',
        'Raison inconnue (xyz)',
      ]);
    });
  });

  group('autres tables', () {
    test('types de la file', () {
      expect(kQueueKindLabels, <String, String>{
        'ban_en_revue': 'Ban en revue',
        'a_examiner': 'À examiner',
        'refus_a_revoir': 'Refus à revoir',
      });
      expect(queueKindLabel('autre'), 'Type inconnu (autre)');
    });

    test('cibles', () {
      expect(kTargetKindLabels, <String, String>{
        'account': 'Compte',
        'channel': 'Chaîne',
        'page': 'Page',
      });
      expect(targetKindLabel('x'), 'Cible inconnue (x)');
    });

    test('actions du journal (9)', () {
      expect(kEventActionLabels, <String, String>{
        'candidate': 'Candidat (1er contenu)',
        'ban': 'Bannissement',
        'already_banned': 'Déjà banni',
        'pending_review': 'À examiner',
        'refused': 'Refus',
        'confirm': 'Confirmation',
        'lift': 'Levée',
        'unban': 'Débannissement manuel',
        'dismiss': "Mise à l'écart",
      });
      expect(eventActionLabel('purge'), 'Action inconnue (purge)');
    });

    test('acteurs', () {
      expect(kActorKindLabels, <String, String>{
        'detecteur': 'Détecteur',
        'revue': 'Revue (compte principal)',
        'manuel': 'Manuel',
      });
      expect(actorKindLabel('bot'), 'Acteur inconnu (bot)');
    });

    test('statuts de ban', () {
      expect(kBanStatusLabels, <String, String>{
        'en_revue': 'Auto — en revue',
        'confirme': 'Auto — confirmé',
        'manuel': 'Manuel',
        'leve': 'Levé',
        'ecarte': 'Écarté',
      });
      expect(banStatusLabel('x'), 'Statut inconnu (x)');
    });

    test('plateformes', () {
      expect(kPlatformLabels, <String, String>{
        'youtube': 'YouTube',
        'rutube': 'RUTUBE',
        'bilibili': 'bilibili',
        'web': 'Web',
      });
      expect(platformLabel('vk'), 'Plateforme inconnue (vk)');
    });

    test('disjoncteur', () {
      expect(kBreakerReasonLabels, <String, String>{
        'plafond_heure': 'plafond horaire atteint',
        'plafond_jour': 'plafond journalier atteint',
      });
      expect(breakerReasonLabel('manuel'), 'motif inconnu (manuel)');
    });

    test('champs des réglages', () {
      expect(kSettingsFieldLabels, <String, String>{
        'auto_ban_enabled': 'Interrupteur',
        'max_auto_bans_per_hour': 'Plafond par heure',
        'max_auto_bans_per_day': 'Plafond par jour',
        'allowed_rules_sha256': 'Empreintes autorisées',
      });
      expect(settingsFieldLabel('autre_cle'), 'autre_cle');
    });

    test('décisions antérieures', () {
      expect(kPreviousDecisionLabels, <String, String>{
        'ban': 'appliquée',
        'already_banned': 'close (déjà banni)',
        'dismiss': 'écartée',
        'refused': 'refusée',
      });
      expect(previousDecisionLabel('x'), 'décision inconnue (x)');
    });

    test('jeux ignorés à l’activation', () {
      expect(kSkippedGameLabels, <String, String>{
        'already_active': 'déjà actif',
        'below_threshold': 'sous le seuil (contenus retirés entre-temps)',
        'not_found': 'supprimé entre-temps',
      });
      expect(skippedGameLabel('x'), 'raison inconnue (x)');
    });

    test('niveaux', () {
      expect(kLevelLabels, <String, String>{
        'suspect': 'suspect',
        'extraction': 'extraction',
      });
      expect(levelLabel('autre'), 'autre');
    });

    test('code absent → « — » partout', () {
      for (final String Function(String?) f in <String Function(String?)>[
        queueKindLabel,
        targetKindLabel,
        eventActionLabel,
        actorKindLabel,
        banStatusLabel,
        platformLabel,
        breakerReasonLabel,
        settingsFieldLabel,
        previousDecisionLabel,
        skippedGameLabel,
        levelLabel,
      ]) {
        expect(f(null), '—');
        expect(f(''), '—');
      }
    });
  });
}
