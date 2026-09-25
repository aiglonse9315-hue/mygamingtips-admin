import 'package:flutter/material.dart';

/// Les trois catégories arborescentes du catalogue de chaque jeu.
///
/// Conformément au cahier des charges, l'arborescence est :
/// Jeu > Video / Patch & MoD / Links.
///
/// §123 (25/09/2026) : la catégorie stockée `guides` est AFFICHÉE « Patch &
/// MoD » (vidéos de mises à jour, patchs, MAJ, mods ; libellé exact voulu
/// par le propriétaire au §125, avant « Patch and Mod ») — la valeur en base
/// ne change pas (compatibilité des anciennes versions de l'app).
enum ContentCategory {
  video,
  guides,
  links;

  /// Libellé affiché dans les onglets.
  String get label {
    switch (this) {
      case ContentCategory.video:
        return 'Vidéo';
      case ContentCategory.guides:
        return 'Patch & MoD';
      case ContentCategory.links:
        return 'Links';
    }
  }

  /// Icône associée (utilisée dans les onglets et cartes).
  IconData get icon {
    switch (this) {
      case ContentCategory.video:
        return Icons.smart_display_rounded;
      case ContentCategory.guides:
        return Icons.build_circle_rounded;
      case ContentCategory.links:
        return Icons.link_rounded;
    }
  }

  /// Couleur sémantique constante (cohérence jour/nuit).
  Color get color {
    switch (this) {
      case ContentCategory.video:
        return const Color(0xFFFF2D55);
      case ContentCategory.guides:
        return const Color(0xFF34C759);
      case ContentCategory.links:
        return const Color(0xFF00A3FF);
    }
  }

  static ContentCategory fromIndex(int i) {
    return ContentCategory.values[i.clamp(0, ContentCategory.values.length - 1)];
  }
}
