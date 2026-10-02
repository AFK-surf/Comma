import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  Dialog,
  EditBigIcon,
  InputField,
  ModelPicker,
  ModelVendorIcon,
  MoreHorizontalIcon,
  type ModelPickerAccount,
  type ModelPickerModel,
  type ModelPickerValue,
  Toggle,
  toast,
  type SettingsCategoryDefinition,
  type SettingsCategoryDetail,
  type SettingsPanelItem,
} from "@comma/ui";
import { CommaApiError, type CommaApiClient } from "../../api";
import type {
  AgentModels,
  AgentSelection,
  CatalogModel,
  ModelCatalog,
  ModelProtocol,
  SettingsAgent,
} from "../../api/modelCatalog";
import type {
  SubscriptionAccount,
  SubscriptionPage,
} from "../../api/subscriptionAccounts";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "../activeWorkspace";
import { CommaProductMark } from "../CommaProductMark";
import { ProviderMark, QuotaMeters } from "./ProviderMarks";
import {
  canServeAgents,
  catalogPresets,
  isSubscription,
  presetForSource,
  presetGroups,
  profileRoute,
  quotaMeters,
  servingProfiles,
  vendorNames,
  type ProviderPreset,
} from "./providerPresets";
import { useRouterRenamed } from "../router-identity/RouterIdentityProvider";
import { useSubscriptionSignIn } from "./useSubscriptionSignIn";
import { tokenDanceAvailable, useTokenDanceConnect } from "./useTokenDanceConnect";

type ConnectMethod = "api_key" | "subscription";

type View =
  | { kind: "pick" }
  | {
      kind: "connect";
      preset: string;
      /** Unset until the reader chooses, for a provider offering both. */
      method?: ConnectMethod;
      key: string;
      baseUrl: string;
      /** The wire protocol of an endpoint outside the catalog. */
      protocol?: ModelProtocol;
      busy: boolean;
      error?: string | undefined;
      /** The subscription this sign-in renews, instead of adding another. */
      reconnect?: { id: string; version: string };
    }
  | { kind: "tokendance" }
  | { kind: "profile"; id: string }
  | { kind: "model"; modelId: string; from: string }
  | {
      kind: "rename-profile";
      id: string;
      name: string;
      busy: boolean;
      error?: string | undefined;
    }
  | {
      kind: "replace-key";
      id: string;
      key: string;
      busy: boolean;
      error?: string | undefined;
    }
  | {
      kind: "rename-agent";
      agentId: string;
      name: string;
      busy: boolean;
      error?: string | undefined;
    };

const protocolLabels: Record<ModelProtocol, string> = {
  chat_completions: "OpenAI Chat Completions",
  responses: "OpenAI Responses",
  anthropic: "Anthropic Messages",
};

const tokenDanceName = "TokenDance";
/** Compute runtimes whose model the page chooses among their plan's models. */
const runtimePlans = new Set(["codex", "claude"]);
/** A Custom profile on TokenDance's gateway, as one-click connect saves it. */
const isTokenDance = (account: SubscriptionAccount) =>
  account.source === "custom" &&
  !!account.connection?.endpoint?.startsWith("https://tokendance.space/");

const tileClass =
  "flex min-w-0 cursor-pointer items-center gap-sm rounded-lg px-md py-sm text-left text-sm text-primary transition-colors duration-150 ease-out hover:bg-secondary focus-visible:bg-secondary focus-visible:outline-none";

/** Which form a view is, whatever its field values. */
const formKey = (view: View) =>
  `${view.kind}:${"preset" in view ? view.preset : "id" in view ? view.id : "agentId" in view ? view.agentId : ""}`;

const endpointHost = (url: string) => {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
};

/** One of two ways to connect a provider, as a large button. */
function Choice({
  label,
  hint,
  onPress,
}: {
  label: string;
  hint: string;
  onPress: () => void;
}) {
  const hintId = useId();
  return (
    <button
      type="button"
      aria-describedby={hintId}
      className="flex min-h-11 w-full cursor-pointer flex-col items-start gap-xxs rounded-lg border-[0.5px] border-primary bg-primary px-lg py-md text-left transition-colors duration-150 ease-out hover:bg-secondary focus-visible:bg-secondary focus-visible:outline-none"
      onClick={onPress}
    >
      <span className="text-sm font-medium text-primary">{label}</span>
      <span
        id={hintId}
        aria-hidden="true"
        className="text-pretty text-xs text-tertiary"
      >
        {hint}
      </span>
    </button>
  );
}

/**
 * Whether a pasted value is a whole callback: an address carrying `code=`, or
 * a `code#state` pair as Claude shows it.
 */
