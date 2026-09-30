import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import {
  InputField,
  Button,
  SettingsChoiceTable,
  ModelTemplatesTable,
  ModelIcon,
  type ModelTemplateRow,
  type SettingsCategoryDefinition,
  type SettingsCategoryDetail,
  type SettingsPanelItem,
} from "@comma/ui";
import type { CommaApiClient } from "../api";
import type {
  AgentModels,
  DiscoveredModels,
  ModelTemplate,
  ModelTemplateInput,
  SubscriptionModelChoice,
} from "../api/modelTemplates";
import { readActiveWorkspaceId, subscribeActiveWorkspace } from "./activeWorkspace";
import { getNativeBridge } from "@comma/native-bridge";
import { useTokenDanceAuthorization } from "./useTokenDanceAuthorization";

/** Dropdown id for "follow the Comma default"; template ids never take this form. */
const followDefaultId = "__follow_default__";

const modelVendorNames: Record<string, string> = {
  openai: "OpenAI",
  codex: "Codex",
  claude: "Claude",
  anthropic: "Anthropic",
  google: "Google",
  deepseek: "DeepSeek",
  qwen: "Qwen",
  kimi: "Kimi",
  glm: "GLM",
  minimax: "MiniMax",
  mistral: "Mistral",
  meta: "Meta",
  xai: "xAI",
};

const reasoningEffortOrder = [
  "none",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
  "ultra",
];

function modelChoiceLabel(model: AgentModels["available_models"][number]): string {
  const name = model.model_display_name || model.model;
  const effort = model.reasoning_effort?.trim();
  if (!effort) return name;
  const lastWord = name
    .trim()
    .split(/[\s·()]+/)
    .at(-1);
  return lastWord?.toLowerCase() === effort.toLowerCase()
    ? name
    : `${name} · ${effort}`;
}

function modelFamilyLabel(model: AgentModels["available_models"][number]): string {
  const name = model.model_display_name || model.model;
  const effort = model.reasoning_effort?.trim();
  if (!effort) return name;
  const escapedEffort = effort.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const suffix = new RegExp(`(?:\\s*·\\s*|\\s+|\\s*\\()${escapedEffort}\\)?$`, "i");
  return name.replace(suffix, "").trim() || model.model;
}

function groupedModelChoices(
  available: AgentModels["available_models"],
  defaultEffortLabel: string
) {
  type Choice = {
    id: string;
    label: string;
    subtitle?: string;
    reasoningEffort: string | null | undefined;
    familyLabel: string;
    alias: string;
  };
  const vendors = new Map<string, Map<string, Choice[]>>();
  const nameCounts = new Map<string, number>();
  for (const model of available) {
    const key = JSON.stringify([
      model.account_pool ?? model.model_vendor ?? "other",
      modelChoiceLabel(model),
    ]);
    nameCounts.set(key, (nameCounts.get(key) ?? 0) + 1);
  }
  for (const model of available) {
    const vendor = model.account_pool ?? model.model_vendor ?? "other";
    const families = vendors.get(vendor) ?? new Map<string, Choice[]>();
    const label = modelChoiceLabel(model);
    const choice: Choice = {
      id: model.template_id,
      label,
      ...((nameCounts.get(JSON.stringify([vendor, label])) ?? 0) > 1
        ? { subtitle: model.name }
        : {}),
      reasoningEffort: model.reasoning_effort,
      familyLabel: modelFamilyLabel(model),
      alias: model.name,
    };
    families.set(model.model, [...(families.get(model.model) ?? []), choice]);
    vendors.set(vendor, families);
  }
  const effortRank = (effort?: string | null) => {
    if (effort == null) return -1;
    const index = reasoningEffortOrder.indexOf(effort.trim().toLowerCase());
    return index < 0 ? reasoningEffortOrder.length : index;
  };
  return Array.from(vendors, ([id, families]) => ({
    id,
    models: Array.from(families.values()).flatMap((choices) => {
      if (!choices.some((choice) => choice.reasoningEffort?.trim())) {
        return choices.map(
          ({
            reasoningEffort: _effort,
            familyLabel: _familyLabel,
            alias: _alias,
            ...choice
          }) => choice
        );
      }
      const effortLabel = (choice: Pick<Choice, "reasoningEffort">) =>
        choice.reasoningEffort?.trim() || defaultEffortLabel;
      const effortCounts = new Map<string, number>();
      for (const choice of choices) {
        const label = effortLabel(choice);
        effortCounts.set(label, (effortCounts.get(label) ?? 0) + 1);
      }
      return [
        {
          id: choices[0]!.id,
          label: choices[0]!.familyLabel,
          efforts: choices
            .toSorted(
              (a, b) => effortRank(a.reasoningEffort) - effortRank(b.reasoningEffort)
            )
            .map((choice) => ({
              id: choice.id,
              label: effortLabel(choice),
              selectedLabel: choice.label,
              ...((effortCounts.get(effortLabel(choice)) ?? 0) > 1 || choice.subtitle
                ? { subtitle: choice.alias }
                : {}),
            })),
        },
      ];
    }),
  }));
}

