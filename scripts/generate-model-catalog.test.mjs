import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildCatalog, lostSince } from "./generate-model-catalog.mjs";

const sources = JSON.parse(readFileSync(new URL("./model-sources.json", import.meta.url), "utf8"));
function input() {
  const providers = Object.fromEntries(Object.values(sources).filter((s) => s.models_dev).map((s) => [s.models_dev, { models: {} }]));
  const model = (id, cost) => ({ id, name: id, tool_call: true, reasoning: true, reasoning_options: [{ type: "effort", values: ["low", "high"] }], modalities: { input: ["text", "image"] }, limit: { context: 1050000, output: 128000 }, cost });
  providers.openai.models = {
    "gpt-6.1-terra": model("gpt-6.1-terra", { input: 1, output: 5, cache_read: 0.05, cache_write: 1.25 }),
    "gpt-4.1": model("gpt-4.1", { input: 2, output: 8 }),
  };
  providers.openrouter.models["openai/gpt-6.1-terra"] = model("openai/gpt-6.1-terra", { input: 0.1, output: 0.2 });
  providers.minimax.models["MiniMax-M2.5"] = model("MiniMax-M2.5", { input: 0.3, output: 1.2 });
  return { retrieved_at: "fixture", providers };
}

test("vendor prices join gateway and subscription routes while Codex keeps its own limits", () => {
  const { catalog } = buildCatalog(input(), {});
  const terra = catalog.models.find((m) => m.id === "gpt-6.1-terra");
  assert.deepEqual(terra.price, { input: 1, output: 5, cache_read: 0.05, cache_write: 1.25 });
  assert.deepEqual(terra.routes.openrouter, { model: "openai/gpt-6.1-terra", protocol: "chat_completions" });
  assert.deepEqual(terra.routes.codex, { model: "gpt-6.1-terra", protocol: "responses" });
  assert.equal(terra.context_tokens, 200000);
  assert.ok(terra.efforts.includes("ultra"));
  assert.equal(catalog.models.find((m) => m.id === "gpt-4.1").routes.codex, undefined);
  assert.deepEqual(catalog.models.find((m) => m.id === "gpt-4.1").efforts, ["low", "high"]);
  assert.deepEqual(catalog.models.find((m) => m.id === "minimax-m2.5").routes.minimax, { model: "MiniMax-M2.5", protocol: "anthropic" });
});

test("Cloudflare AI Gateway keeps the makers' own ids and relays Workers AI", () => {
  const snapshot = input();
  const { models } = snapshot.providers["cloudflare-ai-gateway"];
  models["openai/gpt-6.1-terra"] = { ...snapshot.providers.openai.models["gpt-6.1-terra"], id: "openai/gpt-6.1-terra" };
  models["minimax/m3.1-flash"] = { ...models["openai/gpt-6.1-terra"], id: "minimax/m3.1-flash", name: "m3.1-flash" };
  snapshot.providers["cloudflare-workers-ai"].models["@cf/zai-org/glm-5.3"] = { id: "@cf/zai-org/glm-5.3", name: "GLM-5.3", tool_call: true };
  const { catalog } = buildCatalog(snapshot, {});
  const routes = (id) => catalog.models.find((m) => m.id === id)?.routes;
  assert.deepEqual(routes("gpt-6.1-terra")["cloudflare-ai-gateway"], { model: "gpt-6.1-terra", protocol: "responses" });
  assert.deepEqual(routes("glm-5.3")["cloudflare-ai-gateway"], { model: "workers-ai/@cf/zai-org/glm-5.3", protocol: "chat_completions" });
  assert.equal(catalog.models.some((m) => m.routes["cloudflare-ai-gateway"]?.model.includes("m3.1-flash")), false);
});

