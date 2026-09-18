import 'package:flutter/foundation.dart';

/// Une demande de sync totale BDD→local (table `sync_requests`, migration
/// 0063 — chantier C, décision §70.1), telle que retournée par les routes
/// EF `sync/request`, `sync/status` et `sync/pending`.
///
/// Sémantique anti-pile-up : il n'existe qu'UNE demande « chaude » — l'EF
/// ré-horodate la plus récente si elle a moins de 24 h (même [id], nouveau
/// [createdAt]) au lieu d'empiler des lignes.
@immutable
class SyncRequestInfo {
  const SyncRequestInfo({
    required this.id,
    required this.scope,
    this.requestedBy,
    required this.createdAt,
  });

  /// Identifiant de la demande (bigserial).
  final int id;

  /// Périmètre de la sync ('catalog' aujourd'hui).
  final String scope;

  /// Username du compte admin demandeur (null si non renseigné).
  final String? requestedBy;

  /// Horodatage SERVEUR de la demande (ré-horodaté à chaque nouveau clic
  /// tant que la demande a moins de 24 h).
  final DateTime createdAt;

  factory SyncRequestInfo.fromJson(Map<String, dynamic> json) {
    return SyncRequestInfo(
      id: (json['id'] as num?)?.toInt() ?? 0,
      scope: json['scope']?.toString() ?? 'catalog',
      requestedBy: json['requested_by']?.toString(),
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Acquittement d'une machine Vision pour une demande de sync (table
/// `sync_acks`) : 1 ligne par couple (request_id × machine_id).
@immutable
class SyncAckInfo {
  const SyncAckInfo({
    required this.machineId,
    required this.ackedAt,
    this.report,
  });

  /// Identifiant local stable de la machine Vision (uuid v4 persisté dans
  /// %LOCALAPPDATA%\vision_machine_id.json).
  final String machineId;

  /// Horodatage SERVEUR de l'acquittement (mis à jour si la machine
  /// ré-acquitte la même demande ré-horodatée).
  final DateTime ackedAt;

  /// Rapport jsonb posté par le bot : {aliases:{…}, channels:{…},
  /// translations:{…}, errors:[…]} — null si absent.
  final Map<String, dynamic>? report;

  factory SyncAckInfo.fromJson(Map<String, dynamic> json) {
    final rawReport = json['report'];
    return SyncAckInfo(
      machineId: json['machine_id']?.toString() ?? '',
      ackedAt: DateTime.tryParse(json['acked_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      report: rawReport is Map<String, dynamic> ? rawReport : null,
    );
  }
}

/// Réponse de la route EF `sync/status` : la dernière demande (null si
/// aucune n'a jamais été posée) et TOUS ses acquittements par machine.
@immutable
class SyncStatusResult {
  const SyncStatusResult({this.request, this.acks = const []});

  /// Dernière demande posée (ré-horodatée si « chaude »).
  final SyncRequestInfo? request;

  /// Acquittements de cette demande, par machine.
  final List<SyncAckInfo> acks;
}
