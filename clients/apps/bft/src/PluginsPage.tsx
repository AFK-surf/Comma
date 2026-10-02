import { Dialog, Dropdown, ScrollArea, SearchIcon } from "@comma/ui";
import { useState } from "react";
import {
  emptyPluginRefs,
  pluginRefKeys,
  type BftPlugin,
  type BftPluginDraft,
  type BftPluginRef,
  type BftPlugins,
} from "./api";
import { CopyButton } from "./dialogs";
import { messages } from "./messages";
import { orgHref, projectHref, settingsPaths } from "./navSpec";
import { useApi, useResource } from "./resource";
import { spaLinkClick } from "./router";
import {
  FormDialog,
  FormSection,
  SettingsPage,
  TextAreaField,
  TextField,
  useWrite,
} from "./settingsForm";

const t = messages.plugins;

// Dropdown ids cannot be empty; this one stands for "no setup link".
const noDestination = "none";

const pluginName = (plugin: BftPlugin) => plugin.name ?? plugin.plugin_id;

// The details dialog links to at most this many Agent Swarms.
const swarmLinkLimit = 5;

const refText = (ref: BftPluginRef) =>
  typeof ref === "string" ? ref : JSON.stringify(ref);

/** The editor text for references: the inverse of `parseRefLines`. */
export const refLines = (refs: readonly BftPluginRef[]) => refs.map(refText).join("\n");

/** Plugins whose name, description or id contains `query`, case-insensitively. */
export function filterPlugins(plugins: readonly BftPlugin[], query: string) {
  const needle = query.trim().toLowerCase();
  if (!needle) return [...plugins];
  return plugins.filter((plugin) =>
    [plugin.name, plugin.description, plugin.plugin_id].some((value) =>
      value?.toLowerCase().includes(needle)
    )
  );
}

/**
 * One reference per line: an id, or a JSON object for a structured one.
 * Returns `undefined` when a line is neither.
 */
export function parseRefLines(text: string): BftPluginRef[] | undefined {
  const refs: BftPluginRef[] = [];
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    if (!line.startsWith("{")) {
      refs.push(line);
      continue;
    }
    try {
      const parsed: unknown = JSON.parse(line);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
        return undefined;
      refs.push(parsed as Record<string, unknown>);
    } catch {
      return undefined;
    }
  }
  return refs;
}

/** Where an organization-level setup target is configured. */
function setupLink(org: string, target: string) {
  const integrations = orgHref(org, settingsPaths.integrations);
  switch (target) {
    case "org_oauth":
      return { href: `${integrations}#oauth`, label: t.destinations[target] };
    case "org_feishu":
      return { href: `${integrations}#feishu`, label: t.destinations[target] };
    case "org_composio":
      return { href: `${integrations}#composio`, label: t.destinations[target] };
    default:
      // Agent Swarm targets are set up from each swarm's Plugins page.
      return null;
  }
}

type Open =
  | { kind: "details"; plugin: BftPlugin }
  | { kind: "edit"; plugin?: BftPlugin };

type Swarm = { id: string; name: string };

