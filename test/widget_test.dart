// Test minimal du panneau admin : vérifie la sérialisation JSON des modèles.

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/domain/models/category.dart';
import 'package:mgt_admin/domain/models/content.dart';
import 'package:mgt_admin/domain/models/game.dart';
import 'package:mgt_admin/domain/models/suggestion.dart';
import 'package:mgt_admin/domain/models/suggestion_author.dart';

void main() {
  group('Sérialisation JSON', () {
    test('Game round-trip', () {
      final Game g = Game(
        id: 'g1',
        name: 'Test',
        publisher: 'Pub',
        active: true,
        createdAt: DateTime(2026, 1, 1),
      );
      final Game g2 = Game.fromJson(g.toJson());
      expect(g2.id, 'g1');
      expect(g2.name, 'Test');
      expect(g2.publisher, 'Pub');
      expect(g2.active, isTrue);
    });

    test('Content round-trip + displayTitle', () {
      final Content c = Content(
        id: 'c1',
        gameId: 'g1',
        category: ContentCategory.video,
        url: 'https://youtu.be/abc',
        titleAdmin: 'Titre admin',
        publishedAt: DateTime(2026, 1, 1),
        isVideo: true,
      );
      final Content c2 = Content.fromJson(c.toJson());
      expect(c2.category, ContentCategory.video);
      expect(c2.displayTitle, 'Titre admin');
      expect(c2.isVideo, isTrue);
    });

    test('Suggestion round-trip', () {
      final Suggestion s = Suggestion(
        id: 's1',
        url: 'https://example.com',
        status: SuggestionStatus.pending,
        sharedAt: DateTime(2026, 1, 1),
        author: const SuggestionAuthor(
            id: 'g1', displayName: 'Test', email: 't@t.fr'),
      );
      final Suggestion s2 = Suggestion.fromJson(s.toJson());
      expect(s2.status, SuggestionStatus.pending);
      expect(s2.url, 'https://example.com');
      expect(s2.author.id, 'g1');
      expect(s2.author.displayName, 'Test');
    });
  });
}
