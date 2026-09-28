// Pur (VM) — libellés français de la modération (P4b-3, lot L3, conception
// §4.4) : codes de raison produits par `moderation_auto_ban` et les
// décisions de revue (migration 0094), types d'éléments de la file, cibles,
// actions du journal, acteurs, statuts de ban, plateformes, motifs du
// disjoncteur, champs des réglages, décisions antérieures, jeux ignorés à
// l'activation, niveaux de détection.
//
// Chaque accès passe par une fonction qui rend un REPLI LISIBLE pour un code
// inconnu (un code ajouté plus tard côté serveur ne casse rien) et « — »
// pour un code absent.
//
// La table des raisons est encadrée par `// RAISONS-DEBUT` / `// RAISONS-FIN`
// : le test de parité deno `supabase/tests/parity/panel_labels_parity_test.ts`
// exige l'ÉGALITÉ STRICTE entre ses clés et les codes de la migration 0094
// (un code SQL sans libellé, ou un libellé sans code, fait échouer le test).
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM
// (`flutter test test/moderation_labels_test.dart`).
library;

/// Libellés des 61 codes de raison : les 51 codes ajoutés par
/// `array_append(v_refuse|v_review, '…')` dans `moderation_auto_ban`
/// (M94:982-1251) + 10 codes littéraux (M94:900-923, 1285, 1305, 1313-1319,
/// 1727). Les libellés qui contiennent une apostrophe sont écrits entre
/// guillemets doubles (les clés restent entre apostrophes : lues par le test
/// de parité).
const Map<String, String> kReasonLabels = <String, String>{
  // RAISONS-DEBUT
  // Refus — action demandée.
  'action_introuvable': 'Action introuvable dans la demande',
  'action_incoherente': 'Action incohérente avec la demande',
  'action_non_eligible': 'Action non éligible selon le détecteur',
  'plusieurs_bans_eligibles': 'Plusieurs bans éligibles dans la même demande',
  'fondement_absent': 'Aucune détection fondatrice',
  'fondement_invalide': 'Détection fondatrice invalide',
  // Refus — suggestion.
  'statut_non_pending': 'Suggestion déjà traitée (plus en attente)',
  'source_incoherente': 'Source de la suggestion incohérente',
  'url_invalide': 'URL de la suggestion invalide',
  'plateforme_incoherente': "Plateforme incohérente avec l'URL",
  'texte_absent': 'Texte partagé absent',
  'texte_trop_long': 'Texte partagé trop long (plus de 20 000 caractères)',
  'oracle_present': "Détails de détection encore lisibles par l'auteur",
  // Refus — règles.
  'version_detecteur_refusee': 'Version du détecteur refusée',
  'empreinte_incoherente': 'Empreintes de règles incohérentes',
  'empreinte_non_reconnue_client':
      'Empreinte de règles non reconnue par le bot',
  'bans_suspendus': 'Bans suspendus côté bot',
  'etat_regles_refuse': 'État des règles refusé',
  'regle_reponse': "Détection sur une réponse d'IA ou de niveau invalide",
  'id_regle_inconnu': 'Identifiant de règle inconnu',
  'detections_absentes': 'Aucune détection',
  // Refus — preuve.
  'fondement_non_bannissable': 'Détection fondatrice non bannissable',
  'fondement_sans_consigne_ou_cible': 'Détection sans consigne ni cible',
  'demande_hors_bornes': 'Demande hors bornes (tronquée)',
  // Refus — compte.
  'source_non_utilisateur': "Partage d'un bot : pas de ban de compte",
  'auteur_absent': 'Auteur du partage absent',
  'auteur_incoherent': 'Auteur différent du compte visé',
  'titre_non_lu': 'Titre du contenu non lu',
  'texte_page_partiel': 'Texte de la page incomplet',
  'langue_differente': 'Langue différente de celle du contenu',
  'langue_contenu_inconnue': 'Langue du contenu inconnue',
  'fondement_hors_texte_partage': 'Détection hors du texte partagé',
  // Refus — chaîne.
  'plateforme_non_video': 'Plateforme non vidéo',
  'cle_chaine_invalide': 'Identifiant de chaîne invalide',
  'contenu_id_absent': 'Identifiant de vidéo absent',
  'contenu_id_ambigu': 'Identifiant de vidéo ambigu',
  'contenu_id_incoherent': 'Identifiant de vidéo incohérent',
  'fondement_hors_createur': 'Détection hors des champs du créateur',
  // Refus — page.
  'plateforme_non_web': 'Plateforme non web',
  'cle_page_invalide': 'URL de page invalide',
  'hote_ugc': "Site de contenus d'utilisateurs (jamais bloqué)",
  'fondement_hors_titre_page': 'Détection hors du titre de la page',
  // Refus de procédure (applicables par le compte principal).
  'analyse_non_marquee': 'Analyse Sentinelle non marquée',
  'empreinte_non_autorisee': 'Empreinte de règles non autorisée',
  // À examiner.
  'empreinte_brute_differente': "Texte ou lien modifié depuis l'analyse",
  'detection_createur_site':
      'Détection du créateur ou du site dans le même rapport',
  'detection_utilisateur': "Texte de l'utilisateur repris par la page",
  'page_avec_requete': "Page avec paramètres dans l'URL",
  'page_hote_different': 'Page sur un autre site que le lien partagé',
  'page_publiee': 'Page déjà publiée dans le catalogue',
  'hote_avec_contenus': 'Site qui a déjà des contenus validés',
  'auto_ban_desactive': 'Ban automatique éteint',
  'disjoncteur_declenche': 'Disjoncteur déclenché',
  'plafond_heure': 'Plafond horaire atteint',
  'plafond_jour': 'Plafond journalier atteint',
  // Automate / revue.
  'exempte_apres_levee': "Partage antérieur à une levée ou une mise à l'écart",
  'profil_absent': 'Profil supprimé',
  // Jamais journalisés, mais possibles dans une réponse.
  'role_refuse': "Rôle d'appel refusé",
  'acteur_inactif': 'Compte admin inactif',
  'categorie_non_auto': 'Catégorie non permise au ban automatique',
  'action_inconnue': 'Action inconnue',
  // RAISONS-FIN
};

