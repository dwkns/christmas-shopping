// GET /api/usage: Claude API tokens used by the aisle sorter, this month and all time, with an estimated cost.
import { readUsage } from "../lib/usage.mjs";

export default async () =>
  new Response(JSON.stringify(await readUsage()), {
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

export const config = { path: "/api/usage" };
