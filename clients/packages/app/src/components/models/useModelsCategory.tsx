import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { InputField } from "@comma/ui/components/input";
import {
  ModelPicker,
  type ModelPickerAccount,
  type ModelPickerModel,
  type ModelPickerValue,
} from "@comma/ui/components/model-picker";
import { ModelVendorIcon } from "@comma/ui/components/model-icons/ModelVendorIcon";
import { MoreHorizontalIcon } from "@comma/ui/components/icons";
import { Toggle } from "@comma/ui/components/toggle";
import { toast } from "@comma/ui/components/toast";
import {
  type SettingsCategoryDefinition,
  type SettingsCategoryDetail,
} from "@comma/ui/components/settings";
import {
  type SettingsControl,
  type SettingsPanelItem,
} from "@comma/ui/components/settings-panel";
import {
  useCall,
  useTopic,
  type AgentSelection,
  type CatalogModel,
  type ModelProtocol,
  type ProviderPreset,
  type SettingsAgent,
  type ShownModel,
  type ShownProfile,
  type TaskModelSelection,
  type TaskPlace,
} from "@comma/core-client";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrlFromUserAction,
} from "../../nativePlatformActions";
import { useWorkspacePreference } from "../activeWorkspace";
import { CommaProductMark } from "../CommaProductMark";
import { ProviderMark, QuotaMeters } from "./ProviderMarks";
import { presetGroups } from "./providerPresets";
import { useRouterRenamed } from "../router-identity/RouterIdentityProvider";
import { useSubscriptionSignIn } from "./useSubscriptionSignIn";
import { tokenDanceAvailable, useTokenDanceConnect } from "./useTokenDanceConnect";

type ConnectMethod = "api_key" | "subscription";

/** A place to run Tasks as a dropdown option's id. */
const placeId = (place: TaskPlace) =>
  place.kind === "station" ? `station:${place.device_id}` : place.kind;

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
  | {
      kind: "replace-key";
      id: string;
      key: string;
      busy: boolean;
      error?: string | undefined;
    };

const protocolLabels: Record<ModelProtocol, string> = {
  chat_completions: "OpenAI Chat Completions",
  responses: "OpenAI Responses",
  anthropic: "Anthropic Messages",
};

const tokenDanceName = "TokenDance";
const tileClass =
  "flex min-w-0 cursor-pointer items-center gap-sm rounded-lg px-md py-sm text-left text-sm text-primary transition-colors duration-150 ease-out hover:bg-secondary focus-visible:bg-secondary focus-visible:outline-none";
/** Custom has no brand to show, so it reads as a plain button instead of a logo tile. */
const customTileClass =
  "flex min-w-0 cursor-pointer items-center justify-self-start rounded-lg bg-secondary px-md py-sm text-left text-sm text-primary transition-colors duration-150 ease-out hover:bg-tertiary focus-visible:bg-tertiary focus-visible:outline-none";

/** Which form a view is, whatever its field values. */
const formKey = (view: View) =>
  `${view.kind}:${"preset" in view ? view.preset : "id" in view ? view.id : ""}`;

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

/**
 * Settings → Model & API: the profiles (subscriptions and API keys) the
 * system may route through, the model the Router runs on, and the model a
 * Task runs when it names none and where it runs when the Router names no
 * place.
 */
