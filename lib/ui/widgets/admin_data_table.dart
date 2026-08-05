import 'package:flutter/material.dart';

/// Tableau de données responsive et stylisé.
///
/// [columns] : libellés d'en-tête.
/// [rows] : chaque ligne est une liste de cellules (Widget).
/// [onRowTap] : callback optionnel par ligne.
///
/// Tri optionnel : si [onSort] est fourni, les en-têtes deviennent cliquables.
/// [sortColumnIndex] indique la colonne actuellement triée (null = aucune).
/// [sortAscending] indique le sens du tri (true = croissant).
/// Si [onSort] est null (autres écrans), les en-têtes restent du texte simple.
class AdminDataTable extends StatelessWidget {
  const AdminDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.onRowTap,
    this.sortColumnIndex,
    this.sortAscending = true,
    this.onSort,
    /// Index des colonnes non triables (ex: Actions). Ignorés si onSort est null.
    this.nonSortableColumns,
  });

  final List<String> columns;
  final List<List<Widget>> rows;
  final void Function(int index)? onRowTap;

  /// Index de la colonne triée (null = aucune colonne active).
  final int? sortColumnIndex;

  /// Sens du tri : true = croissant, false = décroissant.
  final bool sortAscending;

  /// Callback appelé quand l'utilisateur tape sur une en-tête triable.
  final void Function(int columnIndex)? onSort;

  /// Noms des colonnes qui ne doivent pas être triables.
  final List<String>? nonSortableColumns;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color border = Theme.of(context).dividerColor;
    final Color mutedColor =
        Theme.of(context).textTheme.bodySmall?.color ?? Colors.grey;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).canvasColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // En-tête
          Container(
            color: dark
                ? Colors.white.withValues(alpha: 0.03)
                : Colors.black.withValues(alpha: 0.02),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: columns
                  .asMap()
                  .entries
                  .map((entry) {
                    final int idx = entry.key;
                    final String c = entry.value;
                    final bool isSortable = onSort != null &&
                        !(nonSortableColumns?.contains(c) ?? false);
                    final bool isActive = sortColumnIndex == idx;

                    // Flex adaptatif : colonnes étroites (checkbox, actions,
                    // nombres courts) prennent moins d'espace que le texte.
                    final int flex;
                    if (c.isEmpty || c == 'Actions') {
                      flex = 0; // Checkbox et boutons : largeur minimale.
                    } else if (c == 'Premium' || c == 'Checked' ||
                               c == 'Langue' || c == 'Total' ||
                               c == 'Rejets' || c == '% Rejets') {
                      flex = 0; // Colonnes courtes : largeur du contenu.
                    } else {
                      flex = 1; // Texte long (Utilisateur, Titre, etc.).
                    }

                    return Expanded(
                      flex: flex,
                      child: Align(
                        alignment: flex == 0
                            ? Alignment.center
                            : Alignment.centerLeft,
                        child: isSortable
                          ? _SortableHeader(
                              label: c,
                              active: isActive,
                              ascending: sortAscending,
                              mutedColor: mutedColor,
                              onTap: () => onSort!(idx),
                            )
                          : Text(
                              c,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                                color: mutedColor,
                              ),
                            ),
                      ),
                    );
                  })
                  .toList(),
            ),
          ),
          const Divider(height: 1),
          // Lignes
          ...List.generate(rows.length, (i) {
            final bool last = i == rows.length - 1;
            return InkWell(
              onTap: onRowTap != null ? () => onRowTap!(i) : null,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: last
                      ? null
                      : Border(
                          bottom: BorderSide(
                            color: border,
                            width: 1,
                          ),
                        ),
                ),
                child: Row(
                  children: rows[i]
                      .asMap()
                      .entries
                      .map((entry) {
                        final int idx = entry.key;
                        final Widget cell = entry.value;
                        final String colName = idx < columns.length ? columns[idx] : '';
                        final int flex = _flexForColumn(colName);
                        return Expanded(
                          flex: flex,
                          child: Align(
                            alignment: flex == 0
                                ? Alignment.center
                                : Alignment.centerLeft,
                            child: cell,
                          ),
                        );
                      })
                      .toList(),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  /// Flex adaptatif selon le nom de la colonne (même logique que les en-têtes).
  int _flexForColumn(String colName) {
    if (colName.isEmpty || colName == 'Actions') return 0;
    if (colName == 'Premium' || colName == 'Checked' ||
        colName == 'Langue' || colName == 'Total' ||
        colName == 'Rejets' || colName == '% Rejets') return 0;
    return 1;
  }
}

/// En-tête de colonne triable : texte + icône de sens.
class _SortableHeader extends StatelessWidget {
  const _SortableHeader({
    required this.label,
    required this.active,
    required this.ascending,
    required this.mutedColor,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool ascending;
  final Color mutedColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color activeColor = Theme.of(context).colorScheme.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: active ? activeColor : mutedColor,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            active
                ? (ascending
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded)
                : Icons.unfold_more_rounded,
            size: 14,
            color: active ? activeColor : mutedColor.withValues(alpha: 0.4),
          ),
        ],
      ),
    );
  }
}
