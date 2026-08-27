// ============================================================================
// MyGamingTips — Edge Function Supabase "admin-catalog" (v60)
// ============================================================================
// Opérations d'écriture administrateur sur le catalogue (jeux, contenus,
// suggestions, profils bannis, abonnements). Contourne la RLS via
// service_role. L'accès est protégé par vérification du JWT admin émis par
// la fonction "admin-login".
//
// Déploiement : supabase functions deploy admin-catalog
// Secrets requis (fournis automatiquement par Supabase) :
//   - SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//   - MGT_ADMIN_JWT_SECRET (SEUL secret jetons admin — Phase 4.4 Phase B :
//     transition terminée, l'ancien JWT_SECRET n'est plus lu)
//
// Endpoints (tous POST, body JSON, header Authorization: Bearer <jwt>) :
//   POST /games            → upsert jeu (create ou update)
//   POST /games/delete     → supprimer un jeu + cascade contenus
//   POST /contents         → upsert contenu (create/update)
//   POST /suggestions/accept → valider une suggestion (crée un contenu)
//   POST /suggestions/accept-batch → valider un LOT de suggestions (max 100)
//     en 1 appel — « Tout valider » Sentinelle (27/08/2026). Idempotent :
//     skip non-pending + pas de doublon de contenu (couple url+game_id).
//   POST /suggestions/reject → rejeter une suggestion
//   POST /suggestions/delete → supprimer définitivement une suggestion pending
//   POST /suggestions/ai-recommend → écrire la recommandation IA Sentinelle
//   POST /profiles/ban     → bannir un utilisateur (is_banned = true)
//   POST /profiles/unban   → lever un ban (is_banned = false)
//   POST /subscriptions/upsert → créer/modifier un abonnement Plus manuel
//   POST /suggestions/list → lecture suggestions par mode (service_role)
//     modes : new, analyzing, analyzed, games-to-create, scruteur, user-links-pending, pending-no-ai
//   POST /suggestions/insert → insertion suggestion bot (Vision/Scruteur) :
//     body.source ('vision'|'scruteur'), author_name, ai_recommendation optionnel
//   POST /suggestions/urls → URLs de toutes les suggestions, paginé (anti-doublons Vision)
//     paramètre optionnel `since` (ISO 8601) : sync incrémentale du cache
//     local Vision (shared_at >= since)
//   POST /cache-ops/list → journal des opérations add/remove d'URLs
//     (migration 0051) — paramètre optionnel `since` (ISO 8601) ; permet à
//     Vision.exe de maintenir son cache local anti-doublons À L'IDENTIQUE
//     de la base, y compris les suppressions (que la sync par created_at
//     ne voit pas).
//   POST /profiles/find-by-email → résolution email → UUID (service_role)
//
// JOURNALISATION cache_ops (v58) : chaque route qui ajoute ou supprime une
// URL du périmètre anti-doublons écrit une ligne dans cache_ops :
//   add    ← contents (upsert), suggestions/insert, suggestions/accept,
//            blocked-urls/insert-batch
//   remove ← contents/delete, contents/delete-batch, games/delete (cascade),
//            suggestions/delete (Sentinelle libère une pending → l'URL
//            redevient candidate)
//   suggestions/reject ne journalise PAS : l'URL reste volontairement dans
//   le cache pour ne jamais reproposer un lien refusé.
// La journalisation est NON BLOQUANTE : un échec est loggé, jamais retourné.
//
// v59 (migration 0052) : chaque ligne journalisée porte désormais un `src`
// ('contents' | 'suggestions' | 'blocked') — permet à l'APP MOBILE de ne
// rejouer QUE les suppressions de contenus (RPC cache_ops_removals_since)
// sans risquer de supprimer un contenu valide à cause d'un « remove »
// provenant de suggestions/delete.
//
// v60 (27/08/2026) : nouvelle route POST /suggestions/accept-batch —
// validation EN LOT des suggestions Sentinelle (max 100 items/appel,
// idempotente : skip non-pending + garde anti-doublon sur url+game_id).
// Correctif passation §25 (3-C) : « Tout valider » ne déclenche plus N
// appels unitaires + N resyncs complets côté client (~3 s/item).
// Erreurs SQL internes loggées serveur uniquement (convention safeError).
//
// Lecture : les lectures du catalogue (games, contents) se font via l'API
// REST PostgREST (anon key suffit grâce aux politiques RLS publiques).
// Les lectures suggestions/profils passent par les routes service_role
// ci-dessus (durcissement RLS progressif — Phases 1 à 3).
// Cette fonction ne gère QUE ces lectures dédiées + les écritures.
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { serve } from "https://deno.land/std/http/server.ts";

// Phase 4.4 (Phase B) — MGT_ADMIN_JWT_SECRET est DÉSORMAIS LE SEUL secret :
// signature ET vérification. Le legacy JWT_SECRET n'est plus lu ; il sera
// supprimé des secrets Supabase après déploiement (aucun autre consommateur).
const SIGNING_SECRET = Deno.env.get("MGT_ADMIN_JWT_SECRET");
const ADMIN_ORIGIN = Deno.env.get("MGT_ADMIN_ORIGIN");

// Fail-closed : sans origine configurée, la fonction refuse TOUT (503).
// Pas de repli codé en dur — un fallback masquerait une mauvaise config.
// Prérequis déploiement : supabase secrets set MGT_ADMIN_ORIGIN=<origine du panneau>
const corsHeaders = {
  "Access-Control-Allow-Origin": ADMIN_ORIGIN ?? "",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, X-Admin-Token",
};

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders },
  });
}

/// Retourne une erreur générique au client tout en loggant le détail serveur.
/// Évite de leaks les messages SQL/Postgres internes.
function safeError(error: unknown, status = 400, context = "Opération échouée") {
  const detail = error instanceof Error ? error.message : String(error);
  console.error(`[admin-catalog] ${context}:`, detail);
  // Le détail PostgreSQL (noms de colonnes/constraints) est loggé côté serveur
  // pour le debug, mais NON retourné au client. En cas de fuite de JWT admin,
  // l'attaquant ne récupère pas d'infos sur le schéma de la base.
  return json({ error: context }, status);
}

