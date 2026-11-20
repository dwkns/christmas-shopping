import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { getStore } from "@netlify/blobs";
import { z } from "zod";

// Supermarket sections in a typical large Sainsbury's walk order.
// Keep this list in sync with AISLES in public/app.js.
export const AISLES = [
  "Fruit & Veg",
  "Bakery",
  "Meat & Poultry",
  "Fish & Seafood",
  "Deli & Cheese",
  "Dairy & Eggs",
  "Chilled & Ready Meals",
  "Frozen",
  "Food Cupboard",
  "Baking & Home Cooking",
  "World Foods",
  "Cereals & Spreads",
  "Tea & Coffee",
  "Crisps & Snacks",
  "Chocolate & Sweets",
  "Soft Drinks & Juice",
  "Beer, Wine & Spirits",
  "Christmas & Seasonal",
  "Household",
  "Health & Beauty",
  "Baby",
  "Pet",
  "Home & Clothing",
];

const Result = z.object({
  items: z.array(z.object({ name: z.string(), aisle: z.enum(AISLES) })),
});

// Cache: one blob per normalised item name -> aisle. Each name is classified once.
const cache = () => getStore({ name: "aisle-cache", consistency: "strong" });
const norm = (s) => String(s).trim().toLowerCase().replace(/\s+/g, " ").slice(0, 200);
const cacheKey = (n) => encodeURIComponent(n).slice(0, 590);

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

async function classify(names) {
  const apiKey =
    process.env.ANTHROPIC_KEY || process.env.ANTHOPIC_KEY || process.env.ANTHROPIC_API_KEY;
  if (!apiKey) throw new Error("No Anthropic API key set");
  const client = new Anthropic({ apiKey });

  const response = await client.beta.messages.parse({
    model: "claude-opus-5-5",
    max_tokens: 16000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: { effort: "low", format: betaZodOutputFormat(Result) },
    system:
      "You sort shopping-list items into the section of a large UK Sainsbury's superstore " +
      "(for example Sainsbury's Haverhill) where a shopper would find them. " +
      `Use only these sections: ${AISLES.join("; ")}. ` +
      "Use 'Christmas & Seasonal' only for seasonal-only products such as crackers, " +
      "Christmas puddings, mince pies or festive decorations. Fresh turkey goes in Meat & Poultry. " +
      "Return exactly one entry per input item, with the name copied exactly as given.",
    messages: [{ role: "user", content: names.map((n) => `- ${n}`).join("\n") }],
  });

  if (response.stop_reason === "refusal" || !response.parsed_output) {
    throw new Error(`Classification failed: ${response.stop_reason}`);
  }
  return response.parsed_output.items;
}

export default async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  let body;
  try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }
  const names = [...new Set((Array.isArray(body?.names) ? body.names : []).map(norm).filter(Boolean))].slice(0, 150);

  const store = cache();
  const out = {};
  const unknown = [];
  await Promise.all(
    names.map(async (n) => {
      const hit = await store.get(cacheKey(n));
      if (hit && AISLES.includes(hit)) out[n] = hit; else unknown.push(n);
    })
  );

  if (unknown.length) {
    try {
      const results = await classify(unknown);
      for (const r of results) {
        const n = norm(r.name);
        if (!unknown.includes(n)) continue;
        out[n] = r.aisle;
        await store.set(cacheKey(n), r.aisle);
      }
    } catch (e) {
      console.error(e);
      return json({ aisles: out, error: String(e.message || e) }, 502);
    }
  }
  return json({ aisles: out });
};

export const config = { path: "/api/aisles" };
