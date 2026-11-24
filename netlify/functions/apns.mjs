// iOS app device tokens (APNs).
// POST { action: "register", token, name, env } | { action: "unregister", token } | { action: "test", token }
// env is "sandbox" (development-signed builds) or "production".
import { apnsConfigured, checkKey, sendAPNs, tokenKey, tokenStore, validToken } from "../lib/apns.mjs";

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

export default async (req) => {
  if (req.method === "GET") {
    // ?check=1: does the key parse, and does Apple accept it? (Never returns the key.)
    if (new URL(req.url).searchParams.get("check")) return json(await checkKey());
    return json({ configured: apnsConfigured() });
  }
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  let body;
  try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }
  const token = String(body?.token || "").toLowerCase();
  if (!validToken(token)) return json({ error: "bad token" }, 400);
  const s = tokenStore();
  const key = tokenKey(token);

  if (body.action === "register") {
    await s.setJSON(key, {
      token,
      name: String(body.name || "").trim().slice(0, 40),
      env: body.env === "production" ? "production" : "sandbox",
      updatedAt: Date.now(),
    });
    return json({ ok: true, configured: apnsConfigured() });
  }

  if (body.action === "unregister") {
    await s.delete(key);
    return json({ ok: true });
  }

  if (body.action === "test") {
    const rec = await s.get(key, { type: "json" });
    if (!rec) return json({ error: "not registered" }, 404);
    if (!apnsConfigured()) return json({ error: "APNs is not set up on the server" }, 503);
    const r = await sendAPNs([{ key, ...rec }], {
      title: "Notifications are on 🎄",
      body: "You will hear about new shopping items, to-dos for you, and reminders.",
      url: "/",
      tag: "test",
    });
    return json({ ok: r.sent === 1 });
  }

  return json({ error: "unknown action" }, 400);
};

export const config = { path: "/api/apns" };
