import webpush from "npm:web-push@3.6.7";

const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const SUPABASE_URL = Deno.env.get("SB_URL")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SB_SECRET_KEY")!;
const INTERNAL_SECRET = Deno.env.get("INTERNAL_FUNCTION_SECRET")!;

webpush.setVapidDetails("mailto:pablomaynard.pm@gmail.com", VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

Deno.serve(async (req) => {
  if (req.headers.get("x-internal-secret") !== INTERNAL_SECRET) {
    return new Response("forbidden", { status: 403 });
  }

  let payload: any = {};
  try {
    payload = await req.json();
  } catch (_e) {
    payload = {};
  }

  const countRes = await fetch(
    `${SUPABASE_URL}/rest/v1/interconsultas?select=id&estado=eq.pendiente`,
    {
      headers: {
        apikey: SUPABASE_SECRET_KEY,
        Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
        Prefer: "count=exact",
      },
    }
  );
  const contentRange = countRes.headers.get("content-range");
  const total = contentRange ? parseInt(contentRange.split("/")[1] || "0", 10) : 0;

  const subsRes = await fetch(`${SUPABASE_URL}/rest/v1/push_subscriptions?select=*`, {
    headers: {
      apikey: SUPABASE_SECRET_KEY,
      Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
    },
  });
  const subs = await subsRes.json();

  const title = "Nueva interconsulta";
  const bodyText = [payload.paciente, payload.sanatorio].filter(Boolean).join(" - ") || "Se cargó una interconsulta nueva";
  const notifPayload = JSON.stringify({ title, body: bodyText, badge: total });

  let sent = 0;
  await Promise.all(
    (subs || []).map(async (s: any) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          notifPayload
        );
        sent++;
      } catch (e: any) {
        if (e.statusCode === 410 || e.statusCode === 404) {
          await fetch(`${SUPABASE_URL}/rest/v1/push_subscriptions?id=eq.${s.id}`, {
            method: "DELETE",
            headers: {
              apikey: SUPABASE_SECRET_KEY,
              Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
            },
          });
        }
      }
    })
  );

  return new Response(JSON.stringify({ ok: true, sent, total }), {
    headers: { "Content-Type": "application/json" },
  });
});