export function useModelsCategory(enabled: boolean): {
  category: SettingsCategoryDefinition;
  openProfile: (id: string) => void;
} {
  const m = useCommaMessages();
  const call = useCall();
  // A renamed Router's name shows in this window's chats at once.
  const routerRenamed = useRouterRenamed();
  const prefer = useWorkspacePreference();
  // The core reads the page while it shows; what it read for the workspace
  // stays across a tab switch, so the page does not collapse and grow back.
  const { value: shownPage } = useTopic(
    enabled && prefer !== undefined ? { topic: "models", prefer } : null
  );
  // The computers and Cloud VM a Task can run on, as Settings › Devices lists them.
  const { value: shownDevices } = useTopic(
    enabled && prefer !== undefined ? { topic: "devices", prefer } : null
  );
  const [checking, setChecking] = useState<ReadonlySet<string>>(new Set());
  const [actionError, setActionError] = useState<string>();
  const [agentErrors, setAgentErrors] = useState<Record<string, string>>({});
  const [taskModelError, setTaskModelError] = useState<string>();
  const [taskPlaceError, setTaskPlaceError] = useState<string>();
  const [view, setView] = useState<View>();
  const [removing, setRemoving] = useState<{ id: string; busy: boolean }>();
  /** A name being edited in the rename dialog: an Agent's or a profile's. */
  const [rename, setRename] = useState<{
    kind: "agent" | "profile";
    id: string;
    name: string;
    busy: boolean;
    error?: string | undefined;
  }>();
  const [resetting, setResetting] = useState<{
    id: string;
    busy: boolean;
    outcome?: string;
    /** The provider answered; nothing is left to retry. */
    settled?: boolean;
  }>();
  // Answers that arrive after the workspace changed are not shown.
  const generation = useRef(0);
  /** Whether there was no profile yet when the sign-in now under way started. */
  const firstProfile = useRef(false);

  const message = useCallback(
    (reason: unknown) => {
      const code =
        (reason as { code?: unknown } | null)?.code ??
        (reason instanceof Error ? reason.message : "");
      if (code === "conflict") return m.settings_providers_conflict();
      if (code === "authorization_port_in_use")
        return m.settings_providers_port_in_use();
      if (code === "authorization_expired")
        return m.settings_providers_signin_expired();
      return m.settings_providers_error();
    },
    [m]
  );

  // Another workspace: its own page.
  const shownPrefer = useRef(prefer);
  useEffect(() => {
    if (shownPrefer.current === prefer) return;
    shownPrefer.current = prefer;
    generation.current += 1;
    setTaskModelError(undefined);
    setTaskPlaceError(undefined);
    setView(undefined);
    setRename(undefined);
    setResetting(undefined);
    setActionError(undefined);
  }, [prefer]);

  // Entering the page reads it again: the menu-bar item can hold this topic,
  // which then does not start (and read) as the page opens.
  useEffect(() => {
    if (enabled) void call("models.refresh", {}).catch(() => null);
  }, [call, enabled]);

  const workspace = shownPage?.workspace ?? undefined;
  const catalog = shownPage?.catalog ?? undefined;
  const profiles = useMemo(() => shownPage?.profiles ?? [], [shownPage]);
  const agents = shownPage?.agents ?? undefined;
  const presets = shownPage?.presets ?? [];
  const error =
    actionError ?? (shownPage?.error ? m.settings_providers_error() : undefined);
  // Models a Custom endpoint lists that the catalog does not know form one group.
  const models = useMemo(
    () =>
      (shownPage?.models ?? []).map((model) =>
        model.custom ? { ...model, family: m.settings_providers_custom() } : model
      ),
    [shownPage, m]
  );
  const modelById = useMemo(
    () => new Map(models.map((model) => [model.id, model])),
    [models]
  );
  const profileById = useMemo(
    () => new Map(profiles.map((account) => [account.id, account])),
    [profiles]
  );

  /** Runs a change; a failure shows on the page, a success clears it. */
  const write = (operation: () => Promise<unknown>) => {
    const current = generation.current;
    return operation().then(
      () => {
        if (current === generation.current) setActionError(undefined);
      },
      (reason: unknown) => {
        if (current === generation.current) setActionError(message(reason));
      }
    );
  };

  // A subscription is named for its account; the reader may rename it later.
  const signIn = useSubscriptionSignIn(workspace, () => {
    const connect = view?.kind === "connect" ? view : undefined;
    if (firstProfile.current && !connect?.reconnect) confirmFirstProfile();
    setView(undefined);
  });

  /** Says once that nothing else is needed: Agents pick profiles themselves. */
  const confirmFirstProfile = () => toast.success(m.settings_providers_first_added());

  // The core saved the key as a profile and read the profiles again.
  const tokenDance = useTokenDanceConnect(workspace, tokenDanceName, () => {
    if (firstProfile.current) confirmFirstProfile();
    setView(undefined);
  });

  /** Starts a plan's sign-in; `reconnect` renews that profile. */
  const beginSignIn = (
    entry: ProviderPreset,
    reconnect?: { account_id: string; version: string }
  ) => {
    firstProfile.current = profiles.length === 0;
    signIn.begin(entry.subscriptionSource!, {
      device: !!entry.deviceSignIn,
      ...(reconnect ? { reconnect } : {}),
    });
  };

  const presetById = (id: string | null | undefined) =>
    presets.find((entry) => entry.id === id);
  const presetName = (entry: ProviderPreset | undefined, fallback = "") => {
    if (!entry) return fallback;
    if (entry.id === "custom") return m.settings_providers_custom();
    if (entry.name) return entry.name;
    const source = entry.keySource ?? entry.subscriptionSource ?? "";
    return catalog?.sources[source]?.name ?? entry.name ?? source;
  };
  const sourceName = (source: string) => catalog?.sources[source]?.name ?? source;
  const providerName = (account: ShownProfile) => {
    if (account.tokenDance) return tokenDanceName;
    const entry = presetById(account.preset);
    return entry ? presetName(entry) : sourceName(account.source);
  };
  const profileName = (account: ShownProfile) =>
    shown(account.name) || shown(account.email) || providerName(account);
  const profileSummary = (account: ShownProfile) => {
    if (account.subscription) {
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
  const profileStatus = (account: ShownProfile) => {
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

  const toggleProfile = (account: ShownProfile) => {
    if (!workspace) return;
    void write(() =>
      call("models.updateProfile", {
        workspace,
        profile: account.id,
        disabled: !account.disabled,
      })
    );
  };

  /** Turns models on or off for a profile: shown at once, saved in order by the core. */
  const offerModels = (account: ShownProfile, ids: string[], on: boolean) => {
    if (!workspace) return;
    void write(() =>
      call("models.offer", { workspace, profile: account.id, models: ids, on })
    );
  };

  const refreshProfile = (account: ShownProfile) => {
    if (!workspace || checking.has(account.id)) return;
    setChecking((previous) => new Set(previous).add(account.id));
    void write(() =>
      call("models.refreshQuota", { workspace, profile: account.id })
    ).finally(() =>
      setChecking((previous) => {
        const next = new Set(previous);
        next.delete(account.id);
        return next;
      })
    );
  };

  const removeProfile = (account: ShownProfile) => {
    if (!workspace) return;
    setRemoving({ id: account.id, busy: true });
    void write(async () => {
      await call("models.deleteProfile", { workspace, profile: account.id });
      setView((open) =>
        open && "id" in open && open.id === account.id ? undefined : open
      );
    }).finally(() => setRemoving(undefined));
  };

  const reauthorize = (account: ShownProfile) => {
    const entry = presetById(account.preset);
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
    beginSignIn(entry, { account_id: account.id, version: account.version });
  };

  const resetQuota = (account: ShownProfile) => {
    if (!workspace || resetting?.busy) return;
    const current = generation.current;
    setResetting({ id: account.id, busy: true });
    call("models.resetQuota", { workspace, profile: account.id }).then(
      (result) => {
        if (current !== generation.current) return;
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
      },
      (reason: unknown) => {
        if (current !== generation.current) return;
        const { code, status = 0 } = (reason ?? {}) as {
          code?: string;
          status?: number;
        };
        // The profile changed or another reset holds it: the core shows the
        // current state, then the reader may try again with it.
        if (status === 409) {
          setResetting({
            id: account.id,
            busy: false,
            outcome:
              code === "reset_in_progress"
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
      }
    );
  };

  const loadMoreProfiles = () => {
    if (!workspace) return;
    void write(() => call("models.moreProfiles", { workspace }));
  };

  const profileRow = (account: ShownProfile): SettingsPanelItem => {
    const name = profileName(account);
    const entry = presetById(account.preset);
    const meters = account.subscription && !account.disabled ? account.meters : [];
    const signedIn = ["active", "connected"].includes(account.status);
    const expired =
      account.subscription &&
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
          brand={account.tokenDance ? "tokendance" : (entry?.brand ?? account.source)}
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
              setRename({ kind: "profile", id: account.id, name, busy: false }),
          },
          ...(account.subscription
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

  // The core shows a choice at once and saves one Agent's choices in order; a
  // failed save reads the Agents again, so the page shows what holds.
  const selectAgentModel = (agent: SettingsAgent, selection: AgentSelection) => {
    if (!workspace) return;
    const current = generation.current;
    setAgentErrors(({ [agent.agent_id]: _cleared, ...rest }) => rest);
    call("models.setAgentModel", {
      workspace,
      agent: agent.agent_id,
      selection,
    }).catch((reason: unknown) => {
      if (current !== generation.current) return;
      setAgentErrors((previous) => ({
        ...previous,
        [agent.agent_id]: message(reason),
      }));
    });
  };

  // The same for the workspace's default Task model.
  const selectTaskModel = (selection: TaskModelSelection) => {
    if (!workspace) return;
    const current = generation.current;
    setTaskModelError(undefined);
    call("models.setTaskModel", { workspace, selection }).catch((reason: unknown) => {
      if (current === generation.current) setTaskModelError(message(reason));
    });
  };

  // The same for where the workspace's Tasks run.
  const selectTaskPlace = (place: TaskPlace) => {
    if (!workspace) return;
    const current = generation.current;
    setTaskPlaceError(undefined);
    call("models.setTaskPlace", { workspace, place }).catch((reason: unknown) => {
      if (current !== generation.current) return;
      const code = (reason as { code?: unknown } | null)?.code;
      setTaskPlaceError(
        code === "cloud_vm_disabled"
          ? m.settings_providers_task_place_cloud_vm_off()
          : code === "not_found"
            ? m.settings_providers_task_place_missing()
            : message(reason)
      );
    });
  };

  /** The usable profiles that serve a model, in the page's order. */
  const servingOf = (model: ShownModel) =>
    model.serving.flatMap((id) => {
      const account = profileById.get(id);
      return account ? [account] : [];
    });

  /**
   * Catalog models some enabled profile serves, as the picker lists them:
   * families in catalog order, the newest model of each first.
   */
  const pickerModels = (chosen: string | undefined): ModelPickerModel[] => {
    const served = models.filter(
      (model) => model.id === chosen || model.serving.length > 0
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
    const serving = servingOf(model);
    const lost =
      pinned && !serving.some((account) => account.id === pinned)
        ? [
            {
              id: pinned,
              name: (() => {
                const account = profileById.get(pinned);
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
        const meters = account.subscription ? account.meters : [];
        const low = meters.some((meter) => meter.percent <= 10);
        return {
          id: account.id,
          name: profileName(account),
          icon: (
            <ProviderMark
              brand={presetById(account.preset)?.brand ?? account.source}
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
    model: ShownModel | undefined,
    paid: boolean,
    pinned: string | null | undefined
  ) => {
    const serving = model ? servingOf(model) : [];
    if (pinned)
      return serving.some((account) => account.id === pinned)
        ? undefined
        : m.settings_providers_pinned_unavailable();
    if (paid) return serving.length ? undefined : m.settings_providers_no_profile();
    return serving.some((account) => account.subscription)
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

  /** The row's own actions, apart from the model it runs. */
  const agentMenu = (agent: SettingsAgent): SettingsControl => ({
    type: "menu",
    label: m.settings_providers_actions({ name: agent.name }),
    icon: <MoreHorizontalIcon className="size-4" />,
    items: [
      {
        id: "rename",
        label: m.settings_providers_rename(),
        onPress: () =>
          setRename({
            kind: "agent",
            id: agent.agent_id,
            name: agent.name,
            busy: false,
          }),
      },
    ],
  });

  /**
   * The model picker for a choice, and why that choice cannot run if it
   * cannot. A choice outside the catalog reads as Comma's own.
   */
  const choice = (
    label: string,
    selection: AgentSelection,
    onChange: (next: TaskModelSelection) => void
  ) => {
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
        : { model: null, effort: null, profile: null, allowPaid: false };
    const warning =
      selection.kind === "catalog"
        ? runWarning(model, selection.allow_paid, selection.profile_id)
        : undefined;
    return {
      controlLeading: (
        <ModelPicker
          label={label}
          value={value}
          builtin={{
            label: m.settings_providers_builtin(),
            icon: <CommaProductMark className="size-4 shrink-0" />,
          }}
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
            onChange(
              next.model === null
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
      content: warning ? (
        <p role="alert" className="text-pretty text-xs text-warning-primary">
          {warning}
        </p>
      ) : null,
    };
  };

  const routerRow = (agent: SettingsAgent): SettingsPanelItem => {
    const errorMessage = agentErrors[agent.agent_id];
    return {
      id: `models.agent.${agent.agent_id}`,
      title: agent.name,
      description: m.settings_providers_router_role(),
      ...(errorMessage ? { errorMessage } : {}),
      ...choice(agent.name, agent.selection ?? { kind: "builtin" }, (selection) =>
        selectAgentModel(agent, selection)
      ),
      control: agentMenu(agent),
    };
  };

  /**
   * Where Tasks run when the Router names no place: Comma's cloud, the Cloud
   * VM when the workspace has one, or one of the person's computers. The place
   * held shows even when the list does not offer it (yet).
   */
  const placeRow = (held: TaskPlace): SettingsPanelItem => {
    const places = new Map<string, { place: TaskPlace; label: string }>([
      [
        "salix",
        { place: { kind: "salix" }, label: m.settings_providers_task_place_salix() },
      ],
    ]);
    if (shownDevices?.cloud || held.kind === "cloud_vm")
      places.set("cloud_vm", {
        place: { kind: "cloud_vm" },
        label: m.settings_providers_task_place_cloud_vm(),
      });
    for (const device of shownDevices?.devices ?? [])
      places.set(`station:${device.device_id}`, {
        place: { kind: "station", device_id: device.device_id },
        label: device.alias || device.name,
      });
    if (!places.has(placeId(held)) && held.kind === "station")
      places.set(placeId(held), { place: held, label: held.device_id });
    return {
      id: "models.task-place",
      title: m.settings_providers_task_place(),
      description: m.settings_providers_task_place_hint(),
      ...(taskPlaceError ? { errorMessage: taskPlaceError } : {}),
      control: {
        type: "dropdown",
        ariaLabel: m.settings_providers_task_place(),
        value: placeId(held),
        disabled: !workspace,
        items: [...places].map(([id, { label }]) => ({ id, label })),
        onChange: (id) => {
          const chosen = places.get(id);
          if (chosen && id !== placeId(held)) selectTaskPlace(chosen.place);
        },
      },
    };
  };

  const agentItems: SettingsPanelItem[] = agents
    ? [
        routerRow(agents.agents.router),
        {
          id: "models.task-model",
          title: m.settings_providers_task_model(),
          description: m.settings_providers_task_model_hint(),
          ...(taskModelError ? { errorMessage: taskModelError } : {}),
          ...choice(
            m.settings_providers_task_model(),
            agents.task_model.selection,
            selectTaskModel
          ),
        },
        placeRow(agents.task_place.place),
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
  const renamingAgent =
    rename?.kind === "agent" && agents?.agents.router.agent_id === rename.id
      ? agents.agents.router
      : undefined;
  const renamingProfile =
    rename?.kind === "profile"
      ? profiles.find((entry) => entry.id === rename.id)
      : undefined;
  const nameBefore =
    renamingAgent?.name ?? (renamingProfile && profileName(renamingProfile));
  const renamedTo = rename?.name.trim() ?? "";
  const canRename =
    nameBefore !== undefined &&
    !!renamedTo &&
    renamedTo !== nameBefore &&
    !rename?.busy;
  const saveRename = () => {
    if (!rename || !workspace || !canRename) return;
    const form = rename;
    const requested = generation.current;
    setRename({ ...form, busy: true, error: undefined });
    const saved = renamingAgent
      ? call("models.renameAgent", {
          workspace,
          agent: renamingAgent.agent_id,
          name: renamedTo,
        }).then(() => {
          if (requested !== generation.current) return;
          routerRenamed(renamedTo, workspace);
        })
      : call("models.updateProfile", { workspace, profile: form.id, name: renamedTo });
    void saved
      .then(() => {
        if (requested === generation.current) setRename(undefined);
      })
      .catch((reason: unknown) => {
        if (requested === generation.current)
          setRename((open) =>
            open?.kind === form.kind && open.id === form.id
              ? { ...open, busy: false, error: message(reason) }
              : open
          );
      });
  };

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
            // The row states what the reader has; the button says what to do.
            title:
              shownPage?.profiles && !profiles.length
                ? m.settings_providers_empty_title()
                : m.settings_providers_add_profile_title(),
            description: profiles.length
              ? m.settings_providers_add_profile_hint()
              : m.settings_providers_empty_hint(),
            descriptionLoading: !shownPage?.profiles && !error,
            ...(error ? { errorMessage: error } : {}),
            control: {
              type: "button",
              label: m.settings_providers_add_profile(),
              disabled: !workspace || !catalog,
              onPress: () => setView({ kind: "pick" }),
            },
          },
          ...profiles.map(profileRow),
          ...(shownPage?.moreProfiles
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
        : rename && nameBefore !== undefined
          ? {
              overlay: (
                <Dialog
                  isOpen
                  isDismissable={!rename.busy}
                  onOpenChange={(open) => {
                    if (!open && !rename.busy) setRename(undefined);
                  }}
                  title={
                    rename.kind === "agent"
                      ? m.settings_providers_rename_agent()
                      : m.settings_providers_rename_title()
                  }
                  variant="input"
                  input={{
                    label:
                      rename.kind === "agent"
                        ? m.settings_providers_agent_name()
                        : m.settings_providers_profile_name(),
                    autoFocus: true,
                    value: rename.name,
                    disabled: rename.busy,
                    ...(rename.error ? { errorMessage: rename.error } : {}),
                    onChange: (event) =>
                      setRename({
                        ...rename,
                        name: event.target.value,
                        error: undefined,
                      }),
                  }}
                  actions={[
                    {
                      label: m.settings_providers_cancel(),
                      hierarchy: "secondary-gray",
                      disabled: rename.busy,
                      onPress: () => setRename(undefined),
                    },
                    {
                      label: m.settings_providers_save(),
                      hierarchy: "primary",
                      disabled: !canRename,
                      onPress: saveRename,
                    },
                  ]}
                />
              ),
            }
          : {}),
  };

  const openProfile = (id: string) => setView({ kind: "profile", id });
  if (!view) return { category, openProfile };
  const detail = detailView(view);
  return {
    category: detail ? { ...category, detail } : category,
    openProfile,
  };

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
          className={entry.id === "custom" ? customTileClass : tileClass}
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
            if (only === "subscription") beginSignIn(entry);
          }}
        >
          {entry.id === "custom" ? null : (
            <ProviderMark brand={entry.brand} name={presetName(entry)} />
          )}
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
          <div className="flex flex-col gap-3xl">
            {presetGroups.map((group) => {
              const entries = presets.filter((entry) => entry.group === group);
              return entries.length ? (
                <section
                  key={group}
                  aria-label={groupLabel[group]}
                  className="flex flex-col gap-xxs"
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
                          firstProfile.current = profiles.length === 0;
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
              {m.settings_providers_tokendance_waiting()}
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
                  beginSignIn(entry);
                }}
              />
              <Choice
                label={m.settings_providers_method_api()}
                hint={
                  entry.keyUsesPlan
                    ? m.settings_providers_method_api_plan_hint({ plan })
                    : m.settings_providers_method_api_hint({ name })
                }
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
      // A browser sign-in that hands back a code is two steps, one row each:
      // open the page, then paste what it shows.
      if (!isKey && attempt && attempt.mode !== "device" && !signIn.state.native)
        fields.push(
          {
            id: "models.connect.signin",
            title: m.settings_providers_callback_step({ name }),
            description: m.settings_providers_callback_hint({ name }),
            control: {
              type: "button",
              label: m.settings_providers_open_signin({ name }),
              onPress: signIn.openAuthorization,
            },
          },
          {
            id: "models.connect.code",
            title: m.settings_providers_callback_code(),
            description: m.settings_providers_callback_code_hint(),
            layout: "field",
            control: {
              type: "custom",
              content: (
                <InputField
                  className="w-full"
                  fieldSize="sm"
                  aria-label={m.settings_providers_callback_code()}
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
              ),
            },
          }
        );
      else if (!isKey && attempt) {
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
                    void openNativePlatformExternalUrlFromUserAction(async () => {
                      await nativePlatformClipboard.writeText(attempt.user_code ?? "");
                      return attempt.url;
                    }).catch(() => {
                      toast.error(m.settings_providers_copy_and_open_failed());
                    });
                  }}
                >
                  {m.settings_providers_copy_and_open({ name })}
                </Button>
                <output className="text-xs text-tertiary">
                  {m.settings_providers_device_waiting()}
                </output>
              </div>
            ) : null,
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
            beginSignIn(
              entry,
              current.reconnect && {
                account_id: current.reconnect.id,
                version: current.reconnect.version,
              }
            );
          return;
        }
        const requested = generation.current;
        const key = current.key.trim();
        const baseUrl = current.baseUrl.trim();
        const first = profiles.length === 0;
        setView({ ...current, busy: true, error: undefined });
        call("models.createProfile", {
          workspace,
          source: entry.keySource!,
          ...(key ? { api_key: key } : {}),
          // A key is named for its provider, and a Custom endpoint (by the
          // core) for its host; the reader may rename it later.
          ...(entry.id === "custom" ? {} : { name }),
          ...(entry.baseUrl ? { base_url: baseUrl } : {}),
          ...(protocol ? { protocol } : {}),
          // An endpoint outside the catalog lists its models first; the
          // profile serves those ids.
          ...(entry.discover && protocol ? { discover: true } : {}),
        }).then(
          () => {
            if (requested !== generation.current) return;
            if (first) confirmFirstProfile();
            settleForm(current, undefined);
          },
          (reason: unknown) => {
            if (requested !== generation.current) return;
            const { code, status } = (reason ?? {}) as {
              code?: string;
              status?: number;
            };
            settleForm(current, {
              ...current,
              busy: false,
              error:
                code === "no_models"
                  ? m.settings_providers_discover_none()
                  : status === 400 || status === 422
                    ? entry.discover
                      ? m.settings_providers_discover_error()
                      : m.settings_providers_key_error({ name })
                    : message(reason),
            });
          }
        );
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
      const account = profileById.get(current.id);
      if (!account) return undefined;
      // Every model the profile can serve, in the picker's families: catalog
      // order, the newest model of each first. Only those left on reach it.
      const servable = account.servable.flatMap(({ model: id, request }) => {
        const model = modelById.get(id);
        return model ? [{ model, request }] : [];
      });
      const turnedOff = (id: string) => !!account.disabled_models?.includes(id);
      const families = [...new Set(servable.map(({ model }) => familyKey(model)))];
      const sections = families.map((key) => {
        const inFamily = servable.filter(({ model }) => familyKey(model) === key);
        // Catalog families list newest first; listed Custom ids keep their order.
        const members =
          inFamily[0]!.model.vendor === "custom" ? inFamily : inFamily.toReversed();
        const family = members[0]!.model.family ?? members[0]!.model.name;
        const ids = members.map(({ model }) => model.id);
        const allOn = ids.every((id) => !turnedOff(id));
        return {
          id: `models.profile.family.${key}`,
          title: family,
          ...(members.length > 1
            ? {
                titleAction: (
                  <Button
                    hierarchy="link-gray"
                    size="xs"
                    aria-label={
                      allOn
                        ? m.settings_providers_family_off_named({ family })
                        : m.settings_providers_family_on_named({ family })
                    }
                    onPress={() => offerModels(account, ids, !allOn)}
                  >
                    {allOn
                      ? m.settings_providers_family_off()
                      : m.settings_providers_family_on()}
                  </Button>
                ),
              }
            : {}),
          // One dense list per family: a checkbox and the model; its ids on hover.
          items: [
            {
              id: `models.profile.family.${key}.models`,
              title: family,
              layout: "stack" as const,
              control: {
                type: "custom" as const,
                content: (
                  <ul className="-mx-sm grid w-full grid-cols-[repeat(auto-fill,minmax(14rem,1fr))] gap-x-md">
                    {members.map(({ model, request }) => {
                      const on = !turnedOff(model.id);
                      return (
                        <li
                          key={model.id}
                          className="flex min-w-0 items-center gap-xs rounded-md px-sm hover:bg-secondary"
                        >
                          <label
                            // The ids are for the curious: shown on hover.
                            title={
                              request === model.id
                                ? model.id
                                : m.settings_providers_model_ids_hover({
                                    id: model.id,
                                    request,
                                  })
                            }
                            className="flex min-w-0 flex-1 cursor-pointer items-center gap-sm py-xs text-sm text-primary"
                          >
                            <input
                              type="checkbox"
                              className="size-4 shrink-0 cursor-pointer accent-brand-solid"
                              checked={on}
                              onChange={() => offerModels(account, [model.id], !on)}
                            />
                            <ModelVendorIcon vendor={model.vendor} />
                            <span className="truncate">{model.name}</span>
                          </label>
                        </li>
                      );
                    })}
                  </ul>
                ),
              },
            },
          ],
        };
      });
      return {
        id: `models.profile.${account.id}`,
        title: profileName(account),
        description: (
          <span className="flex flex-col gap-xxs">
            <span>{profileSummary(account)}</span>
            {sections.length ? (
              <span>{m.settings_providers_profile_models_hint()}</span>
            ) : null}
          </span>
        ),
        backLabel: back,
        onBack: close,
        // A save that failed says so where the reader made it.
        ...(error
          ? {
              content: (
                <p role="alert" className="text-pretty text-sm text-error-primary">
                  {error}
                </p>
              ),
            }
          : {}),
        sections: sections.length
          ? sections
          : [
              {
                id: "models.profile.models",
                title: m.settings_providers_models(),
                items: [
                  {
                    id: "models.profile.models.empty",
                    title: m.settings_providers_profile_models_empty(),
                  },
                ],
              },
            ],
      };
    }

    const account = profileById.get(current.id);
    if (!account || !workspace) return undefined;
    const save = () => {
      const key = current.key.trim();
      if (!key || current.busy) return;
      const requested = generation.current;
      setView({ ...current, busy: true, error: undefined });
      call("models.updateProfile", {
        workspace,
        profile: account.id,
        api_key: key,
      }).then(
        () => {
          if (requested === generation.current) settleForm(current, undefined);
        },
        (reason: unknown) => {
          if (requested !== generation.current) return;
          const status = (reason as { status?: number } | null)?.status;
          settleForm(current, {
            ...current,
            busy: false,
            error:
              status === 400 || status === 422
                ? m.settings_providers_key_error({ name: providerName(account) })
                : message(reason),
          });
        }
      );
    };
    return {
      id: `models.replace-key.${account.id}`,
      title: m.settings_providers_replace_key(),
      description: profileName(account),
      backLabel: back,
      onBack: close,
      onSubmit: save,
      actions: (
        <Button size="sm" disabled={!current.key.trim() || current.busy} onPress={save}>
          {m.settings_providers_save()}
        </Button>
      ),
      sections: [
        {
          id: "models.replace-key",
          title: "",
          items: [
            nameField(
              "models.replace-key.field",
              m.settings_providers_key(),
              current.key,
              (key) => setView({ ...current, key, error: undefined }),
              {
                error: current.error,
                disabled: current.busy,
                type: "password",
                description: m.settings_providers_key_notice(),
              }
            ),
          ],
        },
      ],
    };
  }
}
