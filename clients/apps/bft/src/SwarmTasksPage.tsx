import {
  Button,
  Dropdown,
  ScrollArea,
  ScrollAreaLoadMore,
  SearchIcon,
} from "@comma/ui";
import { Fragment, useEffect, useMemo, useRef, useState } from "react";
import {
  BftApiError,
  type BftSwarmSchedules,
  type BftSwarmTask,
  type BftSwarmTasks,
} from "./api";
import { formatInteger, formatRelative, humanize } from "./format";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { State, stateLabel } from "./ProjectOverviewPage";
import { useApi, useResource, type Resource } from "./resource";
import { navigate, spaLinkClick, useSearch } from "./router";
import { FormDialog, TextField, useConfirm, useWrite } from "./settingsForm";
import { ErrorState, Skeleton } from "./states";

const t = messages.swarmTasks;

/** `all`, `scheduled` (the recurring schedules), or one task status. */
export type TaskView = string;

export const scheduledView = "scheduled";

export const taskTitle = (task: BftSwarmTask) => task.title ?? t.untitled;

export const kindLabel = (kind: string | null) =>
  kind ? (t.kinds[kind] ?? humanize(kind)) : "—";

/** The statuses among the loaded tasks, `active` first. */
export function taskStatuses(tasks: readonly BftSwarmTask[]) {
  return [...new Set(tasks.map((task) => task.status))].toSorted((a, b) =>
    a === "active" ? -1 : b === "active" ? 1 : a.localeCompare(b)
  );
}

/** Tasks in `view` whose title, type or status contains `query`. */
export function filterTasks(
  tasks: readonly BftSwarmTask[],
  view: TaskView,
  query: string
) {
  const needle = query.trim().toLowerCase();
  return tasks.filter(
    (task) =>
      (view === "all" || task.status === view) &&
      (needle === "" ||
        [taskTitle(task), kindLabel(task.kind), stateLabel(task.status)]
          .join(" ")
          .toLowerCase()
          .includes(needle))
  );
}

/**
 * The view an address asks for (`?view=`); the retired Schedules page asks for
 * Scheduled. The address owns the view, so the sidebar's Tasks link opens All.
 */
export const initialView = (search: string): TaskView =>
  new URLSearchParams(search).get("view") || "all";

// The address keeps the view, so a reload or a shared link opens it again.
function setView(next: TaskView) {
  const url = new URL(window.location.href);
  if (next === "all") url.searchParams.delete("view");
  else url.searchParams.set("view", next);
  navigate(url.pathname + url.search + url.hash, { replace: true });
}

interface More {
  tasks: BftSwarmTask[];
  cursor: string | null | undefined;
  loading: boolean;
  failed: boolean;
}

