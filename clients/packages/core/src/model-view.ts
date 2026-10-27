// What Settings › Model & API shows, worked out from the catalog and the profiles: the Add profile tiles for this
// catalog, each profile's plan meters and the models it can serve, and for each model the profiles an Agent's requests
// may run on. Pure: models.ts publishes it with each change.
import type {
  CatalogModel,
  ModelCatalog,
  ModelProfile,
  ModelProtocol,
  ProviderPreset,
  QuotaMeter,
  ShownModel,
  ShownProfile,
} from "./contract.ts";

const groups: ProviderPreset["group"][] = [
  "labs",
  "china",
  "gateways",
  "cloud",
  "inference",
  "local",
];

/**
 * Plans that sign in on the web with a device code. OpenCode Go signs in with an OpenCode account, and the server
 * keeps its token as the Profile's key (renewing it before it runs out).
 */
export const DEVICE_SIGN_IN = new Set([
  "codex",
  "grok",
  "kimi-code",
  "github-copilot",
  "opencode-go",
]);

const preset = (
  group: ProviderPreset["group"],
  id: string,
  brand: string,
  extra: Partial<ProviderPreset> = {}
): ProviderPreset => ({ id, group, brand, keySource: id, ...extra });

const knownPresets: readonly ProviderPreset[] = [
  preset("labs", "openai", "openai", { subscriptionSource: "codex" }),
  preset("labs", "anthropic", "anthropic", { subscriptionSource: "claude" }),
  preset("labs", "google", "google", { subscriptionSource: "gemini" }),
  preset("labs", "xai", "xai", { subscriptionSource: "grok" }),
  preset("labs", "mistral", "mistral"),
  preset("china", "deepseek", "deepseek"),
  preset("china", "qwen", "qwen"),
  preset("china", "moonshotai", "kimi", { subscriptionSource: "kimi-code" }),
  preset("china", "zai", "zai"),
  preset("china", "minimax", "minimax"),
  preset("china", "xiaomi", "xiaomi"),
  preset("china", "ant-ling", "ant-ling"),
  preset("china", "qwen-cn", "qwen"),
  preset("china", "moonshotai-cn", "kimi"),
  preset("china", "zai-coding-cn", "zai"),
  preset("china", "minimax-cn", "minimax"),
  preset("gateways", "openrouter", "openrouter"),
  {
    id: "github-copilot",
    group: "gateways",
    brand: "github-copilot",
    subscriptionSource: "github-copilot",
  },
  preset("gateways", "vercel-ai-gateway", "vercel"),
  preset("gateways", "opencode", "opencode"),
  preset("gateways", "opencode-go", "opencode", {
    subscriptionSource: "opencode-go",
    keyUsesPlan: true,
  }),
  preset("gateways", "cloudflare-ai-gateway", "cloudflare"),
  preset("cloud", "azure-openai", "azure", { baseUrl: true }),
  preset("inference", "groq", "groq"),
  preset("inference", "together", "together"),
  preset("inference", "fireworks", "fireworks"),
  preset("inference", "cerebras", "cerebras"),
  preset("inference", "huggingface", "huggingface"),
  preset("inference", "nvidia", "nvidia"),
  preset("inference", "baseten", "baseten"),
  preset("inference", "cloudflare-workers-ai", "cloudflare"),
  // The backend reaches these over the internet. A server on the person's own
  // computer is a station's: its agents are pointed at it there (Settings ›
  // Devices, the agent's Local model).
  preset("local", "ollama", "ollama", {
    keySource: "custom",
    name: "Ollama",
    baseUrl: true,
    keyOptional: true,
    discover: {
      protocol: "chat_completions",
      placeholder: "https://ollama.example.com/v1",
    },
  }),
  preset("local", "custom", "custom", {
    baseUrl: true,
    keyOptional: true,
    discover: { placeholder: "https://api.example.com/v1" },
  }),
];

/**
 * The tiles to offer for this catalog: known presets trimmed to the sources the catalog has, then any source the
 * catalog adds that this list does not know yet, so a new backend source is reachable without a client release.
 */
export function catalogPresets(catalog: ModelCatalog | null): ProviderPreset[] {
  const sources = catalog?.sources ?? {};
  const has = (source: string | undefined) => !!source && source in sources;
  const signIn = (source: string | undefined) =>
    source && DEVICE_SIGN_IN.has(source) ? { deviceSignIn: true } : {};
  const known = knownPresets.flatMap((entry): ProviderPreset[] => {
    const keySource = has(entry.keySource) ? entry.keySource : undefined;
    const subscriptionSource = has(entry.subscriptionSource)
      ? entry.subscriptionSource
      : undefined;
    if (!keySource && !subscriptionSource) return [];
    const { keySource: _key, subscriptionSource: _subscription, ...rest } = entry;
    return [
      {
        ...rest,
        ...(keySource && sources[keySource]?.endpoint_required
          ? { baseUrl: true }
          : {}),
        ...(keySource ? { keySource } : {}),
        ...(subscriptionSource ? { subscriptionSource } : {}),
        ...signIn(subscriptionSource),
      },
    ];
  });
  const covered = new Set(
    knownPresets.flatMap((entry) => [entry.keySource, entry.subscriptionSource])
  );
  const added = Object.entries(sources)
    .filter(([id]) => !covered.has(id))
    .map(
      ([id, source]): ProviderPreset => ({
        id,
        group: "gateways",
        brand: id,
        ...(source.kind === "subscription"
          ? { subscriptionSource: id, ...signIn(id) }
          : {
              keySource: id,
              ...(source.endpoint_required || source.base_url === null
                ? { baseUrl: true }
                : {}),
            }),
      })
    );
  const order = (entry: ProviderPreset) => groups.indexOf(entry.group);
  return [...known, ...added].toSorted((a, b) => order(a) - order(b));
}

