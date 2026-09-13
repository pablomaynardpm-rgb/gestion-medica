// Recibe el redirect de Google después de que un médico autoriza el acceso a su
// Google Calendar. Intercambia el code por un refresh_token y lo guarda en
// medico_calendar_tokens, scoped a ese médico (identificado por `state`).
// Función pública (verify_jwt=false): Google la llama directamente desde el
// navegador del médico, sin Authorization header de Supabase.

const SUPABASE_URL = Deno.env.get("SB_URL")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SB_SECRET_KEY")!;
const GOOGLE_CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID")!;
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET")!;
const APP_URL = Deno.env.get("APP_URL")!;
const REDIRECT_URI = `${SUPABASE_URL}/functions/v1/google-oauth-callback`;

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const error = url.searchParams.get("error");

  function redirectToApp(status: string) {
    return new Response(null, {
      status: 302,
      headers: { Location: `${APP_URL}/?calendar=${status}` },
    });
  }

  if (error || !code || !state) {
    return redirectToApp("error");
  }

  // Confirma que state corresponde a un médico real antes de guardar nada.
  const medicoRes = await fetch(`${SUPABASE_URL}/rest/v1/medicos?id=eq.${state}&select=id`, {
    headers: { apikey: SUPABASE_SECRET_KEY, Authorization: `Bearer ${SUPABASE_SECRET_KEY}` },
  });
  const medicoRows = await medicoRes.json().catch(() => []);
  if (!Array.isArray(medicoRows) || medicoRows.length === 0) {
    return redirectToApp("error");
  }

  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      redirect_uri: REDIRECT_URI,
      grant_type: "authorization_code",
    }),
  });
  const tokenData = await tokenRes.json().catch(() => ({}));

  if (!tokenRes.ok || !tokenData.refresh_token) {
    // Si el médico ya había conectado antes, Google puede no reenviar refresh_token
    // salvo que se fuerce prompt=consent (ya lo forzamos desde el front), así que
    // esto normalmente solo pasa ante un error real.
    return redirectToApp("error");
  }

  const upsertRes = await fetch(`${SUPABASE_URL}/rest/v1/medico_calendar_tokens`, {
    method: "POST",
    headers: {
      apikey: SUPABASE_SECRET_KEY,
      Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
      "Content-Type": "application/json",
      Prefer: "resolution=merge-duplicates",
    },
    body: JSON.stringify({
      medico_id: state,
      refresh_token: tokenData.refresh_token,
      connected_at: new Date().toISOString(),
    }),
  });

  if (!upsertRes.ok) {
    return redirectToApp("error");
  }

  return redirectToApp("connected");
});
