#!/usr/bin/env node
// Generates systems/apps/salix_agent/priv/model_catalog.json from the provider
// model data that ships with @earendil-works/pi-ai.
//
// One catalog model gathers every source that serves it under its own request
// id: `gpt-5.5` is `gpt-5.5` at OpenAI and `openai/gpt-5.5` at OpenRouter.
// Run `node scripts/generate-model-catalog.mjs` after bumping pi-ai; `--check`
// fails when the committed file differs from what the installed pi-ai yields.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const piRoot = join(root, "node_modules/@earendil-works/pi-ai");
const piVersion = JSON.parse(readFileSync(join(piRoot, "package.json"), "utf8")).version;
const dataDir = join(piRoot, "dist", "providers", "data");
const output = join(root, "systems/apps/salix_agent/priv/model_catalog.json");

// pi wire APIs that Salix speaks, as Salix template protocols.
const protocols = {
  "anthropic-messages": "anthropic",
  "openai-completions": "chat_completions",
  "openai-responses": "responses",
  "azure-openai-responses": "responses",
  "openai-codex-responses": "responses",
};

// A source is what a Profile connects to. `pi` names the pi provider whose
// model list it serves; `vendor` marks a model maker's own API, whose ids and
// names are canonical. `protocol` overrides pi's API where the source also
// offers a compatible endpoint Salix speaks.
const sources = {
  openai: { name: "OpenAI", kind: "api_key", pi: "openai", vendor: "openai" },
  anthropic: { name: "Anthropic", kind: "api_key", pi: "anthropic", vendor: "anthropic" },
  google: {
    name: "Google Gemini",
    kind: "api_key",
    pi: "google",
    vendor: "google",
    protocol: "chat_completions",
    base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
  },
  xai: { name: "xAI", kind: "api_key", pi: "xai", vendor: "xai" },
  mistral: {
    name: "Mistral",
    kind: "api_key",
    pi: "mistral",
    vendor: "mistral",
    protocol: "chat_completions",
    base_url: "https://api.mistral.ai/v1",
  },
  deepseek: { name: "DeepSeek", kind: "api_key", pi: "deepseek", vendor: "deepseek" },
  qwen: { name: "Qwen", kind: "api_key", pi: "qwen-token-plan" },
  "qwen-cn": { name: "Qwen (China)", kind: "api_key", pi: "qwen-token-plan-cn" },
  moonshotai: { name: "Kimi", kind: "api_key", pi: "moonshotai", vendor: "kimi" },
  "moonshotai-cn": { name: "Kimi (China)", kind: "api_key", pi: "moonshotai-cn", vendor: "kimi" },
  zai: { name: "Z.ai", kind: "api_key", pi: "zai", vendor: "glm" },
  "zai-coding-cn": { name: "Z.ai Coding (China)", kind: "api_key", pi: "zai-coding-cn", vendor: "glm" },
  minimax: { name: "MiniMax", kind: "api_key", pi: "minimax", vendor: "minimax" },
  "minimax-cn": { name: "MiniMax (China)", kind: "api_key", pi: "minimax-cn", vendor: "minimax" },
  xiaomi: { name: "Xiaomi MiMo", kind: "api_key", pi: "xiaomi", vendor: "xiaomi" },
  "ant-ling": { name: "Ant Ling", kind: "api_key", pi: "ant-ling", vendor: "ant-ling" },
  openrouter: { name: "OpenRouter", kind: "api_key", pi: "openrouter" },
  "vercel-ai-gateway": { name: "Vercel AI Gateway", kind: "api_key", pi: "vercel-ai-gateway" },
  opencode: { name: "OpenCode Zen", kind: "api_key", pi: "opencode" },
  "opencode-go": { name: "OpenCode Go", kind: "api_key", pi: "opencode-go" },
  "cloudflare-workers-ai": { name: "Cloudflare Workers AI", kind: "api_key", pi: "cloudflare-workers-ai" },
  "cloudflare-ai-gateway": { name: "Cloudflare AI Gateway", kind: "api_key", pi: "cloudflare-ai-gateway" },
  "azure-openai": { name: "Azure OpenAI", kind: "api_key", pi: "azure-openai-responses", base_url: null },
  groq: { name: "Groq", kind: "api_key", pi: "groq" },
  cerebras: { name: "Cerebras", kind: "api_key", pi: "cerebras" },
  together: { name: "Together AI", kind: "api_key", pi: "together" },
  fireworks: { name: "Fireworks", kind: "api_key", pi: "fireworks" },
  huggingface: { name: "Hugging Face", kind: "api_key", pi: "huggingface" },
  nvidia: { name: "NVIDIA", kind: "api_key", pi: "nvidia" },
  baseten: { name: "Baseten", kind: "api_key", pi: "baseten" },
  // Subscriptions sign in to a consumer plan; the subscription worker holds
  // the credential and serves the plan's models.
  codex: { name: "ChatGPT", kind: "subscription", pi: "openai-codex", vendor: "openai" },
  claude: { name: "Claude", kind: "subscription", pi: "anthropic", vendor: "anthropic" },
  gemini: { name: "Google AI", kind: "subscription", pi: "google", vendor: "google", protocol: "chat_completions" },
  grok: { name: "SuperGrok", kind: "subscription", pi: "xai", vendor: "xai" },
  "kimi-code": { name: "Kimi Code", kind: "subscription", pi: "kimi-coding", vendor: "kimi" },
  "github-copilot": { name: "GitHub Copilot", kind: "subscription", pi: "github-copilot" },
};

