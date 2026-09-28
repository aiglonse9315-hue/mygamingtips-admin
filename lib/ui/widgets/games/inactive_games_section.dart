// Section « Jeux inactifs (N) » de l'écran Jeux (P4b-3, lot L9, D2, T7,
// conception §6.13, §6.14). Les jeux inactifs ne sont jamais dans le
// tableau principal (la lecture publique ne voit que les actifs) : ils sont
// lus au serveur (`games/list {active:false}`) à l'ouverture du menu et sur
// « Recharger » ; en aperçu, ce sont les jeux locaux inactifs.
//
// Repliable (ouverte au premier affichage s'il y a au moins un jeu inactif,
// ou une erreur à montrer) ; états : chargement, erreur (« Liste des jeux
// inactifs illisible : <msg>. » + « Réessayer »), vide (« Aucun jeu
// inactif. »), tableau Jeu · Éditeur · Contenus · Actions. Actions :
// « Réactiver » (SANS confirmation, D2), « Modifier », « Supprimer »
// (confirmation de l'écran). Un jeu en cours de création (id temporaire en
// production) a « Réactiver » et « Modifier » désactivés.
//
// Widget « de présentation » (aucun Provider) → testable en VM. Clés :
// `games-inactive-section`, `games-inactive-reload`, `games-inactive-retry`,
// `games-inactive-error`, `games-inactive-empty`,
// `games-inactive-reactivate-<id>`, `games-inactive-edit-<id>`,
// `games-inactive-delete-<id>`.
import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../domain/games_screen_rules.dart';
import '../../../domain/models/game.dart';
import '../admin_data_table.dart';

class InactiveGamesSection extends StatelessWidget {
  const InactiveGamesSection({
    super.key,
    required this.games,
    required this.total,
    required this.loading,
    required this.error,
    required this.hasSync,
    required this.busyIds,
    required this.contentCountLabel,
    required this.onReload,
    required this.onReactivate,
    required this.onEdit,
    required this.onDelete,
  });

  /// Jeux inactifs AFFICHÉS (déjà filtrés par la recherche de l'écran).
  final List<Game> games;

  /// Nombre total de jeux inactifs (avant la recherche) : ouverture de la
  /// section.
  final int total;

  /// Lecture en cours.
  final bool loading;

  /// Message de la dernière lecture en échec (null si réussie).
  final String? error;

  /// Connexion au serveur (false = aperçu : aucune écriture bloquée).
  final bool hasSync;

  /// Jeux dont une écriture est en cours (indicateur sur « Réactiver »).
  final Set<String> busyIds;

  /// Texte de la colonne « Contenus ».
  final String Function(Game game) contentCountLabel;

  final VoidCallback onReload;
  final void Function(Game game) onReactivate;
  final void Function(Game game) onEdit;
  final void Function(Game game) onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool open = inactiveSectionOpen(
      total: total,
      hasError: error != null,
    );
    return ExpansionTile(
      // La clé suit l'ouverture automatique : la section s'ouvre quand des
      // jeux inactifs (ou une erreur) arrivent après un premier affichage
      // vide ; un repli manuel est gardé tant que cet état ne change pas.
      key: ValueKey<String>(
        'games-inactive-section-${open ? 'open' : 'closed'}',
      ),
      initiallyExpanded: open,
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      childrenPadding: const EdgeInsets.only(bottom: 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: Row(
        key: const Key('games-inactive-section'),
        children: <Widget>[
          Text(
            inactiveGamesTitle(games.length),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          if (loading) ...<Widget>[
            const SizedBox(width: 10),
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
          const Spacer(),
          TextButton.icon(
            key: const Key('games-inactive-reload'),
            onPressed: loading ? null : onReload,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Recharger'),
          ),
        ],
      ),
      children: <Widget>[_body(theme)],
    );
  }

  Widget _body(ThemeData theme) {
    final List<Widget> parts = <Widget>[];
    final String? err = error;
    if (err != null) {
      parts.add(
        Row(
          children: <Widget>[
            Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                inactiveGamesErrorText(err),
                key: const Key('games-inactive-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const Key('games-inactive-retry'),
              onPressed: loading ? null : onReload,
              child: const Text('Réessayer'),
            ),
          ],
        ),
      );
    }
    if (games.isEmpty) {
      if (loading) {
        parts.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
          ),
        );
      } else if (err == null) {
        parts.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Text(
              kNoInactiveGamesText,
              key: const Key('games-inactive-empty'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        );
      }
    } else {
      if (parts.isNotEmpty) parts.add(const SizedBox(height: 8));
      parts.add(
        AdminDataTable(
          columns: const <String>['Jeu', 'Éditeur', 'Contenus', 'Actions'],
          rows: <List<Widget>>[for (final Game g in games) _row(theme, g)],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: parts,
    );
  }

  List<Widget> _row(ThemeData theme, Game g) {
    final bool blocked = gameWriteBlocked(g, hasSync: hasSync);
    final bool busy = busyIds.contains(g.id);
    final String? publisher = g.publisher?.trim();
    final Widget reactivate = FilledButton.tonal(
      key: ValueKey<String>('games-inactive-reactivate-${g.id}'),
      onPressed: blocked || busy ? null : () => onReactivate(g),
      child: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('Réactiver'),
    );
    return <Widget>[
      Text(
        g.name,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      ),
      Text(
        publisher == null || publisher.isEmpty ? '—' : publisher,
        style: TextStyle(fontSize: 13, color: theme.textTheme.bodySmall?.color),
      ),
      Text(
        contentCountLabel(g),
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      ),
      Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          blocked
              ? Tooltip(message: kGameWriteBlockedTooltip, child: reactivate)
              : reactivate,
          IconButton(
            key: ValueKey<String>('games-inactive-edit-${g.id}'),
            tooltip: blocked ? kGameWriteBlockedTooltip : 'Modifier',
            icon: const Icon(Icons.edit_outlined, size: 20),
            onPressed: blocked || busy ? null : () => onEdit(g),
          ),
          IconButton(
            key: ValueKey<String>('games-inactive-delete-${g.id}'),
            tooltip: 'Supprimer',
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            color: AppColors.categoryVideo,
            onPressed: busy ? null : () => onDelete(g),
          ),
        ],
      ),
    ];
  }
}
