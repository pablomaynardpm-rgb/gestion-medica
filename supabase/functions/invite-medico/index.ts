// Invita a otro médico por email usando la Admin API de Supabase Auth.
// Solo puede llamarse con un JWT válido (verify_jwt=true en el deploy), es decir
// solo un médico ya logueado en la app puede invitar a otro. Claude nunca ve ni
// maneja contraseñas: el invitado recibe un email de Supabase y la define él mismo.

const SUPABASE_URL = Deno.env.get("SB_URL")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SB_SECRET_KEY")!;
const APP_URL = Deno.env.get("APP_URL")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method not allowed" }), {
      status: 405,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  let payload: any = {};
  try {
    payload = await req.json();
  } catch (_e) {
    return new Response(JSON.stringify({ error: "invalid JSON" }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  const email = String(payload.email || "").trim().toLowerCase();
  const nombre = String(payload.nombre || "").trim();
  const especialidad = String(payload.especialidad || "").trim();
  const rol = payload.rol === "residente" ? "residente" : "medico";
  // "todos" (o directamente nada) = sin restricción de sanatorio (null).
  // Un array de nombres de sanatorio = restringido a esos.
  const sanatorios: string[] | null =
    Array.isArray(payload.sanatorios) && payload.sanatorios.length > 0
      ? payload.sanatorios.map((s: unknown) => String(s)).filter(Boolean)
      : null;

  if (!email || !email.includes("@")) {
    return new Response(JSON.stringify({ error: "email inválido" }), {
      status: 400,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  // Solo un médico (no un residente) puede invitar a otros — se valida server-side,
  // no solo ocultando el botón en la UI.
  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  const jwtPayload = jwt.split(".")[1];
  let callerId = "";
  try {
    callerId = JSON.parse(atob(jwtPayload.replace(/-/g, "+").replace(/_/g, "/"))).sub || "";
  } catch (_e) {
    // sigue sin callerId, se rechaza abajo si no se puede confirmar el rol
  }
  const callerRes = await fetch(
    `${SUPABASE_URL}/rest/v1/medicos?id=eq.${callerId}&select=rol`,
    { headers: { apikey: SUPABASE_SECRET_KEY, Authorization: `Bearer ${SUPABASE_SECRET_KEY}` } }
  );
  const callerRows = await callerRes.json().catch(() => []);
  const callerRol = Array.isArray(callerRows) && callerRows[0] ? callerRows[0].rol : null;
  if (callerRol !== "medico") {
    return new Response(JSON.stringify({ error: "no tenés permiso para invitar médicos" }), {
      status: 403,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  // El rol (y, si es residente, el supervisor = quien invita) viaja en el
  // user_metadata de la invitación — el frontend lo lee al completar el
  // perfil y lo incluye recién ahí en el insert de "medicos" (la fila todavía
  // no existe en este punto, así que no hay nada que pre-crear acá).
  const inviteRes = await fetch(
    `${SUPABASE_URL}/auth/v1/invite?redirect_to=${encodeURIComponent(APP_URL)}`,
    {
      method: "POST",
      headers: {
        apikey: SUPABASE_SECRET_KEY,
        Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        email,
        data: {
          nombre,
          especialidad,
          rol,
          supervisor_id: rol === "residente" ? callerId : null,
          sanatorios_permitidos: rol === "residente" ? sanatorios : null,
        },
      }),
    }
  );

  const result = await inviteRes.json().catch(() => ({}));

  if (!inviteRes.ok) {
    return new Response(JSON.stringify({ error: result.msg || result.message || "no se pudo invitar" }), {
      status: inviteRes.status,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ ok: true }), {
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
});