/** The tile a profile was added from. */
const presetForSource = (presets: readonly ProviderPreset[], source: string) =>
  presets.find((entry) => entry.id === source) ??
  presets.find(
    (entry) => entry.keySource === source || entry.subscriptionSource === source
  );

const isSubscription = (account: ModelProfile) =>
  account.credential_kind === "subscription_oauth";

/** The two plan windows a profile row shows, from the provider's period name. */
function windowKind(period: string): QuotaMeter["window"] | undefined {
  const value = period.trim().toLowerCase();
  if (["5h", "five_hour", "short", "primary", "session"].includes(value)) return "5h";
  if (["week", "weekly", "7d", "seven_day", "secondary"].includes(value)) return "week";
  return undefined;
}

function quotaMeters(account: ModelProfile): QuotaMeter[] {
  const meters: QuotaMeter[] = [];
  for (const window of account.quota?.windows ?? []) {
    const kind = windowKind(window.period);
    // The row meters the whole account; a one-model window is not that.
    if (!kind || window.remaining_percent == null || window.model) continue;
    if (meters.some((meter) => meter.window === kind)) continue;
    meters.push({
      window: kind,
      percent: Math.max(0, Math.min(100, Math.round(window.remaining_percent))),
      ...(window.reset_at ? { resetAt: window.reset_at } : {}),
    });
  }
  return meters.toSorted(
    (a, b) => Number(a.window === "week") - Number(b.window === "week")
  );
}

/** Subscription plans whose requests use the Responses protocol. */
const responsesPlans = new Set(["codex", "grok"]);

const wireProtocols: Record<string, ModelProtocol> = {
  anthropic_messages: "anthropic",
  openai_completions: "chat_completions",
  openai_responses: "responses",
};

/**
 * The request id this profile sends for the model, if it can serve the model, whether or not it is turned off for the
 * profile. A Custom endpoint, such as TokenDance, serves the catalog models it listed when it was connected, under
 * their catalog ids.
 */
export function servableRoute(
  model: CatalogModel,
  account: ModelProfile,
  sources: ModelCatalog["sources"] | undefined
): { model: string; protocol: ModelProtocol } | undefined {
  if (account.source !== "custom") {
    const route = model.routes[account.source];
    if (!route) return undefined;
    // A plan's requests keep one wire protocol; one that does not speak
    // Responses cannot run a Responses-only model, as on GitHub Copilot.
    if (
      isSubscription(account) &&
      route.protocol === "responses" &&
      !responsesPlans.has(account.source)
    )
      return undefined;
    // A key on the reader's own endpoint speaks the one protocol chosen for it.
    const own = wireProtocols[account.connection?.protocol ?? ""];
    if (sources?.[account.source]?.endpoint_required && own && own !== route.protocol)
      return undefined;
    return route;
  }
  const protocol = wireProtocols[account.connection?.protocol ?? ""];
  return protocol && account.models?.includes(model.id)
    ? { model: model.id, protocol }
    : undefined;
}

/** Whether an Agent's requests can run on this profile: it is on and, for a subscription, signed in. */
const usable = (account: ModelProfile) =>
  !account.disabled &&
  (!isSubscription(account) || ["active", "connected"].includes(account.status));

const isTokenDance = (account: ModelProfile) =>
  account.source === "custom" &&
  !!account.connection?.endpoint?.startsWith("https://tokendance.space/");

/** The catalog's models, then those Custom endpoints list that the catalog does not know (one `custom` group). */
function choosable(
  catalog: ModelCatalog | null,
  profiles: readonly ModelProfile[]
): CatalogModel[] {
  const known = new Set((catalog?.models ?? []).map((model) => model.id));
  const listed = [
    ...new Set(
      profiles
        .filter((account) => account.source === "custom")
        .flatMap((account) => account.models ?? [])
        .filter((id) => !known.has(id))
    ),
  ];
  return [
    ...(catalog?.models ?? []),
    ...listed.map((id) => ({
      id,
      name: id,
      vendor: "custom",
      efforts: [],
      routes: {},
      custom: true as const,
    })),
  ];
}

export function modelsView(
  catalog: ModelCatalog | null,
  profiles: readonly ModelProfile[] | null
): {
  presets: ProviderPreset[];
  profiles: ShownProfile[] | null;
  models: ShownModel[];
} {
  const presets = catalogPresets(catalog);
  const all = profiles ?? [];
  const models = choosable(catalog, all);
  const sources = catalog?.sources;
  const shown = profiles?.map(
    (account): ShownProfile => ({
      ...account,
      subscription: isSubscription(account),
      usable: usable(account),
      preset: presetForSource(presets, account.source)?.id ?? null,
      tokenDance: isTokenDance(account),
      meters: quotaMeters(account),
      servable: models.flatMap((model) => {
        const route = servableRoute(model, account, sources);
        return route ? [{ model: model.id, request: route.model }] : [];
      }),
    })
  );
  const serving = all.filter(usable);
  return {
    presets,
    profiles: shown ?? null,
    models: models.map((model) => ({
      ...model,
      serving: serving
        .filter(
          (account) =>
            !account.disabled_models?.includes(model.id) &&
            !!servableRoute(model, account, sources)
        )
        .map((account) => account.id),
    })),
  };
}
