// Borra a un integrante del equipo (médico o residente): su fila en "medicos"
// y su usuario de Supabase Auth. La fila de medicos tiene columnas con
// ON DELETE CASCADE desde pacientes/internaciones/consultas/precios_*/etc,
// así que borrar a un médico con pacientes propios borra también todos esos
// registros — el frontend ya le muestra a quien confirma cuántos pacientes/
// internaciones/consultas tiene esa persona ANTES de llamar a esta función,
// así que acá no se vuelve a preguntar ni se valida ese conteo de nuevo.
// Solo puede llamarlo un médico (no un residente), y nadie puede borrarse a
// sí mismo por acá.

const SUPABASE_URL = Deno.env.get("SB_URL")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SB_SECRET_KEY")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function getUserIdFromJwt(authHeader: string | null): string {
  if (!authHeader) return "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  const jwtPayload = jwt.split(".")[1];
  if (!jwtPayload) return "";
  try {
    return JSON.parse(atob(jwtPayload.replace(/-/g, "+").replace(/_/g, "/"))).sub || "";
  } catch (_e) {
    return "";
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return jsonResponse({ error: "method not allowed" }, 405);

  let payload: any = {};
  try {
    payload = await req.json();
  } catch (_e) {
    return jsonResponse({ error: "invalid JSON" }, 400);
  }

  const targetId = String(payload.medico_id || "");
  if (!targetId) return jsonResponse({ error: "medico_id requerido" }, 400);

  const callerId = getUserIdFromJwt(req.headers.get("Authorization"));
  if (!callerId) return jsonResponse({ error: "no autorizado" }, 401);
  if (callerId === targetId) return jsonResponse({ error: "no podés borrarte a vos mismo" }, 400);

  const callerRes = await fetch(
    `${SUPABASE_URL}/rest/v1/medicos?id=eq.${callerId}&select=rol`,
    { headers: { apikey: SUPABASE_SECRET_KEY, Authorization: `Bearer ${SUPABASE_SECRET_KEY}` } }
  );
  const callerRows = await callerRes.json().catch(() => []);
  const callerRol = Array.isArray(callerRows) && callerRows[0] ? callerRows[0].rol : null;
  if (callerRol !== "medico") {
    return jsonResponse({ error: "no tenés permiso para borrar médicos" }, 403);
  }

  const delRowRes = await fetch(`${SUPABASE_URL}/rest/v1/medicos?id=eq.${targetId}`, {
    method: "DELETE",
    headers: { apikey: SUPABASE_SECRET_KEY, Authorization: `Bearer ${SUPABASE_SECRET_KEY}` },
  });
  if (!delRowRes.ok) {
    const errBody = await delRowRes.json().catch(() => ({}));
    return jsonResponse({ error: errBody.message || "no se pudo borrar el registro" }, 500);
  }

  const delUserRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${targetId}`, {
    method: "DELETE",
    headers: { apikey: SUPABASE_SECRET_KEY, Authorization: `Bearer ${SUPABASE_SECRET_KEY}` },
  });
  if (!delUserRes.ok) {
    const errBody = await delUserRes.json().catch(() => ({}));
    return jsonResponse({
      ok: true,
      warning: "Se borró el perfil y sus datos, pero no el usuario de acceso: " + (errBody.msg || errBody.message || ""),
    });
  }

  return jsonResponse({ ok: true });
});
