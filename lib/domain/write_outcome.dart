// Pur (VM) — résultat commun des écritures du contrôleur (P4b-3, lot L3,
// conception §5) : succès (avec avertissement facultatif), échec (message,
// issue éventuellement incertaine) ou session expirée (401 déjà traité par
// le contrôleur : le dialogue appelant se FERME, sans message ni
// « Réessayer »).
//
// `UnbanOutcome` et `BanBatchReport` sont dans `moderation_actions.dart`.
//
// Aucune dépendance dart:html ni Flutter UI : testé sur VM
// (`flutter test test/moderation_actions_test.dart`).
import 'package:flutter/foundation.dart';

@immutable
class WriteOutcome {
  /// Succès ; [notice] = avertissement orange facultatif.
  const WriteOutcome.ok({this.notice})
    : ok = true,
      message = null,
      uncertain = false,
      sessionExpired = false;

  /// Échec ; [uncertain] = issue inconnue (réseau, délai, 5xx) : l'état doit
  /// être relu.
  const WriteOutcome.failed(String this.message, {this.uncertain = false})
    : ok = false,
      notice = null,
      sessionExpired = false;

  /// 401 déjà traité (`onAuthError` appelé) → fermer le dialogue.
  const WriteOutcome.sessionExpired()
    : ok = false,
      message = null,
      notice = null,
      uncertain = false,
      sessionExpired = true;

  final bool ok;
  final String? message;
  final String? notice;
  final bool uncertain;
  final bool sessionExpired;

  @override
  String toString() => ok
      ? 'WriteOutcome.ok(${notice ?? ''})'
      : sessionExpired
      ? 'WriteOutcome.sessionExpired()'
      : 'WriteOutcome.failed($message, uncertain: $uncertain)';
}
