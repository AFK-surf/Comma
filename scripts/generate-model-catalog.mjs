#!/usr/bin/env node
// Generates the model catalog and Profile sources from the pinned models.dev snapshot.
//
// One catalog model gathers every source that serves it under its own request
// id: `gpt-5.5` is `gpt-5.5` at OpenAI and `openai/gpt-5.5` at OpenRouter.
// Refresh with `node scripts/refresh-model-catalog.mjs`, then run this generator.
// `--check` compares committed outputs without network access or npm dependencies.
//
// The Gemini plan runs on Antigravity, whose model ids are not AI Studio's.
// Its routes come from scripts/antigravity-models.json, extracted from the
// pinned CLIProxyAPI SDK registry. Refresh it when the SDK pin changes.
//
// scripts/model-additions.json keeps the models and routes the snapshot lacks.
// Regenerating fails when a model or route of the previous catalog is gone and
// `removed` there does not name it (`<model id>` or `<model id>@<source>`).
//
// scripts/model-limits.json caps the context window of the models it names, by
// vendor and family, so a product limit outlives the next snapshot refresh and
// reaches a new model of the same family without a per-model entry.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const snapshotPath = join(root, "scripts/models-dev.snapshot.json");
const sources = JSON.parse(readFileSync(join(root, "scripts/model-sources.json"), "utf8"));
const snapshot = JSON.parse(readFileSync(snapshotPath, "utf8"));
const additions = JSON.parse(readFileSync(join(root, "scripts/model-additions.json"), "utf8"));
const limits = JSON.parse(readFileSync(join(root, "scripts/model-limits.json"), "utf8"));
const output = join(root, "systems/apps/salix_agent/priv/model_catalog.json");
// The sources as the Profiles of Comma and its stations both use them (systems/profiles).
const profilesOutput = join(root, "systems/profiles/sources.json");

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
const tiers = /(-fast|-free|-flex|-priority|-spot)$/i;
// Gateway routing aliases and placeholders that name no model.
const aliases = new Set(["auto", "auto-beta", "free", "big-pickle"]);
const effortOrder = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"];

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
  const explicit = entry.reasoning_options?.find((option) => option.type === "effort")?.values;
  return explicit
    ? effortOrder.filter((level) => explicit.includes(level))
    : ["low", "medium", "high"];
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

