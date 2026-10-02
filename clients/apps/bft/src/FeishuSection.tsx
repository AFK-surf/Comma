import { Button, Checkbox, Dropdown } from "@comma/ui";
import { useState } from "react";
import type { BftFeishuApp, BftFeishuSection } from "./api";
import { CodeBlock, CopyButton } from "./dialogs";
import { messages } from "./messages";
import { useApi } from "./resource";
import {
  FormDialog,
  FormSection,
  SecretField,
  TextField,
  useConfirm,
  useWrite,
} from "./settingsForm";

const t = messages.settings.integrations.feishu;
const s = messages.settings;

const appName = (app: BftFeishuApp) => app.display_name ?? app.app_id;

/** The Feishu apps, the Agent Swarm routes of each bot app, and the setup aids. */
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
          {data.apps.map((app) => (
            <li key={app.id}>
              <div className="bft-setting-row">
                <span className="bft-setting-row-main">
                  <span className="bft-truncate">{appName(app)}</span>
                  <span className="bft-setting-row-sub bft-truncate">
                    {[
                      app.app_id,
                      app.sso_enabled ? t.sso : null,
                      app.bot_enabled ? t.bot : null,
                      app.app_secret_configured ? null : t.secretMissing,
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </span>
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
              {app.bot_enabled ? (
                <Routes
                  app={app}
                  connect={(projectId) =>
                    api
                      .connectFeishuRoute(org, {
                        app_id: app.app_id,
                        project_id: projectId,
                      })
                      .then(apply)
                  }
                  data={data}
                  disable={(route) =>
                    confirm.ask({
                      title: t.disableTitle,
                      description: t.disableBody(
                        route.project_name ?? route.project_id
                      ),
                      confirmLabel: t.disable,
                      action: () =>
                        api
                          .disableFeishuRoute(org, route.project_id, route.connect_id)
                          .then(apply),
                    })
                  }
                />
              ) : null}
            </li>
          ))}
        </ul>
      )}
      {data.apps_truncated ? (
        <p className="bft-form-section-note">{t.truncated(data.apps.length)}</p>
      ) : null}
      {data.projects_truncated ? (
        <p className="bft-form-section-note">
          {t.projectsTruncated(data.projects.length)}
        </p>
      ) : null}
      <div className="bft-command">
        <div className="bft-command-head">
          <span className="bft-command-label">{t.redirectUri}</span>
          <CopyButton
            label={messages.common.copyLabel(t.redirectUri)}
            text={data.redirect_uri}
          />
        </div>
        <CodeBlock label={t.redirectUri} text={data.redirect_uri} />
        <p className="bft-form-section-note">{t.redirectUriHint}</p>
      </div>
      <Scopes data={data} />
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
        />
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}

type Route = BftFeishuApp["routes"][number];

function Routes({
  app,
  data,
  connect,
  disable,
}: {
  app: BftFeishuApp;
  data: BftFeishuSection;
  connect: (projectId: string) => Promise<unknown>;
  disable: (route: Route) => void;
}) {
  const [project, setProject] = useState<string>();
  const write = useWrite();
  // Salix lets one Feishu app serve one Agent Swarm, and a disabled route
  // still holds the app, so only an app without routes can connect.
  const candidates = app.routes.length === 0 ? data.projects : [];
  const chosen =
    candidates.find((candidate) => candidate.id === project) ?? candidates[0];

  return (
    <div className="bft-routes">
      {data.routes_status === "unavailable" ? (
        // Unknown is not "none": offering a connect here could duplicate a route.
        <p className="bft-quiet bft-quiet-inline">{t.routesUnavailable}</p>
      ) : (
        <>
          {app.routes.length === 0 ? (
            <p className="bft-quiet bft-quiet-inline">{t.routesEmpty}</p>
          ) : (
            app.routes.map((route) => {
              const name = route.project_name ?? route.project_id;
              return (
                <div className="bft-setting-row bft-route" key={route.connect_id}>
                  <span className="bft-setting-row-main">
                    {/* The swarm's integrations page is LiveView: a full page load. */}
                    <a className="bft-link bft-truncate" href={route.href}>
                      {name}
                    </a>
                  </span>
                  <span
                    className="bft-status bft-setting-row-sub"
                    data-tone={route.disabled ? undefined : "ok"}
                  >
                    {route.disabled ? t.routeDisabled : t.routeActive}
                  </span>
                  {route.disabled ? null : (
                    <Button
                      aria-label={t.disableFor(name)}
                      hierarchy="tertiary-gray"
                      onPress={() => disable(route)}
                      size="xs"
                    >
                      {t.disable}
                    </Button>
                  )}
                </div>
              );
            })
          )}
          {data.projects.length === 0 ? (
            <p className="bft-quiet bft-quiet-inline">{t.noProjects}</p>
          ) : candidates.length > 0 ? (
            <div className="bft-route-connect">
              <Dropdown
                ariaLabel={t.connectTo}
                items={candidates.map((candidate) => ({
                  id: candidate.id,
                  label: candidate.name,
                }))}
                onChange={setProject}
                size="xs"
                {...(chosen ? { value: chosen.id } : {})}
              />
              <Button
                disabled={!chosen || write.busy}
                hierarchy="secondary-gray"
                onPress={() => {
                  if (chosen)
                    write.run(
                      () => connect(chosen.id),
                      () => setProject(undefined)
                    );
                }}
                size="xs"
              >
                {write.busy ? messages.common.working : t.connect}
              </Button>
            </div>
          ) : null}
          {write.error ? (
            <p className="bft-dialog-error" role="alert">
              {write.error}
            </p>
          ) : null}
        </>
      )}
    </div>
  );
}

function Scopes({ data }: { data: BftFeishuSection }) {
  if (data.scope_cards.length === 0) return null;
  return (
    <div className="bft-form-field">
      <h3 className="bft-field-label">{t.scopesTitle}</h3>
      <p className="bft-form-section-note">{t.scopesHint}</p>
      <ul className="bft-list bft-setting-rows">
        {data.scope_cards.map((card) => {
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
              <CopyButton label={`${t.copyJson}: ${title}`} text={card.json} />
            </li>
          );
        })}
      </ul>
      {data.optional_scopes.length > 0 ? (
        <>
          <h3 className="bft-field-label">{t.optionalScopes}</h3>
          <ul className="bft-list bft-setting-rows">
            {data.optional_scopes.map((scope) => (
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
        </>
      ) : null}
    </div>
  );
}

function AppDialog({
  app,
  save,
  onClose,
}: {
  app: BftFeishuApp | null;
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

  return (
    <FormDialog
      description={t.dialogBody}
      onClose={onClose}
      onSubmit={submit}
      title={app ? t.editTitle : t.addTitle}
      write={write}
    >
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
      <SecretField
        configured={app?.app_secret_configured ?? false}
        error={write.fields.app_secret}
        label={t.appSecret}
        onChange={(app_secret) => set({ app_secret })}
        value={draft.app_secret}
      />
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
      {draft.bot_enabled ? (
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
      ) : null}
    </FormDialog>
  );
}
