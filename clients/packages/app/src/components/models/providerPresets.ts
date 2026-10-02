import type { SubscriptionAccount } from "../../api/subscriptionAccounts";
import type { CatalogModel, ModelCatalog, ModelProtocol } from "../../api/modelCatalog";

/** Provider groups in the Add profile grid, most used first. */
export const presetGroups = [
  "labs",
  "china",
  "gateways",
  "cloud",
  "inference",
  "local",
] as const;
export type PresetGroup = (typeof presetGroups)[number];

/**
 * One tile in the Add profile grid. A vendor whose consumer plan can stand in
 * for an API key carries both sources; GitHub Copilot is a plan alone.
 */
export type ProviderPreset = {
  id: string;
  group: PresetGroup;
  /** Brand key for `ModelVendorIcon`. */
  brand: string;
  /** Catalog source of its API key. */
  keySource?: string;
  /** Catalog source of its subscription. */
  subscriptionSource?: string;
  /** Used when the catalog does not name the source, as for local endpoints. */
  name?: string;
  baseUrl?: boolean;
  keyOptional?: boolean;
  /**
   * An endpoint outside the catalog: its models are listed when it connects.
   * `protocol` fixes the wire protocol; without it the reader chooses.
   */
  discover?: { protocol?: ModelProtocol; placeholder: string };
};

const preset = (
  group: PresetGroup,
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
  preset("gateways", "opencode-go", "opencode"),
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
  // The backend reaches these over the internet, so a local server needs an
  // address it can reach, such as a tunnel.
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
 * The tiles to offer for this catalog: known presets trimmed to the sources
 * the catalog has, then any source the catalog adds that this list does not
 * know yet, so a new backend source is reachable without a client release.
 */
export function catalogPresets(catalog: ModelCatalog | undefined): ProviderPreset[] {
  const sources = catalog?.sources ?? {};
  const has = (source: string | undefined) => !!source && source in sources;
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
          ? { subscriptionSource: id }
          : {
              keySource: id,
              ...(source.endpoint_required || source.base_url === null
                ? { baseUrl: true }
                : {}),
            }),
      })
    );
  const order = (entry: ProviderPreset) => presetGroups.indexOf(entry.group);
  return [...known, ...added].toSorted((a, b) => order(a) - order(b));
}

/** The tile a profile was added from. */
export const presetForSource = (presets: readonly ProviderPreset[], source: string) =>
  presets.find((entry) => entry.id === source) ??
  presets.find(
    (entry) => entry.keySource === source || entry.subscriptionSource === source
  );

export const isSubscription = (account: SubscriptionAccount) =>
  account.credential_kind === "subscription_oauth";

export type QuotaWindowKind = "5h" | "week";

/** The two plan windows the profile row shows, from the provider's period name. */
export function quotaWindowKind(period: string): QuotaWindowKind | undefined {
  const value = period.trim().toLowerCase();
  if (["5h", "five_hour", "short", "primary", "session"].includes(value)) return "5h";
  if (["week", "weekly", "7d", "seven_day", "secondary"].includes(value)) return "week";
  return undefined;
}

export type QuotaMeter = { window: QuotaWindowKind; percent: number; resetAt?: string };

export function quotaMeters(account: SubscriptionAccount): QuotaMeter[] {
  const meters: QuotaMeter[] = [];
  for (const window of account.quota?.windows ?? []) {
    const kind = quotaWindowKind(window.period);
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
 * The request id this profile sends for the model, if it serves the model.
 * A Custom endpoint, such as TokenDance, serves the catalog models it listed
 * when it was connected, under their catalog ids.
 */
export function profileRoute(
  model: CatalogModel,
  account: SubscriptionAccount,
  sources?: ModelCatalog["sources"]
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

/** Profiles that can serve a model. */
export const servingProfiles = (
  model: CatalogModel,
  profiles: readonly SubscriptionAccount[],
  sources?: ModelCatalog["sources"]
) => profiles.filter((account) => !!profileRoute(model, account, sources));

/**
 * Whether an Agent's requests can run on this profile: it is on and, for a
 * subscription, signed in.
 */
export const canServeAgents = (account: SubscriptionAccount) =>
  !account.disabled &&
  (!isSubscription(account) || ["active", "connected"].includes(account.status));

/** Catalog vendor names; ids outside this list read as their own id. */
export const vendorNames: Record<string, string> = {
  openai: "OpenAI",
  anthropic: "Anthropic",
  google: "Google",
  xai: "xAI",
  deepseek: "DeepSeek",
  qwen: "Qwen",
  kimi: "Kimi",
  glm: "GLM",
  minimax: "MiniMax",
  mistral: "Mistral",
  meta: "Meta",
  nvidia: "NVIDIA",
  xiaomi: "Xiaomi",
  "ant-ling": "Ant Ling",
};
