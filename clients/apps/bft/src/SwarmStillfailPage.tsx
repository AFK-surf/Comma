import { Button } from "@comma/ui/components/Button";
import { Dropdown } from "@comma/ui/components/dropdown";
import { useEffect, useRef, useState } from "react";
import type { BftSwarmStillfail } from "./api";
import { CodeBlock, CopyButton, writeErrorMessage } from "./dialogs";
import { showFlash } from "./flash";
import { formatCompact, formatInteger, formatRelative } from "./format";
import { messages } from "./messages";
import { projectHref } from "./navSpec";
import { useApi, useLastReady, type Resource } from "./resource";
import { FormSection, SettingsPage, useConfirm } from "./settingsForm";
import { StaleNotice } from "./states";

const t = messages.swarmStillfail;

const money = new Intl.NumberFormat(undefined, {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 2,
});

// The usage view of every station together (Dropdown ids cannot be empty).
const allStations = "all";

type Station = BftSwarmStillfail["stations"][number];
type StillfailTask = BftSwarmStillfail["tasks"][number];
type UsageRow = BftSwarmStillfail["usage"][number];

const systemCardKinds = new Set([
  "login",
  "secret",
  "vault",
  "signin",
  "device",
  "adb",
  "rig",
]);

const stationName = (station: Station) => station.name ?? "Monoid";

function taskState(task: StillfailTask): {
  label: string;
  tone?: "ok" | "warn" | "error";
} {
  if (task.attention === "need") {
    if (task.card_kind && systemCardKinds.has(task.card_kind)) {
      return { label: t.stateAuth, tone: "warn" };
    }
    return { label: t.stateWaitingReply, tone: "warn" };
  }
  if (task.attention === null && task.status === "needs_review") {
    return { label: t.stateWaitingReply, tone: "warn" };
  }
  if (task.attention === "failed") return { label: t.stateFailed, tone: "error" };
  if (task.attention === "done") return { label: t.stateDone, tone: "ok" };
  return { label: t.stateRunning };
}

/**
 * An Agent Swarm's still.fail stations, each one still.fail workspace
 * connected through its Comma connect with a line this page gives: whether it
 * is connected now, and what still.fail's agents spent by person, of every
 * station or of one. Admins make a line, disconnect one station, or remove
 * them all.
 */
export function SwarmStillfailPage({
  org,
  project,
  first,
  onRetry,
}: {
  org: string;
  project: string;
  first: Resource<BftSwarmStillfail>;
  onRetry: () => void;
}) {
  const api = useApi();
  const { data, resource, stale } = useLastReady(first);
  const confirm = useConfirm();
  const [busy, setBusy] = useState(false);
  // The line made last, shown until the page is left: it is not given again.
  const [line, setLine] = useState<string | null>(null);
  const path = projectHref(org, project, "/stillfail");

  const fail = (error: unknown) => {
    setBusy(false);
    showFlash({ kind: "error", text: writeErrorMessage(error) ?? "" }, path);
    onRetry();
  };

  const makeLine = () => {
    setBusy(true);
    api.stillfailLine(org, project).then((made) => {
      setBusy(false);
      setLine(made.line);
    }, fail);
  };

  const remove = () => {
    setBusy(true);
    api.removeStillfail(org, project).then(({ notice }) => {
      setBusy(false);
      setLine(null);
      showFlash({ kind: "info", text: notice }, path);
      onRetry();
    }, fail);
  };

  const disconnect = (station: Station) =>
    confirm.ask({
      title: t.disconnectTitle,
      description: t.disconnectBody(stationName(station)),
      confirmLabel: t.disconnect,
      action: () =>
        api.removeStillfailStation(org, project, station.id).then(({ notice }) => {
          showFlash({ kind: "info", text: notice }, path);
          onRetry();
        }),
    });

  return (
    <SettingsPage
      description={data ? t.description(data.project.name) : undefined}
      onRetry={onRetry}
      resource={resource}
      title={t.title}
      wide
    >
      {(page) => (
        <>
          {stale ? <StaleNotice onRetry={onRetry} /> : null}
          <Stations
            busy={busy}
            line={line}
            manage={page.project.role === "admin"}
            onDisconnect={disconnect}
            onLine={makeLine}
            onRemove={remove}
            page={page}
          />
          <Tasks org={org} page={page} project={project} />
          <Usage org={org} page={page} project={project} />
          {confirm.dialog}
        </>
      )}
    </SettingsPage>
  );
}

