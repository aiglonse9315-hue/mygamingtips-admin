// ============================================================================
// MyGamingTips — Edge Function Supabase "admin-login"
// ============================================================================
// Vérifie les identifiants administrateur CÔTÉ SERVEUR et renvoie un jeton JWT
// court terme. AUCUN identifiant n'est dans le front-end.
//
// Déploiement : supabase functions deploy admin-login
// Secrets requis (supabase secrets set ...):
//   - MGT_ADMIN_LOGIN        : login admin
//   - MGT_ADMIN_PASSWORD_HASH: hash bcrypt du mot de passe
//   - (SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY fournis auto)
//   - JWT_SECRET             : pour signer le jeton (secret Supabase du projet)
//
// Bonnes pratiques intégrées :
//   - Vérification bcrypt (jamais de comparaison de texte clair).
//   - Rate-limiting basique par IP (map en mémoire ; en prod, préférer
//     Upstash Redis ou la table admin_auth_logs + comptage).
//   - Journalisation des tentatives (table admin_auth_logs via service_role).
//   - JWT court (15 min) signé serveur.
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { serve } from "https://deno.land/std/http/server.ts";

const ADMIN_LOGIN = Deno.env.get("MGT_ADMIN_LOGIN");
const ADMIN_PASSWORD_HASH = Deno.env.get("MGT_ADMIN_PASSWORD_HASH");
const JWT_SECRET = Deno.env.get("JWT_SECRET");

// --- Rate limiting PERSISTANT (par IP) via la table admin_auth_logs ---
// Contrairement à une Map en mémoire (perdue à chaque redémarrage d'instance),
// cette implémentation interroge la base de données pour compter les échecs
// récents. Le blocage survit donc aux redémarrages, rafraîchissements et
// changements d'instance Edge Function.
const MAX_ATTEMPTS = 3;
const LOCKOUT_MS = 5 * 60 * 1000; // 5 minutes
const WINDOW_MS = 5 * 60 * 1000;  // fenêtre de 5 min pour compter les échecs

