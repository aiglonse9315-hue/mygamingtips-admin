// Tests purs (VM) du §127 : origine des suggestions (colonne `source` —
// 'user' / 'vision' / 'scruteur') pour les filtres « Masquer Vision » et
// « Masquer Scruteur » du menu Suggestions. Lecture des lignes de la route
// EF suggestions/list, aller-retour du cache local, cache d'avant §127
// (sans `source`). Aucune dépendance dart:html.

import 'package:flutter_test/flutter_test.dart';

import 'package:mgt_admin/data/supabase_sync.dart';
import 'package:mgt_admin/domain/models/suggestion.dart';
import 'package:mgt_admin/domain/models/suggestion_author.dart';

Map<String, dynamic> _row(String id, String? source, {String? authorName}) => {
      'id': id,
      'url': 'https://youtu.be/$id',
      'status': 'pending',
      'shared_at': '2026-09-25T00:00:00Z',
      'author_id': source == 'user' ? 'u1' : null,
      'author': source == 'user' ? {'id': 'u1', 'display_name': 'Nono'} : null,
      'author_name': authorName,
      'source': source,
    };

void main() {
  group('§127 — origine des suggestions', () {
    test('suggestions/list : source lue telle quelle', () {
      final suggestions = SupabaseSync.mapSuggestionRows(<dynamic>[
        _row('v', 'vision', authorName: 'Vision'),
        _row('s', 'scruteur', authorName: 'Scruteur'),
        _row('u', 'user'),
        // Suggestion Vision sans signature (author_name null) : affichée
        // « Inconnu », masquée quand même (l'ancien filtre par nom la ratait).
        _row('v2', 'vision'),
      ]);
      expect(suggestions.map((s) => s.source).toList(),
          <String>['vision', 'scruteur', 'user', 'vision']);
      expect(suggestions[0].isFromVision, isTrue);
      expect(suggestions[1].isFromScruteur, isTrue);
      expect(suggestions[2].isFromVision || suggestions[2].isFromScruteur,
          isFalse);
      expect(suggestions[3].author.displayName, 'Inconnu');
      expect(suggestions[3].isFromVision, isTrue);
    });

    test('un joueur nommé « Scruteur » reste un utilisateur', () {
      final s = SupabaseSync.mapSuggestionRows(<dynamic>[
        {
          ..._row('u', 'user'),
          'author': {'id': 'u1', 'display_name': 'Scruteur'},
        },
      ]).single;
      expect(s.author.displayName, 'Scruteur');
      expect(s.source, Suggestion.sourceUser);
      expect(s.isFromScruteur, isFalse);
    });

    test('cache local : aller-retour et copyWith conservent la source', () {
      final s = Suggestion(
        id: 's1',
        url: 'https://example.com/guide',
        status: SuggestionStatus.pending,
        sharedAt: DateTime(2026, 9, 25),
        author: const SuggestionAuthor(id: '', displayName: 'Scruteur'),
        source: Suggestion.sourceScruteur,
      );
      final restored = Suggestion.fromJson(s.toJson());
      expect(restored.source, Suggestion.sourceScruteur);
      expect(
        restored.copyWith(status: SuggestionStatus.accepted).source,
        Suggestion.sourceScruteur,
      );
    });

    test('cache d\'avant §127 (sans source) : déduite du nom des bots', () {
      Suggestion cached(String name) => Suggestion.fromJson(<String, dynamic>{
            'id': name,
            'url': 'https://youtu.be/$name',
            'status': 'pending',
            'sharedAt': '2026-09-25T00:00:00.000',
            'author': <String, dynamic>{'id': '', 'displayName': name},
          });
      expect(cached('Vision').source, Suggestion.sourceVision);
      expect(cached('Scruteur').source, Suggestion.sourceScruteur);
      expect(cached('Nono').source, Suggestion.sourceUser);
    });

    test('valeur par défaut : utilisateur', () {
      final s = Suggestion(
        id: 's1',
        url: 'https://youtu.be/a',
        status: SuggestionStatus.pending,
        sharedAt: DateTime(2026, 9, 25),
        author: const SuggestionAuthor(id: 'u1', displayName: 'Nono'),
      );
      expect(s.source, Suggestion.sourceUser);
    });
  });
}
