import { Button, Toggle } from "@comma/ui";
import { useEffect, useState } from "react";
import type {
  BftComposioSection,
  BftOAuthSection,
  BftSettingsIntegrations,
  BftSignalSection,
} from "./api";
import { FeishuSection } from "./FeishuSection";
import { messages } from "./messages";
import { useApi } from "./resource";
import {
  FormActions,
  FormDialog,
  FormSection,
  SaveButton,
  SecretField,
  TextField,
  Unavailable,
  useConfirm,
  useWrite,
} from "./settingsForm";

const t = messages.settings.integrations;
const s = messages.settings;

/**
 * OAuth apps, Composio, Signal and Feishu on one page. Each section has an
 * anchor (`#oauth`, ...) that the retired tab addresses land on, and each
 * write replaces only its own section.
 */
export function IntegrationsPage({
  org,
  data,
}: {
  org: string;
  data: BftSettingsIntegrations;
}) {
  useEffect(() => {
    const section = window.location.hash.slice(1);
    if (section) document.getElementById(section)?.scrollIntoView({ block: "start" });
  }, []);

  return (
    <div className="bft-settings-grid">
      <div>
        <OAuthSection initial={data.oauth} org={org} />
        <ComposioSection initial={data.composio} org={org} />
        <SignalSection initial={data.signal} org={org} />
      </div>
      <div>
        <FeishuSection initial={data.feishu} org={org} />
      </div>
    </div>
  );
}

type OAuthApp = BftOAuthSection["apps"][number];