const pastedCallback = (value: string) => {
  const text = value.trim();
  return /[?&#]code=[^&#\s]+/.test(text) || /^[^\s#]{8,}#[^\s#]{8,}$/.test(text);
};

const familyKey = (model: CatalogModel) =>
  `${model.vendor}:${model.family ?? model.id}`;

// A sign-in without an email is identified by "id:<subject>"; show the
// provider instead of that raw id.
const shown = (value: string | null | undefined) =>
  value?.trim() && !value.startsWith("id:") ? value.trim() : undefined;

const titleCase = (value: string) => value.charAt(0).toUpperCase() + value.slice(1);

/** A labelled text field on a detail page. */
const nameField = (
  id: string,
  label: string,
  value: string,
  onChange: (value: string) => void,
  extra: {
    description?: string;
    type?: string;
    placeholder?: string;
    error?: string | undefined;
    disabled?: boolean;
  } = {}
): SettingsPanelItem => ({
  id,
  title: label,
  ...(extra.description ? { description: extra.description } : {}),
  ...(extra.error ? { errorMessage: extra.error } : {}),
  layout: "field",
  control: {
    type: "custom",
    content: (
      <InputField
        className="w-full"
        fieldSize="sm"
        aria-label={label}
        type={extra.type ?? "text"}
        autoComplete="off"
        placeholder={extra.placeholder}
        value={value}
        disabled={extra.disabled ?? false}
        onChange={(event) => onChange(event.target.value)}
      />
    ),
  },
});

/** A literal identifier shown as code. */
const codeControl = (value: string) => ({
  type: "custom" as const,
  content: (
    <code className="rounded-md bg-secondary px-sm py-xxs font-mono text-xs text-secondary">
      {value}
    </code>
  ),
});

/**
 * Settings → Model & API: the profiles (subscriptions and API keys) the
 * system may route through, and the model each Agent runs on.
 */
export function useModelsCategory(
  api: CommaApiClient,
  enabled: boolean
): { category: SettingsCategoryDefinition } {
  const m = useCommaMessages();
  // A renamed Router's name shows in this window's chats at once.
  const routerRenamed = useRouterRenamed();
  const [workspace, setWorkspace] = useState(readActiveWorkspaceId);
  const [catalog, setCatalog] = useState<ModelCatalog>();
  const [page, setPage] = useState<SubscriptionPage>();
  const [agents, setAgents] = useState<AgentModels>();
  const [workerCursor, setWorkerCursor] = useState<string>();
  const [checking, setChecking] = useState<ReadonlySet<string>>(new Set());
  const [error, setError] = useState<string>();
  const [agentErrors, setAgentErrors] = useState<Record<string, string>>({});
  const [view, setView] = useState<View>();
  const [removing, setRemoving] = useState<{ id: string; busy: boolean }>();
  const [resetting, setResetting] = useState<{
    id: string;
    busy: boolean;
    outcome?: string;
    /** The provider answered; nothing is left to retry. */
    settled?: boolean;
  }>();
  // A reset retried after an unconfirmed attempt reuses its request id, so the
  // provider redeems one credit at most.
  const resetKeys = useRef(new Map<string, string>());
  const generation = useRef(0);
  const heldWorkspace = useRef(workspace);

  const message = useCallback(
    (reason: unknown) => {
      const code = reason instanceof Error ? reason.message : "";
      if (code === "conflict") return m.settings_providers_conflict();
      if (code === "authorization_port_in_use")
        return m.settings_providers_port_in_use();
      if (code === "authorization_expired")
        return m.settings_providers_signin_expired();
      return m.settings_providers_error();
    },
    [m]
  );

  useEffect(() => subscribeActiveWorkspace(setWorkspace), []);

  const loadAgents = useCallback(
    async (id: string, cursor: string | undefined, signal?: AbortSignal) => {
      const next = await api.getAgentModels(id, signal ? { signal } : {});
      if (cursor) next.workers = await api.getWorkerModels(id, cursor);
      return next;
    },
    [api]
  );

  useEffect(() => {
    const current = ++generation.current;
    // Kept across a tab switch: the data is the workspace's, and dropping it
    // would collapse the page and grow it back when the reader returns.
    if (heldWorkspace.current !== workspace) {
      heldWorkspace.current = workspace;
      setPage(undefined);
      setAgents(undefined);
      setWorkerCursor(undefined);
      setView(undefined);
    }
    if (!enabled) return;
    const controller = new AbortController();
    const { signal } = controller;
    void (async () => {
      const id = workspace ?? (await api.listWorkspaces({ signal }))[0]?.id;
      if (!id) throw new Error("workspace_unavailable");
      if (signal.aborted) return;
      if (id !== workspace) {
        setWorkspace(id);
        return;
      }
      const [nextCatalog, nextPage, nextAgents] = await Promise.all([
        api.getModelCatalog({ signal }),
        api.listSubscriptionAccounts(id, "", { signal }),
        loadAgents(id, workerCursor, signal),
      ]);
      if (signal.aborted || current !== generation.current) return;
      setCatalog(nextCatalog);
      setPage(nextPage);
      setAgents(nextAgents);
      setError(undefined);
    })().catch((reason: unknown) => {
      if (!signal.aborted && current === generation.current) setError(message(reason));
    });
    return () => controller.abort();
  }, [api, enabled, workspace, workerCursor, loadAgents, message]);

  const profiles = useMemo(() => page?.accounts ?? [], [page]);
  const presets = useMemo(() => catalogPresets(catalog), [catalog]);
  // Catalog models, then the models a Custom endpoint lists that the catalog
  // does not know, such as a local Ollama model; those run as listed.
  const models = useMemo(() => {
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
      ...listed.map(
        // One group for them all, rather than one per model.
        (id): CatalogModel => ({
          id,
          name: id,
          family: m.settings_providers_custom(),
          vendor: "custom",
          efforts: [],
          routes: {},
        })
      ),
    ];
  }, [catalog, profiles, m]);
  const modelById = useMemo(
    () => new Map(models.map((model) => [model.id, model])),
    [models]
  );

  const replaceProfile = (account: SubscriptionAccount) =>
    setPage((previous) =>
      previous
        ? {
            ...previous,
            accounts: previous.accounts.map((entry) =>
              entry.id === account.id ? account : entry
            ),
          }
        : previous
    );

  const reloadProfiles = async () => {
    if (!workspace) return [];
    const next = await api.listSubscriptionAccounts(workspace, "");
    setPage(next);
    return next.accounts;
  };

  /** Runs a write; a failure shows on the page and a stale version reloads. */
  const write = async (operation: () => Promise<void>) => {
    const current = generation.current;
    try {
      await operation();
      if (current === generation.current) setError(undefined);
    } catch (reason) {
      if (current !== generation.current) return;
      setError(message(reason));
      if (reason instanceof Error && reason.message === "conflict")
        await reloadProfiles().catch(() => undefined);
    }
  };

  // A subscription is named for its account; the reader may rename it later.
  const signIn = useSubscriptionSignIn(api, workspace, async () => {
    const connect = view?.kind === "connect" ? view : undefined;
    const first = profiles.length === 0;
    await reloadProfiles().catch(() => profiles);
    if (first && !connect?.reconnect) confirmFirstProfile();
    setView(undefined);
  });

  /** Says once that nothing else is needed: Agents pick profiles themselves. */
  const confirmFirstProfile = () => toast.success(m.settings_providers_first_added());

  const tokenDance = useTokenDanceConnect(workspace, tokenDanceName, async () => {
    const first = profiles.length === 0;
    await reloadProfiles().catch(() => undefined);
    if (first) confirmFirstProfile();
    setView(undefined);
  });

  const presetById = (id: string | undefined) =>
    presets.find((entry) => entry.id === id);
  const presetName = (entry: ProviderPreset | undefined, fallback = "") => {
    if (!entry) return fallback;
    if (entry.id === "custom") return m.settings_providers_custom();
    if (entry.name) return entry.name;
    const source = entry.keySource ?? entry.subscriptionSource ?? "";
    return catalog?.sources[source]?.name ?? entry.name ?? source;
  };
  const sourceName = (source: string) => catalog?.sources[source]?.name ?? source;
  const profilePreset = (account: SubscriptionAccount) =>
    presetForSource(presets, account.source);
  const providerName = (account: SubscriptionAccount) => {
    if (isTokenDance(account)) return tokenDanceName;
    const entry = profilePreset(account);
    return entry ? presetName(entry) : sourceName(account.source);
  };
  const profileName = (account: SubscriptionAccount) =>
    shown(account.name) || shown(account.email) || providerName(account);
  const profileSummary = (account: SubscriptionAccount) => {
    if (isSubscription(account)) {
      const plan = account.quota?.plan_type?.trim();
      return m.settings_providers_row_sub({
        provider: providerName(account),
        plan: [sourceName(account.source), plan ? titleCase(plan) : ""]
          .filter(Boolean)
          .join(" "),
      });
    }
    return m.settings_providers_row_key({
      provider: providerName(account),
      hint: account.key_hint?.trim() || "—",
    });
  };
  const profileStatus = (account: SubscriptionAccount) => {
    if (account.disabled)
      return { label: m.settings_providers_off(), color: "gray" as const };
    if (checking.has(account.id) || account.status === "checking")
      return {
        label: m.settings_providers_checking(),
        color: "gray" as const,
        loading: true,
      };
    if (account.status === "active" || account.status === "connected")
      return { label: m.settings_providers_connected(), color: "success" as const };
    return { label: m.settings_providers_failed(), color: "error" as const };
  };
  /**
   * Settles a form's save: `next` replaces the form only while the reader is
   * still on it, so a late answer does not reopen a form they left.
   */
  const settleForm = (form: View, next: View | undefined) =>
    setView((open) => (open && formKey(open) === formKey(form) ? next : open));

  const close = () => {
    signIn.reset();
    tokenDance.reset();
    setView(undefined);
  };

  const toggleProfile = (account: SubscriptionAccount) => {
    if (!workspace) return;
    void write(async () => {
      replaceProfile(
        await api.updateSubscriptionAccount(workspace, account.id, {
          version: account.version,
          disabled: !account.disabled,
        })
      );
    });
  };

  const refreshProfile = (account: SubscriptionAccount) => {
    if (!workspace || checking.has(account.id)) return;
    setChecking((previous) => new Set(previous).add(account.id));
    void write(async () => {
      if (isSubscription(account))
        replaceProfile(await api.refreshSubscriptionQuota(workspace, account.id));
      else await reloadProfiles();
    }).finally(() =>
      setChecking((previous) => {
        const next = new Set(previous);
        next.delete(account.id);
        return next;
      })
    );
  };

  const removeProfile = (account: SubscriptionAccount) => {
    if (!workspace) return;
    setRemoving({ id: account.id, busy: true });
    void write(async () => {
      await api.deleteSubscriptionAccount(workspace, account.id, account.version);
      setPage((previous) =>
        previous
          ? {
              ...previous,
              accounts: previous.accounts.filter((entry) => entry.id !== account.id),
            }
          : previous
      );
      if (view && "id" in view && view.id === account.id) setView(undefined);
    }).finally(() => setRemoving(undefined));
  };

  const reauthorize = (account: SubscriptionAccount) => {
    const entry = profilePreset(account);
    if (!entry?.subscriptionSource) return;
    signIn.reset();
    setView({
      kind: "connect",
      preset: entry.id,
      method: "subscription",
      key: "",
      baseUrl: "",
      busy: false,
      reconnect: { id: account.id, version: account.version },
    });
    // Renewing has nothing to fill in either: sign in at once.
    signIn.begin(entry.subscriptionSource, {
      account_id: account.id,
      version: account.version,
    });
  };

  const resetQuota = (account: SubscriptionAccount) => {
    if (!workspace || resetting?.busy) return;
    const current = generation.current;
    const slot = `${workspace}:${account.id}:${account.version}`;
    const requestId =
      account.reset_attempt?.outcome === "pending"
        ? account.reset_attempt.request_id
        : (resetKeys.current.get(slot) ?? crypto.randomUUID());
    resetKeys.current.set(slot, requestId);
    setResetting({ id: account.id, busy: true });
    void api
      .resetSubscriptionQuota(workspace, account.id, {
        version: account.version,
        request_id: requestId,
      })
      .then((result) => {
        if (current !== generation.current) return;
        resetKeys.current.delete(slot);
        replaceProfile(result.account);
        const outcomes = {
          reset: m.settings_providers_reset_done(),
          already_redeemed: m.settings_providers_reset_redeemed(),
          nothing_to_reset: m.settings_providers_reset_unneeded(),
          no_credit: m.settings_providers_reset_no_credit(),
        };
        setResetting({
          id: account.id,
          busy: false,
          settled: true,
          outcome:
            outcomes[result.outcome] +
            (result.quota_refreshed ? "" : ` ${m.settings_providers_reset_stale()}`),
        });
      })
      .catch((reason: unknown) => {
        if (current !== generation.current) return;
        const status = reason instanceof CommaApiError ? reason.status : 0;
        // The profile changed or another reset holds it: show the current
        // state, then the reader may try again with it.
        if (status === 409) {
          void reloadProfiles().catch(() => undefined);
          setResetting({
            id: account.id,
            busy: false,
            outcome:
              reason instanceof Error && reason.message === "reset_in_progress"
                ? m.settings_providers_reset_in_progress()
                : m.settings_providers_conflict(),
          });
          return;
        }
        // Refused outright, for example a sign-in that has expired: nothing ran.
        if (status >= 400 && status < 500) {
          setResetting({
            id: account.id,
            busy: false,
            settled: true,
            outcome: m.settings_providers_reset_refused(),
          });
          return;
        }
        // No answer: the reset may have run, so a retry reuses the request.
        setResetting({
          id: account.id,
          busy: false,
          outcome: m.settings_providers_reset_pending(),
        });
      });
  };

  /** The model ids an endpoint lists, as many as a profile keeps. */
  const discoverModelIds = async (
    baseUrl: string,
    protocol: ModelProtocol,
    key: string
  ) => {
    if (!workspace) throw new Error("workspace_unavailable");
    const found = await api.discoverModels(workspace, {
      base_url: baseUrl,
      protocol,
      ...(key ? { api_key: key } : {}),
    });
    const encoder = new TextEncoder();
    const ids = [
      ...new Set(
        found.data
          .map((model) => model.id)
          .filter((id) => id && encoder.encode(id).length <= 200)
      ),
    ].slice(0, 500);
    if (!ids.length) throw new Error("no_models");
    return ids;
  };

  const loadMoreProfiles = () => {
    if (!workspace || !page?.next) return;
    const after = page.next;
    void write(async () => {
      const next = await api.listSubscriptionAccounts(workspace, after);
      setPage((previous) => ({
        accounts: [
          ...(previous?.accounts ?? []),
          ...next.accounts.filter(
            (entry) => !previous?.accounts.some((known) => known.id === entry.id)
          ),
        ],
        next: next.next,
      }));
    });
  };

  const profileRow = (account: SubscriptionAccount): SettingsPanelItem => {
    const name = profileName(account);
    const entry = profilePreset(account);
    const meters =
      isSubscription(account) && !account.disabled ? quotaMeters(account) : [];
    const signedIn = ["active", "connected"].includes(account.status);
    const expired =
      isSubscription(account) &&
      !account.disabled &&
      !signedIn &&
      account.status !== "checking" &&
      !checking.has(account.id);
    // A Codex plan running low, with a reset left to spend.
    const resettable =
      account.source === "codex" &&
      signedIn &&
      !account.disabled &&
      (account.quota?.reset_credits?.available_count ?? 0) > 0 &&
      meters.some((meter) => meter.percent <= 10);
    return {
      id: `models.profile.${account.id}`,
      title: name,
      icon: (
        <ProviderMark
          brand={
            isTokenDance(account) ? "tokendance" : (entry?.brand ?? account.source)
          }
          name={providerName(account)}
        />
      ),
      description: profileSummary(account),
      // A row offering its fix needs no status beside it.
      ...(expired || resettable ? {} : { status: profileStatus(account) }),
      controlLeading: (
        <span className="flex items-center gap-md">
          {/* An expired plan shows no quota: renewing it is what matters. */}
          {meters.length && !expired ? <QuotaMeters meters={meters} /> : null}
          {/* The fix sits where the problem shows, not only in the menu. */}
          {expired ? (
            <Button
              hierarchy="secondary-gray"
              size="xs"
              aria-label={m.settings_providers_reauth_named({ name })}
              onPress={() => reauthorize(account)}
            >
              {m.settings_providers_reauth()}
            </Button>
          ) : resettable ? (
            <Button
              hierarchy="secondary-gray"
              size="xs"
              aria-label={m.settings_providers_reset_named({ name })}
              onPress={() => setResetting({ id: account.id, busy: false })}
            >
              {m.settings_providers_reset_short()}
            </Button>
          ) : null}
          <Toggle
            size="sm"
            aria-label={m.settings_providers_enable({ name })}
            checked={!account.disabled}
            onChange={() => toggleProfile(account)}
          />
        </span>
      ),
      control: {
        type: "menu",
        label: m.settings_providers_actions({ name }),
        icon: <MoreHorizontalIcon className="size-4" />,
        items: [
          {
            id: "models",
            label: m.settings_providers_view_models(),
            onPress: () => setView({ kind: "profile", id: account.id }),
          },
          {
            id: "refresh",
            label: m.settings_providers_refresh(),
            onPress: () => refreshProfile(account),
          },
          {
            id: "rename",
            label: m.settings_providers_rename(),
            onPress: () =>
              setView({ kind: "rename-profile", id: account.id, name, busy: false }),
          },
          ...(isSubscription(account)
            ? [
                {
                  id: "reauth",
                  label: m.settings_providers_reauth(),
                  onPress: () => reauthorize(account),
                },
                ...(account.source === "codex"
                  ? [
                      {
                        id: "reset",
                        label:
                          account.quota?.reset_credits?.available_count == null
                            ? m.settings_providers_reset_menu_unknown()
                            : m.settings_providers_reset_menu({
                                count: account.quota.reset_credits.available_count,
                              }),
                        // A pending reset stays open so it can be confirmed.
                        disabled:
                          account.disabled ||
                          !["active", "connected"].includes(account.status) ||
                          (account.reset_attempt?.outcome !== "pending" &&
                            !account.quota?.reset_credits?.available_count),
                        onPress: () => setResetting({ id: account.id, busy: false }),
                      },
                    ]
                  : []),
              ]
            : [
                {
                  id: "replace",
                  label: m.settings_providers_replace_key(),
                  onPress: () =>
                    setView({
                      kind: "replace-key",
                      id: account.id,
                      key: "",
                      busy: false,
                    }),
                },
              ]),
          {
            id: "remove",
            label: m.settings_providers_remove(),
            tone: "destructive" as const,
            onPress: () => setRemoving({ id: account.id, busy: false }),
          },
        ],
      },
    };
  };

  // ---- Agents ----

  const writeAgent = (agent: SettingsAgent, operation: () => Promise<void>) => {
    const current = generation.current;
    setAgentErrors(({ [agent.agent_id]: _cleared, ...rest }) => rest);
    return operation().catch((reason: unknown) => {
      if (current !== generation.current) return;
      setAgentErrors((previous) => ({
        ...previous,
        [agent.agent_id]: message(reason),
      }));
      throw reason;
    });
  };

  const patchAgent = (agentId: string, patch: Partial<SettingsAgent>) =>
    setAgents((previous) =>
      previous
        ? {
            ...previous,
            agents: {
              ...previous.agents,
              router:
                previous.agents.router.agent_id === agentId
                  ? { ...previous.agents.router, ...patch }
                  : previous.agents.router,
            },
            workers: {
              ...previous.workers,
              items: previous.workers.items.map((agent) =>
                agent.agent_id === agentId ? { ...agent, ...patch } : agent
              ),
            },
          }
        : previous
    );

  // Saves for one Agent run in order, so the server ends on the reader's last
  // choice; a failed save reloads the Agents, so the page shows what holds.
  const agentSaves = useRef(new Map<string, Promise<void>>());
  const selectAgentModel = (agent: SettingsAgent, selection: AgentSelection) => {
    if (!workspace) return;
    patchAgent(agent.agent_id, { selection });
    const previous = agentSaves.current.get(agent.agent_id) ?? Promise.resolve();
    const save = previous.then(() =>
      writeAgent(agent, () =>
        api
          .setAgentModel(workspace, agent.agent_id, selection)
          // Saves run in order, so a success is what the server now holds,
          // even after an earlier failure reloaded the page.
          .then(() => patchAgent(agent.agent_id, { selection }))
      ).catch(async () => {
        const current = generation.current;
        const next = await loadAgents(workspace, workerCursor).catch(() => undefined);
        if (next && current === generation.current) setAgents(next);
      })
    );
    agentSaves.current.set(agent.agent_id, save);
  };

  /**
   * Catalog models some enabled profile serves, as the picker lists them:
   * families in catalog order, the newest model of each first.
   */
  const pickerModels = (chosen: string | undefined): ModelPickerModel[] => {
    const usable = profiles.filter(canServeAgents);
    const served = models.filter(
      (model) =>
        model.id === chosen ||
        servingProfiles(model, usable, catalog?.sources).length > 0
    );
    const families = [...new Set(served.map((model) => familyKey(model)))];
    return families.flatMap((key) =>
      served
        .filter((model) => familyKey(model) === key)
        .toReversed()
        .map((model) => ({
          id: model.id,
          name: model.name,
          ...(model.family ? { family: model.family } : {}),
          icon: <ModelVendorIcon vendor={model.vendor} />,
          efforts: model.efforts,
        }))
    );
  };

  /**
   * Profiles that can serve a model, with what is left of their quota. A
   * profile the agent keeps to stays listed when it is off or gone, so the
   * picker says so instead of reading as automatic.
   */
  const pickerAccounts = (
    modelId: string,
    pinned?: string | null
  ): ModelPickerAccount[] => {
    const model = modelById.get(modelId);
    if (!model) return [];
    const serving = servingProfiles(
      model,
      profiles.filter(canServeAgents),
      catalog?.sources
    );
    const lost =
      pinned && !serving.some((account) => account.id === pinned)
        ? [
            {
              id: pinned,
              name: (() => {
                const account = profiles.find((entry) => entry.id === pinned);
                return account
                  ? profileName(account)
                  : m.settings_providers_pinned_removed();
              })(),
              note: m.settings_providers_pinned_unavailable_short(),
              tone: "warning" as const,
            },
          ]
        : [];
    return [
      ...lost,
      ...serving.map((account) => {
        const meters = isSubscription(account) ? quotaMeters(account) : [];
        const low = meters.some((meter) => meter.percent <= 10);
        return {
          id: account.id,
          name: profileName(account),
          icon: (
            <ProviderMark
              brand={presetForSource(presets, account.source)?.brand ?? account.source}
              name={providerName(account)}
            />
          ),
          note: meters.length
            ? meters
                .map(
                  (meter) =>
                    `${meter.window === "5h" ? m.settings_providers_quota_5h() : m.settings_providers_quota_week()} ${meter.percent}%`
                )
                .join(" · ")
            : profileSummary(account),
          tone: low ? ("warning" as const) : ("default" as const),
        };
      }),
    ];
  };

  /** Why this agent's choice cannot run, if it cannot. */
  const runWarning = (
    model: CatalogModel | undefined,
    paid: boolean,
    pinned: string | null | undefined
  ) => {
    const serving = model
      ? servingProfiles(model, profiles.filter(canServeAgents), catalog?.sources)
      : [];
    if (pinned)
      return serving.some((account) => account.id === pinned)
        ? undefined
        : m.settings_providers_pinned_unavailable();
    if (paid) return serving.length ? undefined : m.settings_providers_no_profile();
    return serving.some(isSubscription)
      ? undefined
      : m.settings_providers_allow_paid_none();
  };

  const pickerLabels = {
    models: m.settings_providers_picker_models(),
    search: m.settings_providers_picker_search(),
    noMatch: m.settings_providers_picker_no_match(),
    effort: m.settings_providers_picker_effort(),
    defaultEffort: m.settings_providers_picker_default_effort(),
    account: m.settings_providers_picker_account(),
    auto: m.settings_providers_picker_auto(),
    autoNote: m.settings_providers_picker_auto_note(),
    allowPaid: m.settings_providers_allow_paid(),
    allowPaidHint: m.settings_providers_allow_paid_on(),
  };

  /** Models a compute runtime runs on its own sign-in: its plan's models. */
  const runtimeModels = (provider: string, chosen: string | undefined) =>
    (catalog?.models ?? [])
      .filter((model) => model.id === chosen || provider in model.routes)
      .map((model) => ({
        id: model.id,
        name: model.name,
        ...(model.family ? { family: model.family } : {}),
        icon: <ModelVendorIcon vendor={model.vendor} />,
        efforts: model.efforts,
      }));

  const agentRow = (agent: SettingsAgent): SettingsPanelItem => {
    // A runtime whose binding names its model sets it; the page shows it.
    if (agent.runtime && !agent.selection) {
      const effort = agent.reasoning_effort ? ` · ${agent.reasoning_effort}` : "";
      return {
        id: `models.agent.${agent.agent_id}`,
        title: agent.name,
        description: m.settings_providers_runtime_role({
          runtime:
            vendorNames[agent.runtime.provider] ?? titleCase(agent.runtime.provider),
        }),
        control: {
          type: "custom",
          content: (
            <span
              className="text-sm text-secondary"
              title={m.settings_providers_runtime_model_hint()}
            >
              {agent.model
                ? `${modelById.get(agent.model)?.name ?? agent.model}${effort}`
                : m.settings_providers_runtime_default()}
            </span>
          ),
        },
      };
    }
    const selection: AgentSelection = agent.selection ?? { kind: "builtin" };
    const runtime = agent.runtime;
    // Codex and Claude Code run their plan's models on their own sign-in.
    // Other runtimes take the catalog choice below.
    if (runtime && runtimePlans.has(runtime.provider)) {
      // A compute Worker runs on the runtime's own sign-in: no profile serves
      // it, so the choice is a model and an effort.
      const current = selection.kind === "runtime" ? selection : undefined;
      const errorMessage = agentErrors[agent.agent_id];
      return {
        id: `models.agent.${agent.agent_id}`,
        title: agent.name,
        description: m.settings_providers_runtime_role({
          runtime: vendorNames[runtime.provider] ?? titleCase(runtime.provider),
        }),
        ...(errorMessage ? { errorMessage } : {}),
        control: {
          type: "custom",
          content: (
            <ModelPicker
              label={agent.name}
              value={{
                model:
                  current?.model ?? (selection.kind === "builtin" ? null : "earlier"),
                effort: current?.reasoning_effort ?? null,
                profile: null,
                allowPaid: false,
              }}
              builtin={{
                label: m.settings_providers_runtime_default(),
                icon: (
                  <ProviderMark
                    brand={runtime.provider}
                    name={vendorNames[runtime.provider] ?? titleCase(runtime.provider)}
                  />
                ),
              }}
              {...(selection.kind === "catalog" || selection.kind === "template"
                ? {
                    currentLabel: m.settings_providers_legacy_choice({
                      name:
                        agent.model_display_name ||
                        agent.template_name ||
                        agent.model ||
                        "",
                    }),
                  }
                : {})}
              models={runtimeModels(runtime.provider, current?.model)}
              accountsFor={() => []}
              labels={pickerLabels}
              chooseAccount={false}
              disabled={!workspace || !catalog}
              onChange={(next) =>
                selectAgentModel(
                  agent,
                  next.model === null
                    ? { kind: "builtin" }
                    : {
                        kind: "runtime",
                        model: next.model,
                        reasoning_effort: next.effort,
                      }
                )
              }
            />
          ),
        },
      };
    }
    const model =
      selection.kind === "catalog" ? modelById.get(selection.model) : undefined;
    const value: ModelPickerValue =
      selection.kind === "catalog"
        ? {
            model: selection.model,
            effort: selection.reasoning_effort,
            profile: selection.profile_id ?? null,
            allowPaid: selection.allow_paid,
          }
        : // A private template from before the catalog stays until replaced.
          {
            model:
              selection.kind === "template"
                ? `template:${selection.template_id}`
                : null,
            effort: null,
            profile: null,
            allowPaid: false,
          };
    const warning =
      selection.kind === "catalog"
        ? runWarning(model, selection.allow_paid, selection.profile_id)
        : undefined;
    const errorMessage = agentErrors[agent.agent_id];
    return {
      id: `models.agent.${agent.agent_id}`,
      title: agent.name,
      description:
        agent.role === "router"
          ? m.settings_providers_router_role()
          : m.settings_providers_worker_role(),
      ...(errorMessage ? { errorMessage } : {}),
      controlLeading: (
        <Button
          hierarchy="tertiary-gray"
          size="sm"
          aria-label={m.settings_providers_rename_agent({ name: agent.name })}
          onPress={() =>
            setView({
              kind: "rename-agent",
              agentId: agent.agent_id,
              name: agent.name,
              busy: false,
            })
          }
        >
          <EditBigIcon className="size-4" />
        </Button>
      ),
      control: {
        type: "custom",
        content: (
          <ModelPicker
            label={agent.name}
            value={value}
            builtin={{
              label: m.settings_providers_builtin(),
              icon: <CommaProductMark className="size-4 shrink-0" />,
            }}
            {...(selection.kind === "template"
              ? {
                  currentLabel: m.settings_providers_legacy_choice({
                    name:
                      agent.model_display_name ||
                      agent.template_name ||
                      agent.model ||
                      "",
                  }),
                }
              : {})}
            models={pickerModels(
              selection.kind === "catalog" ? selection.model : undefined
            )}
            accountsFor={(id) =>
              pickerAccounts(
                id,
                selection.kind === "catalog" && id === selection.model
                  ? selection.profile_id
                  : null
              )
            }
            labels={pickerLabels}
            disabled={!workspace || !catalog}
            onChange={(next) =>
              selectAgentModel(
                agent,
                next.model === null || next.model.startsWith("template:")
                  ? { kind: "builtin" }
                  : {
                      kind: "catalog",
                      model: next.model,
                      reasoning_effort: next.effort,
                      allow_paid: next.allowPaid,
                      profile_id: next.profile,
                    }
              )
            }
          />
        ),
      },
      content: warning ? (
        <p role="alert" className="text-pretty text-xs text-warning-primary">
          {warning}
        </p>
      ) : null,
    };
  };

  const agentItems: SettingsPanelItem[] = agents
    ? [
        agentRow(agents.agents.router),
        ...agents.workers.items.map(agentRow),
        ...(agents.workers.next_cursor
          ? [
              {
                id: "models.workers.next",
                title: m.settings_providers_next_workers(),
                control: {
                  type: "button" as const,
                  label: m.settings_providers_next_workers(),
                  onPress: () =>
                    setWorkerCursor(agents.workers.next_cursor ?? undefined),
                },
              },
            ]
          : []),
        ...(workerCursor
          ? [
              {
                id: "models.workers.first",
                title: m.settings_providers_first_workers(),
                control: {
                  type: "button" as const,
                  label: m.settings_providers_first_workers(),
                  onPress: () => setWorkerCursor(undefined),
                },
              },
            ]
          : []),
      ]
    : [
        {
          id: "models.agents.loading",
          title: m.settings_providers_agents(),
          descriptionLoading: !error,
        },
      ];

  const removingProfile =
    removing && profiles.find((entry) => entry.id === removing.id);
  const resettingProfile =
    resetting && profiles.find((entry) => entry.id === resetting.id);
  const resetSettled = !!resetting?.settled;

  const category: SettingsCategoryDefinition = {
    id: "models",
    icon: "models-api-keys",
    label: m.settings_models_title(),
    keywords: ["BYOK", "API Key", "Codex", "Claude", "OAuth", "Provider", "Profile"],
    sections: [
      {
        id: "models.profiles",
        title: m.settings_providers_profiles(),
        items: [
          {
            id: "models.profiles.add",
            title: m.settings_providers_add_profile(),
            description: profiles.length
              ? m.settings_providers_add_profile_hint()
              : m.settings_providers_empty_hint(),
            descriptionLoading: !page && !error,
            ...(error ? { errorMessage: error } : {}),
            control: {
              type: "button",
              label: m.settings_providers_add_profile(),
              disabled: !workspace || !catalog,
              onPress: () => setView({ kind: "pick" }),
            },
          },
          ...profiles.map(profileRow),
          ...(page?.next
            ? [
                {
                  id: "models.profiles.more",
                  title: m.settings_providers_more_profiles(),
                  control: {
                    type: "button" as const,
                    label: m.settings_providers_more_profiles(),
                    onPress: loadMoreProfiles,
                  },
                },
              ]
            : []),
        ],
      },
      { id: "models.agents", title: m.settings_providers_agents(), items: agentItems },
    ],
    ...(removingProfile
      ? {
          overlay: (
            <Dialog
              isOpen
              isDismissable={!removing.busy}
              onOpenChange={(open) => {
                if (!open && !removing.busy) setRemoving(undefined);
              }}
              title={m.settings_providers_remove_title({
                name: profileName(removingProfile),
              })}
              description={m.settings_providers_remove_hint()}
              actions={[
                {
                  label: m.settings_providers_cancel(),
                  hierarchy: "secondary-gray",
                  disabled: removing.busy,
                  onPress: () => setRemoving(undefined),
                },
                {
                  label: m.settings_providers_remove(),
                  hierarchy: "destructive",
                  disabled: removing.busy,
                  onPress: () => removeProfile(removingProfile),
                },
              ]}
            />
          ),
        }
      : resettingProfile
        ? {
            overlay: (
              <Dialog
                isOpen
                isDismissable={!resetting.busy}
                onOpenChange={(open) => {
                  if (!open && !resetting.busy) setResetting(undefined);
                }}
                title={m.settings_providers_reset_title({
                  name: profileName(resettingProfile),
                })}
                description={m.settings_providers_reset_hint()}
                actions={[
                  {
                    label: resetSettled
                      ? m.settings_providers_close()
                      : m.settings_providers_cancel(),
                    hierarchy: resetSettled ? "primary" : "secondary-gray",
                    disabled: resetting.busy,
                    onPress: () => setResetting(undefined),
                  },
                  ...(resetSettled
                    ? []
                    : [
                        {
                          label: resetting.busy
                            ? m.settings_providers_resetting()
                            : m.settings_providers_reset_confirm(),
                          disabled: resetting.busy,
                          onPress: () => resetQuota(resettingProfile),
                        },
                      ]),
                ]}
              >
                {resetting.outcome ? (
                  <output className="text-sm text-secondary">
                    {resetting.outcome}
                  </output>
                ) : null}
              </Dialog>
            ),
          }
        : {}),
  };

  if (!view) return { category };
  const detail = detailView(view);
  return { category: detail ? { ...category, detail } : category };

  function detailView(current: View): SettingsCategoryDetail | undefined {
    const back = m.settings_models_title();
    if (current.kind === "pick") {
      const groupLabel: Record<ProviderPreset["group"], string> = {
        labs: m.settings_providers_group_labs(),
        china: m.settings_providers_group_china(),
        gateways: m.settings_providers_group_gateways(),
        cloud: m.settings_providers_group_cloud(),
        inference: m.settings_providers_group_inference(),
        local: m.settings_providers_group_local(),
      };
      const tile = (entry: ProviderPreset) => (
        <button
          key={entry.id}
          type="button"
          className={tileClass}
          onClick={() => {
            const only = !entry.keySource
              ? "subscription"
              : !entry.subscriptionSource
                ? "api_key"
                : undefined;
            setView({
              kind: "connect",
              preset: entry.id,
              ...(only ? { method: only } : {}),
              key: "",
              baseUrl: "",
              busy: false,
            });
            // A plan alone has nothing to fill in: its sign-in starts now.
            if (only === "subscription") signIn.begin(entry.subscriptionSource!);
          }}
        >
          <ProviderMark brand={entry.brand} name={presetName(entry)} />
          <span className="truncate">{presetName(entry)}</span>
        </button>
      );
      return {
        id: "models.pick",
        title: m.settings_providers_pick(),
        description: m.settings_providers_pick_hint(),
        backLabel: back,
        onBack: close,
        content: (
          <div className="flex flex-col gap-lg">
            {presetGroups.map((group) => {
              const entries = presets.filter((entry) => entry.group === group);
              return entries.length ? (
                <section
                  key={group}
                  aria-label={groupLabel[group]}
                  className="flex flex-col gap-xs"
                >
                  <h3 className="text-xs font-medium text-tertiary">
                    {groupLabel[group]}
                  </h3>
                  <div className="-mx-md grid grid-cols-3 gap-xs">
                    {group === "gateways" && tokenDanceAvailable() ? (
                      <button
                        type="button"
                        className={tileClass}
                        onClick={() => {
                          setView({ kind: "tokendance" });
                          tokenDance.start();
                        }}
                      >
                        <ProviderMark brand="tokendance" name={tokenDanceName} />
                        <span className="truncate">{tokenDanceName}</span>
                      </button>
                    ) : null}
                    {entries.map(tile)}
                  </div>
                </section>
              ) : null;
            })}
          </div>
        ),
      };
    }

    if (current.kind === "tokendance") {
      const state = tokenDance.state;
      return {
        id: "models.tokendance",
        title: m.settings_providers_connect_title({ name: tokenDanceName }),
        description: m.settings_providers_tokendance_hint(),
        backLabel: m.settings_providers_pick(),
        onBack: () => {
          tokenDance.reset();
          setView({ kind: "pick" });
        },
        actions:
          state.status === "failed" ? (
            <Button size="sm" onPress={tokenDance.start}>
              {m.settings_providers_tokendance_retry()}
            </Button>
          ) : null,
        content:
          state.status === "failed" ? (
            <p role="alert" className="text-pretty text-sm text-error-primary">
              {message(new Error(state.error))}
            </p>
          ) : (
            <output className="text-sm text-secondary">
              {state.status === "saving"
                ? m.settings_providers_tokendance_saving()
                : m.settings_providers_tokendance_waiting()}
            </output>
          ),
      };
    }

    if (current.kind === "connect") {
      const entry = presetById(current.preset);
      if (!entry) return undefined;
      const name = presetName(entry);
      const method: ConnectMethod | undefined = !entry.keySource
        ? "subscription"
        : !entry.subscriptionSource
          ? "api_key"
          : current.method;
      const isKey = method === "api_key";
      const busy = current.busy || signIn.state.busy;
      const fields: SettingsPanelItem[] = [];
      const renewed = current.reconnect
        ? profiles.find((account) => account.id === current.reconnect?.id)
        : undefined;
      // A provider with both: two choices, and the plan starts signing in.
      if (!method) {
        const plan = sourceName(entry.subscriptionSource!);
        return {
          id: `models.connect.${entry.id}`,
          title: m.settings_providers_connect_title({ name }),
          backLabel: m.settings_providers_pick(),
          onBack: () => setView({ kind: "pick" }),
          content: (
            <div className="grid w-full grid-cols-2 gap-md">
              <Choice
                label={m.settings_providers_method_subscription_named({ plan })}
                hint={m.settings_providers_method_subscription_hint({ plan })}
                onPress={() => {
                  setView({ ...current, method: "subscription" });
                  signIn.begin(entry.subscriptionSource!);
                }}
              />
              <Choice
                label={m.settings_providers_method_api()}
                hint={m.settings_providers_method_api_hint({ name })}
                onPress={() => setView({ ...current, method: "api_key" })}
              />
            </div>
          ),
        };
      }
      if (isKey && entry.baseUrl)
        fields.push(
          nameField(
            "models.connect.base-url",
            m.settings_providers_base_url(),
            current.baseUrl,
            (baseUrl) => setView({ ...current, baseUrl, error: undefined }),
            {
              placeholder: entry.discover?.placeholder ?? "https://api.example.com/v1",
              ...(entry.discover
                ? { description: m.settings_providers_endpoint_hint() }
                : {}),
              disabled: busy,
            }
          )
        );
      // An endpoint of the reader's own speaks one protocol: chosen here when
      // the source speaks several, as Cloudflare AI Gateway does.
      const protocols: readonly ModelProtocol[] = entry.discover
        ? entry.discover.protocol
          ? [entry.discover.protocol]
          : ["chat_completions", "responses", "anthropic"]
        : entry.baseUrl
          ? (catalog?.sources[entry.keySource ?? ""]?.protocols ?? [])
          : [];
      const protocol: ModelProtocol | undefined =
        current.protocol && protocols.includes(current.protocol)
          ? current.protocol
          : protocols[0];
      if (isKey && protocols.length > 1)
        fields.push({
          id: "models.connect.protocol",
          title: m.settings_providers_protocol(),
          control: {
            type: "dropdown",
            ariaLabel: m.settings_providers_protocol(),
            ...(protocol ? { value: protocol } : {}),
            disabled: busy,
            items: protocols.map((id) => ({ id, label: protocolLabels[id] })),
            onChange: (id) =>
              setView({ ...current, protocol: id as ModelProtocol, error: undefined }),
          },
        });
      if (isKey)
        fields.push(
          nameField(
            "models.connect.key",
            entry.keyOptional
              ? m.settings_providers_key_optional()
              : m.settings_providers_key(),
            current.key,
            (key) => setView({ ...current, key, error: undefined }),
            {
              description: m.settings_providers_key_notice(),
              type: "password",
              error: current.error,
              disabled: busy,
            }
          )
        );

      const attempt = signIn.state.attempt;
      if (!isKey && attempt) {
        fields.push({
          id: "models.connect.signin",
          title:
            attempt.mode === "device"
              ? m.settings_providers_device_code()
              : m.settings_providers_signin_waiting(),
          layout: "stack",
          control: {
            type: "custom",
            content: signIn.state.native ? (
              <output className="text-sm text-secondary">
                {m.settings_providers_callback_wait()}
              </output>
            ) : attempt.mode === "device" ? (
              <div className="flex flex-col items-start gap-md">
                <p className="text-sm text-secondary">
                  {m.settings_providers_device_hint()}
                </p>
                <output
                  aria-label={m.settings_providers_device_code()}
                  className="select-all font-mono text-2xl font-semibold tracking-widest text-primary"
                >
                  {attempt.user_code}
                </output>
                <Button
                  size="sm"
                  onPress={() => {
                    // One press: the code is on the clipboard when the page opens.
                    void navigator.clipboard
                      ?.writeText(attempt.user_code ?? "")
                      .catch(() => undefined);
                    signIn.openAuthorization();
                  }}
                >
                  {m.settings_providers_copy_and_open()}
                </Button>
                <output className="text-xs text-tertiary">
                  {m.settings_providers_device_waiting()}
                </output>
              </div>
            ) : (
              <div className="flex flex-col gap-md">
                <p className="text-sm text-secondary">
                  {m.settings_providers_callback_hint()}
                </p>
                <div>
                  <Button size="sm" onPress={signIn.openAuthorization}>
                    {m.settings_providers_open_signin()}
                  </Button>
                </div>
                <InputField
                  className="w-full"
                  label={m.settings_providers_callback_code()}
                  autoComplete="off"
                  type="password"
                  disabled={busy}
                  value={signIn.state.code}
                  onChange={(event) => signIn.setCode(event.target.value)}
                  onPaste={(event) => {
                    // A pasted callback address or code finishes on its own;
                    // typing still waits for "Finish sign-in".
                    const value = event.clipboardData.getData("text");
                    if (pastedCallback(value)) signIn.complete(value);
                  }}
                />
              </div>
            ),
          },
        });
      }

      const signInError = signIn.state.error ? message(signIn.state.error) : undefined;
      const waiting = !!attempt && (attempt.mode === "device" || signIn.state.native);
      const canSubmit = isKey
        ? !busy &&
          (entry.keyOptional || !!current.key.trim()) &&
          (!entry.baseUrl || !!current.baseUrl.trim())
        : !busy && !waiting && (!attempt || !!signIn.state.code.trim());
      const submit = () => {
        if (!canSubmit || !workspace) return;
        if (!isKey) {
          if (attempt) signIn.complete();
          else
            signIn.begin(
              entry.subscriptionSource!,
              current.reconnect && {
                account_id: current.reconnect.id,
                version: current.reconnect.version,
              }
            );
          return;
        }
        const source = entry.keySource!;
        const requested = generation.current;
        const key = current.key.trim();
        const baseUrl = current.baseUrl.trim();
        setView({ ...current, busy: true, error: undefined });
        void (async () => {
          // An endpoint outside the catalog lists its models first; the
          // profile serves those ids.
          const listed =
            entry.discover && protocol
              ? await discoverModelIds(baseUrl, protocol, key)
              : undefined;
          return api.createSubscriptionAccount(workspace, {
            credential_kind: "provider_api_key",
            source,
            ...(key || !entry.keyOptional ? { api_key: key } : {}),
            // A key is named for its provider, and a Custom endpoint for its
            // host; the reader may rename it later.
            name: entry.id === "custom" ? endpointHost(baseUrl) : name,
            ...(entry.baseUrl ? { base_url: baseUrl } : {}),
            ...(protocol ? { protocol } : {}),
            ...(listed ? { models: listed } : {}),
          });
        })()
          .then((account) => {
            if (requested !== generation.current) return;
            if (profiles.length === 0) confirmFirstProfile();
            setPage((previous) => ({
              accounts: [...(previous?.accounts ?? []), account],
              next: previous?.next ?? "",
            }));
            settleForm(current, undefined);
          })
          .catch((reason: unknown) => {
            if (requested !== generation.current) return;
            settleForm(current, {
              ...current,
              busy: false,
              error:
                reason instanceof Error && reason.message === "no_models"
                  ? m.settings_providers_discover_none()
                  : reason instanceof CommaApiError &&
                      (reason.status === 400 || reason.status === 422)
                    ? entry.discover
                      ? m.settings_providers_discover_error()
                      : m.settings_providers_key_error({ name })
                    : message(reason),
            });
          });
      };
      return {
        id: `models.connect.${entry.id}`,
        title: current.reconnect
          ? m.settings_providers_reauth_title({
              name: renewed ? profileName(renewed) : name,
            })
          : m.settings_providers_connect_title({ name }),
        description: current.reconnect
          ? m.settings_providers_reauth_hint()
          : isKey
            ? m.settings_providers_connect_hint()
            : m.settings_providers_signin_hint(),
        backLabel: current.reconnect ? back : m.settings_providers_pick(),
        onBack: () => {
          signIn.reset();
          setView(current.reconnect ? undefined : { kind: "pick" });
        },
        onSubmit: submit,
        actions: waiting ? null : (
          <Button size="sm" disabled={!canSubmit} onPress={submit}>
            {busy
              ? m.settings_providers_connecting()
              : isKey
                ? m.settings_providers_connect()
                : attempt
                  ? m.settings_providers_finish_signin()
                  : current.reconnect
                    ? m.settings_providers_reauth()
                    : m.settings_providers_signin()}
          </Button>
        ),
        sections: [{ id: "models.connect", title: "", items: fields }],
        ...(signInError
          ? {
              content: (
                <p role="alert" className="text-pretty text-sm text-error-primary">
                  {signInError}
                </p>
              ),
            }
          : {}),
      };
    }

    if (current.kind === "profile") {
      const account = profiles.find((entry) => entry.id === current.id);
      if (!account) return undefined;
      const served = models.filter((model) =>
        profileRoute(model, account, catalog?.sources)
      );
      return {
        id: `models.profile.${account.id}`,
        title: profileName(account),
        description: profileSummary(account),
        backLabel: back,
        onBack: close,
        sections: [
          {
            id: "models.profile.models",
            title: m.settings_providers_models(),
            items: served.length
              ? served.map((model) => ({
                  id: `models.profile.model.${model.id}`,
                  title: model.name,
                  icon: <ModelVendorIcon vendor={model.vendor} />,
                  description: m.settings_providers_model_request({
                    id: profileRoute(model, account, catalog?.sources)!.model,
                  }),
                  control: {
                    type: "button" as const,
                    label: m.settings_providers_details(),
                    onPress: () =>
                      setView({ kind: "model", modelId: model.id, from: account.id }),
                  },
                }))
              : [
                  {
                    id: "models.profile.models.empty",
                    title: m.settings_providers_profile_models_empty(),
                  },
                ],
          },
        ],
      };
    }

    if (current.kind === "model") {
      const model = modelById.get(current.modelId);
      if (!model) return undefined;
      const sources = Object.entries(model.routes);
      return {
        id: `models.model.${model.id}`,
        title: model.name,
        description: m.settings_providers_model_detail_hint(),
        backLabel: m.settings_providers_view_models(),
        onBack: () => setView({ kind: "profile", id: current.from }),
        sections: [
          {
            id: "models.model.ids",
            title: m.settings_providers_model_ids(),
            items: [
              {
                id: "models.model.id",
                title: m.settings_providers_model_id(),
                description: m.settings_providers_model_id_hint(),
                control: codeControl(model.id),
              },
              {
                id: "models.model.display",
                title: m.settings_providers_model_display(),
                control: {
                  type: "custom",
                  content: <span className="text-sm text-primary">{model.name}</span>,
                },
              },
            ],
          },
          {
            id: "models.model.sources",
            title: m.settings_providers_model_providers(),
            // The request id belongs to the source; every profile of it sends the same one.
            items: sources.map(([source, route]) => {
              const users = profiles.filter((account) => account.source === source);
              const entry = presetForSource(presets, source);
              return {
                id: `models.model.source.${source}`,
                title: sourceName(source),
                icon: (
                  <ProviderMark
                    brand={entry?.brand ?? source}
                    name={sourceName(source)}
                  />
                ),
                description: users.length
                  ? m.settings_providers_model_request_profiles({
                      id: route.model,
                      profiles: users.map(profileName).join(", "),
                    })
                  : m.settings_providers_model_request({ id: route.model }),
              };
            }),
          },
        ],
      };
    }

    if (current.kind === "rename-profile" || current.kind === "replace-key") {
      const account = profiles.find((entry) => entry.id === current.id);
      if (!account || !workspace) return undefined;
      const renaming = current.kind === "rename-profile";
      const value = renaming ? current.name : current.key;
      const save = () => {
        if (!value.trim() || current.busy) return;
        const requested = generation.current;
        setView({ ...current, busy: true, error: undefined });
        void api
          .updateSubscriptionAccount(workspace, account.id, {
            version: account.version,
            ...(renaming ? { name: value.trim() } : { api_key: value.trim() }),
          })
          .then((updated) => {
            if (requested !== generation.current) return;
            replaceProfile(updated);
            settleForm(current, undefined);
          })
          .catch((reason: unknown) => {
            if (requested !== generation.current) return;
            settleForm(current, {
              ...current,
              busy: false,
              error:
                !renaming &&
                reason instanceof CommaApiError &&
                (reason.status === 400 || reason.status === 422)
                  ? m.settings_providers_key_error({ name: providerName(account) })
                  : message(reason),
            });
          });
      };
      const label = renaming
        ? m.settings_providers_profile_name()
        : m.settings_providers_key();
      return {
        id: `models.${current.kind}.${account.id}`,
        title: renaming
          ? m.settings_providers_rename_title()
          : m.settings_providers_replace_key(),
        description: profileName(account),
        backLabel: back,
        onBack: close,
        onSubmit: save,
        actions: (
          <Button size="sm" disabled={!value.trim() || current.busy} onPress={save}>
            {m.settings_providers_save()}
          </Button>
        ),
        sections: [
          {
            id: `models.${current.kind}`,
            title: "",
            items: [
              nameField(
                `models.${current.kind}.field`,
                label,
                value,
                (next) =>
                  setView(
                    current.kind === "rename-profile"
                      ? { ...current, name: next, error: undefined }
                      : { ...current, key: next, error: undefined }
                  ),
                {
                  error: current.error,
                  disabled: current.busy,
                  ...(renaming
                    ? {}
                    : {
                        type: "password",
                        description: m.settings_providers_key_notice(),
                      }),
                }
              ),
            ],
          },
        ],
      };
    }

    const agent = [agents?.agents.router, ...(agents?.workers.items ?? [])].find(
      (entry) => entry?.agent_id === current.agentId
    );
    if (!agent || !workspace) return undefined;
    const save = () => {
      const name = current.name.trim();
      if (!name || current.busy) return;
      const requested = generation.current;
      setView({ ...current, busy: true, error: undefined });
      void api
        .renameAgent(workspace, agent.agent_id, name)
        .then(() => {
          if (requested !== generation.current) return;
          patchAgent(agent.agent_id, { name });
          if (agent.role === "router") routerRenamed(name, workspace);
          settleForm(current, undefined);
        })
        .catch((reason: unknown) => {
          if (requested === generation.current)
            settleForm(current, { ...current, busy: false, error: message(reason) });
        });
    };
    return {
      id: `models.rename-agent.${agent.agent_id}`,
      title: m.settings_providers_rename_agent({ name: agent.name }),
      backLabel: back,
      onBack: close,
      onSubmit: save,
      actions: (
        <Button
          size="sm"
          disabled={!current.name.trim() || current.busy}
          onPress={save}
        >
          {m.settings_providers_save()}
        </Button>
      ),
      sections: [
        {
          id: "models.rename-agent",
          title: "",
          items: [
            nameField(
              "models.rename-agent.name",
              m.settings_providers_agent_name(),
              current.name,
              (name) => setView({ ...current, name, error: undefined }),
              { error: current.error, disabled: current.busy }
            ),
          ],
        },
      ],
    };
  }
}
