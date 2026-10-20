import { Button } from "@comma/ui/components/Button";
import { Toggle } from "@comma/ui/components/toggle";
import { useEffect, useState } from "react";
import type {
  BftComposioSection,
  BftOAuthSection,
  BftSettingsIntegrations,
  BftSignalSection,
} from "./api";
import { CodeBlock, CopyButton } from "./dialogs";
import { FeishuSection } from "./FeishuSection";
import { messages } from "./messages";
import { useApi } from "./resource";
import {
  FormDialog,
  FormSection,
  RowState,
  SecretField,
  Step,
  TextField,
  Unavailable,
  useConfirm,
  useWrite,
} from "./settingsForm";

const t = messages.settings.integrations;
const s = messages.settings;

/**
 * One column of sections: what agents work in (OAuth apps, Composio), then
 * where people reach them (Feishu, Signal). Every section is a list of rows
 * that say their state; setup and edits happen in a dialog. Each section has
 * an anchor (`#oauth`, ...) that the retired tab addresses land on, and each
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
    <>
      <OAuthSection initial={data.oauth} org={org} />
      <ComposioSection initial={data.composio} org={org} />
      <FeishuSection initial={data.feishu} org={org} />
      <SignalSection initial={data.signal} org={org} />
    </>
  );
}

type OAuthApp = BftOAuthSection["apps"][number];

/**
 * Whose app a provider runs under. An organization's own app is "configured":
 * its credentials are saved, and only a member's connect proves the provider
 * accepts them.
 */
