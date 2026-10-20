import { Button } from "@comma/ui/components/Button";
import { Dropdown } from "@comma/ui/components/dropdown";
import { SearchIcon } from "@comma/ui/components/icons";
import { Toggle } from "@comma/ui/components/toggle";
import { useCallback, useEffect, useState } from "react";
import type {
  BftPluginConnection,
  BftPluginDraft,
  BftSwarmPlugin,
  BftSwarmPluginDetail,
  BftSwarmPlugins,
} from "./api";
import {
  ConnectionState,
  connectionKindLabel,
  useConnectionConfirm,
  type ConnectionAction,
} from "./connectionConfirm";
import { writeErrorMessage } from "./dialogs";
import { showFlash } from "./flash";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { PluginEditor, pluginName } from "./PluginsPage";
import { useApi, useLastReady, type Resource } from "./resource";
import { navigate, spaLinkClick } from "./router";
import { FormSection, SettingsPage } from "./settingsForm";
import { StaleNotice } from "./states";

const t = messages.swarmPlugins;

export const pluginSources = ["all", "system", "tenant", "group"] as const;
export const pluginStates = ["all", "enabled", "disabled"] as const;
export type PluginSource = (typeof pluginSources)[number];
export type PluginStateFilter = (typeof pluginStates)[number];

export interface PluginFilter {
  query: string;
  source: PluginSource;
  state: PluginStateFilter;
}

const allPlugins: PluginFilter = { query: "", source: "all", state: "all" };

const isAll = (filter: PluginFilter) =>
  !filter.query.trim() && filter.source === "all" && filter.state === "all";

/** Off and not required: a plugin the swarm can turn on. */
const isOff = (plugin: BftSwarmPlugin) => !plugin.locked && !plugin.enabled;

/**
 * Plugins of the chosen source and state whose name, description, id or
 * capability references contain the query, case-insensitively.
 */
export function filterSwarmPlugins(
  plugins: readonly BftSwarmPlugin[],
  { query, source, state }: PluginFilter
) {
  const needle = query.trim().toLowerCase();
  return plugins.filter(
    (plugin) =>
      (source === "all" || plugin.owner_scope === source) &&
      (state === "all" || (state === "enabled") === !isOff(plugin)) &&
      (!needle ||
        [
          plugin.name,
          plugin.description,
          plugin.plugin_id,
          JSON.stringify(plugin.refs),
        ].some((value) => value?.toLowerCase().includes(needle)))
  );
}

/** The switch label: what pressing it does, or why it cannot be pressed. */
const switchLabel = (plugin: BftSwarmPlugin) =>
  plugin.locked
    ? t.required(pluginName(plugin))
    : plugin.enabled
      ? t.disable(pluginName(plugin))
      : t.enable(pluginName(plugin));

/** A write's notice above the page, which is read again; a refusal the same way. */
function useNotices(path: string, onRetry: () => void) {
  const notify = useCallback(
    (notice: string) => {
      showFlash({ kind: "info", text: notice }, path);
      onRetry();
    },
    [path, onRetry]
  );
  const fail = useCallback(
    (error: unknown) => {
      const text = writeErrorMessage(error);
      if (text) showFlash({ kind: "error", text }, path);
      onRetry();
    },
    [path, onRetry]
  );
  return { notify, fail };
}

/** Turns plugins on and off; each switch stays busy until its own write ends. */
function useEnablement(
  org: string,
  project: string,
  notify: (notice: string) => void,
  fail: (error: unknown) => void
) {
  const api = useApi();
  const [saving, setSaving] = useState<ReadonlySet<string>>(new Set());
  const mark = (id: string, busy: boolean) =>
    setSaving((previous) => {
      const next = new Set(previous);
      if (busy) next.add(id);
      else next.delete(id);
      return next;
    });
  const toggle = (plugin: BftSwarmPlugin, enabled: boolean) => {
    const id = plugin.plugin_id;
    mark(id, true);
    api.setSwarmPluginEnabled(org, project, id, enabled).then(
      ({ notice }) => {
        mark(id, false);
        notify(notice);
      },
      (error: unknown) => {
        mark(id, false);
        fail(error);
      }
    );
  };
  return { saving, toggle };
}

