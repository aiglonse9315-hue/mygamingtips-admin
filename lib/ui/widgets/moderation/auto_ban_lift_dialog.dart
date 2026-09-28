// Levée d'un ban AUTOMATIQUE depuis une LISTE (bannis, chaînes, pages ; P4b-3,
// lot L5, T3, T10, conception §6.4 c, §6.9) : détail chargé par
// `review-detail {event_id: banEventId}` affiché replié (cible, raisons,
// preuve) + décision « lever » avec motif OBLIGATOIRE ; bouton secondaire
// « Ouvrir dans Modération » si [onOpenModeration] est fourni (ferme puis
// l'appelant navigue avec `ModerationFocus(banEventId, status, targetKind)`).
// 401 (chargement ou décision) → fermeture + `onAuthError`. Après succès,
// l'appelant relit sa liste.
//
// Même mécanique que `ReviewDecisionDialog` (en mode `lift` avec détail),
// dont il est une enveloppe.
//
// Widget « de présentation » (aucun Provider) → testable en VM.
import 'package:flutter/material.dart';

import '../../../domain/models/moderation.dart';
import 'review_decision_dialog.dart';

class AutoBanLiftDialog extends StatelessWidget {
  const AutoBanLiftDialog({
    super.key,
    required this.loadDetail,
    required this.submit,
    required this.targetLabel,
    this.manualBanPresent = false,
    this.onOpenModeration,
    required this.onAuthError,
  });

  /// `sync.fetchReviewDetail(banEventId)`.
  final Future<ReviewDetail> Function() loadDetail;

  /// `sync.reviewDecide(banEventId, ReviewDecision.lift, reason: r)`.
  final Future<ReviewDecideResult> Function(String? reason) submit;

  /// Libellé court de la cible (révélé par le dialogue).
  final String targetLabel;

  /// Un ban humain est aussi posé (encart).
  final bool manualBanPresent;

  /// « Ouvrir dans Modération » (null = pas de bouton).
  final VoidCallback? onOpenModeration;

  /// 401 : appelé APRÈS la fermeture.
  final VoidCallback onAuthError;

  /// Ouvre le dialogue ; `null` si annulé, fermé sur 401 ou « Ouvrir dans
  /// Modération ».
  static Future<DecisionDialogOutcome?> show(
    BuildContext context, {
    required Future<ReviewDetail> Function() loadDetail,
    required Future<ReviewDecideResult> Function(String? reason) submit,
    required String targetLabel,
    bool manualBanPresent = false,
    VoidCallback? onOpenModeration,
    required VoidCallback onAuthError,
  }) => showDialog<DecisionDialogOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AutoBanLiftDialog(
      loadDetail: loadDetail,
      submit: submit,
      targetLabel: targetLabel,
      manualBanPresent: manualBanPresent,
      onOpenModeration: onOpenModeration,
      onAuthError: onAuthError,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return ReviewDecisionDialog(
      decision: ReviewDecision.lift,
      targetLabel: targetLabel,
      manualBanPresent: manualBanPresent,
      submit: submit,
      onAuthError: onAuthError,
      loadDetail: loadDetail,
      onOpenModeration: onOpenModeration,
    );
  }
}