// Makers named by an aggregator's path prefix or a model id's first word.
const prefixVendors = {
  openai: "openai",
  anthropic: "anthropic",
  google: "google",
  "x-ai": "xai",
  xai: "xai",
  deepseek: "deepseek",
  "deepseek-ai": "deepseek",
  mistralai: "mistral",
  moonshotai: "kimi",
  "z-ai": "glm",
  "zai-org": "glm",
  minimax: "minimax",
  minimaxai: "minimax",
  qwen: "qwen",
  "meta-llama": "meta",
  meta: "meta",
  xiaomi: "xiaomi",
  xiaomimimo: "xiaomi",
  nvidia: "nvidia",
  inclusionai: "ant-ling",
};
const wordVendors = [
  [/^(claude)/, "anthropic"],
  [/^(gpt|o\d|chatgpt|codex)/, "openai"],
  [/^(gemini|gemma)/, "google"],
  [/^grok/, "xai"],
  [/^deepseek/, "deepseek"],
  [/^(kimi|k\d)/, "kimi"],
  [/^glm/, "glm"],
  [/^minimax/, "minimax"],
  [/^(qwen|qwq)/, "qwen"],
  [/^mimo/, "xiaomi"],
  [/^llama/, "meta"],
  [/^(mistral|devstral|codestral|magistral|ministral|pixtral|mixtral)/, "mistral"],
  [/^(ling|ring)-/, "ant-ling"],
  [/^nemotron/, "nvidia"],
];
// Names that are recognisable without their maker drop it, so a picker grouped
// by maker reads "Opus 5" rather than "Claude Opus 5".
const shortNames = [[/^Claude (Opus|Sonnet|Haiku|Fable) /, "$1 "]];

const skipped = /(realtime|image|live|tts|transcribe|embedding|computer-use|deep-research|moderation|guard)/;
// Gateway pricing tiers of a model, not models of their own.
const tiers = /(-fast|-free|-flex|-priority)$|\((fast|free|\d+% off)\)/i;
const effortOrder = ["minimal", "low", "medium", "high", "xhigh", "max"];

