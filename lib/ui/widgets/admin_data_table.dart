import 'package:flutter/material.dart';

/// Tableau de données responsive et stylisé.
///
/// [columns] : libellés d'en-tête.
/// [rows] : chaque ligne est une liste de cellules (Widget).
/// [onRowTap] : callback optionnel par ligne.
class AdminDataTable extends StatelessWidget {
  const AdminDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.onRowTap,
  });

  final List<String> columns;
  final List<List<Widget>> rows;
  final void Function(int index)? onRowTap;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color border = Theme.of(context).dividerColor;

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
                  .map((c) => Expanded(
                        flex: c == 'Actions' ? 0 : 1,
                        child: Text(
                          c,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color:
                                Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ),
                      ))
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
                      .map((cell) => Expanded(
                            flex: _flexFor(columns, cell),
                            child: cell,
                          ))
                      .toList(),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // Les colonnes d'actions (boutons) prennent une largeur fixe.
  int _flexFor(List<String> columns, Widget cell) {
    // Heuristique : les cellules contenant des boutons restent compactes.
    return 1;
  }
}
