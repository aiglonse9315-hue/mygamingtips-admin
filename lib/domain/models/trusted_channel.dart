import 'package:flutter/foundation.dart';

/// Une chaîne YouTube de confiance associée à un jeu (table
/// `trusted_channels`), telle que retournée par la route EF
/// `trusted-channels/list`.
///
/// Ces chaînes alimentent la collecte (Snifeur / Vision) : seules les vidéos
/// des chaînes actives sont exploitées pour le jeu correspondant. Une même
/// chaîne (handle) peut être liée à PLUSIEURS jeux (une ligne par jeu).
@immutable
class TrustedChannel {
  const TrustedChannel({
    required this.id,
    required this.gameId,
    required this.gameName,
    required this.channelHandle,
    this.channelId,
    this.channelName,
    this.langs = const <String>[],
    this.active = true,
    this.source = 'admin',
    this.createdAt,
  });

  /// Identifiant de la ligne (UUID Supabase).
  final String id;

  /// Jeu associé (FK games.id) + son nom (dénormalisé par la route list).
  final String gameId;
  final String gameName;

  /// Handle YouTube canonique (ex. `@JoueurDuGrenier`), préfixe `@` inclus.
  final String channelHandle;

  /// Identifiant YouTube technique de la chaîne (UC...), si résolu.
  final String? channelId;

  /// Nom d'affichage de la chaîne (optionnel).
  final String? channelName;

  /// Codes langue majuscules exploités sur cette chaîne (FR, EN, ...).
  final List<String> langs;

  /// Chaîne active : une chaîne désactivée est conservée mais ignorée par
  /// les bots de collecte.
  final bool active;

  /// Provenance de la ligne : `const` (liste seedée en dur), `snifeur`
  /// (découverte automatique) ou `admin` (ajout manuel via ce panneau).
  final String source;

  /// Date de création de la ligne (null si absente/invalide côté serveur).
  final DateTime? createdAt;

  factory TrustedChannel.fromJson(Map<String, dynamic> json) {
    final rawLangs = json['langs'];
    return TrustedChannel(
      id: json['id']?.toString() ?? '',
      gameId: json['game_id']?.toString() ?? '',
      gameName: json['game_name']?.toString() ?? '—',
      channelHandle: json['channel_handle']?.toString() ?? '',
      channelId: json['channel_id']?.toString(),
      channelName: json['channel_name']?.toString(),
      langs: rawLangs is List
          ? rawLangs.map((e) => e.toString()).toList()
          : const <String>[],
      active: json['active'] == true,
      source: json['source']?.toString() ?? 'admin',
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }
}
