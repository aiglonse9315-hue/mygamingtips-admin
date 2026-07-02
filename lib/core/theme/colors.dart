import 'package:flutter/material.dart';

/// Palette de couleurs centralisée pour MyGamingTips.
///
/// Garantit une cohérence graphique entre le mode jour et le mode nuit.
/// Les accents néon (cyan / magenta / violet) sont constants : ce sont les
/// « brand colors » de l'application. Seule la surface change entre les thèmes.
class AppColors {
  AppColors._();

  // Accents néon constants (utilisés surtout en mode nuit).
  static const Color neonCyan = Color(0xFF00E5FF);
  static const Color neonMagenta = Color(0xFFFF2D95);
  static const Color neonViolet = Color(0xFF8A2BE2);
  static const Color neonGreen = Color(0xFF39FF14);

  // Couleur « Nitro » : violet/or, marque premium.
  static const Color nitro = Color(0xFFB026FF);
  static const Color nitroGold = Color(0xFFFFC93C);

  // Catégories — couleurs sémantiques partagées par les onglets Video / Guides / Links.
  static const Color categoryVideo = Color(0xFFFF2D55); // rouge YouTube-like
  static const Color categoryGuide = Color(0xFF34C759); // vert
  static const Color categoryLink = Color(0xFF00A3FF); // bleu

  // ---- Palette MODE JOUR ----
  static const Color lightBackground = Color(0xFFF5F7FB);
  static const Color lightSurface = Colors.white;
  static const Color lightSurfaceAlt = Color(0xFFEEF1F7);
  static const Color lightTextPrimary = Color(0xFF11131A);
  static const Color lightTextSecondary = Color(0xFF5A6172);
  static const Color lightBorder = Color(0xFFD9DEE9);
  static const Color lightAccent = Color(0xFF6A11CB); // violet profond jour

  // ---- Palette MODE NUIT ----
  static const Color darkBackground = Color(0xFF070912);
  static const Color darkSurface = Color(0xFF10131F);
  static const Color darkSurfaceAlt = Color(0xFF181C2B);
  static const Color darkTextPrimary = Color(0xFFEAF0FF);
  static const Color darkTextSecondary = Color(0xFF9AA3BD);
  static const Color darkBorder = Color(0xFF262C40);
}
