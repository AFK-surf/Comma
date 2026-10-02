import { Button, Checkbox, Dropdown, Toggle } from "@comma/ui";
import { useEffect, useRef, useState } from "react";
import {
  BftApiError,
  type BftTriageAgent,
  type BftTriageChannels,
  type BftTriageOverview,
  type BftTriageSource,
} from "./api";
import { ConfirmDialog, writeErrorMessage } from "./dialogs";
import { formatDateTime } from "./format";
import { NoSwarms, useSwarmChoice } from "./MeetingsPage";
import { messages } from "./messages";
import { orgHref, triagePaths } from "./navSpec";
import { useApi, useResource, type Resource } from "./resource";
import { navigate, spaLinkClick, type TriageView } from "./router";
import {
  FormActions,
  FormDialog,
  FormSection,
  SaveButton,
  SettingsPage,
  TextField,
  useWrite,
} from "./settingsForm";
import { Skeleton } from "./states";
import { TriageKnowledge } from "./TriageKnowledge";
import {
  agentGroup,
  agentSummary,
  botName,
  canSwitch,
  channelsEditable,
  monitoringActive,
  sourceMeta,
  sourceNotices,
  switchLabel,
  type Tone,
} from "./triageModel";
import { TriageTimeline } from "./TriageTimeline";

const t = messages.triage;

const pages: Record<TriageView, [string, string]> = {
  overview: [t.overviewTitle, t.overviewDescription],
  timeline: [t.timelineTitle, t.timelineDescription],
  knowledge: [t.knowledgeTitle, t.knowledgeDescription],
};

const groupOrder = ["ready", "empty", "partial", "unavailable"];

/**
 * Slack triage: the pages of one router Agent, chosen in the header and kept
 * in `?agent=`. The roster is read once; a write reads it again while the
 * page keeps showing what it had.
 */
export function TriagePage({
  org,
  view,
  retired = false,
}: {
  org: string;
  view: TriageView;
  retired?: boolean;
}) {
  const api = useApi();
  const [resource, reload] = useResource(`triage:${org}`, (signal) =>
    api.triage(org, signal)
  );
  const last = useRef<BftTriageOverview | undefined>(undefined);
  if (resource.state === "ready") last.current = resource.data;
  const data = resource.state === "ready" ? resource.data : last.current;
  const agents = (data?.agents ?? []).toSorted(
    (a, b) => groupOrder.indexOf(a.state) - groupOrder.indexOf(b.state)
  );
  const [agent, choose, missing] = useSwarmChoice(org, agents, "agent");
  const [refresh, setRefresh] = useState(0);
  const [title, description] = pages[view];

  // The retired Context, Memory and Raw data addresses open the Overview.
  useEffect(() => {
    if (!retired) return;
    const agentId = new URLSearchParams(window.location.search).get("agent");
    navigate(
      `${orgHref(org, triagePaths.overview)}${agentId ? `?agent=${encodeURIComponent(agentId)}` : ""}`,
      { replace: true }
    );
  }, [org, retired]);

  return (
    <SettingsPage
      actions={
        <>
          {agents.length > 1 ? (
            <Dropdown
              ariaLabel={t.agent}
              items={agents.map((item) => ({
                id: item.id,
                label: item.name,
                subtitle: [
                  item.name !== item.project_name && item.project_name,
                  agentSummary(item),
                ]
                  .filter(Boolean)
                  .join(" · "),
                group: agentGroup(item),
              }))}
              onChange={choose}
              size="sm"
              width="content"
              {...(agent ? { value: agent.id } : {})}
            />
          ) : null}
          {agent && view === "timeline" ? (
            <button
              className="bft-btn"
              onClick={() => setRefresh((value) => value + 1)}
              type="button"
            >
              {t.refresh}
            </button>
          ) : null}
        </>
      }
      description={description}
      onRetry={reload}
      resource={data ? { state: "ready", data } : resource}
      title={title}
      wide
    >
      {(overview) =>
        overview.agents_status === "unavailable" ? (
          <p className="bft-notice">{t.agentsUnavailable}</p>
        ) : !agent ? (
          <NoSwarms body={t.noAgents} />
        ) : (
          <>
            {missing ? (
              <p className="bft-notice">{t.agentMissing(agent.name)}</p>
            ) : null}
            {view === "overview" ? (
              <Overview
                agent={agent}
                data={overview}
                key={agent.id}
                onChanged={reload}
                org={org}
              />
            ) : view === "timeline" ? (
              <TriageTimeline
                agent={agent}
                key={agent.id}
                org={org}
                refresh={refresh}
              />
            ) : (
              <TriageKnowledge agent={agent} key={agent.id} org={org} />
            )}
          </>
        )
      }
    </SettingsPage>
  );
}

