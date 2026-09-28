// Tuile d'un élément de la file de revue (P4b-3, lot L5, conception §6.3,
// §6.9) : type, cible, raisons, groupe, acteur, auteur du partage, preuve,
// conflit « ban manuel présent », boutons selon `actionsForQueueItem`.
//
// Les textes de la cible (nom du compte, clé de chaîne, URL de page) et le
// nom de l'acteur sont NON FIABLES : aperçu sur une ligne, caractères cachés
// rendus visibles, jamais cliquables.
//
// Widget « de présentation » (aucun Provider) → testable en VM. Clés des
// boutons : `moderation-action-<id>-<action>` (ex. `moderation-action-7-lift`).
import 'package:flutter/material.dart';

import '../../../domain/ids.dart';
import '../../../domain/models/moderation.dart';
import '../../../domain/moderation_actions.dart';
import '../../../domain/moderation_labels.dart';
import '../../../domain/moderation_text.dart';
import 'moderation_ui.dart';
import 'reason_chips.dart';
import 'status_badges.dart';

/// Libellé court de la cible d'un élément de la file (aussi `<cible>` des
/// dialogues de décision, §6.4 b) : compte → nom (ou « (profil supprimé) »)
/// · id court ; chaîne → plateforme · clé ; page → URL ; tout révélé.
String reviewItemTargetLabel(ReviewItem item, {int max = 60}) {
  final String key = item.targetKey ?? '';
  switch (item.targetKind) {
    case 'account':
      final String name = oneLinePreview(
        item.accountDisplayName ?? '(profil supprimé)',
        max: max,
      );
      return key.isEmpty ? name : '$name · ${oneLinePreview(shortId(key))}';
    case 'channel':
      return '${platformLabel(item.platform)} · '
          '${key.isEmpty ? '—' : oneLinePreview(key, max: max)}';
    default:
      return key.isEmpty ? '—' : oneLinePreview(key, max: max);
  }
}

IconData _targetIcon(String kind) => switch (kind) {
  'account' => Icons.person_outline_rounded,
  'channel' => Icons.smart_display_outlined,
  'page' => Icons.language_rounded,
  _ => Icons.help_outline_rounded,
};

class ReviewQueueTile extends StatelessWidget {
  const ReviewQueueTile({
    super.key,
    required this.item,
    required this.busy,
    required this.onAction,
  });

  final ReviewItem item;

  /// Une décision est en cours sur cette tuile : boutons désactivés.
  final bool busy;
  final void Function(ReviewAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle small = theme.textTheme.bodySmall ?? const TextStyle();
    final List<ReviewAction> actions = actionsForQueueItem(item.kind);
    final String? author = item.suggestionAuthorId;
    final String? actor = item.actorUsername;

    return Card(
      key: ValueKey<String>('moderation-tile-${item.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // Ligne 1 : type · cible · date · #id.
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                KindBadge(kind: item.kind),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(_targetIcon(item.targetKind), size: 16),
                    const SizedBox(width: 4),
                    Text(
                      targetKindLabel(item.targetKind),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                Text(formatModerationDate(item.createdAt), style: small),
                Text('#${item.id}', style: small),
                if (item.manualBanPresent) const ManualPresentBadge(),
              ],
            ),
            const SizedBox(height: 6),
            // Ligne 2 : cible (texte non fiable, une ligne).
            _target(),
            const SizedBox(height: 6),
            // Ligne 3 : raisons, groupe, acteur, auteur, preuve.
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                ReasonChips(codes: item.reasons),
                if (item.groupSize > 1)
                  Text('Groupe : ${item.groupSize}', style: small),
                if (actor != null && actor.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: UntrustedLine('par $actor', max: 44, style: small),
                  ),
                if (author != null &&
                    author.isNotEmpty &&
                    item.targetKind != 'account')
                  Text(
                    'Auteur du partage : ${oneLinePreview(shortId(author))}',
                    style: small,
                  ),
                if (item.hasEvidence)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(Icons.description_outlined, size: 14),
                      const SizedBox(width: 4),
                      Text('Preuve conservée', style: small),
                    ],
                  )
                else
                  Text(
                    'sans preuve',
                    style: small.copyWith(color: ModerationColors.neutral),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  for (final ReviewAction a in actions)
                    reviewActionButton(
                      a,
                      key: ValueKey<String>(
                        'moderation-action-${item.id}-${a.name}',
                      ),
                      onPressed: busy ? null : () => onAction(a),
                    ),
                  if (busy) kButtonSpinner,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _target() {
    const TextStyle style = TextStyle(fontSize: 13);
    final String key = item.targetKey ?? '';
    switch (item.targetKind) {
      case 'account':
        return Row(
          children: <Widget>[
            Flexible(
              child: UntrustedLine(
                item.accountDisplayName ?? '(profil supprimé)',
                key: const Key('moderation-tile-target'),
                max: 60,
                style: style.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              ' · ${key.isEmpty ? '—' : oneLinePreview(shortId(key))}',
              style: style.copyWith(fontFamily: 'monospace'),
            ),
          ],
        );
      case 'channel':
        return Row(
          children: <Widget>[
            Text('${platformLabel(item.platform)} · ', style: style),
            Expanded(
              child: UntrustedLine(
                key.isEmpty ? '—' : key,
                key: const Key('moderation-tile-target'),
                max: 60,
                monospace: true,
                style: style,
              ),
            ),
          ],
        );
      default:
        return UntrustedLine(
          key.isEmpty ? '—' : key,
          key: const Key('moderation-tile-target'),
          max: 120,
          monospace: true,
          style: style,
        );
    }
  }
}
