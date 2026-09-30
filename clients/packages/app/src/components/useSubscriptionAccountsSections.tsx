import { getNativeBridge } from "@comma/native-bridge";
import type { JsonValue } from "../api/types";
import { useCallback, useContext, useEffect, useRef, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  InputField,
  type SettingsCategoryDefinition,
  type SettingsCategoryDetail,
  SubscriptionAccounts,
  SubscriptionCredentialInput,
  SubscriptionProviderChoice,
  SubscriptionSteps,
  type SubscriptionAccountRow,
  type SubscriptionProviderOption,
} from "@comma/ui";
import type { CommaApiClient } from "../api";
import type {
  SubscriptionAccount,
  SubscriptionOAuth,
  SubscriptionPage,
  SubscriptionProvider,
} from "../api/subscriptionAccounts";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "./activeWorkspace";
import {
  openNativePlatformExternalUrl,
  openNativePlatformExternalUrlFromUserAction,
} from "../runtime-chat/nativePlatformActions";
import { CommaAuthContext } from "./auth-context";

const providerName = (provider: SubscriptionProvider) =>
  provider === "codex" ? "Codex" : "Claude";

/**
 * Reset and expiry times land in a narrow column and a field hint, where a full
 * locale timestamp wraps to two lines and buries the part that matters.
 */
const shortMoment = (value: string) =>
  new Date(value).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });

/**
 * Where each provider's CLI writes the credential file. Naming the path is the
 * difference between an import dialog a developer can act on and one that only
 * says "paste its JSON" without saying which JSON.
 */
const credentialPaths: Record<SubscriptionProvider, string> = {
  codex: "~/.codex/auth.json",
  claude: "~/.claude/.credentials.json",
};

