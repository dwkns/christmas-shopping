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
// Everyone a to-do is for: `assignees` (iPhone 0.1.21+), else the single `assignee`; empty means anyone.
const whoOf = (t) => (Array.isArray(t?.assignees) && t.assignees.length ? t.assignees : t?.assignee ? [t.assignee] : []);
const sameWho = (a, b) => {
  const x = whoOf(a).map((n) => n.toLowerCase()).sort(), y = whoOf(b).map((n) => n.toLowerCase()).sort();
  return x.length === y.length && x.every((n, i) => n === y[i]);
};
const cleanNames = (v) => [...new Set((Array.isArray(v) ? v : []).map((n) => String(n || "").trim().slice(0, 40)).filter(Boolean))].slice(0, 12);
const list = (names) => names.length <= 2 ? names.join(" and ") : `${names.slice(0, 2).join(", ")} and ${names.length - 2} more`;

// Work out who to notify about this batch of changes, then send.
async function notify(actor, events) {
  const { added, assigned } = events;
  if (!added.length && !assigned.length) return;
  const subs = (await allSubs()).filter((s) => !actor || !sameName(s.name, actor));
  if (!subs.length) return;
  const who = actor ? firstName(actor) : "Someone";
  const jobs = [];

  // iPhones choose in Settings: shopping notifications are off unless turned on, to-dos on unless turned off.
  // Web push subscriptions have no such setting and get both.
  const wantsShopping = (s) => s.kind !== "apns" || s.shopping === true;
  const wantsTodos = (s) => s.kind !== "apns" || s.todos !== false;

  if (added.length && subs.some(wantsShopping)) {
    jobs.push(send(subs.filter(wantsShopping), {
      title: "Shopping list",
      body: `${who} added ${list(added.map((i) => i.name))}`,
      url: "/?view=shop",
      tag: "shopping",
    }));
  }
  for (const t of assigned) {
    const who = whoOf(t);
    const targets = (who.length ? subs.filter((s) => who.some((n) => sameName(s.name, n))) : subs).filter(wantsTodos);
    if (!targets.length) continue;
    const due = t.due ? ` (by ${dueLabel(t.due)})` : "";
    jobs.push(send(targets, {
      title: who.length ? "New to-do for you" : "New to-do for anyone",
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
            assignees: cleanNames(c.assignees),
            assignee: cleanNames(c.assignees)[0] || String(c.assignee || "").slice(0, 40),
            assigneeColor: /^#[0-9a-fA-F]{6}$/.test(c.assigneeColor || "") ? c.assigneeColor : "",
            due: validDate(c.due) ? c.due : "",
            when: ["soon", "norush"].includes(c.when) ? c.when : "", // the iPhone app's undated When choices
            notes: String(c.notes || "").slice(0, 4000),
            doneAt: c.done ? Number(c.doneAt) || 0 : 0, // when it was ticked off, and by whom
            doneBy: c.done ? String(c.doneBy || "").slice(0, 40) : "",
            editedBy: String(c.editedBy || "").slice(0, 40), // who saved it last
            createdAt: Number(c.createdAt) || c.updatedAt,
            updatedAt: c.updatedAt,
          };
      await s.setJSON(c.id, item);
      results.push(item);

      // Notification events: only for brand-new items and changed to-do assignees.
      if (item.deleted || item.done) continue;
      const isNew = !current || current.deleted;
      if (type === "todo") {
        if (isNew || !sameWho(current, item)) {
          const who = whoOf(item);
          if (!who.length || who.some((n) => !sameName(n, actor))) events.assigned.push(item);
        }
      } else if (isNew) {
        events.added.push(item);
      }
    }

    // Send notifications after the response, so saving stays fast. `silent: true` (edits made by Claude on the
    // user's behalf) saves without notifying anyone.
    if (body?.silent === true) return json({ items: results });
    const work = notify(actor, events).catch((e) => console.error("notify failed", e));
    if (context?.waitUntil) context.waitUntil(work); else await work;
    return json({ items: results });
  }

  return json({ error: "method not allowed" }, 405);
};

export const config = { path: "/api/items" };
