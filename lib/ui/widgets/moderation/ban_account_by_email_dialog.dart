// « Bannir un compte » du tableau de bord (P4b-3, lot L6, T4, D4,
// conception §6.10) : le compte est désigné par son E-MAIL ou son
// identifiant (UUID) — plus de champ « Nom / Pseudo » (le nom affiché vient
// du serveur après relecture) ; catégorie (4, D4) ; motif facultatif
// (≤ 500 points de code).
//
// Attend `submit(saisie, catégorie, motif)` (= `store.banAccountByEmailOrId`,
// qui rend un `WriteOutcome`) :
// - succès → ferme en rendant l'issue (l'écran affiche « Compte banni. » ou
//   l'avertissement `notice`) ;
// - échec (e-mail inconnu, identifiant invalide, profil introuvable…) →
//   message rouge DANS le dialogue, qui reste OUVERT ;
// - session expirée (401 déjà traité par le contrôleur) → ferme sans
//   message (S-08).
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

/// Libellé du champ de saisie.
const String kBanByEmailFieldLabel = 'E-mail ou identifiant du compte *';

/// Aide sous le champ de saisie.
const String kBanByEmailFieldHelp =
    'Adresse e-mail du compte ou son identifiant (UUID).';

/// Encart du dialogue.
const String kBanByEmailNotice =
    "Le compte banni ne pourra plus soumettre de suggestions dans "
    "l'application.";

class BanAccountByEmailDialog extends StatefulWidget {
  const BanAccountByEmailDialog({
    super.key,
    required this.categories,
    required this.submit,
  });

  /// Catégories connues (réponse serveur ou repli) ; filtrées par la liste
  /// déroulante (D4).
  final List<BanCategory> categories;

  /// Reçoit la saisie BRUTE (le contrôleur la coupe et la classe), le code
  /// de catégorie et le motif normalisé (null = sans motif).
  final Future<WriteOutcome> Function(
    String input,
    String category,
    String? reason,
  )
  submit;

  @override
  State<BanAccountByEmailDialog> createState() =>
      _BanAccountByEmailDialogState();
}

class _BanAccountByEmailDialogState extends State<BanAccountByEmailDialog> {
  final TextEditingController _input = TextEditingController();
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
    _input.addListener(_onChanged);
    _reason.addListener(_onChanged);
  }

  @override
  void dispose() {
    _input.removeListener(_onChanged);
    _reason.removeListener(_onChanged);
    _input.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  bool get _valid =>
      _input.text.trim().isNotEmpty &&
      ReasonField.isValid(_reason.text, required: false);

  Future<void> _save() async {
    if (_saving || !_valid) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final WriteOutcome o = await widget.submit(
        _input.text,
        _category,
        normalizeReviewReason(_reason.text),
      );
      if (!mounted) return;
      if (o.ok || o.sessionExpired) {
        Navigator.of(context).pop(o);
        return;
      }
      setState(() => _error = o.message ?? 'Bannissement impossible.');
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color danger = ModerationColors.danger;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Row(
          children: <Widget>[
            Icon(Icons.block_rounded, color: danger),
            const SizedBox(width: 8),
            const Text('Bannir un compte'),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  key: const Key('ban-email-input'),
                  controller: _input,
                  enabled: !_saving,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: kBanByEmailFieldLabel,
                    helperText: kBanByEmailFieldHelp,
                    prefixIcon: Icon(Icons.alternate_email_rounded),
                  ),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 16),
                BanCategoryDropdown(
                  categories: widget.categories,
                  value: _category,
                  enabled: !_saving,
                  onChanged: (String v) => setState(() => _category = v),
                ),
                const SizedBox(height: 14),
                ReasonField(
                  controller: _reason,
                  fieldKey: const Key('ban-email-reason'),
                  enabled: !_saving,
                ),
                const SizedBox(height: 8),
                ModerationNotice(
                  text: kBanByEmailNotice,
                  color: danger,
                  icon: Icons.warning_amber_rounded,
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    key: const Key('ban-email-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('ban-email-cancel'),
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton.icon(
            key: const Key('ban-email-submit'),
            style: FilledButton.styleFrom(backgroundColor: danger),
            onPressed: _saving || !_valid ? null : _save,
            icon: _saving ? kButtonSpinner : const Icon(Icons.block_rounded),
            label: Text(_saving ? 'Bannissement…' : 'Bannir'),
          ),
        ],
      ),
    );
  }
}