/// Types d'éléments de la file de revue (`moderation_review_list.kind`).
const Map<String, String> kQueueKindLabels = <String, String>{
  'ban_en_revue': 'Ban en revue',
  'a_examiner': 'À examiner',
  'refus_a_revoir': 'Refus à revoir',
};

/// Types de cible d'un événement.
const Map<String, String> kTargetKindLabels = <String, String>{
  'account': 'Compte',
  'channel': 'Chaîne',
  'page': 'Page',
};

/// Actions du journal `ban_events` (EVENT_ACTIONS, moderation.ts:56-59).
const Map<String, String> kEventActionLabels = <String, String>{
  'candidate': 'Candidat (1er contenu)',
  'ban': 'Bannissement',
  'already_banned': 'Déjà banni',
  'pending_review': 'À examiner',
  'refused': 'Refus',
  'confirm': 'Confirmation',
  'lift': 'Levée',
  'unban': 'Débannissement manuel',
  'dismiss': "Mise à l'écart",
};

/// Auteur d'un événement (`ban_events.actor_kind`).
const Map<String, String> kActorKindLabels = <String, String>{
  'detecteur': 'Détecteur',
  'revue': 'Revue (compte principal)',
  'manuel': 'Manuel',
};

/// Statut d'un ban (compte, chaîne, page).
const Map<String, String> kBanStatusLabels = <String, String>{
  'en_revue': 'Auto — en revue',
  'confirme': 'Auto — confirmé',
  'manuel': 'Manuel',
  'leve': 'Levé',
  'ecarte': 'Écarté',
};

/// Plateformes des cibles.
const Map<String, String> kPlatformLabels = <String, String>{
  'youtube': 'YouTube',
  'rutube': 'RUTUBE',
  'bilibili': 'bilibili',
  'web': 'Web',
};

/// Motif du disjoncteur (`moderation_settings.breaker_reason`) ; en
/// minuscules : affiché au milieu d'une phrase.
const Map<String, String> kBreakerReasonLabels = <String, String>{
  'plafond_heure': 'plafond horaire atteint',
  'plafond_jour': 'plafond journalier atteint',
};