async function checkRateLimit(
  supabase: ReturnType<typeof createClient>,
  ip: string,
  username?: string
): Promise<{ allowed: boolean; remainingMs: number; failedCount: number }> {
  // Compte les échecs récents pour une clé donnée (IP ou login), depuis le
  // dernier succès correspondant (ou la fenêtre de 5 min si aucun succès).
  async function countFailures(
    column: "ip" | "username",
    value: string
  ): Promise<{ blocked: boolean; remainingMs: number; count: number }> {
    const { data: lastSuccess } = await supabase
      .from("admin_auth_logs")
      .select("at")
      .eq(column, value)
      .eq("success", true)
      .order("at", { ascending: false })
      .limit(1)
      .maybeSingle();

    const windowStart = lastSuccess
      ? lastSuccess.at
      : new Date(Date.now() - WINDOW_MS).toISOString();

    const { count, error } = await supabase
      .from("admin_auth_logs")
      .select("id", { count: "exact", head: true })
      .eq(column, value)
      .eq("success", false)
      .gte("at", windowStart);
    if (error) {
      return { blocked: false, remainingMs: 0, count: 0 };
    }
    const failedCount = count ?? 0;
    if (failedCount >= MAX_ATTEMPTS) {
      const { data: lastFail } = await supabase
        .from("admin_auth_logs")
        .select("at")
        .eq(column, value)
        .eq("success", false)
        .order("at", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (lastFail) {
        const lastTime = new Date(lastFail.at).getTime();
        const remaining = lastTime + LOCKOUT_MS - Date.now();
        if (remaining > 0) {
          return { blocked: true, remainingMs: remaining, count: failedCount };
        }
      }
    }
    return { blocked: false, remainingMs: 0, count: failedCount };
  }

  // Blocage par IP (comportement existant, inchangé).
  const byIp = await countFailures("ip", ip);
  if (byIp.blocked) {
    return {
      allowed: false,
      remainingMs: byIp.remainingMs,
      failedCount: byIp.count,
    };
  }
  // Blocage par LOGIN : empêche la force brute distribuée (rotation d'IP).
  // Le compteur s'applique au login SAISI, sans jamais révéler s'il existe.
  if (username) {
    const byUser = await countFailures("username", username);
    if (byUser.blocked) {
      return {
        allowed: false,
        remainingMs: byUser.remainingMs,
        failedCount: byUser.count,
      };
    }
  }
  return { allowed: true, remainingMs: 0, failedCount: byIp.count };
}

// --- Vérification bcrypt via bcryptjs (pure JS, 100% compatible Deno) ---
// On utilise bcryptjs (et non deno.land/x/bcrypt) car cette dernière a des
// soucis de compatibilité avec le runtime Edge de Supabase. bcryptjs est du
// JavaScript pur, sans dépendance native, et fonctionne partout.
async function verifyBcrypt(plain: string, hash: string): Promise<boolean> {
  try {
    const { default: bcryptjs } = await import(
      "https://esm.sh/bcryptjs@2.4.3"
    );
    return await bcryptjs.compareSync(plain, hash);
  } catch (err) {
    console.error("bcryptjs chargement échec:", String(err));
    return false;
  }
}

async function makeJwt(): Promise<string> {
  // Jeton court terme signé (header.payload.signature avec HMAC-SHA256).
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

// --- Journalisation serveur ---
async function logAttempt(
  supabase: ReturnType<typeof createClient>,
  ip: string,
  success: boolean,
  detail: string,
  username?: string
) {
  await supabase.from("admin_auth_logs").insert({
    ip,
    success,
    detail,
    username: username ?? null,
    at: new Date().toISOString(),
  });
}

serve(async (req) => {
  // CORS fail-closed : MGT_ADMIN_ORIGIN DOIT être défini, sinon on refuse
  // tout (pas de repli codé en dur qui masquerait une mauvaise config).
  // Prérequis : supabase secrets set MGT_ADMIN_ORIGIN=<origine du panneau>
  const adminOrigin = Deno.env.get("MGT_ADMIN_ORIGIN");
  if (!adminOrigin) {
    return new Response(
      JSON.stringify({
        error: "Service admin non configuré (MGT_ADMIN_ORIGIN manquant).",
      }),
      { status: 503, headers: { "Content-Type": "application/json" } }
    );
  }
  const corsHeaders = {
    "Access-Control-Allow-Origin": adminOrigin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, X-Admin-Token",
  };
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // Garde : si les secrets serveur ne sont pas configurés, on échoue tôt
  // avec un message explicite plutôt qu'une comparaison contre undefined.
  if (!ADMIN_LOGIN || !ADMIN_PASSWORD_HASH || !JWT_SECRET) {
    return json(
      { error: "Service admin non configuré (secrets manquants)." },
      503,
      corsHeaders
    );
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")! // contourne RLS côté serveur
  );

  // IP vue par la passerelle Supabase uniquement. Ne JAMAIS replier sur
  // x-forwarded-for ici : ce header est contrôlé par le client et
  // permettrait de contourner le rate-limiting par simple rotation.
  const ip = req.headers.get("x-real-ip") ?? "unknown";

  // 1) Lecture du corps (avant le rate-limiting : le compteur par login
  //    a besoin du username saisi).
  let body: { username?: string; password?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Requête invalide." }, 400, corsHeaders);
  }
  const { username, password } = body;
  if (!username || !password) {
    return json({ error: "Champs manquants." }, 400, corsHeaders);
  }

  // 2) Rate-limiting persistant (base de données) : par IP ET par login.
  const rl = await checkRateLimit(supabase, ip, username);
  if (!rl.allowed) {
    await logAttempt(
      supabase,
      ip,
      false,
      `bloqué (${rl.remainingMs}ms)`,
      username
    );
    const remainingMin = Math.ceil(rl.remainingMs / 60000);
    return json(
      { error: `Trop de tentatives. Réessayez dans ${remainingMin} minute(s).` },
      429,
      corsHeaders
    );
  }

  // 3) Vérification serveur (bcrypt).
  const hashConfigured = !!ADMIN_PASSWORD_HASH;
  const usernameMatches = username === ADMIN_LOGIN;
  // Log minimal volontaire : ne JAMAIS logger le login attendu, le résultat
  // de la comparaison ni le préfixe du hash — quiconque lit les logs
  // apprendrait l'identifiant admin.
  console.log("Tentative login:", { reçu: username, hashConfigured });

  let passwordOk = false;
  if (usernameMatches && hashConfigured && ADMIN_PASSWORD_HASH) {
    passwordOk = await verifyBcrypt(password, ADMIN_PASSWORD_HASH);
    console.log("Résultat bcrypt:", passwordOk);
  }
  const ok = usernameMatches && passwordOk;

  if (!ok) {
    // Le log en base sert de compteur pour le rate-limiting persistant.
    await logAttempt(supabase, ip, false, "identifiants invalides", username);
    return json({ error: "Identifiants incorrects." }, 401, corsHeaders);
  }

  // 4) Succès : jeton court terme.
  // Le log de succès en base "écrase" virtuellement les échecs (le
  // rate-limiting compte les échecs, et un succès réinitialise la fenêtre).
  await logAttempt(supabase, ip, true, "connexion réussie", username);
  const token = await makeJwt();
  return json({ token }, 200, corsHeaders);
});

function json(obj: unknown, status: number, headers: Record<string, string>) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}