export function PluginsPage({
  org,
  projects,
}: {
  org: string;
  projects: readonly Swarm[];
}) {
  const api = useApi();
  const [resource, retry] = useResource(`plugins:${org}`, (signal) =>
    api.plugins(org, signal)
  );
  // Saved plugins replace their row (or join the list) without a reload.
  const [saved, setSaved] = useState<BftPlugin[]>([]);
  const [filter, setFilter] = useState("");
  const [open, setOpen] = useState<Open | null>(null);
  const canManage = resource.state === "ready" && resource.data.viewer.can_manage;

  const merge = (data: BftPlugins) => {
    const byId = new Map(data.plugins.map((plugin) => [plugin.plugin_id, plugin]));
    for (const plugin of saved) byId.set(plugin.plugin_id, plugin);
    return filterPlugins([...byId.values()], filter);
  };

  return (
    <SettingsPage
      actions={
        resource.state !== "ready" ? null : (
          <>
            <label className="bft-filter">
              <SearchIcon className="bft-filter-icon" />
              <input
                aria-label={t.filter}
                onChange={(event) => setFilter(event.target.value)}
                placeholder={t.filter}
                type="search"
                value={filter}
              />
            </label>
            {canManage ? (
              <button
                className="bft-btn bft-btn-primary"
                onClick={() => setOpen({ kind: "edit" })}
                type="button"
              >
                {t.create}
              </button>
            ) : null}
          </>
        )
      }
      description={t.description}
      onRetry={retry}
      resource={resource}
      title={t.title}
      wide
    >
      {(data) => {
        const plugins = merge(data);
        return (
          <>
            {(["tenant", "system"] as const).map((scope) => (
              <PluginSection
                empty={
                  filter.trim()
                    ? t.noMatches
                    : scope === "tenant"
                      ? t.organizationEmpty
                      : t.systemEmpty
                }
                key={scope}
                onOpen={(plugin) => setOpen({ kind: "details", plugin })}
                plugins={plugins.filter((plugin) => plugin.owner_scope === scope)}
                title={scope === "tenant" ? t.organization : t.system}
              />
            ))}
            {open?.kind === "details" ? (
              <PluginDetails
                canEdit={canManage && open.plugin.editable}
                onClose={() => setOpen(null)}
                onEdit={() => setOpen({ kind: "edit", plugin: open.plugin })}
                org={org}
                plugin={open.plugin}
                projects={projects}
              />
            ) : null}
            {open?.kind === "edit" ? (
              <PluginEditor
                onClose={() => setOpen(null)}
                onSaved={(plugin) => {
                  setSaved((previous) => [
                    ...previous.filter((item) => item.plugin_id !== plugin.plugin_id),
                    plugin,
                  ]);
                  setOpen(null);
                }}
                org={org}
                plugin={open.plugin}
              />
            ) : null}
          </>
        );
      }}
    </SettingsPage>
  );
}

