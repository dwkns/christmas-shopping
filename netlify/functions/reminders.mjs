// Daily to-do reminders at 08:00 UTC (8am in the UK in winter, 9am in summer).
// Each person gets one notification listing their to-dos that are due today or overdue.
// To-dos for "Anyone" go to everyone.
// Web push only: the iOS app schedules its own 08:00 reminder on the phone (ios/MillHouse/DueReminders.swift), so its
// APNs devices are left out here, or they would get the reminder twice.
import { getStore } from "@netlify/blobs";
import { allSubs, dueLabel, sameName, send, todayUK } from "../lib/push.mjs";

export default async () => {
  const items = getStore({ name: "shopping-items", consistency: "strong" });
  const { blobs } = await items.list();
  const all = (await Promise.all(blobs.map((b) => items.get(b.key, { type: "json" })))).filter(Boolean);
  const today = todayUK();
  const due = all.filter((i) => !i.deleted && i.type === "todo" && !i.done && i.due && i.due <= today);
  if (!due.length) return;

  const subs = (await allSubs()).filter((s) => s.kind !== "apns");
  await Promise.all(subs.map((sub) => {
    const mine = due.filter((t) => !t.assignee || sameName(t.assignee, sub.name));
    if (!mine.length) return null;
    const overdue = mine.filter((t) => t.due < today).length;
    const lines = mine.slice(0, 4).map((t) => `• ${t.name}${t.due < today ? ` (was due ${dueLabel(t.due)})` : ""}`);
    if (mine.length > 4) lines.push(`and ${mine.length - 4} more`);
    return send([sub], {
      title: overdue ? `${mine.length} to-do${mine.length > 1 ? "s" : ""} due (${overdue} overdue)` : `${mine.length} to-do${mine.length > 1 ? "s" : ""} due today`,
      body: lines.join("\n"),
      url: "/?view=todo",
      tag: "reminder",
    });
  }));
};

export const config = { schedule: "0 8 * * *" };