// --- Génération d'un nouveau jeton (sliding session) ---
// Après chaque écriture réussie, on renvoie un fresh_token pour prolonger
// la session de 15 min. Ainsi, un admin actif n'est jamais déconnecté.
async function makeJwt(): Promise<string> {
  const enc = new TextEncoder();
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const now = Math.floor(Date.now() / 1000);
  const payload = btoa(
    JSON.stringify({ role: "admin", iat: now, exp: now + 60 * 15 })
  );
  const data = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(SIGNING_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(data));
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
  return `${data}.${sigB64}`;
}

/// Enveloppe une réponse OK avec un fresh_token (sliding session).
/// Toutes les écritures réussies passent par ici.
async function jsonWithFreshToken(obj: unknown) {
  const freshToken = await makeJwt();
  return json({ ...obj as Record<string, unknown>, fresh_token: freshToken });
}

// --- Vérification du jeton JWT admin ---
// Le jeton admin est transmis via le header personnalisé `X-Admin-Token`
// (et NON `Authorization`, réservé par la passerelle Supabase pour l'auth
// Supabase Auth). On lit aussi `Authorization` en repli pour compatibilité.
// Phase 4.4 (Phase B) : la vérification n'accepte QUE le secret dédié
// MGT_ADMIN_JWT_SECRET — la transition est terminée.
async function verifySignatureWith(
  secret: string,
  data: string,
  sigBytes: Uint8Array
): Promise<boolean> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"]
  );
  return await crypto.subtle.verify("HMAC", key, sigBytes, enc.encode(data));
}

async function verifyAdminToken(req: Request): Promise<boolean> {
  const token =
    req.headers.get("X-Admin-Token") ??
    req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!token) return false;
  const parts = token.split(".");
  if (parts.length !== 3) return false;

  const [header, payload, signature] = parts;
  const data = `${header}.${payload}`;

  try {
    // Le signature en base64url.
    const sigBytes = Uint8Array.from(
      atob(signature.replace(/-/g, "+").replace(/_/g, "/")),
      (c) => c.charCodeAt(0)
    );
    // Phase B : un SEUL secret accepté (le dédié MGT_ADMIN_JWT_SECRET).
    if (!SIGNING_SECRET) return false;
    if (!(await verifySignatureWith(SIGNING_SECRET, data, sigBytes))) {
      return false;
    }

    // Vérifie l'expiration.
    const claims = JSON.parse(atob(payload));
    if (claims.exp && Date.now() / 1000 > claims.exp) return false;
    return claims.role === "admin";
  } catch {
    return false;
  }
}