interface Notice {
  kind: "info" | "error";
  text: string;
}

function Overview({
  org,
  agent,
  data,
  onChanged,
}: {
  org: string;
  agent: BftTriageAgent;
  data: BftTriageOverview;
  onChanged: () => void;
}) {
  const api = useApi();
  const sources = agent.sources.map((source) => ({ ...source, id: source.connect_id }));
  const [source, chooseSource] = useSwarmChoice(org, sources, "connect");
  const [notice, setNotice] = useState<Notice>();
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [adding, setAdding] = useState(false);

  // Every write re-reads the sources, failed or not: a failed write may still
  // have changed the source, and a stale switch must not stay on the page.
  const run = (write: () => Promise<string>) => {
    setBusy(true);
    write()
      .then(
        (text) => setNotice({ kind: "info", text }),
        (error: unknown) =>
          setNotice({ kind: "error", text: writeErrorMessage(error) ?? "" })
      )
      .finally(() => {
        setBusy(false);
        setConfirming(false);
        onChanged();
      });
  };

  return (
    <>
      {notice?.text ? (
        <p
          className="bft-notice"
          data-kind={notice.kind}
          role={notice.kind === "error" ? "alert" : "status"}
        >
          {notice.text}
        </p>
      ) : null}
      <div className="bft-settings-grid">
        <div>
          {!data.has_sources ? (
            <FormSection description={t.noAssistantsBody} title={t.noAssistantsTitle}>
              <a
                className="bft-link"
                href={orgHref(org, "/projects")}
                onClick={spaLinkClick}
              >
                {t.connectSlack}
              </a>
            </FormSection>
          ) : !source ? (
            <FormSection description={t.noSourceBody} title={t.noSourceTitle}>
              {null}
            </FormSection>
          ) : (
            <>
              <FormSection
                action={
                  source.complete || source.enabled ? (
                    <Toggle
                      aria-label={source.enabled ? t.turnOff : t.turnOn}
                      checked={source.enabled}
                      disabled={busy || !canSwitch(source)}
                      label={switchLabel(source)}
                      onChange={() => setConfirming(true)}
                      size="sm"
                    />
                  ) : (
                    <span className="bft-status" data-tone="warn">
                      {t.unavailable}
                    </span>
                  )
                }
                description={[sourceMeta(source), agent.project_name]
                  .filter(Boolean)
                  .join(" · ")}
                title={botName(source)}
              >
                {sources.length > 1 ? (
                  <Dropdown
                    className="bft-form-field"
                    disabled={busy}
                    items={sources.map((item) => ({
                      id: item.connect_id,
                      label: botName(item),
                      subtitle: item.complete ? sourceMeta(item) : t.statusUnreadable,
                    }))}
                    label={t.source}
                    onChange={chooseSource}
                    size="sm"
                    value={source.connect_id}
                  />
                ) : null}
                {sourceNotices(source).map((text) => (
                  <p className="bft-notice" key={text}>
                    {text}
                  </p>
                ))}
              </FormSection>
              <Channels
                busy={busy}
                onAdd={() => setAdding(true)}
                onToggle={(channel, enabled) =>
                  run(() =>
                    api.setTriageChannel(
                      org,
                      agent.id,
                      source.connect_id,
                      channel,
                      enabled
                    )
                  )
                }
                source={source}
              />
            </>
          )}
          {data.unavailable_projects.length > 0 ? (
            <p className="bft-notice">
              {t.projectsUnreadable(
                data.unavailable_projects.filter(Boolean).join(", ")
              )}
            </p>
          ) : null}
        </div>
        <div>
          <Evaluation
            agent={agent}
            monitoring={source ? monitoringActive(source) : false}
            org={org}
          />
          <Worker agent={agent} org={org} />
        </div>
      </div>
      {confirming && source ? (
        <ConfirmDialog
          busy={busy}
          confirmLabel={source.enabled ? t.turnOff : t.turnOn}
          description={
            source.enabled
              ? t.confirmOff(agent.project_name ?? botName(source))
              : t.confirmOn(agent.project_name ?? botName(source))
          }
          destructive={source.enabled}
          error={undefined}
          onClose={() => setConfirming(false)}
          onConfirm={() =>
            run(() =>
              api.setTriageSource(org, agent.id, source.connect_id, !source.enabled)
            )
          }
          title={source.enabled ? t.turnOff : t.turnOn}
        />
      ) : null}
      {adding && source ? (
        <AddChannels
          agent={agent.id}
          onClose={() => setAdding(false)}
          onChanged={onChanged}
          onDone={(text) => {
            setAdding(false);
            setNotice({ kind: "info", text });
            onChanged();
          }}
          org={org}
          source={source}
        />
      ) : null}
    </>
  );
}

