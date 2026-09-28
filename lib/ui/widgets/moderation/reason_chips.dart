// Puces des raisons d'un événement de modération (P4b-3, lot L5, conception
// §6.3, §6.9) : libellé français (`reasonLabel`, repli « Raison inconnue
// (code) »), infobulle = code brut.
//
// Widget « de présentation » (aucun Provider) → testable en VM.
import 'package:flutter/material.dart';

import '../../../domain/moderation_labels.dart';
import 'moderation_ui.dart';

class ReasonChips extends StatelessWidget {
  const ReasonChips({
    super.key,
    required this.codes,
    this.color,
    this.showCode = false,
  });

  final List<String> codes;

  /// Couleur des puces (défaut : gris neutre).
  final Color? color;

  /// Affiche aussi le code entre parenthèses (détail d'un événement).
  final bool showCode;

  @override
  Widget build(BuildContext context) {
    if (codes.isEmpty) return const SizedBox.shrink();
    final Color c = color ?? ModerationColors.neutral;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        for (final String code in codes)
          ModerationPill(
            label: showCode
                ? '${reasonLabel(code)} ($code)'
                : reasonLabel(code),
            color: c,
            tooltip: code,
          ),
      ],
    );
  }
}
