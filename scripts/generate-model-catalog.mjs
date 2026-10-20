#!/usr/bin/env node
// Generates systems/apps/salix_agent/priv/model_catalog.json from the provider
// model data that ships with @earendil-works/pi-ai and provider additions below.
//
// One catalog model gathers every source that serves it under its own request
// id: `gpt-5.5` is `gpt-5.5` at OpenAI and `openai/gpt-5.5` at OpenRouter.
// Run `node scripts/generate-model-catalog.mjs` after bumping pi-ai; `--check`
// fails when the committed file differs from what the installed pi-ai yields.
//
// The Gemini plan runs on Antigravity, whose model ids are not AI Studio's.
// Its routes come from scripts/antigravity-models.json, extracted from the
// pinned CLIProxyAPI SDK registry. Refresh it when the SDK pin changes.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const piRoot = join(root, "node_modules/@earendil-works/pi-ai");
const piVersion = JSON.parse(readFileSync(join(piRoot, "package.json"), "utf8")).version;
const dataDir = join(piRoot, "dist", "providers", "data");
const output = join(root, "systems/apps/salix_agent/priv/model_catalog.json");
// The sources as the Profiles of Comma and its stations both use them (systems/profiles).
const profilesOutput = join(root, "systems/profiles/sources.json");

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
  anthropic: { name: "Anthropic", kind: "api_key", pi: "anthropic", vendor: "anthropic", auth: "api_key" },
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
  opencode: { name: "OpenCode Zen", kind: "api_key", pi: "opencode", auth: "api_key", session_header: true },
  "opencode-go": { name: "OpenCode Go", kind: "api_key", pi: "opencode-go", auth: "api_key", session_header: true },
  "cloudflare-workers-ai": { name: "Cloudflare Workers AI", kind: "api_key", pi: "cloudflare-workers-ai" },
  "cloudflare-ai-gateway": { name: "Cloudflare AI Gateway", kind: "api_key", pi: "cloudflare-ai-gateway", auth: "both" },
  "azure-openai": { name: "Azure OpenAI", kind: "api_key", pi: "azure", base_url: null },
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
  gemini: { name: "Google AI", kind: "subscription", vendor: "google" },
  grok: { name: "SuperGrok", kind: "subscription", pi: "xai", vendor: "xai" },
  "kimi-code": { name: "Kimi Code", kind: "subscription", pi: "kimi-coding", vendor: "kimi" },
  "github-copilot": { name: "GitHub Copilot", kind: "subscription", pi: "github-copilot" },
};

// Sources only a station reaches: an address on the station's own network, and
// the decision endpoint its automatic decisions ask. Not offered to Comma.
const stationSources = {
  jev: { name: "Jev", kind: "api_key", endpoints: { decision: "https://api.typesafe.ai/v1" }, protocols: [] },
  ollama: { name: "Ollama", kind: "api_key", endpoints: {}, protocols: ["chat_completions"], endpoint_required: true, key_optional: true },
};

// Sources only the platform's own Profiles reach: internal gateways behind the
// platform model. Neither members nor stations see them. An adapter
// (SalixAgent.ProviderAdapters) adds what each needs beyond a key, such as
// LMHub's user agent.
const platformSources = {
  lmhub: {
    name: "LMHub",
    kind: "api_key",
    endpoints: {},
    protocols: ["chat_completions", "responses", "anthropic"],
    endpoint_required: true,
  },
};

// How the source pickers group them.
const groups = {
  gateways: ["openrouter", "vercel-ai-gateway", "opencode", "opencode-go", "cloudflare-ai-gateway"],
  hosted: ["azure-openai", "groq", "together", "fireworks", "cerebras", "huggingface", "nvidia", "baseten", "cloudflare-workers-ai"],
  local: ["ollama", "custom"],
};
const groupOf = (id) => Object.entries(groups).find(([, ids]) => ids.includes(id))?.[0] ?? "labs";

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
const shortNames = [
  [/^(Anthropic|OpenAI|Google|MoonshotAI|xAI)\s+(?=\S)/, ""],
  [/^Claude (Opus|Sonnet|Haiku|Fable)\b/, "$1"],
  [/^Claude (\d+(\.\d+)?) (Opus|Sonnet|Haiku)\b/, "$3 $1"],
];

