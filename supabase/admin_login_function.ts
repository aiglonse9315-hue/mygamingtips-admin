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

// --- Rate limiting basique (par IP) ---
const attempts = new Map<string, { count: number; until: number }>();
const MAX_ATTEMPTS = 5;
const LOCKOUT_MS = 2 * 60 * 1000; // 2 minutes

function rateLimit(ip: string): { allowed: boolean; remainingMs: number } {
  const now = Date.now();
  const entry = attempts.get(ip);
  if (entry && now < entry.until) {
    return { allowed: false, remainingMs: entry.until - now };
  }
  return { allowed: true, remainingMs: 0 };
}

function recordFailure(ip: string) {
  const now = Date.now();
  const entry = attempts.get(ip) ?? { count: 0, until: 0 };
  entry.count += 1;
  if (entry.count >= MAX_ATTEMPTS) {
    entry.until = now + LOCKOUT_MS;
    entry.count = 0;
  }
  attempts.set(ip, entry);
}

function clearFailures(ip: string) {
  attempts.delete(ip);
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
  // CORS (le panneau admin web est sur un autre domaine en prod).
  const corsHeaders = {
    "Access-Control-Allow-Origin": Deno.env.get("MGT_ADMIN_ORIGIN") ?? "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
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

  const ip =
    req.headers.get("x-real-ip") ??
    req.headers.get("x-forwarded-for") ??
    "unknown";

  // 1) Rate-limiting.
  const rl = rateLimit(ip);
  if (!rl.allowed) {
    await logAttempt(supabase, ip, false, `bloqué (${rl.remainingMs}ms)`);
    return json(
      { error: "Trop de tentatives. Réessayez plus tard." },
      429,
      corsHeaders
    );
  }

  // 2) Lecture du corps.
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

  // 3) Vérification serveur (bcrypt).
  const loginConfigured = !!ADMIN_LOGIN;
  const hashConfigured = !!ADMIN_PASSWORD_HASH;
  const hashPrefix = ADMIN_PASSWORD_HASH?.substring(0, 7) ?? "(vide)";
  const usernameMatches = username === ADMIN_LOGIN;
  console.log("Tentative login:", {
    reçu: username,
    attendu: ADMIN_LOGIN ? `"${ADMIN_LOGIN}"` : "(non configuré)",
    usernameMatches,
    loginConfigured,
    hashConfigured,
    hashPrefix,
  });

  let passwordOk = false;
  if (usernameMatches && hashConfigured && ADMIN_PASSWORD_HASH) {
    passwordOk = await verifyBcrypt(password, ADMIN_PASSWORD_HASH);
    console.log("Résultat bcrypt:", passwordOk);
  }
  const ok = usernameMatches && passwordOk;

  if (!ok) {
    recordFailure(ip);
    await logAttempt(supabase, ip, false, "identifiants invalides", username);
    return json({ error: "Identifiants incorrects." }, 401, corsHeaders);
  }

  // 4) Succès : jeton court terme.
  clearFailures(ip);
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
