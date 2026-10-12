// En-tête de la clé PUBLIQUE Supabase envoyée par le panneau (étape 3a de
// tools/PLAN_SUPABASE_CLES.md, 12/10/2026). Pur : aucune dépendance
// dart:html, testable en VM.
//
// La clé publique (ancienne `anon`, puis la publishable `sb_publishable_…`
// après l'étape 3b) va UNIQUEMENT dans l'en-tête `apikey` :
//   - la clé publishable n'est pas un jeton signé : envoyée en
//     `Authorization: Bearer`, la plateforme tente de la lire comme un JWT et
//     la refuse (doc Supabase « Migrating to publishable and secret API
//     keys ») ;
//   - avec `apikey` seul, la passerelle fournit elle-même le jeton du rôle
//     `anon` à PostgREST (ancienne clé recopiée telle quelle, nouvelle clé
//     remplacée par un jeton interne) : lectures et RLS inchangées ;
//   - les Edge Functions du panneau (admin-login, admin-catalog) tournent
//     sans « Verify JWT » : la passerelle ne regarde ni `apikey` ni
//     `Authorization` ; admin-catalog lit le jeton admin dans `X-Admin-Token`.
// `Authorization` reste réservé aux sessions Supabase Auth, que le panneau
// n'utilise pas.

/// Nom de l'en-tête qui porte la clé publique.
const String kSupabaseApiKeyHeader = 'apikey';

/// En-tête de la clé publique [key] : `{apikey: key}`, ou rien si [key] est
/// vide (panneau construit sans clé : aperçu local, configuration absente).
/// Jamais d'en-tête `Authorization`.
Map<String, String> supabaseKeyHeaders(String key) =>
    key.isEmpty ? const <String, String>{} : {kSupabaseApiKeyHeader: key};