function PluginSection({
  title,
  plugins,
  empty,
  onOpen,
}: {
  title: string;
  plugins: BftPlugin[];
  empty: string;
  onOpen: (plugin: BftPlugin) => void;
}) {
  return (
    <FormSection
      action={<span className="bft-count">{plugins.length}</span>}
      title={title}
    >
      {plugins.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{empty}</p>
      ) : (
        <ul className="bft-list bft-plugins">
          {plugins.map((plugin) => (
            <li key={plugin.plugin_id}>
              <button
                className="bft-plugin-row"
                onClick={() => onOpen(plugin)}
                type="button"
              >
                <span className="bft-plugin-name">{pluginName(plugin)}</span>
                <span className="bft-plugin-description">
                  {plugin.description ?? t.noDescription}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </FormSection>
  );
}

function PluginDetails({
  org,
  plugin,
  projects,
  canEdit,
  onEdit,
  onClose,
}: {
  org: string;
  plugin: BftPlugin;
  projects: readonly Swarm[];
  canEdit: boolean;
  onEdit: () => void;
  onClose: () => void;
}) {
  const groups = pluginRefKeys.filter((key) => plugin.refs[key].length > 0);
  const links = [
    ...new Map(
      plugin.setup_targets.flatMap((target) => {
        const link = setupLink(org, target);
        return link ? [[link.href, link] as const] : [];
      })
    ).values(),
  ];
  const swarmsHref = orgHref(org, "/projects");

  return (
    <Dialog
      actions={[
        { label: t.close, hierarchy: "secondary-gray", onPress: onClose },
        ...(canEdit
          ? [{ label: t.edit, hierarchy: "primary" as const, onPress: onEdit }]
          : []),
      ]}
      className="bft-dialog-wide"
      description={plugin.description ?? t.noDescription}
      isOpen
      onOpenChange={(isOpen) => {
        if (!isOpen) onClose();
      }}
      title={pluginName(plugin)}
    >
      <ScrollArea
        className="bft-dialog-body"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="bft-dialog-scroll"
      >
        <dl className="bft-plugin-facts">
          <dt>{t.pluginId}</dt>
          <dd>
            <code>{plugin.plugin_id}</code>
            <CopyButton
              label={messages.common.copyLabel(t.pluginId)}
              text={plugin.plugin_id}
            />
          </dd>
          <dt>{t.capabilities}</dt>
          <dd>
            {groups.length === 0 ? (
              <span className="bft-muted">{t.noCapabilities}</span>
            ) : (
              groups.map((key) => (
                <div className="bft-plugin-refs" key={key}>
                  <span>{t.refGroups[key]}</span>
                  {plugin.refs[key].map((ref) => (
                    <code key={refText(ref)}>{refText(ref)}</code>
                  ))}
                </div>
              ))
            )}
          </dd>
          {links.length > 0 ? (
            <>
              <dt>{t.setUp}</dt>
              <dd>
                {links.map((link) => (
                  <a
                    className="bft-link"
                    href={link.href}
                    key={link.href}
                    onClick={spaLinkClick}
                  >
                    {link.label}
                  </a>
                ))}
              </dd>
            </>
          ) : null}
          <dt>{t.enableIn}</dt>
          <dd>
            {projects.slice(0, swarmLinkLimit).map((project) => (
              <a
                className="bft-link"
                href={projectHref(org, project.id, "/plugins")}
                key={project.id}
              >
                {project.name}
              </a>
            ))}
            {projects.length === 0 || projects.length > swarmLinkLimit ? (
              <a className="bft-link" href={swarmsHref} onClick={spaLinkClick}>
                {projects.length === 0 ? t.openSwarms : t.allSwarms(projects.length)}
              </a>
            ) : null}
          </dd>
        </dl>
      </ScrollArea>
    </Dialog>
  );
}

function PluginEditor({
  org,
  plugin,
  onSaved,
  onClose,
}: {
  org: string;
  plugin: BftPlugin | undefined;
  onSaved: (plugin: BftPlugin) => void;
  onClose: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [name, setName] = useState(plugin?.name ?? "");
  const [description, setDescription] = useState(plugin?.description ?? "");
  const [destination, setDestination] = useState(
    plugin?.setup_destination ?? noDestination
  );
  const [refs, setRefs] = useState(() =>
    Object.fromEntries(
      pluginRefKeys.map((key) => [key, refLines(plugin?.refs[key] ?? [])])
    )
  );
  // Salix keeps a saved description or setup link when an update leaves it
  // blank, so the editor does not offer to clear them.
  const keepsDestination = Boolean(plugin?.setup_destination);
  const [invalid, setInvalid] = useState<string>();

  const submit = () => {
    if (!name.trim()) {
      setInvalid(t.nameRequired);
      return;
    }
    const draft: BftPluginDraft = {
      name: name.trim(),
      description: description.trim(),
      setup_destination: destination === noDestination ? "" : destination,
      refs: emptyPluginRefs(),
    };
    for (const key of pluginRefKeys) {
      const parsed = parseRefLines(refs[key] ?? "");
      if (!parsed) {
        setInvalid(t.invalidRef(t.refGroups[key]));
        return;
      }
      draft.refs[key] = parsed;
    }
    setInvalid(undefined);
    write.run(() => api.savePlugin(org, plugin?.plugin_id ?? null, draft), onSaved);
  };

  return (
    <FormDialog
      description={t.description}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={submit}
      title={plugin ? t.editTitle(pluginName(plugin)) : t.create}
      wide
      write={invalid ? { ...write, error: invalid } : write}
    >
      <TextField
        disabled={write.busy}
        label={t.nameLabel}
        onChange={setName}
        value={name}
      />
      <TextAreaField
        disabled={write.busy}
        label={t.descriptionLabel}
        onChange={setDescription}
        value={description}
        {...(plugin?.description ? { hint: t.keepsDescription } : {})}
      />
      <Dropdown
        className="bft-form-field"
        disabled={write.busy}
        items={[
          ...(keepsDestination ? [] : [{ id: noDestination, label: t.noDestination }]),
          ...Object.entries(t.destinations).map(([id, label]) => ({ id, label })),
        ]}
        label={t.destinationLabel}
        onChange={setDestination}
        size="sm"
        value={destination}
      />
      {pluginRefKeys.map((key, index) => (
        <TextAreaField
          disabled={write.busy}
          key={key}
          label={t.refGroups[key]}
          mono
          onChange={(value) => setRefs((previous) => ({ ...previous, [key]: value }))}
          value={refs[key] ?? ""}
          {...(index === 0 ? { hint: t.refHint } : {})}
        />
      ))}
    </FormDialog>
  );
}
