// Dialogue de décision de revue avec motif (P4b-3, lot L5, conception
// §6.4 b et c, §6.9) : commun aux 4 décisions (confirmer, lever, appliquer,
// écarter) et à la levée depuis une LISTE (`AutoBanLiftDialog`, qui ajoute
// le détail replié et « Ouvrir dans Modération »).
//
// Comportement :
// - reste OUVERT pendant l'appel (indicateur 16 px sur le bouton) et sur une
//   erreur 400 (message sous le champ) ;
// - 401 (`AdminAuthException`, au chargement du détail ou à la décision) →
//   se ferme PUIS appelle `onAuthError` (déconnexion) — jamais de
//   « Réessayer » sur un jeton expiré (S-08) ;
// - sinon se ferme et rend le résultat OU l'erreur à l'appelant
//   ([DecisionDialogOutcome], traduit par `outcomeFromResult` /
//   `outcomeFromError` via [DecisionDialogOutcome.outcome]) ; `null` si
//   annulé.
// Motif : `validateReviewReason(raw, required: décision == lever)` ; envoyé
// = `normalizeReviewReason(raw)` (coupé, vide → absent).
//
// Widget « de présentation » (aucun Provider) → testable en VM.
import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart'
    show
        AdminApiException,
        AdminAuthException,
        AdminForbiddenException,
        errorText,
        isUncertainFailure;
import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_labels.dart';
import '../../../domain/moderation_text.dart';
import 'evidence_view.dart';
import 'moderation_ui.dart';
import 'reason_chips.dart';
import 'reason_field.dart';

/// Issue d'un dialogue de décision : résultat 200 OU erreur (hors 401 et
/// 400, gérés dans le dialogue).
@immutable
class DecisionDialogOutcome {
  const DecisionDialogOutcome.result(ReviewDecideResult this.result)
    : error = null;
  const DecisionDialogOutcome.error(Object this.error) : result = null;

  final ReviewDecideResult? result;
  final Object? error;

  /// Traduction pour l'écran (SnackBar, relecture, retrait, purge proposée).
  DecisionOutcome get outcome {
    final ReviewDecideResult? r = result;
    if (r != null) {
      return outcomeFromResult(
        result: r.result,
        targetKind: r.targetKind,
        reasons: r.reasons,
        previous: r.previous,
        stillBanned: r.stillBanned,
        groupSize: r.groupSize,
        replayed: r.replayed,
      );
    }
    final Object e = error!;
    if (e is AdminForbiddenException) {
      return outcomeFromError(statusCode: 403, message: e.message);
    }
    if (e is AdminApiException) {
      return outcomeFromError(
        statusCode: e.statusCode,
        result: e.result,
        distinctContents: e.distinctContents,
        threshold: e.threshold,
        message: e.message,
        uncertain: isUncertainFailure(e),
      );
    }
    return outcomeFromError(
      statusCode: null,
      message: errorText(e),
      uncertain: isUncertainFailure(e),
    );
  }
}

/// Titre du dialogue de [d].
String decisionTitle(ReviewDecision d) => switch (d) {
  ReviewDecision.confirm => 'Confirmer le bannissement ?',
  ReviewDecision.lift => 'Lever le bannissement automatique ?',
  ReviewDecision.apply => 'Appliquer la demande ?',
  ReviewDecision.dismiss => 'Écarter la demande ?',
};

/// Phrase ajoutée à la confirmation d'une CHAÎNE.
const String _kConfirmChannelSuffix =
    ' Vous pourrez ensuite purger ses suggestions en attente.';

/// « bloquée » pour une page (on bloque une page, on ne la bannit pas),
/// « banni(e) » pour un compte ou une chaîne (essai local du 28/09/2026).
String _bannedWord(String? targetKind) =>
    targetKind == 'page' ? 'bloquée' : 'banni(e)';

/// Texte du dialogue de [d] ; [target] = libellé court DÉJÀ révélé.
String decisionText(
  ReviewDecision d, {
  required String target,
  String? targetKind,
  int groupSize = 1,
}) => switch (d) {
  ReviewDecision.confirm =>
    'Le bannissement de $target passe au statut « confirmé » et sort de la '
        'file.${targetKind == 'channel' ? _kConfirmChannelSuffix : ''}',
  ReviewDecision.lift =>
    '$target ne sera plus ${_bannedWord(targetKind)}. Ses partages antérieurs '
        'seront exemptés du bannissement automatique.',
  ReviewDecision.apply =>
    '$target sera ${_bannedWord(targetKind)} avec le statut « confirmé » '
        '(vous avez examiné la preuve). La décision vaut pour tout le groupe '
        '($groupSize événement(s)).',
  ReviewDecision.dismiss =>
    'Rien ne sera banni. Les partages antérieurs de $target seront exemptés '
        'du bannissement automatique. La décision vaut pour tout le groupe '
        '($groupSize événement(s)).',
};