export function SwarmTasksPage({
  org,
  project,
  first,
  onRetry,
}: {
  org: string;
  project: string;
  first: Resource<BftSwarmTasks>;
  onRetry: () => void;
}) {
  const api = useApi();
  const data = first.state === "ready" ? first.data : undefined;
  const view = initialView(useSearch());
  const [query, setQuery] = useState("");
  const [creating, setCreating] = useState(false);
  const [more, setMore] = useState<More>({
    tasks: [],
    cursor: undefined,
    loading: false,
    failed: false,
  });
  const loading = useRef<AbortController | null>(null);
  useEffect(() => () => loading.current?.abort(), []);

  const tasks = useMemo(
    () => (data ? [...data.tasks, ...more.tasks] : []),
    [data, more.tasks]
  );
  const cursor = more.cursor === undefined ? (data?.next_cursor ?? null) : more.cursor;
  const loadMore = () => {
    if (!cursor || more.loading) return;
    const controller = new AbortController();
    loading.current = controller;
    setMore((previous) => ({ ...previous, loading: true, failed: false }));
    api.swarmTasks(org, project, cursor, controller.signal).then(
      (page) => {
        if (controller.signal.aborted) return;
        // An outage on a later page is a failure to retry, never the end.
        if (page.status !== "ok") {
          setMore((previous) => ({ ...previous, loading: false, failed: true }));
          return;
        }
        setMore((previous) => {
          const seen = new Set([...tasks, ...previous.tasks].map((task) => task.id));
          return {
            tasks: [
              ...previous.tasks,
              ...page.tasks.filter((task) => !seen.has(task.id)),
            ],
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

  const agents = data?.agents;
  const canCreate =
    data?.project.role === "admin" &&
    agents?.status === "ok" &&
    agents.items.length > 0;
  const statuses = taskStatuses(tasks);
  const countOf = (status: string) =>
    tasks.filter((task) => task.status === status).length;
  const views = [
    { id: "all", label: `${t.all} ${formatInteger(tasks.length)}` },
    { id: scheduledView, label: t.scheduled },
    ...statuses.map((status) => ({
      id: status,
      label: `${stateLabel(status)} ${formatInteger(countOf(status))}`,
    })),
  ];
  // A status from the address that no loaded task has still shows as chosen.
  if (!views.some((item) => item.id === view)) {
    views.push({ id: view, label: `${stateLabel(view)} 0` });
  }

  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <h1>{t.title}</h1>
          <p>{data ? t.description(data.project.name) : <Skeleton width={220} />}</p>
        </div>
        <div className="bft-page-actions">
          {canCreate ? (
            <button
              className="bft-btn bft-btn-primary"
              onClick={() => setCreating(true)}
              type="button"
            >
              {t.newTask}
            </button>
          ) : null}
        </div>
      </div>
      {first.state === "error" ? (
        <div className="bft-panel bft-panel-fill">
          <ErrorState onRetry={onRetry} />
        </div>
      ) : (
        <section
          aria-labelledby="bft-tasks-title"
          className="bft-panel bft-panel-table"
        >
          <div className="bft-panel-header">
            <h2 id="bft-tasks-title">
              {view === scheduledView ? t.schedulesTitle : t.listTitle}
            </h2>
            <div className="bft-panel-tools">
              {view === scheduledView ? null : (
                <label className="bft-filter">
                  <SearchIcon className="bft-filter-icon" />
                  <input
                    aria-label={t.search}
                    onChange={(event) => setQuery(event.target.value)}
                    placeholder={t.search}
                    type="search"
                    value={query}
                  />
                </label>
              )}
              <Dropdown
                ariaLabel={t.filter}
                contentAlign="end"
                items={views}
                onChange={setView}
                size="xs"
                value={view}
                width="content"
              />
            </div>
          </div>
          {view === scheduledView ? (
            <Schedules org={org} project={project} />
          ) : !data ? (
            <RowsSkeleton />
          ) : data.status === "unavailable" ? (
            <div className="bft-quiet-row">
              <p className="bft-quiet bft-quiet-inline">{t.unavailable}</p>
              <button className="bft-btn bft-btn-sm" onClick={onRetry} type="button">
                {messages.states.retry}
              </button>
            </div>
          ) : agents?.status === "ok" &&
            agents.items.length === 0 &&
            tasks.length === 0 ? (
            <div className="bft-panel-body bft-empty-inline">
              <p className="bft-quiet bft-quiet-inline">
                {t.noAgentsTitle} {t.noAgentsBody}
              </p>
              <a
                className="bft-link"
                href={projectHref(org, project, "/agents")}
                onClick={spaLinkClick}
              >
                {t.manageAgents}
              </a>
            </div>
          ) : (
            <TaskRows
              cursor={cursor}
              failed={more.failed}
              loading={more.loading}
              onLoadMore={loadMore}
              query={query}
              tasks={tasks}
              view={view}
            />
          )}
        </section>
      )}
      {creating && agents ? (
        <NewTaskDialog
          agents={agents.items}
          onClose={() => setCreating(false)}
          org={org}
          project={project}
        />
      ) : null}
    </div>
  );
}

function RowsSkeleton() {
  return (
    <div className="bft-rows-skeleton">
      {Array.from({ length: 5 }, (_, index) => (
        <Skeleton height={14} key={index} />
      ))}
    </div>
  );
}

function TaskRows({
  tasks,
  view,
  query,
  cursor,
  loading,
  failed,
  onLoadMore,
}: {
  tasks: BftSwarmTask[];
  view: TaskView;
  query: string;
  cursor: string | null;
  loading: boolean;
  failed: boolean;
  onLoadMore: () => void;
}) {
  if (tasks.length === 0) return <p className="bft-quiet">{t.empty}</p>;
  const shown = filterTasks(tasks, view, query);
  // A search or filter may match few loaded rows; scrolling would then page
  // through the whole list on its own, so further pages wait for a press.
  const filtering = view !== "all" || query.trim() !== "";
  const groups = taskStatuses(shown).map(
    (status) => [status, shown.filter((task) => task.status === status)] as const
  );
  return (
    <ScrollArea
      className="bft-panel-scroll"
      edgeEffect="none"
      orientation="vertical"
      scrollbarVisibility="hover"
      viewportClassName="bft-scroll-viewport"
    >
      {shown.length === 0 ? (
        <p className="bft-quiet">{t.noMatches}</p>
      ) : (
        <table className="bft-table">
          <thead>
            <tr>
              <th scope="col">{t.columnTask}</th>
              <th className="bft-col-role" scope="col">
                {t.columnKind}
              </th>
              <th className="bft-col-refreshed" scope="col">
                {t.columnUpdated}
              </th>
            </tr>
          </thead>
          <tbody>
            {groups.map(([status, rows]) => (
              <Fragment key={status}>
                <tr className="bft-group-row">
                  <th colSpan={3} scope="colgroup">
                    <State value={status} />
                    <span className="bft-count">{formatInteger(rows.length)}</span>
                  </th>
                </tr>
                {rows.map((task) => (
                  <tr key={task.id}>
                    <td>
                      <span className="bft-title-cell">
                        {/* Task detail is a LiveView page: a full page load. */}
                        <a
                          className="bft-link"
                          href={task.href}
                          title={taskTitle(task)}
                        >
                          {taskTitle(task)}
                        </a>
                        {task.scheduled ? (
                          <span className="bft-tag">{t.scheduledTag}</span>
                        ) : null}
                      </span>
                    </td>
                    <td className="bft-col-role">{kindLabel(task.kind)}</td>
                    <td
                      className="bft-col-refreshed"
                      title={task.updated_at ?? undefined}
                    >
                      {(task.updated_at && formatRelative(task.updated_at)) || "—"}
                    </td>
                  </tr>
                ))}
              </Fragment>
            ))}
          </tbody>
        </table>
      )}
      {filtering ? null : (
        <ScrollAreaLoadMore
          failed={failed}
          hasMore={cursor !== null}
          loading={loading}
          onLoadMore={onLoadMore}
          quiet
        />
      )}
      {loading ? (
        <output className="bft-quiet">{t.loadingMore}</output>
      ) : failed ? (
        <div className="bft-quiet-row" role="alert">
          <p className="bft-quiet bft-quiet-inline">{t.loadMoreFailed}</p>
          <button className="bft-btn bft-btn-sm" onClick={onLoadMore} type="button">
            {messages.states.retry}
          </button>
        </div>
      ) : filtering && cursor !== null ? (
        <div className="bft-quiet-row">
          <p className="bft-quiet bft-quiet-inline">{t.loadedNote(tasks.length)}</p>
          <button className="bft-btn bft-btn-sm" onClick={onLoadMore} type="button">
            {t.loadMore}
          </button>
        </div>
      ) : null}
    </ScrollArea>
  );
}

/** The Scheduled view: every recurring schedule, deleted behind a confirmation. */
function Schedules({ org, project }: { org: string; project: string }) {
  const api = useApi();
  const [loaded, retry] = useResource(`schedules:${org}:${project}`, (signal) =>
    api.swarmSchedules(org, project, signal)
  );
  const [latest, setLatest] = useState<BftSwarmSchedules>();
  const confirm = useConfirm();
  const data = latest ?? (loaded.state === "ready" ? loaded.data : undefined);

  if (loaded.state === "error" && !latest) return <ErrorState onRetry={retry} />;
  if (!data) return <RowsSkeleton />;
  if (data.status === "unavailable") {
    return (
      <div className="bft-quiet-row">
        <p className="bft-quiet bft-quiet-inline">{t.schedulesUnavailable}</p>
        <button className="bft-btn bft-btn-sm" onClick={retry} type="button">
          {messages.states.retry}
        </button>
      </div>
    );
  }
  const manage = data.project.role === "admin";
  return (
    <ScrollArea
      className="bft-panel-scroll"
      edgeEffect="none"
      orientation="vertical"
      scrollbarVisibility="hover"
      viewportClassName="bft-scroll-viewport"
    >
      <p className="bft-quiet">{t.schedulesNote}</p>
      {data.schedules.length === 0 ? (
        <p className="bft-quiet">{t.schedulesEmpty}</p>
      ) : (
        <table className="bft-table">
          <thead>
            <tr>
              <th className="bft-col-target" scope="col">
                {t.columnTarget}
              </th>
              <th scope="col">{t.columnRecurrence}</th>
              <th className="bft-col-refreshed" scope="col">
                {t.columnLastRun}
              </th>
              {manage ? (
                <th className="bft-col-actions" scope="col">
                  <span className="bft-sr-only">{t.delete}</span>
                </th>
              ) : null}
            </tr>
          </thead>
          <tbody>
            {data.schedules.map((schedule) => {
              const target =
                schedule.target === "task"
                  ? t.targetTask
                  : (schedule.agent_name ?? messages.project.unnamedAgent);
              return (
                <tr key={schedule.id}>
                  <td className="bft-col-target">
                    <a
                      className="bft-link"
                      href={schedule.href}
                      // An agent schedule opens the agent on the Agents page.
                      onClick={schedule.target === "agent" ? spaLinkClick : undefined}
                      title={target}
                    >
                      {target}
                    </a>
                  </td>
                  <td title={schedule.recurrence}>
                    {schedule.recurrence}
                    <div
                      className="bft-setting-row-sub bft-truncate"
                      title={schedule.prompt ?? undefined}
                    >
                      {schedule.target === "task"
                        ? t.runsTask
                        : (schedule.prompt ?? "—")}
                    </div>
                  </td>
                  <td
                    className="bft-col-refreshed"
                    title={schedule.last_run_at ?? undefined}
                  >
                    {(schedule.last_run_at && formatRelative(schedule.last_run_at)) ||
                      t.neverRun}
                  </td>
                  {manage ? (
                    <td className="bft-col-actions">
                      <Button
                        aria-label={t.deleteFor(target)}
                        hierarchy="tertiary-gray"
                        onPress={() =>
                          confirm.ask({
                            title: t.deleteTitle,
                            description: t.deleteBody,
                            confirmLabel: t.delete,
                            action: () =>
                              api.deleteSchedule(org, project, schedule.id).then(
                                setLatest,
                                // Already gone: show the list as it is now.
                                async (error: unknown) => {
                                  if (
                                    error instanceof BftApiError &&
                                    error.code === "schedule_not_found"
                                  )
                                    setLatest(await api.swarmSchedules(org, project));
                                  else throw error;
                                }
                              ),
                          })
                        }
                        size="xs"
                      >
                        {t.delete}
                      </Button>
                    </td>
                  ) : null}
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
      {data.truncated ? (
        <p className="bft-quiet">{t.schedulesTruncated(data.schedules.length)}</p>
      ) : null}
      {confirm.dialog}
    </ScrollArea>
  );
}

function NewTaskDialog({
  org,
  project,
  agents,
  onClose,
}: {
  org: string;
  project: string;
  agents: { id: string; name: string }[];
  onClose: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [title, setTitle] = useState("");
  const [agentId, setAgentId] = useState(agents[0]?.id ?? "");

  return (
    <FormDialog
      description={t.createBody}
      onClose={() => {
        if (!write.busy) onClose();
      }}
      onSubmit={() =>
        write.run(
          () =>
            api.createTask(org, project, { title: title.trim(), agent_id: agentId }),
          // Task detail is a LiveView page.
          (task) => window.location.assign(task.href)
        )
      }
      submitLabel={t.createConfirm}
      title={t.newTask}
      write={write}
    >
      <TextField
        disabled={write.busy}
        label={t.titleLabel}
        onChange={setTitle}
        placeholder={t.titlePlaceholder}
        value={title}
      />
      <Dropdown
        className="bft-form-field"
        disabled={write.busy}
        items={agents.map((agent) => ({ id: agent.id, label: agent.name }))}
        label={t.agentLabel}
        onChange={setAgentId}
        size="sm"
        value={agentId}
      />
    </FormDialog>
  );
}
