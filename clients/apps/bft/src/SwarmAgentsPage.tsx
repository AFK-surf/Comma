import { Button, Dropdown, ScrollArea, ScrollAreaLoadMore, XIcon } from "@comma/ui";
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import {
  BftApiError,
  type BftSwarmAgent,
  type BftSwarmAgentRow,
  type BftSwarmAgents,
} from "./api";
import {
  AgentTargetPicker,
  emptyTarget,
  toTarget,
  type TargetDraft,
} from "./AgentTargetPicker";
import { CopyButton, ConfirmDialog } from "./dialogs";
import { showFlash } from "./flash";
import { formatRelative, humanize } from "./format";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { State } from "./ProjectOverviewPage";
import { useApi, useResource, type Resource } from "./resource";
import { navigate, spaLinkClick } from "./router";
import {
  FieldError,
  FormDialog,
  TextAreaField,
  TextField,
  useConfirm,
  useWrite,
} from "./settingsForm";
import { ErrorState, Skeleton } from "./states";

const t = messages.swarmAgents;
const p = messages.project;

export const agentName = (agent: { name: string | null }) =>
  agent.name ?? p.unnamedAgent;

const roleLabel = (role: string) => p.agentRoles[role] ?? humanize(role);

interface More {
  agents: BftSwarmAgentRow[];
  cursor: string | null | undefined;
  loading: boolean;
  failed: boolean;
}

/**
 * An Agent Swarm's agents in a table, the selected one in a detail rail. The
 * address names the selected agent, so `/agents/:id` deep-links to it. Writes
 * leave a notice and reload the list, keeping the last list while it loads.
 */