const initialDraft: ModelTemplateInput = {
  name: "",
  provider: "openai",
  protocol: "responses",
  model: "",
  base_url: "https://api.openai.com/v1",
  max_tokens: 4096,
  context_tokens: 0,
  supports_images: false,
};

export function useModelTemplatesCategory(
  api: CommaApiClient,
  enabled: boolean,
  subscriptionCatalogRevision: number
) {
  const m = useCommaMessages();
  const generation = useRef(0);
  const [workspaceId, setWorkspaceId] = useState(readActiveWorkspaceId);
  const tokenDance = useTokenDanceAuthorization(workspaceId, enabled);
  const resetTokenDance = tokenDance.reset;
  const [templates, setTemplates] = useState<ModelTemplate[]>([]);
  const [models, setModels] = useState<AgentModels>();
  const [poolCatalog, setPoolCatalog] = useState<SubscriptionModelChoice[]>([]);
  const [poolLoading, setPoolLoading] = useState(false);
  const [poolError, setPoolError] = useState(false);
  const [poolTruncated, setPoolTruncated] = useState(false);
  const [workerCursor, setWorkerCursor] = useState<string>();
  // The lists above start out empty for this workspace; only a switch to
  // another workspace resets them. Resetting on mount would swap in equal
  // empty values and re-render all of Settings as it opens.
  const heldWorkspace = useRef(workspaceId);
  const [busy, setBusy] = useState(false);
  const [reload, setReload] = useState(0);
  const [error, setError] = useState<string>();
  const [draft, setDraft] = useState<ModelTemplateInput>();
  const [editingId, setEditingId] = useState<string>();
  const [discovered, setDiscovered] = useState<DiscoveredModels>();
  const [discoveryError, setDiscoveryError] = useState<string>();
  const [discovering, setDiscovering] = useState(false);
  const [manual, setManual] = useState(false);
  const [advanced, setAdvanced] = useState(false);
  const [protocolOverride, setProtocolOverride] = useState(false);
  const [modelSearch, setModelSearch] = useState("");
  const [deleting, setDeleting] = useState<string>();
  const discoveryRequest = useRef<AbortController | undefined>(undefined);
  const resetDiscovery = useCallback(() => {
    discoveryRequest.current?.abort();
    setDiscovering(false);
    setDiscovered(undefined);
    setDiscoveryError(undefined);
    setModelSearch("");
  }, []);
  const closeEditor = useCallback(() => {
    resetTokenDance();
    resetDiscovery();
    setDraft(undefined);
    setEditingId(undefined);
    setDeleting(undefined);
  }, [resetDiscovery, resetTokenDance]);
  useEffect(() => subscribeActiveWorkspace(setWorkspaceId), []);

  useEffect(() => {
    if (tokenDance.result?.status !== "complete" || !tokenDance.result.models) return;
    const result = tokenDance.result.models;
    setDiscovered(result);
    setManual(false);
    setAdvanced(false);
    setProtocolOverride(true);
    setDraft({ ...initialDraft, base_url: result.base_url, protocol: "responses" });
  }, [tokenDance.result]);

  // Two bounded catalog reads per visit, retry, or account change, independent
  // of Agent count. No polling or discovery on assignment/worker pagination.
  useEffect(() => {
    setPoolCatalog([]);
    setPoolError(false);
    setPoolTruncated(false);
    if (!enabled || !workspaceId) return;
    const controller = new AbortController();
    setPoolLoading(true);
    void Promise.allSettled(
      (["codex", "claude"] as const).map(async (pool) => {
        const result = await api.discoverModels(
          workspaceId,
          { account_pool: pool },
          { signal: controller.signal }
        );
        return {
          truncated: result.truncated,
          choices: result.data.flatMap((model): SubscriptionModelChoice[] => {
            const efforts = model.reasoning_efforts?.length
              ? model.reasoning_efforts
              : [null];
            return efforts.map((effort) => ({
              account_pool: pool,
              model: model.id,
              model_display_name: model.name,
              supports_images: model.supports_images,
              reasoning_effort: effort,
            }));
          }),
        };
      })
    ).then((results) => {
      if (controller.signal.aborted) return;
      setPoolCatalog(
        results.flatMap((result) =>
          result.status === "fulfilled" ? result.value.choices : []
        )
      );
      setPoolTruncated(
        results.some(
          (result) => result.status === "fulfilled" && result.value.truncated
        )
      );
      setPoolError(
        results.some(
          (result) =>
            result.status === "rejected" &&
            !(
              result.reason instanceof Error &&
              result.reason.message === "model_discovery_no_account"
            )
        )
      );
      setPoolLoading(false);
    });
    return () => controller.abort();
  }, [api, enabled, workspaceId, reload, subscriptionCatalogRevision]);

  const menu = useMemo(() => {
    const available = [...(models?.available_models ?? [])];
    const subscriptions = new Map<string, SubscriptionModelChoice>();
    const savedKeys = new Set(
      available
        .filter((model) => model.scope === "tenant" && model.account_pool)
        .map((model) =>
          JSON.stringify([
            model.account_pool,
            model.model,
            model.reasoning_effort ?? null,
          ])
        )
    );
    for (const choice of poolCatalog) {
      const key = JSON.stringify([
        choice.account_pool,
        choice.model,
        choice.reasoning_effort,
      ]);
      if (savedKeys.has(key)) continue;
      savedKeys.add(key);
      const id = `subscription:${key}`;
      subscriptions.set(id, choice);
      available.push({
        ...choice,
        template_id: id,
        name: choice.model_display_name,
        provider: choice.account_pool === "codex" ? "openai" : "anthropic",
        scope: "tenant",
      });
    }
    return { available, subscriptions };
  }, [models, poolCatalog]);

  const menuGroups = useMemo(
    () =>
      [
        { id: "platform", label: m.settings_models_platform_billing() },
        { id: "byok", label: m.settings_models_byok_group() },
      ].flatMap((section) =>
        groupedModelChoices(
          menu.available.filter((model) => {
            const source =
              model.account_pool || model.scope === "tenant" ? "byok" : "platform";
            return source === section.id;
          }),
          m.settings_models_reasoning_default()
        ).map(({ id, models: choices }) => ({
          id: `${section.id}-${id}`,
          vendor: id,
          section: section.label,
          label:
            modelVendorNames[id] ?? (id === "other" ? m.settings_models_other() : id),
          models: choices,
        }))
      ),
    [menu, m]
  );

  const refresh = useCallback(
    async (id: string, signal?: AbortSignal) => {
      const requestedGeneration = generation.current;
      const [nextTemplates, nextModels] = await Promise.all([
        api.listModelTemplates(id, signal ? { signal } : {}),
        api.getAgentModels(id, signal ? { signal } : {}),
      ]);
      if (signal?.aborted || requestedGeneration !== generation.current) return;
      setTemplates(nextTemplates);
      if (workerCursor) {
        const page = await api.getWorkerModels(id, workerCursor);
        if (signal?.aborted || requestedGeneration !== generation.current) return;
        nextModels.workers = page;
      }
      setModels(nextModels);
    },
    [api, workerCursor]
  );

  useEffect(() => {
    generation.current += 1;
    closeEditor();
    // Kept across a tab switch for the same reason as the subscription list:
    // the data is the workspace's, and discarding it makes revisiting the tab
    // collapse the card and grow it back. It is re-fetched below regardless.
    if (heldWorkspace.current !== workspaceId) {
      heldWorkspace.current = workspaceId;
      setModels(undefined);
      setTemplates([]);
      setWorkerCursor(undefined);
    }
    if (!enabled) return;
    const controller = new AbortController();
    setBusy(true);
    // The error is not cleared here: on a retry that would collapse the failure
    // block, let the loading state take its place at a different height, and
    // then bring the failure back — two reflows for one press. It is replaced
    // when this load resolves.
    void (async () => {
      const id =
        workspaceId ?? (await api.listWorkspaces({ signal: controller.signal }))[0]?.id;
      if (!id) throw new Error("workspace unavailable");
      if (controller.signal.aborted) return;
      if (id !== workspaceId) {
        setWorkspaceId(id);
        return;
      }
      await refresh(id, controller.signal);
      if (!controller.signal.aborted) {
        setError(undefined);
      }
    })()
      .catch(() => {
        if (!controller.signal.aborted) setError(m.settings_models_load_error());
      })
      .finally(() => {
        if (!controller.signal.aborted) setBusy(false);
      });
    return () => {
      controller.abort();
      discoveryRequest.current?.abort();
      generation.current += 1;
    };
  }, [api, enabled, workspaceId, refresh, m, reload, closeEditor]);

  const openAdd = useCallback(() => {
    closeEditor();
    setManual(false);
    setAdvanced(false);
    setProtocolOverride(false);
    setDraft({ ...initialDraft });
    setError(undefined);
  }, [closeEditor]);

  const mutate = async (action: () => Promise<unknown>) => {
    if (!workspaceId || busy || discovering) return;
    const currentGeneration = generation.current;
    setBusy(true);
    setError(undefined);
    try {
      await action();
      if (currentGeneration !== generation.current) return;
      closeEditor();
      await refresh(workspaceId);
    } catch (reason) {
      if (currentGeneration !== generation.current) return;
      setError(
        tokenDance.requestId &&
          reason instanceof Error &&
          reason.message === "authorization_unavailable"
          ? m.settings_models_tokendance_expired()
          : reason instanceof Error && "status" in reason && reason.status === 409
            ? m.settings_models_in_use()
            : reason instanceof Error && reason.message === "template_reference_limit"
              ? m.settings_models_reference_limit()
              : reason instanceof Error &&
                  reason.message === "agent_configuration_rollout_pending"
                ? m.settings_models_rollout_pending()
                : m.settings_models_save_error()
      );
    } finally {
      if (currentGeneration === generation.current) setBusy(false);
    }
  };

  const roleLabel = (role: "router" | "worker") =>
    role === "router" ? m.settings_models_router() : m.settings_models_worker();
  const apiKeyTemplates = templates.filter((template) => !template.account_pool);
  const rows: ModelTemplateRow[] = apiKeyTemplates.map((template) => {
    // An agent that follows the Comma default does not hold a model of its own,
    // so only a chosen (pinned) model counts as assigned here.
    const usedBy = [models?.agents.router, ...(models?.workers.items ?? [])].filter(
      (agent) =>
        agent?.source === "pinned" && agent.template_id === template.template_id
    );
    return {
      id: template.template_id,
      name: template.model_display_name || template.model,
      model:
        apiKeyTemplates.filter(
          (entry) =>
            (entry.model_display_name || entry.model) ===
            (template.model_display_name || template.model)
        ).length > 1
          ? `${template.model} · ${template.name}`
          : template.model,
      icon: (
        <ModelIcon
          brand={template.model_icon ?? template.account_pool ?? template.model_vendor}
        />
      ),
      source: m.settings_models_key_source(),
      // Assignment hints cover this bounded page. Deletion checks all references.
      assignedTo: usedBy.length
        ? m.settings_models_assigned({
            roles: usedBy.map((agent) => agent?.name).join(" · "),
          })
        : m.settings_models_unassigned(),
      actionsLabel: m.settings_models_row_actions({ name: template.name }),
      onEdit: () => {
        closeEditor();
        setError(undefined);
        setManual(true);
        setAdvanced(false);
        setProtocolOverride(true);
        setDeleting(undefined);
        setEditingId(template.template_id);
        setDraft({
          name: template.name,
          model: template.model,
          model_display_name: template.model_display_name ?? null,
          model_vendor: template.model_vendor ?? null,
          provider: template.provider,
          protocol: template.protocol,
          base_url: template.base_url,
          max_tokens: template.max_tokens,
          context_tokens: template.context_tokens,
          supports_images: template.supports_images,
          reasoning_effort: template.reasoning_effort ?? null,
        });
      },
      onDelete: () => {
        closeEditor();
        setError(undefined);
        setDeleting(template.template_id);
      },
    };
  });

  const items: SettingsPanelItem[] = [
    ...(poolLoading || poolError || poolTruncated
      ? [
          {
            id: "models.subscription-catalog",
            title: m.settings_models_pool_catalog(),
            description: poolLoading
              ? m.settings_models_fetching()
              : poolError
                ? m.settings_models_pool_catalog_error()
                : m.settings_models_truncated(),
            control: {
              type: "button" as const,
              label: m.settings_models_retry(),
              disabled: poolLoading || busy,
              onPress: () => setReload((value) => value + 1),
            },
          },
        ]
      : []),
    {
      id: "models.templates",
      title: m.settings_models_own(),
      description: m.settings_models_lede(),
      layout: "field",
      control: {
        type: "custom",
        content: (
          <ModelTemplatesTable
            label={m.settings_models_own()}
            error={error ?? ""}
            labels={{
              name: m.settings_models_name(),
              source: m.settings_models_source(),
              actions: m.settings_models_manage(),
              edit: m.settings_models_edit(),
              delete: m.settings_models_delete(),
              add: m.settings_models_add(),
              empty: m.settings_models_templates_empty(),
              emptyHint: m.settings_models_empty_hint(),
              loading: m.settings_models_fetching(),
              retry: m.settings_models_retry(),
            }}
            disabled={busy || discovering}
            loaded={!!models}
            onAdd={() => openAdd()}
            onRetry={() => setReload((value) => value + 1)}
            rows={rows}
          />
        ),
      },
    },
    ...[
      ...(models ? [models.agents.router, ...models.workers.items] : []),
      {
        agent_id: "worker-default",
        role: "worker" as const,
        name: m.settings_models_worker(),
        source: models?.worker_default_template_id
          ? ("pinned" as const)
          : ("platform_default" as const),
        template_id: models?.worker_default_template_id,
      },
    ].map((agent): SettingsPanelItem => {
      if (agent.source === "agent_config" || agent.source === "runtime_default") {
        const provider =
          modelVendorNames[agent.runtime.provider] ?? agent.runtime.provider;
        const model = agent.model?.trim();
        const label = model
          ? [model, agent.reasoning_effort?.trim()].filter(Boolean).join(" · ")
          : m.settings_models_runtime_default({ provider });
        return {
          id: `models.${agent.agent_id}`,
          title: agent.name,
          description: m.settings_models_runtime_managed({ provider }),
          control: {
            type: "custom",
            content: <span>{label}</span>,
          },
        };
      }
      const isDefault = agent.agent_id === "worker-default";
      const title = isDefault
        ? m.settings_models_worker()
        : agent.role === "router"
          ? roleLabel("router")
          : agent.name;
      const platformDefault = models?.platform_defaults[agent.role] ?? null;
      return {
        id: `models.${agent.agent_id}`,
        title,
        description: isDefault
          ? m.settings_models_worker_hint()
          : m.settings_models_activation(),
        control: {
          type: "model-menu",
          placeholder: title,
          disabled: busy || discovering || !models,
          value:
            agent.source === "pinned"
              ? (agent.template_id ?? followDefaultId)
              : followDefaultId,
          items: [
            {
              id: followDefaultId,
              label: platformDefault
                ? m.settings_models_follow_default({
                    name: platformDefault.model_display_name || platformDefault.model,
                  })
                : m.settings_models_follow_default_unset(),
            },
            ...(agent.source === "pinned" &&
            agent.template_id &&
            !models?.available_models.some(
              (model) => model.template_id === agent.template_id
            )
              ? [
                  {
                    id: agent.template_id,
                    disabled: true,
                    label: m.settings_models_current_choice({
                      model: "model" in agent ? agent.model : agent.template_id,
                    }),
                  },
                ]
              : []),
          ],
          groups: menuGroups,
          onChange: (id) => {
            if (workspaceId)
              void mutate(async () => {
                const currentGeneration = generation.current;
                const subscription = menu.subscriptions.get(id);
                const templateId = subscription
                  ? (await api.resolveSubscriptionModel(workspaceId, subscription))
                      .template_id
                  : id === followDefaultId
                    ? null
                    : id;
                if (currentGeneration !== generation.current) return;
                if (isDefault) await api.setWorkerDefault(workspaceId, templateId);
                else await api.setAgentModel(workspaceId, agent.agent_id, templateId);
              });
          },
        },
      };
    }),
    ...(models?.workers.next_cursor
      ? [
          {
            id: "models.workers.next",
            title: m.settings_models_next_workers(),
            control: {
              type: "button" as const,
              label: m.settings_models_next_workers(),
              disabled: busy,
              onPress: () => setWorkerCursor(models.workers.next_cursor ?? undefined),
            },
          },
        ]
      : []),
    ...(workerCursor
      ? [
          {
            id: "models.workers.first",
            title: m.settings_models_first_workers(),
            control: {
              type: "button" as const,
              label: m.settings_models_first_workers(),
              disabled: busy,
              onPress: () => setWorkerCursor(undefined),
            },
          },
        ]
      : []),
  ];

  const stored = templates.find((template) => template.template_id === editingId);
  const hasStoredKey = !!stored?.has_api_key;
  /**
   * The server refuses a PATCH that moves `base_url` without a freshly supplied
   * key, and the key field's own label invites leaving it blank — so without
   * this the only way to change an endpoint is a guaranteed 400.
   */
  const endpointNeedsKey = !!stored && !!draft && draft.base_url !== stored.base_url;
  const fields: SettingsPanelItem[] = [];
  let saveAction:
    | { label: string; disabled?: boolean; onPress?: () => void }
    | undefined;
  if (draft) {
    const tokenDancePending = tokenDance.result?.status === "pending";
    const tokenDanceReady = tokenDance.result?.status === "complete";
    const blocked = busy || discovering || tokenDancePending;
    const ready = manual || !!discovered;
    const inferredProtocol = (() => {
      try {
        const host = new URL(draft.base_url).hostname;
        return host === "api.anthropic.com"
          ? "anthropic"
          : host === "api.openai.com"
            ? "responses"
            : "chat_completions";
      } catch {
        return "chat_completions";
      }
    })();
    const protocol = protocolOverride ? draft.protocol : inferredProtocol;
    const field = (
      key: "name" | "model" | "base_url" | "api_key" | "max_tokens" | "context_tokens",
      label: string,
      type = "text",
      description?: string,
      hintAction?: React.ReactNode
    ) => {
      fields.push({
        id: `models.field.${key}`,
        title: label,
        ...(description ? { description } : {}),
        layout: "field",
        control: {
          type: "custom",
          content: (
            <InputField
              className="w-full"
              fieldSize="sm"
              aria-label={label}
              type={type}
              disabled={blocked}
              readOnly={tokenDanceReady && (key === "base_url" || key === "api_key")}
              hintAction={hintAction}
              autoComplete="off"
              value={
                tokenDanceReady && key === "api_key"
                  ? "••••••••"
                  : String(draft[key] ?? "")
              }
              onChange={(event) => {
                const value = event.target.value;
                if (key === "base_url" || key === "api_key") {
                  tokenDance.reset();
                  resetDiscovery();
                }
                setDraft({
                  ...draft,
                  [key]: type === "number" ? Number(value) : value,
                  // Both fields invalidate discovery, so both must drop the
                  // chosen model — otherwise the picker resets while the draft
                  // still holds a model the reader can no longer see.
                  ...(key === "base_url" || key === "api_key" ? { model: "" } : {}),
                  ...(key === "model" || key === "base_url" || key === "api_key"
                    ? { model_display_name: null, model_vendor: null }
                    : {}),
                });
              }}
            />
          ),
        },
      });
    };
    field("base_url", m.settings_models_endpoint());
    field(
      "api_key",
      hasStoredKey ? m.settings_models_key_replace() : m.settings_models_key(),
      "password",
      tokenDanceReady
        ? m.settings_models_tokendance_key_connected()
        : endpointNeedsKey
          ? m.settings_models_key_needed_for_endpoint()
          : hasStoredKey
            ? m.settings_models_key_keep_hint()
            : m.settings_models_notice(),
      !editingId && !tokenDanceReady && getNativeBridge().platform === "electron" ? (
        <Button
          hierarchy="link-gray"
          size="sm"
          disabled={busy || discovering || !workspaceId}
          onPress={() => {
            if (tokenDancePending) tokenDance.reset();
            else {
              tokenDance.reset();
              resetDiscovery();
              setError(undefined);
              void tokenDance.start();
            }
          }}
        >
          {tokenDancePending
            ? m.settings_models_cancel()
            : m.settings_models_tokendance_connect()}
        </Button>
      ) : undefined
    );
    if (tokenDancePending || tokenDance.result?.status === "failed") {
      // Keep the promotion and authorization status subordinate to the Key field.
      fields[fields.length - 1]!.description = tokenDancePending
        ? m.settings_models_tokendance_pending()
        : tokenDance.result?.status === "failed"
          ? tokenDance.result.error === "authorization_expired"
            ? m.settings_models_tokendance_expired()
            : m.settings_models_tokendance_error()
          : m.settings_models_notice();
    }
    const canUseStoredConnection =
      !!editingId &&
      hasStoredKey &&
      !endpointNeedsKey &&
      draft.protocol === stored?.protocol;
    const getModels = () => {
      if (!workspaceId || (!draft.api_key && !canUseStoredConnection)) return;
      resetDiscovery();
      const controller = new AbortController();
      discoveryRequest.current = controller;
      setDiscovering(true);
      void api
        .discoverModels(
          workspaceId,
          canUseStoredConnection && !draft.api_key?.trim()
            ? { template_id: editingId! }
            : {
                base_url: draft.base_url,
                api_key: draft.api_key!,
                ...(protocolOverride ? { protocol: draft.protocol } : {}),
              },
          { signal: controller.signal }
        )
        .then((result) => {
          if (controller.signal.aborted) return;
          setDiscovered(result);
          setManual(false);
          setDraft({
            ...draft,
            base_url: result.base_url,
            protocol: result.protocol,
            provider: result.provider,
            model: "",
          });
        })
        .catch((reason) => {
          if (controller.signal.aborted) return;
          setDiscoveryError(
            reason instanceof Error && reason.message === "model_discovery_unauthorized"
              ? m.settings_models_fetch_unauthorized()
              : m.settings_models_fetch_error()
          );
        })
        .finally(() => {
          if (!controller.signal.aborted) setDiscovering(false);
        });
    };
    const chooseModel = (id: string) => {
      const model = discovered?.data.find((entry) => entry.id === id);
      if (model) {
        setManual(false);
        setDraft({
          ...draft,
          model: id,
          name: draft.name || model.name,
          model_display_name: model.name,
          model_vendor: model.vendor ?? null,
          supports_images: model.supports_images,
          reasoning_effort: model.default_reasoning_effort ?? null,
        });
      }
    };
    fields.push({
      id: "models.discover",
      title: m.settings_models_table(),
      layout: "field",
      control: {
        type: "custom",
        content: (
          <SettingsChoiceTable
            label={m.settings_models_table()}
            choiceLabel={m.settings_models_model()}
            value={draft.model}
            disabled={blocked}
            searchLabel={m.settings_models_search()}
            search={modelSearch}
            onSearchChange={setModelSearch}
            loading={discovering}
            onChange={chooseModel}
            emptyLabel={
              discovered
                ? modelSearch
                  ? m.settings_models_no_match()
                  : m.settings_models_empty()
                : m.settings_models_table_empty()
            }
            message={
              discoveryError ??
              (discovered?.truncated
                ? m.settings_models_truncated()
                : canUseStoredConnection || tokenDanceReady
                  ? ""
                  : // Get models stays disabled until the endpoint and key
                    // exist; say which, rather than leaving a dead button.
                    !draft.base_url.trim() || !draft.api_key?.trim()
                    ? m.settings_models_fetch_hint()
                    : "")
            }
            action={
              tokenDancePending || tokenDanceReady ? undefined : (
                <Button
                  hierarchy="secondary-gray"
                  size="sm"
                  disabled={
                    blocked ||
                    !draft.base_url.trim() ||
                    (!draft.api_key?.trim() && !canUseStoredConnection)
                  }
                  onPress={getModels}
                >
                  {discovering
                    ? m.settings_models_fetching()
                    : m.settings_models_fetch()}
                </Button>
              )
            }
            secondaryAction={
              tokenDancePending || tokenDanceReady ? undefined : (
                <Button
                  hierarchy="tertiary-gray"
                  size="sm"
                  disabled={blocked}
                  onPress={() => {
                    setManual(true);
                    setDraft({
                      ...draft,
                      protocol,
                      provider: protocol === "anthropic" ? "anthropic" : "openai",
                    });
                  }}
                >
                  {m.settings_models_manual()}
                </Button>
              )
            }
            rows={(discovered?.data ?? []).map((model) => ({
              id: model.id,
              label: model.name,
              ...(model.id !== model.name ? { description: model.id } : {}),
            }))}
          />
        ),
      },
    });
    if (ready) {
      if (manual) field("model", m.settings_models_model());
      if (draft.model) field("name", m.settings_models_name());
    }
    fields.push({
      id: "models.advanced",
      title: m.settings_models_advanced(),
      control: {
        type: "toggle",
        checked: advanced,
        disabled: blocked,
        onChange: (event) => setAdvanced(event.target.checked),
      },
    });
    if (advanced) {
      if (!tokenDancePending && !tokenDanceReady)
        fields.push({
          id: "models.protocol",
          title: m.settings_models_protocol(),
          layout: "field",
          control: {
            type: "dropdown",
            placeholder: m.settings_models_protocol(),
            value: protocolOverride ? draft.protocol : "auto",
            disabled: blocked,
            items: [
              { id: "auto", label: m.settings_models_auto() },
              { id: "responses", label: "OpenAI Responses" },
              { id: "chat_completions", label: "OpenAI Chat Completions" },
              { id: "anthropic", label: "Anthropic Messages" },
            ],
            onChange: (value) => {
              resetDiscovery();
              setProtocolOverride(value !== "auto");
              const nextProtocol =
                value === "responses" ||
                value === "anthropic" ||
                value === "chat_completions"
                  ? value
                  : inferredProtocol;
              setDraft({
                ...draft,
                protocol: nextProtocol,
                provider: nextProtocol === "anthropic" ? "anthropic" : "openai",
              });
            },
          },
        });
      field("max_tokens", m.settings_models_max_tokens(), "number");
      field(
        "context_tokens",
        m.settings_models_context_tokens(),
        "number",
        m.settings_models_context_tokens_hint()
      );
      if (!tokenDancePending && !tokenDanceReady)
        fields.push({
          id: "models.images",
          title: m.settings_models_images(),
          control: {
            type: "toggle",
            checked: draft.supports_images,
            disabled: blocked,
            onChange: (event) =>
              setDraft({ ...draft, supports_images: event.target.checked }),
          },
        });
    }
    saveAction = {
      label: m.settings_models_save(),
      disabled:
        blocked ||
        !ready ||
        !draft.model.trim() ||
        !draft.base_url.trim() ||
        (!tokenDanceReady &&
          (!hasStoredKey || endpointNeedsKey) &&
          !draft.api_key?.trim()),
      onPress: () => {
        if (!workspaceId || saveAction?.disabled) return;
        const input = {
          ...draft,
          name: draft.name.trim() || draft.model,
          protocol,
          provider: protocol === "anthropic" ? "anthropic" : "openai",
        };
        // A blank key on an edit means "keep the stored key".
        if (!input.api_key) delete input.api_key;
        void mutate(() =>
          tokenDanceReady
            ? tokenDance.save({
                model: input.model,
                name: input.name,
                maxTokens: input.max_tokens,
                contextTokens: input.context_tokens ?? 0,
              })
            : editingId
              ? api.updateModelTemplate(workspaceId, editingId, input)
              : api.createModelTemplate(workspaceId, input)
        );
      },
    };
  }

  const deletingTemplate = templates.find(
    (template) => template.template_id === deleting
  );
  const editorOpen = !!draft && enabled && models?.workspace_id === workspaceId;
  const detail: SettingsCategoryDetail | undefined = editorOpen
    ? {
        id: editingId ? `models.edit.${editingId}` : "models.add",
        title: editingId ? m.settings_models_edit() : m.settings_models_add(),
        description:
          tokenDance.result?.status === "complete"
            ? m.settings_models_tokendance_connected()
            : m.settings_models_after_save(),
        backLabel: m.settings_models_title(),
        onBack: closeEditor,
        ...(saveAction?.onPress ? { onSubmit: saveAction.onPress } : {}),
        actions: saveAction ? (
          <Button
            size="sm"
            disabled={saveAction.disabled ?? false}
            onPress={() => saveAction?.onPress?.()}
          >
            {saveAction.label}
          </Button>
        ) : undefined,
        sections: [{ id: "models.editor", title: "", items: fields }],
        ...(error
          ? {
              content: (
                <p role="alert" className="text-pretty text-sm text-error-primary">
                  {error}
                </p>
              ),
            }
          : {}),
      }
    : deletingTemplate
      ? {
          id: `models.delete.${deletingTemplate.template_id}`,
          title: m.settings_models_delete(),
          description: m.settings_models_delete_hint(),
          backLabel: m.settings_models_title(),
          onBack: closeEditor,
          // The safe choice sits beside the destructive one rather than only
          // in the header, so the pointer never has to travel to undo.
          actions: (
            <>
              <Button
                hierarchy="secondary-gray"
                size="sm"
                disabled={busy}
                onPress={closeEditor}
              >
                {m.settings_models_cancel()}
              </Button>
              <Button
                hierarchy="destructive"
                size="sm"
                disabled={busy}
                onPress={() => {
                  if (workspaceId)
                    void mutate(() =>
                      api.deleteModelTemplate(workspaceId, deletingTemplate.template_id)
                    );
                }}
              >
                {m.settings_models_delete()}
              </Button>
            </>
          ),
          sections: [
            {
              id: "models.delete",
              title: "",
              items: [
                {
                  id: "models.delete.target",
                  title: deletingTemplate.name,
                  description: m.settings_models_key_source(),
                  layout: "field",
                },
              ],
            },
          ],
          ...(error
            ? {
                content: (
                  <p role="alert" className="text-pretty text-sm text-error-primary">
                    {error}
                  </p>
                ),
              }
            : {}),
        }
      : undefined;

  const category: SettingsCategoryDefinition = {
    id: "models",
    icon: "models-api-keys",
    label: m.settings_models_title(),
    keywords: ["BYOK", "API Key"],
    sections: [{ id: "models.settings", title: "", items }],
    ...(detail ? { detail } : {}),
  };
  return { category };
}