function Stations({
  page,
  manage,
  busy,
  line,
  onLine,
  onRemove,
  onDisconnect,
}: {
  page: BftSwarmStillfail;
  manage: boolean;
  busy: boolean;
  line: string | null;
  onLine: () => void;
  onRemove: () => void;
  onDisconnect: (station: Station) => void;
}) {
  const { stations } = page;
  const hasOffline = stations.some(
    (station) => !station.connected && station.connected_at !== null
  );

  return (
    <FormSection title={t.stations}>
      {stations.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">
          {manage ? t.noStations : t.noStationsMember}
        </p>
      ) : (
        <table className="bft-table">
          <thead>
            <tr>
              <th scope="col">{t.name}</th>
              <th scope="col">{t.state}</th>
              <th scope="col">{t.since}</th>
              {manage ? (
                <th className="bft-col-actions" scope="col">
                  <span className="bft-sr-only">{t.actions}</span>
                </th>
              ) : null}
            </tr>
          </thead>
          <tbody>
            {stations.map((station) => (
              <tr key={station.id}>
                <td>{stationName(station)}</td>
                <td>{station.connected ? t.connected : t.offline}</td>
                <td>
                  {station.connected_at
                    ? formatRelative(new Date(station.connected_at).toISOString())
                    : t.never}
                </td>
                {manage ? (
                  <td className="bft-col-actions">
                    <Button
                      aria-label={t.disconnectFor(stationName(station))}
                      hierarchy="tertiary-gray"
                      isDisabled={busy}
                      onPress={() => onDisconnect(station)}
                      size="xs"
                    >
                      {t.disconnect}
                    </Button>
                  </td>
                ) : null}
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {hasOffline ? (
        <p className="bft-quiet bft-quiet-inline">{t.offlineNotice}</p>
      ) : null}
      {manage && line !== null ? (
        <div>
          <p className="bft-quiet bft-quiet-inline">{t.lineHint}</p>
          <CodeBlock label={t.line} text={line} />
          <CopyButton label={t.line} text={line} />
        </div>
      ) : null}
      {manage ? (
        <div className="bft-inline-actions">
          <button className="bft-btn" disabled={busy} onClick={onLine} type="button">
            {busy ? t.working : t.addStation}
          </button>
          {stations.length > 1 ? (
            <button
              className="bft-btn"
              disabled={busy}
              onClick={onRemove}
              type="button"
            >
              {t.remove}
            </button>
          ) : null}
        </div>
      ) : null}
    </FormSection>
  );
}

/**
 * Monoid tasks needing attention or active in the last 24 hours: every
 * station's together, or, with two or more stations, one station's as the
 * viewer picks it (queried from the server by `device_id`, like `Usage`).
 */
function Tasks({
  org,
  project,
  page,
}: {
  org: string;
  project: string;
  page: BftSwarmStillfail;
}) {
  const api = useApi();
  const [station, setStation] = useState(allStations);
  const [picked, setPicked] = useState<{
    page: BftSwarmStillfail;
    station: string;
    tasks?: StillfailTask[];
    error?: string;
  } | null>(null);
  const stations = page.stations;
  const shown =
    stations.length > 1 && stations.some((s) => s.id === station)
      ? station
      : allStations;

  useEffect(() => {
    if (shown === allStations) return;
    const controller = new AbortController();
    api.swarmStillfail(org, project, controller.signal, shown).then(
      (answer) => setPicked({ page, station: shown, tasks: answer.tasks }),
      (error: unknown) => {
        if (!controller.signal.aborted)
          setPicked({ page, station: shown, error: writeErrorMessage(error) ?? "" });
      }
    );
    return () => controller.abort();
  }, [api, org, project, page, shown]);

  const current = picked?.page === page && picked.station === shown ? picked : null;
  const fresh = shown === allStations ? page.tasks : current?.tasks;
  // While another station's tasks load, the rows shown last stay, marked busy.
  const last = useRef(page.tasks);
  if (fresh) last.current = fresh;
  const tasks = fresh ?? last.current;
  const busy = fresh === undefined && !current?.error;

  return (
    <FormSection
      action={
        stations.length > 1 ? (
          <Dropdown
            ariaLabel={t.tasksOf}
            items={[
              { id: allStations, label: t.allWorkspaces },
              ...stations.map((s) => ({ id: s.id, label: stationName(s) })),
            ]}
            onChange={setStation}
            size="xs"
            value={shown}
            width="content"
          />
        ) : null
      }
      title={t.tasks}
    >
      {current?.error ? (
        <p className="bft-quiet bft-quiet-inline" role="alert">
          {current.error}
        </p>
      ) : tasks.length === 0 ? (
        <p aria-busy={busy || undefined} className="bft-quiet bft-quiet-inline">
          {t.noTasks}
        </p>
      ) : (
        <table aria-busy={busy || undefined} className="bft-table">
          <thead>
            <tr>
              <th scope="col">{t.task}</th>
              <th className="bft-stillfail-col-state" scope="col">
                {t.taskState}
              </th>
              <th className="bft-stillfail-col-waiting" scope="col">
                {t.waitingOn}
              </th>
              <th className="bft-stillfail-col-updated" scope="col">
                {t.updated}
              </th>
            </tr>
          </thead>
          <tbody>
            {tasks.map((task) => {
              const state = taskState(task);
              const waiting =
                task.waits_for.length > 0
                  ? task.waits_for.join(", ")
                  : (task.created_by ?? "—");
              return (
                <tr key={task.id}>
                  <td>
                    <a
                      className="bft-link"
                      href={task.url}
                      rel="noopener noreferrer"
                      target="_blank"
                      title={task.title}
                    >
                      {task.title}
                    </a>
                    {task.note ? (
                      <div
                        className="bft-stillfail-task-note bft-truncate"
                        title={task.note}
                      >
                        {task.note}
                      </div>
                    ) : null}
                  </td>
                  <td className="bft-stillfail-col-state">
                    <span className="bft-status" data-tone={state.tone}>
                      {state.label}
                    </span>
                  </td>
                  <td className="bft-stillfail-col-waiting">
                    <div className="bft-truncate" title={waiting}>
                      {waiting}
                    </div>
                  </td>
                  <td className="bft-stillfail-col-updated">
                    {task.last_activity_at !== null
                      ? formatRelative(new Date(task.last_activity_at).toISOString())
                      : "—"}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </FormSection>
  );
}

/**
 * What still.fail's agents spent by person: every station's together, or, with
 * two or more stations, one station's as the viewer picks it (the page asked
 * again with that station).
 */
function Usage({
  org,
  project,
  page,
}: {
  org: string;
  project: string;
  page: BftSwarmStillfail;
}) {
  const api = useApi();
  const [station, setStation] = useState(allStations);
  // One station's usage as last read, for the page it was read with: a page
  // read again (after a disconnect) reads it again.
  const [picked, setPicked] = useState<{
    page: BftSwarmStillfail;
    station: string;
    usage?: UsageRow[];
    error?: string;
  } | null>(null);
  const stations = page.stations;
  // The picker shows with two stations or more; with fewer it is every station's.
  const shown =
    stations.length > 1 && stations.some((s) => s.id === station)
      ? station
      : allStations;

  useEffect(() => {
    if (shown === allStations) return;
    const controller = new AbortController();
    api.swarmStillfail(org, project, controller.signal, shown).then(
      (answer) => setPicked({ page, station: shown, usage: answer.usage }),
      (error: unknown) => {
        if (!controller.signal.aborted)
          setPicked({ page, station: shown, error: writeErrorMessage(error) ?? "" });
      }
    );
    return () => controller.abort();
  }, [api, org, project, page, shown]);

  const current = picked?.page === page && picked.station === shown ? picked : null;
  const fresh = shown === allStations ? page.usage : current?.usage;
  // While another station's usage loads, the rows shown last stay, marked busy.
  const last = useRef(page.usage);
  if (fresh) last.current = fresh;
  const usage = fresh ?? last.current;
  const busy = fresh === undefined && !current?.error;

  return (
    <FormSection
      action={
        stations.length > 1 ? (
          <Dropdown
            ariaLabel={t.usageOf}
            items={[
              { id: allStations, label: t.allWorkspaces },
              ...stations.map((s) => ({ id: s.id, label: stationName(s) })),
            ]}
            onChange={setStation}
            size="xs"
            value={shown}
            width="content"
          />
        ) : null
      }
      title={t.usage(page.days)}
    >
      {current?.error ? (
        <p className="bft-quiet bft-quiet-inline" role="alert">
          {current.error}
        </p>
      ) : usage.length === 0 ? (
        <p aria-busy={busy || undefined} className="bft-quiet bft-quiet-inline">
          {t.noUsage}
        </p>
      ) : (
        <table aria-busy={busy || undefined} className="bft-table">
          <thead>
            <tr>
              <th scope="col">{t.person}</th>
              <th scope="col">{t.calls}</th>
              <th scope="col">{t.tokens}</th>
              <th scope="col">{t.cost}</th>
            </tr>
          </thead>
          <tbody>
            {usage.map((row) => (
              <tr key={row.key ?? ""}>
                <td>{row.key ?? t.unknownPerson}</td>
                <td>{formatInteger(row.calls)}</td>
                <td
                  title={formatInteger(
                    row.input + row.cache_read + row.cache_write + row.output
                  )}
                >
                  {formatCompact(
                    row.input + row.cache_read + row.cache_write + row.output
                  )}
                </td>
                <td>{row.cost === null ? "—" : money.format(row.cost)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </FormSection>
  );
}
