import { getStore } from "@netlify/blobs";

// Each item is one blob: key = item id. Deleted items stay as tombstones
// ({ deleted: true }) so offline devices learn about deletions.
const store = () => getStore({ name: "shopping-items", consistency: "strong" });

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

const validId = (id) => typeof id === "string" && /^[A-Za-z0-9_-]{6,64}$/.test(id);

export default async (req) => {
  const s = store();

  if (req.method === "GET") {
    const { blobs } = await s.list();
    const items = await Promise.all(blobs.map((b) => s.get(b.key, { type: "json" })));
    return json({ items: items.filter(Boolean), now: Date.now() });
  }

  if (req.method === "POST") {
    // Body: { changes: [item, ...] } — each item carries updatedAt; newest wins.
    let body;
    try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }
    const changes = Array.isArray(body?.changes) ? body.changes.slice(0, 500) : [];
    const results = [];
    for (const c of changes) {
      if (!c || !validId(c.id) || typeof c.updatedAt !== "number") continue;
      const current = await s.get(c.id, { type: "json" });
      if (current && current.updatedAt > c.updatedAt) { results.push(current); continue; }
      const item = c.deleted
        ? { id: c.id, deleted: true, updatedAt: c.updatedAt }
        : {
            id: c.id,
            name: String(c.name || "").slice(0, 200),
            qty: String(c.qty || "").slice(0, 40),
            day: String(c.day || "").slice(0, 20),
            meal: String(c.meal || "").slice(0, 20),
            done: !!c.done,
            by: String(c.by || "").slice(0, 40),
            color: /^#[0-9a-fA-F]{6}$/.test(c.color || "") ? c.color : "",
            createdAt: Number(c.createdAt) || c.updatedAt,
            updatedAt: c.updatedAt,
          };
      await s.setJSON(c.id, item);
      results.push(item);
    }
    return json({ items: results });
  }

  return json({ error: "method not allowed" }, 405);
};

export const config = { path: "/api/items" };
