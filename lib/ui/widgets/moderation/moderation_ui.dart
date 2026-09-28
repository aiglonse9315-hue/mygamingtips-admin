// Briques d'affichage communes aux widgets de modération (P4b-3, lot L5,
// conception §6 et §6.9) : date locale « JJ/MM/AAAA HH:mm », pastille,
// texte NON FIABLE (révélé, gauche-à-droite, rogné), libellés et boutons des
// actions de revue, correspondance action → décision.
//
// Widgets « de présentation » : AUCUN import de StoreController,
// AuthController ni Provider (chaîne dart:html) → testables en VM.
import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_text.dart';

/// Couleurs sémantiques de la modération (conventions de la conception §6).
class ModerationColors {
  ModerationColors._();

  /// Destructif / erreur.
  static const Color danger = AppColors.categoryVideo;

  /// Succès.
  static const Color success = AppColors.categoryGuide;

  /// Information.
  static const Color info = AppColors.neonCyan;

  /// Attention « or ».
  static const Color gold = AppColors.plusGold;

  /// Attention (orange des pastilles et avertissements).
  static Color get warning => Colors.orange.shade700;

  /// Neutre.
  static const Color neutral = Colors.grey;
}

/// Date en heure LOCALE « JJ/MM/AAAA HH:mm » ; « — » si absente.
String formatModerationDate(DateTime? at) {
  if (at == null) return '—';
  final DateTime d = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Libellé d'origine d'un ban ou d'un événement : « Auto » / « Manuel ».
String banOriginLabel(String? origin) {
  if (origin == null || origin.isEmpty) return '—';
  if (origin == 'auto') return 'Auto';
  if (origin == 'manual') return 'Manuel';
  return oneLinePreview(origin, max: 40);
}

/// Pastille (fond α 0.14, bordure α 0.5, rayon 8, texte 11 gras).
class ModerationPill extends StatelessWidget {
  const ModerationPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.tooltip,
  });

  final String label;
  final Color color;
  final IconData? icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
    final String? tip = tooltip;
    return tip == null ? pill : Tooltip(message: tip, child: pill);
  }
}

/// Encart coloré (fond α 0.10, bordure α 0.4, rayon 10) avec icône.
class ModerationNotice extends StatelessWidget {
  const ModerationNotice({
    super.key,
    required this.text,
    required this.color,
    this.icon = Icons.info_outline_rounded,
  });

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5))),
        ],
      ),
    );
  }
}

/// Texte NON FIABLE sur UNE ligne : `oneLinePreview` (caractères cachés
/// rendus visibles, sauts de ligne « ⏎ », coupé à [max] points de code),
/// gauche-à-droite, rogné, jamais cliquable.
class UntrustedLine extends StatelessWidget {
  const UntrustedLine(
    this.raw, {
    super.key,
    this.max = 120,
    this.monospace = false,
    this.style,
  });

  final String raw;
  final int max;
  final bool monospace;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final TextStyle base = style ?? const TextStyle(fontSize: 12.5);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ClipRect(
        child: Text(
          oneLinePreview(raw, max: max),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: monospace ? base.copyWith(fontFamily: 'monospace') : base,
        ),
      ),
    );
  }
}

/// Valeur COMPLÈTE d'un texte non fiable, sélectionnable (jamais un lien) :
/// `revealInvisibles` borné à [maxUnits], gauche-à-droite, rogné.
class UntrustedSelectable extends StatelessWidget {
  const UntrustedSelectable(
    this.raw, {
    super.key,
    this.maxUnits = 4096,
    this.maxLines,
    this.monospace = true,
    this.fontSize = 12,
  });

  final String raw;
  final int maxUnits;
  final int? maxLines;
  final bool monospace;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ClipRect(
        child: SelectableText(
          revealInvisibles(raw, maxUnits: maxUnits).text,
          // minLines : sans lui, SelectableText réserve TOUJOURS la hauteur
          // de maxLines lignes (vide sous une clé courte, essai local P4b-3).
          minLines: maxLines == null ? null : 1,
          maxLines: maxLines,
          style: TextStyle(
            fontSize: fontSize,
            fontFamily: monospace ? 'monospace' : null,
          ),
        ),
      ),
    );
  }
}

/// Libellé du bouton d'une action de revue.
String reviewActionLabel(ReviewAction a) => switch (a) {
  ReviewAction.detail => 'Détail',
  ReviewAction.confirm => 'Confirmer',
  ReviewAction.lift => 'Lever',
  ReviewAction.apply => 'Appliquer',
  ReviewAction.dismiss => 'Écarter',
  ReviewAction.purge => 'Purger',
};

/// Décision de `review-decide` portée par une action (null : détail, purge).
ReviewDecision? decisionForAction(ReviewAction a) => switch (a) {
  ReviewAction.confirm => ReviewDecision.confirm,
  ReviewAction.lift => ReviewDecision.lift,
  ReviewAction.apply => ReviewDecision.apply,
  ReviewAction.dismiss => ReviewDecision.dismiss,
  ReviewAction.detail || ReviewAction.purge => null,
};

/// Bouton d'une action de revue : « Détail » / « Écarter » (contour),
/// « Confirmer » (plein orange), « Lever » / « Purger » (contour rouge),
/// « Appliquer » (plein rouge). [onPressed] nul → désactivé.
Widget reviewActionButton(
  ReviewAction a, {
  required VoidCallback? onPressed,
  Key? key,
}) {
  final Text label = Text(reviewActionLabel(a));
  return switch (a) {
    ReviewAction.confirm => FilledButton(
      key: key,
      style: FilledButton.styleFrom(backgroundColor: ModerationColors.warning),
      onPressed: onPressed,
      child: label,
    ),
    ReviewAction.apply => FilledButton(
      key: key,
      style: FilledButton.styleFrom(backgroundColor: ModerationColors.danger),
      onPressed: onPressed,
      child: label,
    ),
    ReviewAction.lift || ReviewAction.purge => OutlinedButton(
      key: key,
      style: OutlinedButton.styleFrom(
        foregroundColor: ModerationColors.danger,
        side: BorderSide(color: ModerationColors.danger.withValues(alpha: 0.6)),
      ),
      onPressed: onPressed,
      child: label,
    ),
    ReviewAction.detail || ReviewAction.dismiss => OutlinedButton(
      key: key,
      onPressed: onPressed,
      child: label,
    ),
  };
}

/// Petit indicateur de chargement (16 px) pour un bouton en cours.
const Widget kButtonSpinner = SizedBox(
  width: 16,
  height: 16,
  child: CircularProgressIndicator(strokeWidth: 2),
);
