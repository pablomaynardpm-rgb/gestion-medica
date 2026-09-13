// Sincroniza la fecha quirúrgica de un paciente con el Google Calendar de
// TODOS los médicos que ya conectaron el suyo (no solo quien cargó el turno).
// Requiere sesión de un médico logueado (verify_jwt=true) para poder invocarse,
// pero usa la secret key internamente para leer/escribir a través de médicos.

const SUPABASE_URL = Deno.env.get("SB_URL")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SB_SECRET_KEY")!;
const GOOGLE_CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID")!;
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET")!;

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

function addOneDay(isoDate: string): string {
  const d = new Date(isoDate + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

// Suma minutos a una fecha+hora "naive" (sin zona horaria) usando aritmética de
// calendario simple, evitando cualquier ambigüedad de husos horarios reales.
function addMinutes(fecha: string, hora: string, minutes: number): { fecha: string; hora: string } {
  const [y, m, d] = fecha.split("-").map(Number);
  const [hh, mm] = hora.split(":").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d, hh, mm));
  dt.setUTCMinutes(dt.getUTCMinutes() + minutes);
  const pad = (n: number) => String(n).padStart(2, "0");
  return {
    fecha: `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-${pad(dt.getUTCDate())}`,
    hora: `${pad(dt.getUTCHours())}:${pad(dt.getUTCMinutes())}`,
  };
}

async function sbFetch(path: string, init: RequestInit = {}) {
  return fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SUPABASE_SECRET_KEY,
      Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
}

async function getAccessToken(refreshToken: string): Promise<string | null> {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      refresh_token: refreshToken,
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      grant_type: "refresh_token",
    }),
  });
  const data = await res.json().catch(() => ({}));
  return res.ok ? data.access_token : null;
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
  const pacienteId = payload.paciente_id;
  if (!pacienteId) return jsonResponse({ error: "paciente_id requerido" }, 400);

  const pacRes = await sbFetch(
    `pacientes?id=eq.${pacienteId}&select=id,nombre,sanatorio,operacion,fecha_qx,hora_qx,google_calendar_event_ids`
  );
  const pacRows = await pacRes.json().catch(() => []);
  if (!Array.isArray(pacRows) || pacRows.length === 0) return jsonResponse({ error: "paciente no encontrado" }, 404);
  const paciente = pacRows[0];
  const eventIds: Record<string, string> = paciente.google_calendar_event_ids || {};

  // Solo se sincroniza con médicos de rol "medico" — un residente que conecte
  // su Google Calendar no debería empezar a recibir todas las cirugías del equipo.
  const tokensRes = await sbFetch(
    `medico_calendar_tokens?select=medico_id,refresh_token,medicos!inner(rol)&medicos.rol=eq.medico`
  );
  const tokenRows: { medico_id: string; refresh_token: string }[] = await tokensRes.json().catch(() => []);

  if (!paciente.fecha_qx) {
    // Sin fecha: borra los eventos existentes en cada calendario conectado.
    for (const row of tokenRows) {
      const existing = eventIds[row.medico_id];
      if (!existing) continue;
      const accessToken = await getAccessToken(row.refresh_token);
      if (!accessToken) continue;
      await fetch(`https://www.googleapis.com/calendar/v3/calendars/primary/events/${existing}`, {
        method: "DELETE",
        headers: { Authorization: `Bearer ${accessToken}` },
      }).catch(() => {});
    }
    await sbFetch(`pacientes?id=eq.${pacienteId}`, {
      method: "PATCH",
      body: JSON.stringify({ google_calendar_event_ids: {} }),
    });
    return jsonResponse({ ok: true, synced: 0, deleted: true });
  }

  let direccion = "";
  if (paciente.sanatorio) {
    const sanRes = await sbFetch(
      `sanatorios?nombre=eq.${encodeURIComponent(paciente.sanatorio)}&select=direccion`
    );
    const sanRows = await sanRes.json().catch(() => []);
    if (Array.isArray(sanRows) && sanRows[0]?.direccion) direccion = sanRows[0].direccion;
  }

  const summary = paciente.operacion ? `${paciente.nombre} — ${paciente.operacion}` : paciente.nombre;
  const description = paciente.sanatorio ? `Sanatorio: ${paciente.sanatorio}` : "";
  const TZ = "America/Argentina/Buenos_Aires";

  let start: Record<string, string>;
  let end: Record<string, string>;
  if (paciente.hora_qx) {
    const horaInicio = String(paciente.hora_qx).slice(0, 5);
    const fin = addMinutes(paciente.fecha_qx, horaInicio, 60);
    start = { dateTime: `${paciente.fecha_qx}T${horaInicio}:00-03:00`, timeZone: TZ };
    end = { dateTime: `${fin.fecha}T${fin.hora}:00-03:00`, timeZone: TZ };
  } else {
    start = { date: paciente.fecha_qx };
    end = { date: addOneDay(paciente.fecha_qx) };
  }

  // colorId "5" = amarillo ("Banana" en la API/UI de Google Calendar en
  // inglés; no existe un nombre oficial "Girasol" pero es el color amarillo
  // que Pablo pidió para toda cirugía agendada).
  const eventBody: Record<string, unknown> = { summary, description, start, end, colorId: "5" };
  if (direccion) eventBody.location = direccion;

  const newEventIds: Record<string, string> = { ...eventIds };
  let synced = 0;

  for (const row of tokenRows) {
    const accessToken = await getAccessToken(row.refresh_token);
    if (!accessToken) continue;
    const existing = eventIds[row.medico_id];

    if (existing) {
      const patchRes = await fetch(
        `https://www.googleapis.com/calendar/v3/calendars/primary/events/${existing}`,
        {
          method: "PATCH",
          headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
          body: JSON.stringify(eventBody),
        }
      );
      if (patchRes.ok) {
        synced++;
        continue;
      }
      // El evento pudo haber sido borrado a mano del lado de Google: reintenta como insert.
    }

    const insertRes = await fetch(`https://www.googleapis.com/calendar/v3/calendars/primary/events`, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify(eventBody),
    });
    const insertData = await insertRes.json().catch(() => ({}));
    if (insertRes.ok && insertData.id) {
      newEventIds[row.medico_id] = insertData.id;
      synced++;
    }
  }

  await sbFetch(`pacientes?id=eq.${pacienteId}`, {
    method: "PATCH",
    body: JSON.stringify({ google_calendar_event_ids: newEventIds }),
  });

  return jsonResponse({ ok: true, synced });
});