/// Libellé du bouton de [d].
String decisionButtonLabel(ReviewDecision d) => switch (d) {
  ReviewDecision.confirm => 'Confirmer',
  ReviewDecision.lift => 'Lever le bannissement',
  ReviewDecision.apply => 'Appliquer',
  ReviewDecision.dismiss => 'Écarter',
};

/// Encart d'une levée quand un ban humain est aussi posé.
const String kManualBanDuringReviewNotice =
    'Un ban MANUEL a été posé pendant la revue : la cible restera bannie '
    '(ban manuel).';

class ReviewDecisionDialog extends StatefulWidget {
  const ReviewDecisionDialog({
    super.key,
    required this.decision,
    required this.targetLabel,
    this.targetKind,
    this.groupSize = 1,
    this.manualBanPresent = false,
    required this.submit,
    required this.onAuthError,
    this.loadDetail,
    this.onOpenModeration,
  });

  final ReviewDecision decision;

  /// Libellé court de la cible (révélé ici par `oneLinePreview`, 60).
  final String targetLabel;

  /// `channel` → la confirmation mentionne la purge possible.
  final String? targetKind;

  /// Taille du groupe (apply / dismiss).
  final int groupSize;

  /// Un ban humain est présent (encart de la levée).
  final bool manualBanPresent;

  /// Appel serveur ; reçoit le motif normalisé (null = absent).
  final Future<ReviewDecideResult> Function(String? reason) submit;

  /// 401 : appelé APRÈS la fermeture du dialogue.
  final VoidCallback onAuthError;

  /// Levée depuis une liste : détail (cible, raisons, preuve) affiché
  /// replié au-dessus du motif.
  final Future<ReviewDetail> Function()? loadDetail;

  /// Bouton secondaire « Ouvrir dans Modération » : ferme le dialogue PUIS
  /// appelle ce rappel (l'appelant navigue avec son `ModerationFocus`).
  final VoidCallback? onOpenModeration;

  /// Ouvre le dialogue ; `null` si annulé ou fermé sur 401.
  static Future<DecisionDialogOutcome?> show(
    BuildContext context, {
    required ReviewDecision decision,
    required String targetLabel,
    String? targetKind,
    int groupSize = 1,
    bool manualBanPresent = false,
    required Future<ReviewDecideResult> Function(String? reason) submit,
    required VoidCallback onAuthError,
  }) => showDialog<DecisionDialogOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ReviewDecisionDialog(
      decision: decision,
      targetLabel: targetLabel,
      targetKind: targetKind,
      groupSize: groupSize,
      manualBanPresent: manualBanPresent,
      submit: submit,
      onAuthError: onAuthError,
    ),
  );

  @override
  State<ReviewDecisionDialog> createState() => _ReviewDecisionDialogState();
}

class _ReviewDecisionDialogState extends State<ReviewDecisionDialog> {
  final TextEditingController _reason = TextEditingController();
  bool _submitting = false;
  String? _serverError;

  // Détail (levée depuis une liste).
  bool _detailLoading = false;
  ReviewDetail? _detail;
  String? _detailError;
  bool _detailRetryable = false;

  bool get _isLift => widget.decision == ReviewDecision.lift;

  @override
  void initState() {
    super.initState();
    _reason.addListener(_onReasonChanged);
    if (widget.loadDetail != null) _loadDetail();
  }

  @override
  void dispose() {
    _reason.removeListener(_onReasonChanged);
    _reason.dispose();
    super.dispose();
  }