function PluginSwitch({
  plugin,
  busy,
  onToggle,
}: {
  plugin: BftSwarmPlugin;
  busy: boolean;
  onToggle: (plugin: BftSwarmPlugin, enabled: boolean) => void;
}) {
  return (
    <Toggle
      aria-label={switchLabel(plugin)}
      checked={plugin.locked || plugin.enabled}
      disabled={!plugin.toggleable || busy}
      onChange={(event) => onToggle(plugin, event.target.checked)}
      size="sm"
    />
  );
}

/**
 * The products an Agent Swarm can use: search and filter them, turn them on
 * or off, and create or edit the swarm's own plugins. A plugin's name opens
 * its page with its connections.
 */
export function SwarmPluginsPage({
  org,
  project,
  first,
  onRetry,
}: {
  org: string;
  project: string;
  first: Resource<BftSwarmPlugins>;
  onRetry: () => void;
}) {
  const api = useApi();
  const { data, resource, stale } = useLastReady(first);
  const [filter, setFilter] = useState<PluginFilter>(allPlugins);
  const [editing, setEditing] = useState<BftSwarmPlugin | "new" | null>(null);
  const { notify, fail } = useNotices(projectHref(org, project, "/plugins"), onRetry);
  const enablement = useEnablement(org, project, notify, fail);
  const manage = data?.project.role === "admin";
  const plugin = editing === "new" ? undefined : (editing ?? undefined);

  return (
    <>
      <SettingsPage
        actions={
          manage ? (
            <button
              className="bft-btn bft-btn-primary"
              onClick={() => setEditing("new")}
              type="button"
            >
              {t.create}
            </button>
          ) : undefined
        }
        description={data ? t.description(data.project.name) : undefined}
        onRetry={onRetry}
        resource={resource}
        title={t.title}
        wide
      >
        {(page) => (
          <>
            {stale ? <StaleNotice onRetry={onRetry} /> : null}
            <PluginList
              filter={filter}
              onEdit={setEditing}
              onFilter={setFilter}
              onToggle={enablement.toggle}
              org={org}
              page={page}
              project={project}
              saving={enablement.saving}
            />
          </>
        )}
      </SettingsPage>
      {editing ? (
        <PluginEditor
          description={t.editorNote}
          onClose={() => setEditing(null)}
          onSaved={({ notice }) => {
            setEditing(null);
            notify(notice);
          }}
          plugin={plugin}
          save={(draft: BftPluginDraft) =>
            api.saveSwarmPlugin(org, project, plugin?.plugin_id ?? null, draft)
          }
          title={plugin ? t.editTitle(pluginName(plugin)) : t.create}
        />
      ) : null}
    </>
  );
}

