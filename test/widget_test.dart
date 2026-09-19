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

    test('AiRecommendation — fallback reject_reason (purge au ban, I-001)', () {
      // Purge chantier B : ni verdict ni reason, seulement reject_reason →
      // le motif doit être visible (board « Refusées »), verdict par défaut.
      final purged = AiRecommendation.fromJson(const {
        'reject_reason': 'Chaîne bannie',
      });
      expect(purged.reason, 'Chaîne bannie');
      expect(purged.verdict, AiVerdict.caution);

      // Analyse Sentinelle normale : reason prioritaire, JAMAIS écrasée par
      // un éventuel reject_reason résiduel.
      final analyzed = AiRecommendation.fromJson(const {
        'verdict': 'recommended',
        'confidence': 0.99,
        'reason': 'Tuto FR validé',
        'reject_reason': 'Chaîne bannie',
      });
      expect(analyzed.reason, 'Tuto FR validé');
      expect(analyzed.verdict, AiVerdict.recommended);

      // reason vide → fallback actif ; les deux absentes → chaîne vide
      // (comportement d'avant le fix, inchangé).
      final emptyReason = AiRecommendation.fromJson(const {
        'reason': '',
        'reject_reason': 'Chaîne bannie',
      });
      expect(emptyReason.reason, 'Chaîne bannie');
      final nothing = AiRecommendation.fromJson(const {'verdict': 'caution'});
      expect(nothing.reason, '');
    });
  });
}