const skipped = /(realtime|image|live|tts|transcribe|embedding|computer-use|deep-research|moderation|guard)/;
// Gateway pricing tiers of a model, not models of their own.
const tiers = /(-fast|-free|-flex|-priority)$/i;
// Gateway routing aliases and placeholders that name no model.
const aliases = new Set(["auto", "auto-beta", "free", "big-pickle"]);
// Ids a source uses for a model that the key rules cannot tie together.
const sameAs = { "kimi-code": { k3: "kimi-k3" } };
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
    .replace(/-latest$/, "")
    .replace(/^deepseek-chat-v/, "deepseek-v")
    .replace(/[._]/g, "-");
}

function vendorOf(source, id) {
  const word = tail(id).toLowerCase().replace(/^[a-z]+-(?=glm|kimi|qwen|deepseek)/, "");
  const named = wordVendors.find(([pattern]) => pattern.test(word))?.[1];
  // A maker's API can list another maker's model (Mistral serves GLM).
  if (sources[source].vendor) return named ?? sources[source].vendor;
  const parts = id.replace(/^@cf\//, "").split("/");
  if (parts.length > 1) {
    const vendor = prefixVendors[parts.at(-2).toLowerCase()];
    if (vendor) return vendor;
  }
  return named ?? "other";
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
    name
      .replace(/^[^:]+:\s*/, "")
      .replace(/\s*\((latest|\d+% off)\)$/i, "")
  );

// A family is the line a model belongs to across versions: Opus 4.8 and
// Opus 5 are both Opus, GPT-5.4 mini and GPT-5.5 mini are both GPT mini.
// It is the display name without version, size, date and release-stage words.
const familyNoise = /^(v|k|m)?\d+(\.\d+)*[a-z]?$|^\d+[bk]$|^a\d+b$|^\d{4}$|^(preview|latest|instruct|exp|experimental|it|thinking|turbo|chat|fp8|fast|highspeed|beta|v\d+(\.\d+)*)$/i;

function familyOf(name) {
  const words = name
    .replace(/\(.*?\)/g, " ")
    .split(/[\s-]+/)
    .filter((word) => word && !familyNoise.test(word))
    .map((word) => word.replace(/^([A-Za-z]+)\d+(\.\d+)*$/, "$1"));
  const family = words.join(" ") || name;
  // One label per family, whatever casing a gateway uses for it.
  return (familyLabels[family.toLowerCase()] ??= family);
}
const familyLabels = { "gpt oss": "GPT OSS", r: "DeepSeek R" };

const models = new Map();
// Where an API-key source answers each protocol. Subscriptions run through the
// subscription worker and have none. `{PLACEHOLDER}` or empty means the user
// supplies the endpoint.
const endpoints = {};
const canonicalFirst = Object.entries(sources).sort(
  ([, a], [, b]) => Number(Boolean(b.vendor) && b.kind === "api_key") - Number(Boolean(a.vendor) && a.kind === "api_key")
);

for (const [source, config] of canonicalFirst) {
  if (!config.pi) continue;
  const data = JSON.parse(readFileSync(join(dataDir, `${config.pi}.json`), "utf8"));
  for (const [api, entries] of Object.entries(data)) {
    const protocol = config.protocol ?? protocols[api];
    if (!protocol) continue;
    if (config.kind === "api_key") {
      const base = config.base_url ?? Object.values(entries)[0]?.baseUrl ?? "";
      (endpoints[source] ??= {})[protocol] ??= base;
    }
    for (const entry of Object.values(entries)) {
      if (entry.id.includes(":") || skipped.test(entry.id.toLowerCase())) continue;
      if (tiers.test(entry.id) || /\((fast|free)\)/i.test(entry.name ?? "")) continue;
      if (aliases.has(tail(entry.id).toLowerCase())) continue;
      const key = modelKey(source, sameAs[source]?.[entry.id] ?? entry.id);
      const vendor = vendorOf(source, entry.id);
      let model = models.get(key);
      if (!model) {
        model = {
          id: config.vendor && config.kind === "api_key" ? entry.id.replace(/-(\d{8}|\d{4}-\d{2}-\d{2})$/, "") : tail(entry.id).toLowerCase(),
          name: display(entry.name ?? entry.id),
          family: familyOf(display(entry.name ?? entry.id)),
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

// The Gemini plan serves what the subscription worker's Antigravity executor
// runs, by its own ids. A model the catalog already has gains the route; any
// other becomes a Google model of its own. Ids such as `-high` and `-low`
// name a fixed thinking level, so each is a model with no efforts. Antigravity
// also runs some Claude and GPT-OSS models; the plan offers Gemini only.
const antigravity = JSON.parse(readFileSync(join(root, "scripts/antigravity-models.json"), "utf8"));
for (const entry of antigravity.models) {
  if (!entry.id.startsWith("gemini-") || skipped.test(entry.id)) continue;
  const key = modelKey("gemini", entry.id);
  let model = models.get(key);
  if (!model) {
    const name = display(entry.description ?? entry.display_name ?? entry.id);
    model = {
      id: entry.id,
      name,
      family: familyOf(name),
      vendor: "google",
      efforts: [],
      images: (entry.supportedInputModalities ?? []).includes("image"),
      context_tokens: entry.context_length ?? null,
      max_tokens: entry.max_completion_tokens ?? null,
      routes: {},
    };
    models.set(key, model);
  }
  model.routes.gemini = { model: entry.id, protocol: "chat_completions" };
}

// Models released after the pinned pi data. Remove an addition when pi supplies
// its metadata and routes. Like pi's GPT entries, the context window is the
// 272K standard-price tier rather than the 1.05M API maximum.
// pi 1.1.0 lists every model that was added here (GPT-6 Luna, GPT-6.1 Sol,
// Claude 5.5), with routes for each source that serves them.
const providerAdditions = [];
for (const addition of providerAdditions) {
  const key = modelKey(addition.vendor, addition.id);
  const current = models.get(key);
  models.set(key, { ...current, ...addition, routes: { ...current?.routes, ...addition.routes } });
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
    Object.entries(sources).map(([id, { name, kind }]) => {
      const urls = endpoints[id] ?? {};
      const open = Object.values(urls).some((url) => url === "" || url.includes("{"));
      return [
        id,
        {
          name,
          kind,
          ...(kind === "api_key" ? { endpoints: open ? {} : urls, protocols: Object.keys(urls) } : {}),
          ...(open ? { endpoint_required: true } : {}),
        },
      ];
    })
  ),
  models: sorted,
};

for (const [id, source] of Object.entries(platformSources))
  catalog.sources[id] = { ...source, platform_only: true };

// A user endpoint: its models come from discovery, not from this catalog.
catalog.sources.custom = {
  name: "Custom",
  kind: "api_key",
  endpoints: {},
  protocols: ["chat_completions", "responses", "anthropic"],
  endpoint_required: true,
};

// The Profiles' sources: the catalog's, with how a station's runtimes are given
// a key (`auth`: Claude Code's x-api-key, a bearer token, or both), whether one
// works without a key, OpenCode's session header, and the station-only ones.
const profileSources = [
  ...Object.entries(catalog.sources)
    .filter(([, entry]) => !entry.platform_only)
    .map(([id, entry]) => [id, entry, sources[id] ?? { auth: "both", key_optional: true }]),
  ...Object.entries(stationSources).map(([id, entry]) => [id, entry, { ...entry, station_only: true }]),
].map(([id, entry, more]) => ({
  id,
  name: entry.name,
  kind: entry.kind,
  endpoints: entry.endpoints ?? {},
  protocols: entry.protocols ?? [],
  endpoint_required: entry.endpoint_required === true,
  key_optional: more.key_optional === true,
  auth: more.auth ?? "bearer",
  session_header: more.session_header === true,
  station_only: more.station_only === true,
  group: groupOf(id),
}));

const outputs = [
  [output, `${JSON.stringify(catalog, null, 1)}\n`],
  [profilesOutput, `${JSON.stringify(profileSources, null, 1)}\n`],
];
if (process.argv.includes("--check")) {
  for (const [path, text] of outputs) {
    if (readFileSync(path, "utf8") !== text) {
      console.error(`${path} is stale; run node scripts/generate-model-catalog.mjs`);
      process.exit(1);
    }
  }
} else {
  for (const [path, text] of outputs) writeFileSync(path, text);
  console.log(`${sorted.length} models from ${Object.keys(sources).length} sources -> ${output}, ${profilesOutput}`);
}