function PluginList({
  org,
  project,
  page,
  filter,
  saving,
  onFilter,
  onToggle,
  onEdit,
}: {
  org: string;
  project: string;
  page: BftSwarmPlugins;
  filter: PluginFilter;
  saving: ReadonlySet<string>;
  onFilter: (filter: PluginFilter) => void;
  onToggle: (plugin: BftSwarmPlugin, enabled: boolean) => void;
  onEdit: (plugin: BftSwarmPlugin) => void;
}) {
  const visible = filterSwarmPlugins(page.plugins, filter);
  const enabled = page.plugins.filter((plugin) => !isOff(plugin)).length;

  return (
    <FormSection
      action={
        <div className="bft-panel-tools">
          <label className="bft-filter">
            <SearchIcon className="bft-filter-icon" />
            <input
              aria-label={t.search}
              onChange={(event) => onFilter({ ...filter, query: event.target.value })}
              placeholder={t.search}
              type="search"
              value={filter.query}
            />
          </label>
          <Dropdown
            ariaLabel={t.sourceLabel}
            contentAlign="end"
            items={pluginSources.map((id) => ({ id, label: t.sources[id] }))}
            onChange={(source) =>
              onFilter({ ...filter, source: source as PluginSource })
            }
            size="xs"
            value={filter.source}
            width="content"
          />
          <Dropdown
            ariaLabel={t.stateLabel}
            contentAlign="end"
            items={pluginStates.map((id) => ({ id, label: t.states[id] }))}
            onChange={(state) =>
              onFilter({ ...filter, state: state as PluginStateFilter })
            }
            size="xs"
            value={filter.state}
            width="content"
          />
        </div>
      }
      description={t.counts(enabled, page.plugins.length - enabled)}
      title={t.listTitle}
    >
      {visible.length === 0 ? (
        <div className="bft-quiet-row bft-quiet-row-flush">
          <p className="bft-quiet bft-quiet-inline">
            {isAll(filter) ? t.empty : t.noMatches}
          </p>
          {isAll(filter) ? null : (
            <button
              className="bft-btn bft-btn-sm"
              onClick={() => onFilter(allPlugins)}
              type="button"
            >
              {t.clearFilters}
            </button>
          )}
        </div>
      ) : (
        <ul aria-label={t.listTitle} className="bft-list">
          {visible.map((plugin) => (
            <li className="bft-swarm-plugin" key={plugin.plugin_id}>
              <div className="bft-swarm-plugin-main">
                <a
                  className="bft-swarm-plugin-name"
                  href={projectHref(
                    org,
                    project,
                    `/plugins/${encodeURIComponent(plugin.plugin_id)}`
                  )}
                  onClick={spaLinkClick}
                >
                  {pluginName(plugin)}
                </a>
                <span className="bft-plugin-description">
                  {plugin.description ?? t.noDescription}
                </span>
                {plugin.attention.length > 0 ? (
                  <span className="bft-status" data-tone="warn">
                    <span className="bft-truncate">
                      {t.needsSetup(plugin.attention.join(", "))}
                    </span>
                  </span>
                ) : null}
              </div>
              <span className="bft-swarm-plugin-scope">
                {t.sources[plugin.owner_scope]}
              </span>
              {plugin.editable ? (
                <Button
                  aria-label={t.editTitle(pluginName(plugin))}
                  hierarchy="tertiary-gray"
                  onPress={() => onEdit(plugin)}
                  size="xs"
                >
                  {t.edit}
                </Button>
              ) : null}
              <PluginSwitch
                busy={saving.has(plugin.plugin_id)}
                onToggle={onToggle}
                plugin={plugin}
              />
            </li>
          ))}
        </ul>
      )}
    </FormSection>
  );
}

/** The address a provider returns to after a failed OAuth carries `oauth_error`. */
export const oauthFailed = (search: string) =>
  !!new URLSearchParams(search).get("oauth_error");

/**
 * One plugin of an Agent Swarm: whether the swarm uses it, its MCP servers
 * with the credentials each depends on, and its other credentials. Admins
 * connect, reconnect and disconnect managed-OAuth, MCP and Composio
 * credentials after a confirmation; a messaging credential is set up on the
 * swarm's Connections page.
 */
