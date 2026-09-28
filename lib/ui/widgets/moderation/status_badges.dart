// Pastilles de la modération (P4b-3, lot L5, conception §6.3, §6.9-§6.12) :
// type d'élément de la file, statut / origine d'un ban, conflit « ban
// manuel présent », catégorie.
//
// Widgets « de présentation » (aucun Provider) → testables en VM.
import 'package:flutter/material.dart';

import '../../../domain/models/ban_category.dart';
import '../../../domain/moderation_labels.dart';
import 'moderation_ui.dart';

/// Couleur d'un type d'élément de la file : ban en revue = orange, à
/// examiner = cyan, refus à revoir = or, inconnu = gris.
Color queueKindColor(String kind) => switch (kind) {
  'ban_en_revue' => ModerationColors.warning,
  'a_examiner' => ModerationColors.info,
  'refus_a_revoir' => ModerationColors.gold,
  _ => ModerationColors.neutral,
};

/// Couleur d'un statut de ban : en revue = orange, confirmé = rouge,
/// manuel = gris, levé = vert, écarté = gris.
Color banStatusColor(String? status) => switch (status) {
  'en_revue' => ModerationColors.warning,
  'confirme' => ModerationColors.danger,
  'leve' => ModerationColors.success,
  _ => ModerationColors.neutral,
};

/// Type d'un élément de la file (`kQueueKindLabels`).
class KindBadge extends StatelessWidget {
  const KindBadge({super.key, required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context) {
    return ModerationPill(
      label: queueKindLabel(kind),
      color: queueKindColor(kind),
    );
  }
}

/// Statut / origine d'un ban (`kBanStatusLabels` : « Auto — en revue »,
/// « Auto — confirmé », « Manuel »…). [label] remplace le libellé (ex.
/// « Manuel (issu d'un ban auto) », « auto »).
class BanOriginBadge extends StatelessWidget {
  const BanOriginBadge({
    super.key,
    required this.status,
    this.label,
    this.tooltip,
  });

  final String? status;
  final String? label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return ModerationPill(
      label: label ?? banStatusLabel(status),
      color: banStatusColor(status),
      tooltip: tooltip,
    );
  }
}

/// Texte de l'infobulle du conflit « ban manuel présent ».
const String kManualPresentTooltip =
    'Un ban humain a été posé pendant la revue : après une levée, la cible '
    'restera bannie (ban manuel).';

/// Conflit : un ban HUMAIN est aussi posé sur la cible (rouge). [label] :
/// « Ban manuel présent » (file) ou « + ban manuel » (listes).
class ManualPresentBadge extends StatelessWidget {
  const ManualPresentBadge({
    super.key,
    this.label = 'Ban manuel présent',
    this.tooltip = kManualPresentTooltip,
  });

  final String label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return ModerationPill(
      label: label,
      color: ModerationColors.danger,
      icon: Icons.person_off_outlined,
      tooltip: tooltip,
    );
  }
}

/// Catégorie de ban (`banCategoryLabel` : liste serveur [known], sinon
/// repli local, sinon « Injection IA », sinon le code).
class CategoryChip extends StatelessWidget {
  const CategoryChip({
    super.key,
    required this.code,
    this.known = const <BanCategory>[],
  });

  final String? code;
  final List<BanCategory> known;

  @override
  Widget build(BuildContext context) {
    return ModerationPill(
      label: banCategoryLabel(code, known),
      color: Theme.of(context).colorScheme.primary,
      icon: Icons.label_outline_rounded,
    );
  }
}