export function SwarmAgentsPage({
  org,
  project,
  agentId,
  first,
  onRetry,
}: {
  org: string;
  project: string;
  agentId: string | undefined;
  first: Resource<BftSwarmAgents>;
  onRetry: () => void;
}) {
  const api = useApi();
  const last = useRef<BftSwarmAgents | undefined>(undefined);
  if (first.state === "ready") last.current = first.data;
  const data = first.state === "ready" ? first.data : last.current;
  const [creating, setCreating] = useState(false);
  // Refresh also re-reads the open agent.
  const [railReads, setRailReads] = useState(0);
  // A deep link may name the agent by its Salix id; the rail resolves it.
  const [resolved, setResolved] = useState<{ from: string; id: string }>();
  const selected = resolved && resolved.from === agentId ? resolved.id : agentId;
  const [more, setMore] = useState<More & { from?: BftSwarmAgents }>({
    agents: [],
    cursor: undefined,
    loading: false,
    failed: false,
  });
  // A reloaded first page starts the list over.
  const current: More =
    more.from === data
      ? more
      : { agents: [], cursor: undefined, loading: false, failed: false };
  const loading = useRef<AbortController | null>(null);
  useEffect(() => () => loading.current?.abort(), []);

  const agentsPath = projectHref(org, project, "/agents");
  const notify = useCallback(
    (notice: string) => {
      showFlash({ kind: "info", text: notice }, agentsPath);
      onRetry();
    },
    [agentsPath, onRetry]
  );

  const agents = data ? [...data.agents, ...current.agents] : [];
  const cursor =
    current.cursor === undefined ? (data?.next_cursor ?? null) : current.cursor;
  const loadMore = () => {
    if (!cursor || current.loading || !data) return;
    const controller = new AbortController();
    loading.current = controller;
    const from = data;
    setMore({ ...current, from, loading: true, failed: false });
    api.swarmAgents(org, project, cursor, controller.signal).then(
      (page) => {
        if (controller.signal.aborted) return;
        setMore((previous) => {
          if (previous.from !== from) return previous;
          if (page.status !== "ok")
            return { ...previous, loading: false, failed: true };
          const seen = new Set(
            [...from.agents, ...previous.agents].map((agent) => agent.id)
          );
          return {
            from,
            agents: [...previous.agents, ...page.agents.filter((a) => !seen.has(a.id))],
            cursor: page.next_cursor,
            loading: false,
            failed: false,
          };
        });
      },
      () => {
        if (!controller.signal.aborted)
          setMore((previous) => ({ ...previous, loading: false, failed: true }));
      }
    );
  };

  const manage = data?.project.role === "admin";

  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <h1>{t.title}</h1>
          <p>{data ? t.description(data.project.name) : <Skeleton width={220} />}</p>
        </div>
        <div className="bft-page-actions">
          {manage ? (
            <button
              className="bft-btn bft-btn-primary"
              onClick={() => setCreating(true)}
              type="button"
            >
              {t.newAgent}
            </button>
          ) : null}
        </div>
      </div>
      {first.state === "error" && !data ? (
        <div className="bft-panel bft-panel-fill">
          <ErrorState onRetry={onRetry} />
        </div>
      ) : (
        <div
          className={
            agentId ? "bft-agents-grid" : "bft-agents-grid bft-agents-grid-single"
          }
        >
          <section
            aria-labelledby="bft-agents-list-title"
            className="bft-panel bft-panel-table"
          >
            <div className="bft-panel-header">
              <h2 id="bft-agents-list-title">{t.listTitle}</h2>
              {/* New agents appear once provisioned; this reads the list again. */}
              <Button
                className="bft-panel-link"
                hierarchy="tertiary-gray"
                isDisabled={first.state === "loading"}
                onPress={() => {
                  onRetry();
                  setRailReads((count) => count + 1);
                }}
                size="xs"
              >
                {t.refresh}
              </Button>
            </div>
            {!data ? (
              <div className="bft-rows-skeleton">
                {Array.from({ length: 5 }, (_, index) => (
                  <Skeleton height={14} key={index} />
                ))}
              </div>
            ) : data.status === "unavailable" ? (
              <div className="bft-quiet-row">
                <p className="bft-quiet bft-quiet-inline">{p.agentsUnavailable}</p>
                <button className="bft-btn bft-btn-sm" onClick={onRetry} type="button">
                  {messages.states.retry}
                </button>
              </div>
            ) : (
              <AgentRows
                agents={agents}
                cursor={cursor}
                failed={current.failed}
                href={(id) => `${agentsPath}/${encodeURIComponent(id)}`}
                loading={current.loading}
                onLoadMore={loadMore}
                selected={selected}
                triageHref={data.triage_href}
              />
            )}
          </section>
          {agentId ? (
            <AgentRail
              agentId={agentId}
              agentsPath={agentsPath}
              key={agentId}
              notify={notify}
              onResolved={(id) => setResolved({ from: agentId, id })}
              org={org}
              project={project}
              reads={railReads}
            />
          ) : null}
        </div>
      )}
      {creating ? (
        <NewAgentDialog
          onClose={() => setCreating(false)}
          onCreated={(notice) => {
            setCreating(false);
            notify(notice);
          }}
          org={org}
          project={project}
        />
      ) : null}
    </div>
  );
}