serve(async (req) => {
  // Garde fail-closed : origine admin requise (sinon on ne sert rien).
  if (!ADMIN_ORIGIN) {
    return json(
      { error: "Service non configuré (MGT_ADMIN_ORIGIN manquant)." },
      503
    );
  }

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Garde : le secret dédié est requis (Phase B — plus de repli legacy).
  if (!SIGNING_SECRET) {
    return json(
      { error: "Service non configuré (MGT_ADMIN_JWT_SECRET manquant)." },
      503
    );
  }

  // Auth : vérifie le jeton admin (header X-Admin-Token ou Authorization).
  const isAdmin = await verifyAdminToken(req);
  if (!isAdmin) {
    return json({ error: "Non autorisé." }, 401);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  // --- Routage par URL ---
  // L'URL reçue est de la forme :
  //   https://<project>.supabase.co/functions/v1/admin-catalog/<route>
  // On extrait uniquement <route> (ex: "games", "suggestions/accept").
  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/+|\/+$/g, ""); // retire les slashes de bord
  const marker = "admin-catalog/";
  const idx = path.indexOf(marker);
  const route = idx >= 0 ? path.substring(idx + marker.length) : "";

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Corps de requête JSON invalide." }, 400);
  }

  // Les tables utilisent des UUID comme clé primaire (gen_random_uuid()).
  // L'admin génère des IDs temporaires côté client (ex: "g-1783042025131")
  // pour ses manipulations locales. On ne doit JAMAIS envoyer ces IDs
  // temporaires à Supabase (erreur "invalid input syntax for type uuid").
  // Cette fonction ne retourne l'ID que si c'est un vrai UUID valide.
  const uuidOrUndefined = (id: unknown): string | undefined => {
    if (typeof id !== "string") return undefined;
    // Un UUID v4 fait 36 caractères : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    const uuidRegex =
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    return uuidRegex.test(id) ? id : undefined;
  };

  // --- Journalisation cache_ops (migration 0051 + src 0052) ---
  // Écrit une ligne par URL dans le journal consommé par Vision.exe pour
  // maintenir son cache local anti-doublons synchro avec la base.
  // [src] distingue l'origine ('contents' | 'suggestions' | 'blocked') :
  // l'app mobile ne rejoue QUE les remove src='contents' (RPC dédiée).
  // NON BLOQUANT : un échec est loggé côté serveur, jamais retourné — une
  // action admin ne doit jamais échouer à cause de la journalisation.
  const journalCacheOp = async (
    op: "add" | "remove",
    urls: (string | null | undefined)[],
    src: "contents" | "suggestions" | "blocked"
  ) => {
    const rows = urls
      .filter((u): u is string => typeof u === "string" && u.length > 0)
      .map((u) => ({ url: u, op, src }));
    if (rows.length === 0) return;
    const { error } = await supabase.from("cache_ops").insert(rows);
    if (error) {
      console.error(`[cache_ops] journalisation ${op} échouée:`, error.message);
    }
  };

  try {
    // ======================================================================
    // JEUX
    // ======================================================================
    if (route === "games") {
      const { data, error } = await supabase
        .from("games")
        .upsert({
          id: uuidOrUndefined(body.id),
          name: body.name,
          publisher: body.publisher,
          cover_url: body.cover_url,
          active: body.active ?? true,
        })
        .select()
        .single();
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ game: data });
    }

    if (route === "games/delete") {
      // Cascade : supprimer d'abord les contenus liés, puis les favoris.
      const gameId = uuidOrUndefined(body.id);
      if (!gameId) {
        return json(
          { error: "id manquant ou invalide (UUID attendu)." },
          400
        );
      }
      // Journalise les URLs des contenus supprimés (cache Vision).
      const { data: doomed } = await supabase
        .from("contents")
        .select("url")
        .eq("game_id", gameId);
      await supabase.from("contents").delete().eq("game_id", gameId);
      await supabase.from("favorite_games").delete().eq("game_id", gameId);
      const { error } = await supabase.from("games").delete().eq("id", gameId);
      if (error) return safeError(error, 400);
      await journalCacheOp(
        "remove",
        (doomed ?? []).map((r: { url: string }) => r.url),
        "contents"
      );
      return await jsonWithFreshToken({ ok: true });
    }

    // ======================================================================
    // TRADUCTIONS DE TITRES DE JEUX (game_translations)
    // ======================================================================

    if (route === "games/translate") {
      // Upsert batch de traductions pour un jeu.
      // body : { game_id: UUID, translations: { FR: "...", EN: "...", ... } }
      const gameId = uuidOrUndefined(body.game_id);
      const translations = body.translations;
      if (!gameId) {
        return json({ error: "game_id (UUID) requis." }, 400);
      }
      if (!translations || typeof translations !== "object") {
        return json({ error: "translations (objet {LANG: title}) requis." }, 400);
      }
      // Construit une ligne par langue (upsert sur la PK composite).
      const rows = Object.entries(translations).map(([lang, title]) => ({
        game_id: gameId,
        lang: String(lang).toUpperCase(),
        title: String(title),
      }));
      if (rows.length === 0) {
        return json({ error: "Aucune traduction à insérer." }, 400);
      }
      const { error } = await supabase
        .from("game_translations")
        .upsert(rows, { onConflict: "game_id,lang" });
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ ok: true, count: rows.length });
    }

    if (route === "games/translations-list") {
      // Lecture de toutes les traductions (pour les bots et le panneau admin).
      // **Pagination obligatoire** : Supabase limite par défaut à 1000 lignes.
      // Avec 103 jeux × 12 langues = 1236 lignes, on dépasserait la limite.
      const all: { game_id: string; lang: string; title: string }[] = [];
      const pageSize = 1000;
      for (let page = 0;; page++) {
        const from = page * pageSize;
        const to = from + pageSize - 1;
        const { data, error } = await supabase
          .from("game_translations")
          .select("game_id,lang,title")
          .range(from, to)
          .order("game_id", { ascending: true });
        if (error) return safeError(error, 400);
        if (data && data.length > 0) all.push(...data);
        if (!data || data.length < pageSize) break; // Fin des données.
      }
      return await jsonWithFreshToken({ translations: all });
    }

    // ======================================================================
    // CONTENUS
    // ======================================================================
    if (route === "contents") {
      const { data, error } = await supabase
        .from("contents")
        .upsert({
          id: uuidOrUndefined(body.id),
          game_id: body.game_id,
          category: body.category,
          url: body.url,
          title_source: body.title_source ?? body.title_admin,
          title_admin: body.title_admin,
          image_url: body.image_url,
          validated: body.validated ?? true,
          is_video: body.is_video ?? false,
          video_language: body.video_language ?? null,
        })
        .select()
        .single();
      if (error) return safeError(error, 400);
      await journalCacheOp("add", [typeof body.url === "string" ? body.url : null], "contents");
      return await jsonWithFreshToken({ content: data });
    }

    if (route === "suggestions/insert") {
      // Insère une suggestion découverte par un bot (Vision ou Scruteur).
      // - source : origine ('vision' | 'scruteur', défaut 'vision' pour la
      //   rétro-compatibilité avec le bot Vision qui ne l'envoie pas).
      // - author_name : signature du bot (défaut 'Vision').
      // - ai_recommendation : optionnel (le Scruteur fournit déjà son verdict
      //   IA puisqu'il découvre ET juge en un seul passage).
      const { data, error } = await supabase
        .from("suggestions")
        .insert({
          url: body.url,
          shared_text: body.shared_text ?? null,
          status: "pending",
          source: body.source ?? "vision",
          author_name: body.author_name ?? "Vision",
          ai_recommendation: body.ai_recommendation ?? null,
        })
        .select()
        .single();
      if (error) {
        console.error("[suggestions/insert] erreur:", JSON.stringify(error));
        // 23505 = doublon (URL unique) → pas une erreur, on retourne ok.
        if (error.code === "23505") {
          return await jsonWithFreshToken({ ok: true, duplicate: true });
        }
        return json({ error: `Insertion échouée: ${error.message} (code: ${error.code})` }, 400);
      }
      await journalCacheOp("add", [typeof body.url === "string" ? body.url : null], "suggestions");
      return await jsonWithFreshToken({ ok: true, duplicate: false, id: data?.id });
    }

    if (route === "contents/mark-checked") {
      // Marque un ou plusieurs contenus comme vérifiés (checked_at = now).
      const ids = body.ids;
      if (!Array.isArray(ids) || ids.length === 0) {
        return json({ error: "ids (array) requis." }, 400);
      }
      const { error } = await supabase
        .from("contents")
        .update({ checked_at: new Date().toISOString() })
        .in("id", ids);
      if (error) return safeError(error, 400, "Marquage checked échoué");
      return await jsonWithFreshToken({ ok: true, marked: ids.length });
    }

    if (route === "contents/delete-batch") {
      // Supprime plusieurs contenus par leurs IDs (batch).
      const ids = body.ids;
      if (!Array.isArray(ids) || ids.length === 0) {
        return json({ error: "ids (array) requis." }, 400);
      }
      // Journalise les URLs supprimées (cache Vision).
      const { data: doomed } = await supabase
        .from("contents")
        .select("url")
        .in("id", ids);
      const { error } = await supabase
        .from("contents")
        .delete()
        .in("id", ids);
      if (error) return safeError(error, 400, "Suppression batch échouée");
      await journalCacheOp(
        "remove",
        (doomed ?? []).map((r: { url: string }) => r.url),
        "contents"
      );
      return await jsonWithFreshToken({ ok: true, deleted: ids.length });
    }

    if (route === "blocked-urls/insert-batch") {
      // Insère plusieurs URLs bloqués (vidéos consolidées en playlist par Check).
      const urls = body.urls;
      const playlistUrl = body.playlist_url ?? null;
      const reason = body.reason ?? "Consolidated into playlist by Check bot";
      if (!Array.isArray(urls) || urls.length === 0) {
        return json({ error: "urls (array) requis." }, 400);
      }
      const rows = urls.map((u: string) => ({
        url: u,
        reason: reason,
        playlist_url: playlistUrl,
      }));
      // upsert pour ignorer les doublons (url est UNIQUE).
      const { error } = await supabase
        .from("blocked_urls")
        .upsert(rows, { onConflict: "url", ignoreDuplicates: true });
      if (error) return safeError(error, 400, "Insertion blocked_urls échouée");
      await journalCacheOp("add", urls.map((u: unknown) => String(u)), "blocked");
      return await jsonWithFreshToken({ ok: true, blocked: urls.length });
    }

    if (route === "contents/update-language") {
      // Met à jour uniquement la langue d'un contenu.
      const contentId = uuidOrUndefined(body.id);
      const language = body.video_language;
      if (!contentId) {
        return json({ error: "id requis." }, 400);
      }
      const { error } = await supabase
        .from("contents")
        .update({ video_language: language ?? null })
        .eq("id", contentId);
      if (error) return safeError(error, 400, "Mise à jour langue échouée");
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "contents/update-date") {
      // Met à jour uniquement la date de publication d'un contenu.
      // Utilisé par le bot Check pour corriger les dates YouTube.
      const contentId = uuidOrUndefined(body.id);
      const newDate = body.published_at;
      if (!contentId || !newDate) {
        return json({ error: "id et published_at requis." }, 400);
      }
      const { error } = await supabase
        .from("contents")
        .update({ published_at: newDate })
        .eq("id", contentId);
      if (error) return safeError(error, 400, "Mise à jour date échouée");
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "contents/delete") {
      const contentId = uuidOrUndefined(body.id);
      if (!contentId) {
        return json(
          { error: "id manquant ou invalide (UUID attendu)." },
          400
        );
      }
      // Journalise l'URL supprimée (cache Vision).
      const { data: doomed } = await supabase
        .from("contents")
        .select("url")
        .eq("id", contentId)
        .maybeSingle();
      // Supprime d'abord les favoris liés (cohérence référentielle).
      await supabase.from("favorite_contents").delete().eq("content_id", contentId);
      const { error } = await supabase
        .from("contents")
        .delete()
        .eq("id", contentId);
      if (error) return safeError(error, 400);
      await journalCacheOp("remove", [doomed?.url ?? null], "contents");
      return await jsonWithFreshToken({ ok: true });
    }

    // ======================================================================
    // SUGGESTIONS — modération
    // ======================================================================
    if (route === "suggestions/accept") {
      // Crée un contenu validé à partir de la suggestion.
      const suggestionId = body.id;
      const { data: suggestion, error: se } = await supabase
        .from("suggestions")
        .select("*")
        .eq("id", suggestionId)
        .single();
      if (se || !suggestion) return json({ error: "Suggestion introuvable." }, 404);

      const { error: ce } = await supabase.from("contents").insert({
        game_id: body.game_id,
        category: body.category,
        url: suggestion.url,
        title_source: suggestion.shared_text,
        title_admin: body.title_admin,
        validated: true,
        is_video: body.is_video ?? false,
        author_id: suggestion.author_id,
        // Langue du contenu : pour les liens du Scruteur (catégorie 'links'),
        // transmise par l'admin (langue détectée de la page web). Les vidéos
        // YouTube l'avaient déjà via la colonne video_language côté contents.
        video_language: body.video_language ?? null,
        // Date de publication de la vidéo (récupérée par Sentinelle via YouTube API).
        // Pour les liens du Scruteur : date du site si trouvée. Si non fournie,
        // on utilise now().
        published_at: body.published_at ?? new Date().toISOString(),
      });
      if (ce) return json({ error: ce.message }, 400);

      const { error: use } = await supabase
        .from("suggestions")
        .update({ status: "accepted", accepted_at: new Date().toISOString() })
        .eq("id", suggestionId);
      if (use) return json({ error: use.message }, 400);
      // L'URL figure désormais aussi dans contents (elle y était déjà via la
      // suggestion) — add idempotent côté cache Vision (Set normalisé).
      await journalCacheOp("add", [suggestion.url ?? null], "contents");
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "suggestions/accept-batch") {
      // ── Validation EN LOT de suggestions Sentinelle (27/08/2026) ──
      // « Tout valider » validait N suggestions via N appels suggestions/accept
      // + N resyncs complets côté client (~3 s/item → ~15 min pour 300).
      // Ici : 1 appel pour N items (le client chunke à 100 max).
      //
      // SÉCURITÉ : l'auth JWT admin est la MÊME que pour toutes les routes
      // (verifyAdminToken appliqué en amont, avant le routage). Toutes les
      // requêtes sont paramétrées PostgREST — AUCUNE interpolation SQL.
      // La clé service_role reste côté EF (jamais exposée au client).
      //
      // ENTRÉE : { items: [{ id, game_id, category, title_admin?, is_video?,
      //   published_at?, video_language? }, ...] } — max 100 items/appel.
      //
      // TRANSACTIONNALITÉ (choix documenté) : le multi-insert contents est
      // UNE requête atomique, le multi-update suggestions également.
      //   - Insert contents en échec → 400, RIEN n'est validé (atomique).
      //   - Update suggestions en échec APRÈS un insert réussi → les contenus
      //     existent mais les suggestions restent 'pending' : REJOUER le lot
      //     est sans effet grâce à l'idempotence ci-dessous (le contenu
      //     existant n'est pas réinséré, la suggestion est juste marquée).
      //
      // IDEMPOTENCE : une suggestion non 'pending' (déjà accepted/rejected)
      // ou introuvable est skippée ; un couple (url, game_id) déjà présent
      // dans contents n'est PAS réinséré (couvre le replay après échec
      // partiel de l'update).
      //
      // RÉPONSE : { ok: [ids], skipped: [{id, reason}], failed: [{id, error}] }
      const rawItems = body.items;
      if (!Array.isArray(rawItems) || rawItems.length === 0) {
        return json(
          { error: "items manquant ou vide (tableau attendu)." },
          400
        );
      }
      if (rawItems.length > 100) {
        return json(
          { error: "Maximum 100 items par appel (le client chunke)." },
          400
        );
      }

      // Validation stricte de CHAQUE item (aucun confiance au client).
      const ALLOWED_CATEGORIES = new Set(["video", "guides", "links"]);
      interface BatchItem {
        id: string;
        game_id: string;
        category: string;
        title_admin: string | null;
        is_video: boolean;
        published_at: string | null;
        video_language: string | null;
      }
      const items: BatchItem[] = [];
      for (const raw of rawItems) {
        const it = raw as Record<string, unknown> | null;
        const id = uuidOrUndefined(it?.id);
        const gameId = uuidOrUndefined(it?.game_id);
        const category =
          typeof it?.category === "string" ? it.category : "";
        if (!id || !gameId || !ALLOWED_CATEGORIES.has(category)) {
          return json(
            {
              error:
                "Item invalide : id et game_id doivent être des UUID, " +
                "category ∈ video|guides|links.",
            },
            400
          );
        }
        const titleAdmin =
          it?.title_admin == null ? null : String(it.title_admin).slice(0, 500);
        const publishedAt =
          typeof it?.published_at === "string" &&
          !Number.isNaN(Date.parse(it.published_at as string))
            ? (it.published_at as string)
            : null;
        const videoLanguage =
          typeof it?.video_language === "string"
            ? (it.video_language as string).slice(0, 10)
            : null;
        items.push({
          id,
          game_id: gameId,
          category,
          title_admin: titleAdmin,
          is_video: it?.is_video === true,
          published_at: publishedAt,
          video_language: videoLanguage,
        });
      }

      const ids = items.map((i) => i.id);
      const { data: rows, error: fe } = await supabase
        .from("suggestions")
        .select("*")
        .in("id", ids);
      if (fe) return safeError(fe, 400);
      const byId = new Map<string, Record<string, unknown>>(
        (rows ?? []).map((r) => [r.id as string, r as Record<string, unknown>])
      );

      // Partition : introuvables / non-pending (idempotence) vs à valider.
      const skipped: { id: string; reason: string }[] = [];
      const toAccept: { item: BatchItem; suggestion: Record<string, unknown> }[] =
        [];
      for (const item of items) {
        const s = byId.get(item.id);
        if (!s) {
          skipped.push({ id: item.id, reason: "introuvable" });
          continue;
        }
        if (s.status !== "pending") {
          skipped.push({ id: item.id, reason: `déjà ${s.status}` });
          continue;
        }
        toAccept.push({ item, suggestion: s });
      }
      if (toAccept.length === 0) {
        return await jsonWithFreshToken({ ok: [], skipped, failed: [] });
      }

      // Garde-fou anti-doublon (idempotence de replay) : ne pas réinsérer un
      // contenu déjà créé pour le même couple (url, game_id).
      const urls = toAccept.map((t) => t.suggestion.url as string);
      const { data: existing } = await supabase
        .from("contents")
        .select("url, game_id")
        .in("url", urls);
      const existingPairs = new Set(
        (existing ?? []).map((c) => `${c.url}|${c.game_id}`)
      );

      const inserts: Record<string, unknown>[] = [];
      const acceptedIds: string[] = [];
      const okUrls: string[] = [];
      for (const { item, suggestion } of toAccept) {
        const url = suggestion.url as string;
        acceptedIds.push(item.id);
        if (existingPairs.has(`${url}|${item.game_id}`)) {
          continue; // contenu déjà créé (replay) → on marque juste accepted
        }
        inserts.push({
          game_id: item.game_id,
          category: item.category,
          url,
          title_source: suggestion.shared_text ?? null,
          title_admin: item.title_admin,
          validated: true,
          is_video: item.is_video,
          author_id: suggestion.author_id ?? null,
          video_language: item.video_language,
          published_at: item.published_at ?? new Date().toISOString(),
        });
        okUrls.push(url);
      }

      if (inserts.length > 0) {
        // Multi-insert = UNE requête SQL atomique : tout ou rien.
        const { error: ce } = await supabase.from("contents").insert(inserts);
        if (ce) {
          // Détails SQL loggés serveur uniquement (jamais renvoyés au
          // client, convention safeError du fichier).
          console.error("[admin-catalog] accept-batch insert contents:", ce.message);
          return json(
            {
              error: "Insertion des contenus échouée — rien n'a été validé.",
              ok: [],
              skipped,
              failed: acceptedIds.map((id) => ({
                id,
                error: "insert contents échoué (lot rejouable)",
              })),
            },
            400
          );
        }
      }

      // Multi-update = UNE requête SQL atomique : tout ou rien.
      const { error: ue } = await supabase
        .from("suggestions")
        .update({ status: "accepted", accepted_at: new Date().toISOString() })
        .in("id", acceptedIds);
      if (ue) {
        // Contenus insérés mais suggestions non marquées : le client peut
        // REJOUER le lot — l'idempotence (skip url+game_id existants) évite
        // les doublons et l'update passera au second essai.
        console.error("[admin-catalog] accept-batch update suggestions:", ue.message);
        return json(
          {
            error:
              "Marquage des suggestions échoué — rejouez le lot (idempotent).",
            ok: [],
            skipped,
            failed: acceptedIds.map((id) => ({
              id,
              error: "update suggestions échoué (lot rejouable)",
            })),
          },
          400
        );
      }

      await journalCacheOp("add", okUrls, "contents");
      return await jsonWithFreshToken({ ok: acceptedIds, skipped, failed: [] });
    }

    if (route === "suggestions/reject") {
      const { error } = await supabase
        .from("suggestions")
        .update({ status: "rejected" })
        .eq("id", body.id);
      if (error) return safeError(error, 400);
      // Pas de journalisation : l'URL d'une suggestion REJETÉE reste
      // volontairement dans le cache Vision (ne jamais reproposer un refusé).
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "suggestions/delete") {
      // Suppression DÉFINITIVE d'une suggestion, uniquement si encore
      // « pending » (garde-fou : jamais de suppression d'une ligne modérée).
      // Utilisée par Sentinelle pour les vidéos différées faute d'audience
      // suffisante (règle 20/07/2026) : la ligne sort de la file pour
      // débloquer la pagination des 500, et l'URL redevient candidate —
      // Vision la re-scannera ultérieurement quand l'audience aura grandi.
      const suggestionId = uuidOrUndefined(body.id);
      if (!suggestionId) {
        return json(
          { error: "id manquant ou invalide (UUID attendu)." },
          400
        );
      }
      // Journalise l'URL libérée AVANT suppression (cache Vision : remove).
      const { data: doomed } = await supabase
        .from("suggestions")
        .select("url")
        .eq("id", suggestionId)
        .maybeSingle();
      const { error } = await supabase
        .from("suggestions")
        .delete()
        .eq("id", suggestionId)
        .eq("status", "pending");
      if (error) return safeError(error, 400);
      await journalCacheOp("remove", [doomed?.url ?? null], "suggestions");
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "games-to-create/delete") {
      // Retire une suggestion de la file « Jeux à créer » en la marquant
      // rejected (le flag needs_game_creation reste dans ai_recommendation
      // mais status='rejected' la sort des résultats pending).
      const suggestionId = uuidOrUndefined(body.id);
      if (!suggestionId) {
        return json(
          { error: "id manquant ou invalide." },
          400
        );
      }
      const { error } = await supabase
        .from("suggestions")
        .update({ status: "rejected" })
        .eq("id", suggestionId);
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "games-to-create/delete-batch") {
      // Suppression par lot des suggestions « Jeux à créer ».
      const ids: string[] = Array.isArray(body.ids) ? body.ids : [];
      if (ids.length === 0) {
        return json({ error: "Aucun id fourni." }, 400);
      }
      const { error } = await supabase
        .from("suggestions")
        .update({ status: "rejected" })
        .in("id", ids);
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ ok: true, count: ids.length });
    }

    if (route === "suggestions/ai-recommend") {
      // Écrit la recommandation de l'IA Sentinelle sur une suggestion.
      // Le champ ai_recommendation est un JSONB stockant verdict, confidence,
      // reason, suggested_game, suggested_category, youtube_views, etc.
      const suggestionId = uuidOrUndefined(body.id);
      if (!suggestionId) {
        return json(
          { error: "id manquant ou invalide (UUID attendu)." },
          400
        );
      }
      const recommendation = body.recommendation;
      if (!recommendation) {
        return json({ error: "recommendation manquant." }, 400);
      }
      const { error } = await supabase
        .from("suggestions")
        .update({ ai_recommendation: recommendation })
        .eq("id", suggestionId);
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "suggestions/mark-analyzing") {
      // Marque qu'une suggestion est en cours d'analyse par Sentinelle.
      // Écrit sentinelle_started_at = now() (sans ai_recommendation).
      // L'admin voit alors la suggestion passer dans le menu Sentinelle,
      // section "Analyse en cours", jusqu'à ce que l'analyse termine.
      const suggestionId = uuidOrUndefined(body.id);
      if (!suggestionId) {
        return json(
          { error: "id manquant ou invalide (UUID attendu)." },
          400
        );
      }
      const { error } = await supabase
        .from("suggestions")
        .update({ sentinelle_started_at: new Date().toISOString() })
        .eq("id", suggestionId);
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "suggestions/unlock-stuck") {
      // SOLUTION 1 : Débloque les suggestions stuck en "Analyse en cours".
      // Une suggestion est "stuck" si sentinelle_started_at est posé depuis
      // plus de [timeoutMinutes] (défaut 10 min) sans ai_recommendation.
      // Cela arrive si le bot crash/stop entre markAnalyzing et le verdict.
      // Reset sentinelle_started_at = NULL → la suggestion redevient "nouvelle"
      // et sera reprise par le prochain cycle (mode pending-no-ai).
      const timeoutMinutes =
        typeof body.timeout_minutes === "number" && body.timeout_minutes > 0
          ? body.timeout_minutes
          : 10;
      const cutoff = new Date(
        Date.now() - timeoutMinutes * 60 * 1000
      ).toISOString();
      const { data, error } = await supabase
        .from("suggestions")
        .update({ sentinelle_started_at: null })
        .not("sentinelle_started_at", "is", null)
        .is("ai_recommendation", null)
        .eq("status", "pending")
        .lt("sentinelle_started_at", cutoff)
        .select("id");
      if (error) return safeError(error, 400, "Déblocage échoué");
      return await jsonWithFreshToken({
        ok: true,
        unlocked: data?.length ?? 0,
        ids: data?.map((r: { id: string }) => r.id) ?? [],
      });
    }

    if (route === "suggestions/analyzing-count") {
      // SOLUTION 2 : Compte les suggestions actuellement en "Analyse en cours"
      // (pour afficher un badge/alerte dans l'admin si des stuck sont détectés).
      const stuckCount =
        typeof body.stuck_only === "boolean" ? body.stuck_only : false;
      let query = supabase
        .from("suggestions")
        .select("id", { count: "exact", head: true })
        .not("sentinelle_started_at", "is", null)
        .is("ai_recommendation", null)
        .eq("status", "pending");
      if (stuckCount) {
        const cutoff = new Date(Date.now() - 10 * 60 * 1000).toISOString();
        query = query.lt("sentinelle_started_at", cutoff);
      }
      const { count, error } = await query;
      if (error) return safeError(error, 400, "Comptage échoué");
      return await jsonWithFreshToken({ count: count ?? 0 });
    }

    // ======================================================================
    // PROFILS — ban / unban
    // ======================================================================
    if (route === "profiles/ban") {
      const { error } = await supabase
        .from("profiles")
        .update({ is_banned: true, ban_reason: body.reason ?? "Modération" })
        .eq("id", body.user_id);
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "profiles/unban") {
      const { error } = await supabase
        .from("profiles")
        .update({ is_banned: false, ban_reason: null })
        .eq("id", body.user_id);
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "profiles/banned-list") {
      // Retourne tous les profils bannis (synchro admin).
      const { data, error } = await supabase
        .from("profiles")
        .select("id, display_name, is_banned, ban_reason")
        .eq("is_banned", true);
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ banned: data ?? [] });
    }

    if (route === "bad-contributors/list") {
      // Retourne les mauvais contributeurs (vue bad_contributors, migration 0046)
      // avec jointure sur subscriptions pour le badge Premium.
      const { data: contributors, error } = await supabase
        .from("bad_contributors")
        .select("*");
      if (error) return safeError(error, 400);

      // Récupère les abonnements actifs pour le badge Premium.
      const authorIds = (contributors ?? []).map((c: any) => c.author_id);
      let plusMap: Record<string, boolean> = {};
      if (authorIds.length > 0) {
        const { data: subs } = await supabase
          .from("subscriptions")
          .select("user_id, is_active")
          .in("user_id", authorIds)
          .eq("is_active", true);
        for (const s of subs ?? []) {
          plusMap[s.user_id] = true;
        }
      }

      const result = (contributors ?? []).map((c: any) => ({
        ...c,
        is_premium: plusMap[c.author_id] ?? false,
      }));
      return await jsonWithFreshToken({ contributors: result });
    }

    // ======================================================================
    // ABONNEMENTS — gestion manuelle (pour le test fermé, avant Play Billing)
    // ======================================================================
    if (route === "subscriptions/upsert") {
      const now = new Date().toISOString();
      const expiresAt = body.expires_at ?? null;
      const { data, error } = await supabase
        .from("subscriptions")
        .upsert({
          user_id: body.user_id,
          plan: body.plan,
          is_active: body.is_active ?? true,
          started_at: body.started_at ?? now,
          expires_at: expiresAt,
          updated_at: now,
        })
        .select()
        .single();
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ subscription: data });
    }

    if (route === "subscriptions/list") {
      // Récupère tous les abonnements, puis les profils associés.
      // On fait 2 requêtes séparées (pas de jointure PostgREST) car la FK
      // subscriptions.user_id → profiles.id peut ne pas être déclarée.
      const { data: subs, error } = await supabase
        .from("subscriptions")
        .select("user_id, plan, is_active, started_at, expires_at, updated_at, source")
        .order("updated_at", { ascending: false });
      if (error) return safeError(error, 400);

      // Récupère les display_name + is_banned des profils correspondants.
      const userIds = (subs ?? [])
        .map((s: any) => s.user_id)
        .filter((id: any) => id != null);
      let profilesMap: Record<string, { name: string; banned: boolean; reason: string | null }> = {};
      if (userIds.length > 0) {
        const { data: profiles } = await supabase
          .from("profiles")
          .select("id, display_name, is_banned")
          .in("id", userIds);
        for (const p of profiles ?? []) {
          profilesMap[p.id] = {
            name: p.display_name ?? "Inconnu",
            banned: p.is_banned ?? false,
            reason: p.ban_reason,
          };
        }
      }

      // Fusionne les abonnements avec les display_name + is_banned.
      const result = (subs ?? []).map((s: any) => {
        const p = profilesMap[s.user_id] ?? { name: "Inconnu", banned: false, reason: null };
        return {
          ...s,
          display_name: p.name,
          is_banned: p.banned,
          ban_reason: p.ban_reason,
        };
      });
      return json({ subscriptions: result });
    }

    // ======================================================================
    // LECTURES service_role (Phase 1 — durcissement RLS progressif)
    // Ces routes remplacent à terme les lectures PostgREST anon du panneau
    // sur suggestions/profils ; elles fonctionnent quel que soit l'état des
    // policies (ajout pur — aucune route existante n'est modifiée).
    // ======================================================================
    if (route === "suggestions/list") {
      // Lecture des suggestions par mode (filtres strictement identiques
      // aux requêtes PostgREST actuelles du panneau).
      const mode = typeof body.mode === "string" ? body.mode : "new";
      const page =
        typeof body.page === "number" && body.page >= 0 ? body.page : 0;
      const pageSize =
        typeof body.pageSize === "number" &&
        body.pageSize > 0 &&
        body.pageSize <= 1000
          ? body.pageSize
          : 500;

      let query = supabase.from("suggestions").select("*");
      // Ordre antéchronologique pour les vues du panneau, chronologique pour
      // la file de travail des bots (mode "pending-no-ai").
      let ascending = false;

      switch (mode) {
        case "analyzing":
          // En cours d'analyse Sentinelle (démarrée, pas encore de verdict).
          query = query
            .not("sentinelle_started_at", "is", "null")
            .is("ai_recommendation", null)
            .eq("status", "pending");
          break;
        case "analyzed":
          // Analysées par Sentinelle (verdict IA présent).
          query = query
            .not("ai_recommendation", "is", null)
            .eq("status", "pending");
          break;
        case "games-to-create":
          // File « Jeux à créer » (flag dans la recommandation IA).
          query = query
            .eq("ai_recommendation->needs_game_creation", true)
            .eq("status", "pending");
          break;
        case "scruteur":
          // Suggestions découvertes par le bot Scruteur (sites web de guides
          // d'astuces/solutions) : déjà jugées par l'IA (ai_recommendation
          // présent), en attente de validation manuelle par l'admin.
          // Distinguées des suggestions utilisateurs ('user') et des vidéos
          // Vision ('vision') via la colonne source (migration 0032).
          query = query
            .eq("source", "scruteur")
            .not("ai_recommendation", "is", null)
            .eq("status", "pending");
          break;
        case "user-links-pending":
          // Suggestions UTILISATEURS (source='user') de type LIENS WEB
          // (non-YouTube), en attente et sans verdict IA. Sert au "1 click
          // review" du Scruteur qui les passe au juge IA pour valider/tagger.
          // On exclut les URLs YouTube (gérées par Sentinelle) et on ne prend
          // QUE les sites web (guides, wikis, blogs gaming).
          query = query
            .eq("source", "user")
            .eq("status", "pending")
            .is("ai_recommendation", null)
            .not("url", "ilike", "%youtube.com/%")
            .not("url", "ilike", "%youtu.be/%");
          ascending = true; // plus anciennes d'abord
          break;
        case "pending-no-ai":
          // File de travail des bots Sentinelle/Vision : en attente, sans
          // verdict IA (inclut les reprises après crash), plus anciennes
          // d'abord. Filtre strictement identique à l'ancienne lecture
          // PostgREST anon des bots.
          query = query
            .eq("status", "pending")
            .is("ai_recommendation", null);
          ascending = true;
          break;
        default:
          // "new" : jamais prises en charge par Sentinelle.
          query = query.is("sentinelle_started_at", null);
      }

      query = query
        .order("shared_at", { ascending })
        .range(page * pageSize, (page + 1) * pageSize - 1);

      const { data: rows, error } = await query;
      if (error) return safeError(error, 400, "Lecture des suggestions échouée");

      // Reproduit l'embed PostgREST author:profiles(id,display_name,avatar_preset)
      // via une 2ᵉ requête (service_role — indépendant de la RLS profiles).
      const authorIds = [
        ...new Set(
          (rows ?? [])
            .map((r: any) => r.author_id)
            .filter((id: any) => typeof id === "string" && id.length > 0)
        ),
      ];
      const authorsMap: Record<string, any> = {};
      if (authorIds.length > 0) {
        const { data: profs } = await supabase
          .from("profiles")
          .select("id, display_name, avatar_preset")
          .in("id", authorIds);
        for (const p of profs ?? []) authorsMap[p.id] = p;
      }
      const suggestions = (rows ?? []).map((r: any) => ({
        ...r,
        author: r.author_id ? authorsMap[r.author_id] ?? null : null,
      }));
      return await jsonWithFreshToken({ suggestions });
    }

    if (route === "profiles/find-by-email") {
      // Résolution email → UUID profil (ajout manuel Plus / ban par email).
      // Délègue à la fonction SQL existante : exécutée ici en service_role,
      // elle reste utilisable après révocation du grant anon (Phase 3).
      const email = body.email;
      if (typeof email !== "string" || email.length === 0) {
        return json({ error: "email requis." }, 400);
      }
      const { data, error } = await supabase.rpc("find_profile_by_email", {
        email,
      });
      if (error) return safeError(error, 400, "Recherche par email échouée");
      return await jsonWithFreshToken({ id: data ?? null });
    }

    if (route === "suggestions/urls") {
      // Anti-doublons Vision : TOUTES les URLs de suggestions (tous statuts,
      // y compris rejected pour ne jamais reproposer un lien refusé), paginé.
      // service_role — remplace la lecture PostgREST anon du bot (Phase 3.2b).
      //
      // Paramètre optionnel `since` (ISO 8601) : ne retourne que les
      // suggestions dont shared_at >= since — utilisé par Vision pour la
      // synchronisation INCRÉMENTALE de son cache local anti-doublons
      // (évite de re-télécharger les ~33k URLs à chaque cycle, egress).
      const page =
        typeof body.page === "number" && body.page >= 0 ? body.page : 0;
      const pageSize =
        typeof body.pageSize === "number" &&
        body.pageSize > 0 &&
        body.pageSize <= 1000
          ? body.pageSize
          : 1000;
      const since =
        typeof body.since === "string" && body.since.length > 0
          ? body.since
          : null;
      let query = supabase
        .from("suggestions")
        .select("url")
        .order("shared_at", { ascending: true });
      if (since) query = query.gte("shared_at", since);
      const { data: rows, error } = await query
        .range(page * pageSize, (page + 1) * pageSize - 1);
      if (error) return safeError(error, 400, "Lecture des URLs échouée");
      return await jsonWithFreshToken({
        urls: (rows ?? []).map((r: any) => r.url),
      });
    }

    if (route === "cache-ops/list") {
      // Journal des opérations d'URLs (migration 0051) pour la sync du cache
      // local Vision : additions ET suppressions, dans l'ordre chronologique.
      // Paramètre optionnel `since` (ISO 8601) : created_at >= since.
      const page =
        typeof body.page === "number" && body.page >= 0 ? body.page : 0;
      const pageSize =
        typeof body.pageSize === "number" &&
        body.pageSize > 0 &&
        body.pageSize <= 1000
          ? body.pageSize
          : 1000;
      const since =
        typeof body.since === "string" && body.since.length > 0
          ? body.since
          : null;
      let query = supabase
        .from("cache_ops")
        .select("url,op,created_at")
        .order("created_at", { ascending: true })
        .order("id", { ascending: true });
      if (since) query = query.gte("created_at", since);
      const { data: rows, error } = await query
        .range(page * pageSize, (page + 1) * pageSize - 1);
      if (error) return safeError(error, 400, "Lecture du journal échouée");
      return await jsonWithFreshToken({ ops: rows ?? [] });
    }

    // Route inconnue.
    return json({ error: `Route inconnue : ${route}` }, 404);
  } catch (err) {
    return safeError(err, 500, "Erreur interne du serveur.");
  }
});
