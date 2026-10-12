// Tests purs (VM) de l'étape 3a de tools/PLAN_SUPABASE_CLES.md : la clé
// PUBLIQUE Supabase part dans l'en-tête `apikey` SEULEMENT, jamais en
// `Authorization: Bearer` (une clé publishable n'est pas un JWT : la
// plateforme la refuserait). Couvre l'aide pure, CHAQUE forme de requête de
// SupabaseSync (lectures PostgREST, comptages HEAD et GET, traductions,
// Edge Function admin-catalog) avec l'ancienne clé ET la nouvelle, et le
// câblage d'auth_service.dart (dart:html : lu comme texte). Clés FACTICES.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:mgt_admin/data/supabase_key_headers.dart';
import 'package:mgt_admin/data/supabase_sync.dart';

import 'support/http_fixtures.dart';

/// Clés FACTICES aux formes réelles : publishable et ancienne `anon` (JWT à
/// 3 segments).
const String _publishable = 'sb_publishable_ZZfauxFAUXfaux0123-_zz_ZZfaux01';
const String _legacyAnon =
    'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.ZmF1c3NlLXNpZ25hdHVyZQ';

const Map<String, String> _cles = <String, String>{
  'nouvelle clé publishable': _publishable,
  'ancienne clé anon': _legacyAnon,
};

/// Jeton admin de test (JWT à échéance future : sans lui, aucun appel à
/// admin-catalog ne part).
final String _jeton = testJwt();

SupabaseSync _sync(String key) => SupabaseSync(
  supabaseUrl: 'https://exemple.invalid',
  anonKey: key,
  catalogEndpoint: 'https://exemple.invalid/functions/v1/admin-catalog',
  adminToken: _jeton,
  retryDelays: const [Duration.zero, Duration.zero],
);

/// Littéral de chaîne qui NOMME l'en-tête Authorization, toute casse
/// (`'Authorization'`, `"authorization"`…). Les commentaires de lib/ écrivent
/// l'en-tête entre accents graves : non visés.
final RegExp _litteralAuthorization = RegExp(
  r'''['"]authorization['"]''',
  caseSensitive: false,
);

/// Littéral de chaîne qui COMMENCE par « Bearer », toute casse
/// (`'Bearer $x'`, `'Bearer ${x}'`, `'Bearer ' + x`).
final RegExp _litteralBearer = RegExp(
  r'''['"]bearer\b''',
  caseSensitive: false,
);

/// [req] porte [key] dans `apikey`, n'a AUCUN en-tête `Authorization`, et
/// [key] n'apparaît dans aucun autre en-tête.
void _expectCleDansApikeySeulement(http.Request req, String key) {
  final String quoi = '${req.method} ${req.url.path}';
  expect(req.headers['apikey'], key, reason: quoi);
  expect(
    req.headers.keys.map((String k) => k.toLowerCase()),
    isNot(contains('authorization')),
    reason: quoi,
  );
  for (final MapEntry<String, String> e in req.headers.entries) {
    if (e.key.toLowerCase() == 'apikey') continue;
    expect(e.value, isNot(contains(key)), reason: '$quoi, en-tête ${e.key}');
  }
}

/// Réponse neutre selon la requête : HEAD → total dans content-range,
/// Edge Function → objet JSON, PostgREST → liste vide.
http.Response _neutre(http.Request req) {
  if (req.method == 'HEAD') {
    return http.Response('', 200, headers: const {'content-range': '*/3'});
  }
  if (req.url.path.contains('/functions/v1/')) {
    return jsonResponse(<String, dynamic>{'ok': true});
  }
  return http.Response(
    '[]',
    200,
    headers: const {
      'content-range': '0-0/0',
      'content-type': 'application/json',
    },
  );
}

void main() {
  group('supabaseKeyHeaders (pur)', () {
    test('clé non vide → {apikey: clé} et rien d\'autre', () {
      expect(supabaseKeyHeaders(_publishable), <String, String>{
        'apikey': _publishable,
      });
      expect(supabaseKeyHeaders(_legacyAnon), <String, String>{
        'apikey': _legacyAnon,
      });
      expect(kSupabaseApiKeyHeader, 'apikey');
    });

    test('clé vide → aucun en-tête (panneau construit sans clé)', () {
      expect(supabaseKeyHeaders(''), isEmpty);
    });
  });

  for (final MapEntry<String, String> cle in _cles.entries) {
    group('SupabaseSync, ${cle.key} : apikey seulement', () {
      late List<http.Request> seen;
      setUp(() => seen = <http.Request>[]);

      Future<void> appel(Future<Object?> Function(SupabaseSync s) fn) =>
          withMock(seen, _neutre, () => fn(_sync(cle.value)));

      test('lectures PostgREST (jeux, contenus, contributeurs)', () async {
        await appel((SupabaseSync s) => s.fetchGames());
        await appel((SupabaseSync s) => s.fetchContents());
        await appel((SupabaseSync s) => s.fetchTopContributors());
        expect(seen, hasLength(3));
        for (final http.Request r in seen) {
          expect(r.url.path, startsWith('/rest/v1/'));
          _expectCleDansApikeySeulement(r, cle.value);
        }
      });

      test('comptages (HEAD et GET avec Prefer: count=exact)', () async {
        await appel((SupabaseSync s) => s.fetchTableCount('games'));
        await appel((SupabaseSync s) => s.countSuggestions());
        expect(seen.map((http.Request r) => r.method), <String>['HEAD', 'GET']);
        for (final http.Request r in seen) {
          expect(r.headers['Prefer'], 'count=exact');
          _expectCleDansApikeySeulement(r, cle.value);
        }
      });

      test('traductions (un jeu, puis toutes)', () async {
        await appel((SupabaseSync s) => s.fetchTranslationsForGame('g1'));
        await appel((SupabaseSync s) => s.fetchGameTranslationsAll());
        expect(seen, hasLength(2));
        for (final http.Request r in seen) {
          expect(r.url.path, '/rest/v1/game_translations');
          _expectCleDansApikeySeulement(r, cle.value);
        }
      });

      test('Edge Function admin-catalog : apikey + X-Admin-Token', () async {
        await appel((SupabaseSync s) => s.deleteGame('g1'));
        final http.Request r = seen.single;
        expect(isRoute(r, 'games/delete'), isTrue);
        expect(r.headers['X-Admin-Token'], _jeton);
        expect(r.headers['Content-Type'], startsWith('application/json'));
        _expectCleDansApikeySeulement(r, cle.value);
      });
    });
  }

  group('câblage (sources lues comme texte)', () {
    test('auth_service.dart : admin-login reçoit la clé par '
        'supabaseKeyHeaders, jamais en Authorization', () {
      final String src = File(
        'lib/core/auth/auth_service.dart',
      ).readAsStringSync();
      expect(src, contains('...supabaseKeyHeaders(anonKey)'));
      expect(src, isNot(contains(_litteralAuthorization)));
      expect(src, isNot(contains(_litteralBearer)));
    });

    test('aucun fichier de lib/ ne pose la clé publique en Bearer ni ne '
        'construit d\'en-tête Authorization', () {
      final List<File> dart = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .toList();
      expect(dart, isNotEmpty);
      for (final File f in dart) {
        final String src = f.readAsStringSync();
        expect(src, isNot(contains(_litteralAuthorization)), reason: f.path);
        expect(src, isNot(contains(_litteralBearer)), reason: f.path);
      }
    });
  });
}
