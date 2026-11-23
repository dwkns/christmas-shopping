// Apple Push Notification service (APNs) for the iOS app. No dependencies: HTTP/2 from node:http2 and an ES256
// token signed with node:crypto.
//
// Device tokens live in the "apns-tokens" blob store: one blob per phone, keyed by a hash of the token,
// { token, name, env, updatedAt }. env is "sandbox" for development-signed builds (every build we ship today, as in
// Lifts) and "production" for App Store / TestFlight builds; the app reads it from its provisioning profile.
//
// Environment variables (Netlify): APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY (the .p8 file's text, newlines kept or as \n),
// optional APNS_BUNDLE_ID (default com.dwkns.millhouse).
import { createHash, createPrivateKey, sign } from "node:crypto";
import { connect } from "node:http2";
import { getStore } from "@netlify/blobs";

const env = (k) => (globalThis.Netlify?.env?.get(k)) ?? process.env[k];
const HOSTS = { production: "https://api.push.apple.com", sandbox: "https://api.sandbox.push.apple.com" };

export const tokenStore = () => getStore({ name: "apns-tokens", consistency: "strong" });
export const tokenKey = (token) => createHash("sha256").update(String(token)).digest("hex");
export const validToken = (t) => typeof t === "string" && /^[0-9a-f]{64,200}$/i.test(t);
export const apnsConfigured = () => !!(env("APNS_KEY_ID") && env("APNS_TEAM_ID") && env("APNS_KEY"));
const topic = () => env("APNS_BUNDLE_ID") || "com.dwkns.millhouse";

// Provider token: valid for an hour, and Apple refuses one renewed more often than every 20 minutes. Keep it 40.
let jwt = null;
function providerToken() {
  if (jwt && Date.now() - jwt.at < 40 * 60 * 1000) return jwt.value;
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = b64({ alg: "ES256", kid: env("APNS_KEY_ID") });
  const claims = b64({ iss: env("APNS_TEAM_ID"), iat: Math.floor(Date.now() / 1000) });
  const key = createPrivateKey(String(env("APNS_KEY")).replace(/\\n/g, "\n"));
  const sig = sign("sha256", Buffer.from(`${head}.${claims}`), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  jwt = { value: `${head}.${claims}.${sig}`, at: Date.now() };
  return jwt.value;
}

// One POST on an open HTTP/2 session. Resolves { status, reason }.
function post(session, token, body, headers) {
  return new Promise((resolve) => {
    const req = session.request({ ":method": "POST", ":path": `/3/device/${token}`, ...headers });
    let status = 0, data = "";
    req.setTimeout(10000, () => { req.close(); resolve({ status: 0, reason: "timeout" }); });
    req.on("response", (h) => { status = h[":status"]; });
    req.on("data", (c) => { data += c; });
    req.on("end", () => {
      let reason = "";
      try { reason = data ? JSON.parse(data).reason : ""; } catch {}
      resolve({ status, reason });
    });
    req.on("error", (e) => resolve({ status: 0, reason: e.message }));
    req.end(JSON.stringify(body));
  });
}

// The web-push payload ({ title, body, url, tag }) as an APNs one. url "/?view=todo" becomes view "todo", which the app
// opens on tap.
export function apnsPayload({ title, body, url, tag }) {
  const view = /view=(\w+)/.exec(url || "")?.[1] || "";
  return { aps: { alert: { title, body }, sound: "default", "thread-id": tag || "general" }, view };
}

// Send one payload to many devices: [{ key, token, env }]. Tokens Apple says are gone are deleted. A token stored under
// the wrong environment is retried on the other one and corrected.
export async function sendAPNs(devices, payload) {
  if (!apnsConfigured() || !devices.length) return { sent: 0 };
  const body = apnsPayload(payload);
  const headers = {
    authorization: `bearer ${providerToken()}`,
    "apns-topic": topic(),
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-expiration": String(Math.floor(Date.now() / 1000) + 60 * 60 * 12),
    ...(payload.tag ? { "apns-collapse-id": String(payload.tag).slice(0, 64) } : {}),
  };
  const sessions = {};
  const session = (e) => (sessions[e] ||= connect(HOSTS[e]).on("error", (err) => console.error("apns session", e, err.message)));
  let sent = 0;
  try {
    await Promise.all(devices.map(async (d) => {
      let e = d.env === "production" ? "production" : "sandbox";
      let r = await post(session(e), d.token, body, headers);
      if (r.status === 400 && r.reason === "BadDeviceToken") {
        const other = e === "production" ? "sandbox" : "production";
        const r2 = await post(session(other), d.token, body, headers);
        if (r2.status === 200) { e = other; r = r2; await tokenStore().setJSON(d.key, { token: d.token, name: d.name, env: e, updatedAt: d.updatedAt }); }
      }
      if (r.status === 200) sent++;
      else if (r.status === 410 || (r.status === 400 && r.reason === "BadDeviceToken")) await tokenStore().delete(d.key);
      else console.error("apns failed", r.status, r.reason);
    }));
  } finally {
    for (const s of Object.values(sessions)) s.close();
  }
  return { sent };
}

// All registered phones: [{ kind: "apns", key, token, name, env }]
export async function allDevices() {
  const s = tokenStore();
  const { blobs } = await s.list();
  const rows = await Promise.all(blobs.map(async (b) => ({ kind: "apns", key: b.key, ...(await s.get(b.key, { type: "json" })) })));
  return rows.filter((x) => validToken(x.token));
}