  void _onReasonChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDetail() async {
    final Future<ReviewDetail> Function()? load = widget.loadDetail;
    if (load == null) return;
    setState(() {
      _detailLoading = true;
      _detailError = null;
    });
    try {
      final ReviewDetail d = await load();
      if (!mounted) return;
      setState(() {
        _detail = d;
        _detailLoading = false;
      });
    } on AdminAuthException {
      if (mounted) Navigator.of(context).pop();
      widget.onAuthError();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _detailLoading = false;
        _detailRetryable = false;
        if (e is AdminForbiddenException) {
          _detailError = 'Réservé au compte principal.';
        } else if (e is AdminApiException && e.isNotFound) {
          _detailError = 'Événement introuvable.';
        } else {
          _detailError = errorText(e);
          _detailRetryable = true;
        }
      });
    }
  }

  bool get _reasonValid =>
      validateReviewReason(_reason.text, required: _isLift) == null;

  Future<void> _submit() async {
    if (_submitting || !_reasonValid) return;
    setState(() {
      _submitting = true;
      _serverError = null;
    });
    try {
      final ReviewDecideResult r = await widget.submit(
        normalizeReviewReason(_reason.text),
      );
      if (!mounted) return;
      Navigator.of(context).pop(DecisionDialogOutcome.result(r));
    } on AdminAuthException {
      if (mounted) Navigator.of(context).pop();
      widget.onAuthError();
    } on AdminApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 400) {
        setState(() {
          _submitting = false;
          _serverError = e.message;
        });
        return;
      }
      Navigator.of(context).pop(DecisionDialogOutcome.error(e));
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(DecisionDialogOutcome.error(e));
    }
  }

  void _openModeration() {
    Navigator.of(context).pop();
    widget.onOpenModeration?.call();
  }

  Color? _buttonColor() => switch (widget.decision) {
    ReviewDecision.confirm => ModerationColors.warning,
    ReviewDecision.lift || ReviewDecision.apply => ModerationColors.danger,
    ReviewDecision.dismiss => null,
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String target = oneLinePreview(widget.targetLabel, max: 60);
    final bool withDetail = widget.loadDetail != null;
    return PopScope(
      canPop: !_submitting,
      child: AlertDialog(
        title: Text(decisionTitle(widget.decision)),
        content: SizedBox(
          width: withDetail ? 640 : 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (withDetail) ...<Widget>[
                  _detailSection(theme),
                  const SizedBox(height: 12),
                ],
                Text(
                  decisionText(
                    widget.decision,
                    target: target,
                    targetKind: widget.targetKind,
                    groupSize: widget.groupSize,
                  ),
                  key: const Key('moderation-decision-text'),
                ),
                if (_isLift && widget.manualBanPresent) ...<Widget>[
                  const SizedBox(height: 10),
                  const ModerationNotice(
                    key: Key('moderation-decision-manual-notice'),
                    text: kManualBanDuringReviewNotice,
                    color: ModerationColors.danger,
                    icon: Icons.person_off_outlined,
                  ),
                ],
                const SizedBox(height: 14),
                ReasonField(
                  controller: _reason,
                  fieldKey: const Key('moderation-decision-reason'),
                  required: _isLift,
                  label: _isLift ? 'Motif de la levée *' : 'Motif (facultatif)',
                  enabled: !_submitting,
                ),
                if (_serverError != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    _serverError!,
                    key: const Key('moderation-decision-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          if (widget.onOpenModeration != null)
            TextButton.icon(
              key: const Key('moderation-decision-open-moderation'),
              onPressed: _submitting ? null : _openModeration,
              icon: const Icon(Icons.gavel_rounded, size: 18),
              label: const Text('Ouvrir dans Modération'),
            ),
          TextButton(
            key: const Key('moderation-decision-cancel'),
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            key: const Key('moderation-decision-submit'),
            style: FilledButton.styleFrom(backgroundColor: _buttonColor()),
            onPressed: _submitting || !_reasonValid ? null : _submit,
            child: _submitting
                ? kButtonSpinner
                : Text(decisionButtonLabel(widget.decision)),
          ),
        ],
      ),
    );
  }

  /// Détail replié (levée depuis une liste) : cible, raisons, preuve.
  Widget _detailSection(ThemeData theme) {
    if (_detailLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
      );
    }
    final String? error = _detailError;
    if (error != null) {
      return Row(
        children: <Widget>[
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: Colors.orange.shade300,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              key: const Key('moderation-decision-detail-error'),
              style: TextStyle(color: Colors.orange.shade300),
            ),
          ),
          if (_detailRetryable)
            TextButton(
              key: const Key('moderation-decision-detail-retry'),
              onPressed: _loadDetail,
              child: const Text('Réessayer'),
            ),
        ],
      );
    }
    final ReviewDetail? d = _detail;
    if (d == null) return const SizedBox.shrink();
    final TextStyle? small = theme.textTheme.bodySmall;
    return Column(
      key: const Key('moderation-decision-detail'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '${targetKindLabel(d.event.targetKind)} · événement #${d.event.id} '
          '(${formatModerationDate(d.event.createdAt)})',
          style: small?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        UntrustedSelectable(d.event.targetKey ?? '—', maxLines: 3),
        const SizedBox(height: 6),
        ReasonChips(codes: d.event.reasons),
        ExpansionTile(
          key: const Key('moderation-decision-evidence'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: const Text(
            'Preuve',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          children: <Widget>[EvidenceView(detail: d)],
        ),
      ],
    );
  }
}