function Channels({
  source,
  busy,
  onToggle,
  onAdd,
}: {
  source: BftTriageSource;
  busy: boolean;
  onToggle: (channel: string, enabled: boolean) => void;
  onAdd: () => void;
}) {
  const editable = channelsEditable(source);
  return (
    <FormSection
      action={
        editable ? (
          <button
            className="bft-btn bft-btn-sm"
            disabled={busy}
            onClick={onAdd}
            type="button"
          >
            {t.addChannels}
          </button>
        ) : null
      }
      description={t.channelsHint}
      title={t.channelsTitle}
    >
      {source.channels.length > 0 ? (
        <ul className="bft-list">
          {source.channels.map((channel) => {
            const name = `#${channel.name ?? channel.id}`;
            return (
              <li className="bft-setting-row" key={channel.id}>
                <span className="bft-setting-row-main">
                  <span className="bft-truncate">{name}</span>
                  <span className="bft-setting-row-sub">
                    {channel.enabled ? t.channelIncluded : t.channelPaused}
                  </span>
                </span>
                <Toggle
                  aria-label={name}
                  checked={channel.enabled}
                  disabled={busy || !editable}
                  onChange={(event) => onToggle(channel.id, event.target.checked)}
                  size="sm"
                />
              </li>
            );
          })}
        </ul>
      ) : source.complete && source.channel_scope_complete !== false ? (
        <div className="bft-quiet bft-quiet-inline">
          <p>{t.noChannelsTitle}</p>
          <p>{t.noChannelsBody}</p>
        </div>
      ) : null}
    </FormSection>
  );
}

const maxNewChannels = 20;

/**
 * A failed add may still have added some channels: these answers re-read the
 * source and the channel list, so a retry sends only what is still missing.
 */
const addMayHaveLanded = (error: unknown) =>
  error instanceof BftApiError &&
  (error.code === "partially_added" || error.status === 503 || error.status === 504);