const tail = (id) => id.replace(/^@cf\//, "").split("/").at(-1);

// Ids that name the same model across sources share a key.
function modelKey(source, id) {
  let key = tail(id).toLowerCase();
  if (source === "fireworks") key = key.replace(/(\d)p(\d)/g, "$1.$2");
  return key
    .replace(/@.*$/, "")
    .replace(/-v\d+:\d+$/, "")
    .replace(/-(\d{8}|\d{4}-\d{2}-\d{2})$/, "")
    .replace(/[._]/g, "-");
}

function vendorOf(source, id) {
  if (sources[source].vendor) return sources[source].vendor;
  const parts = id.replace(/^@cf\//, "").split("/");
  if (parts.length > 1) {
    const vendor = prefixVendors[parts.at(-2).toLowerCase()];
    if (vendor) return vendor;
  }
  const word = tail(id).toLowerCase();
  return wordVendors.find(([pattern]) => pattern.test(word))?.[1] ?? "other";
}

function efforts(entry) {
  if (!entry.reasoning) return [];
  const map = entry.thinkingLevelMap ?? {};
  return effortOrder.filter((level) =>
    level in map ? map[level] !== null : ["low", "medium", "high"].includes(level)
  );
}

const display = (name) =>
  shortNames.reduce(
    (value, [pattern, replacement]) => value.replace(pattern, replacement),
    name.replace(/^[^:]+:\s*/, "").replace(/\s*\(latest\)$/i, "")
  );

const models = new Map();
const canonicalFirst = Object.entries(sources).sort(
  ([, a], [, b]) => Number(Boolean(b.vendor) && b.kind === "api_key") - Number(Boolean(a.vendor) && a.kind === "api_key")
);

for (const [source, config] of canonicalFirst) {
  const data = JSON.parse(readFileSync(join(dataDir, `${config.pi}.json`), "utf8"));
  for (const [api, entries] of Object.entries(data)) {
    const protocol = config.protocol ?? protocols[api];
    if (!protocol) continue;
    for (const entry of Object.values(entries)) {
      if (entry.id.includes(":") || skipped.test(entry.id.toLowerCase())) continue;
      if (tiers.test(entry.id) || tiers.test(entry.name ?? "")) continue;
      const key = modelKey(source, entry.id);
      const vendor = vendorOf(source, entry.id);
      let model = models.get(key);
      if (!model) {
        model = {
          id: config.vendor && config.kind === "api_key" ? entry.id.replace(/-(\d{8}|\d{4}-\d{2}-\d{2})$/, "") : tail(entry.id).toLowerCase(),
          name: display(entry.name ?? entry.id),
          vendor,
          efforts: efforts(entry),
          images: (entry.input ?? []).includes("image"),
          context_tokens: entry.contextWindow ?? null,
          max_tokens: entry.maxTokens ?? null,
          routes: {},
        };
        models.set(key, model);
      }
      // A dated snapshot never replaces the alias a source already lists.
      if (!model.routes[source] || entry.id.length < model.routes[source].model.length)
        model.routes[source] = { model: entry.id, protocol };
    }
  }
}

const vendorOrder = ["openai", "anthropic", "google", "xai", "deepseek", "qwen", "kimi", "glm", "minimax", "mistral", "xiaomi", "ant-ling", "meta", "nvidia", "other"];
const sorted = [...models.values()].sort(
  (a, b) =>
    vendorOrder.indexOf(a.vendor) - vendorOrder.indexOf(b.vendor) ||
    a.name.localeCompare(b.name, "en", { numeric: true })
);

const catalog = {
  generated_from: `@earendil-works/pi-ai@${piVersion}`,
  sources: Object.fromEntries(
    Object.entries(sources).map(([id, { name, kind, base_url }]) => [
      id,
      { name, kind, ...(base_url !== undefined ? { base_url } : {}) },
    ])
  ),
  models: sorted,
};

const text = `${JSON.stringify(catalog, null, 1)}\n`;
if (process.argv.includes("--check")) {
  if (readFileSync(output, "utf8") !== text) {
    console.error(`${output} is stale; run node scripts/generate-model-catalog.mjs`);
    process.exit(1);
  }
} else {
  writeFileSync(output, text);
  console.log(`${sorted.length} models from ${Object.keys(sources).length} sources -> ${output}`);
}
