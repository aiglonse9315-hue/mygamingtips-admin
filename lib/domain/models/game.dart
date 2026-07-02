import 'package:flutter/foundation.dart';

/// Un jeu du catalogue (version admin, sérialisable JSON).
@immutable
class Game {
  final String id;
  final String name;
  final String? coverUrl;
  final String? publisher;
  final bool active;
  final DateTime createdAt;

  const Game({
    required this.id,
    required this.name,
    this.coverUrl,
    this.publisher,
    this.active = true,
    required this.createdAt,
  });

  factory Game.fromJson(Map<String, dynamic> json) {
    return Game(
      id: json['id'] as String,
      name: json['name'] as String,
      coverUrl: json['coverUrl'] as String?,
      publisher: json['publisher'] as String?,
      active: (json['active'] as bool?) ?? true,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'coverUrl': coverUrl,
        'publisher': publisher,
        'active': active,
        'createdAt': createdAt.toIso8601String(),
      };

  Game copyWith({
    String? name,
    ValueGetter<String?>? coverUrl,
    ValueGetter<String?>? publisher,
    bool? active,
  }) {
    return Game(
      id: id,
      name: name ?? this.name,
      coverUrl: coverUrl != null ? coverUrl() : this.coverUrl,
      publisher: publisher != null ? publisher() : this.publisher,
      active: active ?? this.active,
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) => other is Game && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
