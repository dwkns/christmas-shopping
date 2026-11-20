// App shell: network-first, so a new deploy shows on the next open.
// Falls back to the cache when offline or when the network is slow (>3 s).
// List data is held in localStorage by app.js.
const CACHE = "cs-shell-v6";
const SHELL = ["/", "/index.html", "/style.css", "/app.js", "/version.js", "/manifest.webmanifest", "/icons/icon.svg", "/icons/icon-180.png", "/icons/icon-512.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE)
      .then((c) => c.addAll(SHELL.map((u) => new Request(u, { cache: "reload" }))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin || url.pathname.startsWith("/api/")) return;

  const key = e.request.mode === "navigate" ? "/index.html" : url.pathname;
  e.respondWith(
    caches.open(CACHE).then(async (cache) => {
      const network = fetch(e.request, { cache: "no-cache" }).then((res) => {
        if (res.ok) cache.put(key, res.clone());
        return res;
      });
      const timeout = new Promise((resolve) => setTimeout(resolve, 3000));
      try {
        const res = await Promise.race([network, timeout]);
        if (res) return res;
      } catch {}
      return (await cache.match(key)) || network;
    })
  );
});