/// Champs refusés par `moderation_settings_set` (`reasons` du 400 SQL,
/// M94:2311-2327 — branche inatteignable par l'EF v95, décodée par
/// sécurité).
const Map<String, String> kSettingsFieldLabels = <String, String>{
  'auto_ban_enabled': 'Interrupteur',
  'max_auto_bans_per_hour': 'Plafond par heure',
  'max_auto_bans_per_day': 'Plafond par jour',
  'allowed_rules_sha256': 'Empreintes autorisées',
};

/// Décision antérieure d'un élément déjà traité
/// (`already_resolved.previous`, M94:1669-1679) ; en minuscules.
const Map<String, String> kPreviousDecisionLabels = <String, String>{
  'ban': 'appliquée',
  'already_banned': 'close (déjà banni)',
  'dismiss': 'écartée',
  'refused': 'refusée',
};

/// Jeux ignorés par `games/activate-ready` (M95:127-137) ; en minuscules.
const Map<String, String> kSkippedGameLabels = <String, String>{
  'already_active': 'déjà actif',
  'below_threshold': 'sous le seuil (contenus retirés entre-temps)',
  'not_found': 'supprimé entre-temps',
};

/// Niveau d'une détection ; en minuscules.
const Map<String, String> kLevelLabels = <String, String>{
  'suspect': 'suspect',
  'extraction': 'extraction',
};

/// Libellé d'une table, « — » pour un code absent, repli sinon.
String _label(
  Map<String, String> table,
  String? code,
  String Function(String) fallback,
) {
  if (code == null || code.isEmpty) return '—';
  return table[code] ?? fallback(code);
}

/// Libellé d'un code de raison ; code inconnu → « Raison inconnue (xyz) ».
String reasonLabel(String? code) =>
    _label(kReasonLabels, code, (String c) => 'Raison inconnue ($c)');

/// Libellés d'une liste de raisons, dans l'ordre reçu.
List<String> reasonLabels(Iterable<String> codes) => <String>[
  for (final String c in codes) reasonLabel(c),
];

/// Type d'élément de la file ; inconnu → « Type inconnu (xyz) ».
String queueKindLabel(String? kind) =>
    _label(kQueueKindLabels, kind, (String c) => 'Type inconnu ($c)');

/// Type de cible ; inconnu → « Cible inconnue (xyz) ».
String targetKindLabel(String? kind) =>
    _label(kTargetKindLabels, kind, (String c) => 'Cible inconnue ($c)');

/// Action du journal ; inconnue → « Action inconnue (xyz) ».
String eventActionLabel(String? action) =>
    _label(kEventActionLabels, action, (String c) => 'Action inconnue ($c)');

/// Auteur d'un événement ; inconnu → « Acteur inconnu (xyz) ».
String actorKindLabel(String? kind) =>
    _label(kActorKindLabels, kind, (String c) => 'Acteur inconnu ($c)');

/// Statut d'un ban ; inconnu → « Statut inconnu (xyz) ».
String banStatusLabel(String? status) =>
    _label(kBanStatusLabels, status, (String c) => 'Statut inconnu ($c)');

/// Plateforme ; inconnue → « Plateforme inconnue (xyz) ».
String platformLabel(String? platform) =>
    _label(kPlatformLabels, platform, (String c) => 'Plateforme inconnue ($c)');

/// Motif du disjoncteur ; inconnu → « motif inconnu (xyz) ».
String breakerReasonLabel(String? reason) =>
    _label(kBreakerReasonLabels, reason, (String c) => 'motif inconnu ($c)');

/// Champ des réglages ; inconnu → le code brut.
String settingsFieldLabel(String? field) =>
    _label(kSettingsFieldLabels, field, (String c) => c);

/// Décision antérieure ; inconnue → « décision inconnue (xyz) ».
String previousDecisionLabel(String? previous) => _label(
  kPreviousDecisionLabels,
  previous,
  (String c) => 'décision inconnue ($c)',
);

/// Raison d'un jeu ignoré ; inconnue → « raison inconnue (xyz) ».
String skippedGameLabel(String? reason) =>
    _label(kSkippedGameLabels, reason, (String c) => 'raison inconnue ($c)');

/// Niveau d'une détection ; inconnu → le code brut.
String levelLabel(String? level) =>
    _label(kLevelLabels, level, (String c) => c);
