import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_languages.dart';

/// Badge compact affichant le code langue + drapeau + couleur sémantique.
///
/// Utilisé sur les cartes de contenu, les lignes de tableau admin, etc.
/// Remplace les cascades `== 'FR' ? blue : == 'EN' ? red : grey` dupliquées
/// dans ~5 fichiers (content_card, contents_screen, etc.).
class LanguageBadge extends StatelessWidget {
  const LanguageBadge({
    super.key,
    required this.languageCode,
    this.size = BadgeSize.standard,
  });

  /// Code langue stocké en base (`'FR'`, `'EN'`, `'JA'`...) ou `null`.
  final String? languageCode;

  /// Taille du badge (standard pour les cartes, small pour les cellules).
  final BadgeSize size;

  @override
  Widget build(BuildContext context) {
    final lang = findLanguage(languageCode);
    if (lang == null) {
      // Langue non reconnue ou null : badge discret « — ».
      return _buildShell(
        context,
        text: languageCode?.toUpperCase() ?? '—',
        color: Theme.of(context).disabledColor,
        flag: null,
      );
    }
    return _buildShell(
      context,
      text: lang.code,
      color: lang.color,
      flag: lang.flag,
    );
  }

  Widget _buildShell(
    BuildContext context, {
    required String text,
    required Color color,
    required String? flag,
  }) {
    final isSmall = size == BadgeSize.small;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isSmall ? 6 : 8,
        vertical: isSmall ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(isSmall ? 6 : 8),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (flag != null) ...[
            Text(flag, style: TextStyle(fontSize: isSmall ? 10 : 12)),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: isSmall ? 10 : 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

enum BadgeSize { small, standard }
