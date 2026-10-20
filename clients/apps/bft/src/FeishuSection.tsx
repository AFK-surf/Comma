import { Button } from "@comma/ui/components/Button";
import { Checkbox } from "@comma/ui/components/checkbox";
import { useState } from "react";
import { type BftFeishuApp, type BftFeishuSection } from "./api";
import { CodeBlock, CopyButton } from "./dialogs";
import { messages } from "./messages";
import { orgHref } from "./navSpec";
import { useApi } from "./resource";
import { spaLinkClick } from "./router";
import {
  FormDialog,
  FormSection,
  RowState,
  SecretField,
  Step,
  TextField,
  useConfirm,
  useWrite,
} from "./settingsForm";

const t = messages.settings.integrations.feishu;
const s = messages.settings;

const appName = (app: BftFeishuApp) => app.display_name ?? app.app_id;

/**
 * The Feishu apps and what each one is used for: dashboard sign-in, and the
 * Agent Swarms its group bot serves. Routes are read here only: each links the
 * Agent Swarm's Connections page, where they are connected, disabled and
 * deleted. The values an admin copies into the Feishu console (redirect URI,
 * permission presets) live in the app dialog, where they are needed.
 */
export function FeishuSection({
  org,
  initial,
}: {
  org: string;
  initial: BftFeishuSection;
}) {
  const api = useApi();
  const [data, setData] = useState(initial);
  const [editing, setEditing] = useState<BftFeishuApp | "new" | null>(null);
  const confirm = useConfirm();
  const apply = (next: BftFeishuSection) => {
    setData(next);
    return next;
  };

  return (
    <FormSection
      action={
        <Button hierarchy="secondary-gray" onPress={() => setEditing("new")} size="xs">
          {t.add}
        </Button>
      }
      description={t.description}
      id="feishu"
      title={t.title}
    >
      {data.apps.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.empty}</p>
      ) : (
        <ul className="bft-list bft-setting-rows">
          {data.apps.map((app) => {
            const identity = t.appIdValue(app.app_id);
            return (
              <li key={app.id}>
                <div className="bft-setting-row">
                  <span className="bft-setting-row-main">
                    <span className="bft-truncate">{appName(app)}</span>
                    {app.app_secret_configured ? (
                      <span className="bft-setting-row-sub bft-truncate">
                        {identity}
                      </span>
                    ) : (
                      <RowState detail={identity} label={t.secretMissing} tone="warn" />
                    )}
                  </span>
                  <Button
                    aria-label={t.editFor(appName(app))}
                    hierarchy="secondary-gray"
                    onPress={() => setEditing(app)}
                    size="xs"
                  >
                    {s.edit}
                  </Button>
                  <Button
                    aria-label={t.removeFor(appName(app))}
                    hierarchy="tertiary-gray"
                    onPress={() =>
                      confirm.ask({
                        title: t.removeTitle,
                        description: t.removeBody(appName(app)),
                        confirmLabel: s.remove,
                        action: () => api.deleteFeishuApp(org, app.id).then(apply),
                      })
                    }
                    size="xs"
                  >
                    {s.remove}
                  </Button>
                </div>
                <dl className="bft-kv bft-kv-wrap bft-app-uses">
                  <div>
                    <dt>{t.sso}</dt>
                    <dd>
                      {app.sso_enabled ? (
                        <span className="bft-app-use">
                          <span className="bft-status" data-tone="ok">
                            {t.useOn}
                          </span>
                          <a
                            className="bft-link"
                            href={orgHref(org, "/settings/sso")}
                            onClick={spaLinkClick}
                          >
                            {t.ssoLink}
                          </a>
                        </span>
                      ) : (
                        <span className="bft-status">{t.useOff}</span>
                      )}
                    </dd>
                  </div>
                  <div>
                    <dt>{t.bot}</dt>
                    <dd>
                      {app.bot_enabled ? (
                        <Routes app={app} status={data.routes_status} />
                      ) : (
                        <span className="bft-status">{t.useOff}</span>
                      )}
                    </dd>
                  </div>
                </dl>
              </li>
            );
          })}
        </ul>
      )}
      {data.apps_truncated ? (
        <p className="bft-form-section-note">{t.truncated(data.apps.length)}</p>
      ) : null}
      {data.projects_truncated ? (
        <p className="bft-form-section-note">
          {t.projectsTruncated(data.projects_shown)}
        </p>
      ) : null}
      {editing ? (
        <AppDialog
          app={editing === "new" ? null : editing}
          onClose={() => setEditing(null)}
          save={(body) =>
            api
              .saveFeishuApp(org, editing === "new" ? null : editing.id, body)
              .then((next) => {
                apply(next);
                setEditing(null);
              })
          }
          section={data}
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

/** The Agent Swarms a bot app serves, each linking its Connections page. */
function Routes({
  app,
  status,
}: {
  app: BftFeishuApp;
  status: BftFeishuSection["routes_status"];
}) {
  // Unknown is not "none": say the lookup failed instead of "not connected".
  if (status === "unavailable") return <span>{t.routesUnavailable}</span>;
  if (app.routes.length === 0) return <span>{t.routesEmpty}</span>;
  return (
    <ul aria-label={t.routesLabel(appName(app))} className="bft-app-routes">
      {app.routes.map((route) => (
        <li className="bft-app-use" key={route.connect_id}>
          <a className="bft-link bft-truncate" href={route.href} onClick={spaLinkClick}>
            {route.project_name ?? route.project_id}
          </a>
          <span className="bft-status" data-tone={route.disabled ? undefined : "ok"}>
            {route.disabled ? t.routeDisabled : t.routeActive}
          </span>
        </li>
      ))}
    </ul>
  );
}

/**
 * What an admin copies into the Feishu developer console: the sign-in redirect
 * URI when the app signs people in, and a permission preset to batch-import.
 */
function ConsoleSetup({ section, sso }: { section: BftFeishuSection; sso: boolean }) {
  return (
    <>
      {sso ? (
        <div className="bft-command">
          <div className="bft-command-head">
            <span className="bft-command-label">{t.redirectUri}</span>
            <CopyButton
              label={messages.common.copyLabel(t.redirectUri)}
              text={section.redirect_uri}
            />
          </div>
          <CodeBlock label={t.redirectUri} text={section.redirect_uri} />
          <p className="bft-form-section-note">{t.redirectUriHint}</p>
        </div>
      ) : null}
      {section.scope_cards.length > 0 ? (
        <div className="bft-form-field">
          <h4 className="bft-field-label">{t.scopesTitle}</h4>
          <p className="bft-form-section-note">{t.scopesHint}</p>
          <ul className="bft-list bft-setting-rows">
            {section.scope_cards.map((card) => {
              const local = t.scopeCards[card.id];
              const title = local?.title ?? card.title;
              return (
                <li className="bft-setting-row" key={card.id}>
                  <span className="bft-setting-row-main">
                    <span className="bft-truncate">{title}</span>
                    <span className="bft-setting-row-sub">
                      {local?.description ?? card.description}
                    </span>
                  </span>
                  <CopyButton label={`${t.copyJson}: ${title}`} text={card.json}>
                    {t.copyJson}
                  </CopyButton>
                </li>
              );
            })}
          </ul>
        </div>
      ) : null}
      {section.optional_scopes.length > 0 ? (
        <div className="bft-form-field">
          <h4 className="bft-field-label">{t.optionalScopes}</h4>
          <ul className="bft-list bft-setting-rows">
            {section.optional_scopes.map((scope) => (
              <li className="bft-setting-row" key={scope.scope}>
                <span className="bft-setting-row-main">
                  <code className="bft-truncate">{scope.scope}</code>
                  <span className="bft-setting-row-sub">
                    {[scope.label, scope.note].filter(Boolean).join(". ")}
                  </span>
                </span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </>
  );
}

/**
 * Adding an app walks the order the work happens in: choose its uses, create
 * it in the Feishu console, copy the console values, paste its credentials.
 * Editing shows the fields, with the console values folded below them.
 */
function AppDialog({
  app,
  section,
  save,
  onClose,
}: {
  app: BftFeishuApp | null;
  section: BftFeishuSection;
  save: (body: Record<string, unknown>) => Promise<void>;
  onClose: () => void;
}) {
  const [draft, setDraft] = useState({
    display_name: app?.display_name ?? "",
    app_id: app?.app_id ?? "",
    app_secret: "",
    verification_token: "",
    encrypt_key: "",
    sso_enabled: app?.sso_enabled ?? false,
    bot_enabled: app?.bot_enabled ?? false,
  });
  const write = useWrite();
  const set = (patch: Partial<typeof draft>) =>
    setDraft((value) => ({ ...value, ...patch }));

  const submit = () => {
    const { app_id, app_secret, verification_token, encrypt_key, ...rest } = draft;
    // Blank secrets keep the stored ones; the App ID of an existing app is fixed.
    const secrets = Object.entries({
      app_secret,
      verification_token,
      encrypt_key,
    }).filter(([, value]) => value !== "");
    const body = {
      ...rest,
      display_name: rest.display_name.trim(),
      ...(app ? {} : { app_id: app_id.trim() }),
      ...Object.fromEntries(secrets),
    };
    write.run(
      () => save(body),
      () => undefined
    );
  };

  const uses = (
    <>
      <Checkbox
        checked={draft.sso_enabled}
        label={t.useSso}
        onChange={(event) => set({ sso_enabled: event.target.checked })}
        size="sm"
      />
      <Checkbox
        checked={draft.bot_enabled}
        label={t.useBot}
        onChange={(event) => set({ bot_enabled: event.target.checked })}
        size="sm"
      />
    </>
  );
  const identity = (
    <>
      <TextField
        error={write.fields.display_name}
        label={t.displayName}
        onChange={(display_name) => set({ display_name })}
        value={draft.display_name}
      />
      <TextField
        disabled={app !== null}
        error={write.fields.app_id}
        label={t.appId}
        onChange={(app_id) => set({ app_id })}
        placeholder="cli_..."
        value={draft.app_id}
        {...(app ? { hint: t.appIdFixed } : {})}
      />
    </>
  );
  const appSecret = (
    <SecretField
      configured={app?.app_secret_configured ?? false}
      error={write.fields.app_secret}
      label={t.appSecret}
      onChange={(app_secret) => set({ app_secret })}
      value={draft.app_secret}
    />
  );
  const botSecrets = draft.bot_enabled ? (
    <>
      <SecretField
        configured={app?.verification_token_configured ?? false}
        error={write.fields.verification_token}
        label={t.verificationToken}
        onChange={(verification_token) => set({ verification_token })}
        value={draft.verification_token}
      />
      <SecretField
        configured={app?.encrypt_key_configured ?? false}
        error={write.fields.encrypt_key}
        label={t.encryptKey}
        onChange={(encrypt_key) => set({ encrypt_key })}
        value={draft.encrypt_key}
      />
    </>
  ) : null;
  const consoleSetup = <ConsoleSetup section={section} sso={draft.sso_enabled} />;

  return (
    <FormDialog
      description={app ? t.editBody : t.addBody}
      onClose={onClose}
      onSubmit={submit}
      title={app ? t.editTitle : t.addTitle}
      wide
      write={write}
    >
      {app ? (
        <>
          {identity}
          {appSecret}
          {uses}
          {botSecrets}
          <details className="bft-details">
            <summary>{t.consoleSettings}</summary>
            <div className="bft-details-body">{consoleSetup}</div>
          </details>
        </>
      ) : (
        <ol className="bft-steps">
          <Step index={1} title={t.stepUses}>
            <div className="bft-checklist">{uses}</div>
          </Step>
          <Step index={2} title={t.stepCreate}>
            <p className="bft-step-body">{t.stepCreateBody}</p>
          </Step>
          <Step index={3} title={t.stepConsole}>
            <div className="bft-form bft-step-form">{consoleSetup}</div>
          </Step>
          <Step index={4} title={t.stepCredentials}>
            <p className="bft-step-body">
              {draft.bot_enabled ? t.stepCredentialsBotBody : t.stepCredentialsBody}
            </p>
            <div className="bft-form bft-step-form">
              {identity}
              {appSecret}
              {botSecrets}
            </div>
          </Step>
          <Step index={5} title={t.stepAfter}>
            {draft.sso_enabled ? <p className="bft-step-body">{t.afterSso}</p> : null}
            {draft.bot_enabled ? <p className="bft-step-body">{t.afterBot}</p> : null}
            {draft.sso_enabled || draft.bot_enabled ? null : (
              <p className="bft-step-body">{t.afterNone}</p>
            )}
          </Step>
        </ol>
      )}
    </FormDialog>
  );
}