/** Adds channels from Slack's list, read 100 at a time and searched locally. */
function AddChannels({
  org,
  agent,
  source,
  onClose,
  onChanged,
  onDone,
}: {
  org: string;
  agent: string;
  source: BftTriageSource;
  onClose: () => void;
  onChanged: () => void;
  onDone: (notice: string) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [page, setPage] = useState<Resource<BftTriageChannels>>({ state: "loading" });
  const [loadingMore, setLoadingMore] = useState(false);
  const [reread, setReread] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    api.triageChannels(org, agent, source.connect_id, null).then(
      (data) => !controller.signal.aborted && setPage({ state: "ready", data }),
      (error: unknown) =>
        !controller.signal.aborted && setPage({ state: "error", error })
    );
    return () => controller.abort();
  }, [api, org, agent, source.connect_id, reread]);

  const ready = page.state === "ready" ? page.data : undefined;
  const configured = new Set(source.channels.map((channel) => channel.id));
  // A channel added by an earlier, partly failed attempt is not sent again.
  const pending = selected.filter((id) => !configured.has(id));
  const options = (ready?.channels ?? []).filter(
    (channel) =>
      !configured.has(channel.id) &&
      (query.trim() === "" ||
        `${channel.name} ${channel.id}`
          .toLowerCase()
          .includes(query.trim().toLowerCase()))
  );

  const more = () => {
    if (!ready?.next_cursor) return;
    setLoadingMore(true);
    api.triageChannels(org, agent, source.connect_id, ready.next_cursor).then(
      (next) => {
        setLoadingMore(false);
        setPage({
          state: "ready",
          data: {
            channels: [...ready.channels, ...next.channels],
            next_cursor: next.next_cursor,
          },
        });
      },
      (error: unknown) => {
        setLoadingMore(false);
        setPage({ state: "error", error });
      }
    );
  };

  return (
    <FormDialog
      description={t.addChannelsDescription}
      onClose={onClose}
      onSubmit={() =>
        pending.length > 0 &&
        pending.length <= maxNewChannels &&
        write.run(
          () =>
            api
              .addTriageChannels(org, agent, source.connect_id, pending)
              .catch((error: unknown) => {
                if (addMayHaveLanded(error)) {
                  onChanged();
                  setReread((value) => value + 1);
                }
                throw error;
              }),
          onDone
        )
      }
      submitLabel={t.addSelected}
      title={t.addChannels}
      wide
      write={write}
    >
      <TextField
        label={t.searchChannels}
        onChange={setQuery}
        placeholder={t.searchChannelsHint}
        value={query}
      />
      {page.state === "loading" ? (
        <Skeleton height={14} />
      ) : page.state === "error" ? (
        <p className="bft-dialog-error" role="alert">
          {writeErrorMessage(page.error)}
        </p>
      ) : options.length === 0 ? (
        <p className="bft-dialog-note">
          {query.trim() ? t.noMatchingChannels : t.noMoreChannels}
        </p>
      ) : (
        <div className="bft-checklist">
          {options.map((channel) => (
            <Checkbox
              checked={pending.includes(channel.id)}
              {...(channel.private ? { hint: t.privateChannel } : {})}
              key={channel.id}
              label={`#${channel.name}`}
              onChange={(event) =>
                setSelected((value) =>
                  event.target.checked
                    ? [...value, channel.id]
                    : value.filter((id) => id !== channel.id)
                )
              }
              size="sm"
            />
          ))}
        </div>
      )}
      {ready?.next_cursor ? (
        <Button
          disabled={loadingMore}
          hierarchy="secondary-gray"
          onPress={more}
          size="sm"
        >
          {t.moreChannels}
        </Button>
      ) : null}
      <p className="bft-form-section-note">
        {t.selectedChannels(pending.length, maxNewChannels)}
      </p>
    </FormDialog>
  );
}

const readiness: Record<string, [string, Tone]> = {
  ready: [t.evaluationReady, "ok"],
  unavailable: [t.evaluationDown, "warn"],
  unknown: [t.statusUnavailable, undefined],
};

function Evaluation({
  org,
  agent,
  monitoring,
}: {
  org: string;
  agent: BftTriageAgent;
  monitoring: boolean;
}) {
  const api = useApi();
  const [refresh, setRefresh] = useState(0);
  const [status] = useResource(
    `triage-evaluation:${org}:${agent.id}:${refresh}`,
    (signal) => api.triageEvaluation(org, agent.id, refresh > 0, signal)
  );
  const ready = status.state === "ready" ? status.data : undefined;
  const state =
    status.state === "loading" ? undefined : (ready?.readiness ?? "unknown");
  const [label, tone] = readiness[state ?? "unknown"] ?? ["", undefined];

  return (
    <FormSection
      action={
        <button
          className="bft-btn bft-btn-sm"
          disabled={status.state === "loading"}
          onClick={() => setRefresh((value) => value + 1)}
          type="button"
        >
          {t.refreshStatus}
        </button>
      }
      title={t.evaluationTitle}
    >
      {state === undefined ? (
        <Skeleton height={14} width="40%" />
      ) : (
        <>
          <p className="bft-row-title">
            <span className="bft-status" data-tone={tone}>
              {label}
            </span>
            {ready?.checked_at_ms ? (
              <span className="bft-tag">
                {t.checkedAt(formatDateTime(ready.checked_at_ms))}
              </span>
            ) : null}
          </p>
          <p className="bft-form-section-note">
            {state === "ready"
              ? monitoring
                ? t.evaluationActive
                : t.evaluationPaused
              : state === "unavailable"
                ? t.evaluationDownBody
                : t.evaluationUnknownBody}
          </p>
        </>
      )}
    </FormSection>
  );
}

