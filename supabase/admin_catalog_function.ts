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
//
// Lecture : les lectures du catalogue se font directement via l'API REST
// PostgREST (anon key suffit grâce aux politiques RLS publiques en lecture).
// Cette fonction ne gère QUE les écritures.
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { serve } from "https://deno.land/std/http/server.ts";

const JWT_SECRET = Deno.env.get("JWT_SECRET");

const corsHeaders = {
  "Access-Control-Allow-Origin": Deno.env.get("MGT_ADMIN_ORIGIN") ?? "https://aiglonse9315-hue.github.io",
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
        })
        .select()
        .single();
      if (error) return safeError(error, 400);
      return await jsonWithFreshToken({ content: data });
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
        // Si non fournie, la base utilise la valeur par défaut (now()).
        published_at: body.published_at ?? null,
      });
      if (ce) return json({ error: ce.message }, 400);

      const { error: use } = await supabase
        .from("suggestions")
        .update({ status: "accepted" })
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

    // Route inconnue.
    return json({ error: `Route inconnue : ${route}` }, 404);
  } catch (err) {
    return safeError(err, 500, "Erreur interne du serveur.");
  }
});
