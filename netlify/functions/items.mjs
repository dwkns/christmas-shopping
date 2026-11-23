import { getStore } from "@netlify/blobs";
import { allSubs, dueLabel, firstName, sameName, send } from "../lib/push.mjs";

// Each item is one blob: key = item id. Deleted items stay as tombstones
// ({ deleted: true }) so offline devices learn about deletions.
// Shopping items have type ""; to-dos have type "todo".
const store = () => getStore({ name: "shopping-items", consistency: "strong" });

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

const validId = (id) => typeof id === "string" && /^[A-Za-z0-9_-]{6,64}$/.test(id);
const validDate = (d) => /^\d{4}-\d{2}-\d{2}$/.test(d || "");
const list = (names) => names.length <= 2 ? names.join(" and ") : `${names.slice(0, 2).join(", ")} and ${names.length - 2} more`;

// Work out who to notify about this batch of changes, then send.
async function notify(actor, events) {
  const { added, assigned } = events;
  if (!added.length && !assigned.length) return;
  const subs = (await allSubs()).filter((s) => !actor || !sameName(s.name, actor));
  if (!subs.length) return;
  const who = actor ? firstName(actor) : "Someone";
  const jobs = [];

  if (added.length) {
    jobs.push(send(subs, {
      title: "Shopping list",
      body: `${who} added ${list(added.map((i) => i.name))}`,
      url: "/?view=shop",
      tag: "shopping",
    }));
  }
  for (const t of assigned) {
    const targets = t.assignee ? subs.filter((s) => sameName(s.name, t.assignee)) : subs;
    const due = t.due ? ` (by ${dueLabel(t.due)})` : "";
    jobs.push(send(targets, {
      title: t.assignee ? "New to-do for you" : "New to-do for anyone",
      body: `${who}: ${t.name}${due}`,
      url: "/?view=todo",
      tag: `todo-${t.id}`,
    }));
  }
  await Promise.all(jobs);
}

export default async (req, context) => {
  const s = store();

  if (req.method === "GET") {
    const { blobs } = await s.list();
    const items = await Promise.all(blobs.map((b) => s.get(b.key, { type: "json" })));
    return json({ items: items.filter(Boolean), now: Date.now() });
  }

  if (req.method === "POST") {
    // Body: { changes: [item, ...], actor } — each item carries updatedAt; newest wins.
    let body;
    try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }
    const changes = Array.isArray(body?.changes) ? body.changes.slice(0, 500) : [];
    const actor = String(body?.actor || "").slice(0, 40);
    const results = [];
    const events = { added: [], assigned: [] };

    for (const c of changes) {
      if (!c || !validId(c.id) || typeof c.updatedAt !== "number") continue;
      const current = await s.get(c.id, { type: "json" });
      if (current && current.updatedAt > c.updatedAt) { results.push(current); continue; }
      const type = c.type === "todo" ? "todo" : "";
      const item = c.deleted
        ? { id: c.id, deleted: true, updatedAt: c.updatedAt }
        : {
            id: c.id,
            type,
            name: String(c.name || "").slice(0, 200),
            qty: String(c.qty || "").slice(0, 40),
            day: String(c.day || "").slice(0, 20),
            meal: String(c.meal || "").slice(0, 20),
            done: !!c.done,
            by: String(c.by || "").slice(0, 40),
            color: /^#[0-9a-fA-F]{6}$/.test(c.color || "") ? c.color : "",
            assignee: String(c.assignee || "").slice(0, 40),
            assigneeColor: /^#[0-9a-fA-F]{6}$/.test(c.assigneeColor || "") ? c.assigneeColor : "",
            due: validDate(c.due) ? c.due : "",
            createdAt: Number(c.createdAt) || c.updatedAt,
            updatedAt: c.updatedAt,
          };
      await s.setJSON(c.id, item);
      results.push(item);

      // Notification events: only for brand-new items and changed to-do assignees.
      if (item.deleted || item.done) continue;
      const isNew = !current || current.deleted;
      if (type === "todo") {
        if (isNew || !sameName(current.assignee, item.assignee)) {
          if (!item.assignee || !sameName(item.assignee, actor)) events.assigned.push(item);
        }
      } else if (isNew) {
        events.added.push(item);
      }
    }

    // Send notifications after the response, so saving stays fast.
    const work = notify(actor, events).catch((e) => console.error("notify failed", e));
    if (context?.waitUntil) context.waitUntil(work); else await work;
    return json({ items: results });
  }

  return json({ error: "method not allowed" }, 405);
};

export const config = { path: "/api/items" };
