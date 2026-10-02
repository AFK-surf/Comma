import { Button, Dropdown } from "@comma/ui";
import { useState } from "react";
import {
  subscriptionProviders,
  type BftDiscoveredModels,
  type BftModelTemplate,
  type BftSubscriptionProvider,
  type BftTemplateDraft,
} from "./api";
import { DialogError, writeErrorMessage } from "./dialogs";
import { messages } from "./messages";
import { useApi, useResource } from "./resource";
import {
  FormDialog,
  FormSection,
  TextField,
  Unavailable,
  useConfirm,
  useWrite,
} from "./settingsForm";
import { Skeleton } from "./states";

const t = messages.settings.models.templates;
const providerNames = messages.settings.models.accounts.providers;

// The model a new template, or a template switched to another provider, starts with.
const starterModels: Record<BftSubscriptionProvider, string> = {
  codex: "gpt-5.6-sol",
  claude: "claude-sonnet-4-6",
};

/**
 * The organization's private templates: models served through its own
 * subscriptions. A save or delete changes the model catalog, so `onChanged`
 * reloads the allowed models above.
 */
export function PrivateTemplatesSection({
  org,
  defaultIds,
  onChanged,
}: {
  org: string;
  defaultIds: (string | null)[];
  onChanged: () => void;
}) {
  const api = useApi();
  const [resource, retry] = useResource(`templates:${org}`, (signal) =>
    api.modelTemplates(org, signal)
  );
  const [written, setWritten] = useState<BftModelTemplate[] | null>(null);
  const [editing, setEditing] = useState<BftModelTemplate | "new" | null>(null);
  const confirm = useConfirm();
  const templates = written ?? (resource.state === "ready" ? resource.data : null);
  const apply = (next: BftModelTemplate[]) => {
    setWritten(next);
    onChanged();
  };

  return (
    <FormSection
      action={
        <Button hierarchy="secondary-gray" onPress={() => setEditing("new")} size="xs">
          {t.add}
        </Button>
      }
      description={t.description}
      id="templates"
      title={t.title}
    >
      {resource.state === "error" && !written ? (
        <Unavailable onRetry={retry} />
      ) : templates === null ? (
        <Skeleton height={32} />
      ) : templates.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.empty}</p>
      ) : (
        <ul className="bft-list bft-setting-rows">
          {templates.map((template) => (
            <li className="bft-setting-row" key={template.template_id}>
              <span className="bft-setting-row-main">
                <span className="bft-row-title">
                  <span className="bft-truncate">{template.name}</span>
                  {defaultIds.includes(template.template_id) ? (
                    <span className="bft-tag">{t.default}</span>
                  ) : null}
                </span>
                <span className="bft-setting-row-sub bft-truncate">
                  {[
                    template.model_display_name ?? template.model,
                    t.source(
                      template.subscription_provider &&
                        (providerNames[template.subscription_provider] ?? null)
                    ),
                  ].join(" · ")}
                </span>
              </span>
              {template.subscription_provider ? (
                <>
                  <Button
                    aria-label={t.editFor(template.name)}
                    hierarchy="secondary-gray"
                    onPress={() => setEditing(template)}
                    size="xs"
                  >
                    {messages.settings.edit}
                  </Button>
                  <Button
                    aria-label={t.removeFor(template.name)}
                    hierarchy="tertiary-gray"
                    onPress={() =>
                      confirm.ask({
                        title: t.removeTitle,
                        description: t.removeBody(template.name),
                        confirmLabel: t.removeConfirm,
                        action: () =>
                          api
                            .deleteModelTemplate(org, template.template_id)
                            .then(apply),
                      })
                    }
                    size="xs"
                  >
                    {messages.settings.remove}
                  </Button>
                </>
              ) : null}
            </li>
          ))}
        </ul>
      )}
      {editing ? (
        <TemplateDialog
          discover={(provider) => api.discoverModels(org, provider)}
          onClose={() => setEditing(null)}
          save={(draft) =>
            api
              .saveModelTemplate(
                org,
                editing === "new" ? null : editing.template_id,
                draft
              )
              .then((next) => {
                apply(next);
                setEditing(null);
              })
          }
          template={editing === "new" ? null : editing}
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

function TemplateDialog({
  template,
  discover,
  save,
  onClose,
}: {
  template: BftModelTemplate | null;
  discover: (provider: BftSubscriptionProvider) => Promise<BftDiscoveredModels>;
  save: (draft: BftTemplateDraft) => Promise<void>;
  onClose: () => void;
}) {
  const [name, setName] = useState(template?.name ?? "");
  const [provider, setProvider] = useState<BftSubscriptionProvider>(
    template?.subscription_provider ?? "codex"
  );
  const [model, setModel] = useState(template?.model ?? starterModels.codex);
  const [maxTokens, setMaxTokens] = useState(String(template?.max_tokens ?? 65536));
  const [found, setFound] = useState<BftDiscoveredModels | null>(null);
  const [fetching, setFetching] = useState(false);
  const [fetchError, setFetchError] = useState<string | undefined>();
  const write = useWrite();

  const picked = found?.models.find((option) => option.id === model.trim());
  // The editor keeps a stored display name only while the model stays the same.
  const unchanged =
    template !== null &&
    model.trim() === template.model &&
    provider === template.subscription_provider;
  const display = picked
    ? { name: picked.name, vendor: picked.vendor }
    : unchanged
      ? { name: template.model_display_name, vendor: template.model_vendor }
      : { name: null, vendor: null };

  const fetchModels = () => {
    setFetching(true);
    setFetchError(undefined);
    discover(provider).then(
      (result) => {
        setFound(result);
        setFetching(false);
      },
      (error: unknown) => {
        setFetchError(writeErrorMessage(error));
        setFetching(false);
      }
    );
  };

  const submit = () =>
    write.run(
      () =>
        save({
          name: name.trim(),
          subscription_provider: provider,
          model: model.trim(),
          model_display_name: display.name,
          model_vendor: display.vendor,
          max_tokens: maxTokens.trim(),
        }),
      () => undefined
    );

  return (
    <FormDialog
      description={t.dialogBody}
      onClose={onClose}
      onSubmit={submit}
      submitLabel={t.save}
      title={template ? t.editTitle : t.createTitle}
      write={write}
    >
      <TextField label={t.name} onChange={setName} value={name} />
      <Dropdown
        className="bft-form-field"
        items={subscriptionProviders.map((id) => ({
          id,
          label: providerNames[id] ?? id,
        }))}
        label={t.provider}
        onChange={(value) => {
          const next = value as BftSubscriptionProvider;
          if (next === provider) return;
          setProvider(next);
          setModel(starterModels[next]);
          setFound(null);
        }}
        size="sm"
        value={provider}
      />
      <div className="bft-inline-actions">
        <Button
          disabled={fetching || write.busy}
          hierarchy="secondary-gray"
          onPress={fetchModels}
          size="xs"
        >
          {fetching ? t.fetching : t.fetchModels}
        </Button>
      </div>
      <DialogError message={fetchError} />
      {found ? (
        found.models.length === 0 ? (
          <p className="bft-dialog-note">{t.noMatches}</p>
        ) : (
          <Dropdown
            className="bft-form-field"
            hint={found.truncated ? t.modelsTruncated : t.modelsHint}
            items={found.models.map((option) => ({
              id: option.id,
              label: option.name,
            }))}
            label={t.searchModels}
            onChange={setModel}
            size="sm"
            virtualized
            {...(picked ? { value: picked.id } : {})}
          />
        )
      ) : null}
      <TextField
        label={t.model}
        onChange={setModel}
        value={model}
        {...(display.name ? { hint: t.displayName(display.name) } : {})}
      />
      <TextField label={t.maxTokens} onChange={setMaxTokens} value={maxTokens} />
    </FormDialog>
  );
}
