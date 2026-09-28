// Champ « Motif » des décisions et des bans (P4b-3, lot L5, conception
// §4.3 b, §6.4 b, §6.9) : compteur « N/500 » en POINTS DE CODE du texte coupé
// (`reasonCodePoints`, comme le serveur) — jamais `maxLength`, qui compte
// les graphèmes. Signale localement un motif trop long ou un caractère
// interdit (U+0000, demi-paire) ; le caractère OBLIGATOIRE est géré par
// l'appelant (bouton désactivé), avec le message qui lui est propre.
//
// Widget « de présentation » (aucun Provider) → testable en VM.
import 'package:flutter/material.dart';

import '../../../domain/moderation_text.dart';

class ReasonField extends StatelessWidget {
  const ReasonField({
    super.key,
    required this.controller,
    this.required = false,
    this.label,
    this.errorText,
    this.enabled = true,
    this.onChanged,
    this.fieldKey,
    this.maxLines = 3,
  });

  final TextEditingController controller;

  /// Motif obligatoire (libellé suivi de « * »).
  final bool required;

  /// Libellé ; défaut « Motif * » ou « Motif (facultatif) ».
  final String? label;

  /// Erreur imposée par l'appelant (prioritaire sur l'erreur locale).
  final String? errorText;
  final bool enabled;
  final ValueChanged<String>? onChanged;

  /// Clé posée sur le `TextField` (tests).
  final Key? fieldKey;
  final int maxLines;

  /// Erreur LOCALE (texte non vide trop long ou caractère interdit) ; null
  /// si valide ou vide (le caractère obligatoire est traité par l'appelant).
  static String? localError(String raw) =>
      raw.isEmpty ? null : validateReviewReason(raw, required: false);

  /// Vrai si le motif est envoyable ([required] : 1 à 500 points de code).
  static bool isValid(String raw, {required bool required}) =>
      validateReviewReason(raw, required: required) == null;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (BuildContext context, TextEditingValue value, Widget? _) {
        final int n = reasonCodePoints(value.text);
        final bool tooLong = n > kReasonMaxCodePoints;
        return TextField(
          key: fieldKey,
          controller: controller,
          enabled: enabled,
          minLines: 1,
          maxLines: maxLines,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label ?? (required ? 'Motif *' : 'Motif (facultatif)'),
            errorText: errorText ?? localError(value.text),
            errorMaxLines: 3,
            counterText: '$n/$kReasonMaxCodePoints',
            counterStyle: tooLong
                ? TextStyle(color: Theme.of(context).colorScheme.error)
                : null,
            border: const OutlineInputBorder(),
          ),
        );
      },
    );
  }
}