const unassigned = "none";
const workerAnchor = "triage-worker-configuration";

/**
 * The Worker for new Triage tasks of this Agent's Agent Swarm. The Agent
 * Swarm's Agents page links here with `#triage-worker-configuration`.
 */
function Worker({ org, agent }: { org: string; agent: BftTriageAgent }) {
  const api = useApi();
  const write = useWrite();
  const [query, setQuery] = useState("");
  const [search, setSearch] = useState("");
  const [cursor, setCursor] = useState<string | null>(null);
  const [choice, setChoice] = useState<string | null>(null);
  const [reload, setReload] = useState(0);
  const [notice, setNotice] = useState<string>();
  // The revision this page read first; a save against another one is refused.
  const revision = useRef<number | null | undefined>(undefined);
  const preview = choice === unassigned ? null : choice;
  const [config] = useResource(
    `triage-worker:${org}:${agent.id}:${search}:${cursor ?? ""}:${choice ?? ""}:${reload}`,
    (signal) =>
      api.triageWorker(org, agent.id, { query: search, preview, cursor }, signal)
  );
  const view = config.state === "ready" ? config.data : undefined;
  if (view && revision.current === undefined) revision.current = view.revision;

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setSearch(query.trim());
      setCursor(null);
    }, 300);
    return () => window.clearTimeout(timer);
  }, [query]);

  useEffect(() => {
    if (window.location.hash === `#${workerAnchor}`)
      document.getElementById(workerAnchor)?.scrollIntoView({ block: "start" });
  }, []);

  const selected = choice ?? view?.worker_id ?? unassigned;
  const options = [view?.worker, view?.preview, ...(view?.candidates ?? [])].filter(
    (worker, index, all): worker is NonNullable<typeof worker> =>
      !!worker && all.findIndex((other) => other?.id === worker.id) === index
  );
  const shown = selected === unassigned ? null : (view?.preview ?? view?.worker);

  const save = () =>
    write.run(
      () =>
        api
          .saveTriageWorker(
            org,
            agent.id,
            selected === unassigned ? null : selected,
            revision.current ?? null
          )
          .finally(() => {
            // Saved or refused, the page shows the current selection again.
            revision.current = undefined;
            setChoice(null);
            setReload((value) => value + 1);
          }),
      setNotice
    );

  return (
    <FormSection description={t.workerHint} id={workerAnchor} title={t.workerTitle}>
      {config.state === "loading" && !view ? (
        <Skeleton height={14} width="50%" />
      ) : config.state === "error" ? (
        <p className="bft-notice">{writeErrorMessage(config.error)}</p>
      ) : view && !view.can_manage ? (
        <p>{view.worker?.name ?? (view.worker_id ? view.worker_id : t.notAssigned)}</p>
      ) : view ? (
        <>
          <TextField label={t.findWorker} onChange={setQuery} value={query} />
          <Dropdown
            ariaLabel={t.workerTitle}
            className="bft-form-field"
            disabled={write.busy}
            items={[
              { id: unassigned, label: t.unassignedOption },
              ...options.map((worker) => ({
                id: worker.id,
                label: worker.name ?? worker.id,
              })),
            ]}
            onChange={(id) => {
              setNotice(undefined);
              setChoice(id);
            }}
            size="sm"
            value={selected}
          />
          {view.next_cursor ? (
            <button
              className="bft-btn bft-btn-sm"
              onClick={() => setCursor(view.next_cursor)}
              type="button"
            >
              {t.moreWorkers}
            </button>
          ) : null}
          <output className="bft-form-section-note" id="triage-worker-preview">
            {shown === null
              ? t.pausedWithoutWorker
              : t.sentence(
                  (t.availability as Record<string, string>)[shown?.status ?? "none"] ??
                    t.availability.unavailable
                )}{" "}
            {t.existingTasksStay}
          </output>
          {view.tools_ready === false ? (
            <p className="bft-notice">{t.toolsDisabled}</p>
          ) : null}
          {notice ? <output className="bft-form-section-note">{notice}</output> : null}
          <FormActions write={{ ...write, saved: false }}>
            <SaveButton busy={write.busy} onPress={save} />
          </FormActions>
        </>
      ) : null}
    </FormSection>
  );
}
