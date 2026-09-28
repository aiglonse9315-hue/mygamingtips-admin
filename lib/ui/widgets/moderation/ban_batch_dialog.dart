// Ban MANUEL d'un LOT de comptes (« Comptes à bannir » ; P4b-3, lot L5, T6,
// conception §6.11, §6.9) : catégorie et motif COMMUNS choisis dans
// `BanBatchDialog`, puis bilan dans `BanBatchReportDialog` (bannis, déjà
// bannis, erreurs avec id court + message, lot interrompu par une session
// expirée).
//
// Texte du bilan : « Bilan : » suivi de `banBatchSummary` (fonction pure du
// lot L3, testée) — la conception écrivait « Bilan : A banni(s)… » au §6.11
// et « 3 compte(s) banni(s)… » au §4.5 : les deux sont réunis ici.
//
// Widgets « de présentation » (aucun Provider) → testables en VM.
import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart' show errorText;
import '../../../domain/ids.dart';
import '../../../domain/models/ban_category.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_text.dart';
import 'ban_category_dropdown.dart';
import 'moderation_ui.dart';
import 'reason_field.dart';

/// Texte du dialogue de lot.
const String kBanBatchMessage =
    'Ils ne pourront plus soumettre de suggestions.';

/// Ligne ajoutée au bilan quand un 401 a interrompu le lot.
const String kBanBatchStoppedBySession = 'Session expirée : lot interrompu.';

/// « Bilan : 3 compte(s) banni(s), 1 déjà banni(s), 2 erreur(s). »
String banBatchReportText(BanBatchReport r) => 'Bilan : ${banBatchSummary(r)}';

class BanBatchDialog extends StatefulWidget {
  const BanBatchDialog({
    super.key,
    required this.count,
    required this.categories,
    required this.submit,
  });

  /// Nombre de comptes sélectionnés.
  final int count;
  final List<BanCategory> categories;

  /// `store.banAccounts(ids, category:, reason:)`.
  final Future<BanBatchReport> Function(String category, String? reason) submit;

  /// Ouvre le dialogue ; rend le bilan (null si annulé).
  static Future<BanBatchReport?> show(
    BuildContext context, {
    required int count,
    required List<BanCategory> categories,
    required Future<BanBatchReport> Function(String category, String? reason)
    submit,
  }) => showDialog<BanBatchReport>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        BanBatchDialog(count: count, categories: categories, submit: submit),
  );

  @override
  State<BanBatchDialog> createState() => _BanBatchDialogState();
}

class _BanBatchDialogState extends State<BanBatchDialog> {
  final TextEditingController _reason = TextEditingController();
  late String _category;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _category = effectiveBanCategory(
      widget.categories,
      kDefaultManualBanCategory,
    );
    _reason.addListener(_onChanged);
  }

  @override
  void dispose() {
    _reason.removeListener(_onChanged);
    _reason.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  bool get _valid =>
      widget.count > 0 && ReasonField.isValid(_reason.text, required: false);

  Future<void> _submit() async {
    if (_saving || !_valid) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final BanBatchReport r = await widget.submit(
        _category,
        normalizeReviewReason(_reason.text),
      );
      if (!mounted) return;
      Navigator.of(context).pop(r);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text('Bannir ${widget.count} compte(s) ?'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(kBanBatchMessage),
                const SizedBox(height: 14),
                BanCategoryDropdown(
                  categories: widget.categories,
                  value: _category,
                  enabled: !_saving,
                  onChanged: (String v) => setState(() => _category = v),
                ),
                const SizedBox(height: 14),
                ReasonField(
                  controller: _reason,
                  fieldKey: const Key('ban-batch-reason'),
                  enabled: !_saving,
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    key: const Key('ban-batch-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('ban-batch-cancel'),
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            key: const Key('ban-batch-submit'),
            style: FilledButton.styleFrom(
              backgroundColor: ModerationColors.danger,
            ),
            onPressed: _saving || !_valid ? null : _submit,
            child: _saving ? kButtonSpinner : const Text('Bannir'),
          ),
        ],
      ),
    );
  }
}

class BanBatchReportDialog extends StatelessWidget {
  const BanBatchReportDialog({super.key, required this.report});

  final BanBatchReport report;

  static Future<void> show(BuildContext context, BanBatchReport report) =>
      showDialog<void>(
        context: context,
        builder: (_) => BanBatchReportDialog(report: report),
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<({String id, String message})> errors = report.errors;
    return AlertDialog(
      title: const Text('Bilan du bannissement'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                banBatchReportText(report),
                key: const Key('ban-batch-summary'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              if (report.stoppedBySession) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  kBanBatchStoppedBySession,
                  key: const Key('ban-batch-stopped'),
                  style: TextStyle(color: ModerationColors.warning),
                ),
              ],
              if (errors.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Text('Erreurs :', style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                for (final ({String id, String message}) e in errors)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '• ${oneLinePreview(shortId(e.id))} : '
                      '${oneLinePreview(e.message, max: 200)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FilledButton(
          key: const Key('ban-batch-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fermer'),
        ),
      ],
    );
  }
}
