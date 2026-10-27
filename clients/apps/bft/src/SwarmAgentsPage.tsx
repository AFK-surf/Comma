import { Button } from "@comma/ui/components/Button";
import { Dropdown } from "@comma/ui/components/dropdown";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { XIcon } from "@comma/ui/components/icons";
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import {
  BftApiError,
  type BftModelPickerRow,
  type BftSwarmAgent,
  type BftSwarmAgentRow,
  type BftSwarmAgents,
} from "./api";
import { CopyButton } from "./dialogs";
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
  useConfirm,
  useWrite,
} from "./settingsForm";
import { ErrorState, Skeleton } from "./states";

const t = messages.swarmAgents;
const p = messages.project;

export const agentName = (agent: { name: string | null }) =>
  agent.name ?? p.unnamedAgent;

const roleLabel = (role: string) => p.agentRoles[role] ?? humanize(role);

/**
 * An Agent Swarm's Router in a table, the selected agent in a detail rail. The
 * address names the selected agent, so `/agents/:id` deep-links to it; a
 * Worker made before Workers were retired opens there read-only. Writes leave
 * a notice and reload the list, keeping the last list while it loads.
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
  const last = useRef<BftSwarmAgents | undefined>(undefined);
  if (first.state === "ready") last.current = first.data;
  const data = first.state === "ready" ? first.data : last.current;
  // Refresh also re-reads the open agent.
  const [railReads, setRailReads] = useState(0);
  // A deep link may name the agent by its Salix id; the rail resolves it.
  const [resolved, setResolved] = useState<{ from: string; id: string }>();
  const selected = resolved && resolved.from === agentId ? resolved.id : agentId;

  const agentsPath = projectHref(org, project, "/agents");
  const notify = useCallback(
    (notice: string) => {
      showFlash({ kind: "info", text: notice }, agentsPath);
      onRetry();
    },
    [agentsPath, onRetry]
  );

  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <h1>{t.title}</h1>
          <p>{data ? t.description(data.project.name) : <Skeleton width={220} />}</p>
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
                <Skeleton height={14} />
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
                agents={data.agents}
                href={(id) => `${agentsPath}/${encodeURIComponent(id)}`}
                selected={selected}
              />
            )}
            <p className="bft-quiet">
              {t.tasksNote}{" "}
              <a
                className="bft-link"
                href={projectHref(org, project, "/settings")}
                onClick={spaLinkClick}
              >
                {t.tasksSettings}
              </a>
            </p>
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
    </div>
  );
}

function AgentRows({
  agents,
  selected,
  href,
}: {
  agents: BftSwarmAgentRow[];
  selected: string | undefined;
  href: (id: string) => string;
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
          </tr>
        </thead>
        <tbody>
          {agents.map((agent) => (
            <tr data-selected={agent.id === selected ? true : undefined} key={agent.id}>
              <td>
                <a
                  aria-current={agent.id === selected ? "true" : undefined}
                  className="bft-link"
                  href={href(agent.id)}
                  onClick={spaLinkClick}
                  title={agentName(agent)}
                >
                  {agentName(agent)}
                </a>
              </td>
              <td className="bft-col-role">{roleLabel(agent.role)}</td>
              <td className="bft-col-status">
                <State value={agent.lifecycle} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </ScrollArea>
  );
}

/**
 * One agent's facts and prompt; for the Router also its session and the admin
 * actions. A retired Worker reads as history, without actions.
 */
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
  const [configuring, setConfiguring] = useState(false);
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
  const manage = data.project.role === "admin" && !agent.read_only;
  const archived = agent.lifecycle === "archived";
  const name = agentName(agent);
  const rows: [string, ReactNode, (string | undefined)?][] = [
    [t.detailRole, roleLabel(agent.role)],
    [t.detailStatus, <State key="status" value={agent.lifecycle} />],
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
          {agent.read_only ? <p className="bft-notice">{t.retiredNote}</p> : null}
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
          {manage && !archived ? (
            <div className="bft-rail-actions">
              <Button
                hierarchy="secondary-gray"
                onPress={() => setConfiguring(true)}
                size="xs"
              >
                {t.configure}
              </Button>
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
      {configuring ? (
        <ConfigureDialog
          agentId={agentId}
          name={name}
          onClose={() => setConfiguring(false)}
          onSaved={(saved) => {
            setLatest(saved);
            setConfiguring(false);
            notify(saved.notice);
          }}
          org={org}
          project={project}
        />
      ) : null}
      {confirm.dialog}
    </aside>
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
  const [modelKey, setModelKey] = useState<string>();
  const [prompt, setPrompt] = useState<string>();
  const chosen = modelKey ?? data?.model_key ?? "";
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
              ...(chosen === data.model_key
                ? {}
                : {
                    model:
                      data.models.find((model) => model.key === chosen)?.choice ?? null,
                  }),
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
          <ChoiceModelField
            available={data.available}
            busy={write.busy}
            chosen={chosen}
            models={data.models}
            onChange={setModelKey}
          />
          <TextAreaField
            disabled={write.busy || !data.prompt_editable}
            {...(data.prompt_editable ? {} : { hint: t.promptOwnerOnly })}
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

/**
 * The org's model choices as the server lists them; key "" is the row for
 * "no choice" (the default model, or the org default Task model).
 */
export function ChoiceModelField({
  models,
  chosen,
  busy,
  label = t.modelLabel,
  available = true,
  onChange,
}: {
  models: BftModelPickerRow[];
  chosen: string;
  busy: boolean;
  label?: string;
  available?: boolean;
  onChange: (key: string) => void;
}) {
  return (
    <>
      <Dropdown
        className="bft-form-field"
        disabled={busy || !available}
        items={models.map((model) => ({
          id: model.key === "" ? followDefault : model.key,
          label: model.label,
          disabled: model.disabled,
          group: model.group,
        }))}
        label={label}
        onChange={(id) => onChange(id === followDefault ? "" : id)}
        size="sm"
        value={chosen === "" ? followDefault : chosen}
      />
      {available ? null : <p className="bft-dialog-note">{t.noModels}</p>}
    </>
  );
}
