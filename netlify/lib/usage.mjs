// Claude API usage by the aisle sorter (netlify/functions/aisles.mjs), kept as running totals in the "api-usage" blob
// store: one record per calendar month ("2026-11") and one for all time ("all"). Read by GET /api/usage for the
// iPhone app's Debug screen. Costs are estimates from list prices, not the Anthropic bill.
import { getStore } from "@netlify/blobs";

const store = () => getStore({ name: "api-usage", consistency: "strong" });

// US$ per million tokens: [input, output]. Cache reads are 0.05x input and 5-minute cache writes 1.25x input.
const PRICES = {
  "claude-opus-5-5": [4, 20],
  "claude-opus-5": [5, 25],
  "claude-opus-4-8": [5, 25],
  "claude-opus-4-7": [5, 25],
  "claude-sonnet-5-5": [2, 10],
  "claude-sonnet-5": [2, 10],
  "claude-haiku-5-5": [0.1, 0.5],
};

export function costOf(model, u) {
  const [inp, out] = PRICES[model] || PRICES["claude-opus-5-5"];
  return ((u.input_tokens || 0) * inp + (u.output_tokens || 0) * out +
    (u.cache_read_input_tokens || 0) * inp * 0.05 + (u.cache_creation_input_tokens || 0) * inp * 1.25) / 1e6;
}

const empty = () => ({ calls: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, since: Date.now() });

/** Add one response's usage to this month's and the all-time totals. Never throws: usage is not worth a failed sort. */
export async function recordUsage(model, usage) {
  try {
    const s = store();
    const month = new Date().toISOString().slice(0, 7);
    for (const key of [month, "all"]) {
      const t = (await s.get(key, { type: "json" })) || empty();
      t.calls += 1;
      t.input += usage?.input_tokens || 0;
      t.output += usage?.output_tokens || 0;
      t.cacheRead += usage?.cache_read_input_tokens || 0;
      t.cacheWrite += usage?.cache_creation_input_tokens || 0;
      t.cost += costOf(model, usage || {});
      t.lastModel = model;
      t.lastAt = Date.now();
      await s.setJSON(key, t);
    }
  } catch (e) {
    console.error("recordUsage failed", e);
  }
}

export async function readUsage() {
  const s = store();
  const month = new Date().toISOString().slice(0, 7);
  return { month: (await s.get(month, { type: "json" })) || empty(), all: (await s.get("all", { type: "json" })) || empty(), monthKey: month };
}