export function useSubscriptionAccountsSections(api: CommaApiClient, enabled: boolean) {
  const m = useCommaMessages();
  const productLease = useContext(CommaAuthContext)?.productLease;
  const [workspace, setWorkspace] = useState(readActiveWorkspaceId);
  const [page, setPage] = useState<SubscriptionPage>({ accounts: [], next: "" });
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [modelCatalogRevision, setModelCatalogRevision] = useState(0);
  const [fileName, setFileName] = useState("");
  const [error, setError] = useState("");
  const [mode, setMode] = useState<"import" | "oauth" | "delete" | "reset">();
  const [selected, setSelected] = useState<SubscriptionAccount>();
  const [provider, setProvider] = useState<SubscriptionProvider>("codex");
  const [credentials, setCredentials] = useState("");
  const [code, setCode] = useState("");
  const [attempt, setAttempt] = useState<SubscriptionOAuth>();
  const [resetFeedback, setResetFeedback] = useState("");
  const resetKeys = useRef(new Map<string, string>());
  const resetLock = useRef(false);
  const generation = useRef(0);
  // The page starts out empty for this workspace; only a switch to another
  // workspace resets it (a reset on mount re-rendered all of Settings).
  const heldWorkspace = useRef(workspace);
  const nativeAuthorization = useRef<string | undefined>(undefined);
  const oauthGeneration = useRef(0);
  const close = useCallback(() => {
    oauthGeneration.current += 1;
    if (nativeAuthorization.current && productLease) {
      void getNativeBridge()
        .subscriptionAuthorization.cancel({
          session: productLease,
          requestId: nativeAuthorization.current,
        })
        .catch(() => undefined);
      nativeAuthorization.current = undefined;
    }
    setResetFeedback("");
    setMode(undefined);
    setSelected(undefined);
    setCredentials("");
    setFileName("");
    setCode("");
    setAttempt(undefined);
  }, [productLease]);
  const message = useCallback(
    (reason: unknown) =>
      reason instanceof Error && reason.message === "authorization_port_in_use"
        ? m.settings_subscriptions_port_in_use()
        : reason instanceof Error && reason.message === "reset_pending"
          ? m.settings_subscriptions_reset_pending()
          : reason instanceof Error && reason.message === "not_configured"
            ? m.settings_subscriptions_not_configured()
            : reason instanceof Error && reason.message === "conflict"
              ? m.settings_subscriptions_conflict()
              : reason instanceof Error && reason.message === "unavailable"
                ? m.settings_subscriptions_unavailable()
                : m.settings_subscriptions_error(),
    [m]
  );
  useEffect(() => subscribeActiveWorkspace(setWorkspace), []);
  useEffect(() => {
    const current = ++generation.current;
    const controller = new AbortController();
    close();
    // The list belongs to a workspace, not to whether this category is on
    // screen. Dropping it when the tab hides made coming back collapse the card
    // to nothing and grow it again a frame later; it is re-fetched below either
    // way, so the reader sees what they last saw until the answer arrives.
    if (heldWorkspace.current !== workspace) {
      heldWorkspace.current = workspace;
      setPage({ accounts: [], next: "" });
      setLoaded(false);
      setError("");
    }
    setBusy(false);
    if (!enabled) return;
    setBusy(true);
    void (async () => {
      const id =
        workspace ?? (await api.listWorkspaces({ signal: controller.signal }))[0]?.id;
      if (!id) throw new Error("workspace unavailable");
      if (controller.signal.aborted) return;
      if (id !== workspace) {
        setWorkspace(id);
        return;
      }
      const result = await api.listSubscriptionAccounts(id, "", {
        signal: controller.signal,
      });
      if (!controller.signal.aborted) {
        setPage(result);
        setLoaded(true);
      }
    })()
      .catch((reason: unknown) => {
        if (!controller.signal.aborted) setError(message(reason));
      })
      .finally(() => {
        if (current === generation.current) setBusy(false);
      });
    return () => {
      controller.abort();
      generation.current = current + 1;
      oauthGeneration.current += 1;
      if (nativeAuthorization.current && productLease) {
        void getNativeBridge()
          .subscriptionAuthorization.cancel({
            session: productLease,
            requestId: nativeAuthorization.current,
          })
          .catch(() => undefined);
        nativeAuthorization.current = undefined;
      }
    };
  }, [api, enabled, workspace, message, close, productLease]);

  /**
   * `keepError` holds the failure on screen for the length of a retry. Clearing
   * it up front collapses the failure block, the loading state takes its place
   * at a different height, and the failure comes back — two reflows for one
   * press. The error is replaced when the retry actually resolves.
   */
  const run = async (operation: () => Promise<void>, keepError = false) => {
    if (busy || !workspace) return;
    const current = generation.current;
    setBusy(true);
    if (!keepError) setError("");
    try {
      await operation();
      if (current === generation.current) setError("");
    } catch (reason) {
      if (current === generation.current) setError(message(reason));
    } finally {
      if (current === generation.current) setBusy(false);
    }
  };
  const load = useCallback(
    async (after = "") => {
      if (!workspace) return;
      const current = generation.current;
      const result = await api.listSubscriptionAccounts(workspace, after);
      if (current === generation.current) {
        setPage(result);
        setLoaded(true);
      }
    },
    [api, workspace]
  );
  const mutate = (operation: () => Promise<unknown>, affectsModels = true) =>
    run(async () => {
      const current = generation.current;
      await operation();
      if (current !== generation.current) return;
      close();
      if (affectsModels) setModelCatalogRevision((value) => value + 1);
      await load();
    });
  const open = (next: typeof mode, account?: SubscriptionAccount) => {
    close();
    setError("");
    setMode(next);
    setSelected(account);
    setProvider(account?.provider ?? "codex");
  };
  const importCredentials = () => {
    let parsed: unknown;
    try {
      parsed = JSON.parse(credentials);
    } catch {
      setError(m.settings_subscriptions_invalid_json());
      return;
    }
    if (
      !parsed ||
      Array.isArray(parsed) ||
      typeof parsed !== "object" ||
      new TextEncoder().encode(credentials).length > 2_097_152
    ) {
      setError(m.settings_subscriptions_invalid_json());
      return;
    }
    const value = parsed as Record<string, JsonValue>;
    if (workspace)
      void mutate(() =>
        selected
          ? api.updateSubscriptionAccount(workspace, selected.id, {
              version: selected.version,
              credentials: value,
            })
          : api.createSubscriptionAccount(workspace, { provider, credentials: value })
      );
  };
  const providerOptions: SubscriptionProviderOption[] = [
    {
      id: "codex",
      label: "Codex",
      hint: m.settings_subscriptions_provider_hint_codex(),
    },
    {
      id: "claude",
      label: "Claude",
      hint: m.settings_subscriptions_provider_hint_claude(),
    },
  ];
  const rows: SubscriptionAccountRow[] = page.accounts.map((account) => {
    const windows = account.quota?.windows ?? [];
    const window =
      windows.find((value) => value.period === "week") ??
      windows.find((value) => value.period === "month") ??
      windows[0];
    const plan = account.quota?.plan_type?.trim();
    const planName = plan ? plan.charAt(0).toUpperCase() + plan.slice(1) : null;
    const identity = account.email || providerName(account.provider);
    return {
      id: account.id,
      identity,
      plan: planName || m.settings_subscriptions_unknown_plan(),
      provider: providerName(account.provider),
      providerKind: account.provider,
      status:
        !account.disabled && account.status !== "active"
          ? m.settings_subscriptions_needs_reauth()
          : "",
      statusTone: "warning",
      enabled: !account.disabled,
      // Only an enabled account that the runtime cannot use needs repairing;
      // a disabled one is off on purpose.
      repair:
        !account.disabled && account.status !== "active"
          ? {
              label: m.settings_subscriptions_reauth(),
              onPress: () => open("oauth", account),
            }
          : undefined,
      toggleLabel: m.settings_subscriptions_toggle({ account: identity }),
      actionsLabel: m.settings_subscriptions_row_actions({ account: identity }),
      onToggle: () => {
        if (workspace)
          void mutate(() =>
            api.updateSubscriptionAccount(workspace, account.id, {
              version: account.version,
              disabled: !account.disabled,
            })
          );
      },
      quota: window
        ? {
            percent: window.remaining_percent ?? null,
            label:
              window.period === "week" || window.period === "weekly"
                ? m.settings_subscriptions_weekly()
                : window.period === "month"
                  ? m.settings_subscriptions_monthly()
                  : window.period === "short"
                    ? m.settings_subscriptions_short()
                    : window.period,
            detail: window.reset_at
              ? m.settings_subscriptions_reset({ time: shortMoment(window.reset_at) })
              : "",
          }
        : null,
      actions: [
        {
          id: "reauthorize",
          label: m.settings_subscriptions_reauth(),
          onPress: () => open("oauth", account),
        },
        {
          id: "replace",
          label: m.settings_subscriptions_replace(),
          onPress: () => open("import", account),
        },
        {
          id: "quota",
          label: m.settings_subscriptions_quota(),
          onPress: () => {
            if (workspace)
              void mutate(
                () => api.refreshSubscriptionQuota(workspace, account.id),
                false
              );
          },
        },
        ...(account.provider === "codex"
          ? [
              {
                id: "reset" as const,
                label:
                  account.quota?.reset_credits?.available_count == null
                    ? m.settings_subscriptions_reset_menu_unknown()
                    : m.settings_subscriptions_reset_menu({
                        count: account.quota.reset_credits.available_count,
                      }),
                disabled:
                  account.status !== "active" ||
                  (account.reset_attempt?.outcome !== "pending" &&
                    !account.quota?.reset_credits?.available_count),
                onPress: () => open("reset", account),
              },
            ]
          : []),
        {
          id: "delete",
          label: m.settings_subscriptions_delete(),
          destructive: true,
          onPress: () => open("delete", account),
        },
      ],
    };
  });
  const beginAuthorization = () => {
    if (!workspace || busy) return;
    const current = ++oauthGeneration.current;
    void run(async () => {
      const bridge = getNativeBridge();
      if (bridge.platform === "electron") {
        if (!productLease) throw new Error("authorization_unavailable");
        const requestId = crypto.randomUUID();
        nativeAuthorization.current = requestId;
        const result = await bridge.subscriptionAuthorization.start({
          session: productLease,
          requestId,
          workspaceId: workspace,
          provider,
          ...(selected ? { accountId: selected.id, version: selected.version } : {}),
        });
        if (current !== oauthGeneration.current) return;
        if (result.status === "failed") throw new Error(result.error);
        if (result.status === "complete") {
          close();
          setModelCatalogRevision((value) => value + 1);
          await load();
          return;
        }
        setAttempt({
          id: requestId,
          url: "",
          mode: "callback",
          expires_at: new Date(Date.now() + 900_000).toISOString(),
        });
      } else if (provider === "codex") {
        const result = await api.beginSubscriptionOAuth(workspace, {
          provider,
          mode: "device",
          ...(selected ? { account_id: selected.id, version: selected.version } : {}),
        });
        if (current === oauthGeneration.current) setAttempt(result);
      } else {
        await openNativePlatformExternalUrlFromUserAction(async () => {
          const result = await api.beginSubscriptionOAuth(workspace, {
            provider,
            ...(selected ? { account_id: selected.id, version: selected.version } : {}),
          });
          if (current !== oauthGeneration.current)
            throw new Error("Authorization cancelled");
          setAttempt(result);
          return result.url;
        });
      }
    });
  };
  useEffect(() => {
    if (
      !attempt ||
      !workspace ||
      (attempt.mode !== "device" && !nativeAuthorization.current)
    )
      return;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout>;
    const current = oauthGeneration.current;
    const poll = async () => {
      try {
        if (Date.now() >= Date.parse(attempt.expires_at))
          throw new Error("authorization_expired");
        if (nativeAuthorization.current && !productLease)
          throw new Error("authorization_unavailable");
        const result =
          nativeAuthorization.current && productLease
            ? await getNativeBridge().subscriptionAuthorization.status({
                session: productLease,
                requestId: attempt.id,
              })
            : await api.pollSubscriptionOAuth(workspace, attempt.id);
        if (stopped || current !== oauthGeneration.current) return;
        if (result.status === "pending") {
          timer = setTimeout(
            poll,
            "interval" in result ? result.interval * 1000 : 1000
          );
        } else if ("id" in result || result.status === "complete") {
          close();
          setModelCatalogRevision((value) => value + 1);
          await load();
        } else {
          throw new Error("error" in result ? result.error : "authorization_failed");
        }
      } catch (reason) {
        if (!stopped && current === oauthGeneration.current) {
          setAttempt(undefined);
          if (nativeAuthorization.current && productLease) {
            void getNativeBridge()
              .subscriptionAuthorization.cancel({
                session: productLease,
                requestId: nativeAuthorization.current,
              })
              .catch(() => undefined);
            nativeAuthorization.current = undefined;
          }
          setError(message(reason));
        }
      }
    };
    timer = setTimeout(
      poll,
      attempt.mode === "device" ? (attempt.interval ?? 5) * 1000 : 1000
    );
    return () => {
      stopped = true;
      clearTimeout(timer);
    };
  }, [attempt, workspace, api, load, message, close, productLease]);
  const completeAuthorization = () => {
    if (busy || !workspace || !attempt || !code.trim()) return;
    const submittedCode = code;
    const id = attempt.id;
    setCode("");
    setAttempt(undefined);
    void mutate(() => api.completeSubscriptionOAuth(workspace, id, submittedCode));
  };
  const reload = () => {
    if (busy) return;
    setModelCatalogRevision((value) => value + 1);
    void run(() => load(), true);
  };
  const sections: SettingsCategoryDefinition["sections"] = [
    {
      id: "subscriptions.list",
      title: "",
      items: [
        {
          id: "subscriptions.accounts",
          title: m.settings_subscriptions_title(),
          description: m.settings_subscriptions_description(),
          layout: "field",
          control: {
            type: "custom",
            content: (
              <SubscriptionAccounts
                rows={rows}
                busy={busy}
                loaded={loaded}
                error={mode ? "" : error}
                labels={{
                  table: m.settings_subscriptions_title(),
                  identity: m.settings_subscriptions_identity(),
                  remaining: m.settings_subscriptions_remaining(),
                  actions: m.settings_models_manage(),
                  enabled: m.settings_subscriptions_enable(),
                  empty: m.settings_subscriptions_empty(),
                  emptyHint: m.settings_subscriptions_empty_hint(),
                  loading: m.settings_subscriptions_pending(),
                  refresh: m.settings_subscriptions_refresh(),
                  unknownQuota: m.settings_subscriptions_unknown_quota(),
                  import: m.settings_subscriptions_import(),
                  connect: m.settings_subscriptions_connect(),
                  next: m.settings_subscriptions_next(),
                }}
                onImport={() => open("import")}
                onConnect={() => open("oauth")}
                onRefresh={reload}
                onNext={
                  page.next
                    ? () => {
                        void run(() => load(page.next), true);
                      }
                    : undefined
                }
              />
            ),
          },
        },
      ],
    },
  ];
  const pending = busy ? (
    <output className="text-sm text-tertiary">
      {m.settings_subscriptions_pending()}
    </output>
  ) : null;
  const alert = error ? (
    <p role="alert" className="text-pretty text-sm text-error-primary">
      {error}
    </p>
  ) : null;
  const backLabel = m.settings_models_title();
  const identity = selected ? selected.email || providerName(selected.provider) : "";
  const accountRow = identity
    ? [
        {
          id: "subscriptions.detail.account",
          title: identity,
          ...(selected ? { description: providerName(selected.provider) } : {}),
          layout: "field" as const,
        },
      ]
    : [];
  const providerRow = {
    id: "subscriptions.detail.provider",
    title: m.settings_subscriptions_provider(),
    layout: "stack" as const,
    control: {
      type: "custom" as const,
      content: (
        <SubscriptionProviderChoice
          label={m.settings_subscriptions_provider()}
          options={providerOptions}
          value={provider}
          disabled={busy || !!selected}
          onChange={setProvider}
        />
      ),
    },
  };

  const confirmReset = () => {
    if (busy || resetLock.current || !workspace || !selected || resetFeedback) return;
    const current = generation.current;
    const keySlot = `${workspace}:${selected.id}:${selected.version}`;
    const requestId =
      selected.reset_attempt?.outcome === "pending"
        ? selected.reset_attempt.request_id
        : (resetKeys.current.get(keySlot) ?? crypto.randomUUID());
    resetKeys.current.set(keySlot, requestId);
    resetLock.current = true;
    void run(async () => {
      try {
        const result = await api.resetSubscriptionQuota(workspace, selected.id, {
          version: selected.version,
          request_id: requestId,
        });
        if (current !== generation.current) return;
        setSelected(result.account);
        setPage((previous) => ({
          ...previous,
          accounts: previous.accounts.map((account) =>
            account.id === result.account.id ? result.account : account
          ),
        }));
        const outcomes = {
          reset: m.settings_subscriptions_reset_done(),
          already_redeemed: m.settings_subscriptions_reset_redeemed(),
          nothing_to_reset: m.settings_subscriptions_reset_unneeded(),
          no_credit: m.settings_subscriptions_reset_no_credit(),
        };
        setResetFeedback(
          outcomes[result.outcome] +
            (result.quota_refreshed ? "" : ` ${m.settings_subscriptions_reset_stale()}`)
        );
        resetKeys.current.delete(keySlot);
      } catch {
        throw new Error("reset_pending");
      } finally {
        resetLock.current = false;
      }
    });
  };
  const resetDetail: SettingsCategoryDetail | undefined =
    mode === "reset"
      ? {
          id: "subscriptions.reset",
          title: m.settings_subscriptions_reset_action(),
          description: m.settings_subscriptions_reset_hint(),
          backLabel,
          onBack: close,
          actions: (
            <>
              <Button
                hierarchy="secondary-gray"
                size="sm"
                disabled={busy}
                onPress={close}
              >
                {resetFeedback ? m.common_close() : m.settings_models_cancel()}
              </Button>
              <Button
                size="sm"
                disabled={busy || !!resetFeedback}
                onPress={confirmReset}
              >
                {busy
                  ? m.settings_subscriptions_pending()
                  : m.settings_subscriptions_reset_confirm()}
              </Button>
            </>
          ),
          sections: [{ id: "subscriptions.reset.card", title: "", items: accountRow }],
          content: (
            <>
              {alert}
              {pending}
              {resetFeedback ? (
                <output className="text-sm text-secondary">{resetFeedback}</output>
              ) : null}
            </>
          ),
        }
      : undefined;
  const detail: SettingsCategoryDetail | undefined =
    mode === "oauth"
      ? {
          id: attempt ? "subscriptions.oauth.finish" : "subscriptions.oauth.provider",
          title: selected
            ? m.settings_subscriptions_reauth()
            : m.settings_subscriptions_connect(),
          ...(attempt
            ? {}
            : {
                description:
                  getNativeBridge().platform === "electron"
                    ? m.settings_subscriptions_callback_wait()
                    : provider === "codex"
                      ? m.settings_subscriptions_device_hint()
                      : m.settings_subscriptions_authorize_hint(),
              }),
          backLabel,
          onBack: close,
          ...(attempt && (attempt.mode === "device" || nativeAuthorization.current)
            ? {}
            : { onSubmit: attempt ? completeAuthorization : beginAuthorization }),
          // A commit page leaves by the Back control in its header, so the
          // footer carries the commit alone.
          actions:
            attempt &&
            (attempt.mode === "device" || nativeAuthorization.current) ? null : (
              <Button
                size="sm"
                disabled={busy || !workspace || (!!attempt && !code.trim())}
                onPress={attempt ? completeAuthorization : beginAuthorization}
              >
                {busy
                  ? m.settings_subscriptions_pending()
                  : attempt
                    ? m.settings_subscriptions_finish()
                    : m.settings_subscriptions_continue({
                        provider: providerName(provider),
                      })}
              </Button>
            ),
          sections: [
            {
              id: "subscriptions.oauth.card",
              title: "",
              items: [
                ...accountRow,
                attempt
                  ? {
                      id: "subscriptions.oauth.steps",
                      title:
                        attempt.mode === "device"
                          ? m.settings_subscriptions_device_code()
                          : nativeAuthorization.current
                            ? m.settings_subscriptions_pending()
                            : m.settings_subscriptions_code(),
                      layout: "stack" as const,
                      control: {
                        type: "custom" as const,
                        content: nativeAuthorization.current ? (
                          <output>{m.settings_subscriptions_callback_wait()}</output>
                        ) : attempt.mode === "device" ? (
                          <div className="space-y-3">
                            <p>{m.settings_subscriptions_device_hint()}</p>
                            <InputField
                              label={m.settings_subscriptions_device_code()}
                              value={attempt.user_code ?? ""}
                              readOnly
                            />
                            <Button
                              onPress={() => {
                                void openNativePlatformExternalUrl(attempt.url);
                              }}
                            >
                              {m.settings_subscriptions_open()}
                            </Button>
                            <output className="block text-sm text-secondary">
                              {m.settings_subscriptions_pending()}
                            </output>
                            <p>
                              {m.settings_subscriptions_expires({
                                time: shortMoment(attempt.expires_at),
                              })}
                            </p>
                          </div>
                        ) : (
                          <SubscriptionSteps
                            steps={[
                              {
                                text: m.settings_subscriptions_step_browser(),
                                action: (
                                  <Button
                                    hierarchy="secondary-gray"
                                    size="sm"
                                    disabled={busy}
                                    onPress={() => {
                                      void run(() =>
                                        openNativePlatformExternalUrl(attempt.url)
                                      );
                                    }}
                                  >
                                    {m.settings_subscriptions_open()}
                                  </Button>
                                ),
                              },
                              {
                                text: m.settings_subscriptions_step_callback(),
                                action: (
                                  <InputField
                                    className="w-full"
                                    label={m.settings_subscriptions_code()}
                                    autoComplete="off"
                                    type="password"
                                    disabled={busy}
                                    value={code}
                                    onChange={(event) => setCode(event.target.value)}
                                    hint={m.settings_subscriptions_expires({
                                      time: shortMoment(attempt.expires_at),
                                    })}
                                  />
                                ),
                              },
                            ]}
                          />
                        ),
                      },
                    }
                  : providerRow,
              ],
            },
          ],
          content: (
            <>
              {alert}
              {pending}
            </>
          ),
        }
      : mode === "import"
        ? {
            id: "subscriptions.import",
            title: selected
              ? m.settings_subscriptions_replace()
              : m.settings_subscriptions_import(),
            description: m.settings_subscriptions_import_hint(),
            backLabel,
            onBack: close,
            onSubmit: importCredentials,
            actions: (
              <Button
                size="sm"
                disabled={busy || !credentials.trim()}
                onPress={importCredentials}
              >
                {busy
                  ? m.settings_subscriptions_pending()
                  : selected
                    ? m.settings_subscriptions_replace()
                    : m.settings_subscriptions_import()}
              </Button>
            ),
            sections: [
              {
                id: "subscriptions.import.card",
                title: "",
                items: [
                  ...accountRow,
                  ...(selected ? [] : [providerRow]),
                  {
                    id: "subscriptions.import.credential",
                    title: m.settings_subscriptions_credentials(),
                    layout: "stack" as const,
                    control: {
                      type: "custom" as const,
                      content: (
                        <SubscriptionCredentialInput
                          busy={busy}
                          value={credentials}
                          onChange={(value) => {
                            setCredentials(value);
                            setFileName("");
                          }}
                          fileName={fileName}
                          fileLabel={m.settings_subscriptions_file()}
                          fileSource={m.settings_subscriptions_file_source({
                            provider: providerName(selected?.provider ?? provider),
                            path: credentialPaths[selected?.provider ?? provider],
                          })}
                          jsonLabel={m.settings_subscriptions_credentials()}
                          onFile={(file) => {
                            if (file.size > 2_097_152) {
                              setError(m.settings_subscriptions_invalid_json());
                              return;
                            }
                            const current = generation.current;
                            void run(async () => {
                              const text = await file.text();
                              if (current === generation.current) {
                                setCredentials(text);
                                setFileName(file.name);
                              }
                            });
                          }}
                        />
                      ),
                    },
                  },
                ],
              },
            ],
            content: (
              <>
                {alert}
                {pending}
              </>
            ),
          }
        : mode === "delete"
          ? {
              id: "subscriptions.delete",
              title: m.settings_subscriptions_delete(),
              description: m.settings_subscriptions_delete_hint(),
              backLabel,
              onBack: close,
              // The one page that keeps an explicit Cancel: the safe choice
              // belongs beside the destructive one, not only in the corner.
              actions: (
                <>
                  <Button
                    hierarchy="secondary-gray"
                    size="sm"
                    disabled={busy}
                    onPress={close}
                  >
                    {m.settings_models_cancel()}
                  </Button>
                  <Button
                    hierarchy="destructive"
                    size="sm"
                    disabled={busy}
                    onPress={() => {
                      if (workspace && selected)
                        void mutate(() =>
                          api.deleteSubscriptionAccount(
                            workspace,
                            selected.id,
                            selected.version
                          )
                        );
                    }}
                  >
                    {busy
                      ? m.settings_subscriptions_pending()
                      : m.settings_subscriptions_delete()}
                  </Button>
                </>
              ),
              sections: [
                { id: "subscriptions.delete.card", title: "", items: accountRow },
              ],
              content: (
                <>
                  {alert}
                  {pending}
                </>
              ),
            }
          : resetDetail;
  return { sections, detail, modelCatalogRevision };
}