function OAuthSection({ org, initial }: { org: string; initial: BftOAuthSection }) {
  const api = useApi();
  const [data, setData] = useState(initial);
  const [editing, setEditing] = useState<OAuthApp | null>(null);
  const confirm = useConfirm();
  const waiting = data.waiting_members;
  const noneConfigured = !data.apps.some((app) => app.configured);

  return (
    <FormSection description={t.oauth.description} id="oauth" title={t.oauth.title}>
      {data.status === "unavailable" ? <Unavailable /> : null}
      {noneConfigured && waiting.names.length > 0 ? (
        <p className="bft-notice">
          {t.oauth.waiting(
            waiting.names.length,
            waiting.names.join(", "),
            waiting.truncated
          )}
        </p>
      ) : null}
      <ul className="bft-list bft-setting-rows">
        {data.apps.map((app) => (
          <li className="bft-setting-row" key={app.provider}>
            <span className="bft-setting-row-main">
              <span className="bft-truncate">{app.label}</span>
              <span
                className="bft-status bft-setting-row-sub"
                data-tone={app.configured ? "ok" : undefined}
              >
                <span className="bft-truncate">
                  {app.source === "default"
                    ? t.oauth.platformDefault
                    : app.client_id
                      ? t.oauth.clientId(app.client_id)
                      : app.configured
                        ? s.configured
                        : s.notConfigured}
                </span>
              </span>
            </span>
            {!app.configured && app.setup_href ? (
              <a
                className="bft-link bft-setting-row-link"
                href={app.setup_href}
                rel="noopener noreferrer"
                target="_blank"
              >
                {t.oauth.createApp}
              </a>
            ) : null}
            <Button
              aria-label={t.oauth.editFor(app.label)}
              hierarchy="secondary-gray"
              onPress={() => setEditing(app)}
              size="xs"
            >
              {app.configured ? s.edit : t.oauth.setUp}
            </Button>
            {app.configured && app.source !== "default" ? (
              <Button
                aria-label={t.oauth.removeFor(app.label)}
                hierarchy="tertiary-gray"
                onPress={() =>
                  confirm.ask({
                    title: t.oauth.removeTitle,
                    description: t.oauth.removeBody(app.label),
                    confirmLabel: s.remove,
                    action: () => api.deleteOAuthApp(org, app.provider).then(setData),
                  })
                }
                size="xs"
              >
                {s.remove}
              </Button>
            ) : null}
          </li>
        ))}
      </ul>
      {editing ? (
        <OAuthDialog
          app={editing}
          onClose={() => setEditing(null)}
          save={(app) =>
            api.saveOAuthApp(org, editing.provider, app).then((next) => {
              setData(next);
              setEditing(null);
            })
          }
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

function OAuthDialog({
  app,
  save,
  onClose,
}: {
  app: OAuthApp;
  save: (app: { client_id: string; client_secret: string }) => Promise<void>;
  onClose: () => void;
}) {
  const [clientId, setClientId] = useState(app.client_id ?? "");
  const [secret, setSecret] = useState("");
  const write = useWrite();
  return (
    <FormDialog
      description={t.oauth.dialogBody}
      onClose={onClose}
      onSubmit={() =>
        write.run(
          () => save({ client_id: clientId.trim(), client_secret: secret }),
          () => undefined
        )
      }
      title={t.oauth.dialogTitle(app.label)}
      write={write}
    >
      <TextField
        error={write.fields.client_id}
        label={messages.settings.sso.clientId}
        onChange={setClientId}
        value={clientId}
      />
      <SecretField
        configured={app.client_secret_configured}
        error={write.fields.client_secret}
        label={messages.settings.sso.clientSecret}
        onChange={setSecret}
        value={secret}
      />
    </FormDialog>
  );
}

function ComposioSection({
  org,
  initial,
}: {
  org: string;
  initial: BftComposioSection;
}) {
  const api = useApi();
  const [data, setData] = useState(initial);
  // A first setup starts enabled, like the retired page.
  const [enabled, setEnabled] = useState(data.enabled || !data.api_key_configured);
  const [apiKey, setApiKey] = useState("");
  const [baseUrl, setBaseUrl] = useState(data.base_url ?? "");
  const write = useWrite();
  const confirm = useConfirm();
  const apply = (next: BftComposioSection) => {
    setData(next);
    setApiKey("");
    setBaseUrl(next.base_url ?? "");
    setEnabled(next.enabled || !next.api_key_configured);
  };

  return (
    <FormSection
      action={
        data.api_key_configured && data.source !== "default" ? (
          <Button
            hierarchy="tertiary-gray"
            onPress={() =>
              confirm.ask({
                title: t.composio.removeTitle,
                description: t.composio.removeBody,
                confirmLabel: s.remove,
                action: () => api.deleteComposio(org).then(apply),
              })
            }
            size="xs"
          >
            {s.remove}
          </Button>
        ) : null
      }
      description={t.composio.description}
      id="composio"
      title={t.composio.title}
    >
      {data.status === "unavailable" ? (
        <Unavailable />
      ) : (
        <>
          <Toggle
            checked={enabled}
            label={t.composio.enabled}
            onChange={(event) => setEnabled(event.target.checked)}
            size="sm"
          />
          <SecretField
            configured={data.api_key_configured}
            error={write.fields.api_key}
            label={t.composio.apiKey}
            onChange={setApiKey}
            value={apiKey}
          />
          <TextField
            error={write.fields.base_url}
            label={t.composio.baseUrl}
            onChange={setBaseUrl}
            placeholder="https://backend.composio.dev"
            value={baseUrl}
          />
          <FormActions write={write}>
            <SaveButton
              busy={write.busy}
              onPress={() =>
                write.run(
                  () =>
                    api.saveComposio(org, {
                      api_key: apiKey,
                      base_url: baseUrl.trim(),
                      enabled,
                    }),
                  apply
                )
              }
            />
          </FormActions>
        </>
      )}
      {confirm.dialog}
    </FormSection>
  );
}

function SignalSection({ org, initial }: { org: string; initial: BftSignalSection }) {
  const api = useApi();
  const [data, setData] = useState(initial);
  const [number, setNumber] = useState(data.override_e164 ?? "");
  const write = useWrite();

  return (
    <FormSection description={t.signal.description} id="signal" title={t.signal.title}>
      {data.status === "unavailable" ? (
        <Unavailable />
      ) : (
        <>
          <dl className="bft-kv">
            <div>
              <dt>{t.signal.inUse}</dt>
              <dd>{data.effective_e164 ?? t.signal.none}</dd>
            </div>
            <div>
              <dt>{t.signal.platform}</dt>
              <dd>{data.platform_e164 ?? t.signal.none}</dd>
            </div>
          </dl>
          <TextField
            error={write.fields.number}
            hint={t.signal.numberHint}
            label={t.signal.number}
            onChange={setNumber}
            placeholder={data.platform_e164 ?? "+15551234567"}
            value={number}
          />
          <FormActions write={write}>
            <SaveButton
              busy={write.busy}
              onPress={() =>
                write.run(
                  () => api.saveSignal(org, number.trim()),
                  (next) => {
                    setData(next);
                    setNumber(next.override_e164 ?? "");
                  }
                )
              }
            />
          </FormActions>
        </>
      )}
    </FormSection>
  );
}
