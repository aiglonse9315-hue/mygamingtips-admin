// ============================================================================
// MyGamingTips — Edge Function Supabase "admin-catalog"
// ============================================================================
// Opérations d'écriture administrateur sur le catalogue (jeux, contenus,
// suggestions, profils bannis, abonnements). Contourne la RLS via
// service_role. L'accès est protégé par vérification du JWT admin émis par
// la fonction "admin-login".
//
// Déploiement : supabase functions deploy admin-catalog
// Secrets requis (fournis automatiquement par Supabase) :
//   - SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//   - JWT_SECRET (pour vérifier le jeton admin)
//
// Endpoints (tous POST, body JSON, header Authorization: Bearer <jwt>) :
//   POST /games            → upsert jeu (create ou update)
//   POST /games/delete     → supprimer un jeu + cascade contenus
//   POST /contents         → upsert contenu (create/update)
//   POST /suggestions/accept → valider une suggestion (crée un contenu)
//   POST /suggestions/reject → rejeter une suggestion
//   POST /suggestions/ai-recommend → écrire la recommandation IA Sentinelle
//   POST /profiles/ban     → bannir un utilisateur (is_banned = true)
//   POST /profiles/unban   → lever un ban (is_banned = false)
//   POST /subscriptions/upsert → créer/modifier un abonnement Plus manuel
//   POST /suggestions/list → lecture suggestions par mode (service_role)
//   POST /profiles/find-by-email → résolution email → UUID (service_role)
//
// Lecture : les lectures du catalogue (games, contents) se font via l'API
// REST PostgREST (anon key suffit grâce aux politiques RLS publiques).
// Les lectures suggestions/profils passent par les routes service_role
// ci-dessus (durcissement RLS progressif — Phases 1 à 3).
// Cette fonction ne gère QUE ces lectures dédiées + les écritures.
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { serve } from "https://deno.land/std/http/server.ts";

const JWT_SECRET = Deno.env.get("JWT_SECRET");
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
    enc.encode(JWT_SECRET),
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
async function verifyAdminToken(req: Request): Promise<boolean> {
  const token =
    req.headers.get("X-Admin-Token") ??
    req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!token) return false;
  const parts = token.split(".");
  if (parts.length !== 3) return false;

  const [header, payload, signature] = parts;
  const enc = new TextEncoder();
  const data = `${header}.${payload}`;

  try {
    const key = await crypto.subtle.importKey(
      "raw",
      enc.encode(JWT_SECRET),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["verify"]
    );
    // Le signature en base64url.
    const sigBytes = Uint8Array.from(
      atob(signature.replace(/-/g, "+").replace(/_/g, "/")),
      (c) => c.charCodeAt(0)
    );
    const valid = await crypto.subtle.verify("HMAC", key, sigBytes, enc.encode(data));
    if (!valid) return false;

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

  // Garde : secret JWT requis.
  if (!JWT_SECRET) {
    return json({ error: "Service non configuré (JWT_SECRET manquant)." }, 503);
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
      await supabase.from("contents").delete().eq("game_id", gameId);
      await supabase.from("favorite_games").delete().eq("game_id", gameId);
      const { error } = await supabase.from("games").delete().eq("id", gameId);
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ ok: true });
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
      return await jsonWithFreshToken({ content: data });
    }

    if (route === "suggestions/insert") {
      // Insère une suggestion découverte par le bot Vision.
      const { data, error } = await supabase
        .from("suggestions")
        .insert({
          url: body.url,
          shared_text: body.shared_text ?? null,
          status: "pending",
          author_name: "Vision",
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
      const { error } = await supabase
        .from("contents")
        .delete()
        .in("id", ids);
      if (error) return safeError(error, 400, "Suppression batch échouée");
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
      // Supprime d'abord les favoris liés (cohérence référentielle).
      await supabase.from("favorite_contents").delete().eq("content_id", contentId);
      const { error } = await supabase
        .from("contents")
        .delete()
        .eq("id", contentId);
      if (error) return safeError(error, 400);
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
        // Date de publication de la vidéo (récupérée par Sentinelle via YouTube API).
        // Si non fournie (non-YouTube ou date indisponible), on utilise now().
        published_at: body.published_at ?? new Date().toISOString(),
      });
      if (ce) return json({ error: ce.message }, 400);

      const { error: use } = await supabase
        .from("suggestions")
        .update({ status: "accepted", accepted_at: new Date().toISOString() })
        .eq("id", suggestionId);
      if (use) return json({ error: use.message }, 400);
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "suggestions/reject") {
      const { error } = await supabase
        .from("suggestions")
        .update({ status: "rejected" })
        .eq("id", body.id);
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ ok: true });
    }

    if (route === "games-to-create/delete") {
      // Retire une suggestion de la file « Jeux à créer » en la marquant
      // rejected (le flag needs_game_creation reste dans ai_recommendation
      // mais status='rejected' la sort des résultats pending).
      const suggestionId = uuidOrUndefined(body.id);
      if (!suggestionId) {
        return json({ error: "id manquant ou invalide." }, 400);
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
        .select("user_id, plan, is_active, started_at, expires_at, updated_at")
        .order("updated_at", { ascending: false });
      if (error) return safeError(error, 400);

      // Récupère les display_name des profils correspondants.
      const userIds = (subs ?? [])
        .map((s: any) => s.user_id)
        .filter((id: any) => id != null);
      let profilesMap: Record<string, string> = {};
      if (userIds.length > 0) {
        const { data: profiles } = await supabase
          .from("profiles")
          .select("id, display_name")
          .in("id", userIds);
        for (const p of profiles ?? []) {
          profilesMap[p.id] = p.display_name ?? "Inconnu";
        }
      }

      // Fusionne les abonnements avec les display_name.
      const result = (subs ?? []).map((s: any) => ({
        ...s,
        display_name: profilesMap[s.user_id] ?? "Inconnu",
      }));
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

      let query = supabase
        .from("suggestions")
        .select("*")
        .order("shared_at", { ascending: false })
        .range(page * pageSize, (page + 1) * pageSize - 1);

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
            .not("ai_recommendation", "is", "null")
            .eq("status", "pending");
          break;
        case "games-to-create":
          // File « Jeux à créer » (flag dans la recommandation IA).
          query = query
            .eq("ai_recommendation->needs_game_creation", true)
            .eq("status", "pending");
          break;
        default:
          // "new" : jamais prises en charge par Sentinelle.
          query = query.is("sentinelle_started_at", null);
      }

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

    // Route inconnue.
    return json({ error: `Route inconnue : ${route}` }, 404);
  } catch (err) {
    return safeError(err, 500, "Erreur interne du serveur.");
  }
});