function AgentRows({
  agents,
  selected,
  href,
  triageHref,
  cursor,
  loading,
  failed,
  onLoadMore,
}: {
  agents: BftSwarmAgentRow[];
  selected: string | undefined;
  href: (id: string) => string;
  triageHref: string | null;
  cursor: string | null;
  loading: boolean;
  failed: boolean;
  onLoadMore: () => void;
}) {
  if (agents.length === 0) return <p className="bft-quiet">{t.empty}</p>;
  return (
    <ScrollArea
      className="bft-panel-scroll"
      edgeEffect="none"
      orientation="vertical"
      scrollbarVisibility="hover"
      viewportClassName="bft-scroll-viewport"
    >
      <table className="bft-table">
        <thead>
          <tr>
            <th scope="col">{p.columnName}</th>
            <th className="bft-col-role" scope="col">
              {p.columnRole}
            </th>
            <th className="bft-col-status" scope="col">
              {p.columnStatus}
            </th>
            <th className="bft-col-runtime" scope="col">
              {p.columnRunsOn}
            </th>
          </tr>
        </thead>
        <tbody>
          {agents.map((agent) => (
            <tr data-selected={agent.id === selected ? true : undefined} key={agent.id}>
              <td>
                <span className="bft-title-cell">
                  <a
                    aria-current={agent.id === selected ? "true" : undefined}
                    className="bft-link"
                    href={href(agent.id)}
                    onClick={spaLinkClick}
                    title={agentName(agent)}
                  >
                    {agentName(agent)}
                  </a>
                  {agent.group_router ? (
                    <span className="bft-tag">{t.groupRouter}</span>
                  ) : null}
                  {agent.triage ? (
                    triageHref ? (
                      <a className="bft-tag bft-tag-link" href={triageHref}>
                        {t.usedByTriage}
                      </a>
                    ) : (
                      <span className="bft-tag">{t.usedByTriage}</span>
                    )
                  ) : null}
                </span>
              </td>
              <td className="bft-col-role">{roleLabel(agent.role)}</td>
              <td className="bft-col-status">
                <State value={agent.lifecycle} />
              </td>
              <td className="bft-col-runtime">{p.runtimes[agent.runtime]}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <ScrollAreaLoadMore
        failed={failed}
        hasMore={cursor !== null}
        loading={loading}
        onLoadMore={onLoadMore}
        quiet
      />
      {loading ? (
        <output className="bft-quiet">{t.loadingMore}</output>
      ) : failed ? (
        <div className="bft-quiet-row" role="alert">
          <p className="bft-quiet bft-quiet-inline">{t.loadMoreFailed}</p>
          <button className="bft-btn bft-btn-sm" onClick={onLoadMore} type="button">
            {messages.states.retry}
          </button>
        </div>
      ) : null}
    </ScrollArea>
  );
}

type RailDialog = "configure" | "rebind" | "archive" | null;

/** One agent's facts, its Router session and the admin actions. */
function AgentRail({
  org,
  project,
  agentId,
  agentsPath,
  notify,
  onResolved,
  reads,
}: {
  org: string;
  project: string;
  agentId: string;
  agentsPath: string;
  notify: (notice: string) => void;
  onResolved: (id: string) => void;
  reads: number;
}) {
  const api = useApi();
  const [loaded, reload] = useResource(
    `swarm-agent:${org}:${project}:${agentId}`,
    (signal) => api.swarmAgent(org, project, agentId, signal)
  );
  const [latest, setLatest] = useState<BftSwarmAgent>();
  const data = latest ?? (loaded.state === "ready" ? loaded.data : undefined);
  const [dialog, setDialog] = useState<RailDialog>(null);
  const [notice, setNotice] = useState<string>();
  const confirm = useConfirm();
  // Best effort: after a refused write the refusal stays the message shown.
  const refresh = () =>
    api.swarmAgent(org, project, agentId).then(setLatest, () => undefined);
  const resolvedId = data?.agent.id;
  useEffect(() => {
    if (resolvedId) onResolved(resolvedId);
    // `onResolved` is a fresh closure each render; the id is what matters.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [resolvedId]);
  const seenReads = useRef(reads);
  useEffect(() => {
    if (seenReads.current === reads) return;
    seenReads.current = reads;
    if (data) void refresh();
    else reload();
    // Runs only when the list's Refresh is pressed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reads]);
  const close = (
    <Button
      aria-label={t.close}
      className="bft-panel-link"
      hierarchy="tertiary-gray"
      iconLeading={<XIcon />}
      iconOnly
      onPress={() => navigate(agentsPath)}
      size="xs"
    />
  );

  if (!data) {
    const missing =
      loaded.state === "error" &&
      loaded.error instanceof BftApiError &&
      loaded.error.code === "agent_not_found";
    return (
      <aside aria-label={t.detailLabel} className="bft-panel bft-agent-rail">
        <div className="bft-panel-header">
          <h2>{t.detailLabel}</h2>
          {close}
        </div>
        {missing ? (
          <p className="bft-quiet">{t.notFound}</p>
        ) : loaded.state === "error" ? (
          <ErrorState onRetry={reload} />
        ) : (
          <div className="bft-rows-skeleton">
            <Skeleton height={14} />
            <Skeleton height={14} width="70%" />
            <Skeleton height={14} width="80%" />
          </div>
        )}
      </aside>
    );
  }

  const { agent, router_session: session } = data;
  const manage = data.project.role === "admin";
  const archived = agent.lifecycle === "archived";
  const name = agentName(agent);
  const openArchive = () => {
    setNotice(undefined);
    // The Triage assignment is read again, as the confirmation shows it.
    api.swarmAgent(org, project, agentId).then(
      (fresh) => {
        setLatest(fresh);
        if (fresh.triage.status === "ok") setDialog("archive");
        else setNotice(t.triageUnknown);
      },
      () => setNotice(t.triageUnknown)
    );
  };
  const rows: [string, ReactNode, (string | undefined)?][] = [
    [t.detailRole, roleLabel(agent.role)],
    [t.detailStatus, <State key="status" value={agent.lifecycle} />],
    [t.detailRunsOn, agent.binding?.summary ?? p.runtimes[agent.runtime]],
    [t.detailModel, agent.model ?? t.modelDefault],
    [
      t.detailCreated,
      (agent.created_at && formatRelative(agent.created_at)) || "—",
      agent.created_at ?? undefined,
    ],
  ];

  return (
    <aside aria-labelledby="bft-agent-rail-title" className="bft-panel bft-agent-rail">
      <div className="bft-panel-header">
        <h2 id="bft-agent-rail-title" title={name}>
          {name}
        </h2>
        {close}
      </div>
      <ScrollArea
        className="bft-panel-scroll"
        edgeEffect="none"
        orientation="vertical"
        scrollbarVisibility="hover"
        viewportClassName="bft-scroll-viewport"
      >
        <div className="bft-rail-body">
          <dl className="bft-kv">
            {rows.map(([label, value, title]) => (
              <div key={label}>
                <dt>{label}</dt>
                <dd title={title ?? (typeof value === "string" ? value : undefined)}>
                  {value}
                </dd>
              </div>
            ))}
          </dl>
          {notice ? (
            <p className="bft-dialog-error" role="alert">
              {notice}
            </p>
          ) : null}
          {manage && !archived ? (
            <div className="bft-rail-actions">
              <Button
                hierarchy="secondary-gray"
                onPress={() => setDialog("configure")}
                size="xs"
              >
                {t.configure}
              </Button>
              {agent.rebindable && agent.binding ? (
                <Button
                  hierarchy="secondary-gray"
                  onPress={() => setDialog("rebind")}
                  size="xs"
                >
                  {t.rebind}
                </Button>
              ) : null}
              {agent.role === "router" ? null : (
                <Button hierarchy="secondary-gray" onPress={openArchive} size="xs">
                  {t.archive}
                </Button>
              )}
            </div>
          ) : null}
          {agent.runtime_id ? (
            <div className="bft-rail-section">
              <h3>{t.detailRuntimeId}</h3>
              <p className="bft-mono bft-break">{agent.runtime_id}</p>
              <CopyButton
                label={messages.common.copyLabel(t.detailRuntimeId)}
                text={agent.runtime_id}
              />
            </div>
          ) : null}
          <div className="bft-rail-section">
            <h3>{t.detailPrompt}</h3>
            <p
              className={
                agent.system_prompt ? "bft-prompt" : "bft-quiet-inline bft-muted"
              }
            >
              {agent.system_prompt ?? t.noPrompt}
            </p>
          </div>
          {agent.triage ? (
            <div className="bft-rail-section">
              <h3>{t.usedByTriage}</h3>
              <p className="bft-dialog-note">{t.triageNote}</p>
              {data.triage_href ? (
                <a className="bft-link" href={data.triage_href}>
                  {t.openTriage}
                </a>
              ) : null}
            </div>
          ) : null}
          {session ? (
            <div className="bft-rail-section">
              <h3>{t.sessionTitle}</h3>
              <p className="bft-dialog-note">{t.sessionNote}</p>
              {session.status === "ok" && session.id ? (
                <p className="bft-mono bft-break" id="router-session-id">
                  {session.id}
                </p>
              ) : (
                <p className="bft-dialog-error">{t.sessionUnavailable}</p>
              )}
              {manage && session.id ? (
                <div>
                  <Button
                    hierarchy="secondary-gray"
                    onPress={() => {
                      const expected = session.id ?? "";
                      confirm.ask({
                        title: t.startSessionTitle,
                        description: t.startSessionBody,
                        confirmLabel: t.startSession,
                        action: () =>
                          api.switchRouterSession(org, project, agentId, expected).then(
                            (switched) => {
                              setLatest({
                                ...data,
                                router_session: {
                                  status: "ok",
                                  id: switched.router_session_id,
                                },
                              });
                              notify(switched.notice);
                            },
                            // Already switched: show the current session.
                            async (error: unknown) => {
                              await refresh();
                              throw error;
                            }
                          ),
                      });
                    }}
                    size="xs"
                  >
                    {t.startSession}
                  </Button>
                </div>
              ) : null}
            </div>
          ) : null}
        </div>
      </ScrollArea>
      {dialog === "configure" ? (
        <ConfigureDialog
          agentId={agentId}
          name={name}
          onClose={() => setDialog(null)}
          onSaved={(saved) => {
            setLatest(saved);
            setDialog(null);
            notify(saved.notice);
          }}
          org={org}
          project={project}
        />
      ) : null}
      {dialog === "rebind" && agent.binding ? (
        <RebindDialog
          agentId={agentId}
          binding={agent.binding}
          name={name}
          onClose={() => setDialog(null)}
          onSaved={(saved) => {
            setLatest(saved);
            setDialog(null);
            notify(saved.notice);
          }}
          org={org}
          project={project}
        />
      ) : null}
      {dialog === "archive" ? (
        <ArchiveDialog
          data={data}
          onArchived={(redirect, text) => {
            navigate(redirect);
            notify(text);
          }}
          onClose={() => setDialog(null)}
          onRefused={refresh}
          org={org}
          project={project}
        />
      ) : null}
      {confirm.dialog}
    </aside>
  );
}

function NewAgentDialog({
  org,
  project,
  onClose,
  onCreated,
}: {
  org: string;
  project: string;
  onClose: () => void;
  onCreated: (notice: string) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [name, setName] = useState("");
  const [type, setType] = useState<"internal" | "external">("internal");
  const [target, setTarget] = useState<TargetDraft>(emptyTarget);
  const change = useCallback(
    (next: Partial<TargetDraft>) => setTarget((previous) => ({ ...previous, ...next })),
    []
  );

  return (
    <FormDialog
      description={t.createBody}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={() =>
        write.run(
          () =>
            api.createAgent(
              org,
              project,
              type === "external"
                ? { type, name: name.trim(), target: toTarget(target) }
                : { type, name: name.trim() }
            ),
          (created) => onCreated(created.notice)
        )
      }
      submitLabel={t.createConfirm}
      title={t.newAgent}
      wide
      write={write}
    >
      <TextField
        disabled={write.busy}
        error={write.fields.name}
        label={t.nameLabel}
        onChange={setName}
        placeholder={t.namePlaceholder}
        value={name}
      />
      <Dropdown
        className="bft-form-field"
        disabled={write.busy}
        items={(["internal", "external"] as const).map((option) => ({
          id: option,
          label: t.types[option],
          subtitle: t.typeHints[option],
        }))}
        label={t.typeLabel}
        onChange={(value) => setType(value as "internal" | "external")}
        size="sm"
        value={type}
      />
      {type === "external" ? (
        <AgentTargetPicker
          disabled={write.busy}
          draft={target}
          onChange={change}
          org={org}
          project={project}
        />
      ) : null}
    </FormDialog>
  );
}

// The Dropdown needs a non-empty id for "follow the role default".
const followDefault = "__default";

function ConfigureDialog({
  org,
  project,
  agentId,
  name,
  onClose,
  onSaved,
}: {
  org: string;
  project: string;
  agentId: string;
  name: string;
  onClose: () => void;
  onSaved: (
    saved: Awaited<ReturnType<ReturnType<typeof useApi>["configureAgent"]>>
  ) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [config, retry] = useResource(
    `agent-config:${org}:${project}:${agentId}`,
    (signal) => api.agentConfig(org, project, agentId, signal)
  );
  const data = config.state === "ready" ? config.data : undefined;
  const [template, setTemplate] = useState<string>();
  const [prompt, setPrompt] = useState<string>();
  const chosen = template ?? data?.template_id ?? "";
  const text = prompt ?? data?.system_prompt ?? "";

  return (
    <FormDialog
      description={t.configureBody}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={() => {
        if (!data) return;
        write.run(
          () =>
            api.configureAgent(org, project, agentId, {
              // An untouched model is kept, even one the org no longer offers.
              ...(chosen === data.template_id ? {} : { template_id: chosen }),
              system_prompt: text,
            }),
          onSaved
        );
      }}
      submitLabel={t.saveConfig}
      title={t.configureTitle(name)}
      write={write}
    >
      {config.state === "error" ? (
        <ErrorState onRetry={retry} />
      ) : !data ? (
        <Skeleton height={32} />
      ) : (
        <>
          <Dropdown
            className="bft-form-field"
            disabled={write.busy || !data.available}
            items={data.models.map((model) => ({
              id: model.id === "" ? followDefault : model.id,
              label: model.label,
              disabled: model.disabled,
              group: model.group,
            }))}
            label={t.modelLabel}
            onChange={(id) => setTemplate(id === followDefault ? "" : id)}
            size="sm"
            value={chosen === "" ? followDefault : chosen}
          />
          {data.available ? null : <p className="bft-dialog-note">{t.noModels}</p>}
          <TextAreaField
            disabled={write.busy}
            label={t.promptLabel}
            onChange={setPrompt}
            rows={6}
            value={text}
          />
          <FieldError message={write.fields.system_prompt} />
        </>
      )}
    </FormDialog>
  );
}

function RebindDialog({
  org,
  project,
  agentId,
  name,
  binding,
  onClose,
  onSaved,
}: {
  org: string;
  project: string;
  agentId: string;
  name: string;
  binding: NonNullable<BftSwarmAgent["agent"]["binding"]>;
  onClose: () => void;
  onSaved: (
    saved: Awaited<ReturnType<ReturnType<typeof useApi>["rebindAgent"]>>
  ) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [target, setTarget] = useState<TargetDraft>(() => ({
    ...emptyTarget,
    location: binding.location,
    deviceId: binding.device_id ?? "",
    runtimeId: binding.device_runtime_id ?? "",
    provider:
      binding.provider === "pi" || binding.provider === "claude"
        ? binding.provider
        : "codex",
    workloadId: binding.workload_id ?? "",
  }));
  const change = useCallback(
    (next: Partial<TargetDraft>) => setTarget((previous) => ({ ...previous, ...next })),
    []
  );

  return (
    <FormDialog
      description={t.rebindBody}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={() =>
        write.run(
          () =>
            api.rebindAgent(org, project, agentId, {
              expected_binding_revision: binding.revision,
              target: toTarget(target),
            }),
          onSaved
        )
      }
      submitLabel={t.saveRuntime}
      title={t.rebindTitle(name)}
      wide
      write={write}
    >
      <p className="bft-dialog-note">{t.currentTarget(binding.summary)}</p>
      <AgentTargetPicker
        disabled={write.busy}
        draft={target}
        onChange={change}
        org={org}
        project={project}
      />
    </FormDialog>
  );
}

/**
 * Archiving the Triage Worker shows what stops and confirms the Triage
 * revision it showed; an assignment made meanwhile is refused and shown.
 */
function ArchiveDialog({
  org,
  project,
  data,
  onClose,
  onArchived,
  onRefused,
}: {
  org: string;
  project: string;
  data: BftSwarmAgent;
  onClose: () => void;
  onArchived: (redirect: string, notice: string) => void;
  onRefused: () => Promise<void>;
}) {
  const api = useApi();
  const write = useWrite();
  const { agent, triage } = data;
  const name = agentName(agent);

  return (
    <ConfirmDialog
      busy={write.busy}
      confirmLabel={triage.used ? t.archiveAndPause : t.archive}
      description={t.archiveBody(name)}
      destructive
      error={write.error}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onConfirm={() =>
        write.run(
          () =>
            api
              .archiveAgent(
                org,
                project,
                agent.id,
                triage.used ? triage.revision : null
              )
              .catch(async (error: unknown) => {
                if (
                  error instanceof BftApiError &&
                  error.code === "triage_confirmation_required"
                )
                  await onRefused();
                throw error;
              }),
          ({ redirect, notice }) => onArchived(redirect, notice)
        )
      }
      title={t.archiveTitle}
    >
      {triage.used ? (
        <div className="bft-notice" id="archive-triage-warning">
          <p>{t.triageWarning(data.project.name)}</p>
          <p>{t.triageWarningMore}</p>
          {data.triage_href ? (
            <a className="bft-link" href={data.triage_href}>
              {t.chooseAnother}
            </a>
          ) : null}
        </div>
      ) : null}
    </ConfirmDialog>
  );
}
