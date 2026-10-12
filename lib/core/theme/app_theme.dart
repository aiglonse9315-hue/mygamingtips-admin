import 'package:flutter/material.dart';
import 'colors.dart';

/// Thème du panneau d'administration web.
///
/// Reprise de l'ambiance néon de l'app mobile (cyan / magenta / violet) mais
/// adaptée à un usage desktop : fond sombre profond, surfaces nettes,
/// contrastes forts pour la lecture de tableaux de données. Le mode clair
/// reste disponible mais le panneau s'ouvre par défaut en mode sombre
/// (cohérent avec l'ambiance gaming).
class AdminTheme {
  AdminTheme._();

  static ThemeData get dark => _base(Brightness.dark);
  static ThemeData get light => _base(Brightness.light);

  static ThemeData _base(Brightness brightness) {
    final bool dark = brightness == Brightness.dark;

    final Color background = dark
        ? const Color(0xFF0A0D17)
        : const Color(0xFFF4F6FC);
    final Color surface =
        dark ? const Color(0xFF121624) : Colors.white;
    final Color surfaceAlt =
        dark ? const Color(0xFF1A1F31) : const Color(0xFFEEF1F8);
    final Color textPrimary =
        dark ? const Color(0xFFEAF0FF) : const Color(0xFF11131A);
    final Color textSecondary =
        dark ? const Color(0xFF97A1BD) : const Color(0xFF5A6172);
    final Color border =
        dark ? const Color(0xFF262C40) : const Color(0xFFD9DEE9);
    final Color accent =
        dark ? AppColors.neonViolet : AppColors.lightAccent;

    final ColorScheme scheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: Colors.white,
      secondary: AppColors.neonCyan,
      onSecondary: Colors.black,
      error: AppColors.categoryVideo,
      onError: Colors.white,
      surface: surface,
      onSurface: textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: surface,
      dividerColor: border,
      fontFamily: 'Roboto',
      textTheme: const TextTheme().apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceAlt,
        hintStyle: TextStyle(color: textSecondary),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        labelStyle: TextStyle(color: textSecondary, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: border, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: border, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: accent, width: 1.6),
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: border, width: 1),
        ),
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: TextStyle(
          color: textSecondary,
          fontWeight: FontWeight.w800,
          fontSize: 12,
          letterSpacing: 0.4,
        ),
        dataTextStyle: TextStyle(color: textPrimary, fontSize: 13),
        dividerThickness: 1,
      ),
      iconTheme: IconThemeData(color: textPrimary),
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accent,
          side: BorderSide(color: border),
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: accent),
      ),
      // Ascenseurs (demande du propriétaire, 12/10/2026) : le curseur
      // occupe TOUTE la largeur de sa colonne (aucune marge latérale) pour
      // être facile à attraper — avant : curseur de 8 px dans une colonne
      // plus large. Colonne et curseur toujours visibles, curseur plus clair
      // au survol et pendant le glisser.
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(kScrollbarThickness),
        crossAxisMargin: 0,
        radius: const Radius.circular(kScrollbarThickness / 2),
        interactive: true,
        thumbVisibility: const WidgetStatePropertyAll<bool>(true),
        trackVisibility: const WidgetStatePropertyAll<bool>(true),
        trackColor: WidgetStatePropertyAll<Color>(surfaceAlt),
        trackBorderColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        thumbColor: WidgetStateProperty.resolveWith<Color>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.dragged)) return accent;
          if (states.contains(WidgetState.hovered)) {
            return dark ? const Color(0xFF6B7598) : const Color(0xFF8A93A8);
          }
          return dark ? const Color(0xFF4A5270) : const Color(0xFFB4BBCB);
        }),
      ),
    );
  }

  /// Largeur des ascenseurs : celle de la colonne ET du curseur (marge
  /// latérale nulle).
  static const double kScrollbarThickness = 14;
}
