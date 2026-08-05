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
///
/// Layout : les colonnes « étroites » (case à cocher, nombres, premium,
/// actions) reçoivent une largeur fixe via [SizedBox] ; les colonnes « larges »
/// (Utilisateur, Titre, etc.) reçoivent un [Expanded] flex 1. L'ensemble est
/// enveloppé dans un scroll horizontal afin que le tableau reste lisible même
/// quand la somme des largeurs dépasse l'écran.
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

  /// Largeurs fixes (en px) par nom de colonne pour les colonnes « étroites ».
  /// Toute colonne absente de cette map est traitée comme une colonne large
  /// (Expanded flex 1). Le nom vide '' et le symbole '☐' désignent tous deux
  /// la colonne « case à cocher ».
  static const Map<String, double> _narrowWidths = {
    '': 50, // case à cocher (colonne sans libellé)
    '☐': 50, // case à cocher (sentinelle_screen)
    'Total': 70,
    'Rejets': 70,
    '% Rejets': 90,
    'Premium': 80,
    'Checked': 70,
    'Langue': 80,
    'Actions': 100,
  };

  /// Largeur minimale garantie pour chaque colonne large (Expanded).
  /// Évite qu'une colonne de texte ne s'écrase sur les écrans étroits ;
  /// déclenche alors le scroll horizontal.
  static const double _minWideWidth = 140;

  /// Marge intérieure horizontale commune à l'en-tête et aux lignes.
  static const double _horizontalPadding = 16;

  double? _fixedWidthFor(String name) => _narrowWidths[name];

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
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── En-tête ────────────────────────────────────────────────
              Container(
                color: dark
                    ? Colors.white.withValues(alpha: 0.03)
                    : Colors.black.withValues(alpha: 0.02),
                padding: const EdgeInsets.symmetric(
                  horizontal: _horizontalPadding,
                  vertical: 14,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (int idx = 0; idx < columns.length; idx++)
                      _buildHeaderCell(columns[idx], idx, mutedColor),
                  ],
                ),
              ),
              const Divider(height: 1, thickness: 1),
              // ── Lignes ─────────────────────────────────────────────────
              for (int i = 0; i < rows.length; i++)
                InkWell(
                  onTap: onRowTap != null ? () => onRowTap!(i) : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _horizontalPadding,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      border: i == rows.length - 1
                          ? null
                          : Border(bottom: BorderSide(color: border, width: 1)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        for (int idx = 0; idx < rows[i].length; idx++)
                          _buildBodyCell(rows[i][idx], idx),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Construit une cellule d'en-tête pour la colonne [name] (index [idx]).
  Widget _buildHeaderCell(String name, int idx, Color mutedColor) {
    final bool isSortable =
        onSort != null && !(nonSortableColumns?.contains(name) ?? false);
    final bool isActive = sortColumnIndex == idx;

    final Widget content = isSortable
        ? _SortableHeader(
            label: name,
            active: isActive,
            ascending: sortAscending,
            mutedColor: mutedColor,
            onTap: () => onSort!(idx),
          )
        : Text(
            name,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              color: mutedColor,
            ),
          );

    return _wrapCell(content, name);
  }

  /// Construit une cellule de données pour la colonne à l'index [idx].
  Widget _buildBodyCell(Widget cell, int idx) {
    final String colName = idx < columns.length ? columns[idx] : '';
    return _wrapCell(cell, colName);
  }

  /// Enveloppe une cellule selon le type de colonne :
  /// - colonne étroite → [SizedBox] de largeur fixe, contenu centré ;
  /// - colonne large → [Expanded] flex 1, contenu aligné à gauche, avec une
  ///   largeur minimale garantie pour éviter l'écrasement.
  Widget _wrapCell(Widget child, String colName) {
    final double? width = _fixedWidthFor(colName);

    if (width != null) {
      // Colonne étroite : largeur fixe, cellule centrée horizontalement.
      return SizedBox(
        width: width,
        child: Align(alignment: Alignment.center, child: child),
      );
    }

    // Colonne large : flexible, alignée à gauche, largeur minimale garantie.
    return Expanded(
      flex: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: _minWideWidth),
        child: Align(alignment: Alignment.centerLeft, child: child),
      ),
    );
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
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
      ),
    );
  }
}
