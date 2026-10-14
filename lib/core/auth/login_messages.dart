// Pur (VM) — message de l'écran de connexion selon la réponse d'admin-login
// (P4d L3, décision D14 ; tools/PLAN_VISION2_P4d_CONCEPTION.md §4
// « L3 — CONTRAT », partie « Connexion »).
//
// Avant L3, toute réponse autre qu'un jeton devenait « Identifiants
// incorrects » et un verrou LOCAL recopiait les seuils du serveur (nombre
// d'essais, durée de blocage) dans ce code, publié dans le miroir PUBLIC du
// panneau. Désormais le serveur fait foi :
//   - 401 → « Identifiants incorrects. » (texte fixe) ;
//   - 429 → le message RENDU PAR LE SERVEUR, tel quel (il porte la durée
//     restante ; rien n'est recalculé ici, l'en-tête Retry-After n'est pas
//     lu) ;
//   - 503 → indisponibilité (texte fixe : le détail du serveur ne sert pas
//     à l'utilisateur) ;
//   - 400 → requête refusée (texte fixe) ;
//   - 403 → message du serveur s'il en donne un, sinon générique (cas
//     que le panneau ne rencontre pas en usage normal) ;
//   - erreur réseau ou délai dépassé → « Serveur injoignable. » ;
//   - identifiant vide (ou fait d'espaces) ou mot de passe vide → texte
//     local fixe, AUCUNE requête (`AuthService.login`) : le serveur aurait
//     répondu 400 et noté une « requête invalide » pour un simple oubli.
// AUCUN seuil, aucune durée, aucun nom de compte dans ce fichier.
//
// Le texte rendu par le serveur passe par [oneLinePreview] (une ligne,
// caractères invisibles rendus visibles, longueur bornée) : défense en
// profondeur, le corps d'une réponse n'est jamais affiché brut.
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM
// (`flutter test test/auth_login_messages_test.dart`).
import 'dart:convert';

import '../../domain/moderation_text.dart' show oneLinePreview;

/// 401 : identifiant inconnu, mot de passe faux ou compte désactivé (le
/// serveur ne les distingue pas).
const String kMessageIdentifiantsIncorrects = 'Identifiants incorrects.';

/// 503 (et autres 5xx) : service momentanément indisponible.
const String kMessageServiceIndisponible =
    'Service momentanément indisponible, réessaie dans un instant.';

/// 400 : corps refusé par le serveur (« Requête invalide. », « Champs
/// manquants. »).
const String kMessageRequeteRefusee = 'Requête refusée par le serveur.';

/// Erreur réseau, CORS ou délai dépassé : aucune réponse lisible.
const String kMessageServeurInjoignable = 'Serveur injoignable.';

/// Identifiant vide (ou fait d'espaces) ou mot de passe vide : rien n'est
/// envoyé au serveur (texte local fixe, sans seuil ni durée).
const String kMessageChampsRequis = 'Identifiant et mot de passe requis.';

/// 429 sans message lisible : le serveur n'a pas donné la durée, on n'en
/// invente aucune.
const String kMessageTropDeTentatives =
    'Trop de tentatives. Réessaie plus tard.';

/// 403 sans message lisible.
const String kMessageAccesRefuse = 'Accès refusé par le serveur.';

/// 200 sans jeton, ou statut que le contrat ne prévoit pas.
const String kMessageReponseInattendue = 'Réponse inattendue du serveur.';

/// Jeton reçu dont l'`exp` est déjà passé pour cet appareil (horloge locale
/// en avance) : la session ne serait jamais ouverte.
const String kMessageJetonDejaExpire =
    'Jeton reçu déjà expiré : vérifie la date et l\'heure de cet appareil.';

/// Session fermée par l'échéance du jeton (même texte que l'avis du 401
/// d'une écriture, admin_shell.dart).
const String kMessageSessionExpiree =
    'Session expirée. Veuillez vous reconnecter.';

/// Panneau construit sans adresse d'authentification.
const String kMessageConfigurationRequise =
    'Configuration serveur requise pour l\'authentification.';

/// Longueur affichée au plus d'un message du serveur (points de code).
const int kMessageServeurMax = 200;

/// Objet JSON du corps [corps], ou null (corps vide, illisible, ou qui
/// n'est pas un objet).
Map<String, dynamic>? _objet(String corps) {
  try {
    final Object? v = jsonDecode(corps);
    return v is Map<String, dynamic> ? v : null;
  } on FormatException {
    return null;
  }
}

/// Champ `error` du corps [corps] d'une réponse d'admin-login, sur une
/// ligne, caractères invisibles neutralisés, borné à [kMessageServeurMax] ;
/// null s'il est absent, non textuel ou vide.
String? messageDuServeur(String corps) {
  final Object? brut = _objet(corps)?['error'];
  if (brut is! String) return null;
  final String texte = brut.trim();
  if (texte.isEmpty) return null;
  return oneLinePreview(texte, max: kMessageServeurMax);
}

/// Message à afficher pour une réponse d'admin-login de statut [statut] et
/// de corps [corps] (texte déjà décodé) qui n'a PAS ouvert de session.
String messageRefusConnexion(int statut, String corps) {
  switch (statut) {
    case 400:
      return kMessageRequeteRefusee;
    case 401:
      return kMessageIdentifiantsIncorrects;
    case 403:
      return messageDuServeur(corps) ?? kMessageAccesRefuse;
    case 429:
      return messageDuServeur(corps) ?? kMessageTropDeTentatives;
  }
  // 503 du contrat ; les autres 5xx (passerelle, délai de la fonction)
  // disent la même chose à l'utilisateur.
  if (statut >= 500 && statut <= 599) return kMessageServiceIndisponible;
  return kMessageReponseInattendue;
}

/// Succès lu dans le corps d'un 200 : `{token, is_owner}`.
typedef SuccesConnexion = ({String token, bool isOwner});

/// Jeton et privilège du corps [corps] d'un 200 ; null si le corps n'est pas
/// un objet portant un `token` textuel non vide. `is_owner` absent ou non
/// booléen vaut faux (le jeton le confirme ensuite).
SuccesConnexion? lireSuccesConnexion(String corps) {
  final Map<String, dynamic>? objet = _objet(corps);
  final Object? token = objet?['token'];
  if (token is! String || token.isEmpty) return null;
  return (token: token, isOwner: objet!['is_owner'] == true);
}
