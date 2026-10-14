// Pur (VM) — libellés et règles d'AFFICHAGE du menu « Log » (P4d L3,
// conception tools/PLAN_VISION2_P4d_CONCEPTION.md §4 « L3 — CONTRAT »).
//
// Le dépôt du panneau est PUBLIC (miroir) : ce fichier ne contient aucune
// règle du filtre « activité normale » (tenue en SQL par le serveur), aucun
// seuil, aucun code de tentative interprété (le libellé vient du serveur),
// aucun nom de compte.
//
// Aucune dépendance Flutter ni dart:html : testé sur VM
// (`flutter test test/logs_screen_rules_test.dart`).
import 'logs_export.dart';
import 'models/security_attempt.dart';

/// Onglets de l'écran.
const List<String> kLogsTabLabels = <String>['Journal', 'Tentatives'];

/// Lignes par page (journal et tentatives).
const int kLogsPageSize = 100;

/// Lignes par lecture de l'export « tout » (plafond du serveur : 500).
const int kLogsExportChunk = 500;

/// Bascule du filtre « activité normale » (fait par le serveur).
const String kLogsMaskToggleLabel = 'Masquer l\'activité normale';

/// Filtre demandé mais pas appliqué par le serveur (`filtre_applique`
/// faux) : le journal affiche tout.
const String kLogsFilterUnavailable = 'Filtre indisponible : tout est affiché';

/// Journal vide.
const String kLogsEmptyMessage = 'Aucun log pour ce filtre.';

/// Aucune tentative.
const String kAttemptsEmptyMessage = 'Aucune tentative enregistrée.';

/// Page à recharger quand la page [page] revient VIDE ([empty]) alors que
/// le serveur annonce [total] lignes (lignes archivées ou purgées pendant
/// la consultation) : la dernière page qui existe. Null s'il n'y a rien à
/// recharger : page non vide, 1re page, total nul (vrai message « vide »)
/// ou dernière page qui n'est pas AVANT [page] — la relance se termine
/// donc toujours.
int? lastPageIfBeyondEnd({
  required int page,
  required bool empty,
  required int total,
}) {
  if (!empty || page <= 0 || total <= 0) return null;
  final int last = (total - 1) ~/ kLogsPageSize;
  return last < page ? last : null;
}

/// Message « vide » (journal ou tentatives) : seulement quand le serveur
/// annonce 0 ligne ; une page vide avec un total positif garde la barre
/// de pagination.
bool showLogsEmpty({required bool empty, required int total}) =>
    empty && total <= 0;

/// « N ligne masquée » / « N lignes masquées » (singulier jusqu'à 1).
String maskedCountLabel(int n) =>
    n <= 1 ? '$n ligne masquée' : '$n lignes masquées';

/// Session courte : les 8 premiers caractères, '' si absente ou vide.
String shortSid(String? sid) {
  if (sid == null || sid.isEmpty) return '';
  return String.fromCharCodes(sid.runes.take(8));
}

/// Infobulle de l'icône de réussite (null : aucune icône).
String? successTooltip(bool? success) => switch (success) {
  true => 'Réussie',
  false => 'Échec ou blocage',
  null => null,
};

/// Date au format JJ/MM/AAAA HH:mm (heure locale du navigateur) ; « — » si
/// absente.
String formatLogDate(DateTime? at) {
  if (at == null) return '—';
  final DateTime d = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} '
      '${two(d.hour)}:${two(d.minute)}';
}

/// « ×N » d'une tentative regroupée ('' pour une seule occurrence).
String attemptOccurrencesLabel(SecurityAttempt a) =>
    a.isGrouped ? '×${a.occurrences}' : '';

/// « dernière : JJ/MM/AAAA HH:mm » d'une tentative regroupée dont la
/// dernière date diffère de la première ; null sinon.
String? attemptLastAtLabel(SecurityAttempt a) =>
    a.showLastAt ? 'dernière : ${formatLogDate(a.lastAt)}' : null;

/// Libellé affiché d'une tentative (« — » si le serveur n'en rend pas).
String attemptLabel(SecurityAttempt a) => a.libelle.isEmpty ? '—' : a.libelle;

/// Horodatage des noms de fichiers : AAAAMMJJ_HHmm.
String exportFileStamp(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}';
}

/// Message de fin d'un export « tout » : lignes exportées, lignes plus
/// récentes ignorées, doublons retirés, avertissement si incomplet, et
/// « filtre indisponible » si le filtre était demandé sans être appliqué.
String exportDoneMessage(
  StableExport<Object?> r, {
  bool maskRequested = false,
}) {
  final int n = r.rows.length;
  final StringBuffer sb = StringBuffer(
    'Export terminé : $n ${n <= 1 ? 'ligne' : 'lignes'}.',
  );
  if (r.ignoredRecent > 0) {
    sb.write(
      ' ${r.ignoredRecent} plus récente(s) que le début de l\'export '
      'ignorée(s).',
    );
  }
  if (r.removedDuplicates > 0) {
    sb.write(' ${r.removedDuplicates} doublon(s) retiré(s).');
  }
  if (maskRequested && !r.filtered) sb.write(' $kLogsFilterUnavailable.');
  if (!r.complete) {
    sb.write(' Export peut-être incomplet : relance-le.');
  }
  return sb.toString();
}
