// « Bannir <nom> ? » — ban MANUEL d'un compte connu (Suggestions,
// Abonnements, Comptes à bannir ; P4b-3, lot L5, T4, D4, conception §6.11,
// §6.9) : catégorie (4, D4), motif facultatif (≤ 500 points de code),
// encart si un ban AUTOMATIQUE est en cours, bouton « Bannir » (rouge).
//
// Attend `submit(category, reason)` (= `store.banAccount(...)`, qui rend un
// `WriteOutcome`) : succès → ferme en rendant l'issue (l'écran affiche
// « Compte banni. » ou l'avertissement `notice`) ; échec → message DANS le
// dialogue, qui reste ouvert ; session expirée (401 déjà traité par le
// contrôleur) → ferme sans message (S-08).
//
// Widget « de présentation » (aucun Provider) → testable en VM.
import 'package:flutter/material.dart';

import '../../../data/supabase_sync.dart' show errorText;
import '../../../domain/models/ban_category.dart';
import '../../../domain/moderation_text.dart';
import '../../../domain/write_outcome.dart';
import 'ban_category_dropdown.dart';
import 'moderation_ui.dart';
import 'reason_field.dart';

/// Texte du dialogue de ban d'un compte.
const String kBanAccountMessage =
    "Le compte ne pourra plus partager de contenus dans l'application.";

/// Encart : un ban automatique est déjà en cours sur ce compte.
const String kBanAccountAutoInReviewNotice =
    'Un bannissement automatique est en cours pour ce compte : ce ban MANUEL '
    'sera enregistré et restera en vigueur même si le ban automatique est '
    'levé.';

class BanAccountDialog extends StatefulWidget {
  const BanAccountDialog({
    super.key,
    this.title,
    required this.displayName,
    required this.categories,
    this.autoBanInReview = false,
    required this.submit,
    this.message = kBanAccountMessage,
  });

  /// Titre ; défaut « Bannir `nom` ? ».
  final String? title;

  /// Nom affiché du compte (texte d'utilisateur : révélé, 60 points de code).
  final String displayName;
  final List<BanCategory> categories;

  /// L'entrée connue est un ban AUTO en cours (encart).
  final bool autoBanInReview;
  final Future<WriteOutcome> Function(String category, String? reason) submit;
  final String message;

  /// Ouvre le dialogue ; rend l'issue (succès ou session expirée), `null` si
  /// annulé.
  static Future<WriteOutcome?> show(
    BuildContext context, {
    String? title,
    required String displayName,
    required List<BanCategory> categories,
    bool autoBanInReview = false,
    required Future<WriteOutcome> Function(String category, String? reason)
    submit,
  }) => showDialog<WriteOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => BanAccountDialog(
      title: title,
      displayName: displayName,
      categories: categories,
      autoBanInReview: autoBanInReview,
      submit: submit,
    ),
  );

  @override
  State<BanAccountDialog> createState() => _BanAccountDialogState();
}

class _BanAccountDialogState extends State<BanAccountDialog> {
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

  bool get _valid => ReasonField.isValid(_reason.text, required: false);

  Future<void> _submit() async {
    if (_saving || !_valid) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final WriteOutcome o = await widget.submit(
        _category,
        normalizeReviewReason(_reason.text),
      );
      if (!mounted) return;
      if (o.ok || o.sessionExpired) {
        Navigator.of(context).pop(o);
        return;
      }
      setState(() {
        _saving = false;
        _error = o.message ?? 'Bannissement impossible.';
      });
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
    final String name = oneLinePreview(widget.displayName, max: 60);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(widget.title ?? 'Bannir $name ?'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(widget.message),
                if (widget.autoBanInReview) ...<Widget>[
                  const SizedBox(height: 10),
                  ModerationNotice(
                    key: const Key('ban-account-auto-notice'),
                    text: kBanAccountAutoInReviewNotice,
                    color: ModerationColors.warning,
                    icon: Icons.gavel_rounded,
                  ),
                ],
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
                  fieldKey: const Key('ban-account-reason'),
                  enabled: !_saving,
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    key: const Key('ban-account-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('ban-account-cancel'),
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            key: const Key('ban-account-submit'),
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
