// Push subscription endpoint.
// GET  -> { publicKey }
// POST { action: "subscribe", subscription, name } | { action: "unsubscribe", endpoint } | { action: "test", endpoint }
import { publicKey, send, subKey, subStore } from "../lib/push.mjs";

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

export default async (req) => {
  if (req.method === "GET") return json({ publicKey: publicKey() });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  let body;
  try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }
  const s = subStore();

  if (body.action === "subscribe") {
    const sub = body.subscription;
    if (!sub?.endpoint || !/^https:\/\//.test(sub.endpoint) || !sub.keys?.p256dh || !sub.keys?.auth) {
      return json({ error: "bad subscription" }, 400);
    }
    const record = {
      subscription: { endpoint: sub.endpoint, keys: { p256dh: String(sub.keys.p256dh), auth: String(sub.keys.auth) } },
      name: String(body.name || "").slice(0, 40),
      updatedAt: Date.now(),
    };
    await s.setJSON(subKey(sub.endpoint), record);
    return json({ ok: true });
  }

  if (body.action === "unsubscribe") {
    if (body.endpoint) await s.delete(subKey(body.endpoint));
    return json({ ok: true });
  }

  if (body.action === "test") {
    const rec = body.endpoint ? await s.get(subKey(body.endpoint), { type: "json" }) : null;
    if (!rec) return json({ error: "not subscribed" }, 404);
    const r = await send([{ key: subKey(body.endpoint), ...rec }], {
      title: "Notifications are on 🎄",
      body: "You will hear about new shopping items, to-dos for you, and reminders.",
      url: "/",
      tag: "test",
    });
    return json({ ok: r.sent === 1 });
  }

  return json({ error: "unknown action" }, 400);
};

export const config = { path: "/api/push" };
