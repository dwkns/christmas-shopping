// Over-the-air iPhone updates, modelled on YouPods (app/releases.py) and Lifts. scripts/release-ios.sh on the mini
// uploads MillHouse.ipa and then release.json into the "app-updates" blob store; the app asks /updates/release for the
// newest version and, when it is behind, hands /updates/manifest.plist to iOS, which installs it.
//
//   GET  /updates/                 install page for Safari on the phone (the first install)
//   GET  /updates/release          { version, notes, built_at } or 404
//   GET  /updates/manifest.plist   what iOS's installer reads
//   GET  /updates/MillHouse.ipa    the build
//   POST /updates/upload?file=ipa|release   Authorization: Bearer <token>
//
// The token is in ~/.millhouse-release-token on the mini (32 random bytes). Only its SHA-256 is here: safe to publish,
// since the token cannot be worked back from it. RELEASE_TOKEN_SHA256 in Netlify overrides it.
//
// Only phones registered with the Apple developer account (scripts/add-device.sh) can install the build.
import { createHash, timingSafeEqual } from "node:crypto";
import { getStore } from "@netlify/blobs";

const BUNDLE_ID = "com.dwkns.millhouse";
const TITLE = "Xmas List";
const store = () => getStore({ name: "app-updates", consistency: "strong" });
const env = (k) => (globalThis.Netlify?.env?.get(k)) ?? process.env[k];
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const noStore = { "cache-control": "no-store" };
const TOKEN_SHA256 = "f4bfb8b6199b95f7fd06bcac91c1679c7bc5a4b0db12f19db888e88947713fa5";

async function latest() {
  const s = store();
  const release = await s.get("release.json", { type: "json" });
  if (!release?.version) return null;
  const meta = await s.getMetadata("MillHouse.ipa");
  return meta ? release : null; // an upload cut short: no IPA, no release
}

function authorised(req) {
  const want = env("RELEASE_TOKEN_SHA256") || TOKEN_SHA256;
  const got = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!/^[0-9a-f]{64}$/.test(want) || !got) return false;
  const a = Buffer.from(createHash("sha256").update(got).digest("hex"));
  return timingSafeEqual(a, Buffer.from(want));
}

function manifest(release, origin) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${esc(origin)}/updates/MillHouse.ipa?v=${esc(release.version)}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${BUNDLE_ID}</string>
        <key>bundle-version</key>
        <string>${esc(release.version)}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>${TITLE}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
`;
}

function installPage(release, origin) {
  const body = !release
    ? "<p>No build has been released yet.</p>"
    : `<p><a class="b" href="itms-services://?action=download-manifest&amp;url=${esc(origin)}/updates/manifest.plist">Install ${TITLE} ${esc(release.version)}</a></p><p>${esc(release.notes).replace(/\n/g, "<br>")}</p>`;
  return `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${TITLE}</title><meta name="robots" content="noindex">
<style>body{font:17px -apple-system,sans-serif;margin:40px 20px;text-align:center}
.b{display:inline-block;background:#d1242f;color:#fff;padding:14px 28px;border-radius:12px;text-decoration:none}</style>
</head><body><h1>${TITLE}</h1>${body}</body></html>
`;
}

export default async (req) => {
  const url = new URL(req.url);
  const origin = env("URL") || url.origin;
  const path = url.pathname.replace(/\/+$/, "");

  if (req.method === "POST" && path === "/updates/upload") {
    if (!authorised(req)) return new Response("forbidden", { status: 403 });
    const file = url.searchParams.get("file");
    const s = store();
    if (file === "ipa") {
      const data = await req.arrayBuffer();
      if (data.byteLength < 1000) return new Response("empty ipa", { status: 400 });
      await s.set("MillHouse.ipa", data, { metadata: { size: data.byteLength, at: Date.now() } });
      return Response.json({ ok: true, size: data.byteLength });
    }
    if (file === "release") {
      let release;
      try { release = await req.json(); } catch { return new Response("bad json", { status: 400 }); }
      if (!/^\d+\.\d+\.\d+$/.test(release?.version || "")) return new Response("bad version", { status: 400 });
      if (!(await s.getMetadata("MillHouse.ipa"))) return new Response("upload the ipa first", { status: 409 });
      await s.setJSON("release.json", { version: release.version, notes: String(release.notes || ""), built_at: release.built_at || new Date().toISOString() });
      return Response.json({ ok: true });
    }
    return new Response("unknown file", { status: 400 });
  }

  if (req.method !== "GET" && req.method !== "HEAD") return new Response("method not allowed", { status: 405 });
  const release = await latest();

  if (path === "/updates/release") {
    return release ? Response.json(release, { headers: noStore }) : Response.json({ error: "no release" }, { status: 404, headers: noStore });
  }
  if (path === "/updates/manifest.plist") {
    if (!release) return new Response("no release", { status: 404 });
    return new Response(manifest(release, origin), { headers: { "content-type": "application/xml", ...noStore } });
  }
  if (path === "/updates/MillHouse.ipa") {
    const data = release && (await store().get("MillHouse.ipa", { type: "arrayBuffer" }));
    if (!data) return new Response("no build", { status: 404 });
    return new Response(data, { headers: { "content-type": "application/octet-stream", "content-length": String(data.byteLength), ...noStore } });
  }
  if (path === "/updates") {
    return new Response(installPage(release, origin), { headers: { "content-type": "text/html; charset=utf-8", ...noStore } });
  }
  return new Response("not found", { status: 404 });
};

export const config = { path: ["/updates", "/updates/*"] };
