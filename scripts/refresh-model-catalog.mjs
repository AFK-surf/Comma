#!/usr/bin/env node
// Update the committed input. Catalog generation and application startup stay offline.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const sources = JSON.parse(readFileSync(new URL("./model-sources.json", import.meta.url), "utf8"));
const url = "https://models.dev/api.json";
const response = await fetch(url, { signal: AbortSignal.timeout(30_000) });
if (!response.ok) throw new Error(`models.dev returned HTTP ${response.status}`);
const data = await response.json();
const fields = ["id", "name", "canonical_model_id", "type", "reasoning", "reasoning_options", "tool_call", "modalities", "limit", "cost"];
const providers = Object.fromEntries(
  [...new Set(Object.values(sources).map((source) => source.models_dev).filter(Boolean))].sort().map((id) => {
    if (!data[id]?.models) throw new Error(`Missing models.dev provider: ${id}`);
    return [id, { models: Object.fromEntries(Object.entries(data[id].models).sort(([a], [b]) => a.localeCompare(b)).map(([key, model]) => [key, {
      ...Object.fromEntries(fields.filter((field) => model[field] !== undefined).map((field) => [field, model[field]])),
      ...(model.provider?.npm ? { provider: { npm: model.provider.npm } } : {}),
    }])) }];
  })
);
const snapshot = { source: url, license: "https://github.com/anomalyco/models.dev/blob/dev/LICENSE", retrieved_at: new Date().toISOString(), providers };
const path = fileURLToPath(new URL("./models-dev.snapshot.json", import.meta.url));
// One model per line keeps snapshot updates readable in code review.
const { providers: entries, ...metadata } = snapshot;
const rows = Object.entries(entries).map(([id, provider]) => {
  const models = Object.entries(provider.models).map(([key, model]) => `   ${JSON.stringify(key)}: ${JSON.stringify(model)}`).join(",\n");
  return `  ${JSON.stringify(id)}: {"models": {\n${models}\n  }}`;
}).join(",\n");
writeFileSync(path, `${JSON.stringify(metadata, null, 1).slice(0, -2)},\n "providers": {\n${rows}\n }\n}\n`);
console.log(`Saved ${Object.keys(providers).length} providers to ${path}. Run node scripts/generate-model-catalog.mjs.`);