function familyOf(name, familyLabels) {
  const words = name
    .replace(/\(.*?\)/g, " ")
    .split(/[\s-]+/)
    .filter((word) => word && !familyNoise.test(word))
    .map((word) => word.replace(/^([A-Za-z]+)\d+(\.\d+)*$/, "$1"));
  const family = words.join(" ") || name;
  // One label per family, whatever casing a gateway uses for it.
  return (familyLabels[family.toLowerCase()] ??= family);
}
export function buildCatalog(snapshot, extra = additions) {
  const familyLabels = { "gpt oss": "GPT OSS", r: "DeepSeek R" };
  const models = new Map();
  const canonicalFirst = Object.entries(sources).sort(
    ([, a], [, b]) => Number(Boolean(b.vendor) && b.kind === "api_key") - Number(Boolean(a.vendor) && a.kind === "api_key")
  );

  function protocolFor(config, entry, vendor) {
    if (config.route_protocols?.[entry.id]) return config.route_protocols[entry.id];
    if (config.protocol) return config.protocol;
    const allowed = config.protocols ?? [];
    if (allowed.length === 1) return allowed[0];
    const sdk = entry.provider?.npm;
    const preferred = sdk === "@ai-sdk/anthropic" || vendor === "anthropic"
      ? "anthropic"
      : sdk === "@ai-sdk/openai" || vendor === "openai" ? "responses" : "chat_completions";
    return allowed.includes(preferred) ? preferred : allowed.find((p) => p === "chat_completions") ?? allowed[0];
  }

  for (const [source, config] of canonicalFirst) {
    if (!config.models_dev) continue;
    const provider = snapshot.providers[config.models_dev];
    if (!provider) throw new Error(`Missing models.dev provider: ${config.models_dev}`);
    for (const entry of Object.values(provider.models)) {
      if (!entry.tool_call || (entry.type && entry.type !== "chat")) continue;
      if (entry.id.includes(":") || skipped.test(entry.id.toLowerCase())) continue;
      if (tiers.test(entry.id) || /\((fast|free)\)/i.test(entry.name ?? "")) continue;
      if (aliases.has(tail(entry.id).toLowerCase())) continue;
      if (config.models && !config.models.includes(entry.id)) continue;
      // A gateway that forwards to a maker's own API takes that API's model id.
      let routeId = entry.id;
      if (config.native_prefixes) {
        const [prefix, ...rest] = entry.id.split("/");
        const maker = config.native_prefixes[prefix];
        routeId = maker && models.get(modelKey(maker, rest.join("/")))?.routes[maker]?.model;
        if (!routeId) continue;
      }
      // `same_as`: ids a source uses for a model that the key rules cannot tie together.
      const canonical = entry.canonical_model_id ?? config.same_as?.[entry.id] ?? routeId;
      const key = modelKey(source, config.same_as?.[entry.id] ?? routeId);
      const vendor = vendorOf(source, canonical);
      const protocol = protocolFor(config, entry, vendor);
      if (!protocol) throw new Error(`No supported protocol for ${source}/${entry.id}`);
      let model = models.get(key);
      if (!model) {
        model = {
          id: config.catalog_ids?.[entry.id] ?? config.same_as?.[entry.id] ?? (config.vendor && config.kind === "api_key" ? entry.id.replace(/-(\d{8}|\d{4}-\d{2}-\d{2})$/, "") : tail(entry.id).toLowerCase()),
          name: display(entry.name ?? entry.id),
          family: familyOf(display(entry.name ?? entry.id), familyLabels),
          vendor,
          efforts: efforts(entry),
          images: (entry.modalities?.input ?? []).some((type) => type === "image" || type.startsWith("image/")),
          context_tokens: entry.limit?.context ?? null,
          max_tokens: entry.limit?.output ?? null,
          routes: {},
        };
        models.set(key, model);
      }
      if (config.overrides?.[entry.id]) Object.assign(model, config.overrides[entry.id]);
      // API list prices compare subscription models on the same reference basis.
      const cost = entry.cost ?? {};
      if (!model.price && (cost.input > 0 || cost.output > 0)) {
        // A rate the source does not list stays absent: unknown is not free.
        model.price = Object.fromEntries(
          ["input", "output", "cache_read", "cache_write"].flatMap((key) => (cost[key] == null ? [] : [[key, cost[key]]])),
        );
        // Keep context tiers beside the flat rates used by existing consumers.
        if (cost.tiers?.length) model.price_tiers = cost.tiers;
      }
      if (!model.routes[source] || routeId.length < model.routes[source].model.length)
        model.routes[source] = { model: routeId, protocol };
    }
  }

  // `relays`: a gateway also serves another source's models under a path prefix.
  for (const [source, config] of Object.entries(sources))
    for (const [relayed, prefix] of Object.entries(config.relays ?? {}))
      for (const model of models.values())
        if (model.routes[relayed])
          model.routes[source] = { model: prefix + model.routes[relayed].model, protocol: model.routes[relayed].protocol };

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
        family: familyOf(name, familyLabels),
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

  const generatedIds = new Set([...models.values()].map((model) => model.id));
  for (const addition of extra.models ?? []) {
    if (generatedIds.has(addition.id))
      throw new Error(`${addition.id} is generated now; remove it from scripts/model-additions.json`);
    models.set(`addition:${addition.id}`, structuredClone(addition));
  }
  const byId = new Map([...models.values()].map((model) => [model.id, model]));
  for (const [id, routes] of Object.entries(extra.routes ?? {})) {
    const model = byId.get(id);
    if (!model) throw new Error(`model-additions.json routes name an unknown model: ${id}`);
    for (const [source, route] of Object.entries(routes)) {
      const current = model.routes[source];
      if (current?.model === route.model && current?.protocol === route.protocol)
        throw new Error(`${id}@${source} is generated now; remove it from scripts/model-additions.json`);
      model.routes[source] = route;
    }
  }

  // A context cap applies to a model of the rule's vendor whose family is one
  // the rule names (or a variant of it, "GPT Sol Pro" for "GPT Sol") or whose
  // id the rule lists. A smaller window from the source stays.
  for (const rule of limits.context_tokens ?? [])
    for (const model of models.values())
      if (cappedBy(rule, model) && (model.context_tokens ?? 0) > rule.cap) model.context_tokens = rule.cap;

  const vendorOrder = ["openai", "anthropic", "google", "xai", "deepseek", "qwen", "kimi", "glm", "minimax", "mistral", "xiaomi", "ant-ling", "meta", "nvidia", "other"];
  const sorted = [...models.values()].sort(
    (a, b) =>
      vendorOrder.indexOf(a.vendor) - vendorOrder.indexOf(b.vendor) ||
      a.name.localeCompare(b.name, "en", { numeric: true })
  );

  const catalog = {
    generated_from: `models.dev snapshot ${snapshot.retrieved_at}`,
    sources: Object.fromEntries(
      Object.entries(sources).map(([id, { name, kind }]) => {
        const urls = sources[id].endpoints ?? {};
        const open = sources[id].endpoint_required === true;
        return [
          id,
          {
            name,
            kind,
            ...(kind === "api_key" ? { endpoints: open ? {} : urls, protocols: sources[id].protocols ?? Object.keys(urls) } : {}),
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

  return { catalog, profileSources };
}

export function cappedBy(rule, model) {
  if (rule.vendor && model.vendor !== rule.vendor) return false;
  if ((rule.models ?? []).includes(model.id)) return true;
  const family = (model.family ?? "").toLowerCase();
  return (rule.families ?? []).some((name) => family === name.toLowerCase() || family.startsWith(`${name.toLowerCase()} `));
}

// What `baseline` offers that `catalog` lost: a source, a model, or a model's route
// at a source, unless `removed` names it.
export function lostSince(baseline, catalog, removed = {}) {
  const current = new Map(catalog.models.map((model) => [model.id, model]));
  const lost = Object.keys(baseline.sources).filter((id) => !catalog.sources[id] && !(id in removed));
  for (const model of baseline.models) {
    if (model.id in removed) continue;
    const now = current.get(model.id);
    if (!now) {
      lost.push(model.id);
      continue;
    }
    for (const [source, route] of Object.entries(model.routes)) {
      const key = `${model.id}@${source}`;
      const next = now.routes[source];
      if (!(key in removed) && (next?.model !== route.model || next?.protocol !== route.protocol)) lost.push(key);
    }
  }
  return lost;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  const { catalog, profileSources } = buildCatalog(snapshot);
  const check = process.argv.includes("--check");
  const baselineArg = process.argv.indexOf("--baseline");
  // Regenerating compares with the catalog it replaces; `--check` with the one `--baseline` names.
  const baselinePath = baselineArg > 0 ? process.argv[baselineArg + 1] : check ? null : output;
  if (baselinePath) {
    const lost = lostSince(JSON.parse(readFileSync(baselinePath, "utf8")), catalog, additions.removed);
    if (lost.length) {
      console.error(`Lost since ${baselinePath}; restore them in scripts/model-additions.json or list them in its removed:\n${lost.join("\n")}`);
      process.exit(1);
    }
  }
  const outputs = [
    [output, `${JSON.stringify(catalog, null, 1)}\n`],
    [profilesOutput, `${JSON.stringify(profileSources, null, 1)}\n`],
  ];
  if (check) {
    for (const [path, text] of outputs) {
      if (readFileSync(path, "utf8") !== text) {
        console.error(`${path} is stale; run node scripts/generate-model-catalog.mjs`);
        process.exit(1);
      }
    }
  } else {
    for (const [path, text] of outputs) writeFileSync(path, text);
    console.log(`${catalog.models.length} models from ${Object.keys(sources).length} sources -> ${output}, ${profilesOutput}`);
  }
}