export function SwarmPluginPage({
  org,
  project,
  pluginId,
  first,
  onRetry,
}: {
  org: string;
  project: string;
  pluginId: string;
  first: Resource<BftSwarmPluginDetail>;
  onRetry: () => void;
}) {
  const api = useApi();
  // Another plugin's page starts empty rather than show this one's data.
  const { data, resource, stale } = useLastReady(first, pluginId);
  const [editing, setEditing] = useState(false);
  const listPath = projectHref(org, project, "/plugins");
  const path = `${listPath}/${encodeURIComponent(pluginId)}`;
  const connectionsHref = projectHref(org, project, "/connections");
  // The shell shows a plugin's page as Plugins, so its notices belong there.
  const { notify, fail } = useNotices(listPath, onRetry);
  const enablement = useEnablement(org, project, notify, fail);
  const connection = useConnectionConfirm(notify);
  const plugin = data?.plugin ?? null;
  const manage = data?.project.role === "admin";

  // The provider sends the browser back here; a failure says so once.
  useEffect(() => {
    if (!oauthFailed(window.location.search)) return;
    showFlash({ kind: "error", text: t.oauthFailed }, listPath);
    navigate(path, { replace: true });
  }, [listPath, path]);

  const ask = (credential: BftPluginConnection, action: ConnectionAction) =>
    connection.ask({
      label: credential.label,
      kind: credential.kind,
      action,
      dependentMcps: credential.dependent_mcps,
      credentialConnected: credential.state === "connected",
      credential:
        action !== "disconnect" && credential.credential_setup
          ? {
              label: credential.credential_setup.label,
              helpUrl: credential.credential_setup.help_url,
            }
          : undefined,
      run: (input) =>
        action === "disconnect"
          ? api.disconnectPlugin(org, project, pluginId, credential.id)
          : api.connectPlugin(
              org,
              project,
              pluginId,
              credential.id,
              credential.credential_setup
                ? { [credential.credential_setup.key]: input }
                : undefined
            ),
    });

  return (
    <>
      <SettingsPage
        actions={
          plugin?.editable ? (
            <button className="bft-btn" onClick={() => setEditing(true)} type="button">
              {t.edit}
            </button>
          ) : undefined
        }
        crumb={
          <a className="bft-link" href={listPath} onClick={spaLinkClick}>
            {t.title}
          </a>
        }
        description={
          data
            ? plugin
              ? (plugin.description ?? t.noDescription)
              : t.notFoundBody
            : undefined
        }
        onRetry={onRetry}
        resource={resource}
        title={plugin ? pluginName(plugin) : data ? t.notFoundTitle : pluginId}
        wide
      >
        {(page) =>
          page.plugin ? (
            <>
              {stale ? <StaleNotice onRetry={onRetry} /> : null}
              <UseSection
                android={page.android}
                busy={enablement.saving.has(page.plugin.plugin_id)}
                onToggle={enablement.toggle}
                org={org}
                plugin={page.plugin}
                project={project}
              />
              {page.plugin.setup && page.plugin.setup.mcps.length > 0 ? (
                <FormSection description={t.mcpNote} title={t.mcpTitle}>
                  <ul className="bft-list">
                    {page.plugin.setup.mcps.map((server) => (
                      <li className="bft-mcp" key={server.alias}>
                        <div className="bft-mcp-head">
                          <span className="bft-mono bft-truncate">{server.alias}</span>
                          {server.placement ? (
                            <span className="bft-muted">{server.placement}</span>
                          ) : null}
                          <ConnectionState state={server.state} />
                        </div>
                        <Credentials
                          connectionsHref={connectionsHref}
                          credentials={server.connections}
                          manage={manage}
                          onAsk={ask}
                        />
                      </li>
                    ))}
                  </ul>
                </FormSection>
              ) : null}
              {page.plugin.setup && page.plugin.setup.connections.length > 0 ? (
                <FormSection description={t.credentialsNote} title={t.credentialsTitle}>
                  <Credentials
                    connectionsHref={connectionsHref}
                    credentials={page.plugin.setup.connections}
                    manage={manage}
                    onAsk={ask}
                  />
                </FormSection>
              ) : null}
            </>
          ) : (
            <p className="bft-quiet bft-quiet-inline">
              <a className="bft-link" href={listPath} onClick={spaLinkClick}>
                {t.backToPlugins}
              </a>
            </p>
          )
        }
      </SettingsPage>
      {connection.dialog}
      {editing && plugin ? (
        <PluginEditor
          description={t.editorNote}
          onClose={() => setEditing(false)}
          onSaved={({ notice }) => {
            setEditing(false);
            notify(notice);
          }}
          plugin={plugin}
          save={(draft: BftPluginDraft) =>
            api.saveSwarmPlugin(org, project, plugin.plugin_id, draft)
          }
          title={t.editTitle(pluginName(plugin))}
        />
      ) : null}
    </>
  );
}