test("GPT-5.6 and later OpenAI families keep a 200K context window, earlier models their own", () => {
  const snapshot = JSON.parse(readFileSync(new URL("./models-dev.snapshot.json", import.meta.url), "utf8"));
  const { catalog } = buildCatalog(snapshot);
  const capped = catalog.models.filter((m) => m.vendor === "openai" && /^GPT (Astra|Luna|Sol|Terra)\b/.test(m.family));
  assert.ok(capped.length >= 8, `only ${capped.length} capped models`);
  for (const model of capped) assert.ok(model.context_tokens <= 200000, `${model.id}: ${model.context_tokens}`);
  assert.equal(catalog.models.find((m) => m.id === "gpt-5.6").context_tokens, 200000);
  assert.equal(catalog.models.find((m) => m.id === "gpt-5.5").context_tokens, 272000);
  assert.equal(catalog.models.find((m) => m.id === "gpt-5.4").context_tokens, 1050000);
  // The cap reaches a model the snapshot adds to a capped family later.
  const next = input();
  next.providers.openai.models["gpt-6.2-sol"] = { ...next.providers.openai.models["gpt-6.1-terra"], id: "gpt-6.2-sol", name: "GPT-6.2 Sol" };
  assert.equal(buildCatalog(next, {}).catalog.models.find((m) => m.id === "gpt-6.2-sol").context_tokens, 200000);
});

test("DeepSeek V4.1 Flash 1017 takes images on every route", () => {
  const snapshot = JSON.parse(readFileSync(new URL("./models-dev.snapshot.json", import.meta.url), "utf8"));
  const model = buildCatalog(snapshot).catalog.models.find(({ id }) => id === "deepseek-v4-1-flash-1017");
  assert.equal(model.images, true);
});

test("a model or route the previous catalog offered is lost unless restored or removed", () => {
  const before = buildCatalog(input(), {}).catalog;
  const snapshot = input();
  delete snapshot.providers.openai.models["gpt-4.1"];
  delete snapshot.providers.openrouter.models["openai/gpt-6.1-terra"];
  const after = buildCatalog(snapshot, {}).catalog;
  assert.deepEqual(lostSince(before, after), ["gpt-4.1", "gpt-6.1-terra@openrouter"]);
  assert.deepEqual(lostSince(before, after, { "gpt-4.1": "retired", "gpt-6.1-terra@openrouter": "retired" }), []);

  const gpt41 = before.models.find((m) => m.id === "gpt-4.1");
  const restored = buildCatalog(snapshot, {
    models: [gpt41],
    routes: { "gpt-6.1-terra": { openrouter: { model: "openai/gpt-6.1-terra", protocol: "chat_completions" } } },
  }).catalog;
  assert.deepEqual(lostSince(before, restored), []);
  assert.throws(() => buildCatalog(input(), { models: [gpt41] }), /gpt-4.1 is generated now/);
});


test("rates the source does not list stay absent, and listed zeros stay", () => {
  const snapshot = input();
  snapshot.providers.openai.models["gpt-6.1-terra"].cost = { input: 1, output: 5, cache_read: 0 };
  const terra = buildCatalog(snapshot, {}).catalog.models.find((m) => m.id === "gpt-6.1-terra");
  assert.deepEqual(terra.price, { input: 1, output: 5, cache_read: 0 });
});

test("context tiers retain the price source and leave flat rates usable on their own", () => {
  const snapshot = input();
  const tiers = [{ input: 2, output: 7.5, cache_read: 0.1, cache_write: 2.5, tier: { type: "context", size: 272000 } }];
  snapshot.providers.openai.models["gpt-6.1-terra"].cost.tiers = tiers;
  snapshot.providers.openrouter.models["openai/gpt-6.1-terra"].cost.tiers = [{ input: 99, tier: { type: "context", size: 1000 } }];
  const terra = buildCatalog(snapshot, {}).catalog.models.find((m) => m.id === "gpt-6.1-terra");
  assert.deepEqual(terra.price, { input: 1, output: 5, cache_read: 0.05, cache_write: 1.25 });
  assert.deepEqual(terra.price_tiers, tiers);
});