function oauthState(app: OAuthApp): {
  kind: "platform" | "own" | "none";
  tone?: "ok" | "warn";
  label: string;
  detail?: string;
} {
  if (app.source === "default")
    return {
      kind: "platform",
      tone: "ok",
      label: t.status.ready,
      detail: t.oauth.platformApp,
    };
  if (!app.configured) return { kind: "none", label: t.status.notSetUp };
  const detail = app.client_id ? t.oauth.ownAppId(app.client_id) : t.oauth.ownApp;
  return app.client_secret_configured
    ? { kind: "own", tone: "ok", label: t.status.configured, detail }
    : { kind: "own", tone: "warn", label: t.oauth.secretMissing, detail };
}

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
        {data.apps.map((app) => {
          const state = oauthState(app);
          const [action, actionFor] =
            state.kind === "own"
              ? [s.edit, t.oauth.editFor]
              : state.kind === "platform"
                ? [t.oauth.useOwn, t.oauth.useOwnFor]
                : [t.oauth.setUp, t.oauth.setUpFor];
          return (
            <li className="bft-setting-row" key={app.provider}>
              <span className="bft-setting-row-main">
                <span className="bft-truncate">{app.label}</span>
                <RowState detail={state.detail} label={state.label} tone={state.tone} />
              </span>
              <Button
                aria-label={actionFor(app.label)}
                hierarchy="secondary-gray"
                onPress={() => setEditing(app)}
                size="xs"
              >
                {action}
              </Button>
              {state.kind === "own" ? (
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
          );
        })}
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

/**
 * A first setup walks the order the work happens in: create the app at the
 * provider, paste its credentials, then connect accounts. An edit of the
 * organization's own app is the two fields, with the provider's values folded.
 */
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
  const kind = oauthState(app).kind;
  const setup = app.setup_config;

  const credentials = (
    <>
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
    </>
  );
  const consoleLink = app.setup_href ? (
    <a
      className="bft-link bft-step-link"
      href={app.setup_href}
      rel="noopener noreferrer"
      target="_blank"
    >
      {t.oauth.openConsole(app.label)}
    </a>
  ) : null;
  // X sends the values its creation form asks for; Lark and Feishu only their
  // redirect URL.
  const signIn =
    app.provider === "lark"
      ? { setup: t.oauth.larkSetupNote, after: t.oauth.larkAuthorizationNote }
      : app.provider === "feishu"
        ? { setup: t.oauth.feishuSetupNote, after: t.oauth.feishuAuthorizationNote }
        : null;
  const providerValues = setup ? (
    <>
      <p className="bft-step-body">{signIn ? signIn.setup : t.oauth.xSetupNote}</p>
      {signIn ? null : <p className="bft-step-body">{t.oauth.xAppType}</p>}
      {consoleLink}
      {(
        [
          [t.oauth.appName, setup.app_name],
          [messages.settings.sso.redirectUri, setup.callback_url],
          [t.oauth.websiteUrl, setup.website_url],
        ] as const
      ).map(([label, value]) =>
        value ? (
          <div className="bft-command" key={label}>
            <div className="bft-command-head">
              <span className="bft-command-label">{label}</span>
              <CopyButton label={messages.common.copyLabel(label)} text={value} />
            </div>
            <CodeBlock label={label} text={value} />
          </div>
        ) : null
      )}
    </>
  ) : null;
  const afterSaving = setup
    ? (signIn?.after ?? t.oauth.xAuthorizationNote)
    : t.oauth.connectBody(app.label);

  return (
    <FormDialog
      description={
        kind === "own"
          ? t.oauth.editBody
          : kind === "platform"
            ? t.oauth.platformBody(app.label)
            : t.oauth.setupBody(app.label)
      }
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
      {kind === "own" ? (
        <>
          {credentials}
          {providerValues ? (
            <details className="bft-details">
              <summary>{t.oauth.creationSettings}</summary>
              <div className="bft-details-body">{providerValues}</div>
            </details>
          ) : (
            consoleLink
          )}
          {setup ? <p className="bft-dialog-note bft-muted">{afterSaving}</p> : null}
        </>
      ) : (
        <ol className="bft-steps">
          <Step index={1} title={t.oauth.stepCreate(app.label)}>
            {providerValues ?? (
              <>
                <p className="bft-step-body">{t.oauth.stepCreateBody}</p>
                {consoleLink}
              </>
            )}
          </Step>
          <Step index={2} title={t.oauth.stepPaste}>
            <div className="bft-form bft-step-form">{credentials}</div>
          </Step>
          <Step index={3} title={t.oauth.stepConnect}>
            <p className="bft-step-body">{afterSaving}</p>
          </Step>
        </ol>
      )}
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
  const [editing, setEditing] = useState(false);
  const confirm = useConfirm();
  const platform = data.source === "default";
  const state = data.enabled
    ? {
        tone: "ok" as const,
        label: t.status.on,
        detail: platform ? t.composio.platformKey : t.composio.ownKey,
      }
    : data.api_key_configured
      ? { label: t.status.off, detail: t.composio.savedOff }
      : { label: t.status.notSetUp };

  return (
    <FormSection
      description={t.composio.description}
      id="composio"
      title={t.composio.title}
    >
      {data.status === "unavailable" ? (
        <Unavailable />
      ) : (
        <ul className="bft-list bft-setting-rows">
          <li className="bft-setting-row">
            <span className="bft-setting-row-main">
              <span className="bft-truncate">{t.composio.apiKey}</span>
              <RowState {...state} />
            </span>
            <Button
              aria-label={
                data.api_key_configured ? t.composio.editFor : t.composio.setUpFor
              }
              hierarchy="secondary-gray"
              onPress={() => setEditing(true)}
              size="xs"
            >
              {data.api_key_configured ? s.edit : t.oauth.setUp}
            </Button>
            {data.api_key_configured && !platform ? (
              <Button
                aria-label={t.composio.removeTitle}
                hierarchy="tertiary-gray"
                onPress={() =>
                  confirm.ask({
                    title: t.composio.removeTitle,
                    description: t.composio.removeBody,
                    confirmLabel: s.remove,
                    action: () => api.deleteComposio(org).then(setData),
                  })
                }
                size="xs"
              >
                {s.remove}
              </Button>
            ) : null}
          </li>
        </ul>
      )}
      {editing ? (
        <ComposioDialog
          data={data}
          onClose={() => setEditing(false)}
          save={(body) =>
            api.saveComposio(org, body).then((next) => {
              setData(next);
              setEditing(false);
            })
          }
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

function ComposioDialog({
  data,
  save,
  onClose,
}: {
  data: BftComposioSection;
  save: (body: {
    api_key: string;
    base_url: string;
    enabled: boolean;
  }) => Promise<void>;
  onClose: () => void;
}) {
  // A first setup starts turned on: saving a key is asking to use it.
  const [enabled, setEnabled] = useState(data.enabled || !data.api_key_configured);
  const [apiKey, setApiKey] = useState("");
  const [baseUrl, setBaseUrl] = useState(data.base_url ?? "");
  const write = useWrite();
  return (
    <FormDialog
      description={t.composio.dialogBody}
      onClose={onClose}
      onSubmit={() =>
        write.run(
          () => save({ api_key: apiKey, base_url: baseUrl.trim(), enabled }),
          () => undefined
        )
      }
      title={t.composio.title}
      write={write}
    >
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
      <Toggle
        checked={enabled}
        label={t.composio.enabled}
        onChange={(event) => setEnabled(event.target.checked)}
        size="sm"
      />
    </FormDialog>
  );
}

function SignalSection({ org, initial }: { org: string; initial: BftSignalSection }) {
  const api = useApi();
  const [data, setData] = useState(initial);
  const [editing, setEditing] = useState(false);

  return (
    <FormSection description={t.signal.description} id="signal" title={t.signal.title}>
      {data.status === "unavailable" ? (
        <Unavailable />
      ) : (
        <ul className="bft-list bft-setting-rows">
          <li className="bft-setting-row">
            <span className="bft-setting-row-main">
              <span className="bft-truncate">
                {data.effective_e164 ?? t.signal.number}
              </span>
              {data.effective_e164 ? (
                <RowState
                  detail={data.override_e164 ? t.signal.ownNumber : t.signal.platform}
                  label={t.status.ready}
                  tone="ok"
                />
              ) : (
                <RowState label={t.status.notSetUp} />
              )}
            </span>
            <Button
              aria-label={t.signal.changeFor}
              hierarchy="secondary-gray"
              onPress={() => setEditing(true)}
              size="xs"
            >
              {data.effective_e164 ? t.signal.change : t.oauth.setUp}
            </Button>
          </li>
        </ul>
      )}
      {editing ? (
        <SignalDialog
          data={data}
          onClose={() => setEditing(false)}
          save={(number) =>
            api.saveSignal(org, number).then((next) => {
              setData(next);
              setEditing(false);
            })
          }
        />
      ) : null}
    </FormSection>
  );
}

function SignalDialog({
  data,
  save,
  onClose,
}: {
  data: BftSignalSection;
  save: (number: string) => Promise<void>;
  onClose: () => void;
}) {
  const [number, setNumber] = useState(data.override_e164 ?? "");
  const write = useWrite();
  return (
    <FormDialog
      description={t.signal.dialogBody(data.platform_e164 ?? t.signal.none)}
      onClose={onClose}
      onSubmit={() =>
        write.run(
          () => save(number.trim()),
          () => undefined
        )
      }
      title={t.signal.dialogTitle}
      write={write}
    >
      <TextField
        error={write.fields.number}
        hint={t.signal.numberHint}
        label={t.signal.number}
        onChange={setNumber}
        placeholder={data.platform_e164 ?? "+15551234567"}
        value={number}
      />
    </FormDialog>
  );
}