/** Whether the swarm uses the plugin; for Android, the organization's admission too. */
function UseSection({
  org,
  project,
  plugin,
  android,
  busy,
  onToggle,
}: {
  org: string;
  project: string;
  plugin: BftSwarmPlugin;
  android: BftSwarmPluginDetail["android"];
  busy: boolean;
  onToggle: (plugin: BftSwarmPlugin, enabled: boolean) => void;
}) {
  const on = plugin.locked || plugin.enabled;
  return (
    <FormSection
      action={<PluginSwitch busy={busy} onToggle={onToggle} plugin={plugin} />}
      title={t.useTitle}
    >
      <dl className="bft-kv">
        <div>
          <dt>{t.sourceLabel}</dt>
          <dd>{t.sources[plugin.owner_scope]}</dd>
        </div>
        <div>
          <dt>{t.stateLabel}</dt>
          <dd>{plugin.locked ? t.requiredState : on ? t.on : t.off}</dd>
        </div>
        {android ? (
          <div>
            <dt>{t.admission}</dt>
            <dd>
              {android.status === "unavailable"
                ? t.admissionUnavailable
                : android.entitled
                  ? t.admitted
                  : t.notAdmitted}
            </dd>
          </div>
        ) : null}
      </dl>
      {android?.status === "unavailable" ? (
        <p className="bft-dialog-note">{t.androidUnavailable}</p>
      ) : android && !android.entitled ? (
        <p className="bft-dialog-note">{t.androidNotAdmitted}</p>
      ) : null}
      {android && on ? (
        <a
          className="bft-link"
          href={projectHref(org, project, "/devices")}
          onClick={spaLinkClick}
        >
          {t.goToDevices}
        </a>
      ) : null}
    </FormSection>
  );
}

function Credentials({
  credentials,
  connectionsHref,
  manage,
  onAsk,
}: {
  credentials: readonly BftPluginConnection[];
  /** Where a connected Composio account is disconnected. */
  connectionsHref: string;
  manage: boolean;
  onAsk: (credential: BftPluginConnection, action: ConnectionAction) => void;
}) {
  return (
    <ul aria-label={t.credentialsTitle} className="bft-list bft-credentials">
      {credentials.map((credential) => (
        <li className="bft-credential" key={credential.id}>
          <div className="bft-credential-main">
            <span className="bft-cell-main">{credential.label}</span>
            <span className="bft-cell-sub">{connectionKindLabel(credential.kind)}</span>
          </div>
          <ConnectionState state={credential.state} />
          {manage ? (
            <div className="bft-credential-actions">
              {credential.integrations_href ? (
                <a
                  aria-label={`${t.setUpMessaging} ${credential.label}`}
                  className="bft-btn bft-btn-sm"
                  href={credential.integrations_href}
                  onClick={spaLinkClick}
                >
                  {t.setUpMessaging}
                </a>
              ) : null}
              {credential.action ? (
                <button
                  aria-label={`${credential.action === "reconnect" ? t.reconnect : t.connect} ${credential.label}`}
                  className="bft-btn bft-btn-sm"
                  onClick={() => onAsk(credential, credential.action ?? "connect")}
                  type="button"
                >
                  {credential.action === "reconnect" ? t.reconnect : t.connect}
                </button>
              ) : null}
              {credential.disconnectable ? (
                <button
                  aria-label={`${t.disconnect} ${credential.label}`}
                  className="bft-btn bft-btn-sm"
                  onClick={() => onAsk(credential, "disconnect")}
                  type="button"
                >
                  {t.disconnect}
                </button>
              ) : credential.kind === "composio" && credential.state === "connected" ? (
                <a
                  className="bft-link bft-credential-hint"
                  href={`${connectionsHref}#composio`}
                  onClick={spaLinkClick}
                >
                  {t.composioDisconnect}
                </a>
              ) : null}
            </div>
          ) : null}
        </li>
      ))}
    </ul>
  );
}
