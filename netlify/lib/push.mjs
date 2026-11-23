// Shared Web Push helpers. Subscriptions live in the "push-subs" blob store:
// one blob per device, keyed by a hash of the push endpoint.
import { createHash } from "node:crypto";
import { getStore } from "@netlify/blobs";
import webpush from "web-push";

export const subStore = () => getStore({ name: "push-subs", consistency: "strong" });
export const subKey = (endpoint) => createHash("sha256").update(String(endpoint)).digest("hex");
export const sameName = (a, b) => String(a || "").trim().toLowerCase() === String(b || "").trim().toLowerCase();
export const firstName = (n) => String(n || "").trim().split(/\s+/)[0];

const env = (k) => (globalThis.Netlify?.env?.get(k)) ?? process.env[k];
export const publicKey = () => env("VAPID_PUBLIC_KEY") || "";

let configured = false;
function configure() {
  if (configured) return true;
  const pub = env("VAPID_PUBLIC_KEY"), priv = env("VAPID_PRIVATE_KEY");
  if (!pub || !priv) return false;
  webpush.setVapidDetails(env("URL") || "https://christmas-shopping-uovm.netlify.app", pub, priv);
  configured = true;
  return true;
}

// All saved subscriptions: [{ key, subscription, name }]
export async function allSubs() {
  const s = subStore();
  const { blobs } = await s.list();
  const subs = await Promise.all(blobs.map(async (b) => ({ key: b.key, ...(await s.get(b.key, { type: "json" })) })));
  return subs.filter((x) => x.subscription?.endpoint);
}

// Send one payload to many subscriptions. Removes subscriptions the push service says are gone.
export async function send(subs, payload) {
  if (!configure() || !subs.length) return { sent: 0 };
  const s = subStore();
  let sent = 0;
  await Promise.all(subs.map(async (sub) => {
    try {
      await webpush.sendNotification(sub.subscription, JSON.stringify(payload), { TTL: 60 * 60 * 12 });
      sent++;
    } catch (e) {
      if (e.statusCode === 404 || e.statusCode === 410) await s.delete(sub.key);
      else console.error("push failed", e.statusCode, e.body || e.message);
    }
  }));
  return { sent };
}

// "Fri 25 Dec" from "2026-12-25"
export function dueLabel(due) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(due || "")) return "";
  const d = new Date(due + "T12:00:00Z");
  return d.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
}

// Today's date in the UK as "YYYY-MM-DD"
export function todayUK() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/London", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
}
