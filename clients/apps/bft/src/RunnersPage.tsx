import {
  Button,
  ChevronRightSmallIcon,
  Dialog,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  MoreHorizontalIcon,
  ScrollArea,
  ScrollAreaLoadMore,
} from "@comma/ui";
import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import type {
  BftInstallCommand,
  BftRunner,
  BftRunnerConnector,
  BftRunnerConnectors,
  BftRunnerOnboarding,
  BftRunnersPage,
  BftRunnerStatus,
} from "./api";
import {
  AddRunnerDialog,
  InstallCommand,
  installErrorMessage,
} from "./AddRunnerDialog";
import { ConfirmDialog, writeErrorMessage } from "./dialogs";
import { formatInteger, formatRelative, humanize } from "./format";
import { MetricCards } from "./MetricCards";
import { messages } from "./messages";
import type { Resource } from "./resource";
import { ErrorState, Skeleton } from "./states";

const t = messages.runners;

type Tone = "ok" | "warn" | "error" | "neutral";

export const runnerTones: Record<BftRunnerStatus, Tone> = {
  online: "ok",
  recently_lost: "warn",
  degraded: "warn",
  offline: "error",
  unknown: "neutral",
};

const connectorTone = (status: string): Tone => {
  switch (status) {
    case "connected":
    case "running":
      return "ok";
    case "failed":
    case "error":
      return "error";
    case "stopped":
      return "neutral";
    default:
      return "warn";
  }
};

export const runnerName = (runner: BftRunner) =>
  runner.name ?? runner.stable_id ?? t.unnamed;

export interface RunnerApi {
  page: (cursor: string | null, signal: AbortSignal) => Promise<BftRunnersPage>;
  connectors: (
    runnerId: string,
    cursor: string | null,
    signal: AbortSignal
  ) => Promise<BftRunnerConnectors>;
  onboarding: (signal: AbortSignal) => Promise<BftRunnerOnboarding>;
  createInstallCommand: () => Promise<BftInstallCommand>;
  rotateKey: (keyId: string) => Promise<BftInstallCommand>;
  revokeKey: (keyId: string) => Promise<unknown>;
  remove: (runnerId: string) => Promise<unknown>;
}

/** Runners of every loaded page, first occurrence wins across overlapping cursors. */
export function mergeRunnerPages(pages: readonly BftRunnersPage[]) {
  const seen = new Set<string>();
  return pages
    .flatMap((page) => page.runners)
    .filter((runner) => (seen.has(runner.id) ? false : (seen.add(runner.id), true)));
}

/**
 * The loaded pages of the fleet, appended on scroll and refreshed every
 * `poll_interval_ms` while the tab is visible. A refresh re-reads as many pages
 * as are loaded, so rows keep their place and open dialogs stay untouched.
 */
function useFleet(first: Resource<BftRunnersPage>, api: RunnerApi) {
  const [pages, setPages] = useState<BftRunnersPage[] | null>(null);
  const [more, setMore] = useState({ loading: false, failed: false });
  const base = first.state === "ready" ? first.data : undefined;
  const current = pages ?? (base ? [base] : null);
  const currentRef = useRef(current);
  currentRef.current = current;
  const refreshing = useRef<AbortController | null>(null);
  const appending = useRef<AbortController | null>(null);
  const loadPage = useRef(api.page);
  loadPage.current = api.page;

  /** Re-reads the loaded pages; `force` replaces a poll already in flight. */
  const refresh = useCallback(async (force = false) => {
    const loaded = currentRef.current;
    if (!loaded) return;
    if (refreshing.current) {
      if (!force) return;
      refreshing.current.abort();
    }
    const controller = new AbortController();
    refreshing.current = controller;
    try {
      const next: BftRunnersPage[] = [];
      let cursor: string | null = null;
      for (let index = 0; index < loaded.length; index += 1) {
        const page: BftRunnersPage = await loadPage.current(cursor, controller.signal);
        next.push(page);
        cursor = page.next_cursor;
        if (!cursor) break;
      }
      if (controller.signal.aborted) return;
      setPages((previous) => {
        const known = previous ?? loaded;
        // A page appended while this refresh ran stays.
        return known.length > next.length && next.at(-1)?.next_cursor
          ? [...next, ...known.slice(next.length)]
          : next;
      });
    } catch {
      // A failed poll keeps the last good list; the next one tries again.
    } finally {
      if (refreshing.current === controller) refreshing.current = null;
    }
  }, []);

  const interval = current?.[0]?.poll_interval_ms ?? 5_000;
  const ready = base !== undefined;

  useEffect(() => {
    if (!ready) return undefined;
    let timer: number | undefined;
    let stopped = false;
    // One loop at a time: a tick while a poll runs leaves rescheduling to it.
    let polling = false;
    const tick = () => {
      if (polling || document.visibilityState !== "visible") return;
      polling = true;
      void refresh().finally(() => {
        polling = false;
        window.clearTimeout(timer);
        if (!stopped) timer = window.setTimeout(tick, interval);
      });
    };
    const onVisibility = () => {
      window.clearTimeout(timer);
      if (document.visibilityState === "visible") tick();
    };
    timer = window.setTimeout(tick, interval);
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stopped = true;
      window.clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibility);
      refreshing.current?.abort();
      refreshing.current = null;
    };
  }, [ready, interval, refresh]);

  useEffect(() => () => appending.current?.abort(), []);

  const cursor = current?.at(-1)?.next_cursor ?? null;
  const loadMore = () => {
    const loaded = currentRef.current;
    if (!cursor || !loaded || more.loading) return;
    const controller = new AbortController();
    appending.current = controller;
    setMore({ loading: true, failed: false });
    loadPage.current(cursor, controller.signal).then(
      (page) => {
        if (controller.signal.aborted) return;
        setPages((previous) => [...(previous ?? loaded), page]);
        setMore({ loading: false, failed: false });
      },
      () => {
        if (controller.signal.aborted) return;
        setMore({ loading: false, failed: true });
      }
    );
  };

  return {
    first: current?.[0],
    runners: current ? mergeRunnerPages(current) : undefined,
    hasMore: cursor !== null,
    more,
    loadMore,
    refresh,
  };
}

type Pending =
  | { kind: "add" }
  | { kind: "rotate" | "revoke" | "remove"; runner: BftRunner }
  | { kind: "issued"; runner: BftRunner; command: BftInstallCommand };

export function RunnersPage({
  org,
  orgName,
  first,
  onRetry,
  api,
}: {
  org: string;
  orgName: string | undefined;
  first: Resource<BftRunnersPage>;
  onRetry: () => void;
  api: RunnerApi;
}) {
  const fleet = useFleet(first, api);
  const [pending, setPending] = useState<Pending | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [expanded, setExpanded] = useState<string | null>(null);
  const canManage = fleet.first?.viewer.can_manage ?? false;

  const open = (next: Pending) => {
    setError(undefined);
    setPending(next);
  };
  const close = () => {
    if (busy) return;
    setPending(null);
    setError(undefined);
  };

  const confirm = () => {
    if (!pending || pending.kind === "add" || pending.kind === "issued") return;
    const { kind, runner } = pending;
    const keyId = runner.credential?.key_id;
    setBusy(true);
    setError(undefined);
    const write: Promise<BftInstallCommand | undefined> =
      kind === "remove"
        ? api.remove(runner.id).then(() => undefined)
        : keyId
          ? kind === "rotate"
            ? api.rotateKey(keyId)
            : api.revokeKey(keyId).then(() => undefined)
          : Promise.reject(new Error("The runner has no active key."));
    write.then(
      (command) => {
        setBusy(false);
        setPending(command ? { kind: "issued", runner, command } : null);
        void fleet.refresh(true);
      },
      (caught: unknown) => {
        setBusy(false);
        setError(
          kind === "rotate" ? installErrorMessage(caught) : writeErrorMessage(caught)
        );
      }
    );
  };

  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <h1>{t.title}</h1>
          <p>{orgName ? t.description(orgName) : <Skeleton width={220} />}</p>
        </div>
        <div className="bft-page-actions">
          {canManage ? (
            <button
              className="bft-btn bft-btn-primary"
              onClick={() => open({ kind: "add" })}
              type="button"
            >
              {t.add}
            </button>
          ) : null}
        </div>
      </div>
      {first.state === "error" && !fleet.runners ? (
        <div className="bft-panel bft-panel-fill">
          <ErrorState onRetry={onRetry} />
        </div>
      ) : (
        <>
          <Summary fleet={fleet} />
          <FleetPanel
            api={api}
            canManage={canManage}
            expanded={expanded}
            fleet={fleet}
            onAction={(kind, runner) => open({ kind, runner })}
            onToggle={(id) => setExpanded((value) => (value === id ? null : id))}
          />
        </>
      )}
      {pending?.kind === "add" ? (
        <AddRunnerDialog
          createCommand={api.createInstallCommand}
          loadOnboarding={api.onboarding}
          onClose={close}
          org={org}
        />
      ) : null}
      {pending?.kind === "rotate" ? (
        <ConfirmDialog
          busy={busy}
          confirmLabel={t.rotateConfirm}
          description={t.rotateBody(runnerName(pending.runner))}
          error={error}
          onClose={close}
          onConfirm={confirm}
          title={t.rotateTitle}
        />
      ) : null}
      {pending?.kind === "revoke" ? (
        <ConfirmDialog
          busy={busy}
          confirmLabel={t.revokeConfirm}
          description={t.revokeBody(runnerName(pending.runner))}
          destructive
          error={error}
          onClose={close}
          onConfirm={confirm}
          title={t.revokeTitle}
        />
      ) : null}
      {pending?.kind === "remove" ? (
        <ConfirmDialog
          busy={busy}
          confirmLabel={t.removeConfirm}
          description={t.removeBody(runnerName(pending.runner))}
          destructive
          error={error}
          onClose={close}
          onConfirm={confirm}
          title={t.removeTitle}
        />
      ) : null}
      {pending?.kind === "issued" ? (
        <Dialog
          actions={[{ label: t.done, hierarchy: "secondary-gray", onPress: close }]}
          className="bft-dialog-wide"
          description={t.newCommandBody(runnerName(pending.runner))}
          // The old key is already revoked and this command shows only once,
          // so only Done closes it.
          isDismissable={false}
          isOpen
          onOpenChange={() => undefined}
          title={t.newCommandTitle}
        >
          <InstallCommand issued={pending.command} />
        </Dialog>
      ) : null}
    </div>
  );
}

type Fleet = ReturnType<typeof useFleet>;

function Summary({ fleet }: { fleet: Fleet }) {
  const runners = fleet.runners;
  const partial = fleet.hasMore && runners ? t.metricLoaded(runners.length) : undefined;
  const count = (predicate: (runner: BftRunner) => boolean) =>
    formatInteger(runners?.filter(predicate).length ?? 0);
  return (
    <MetricCards
      cards={
        runners &&
        fleet.first && [
          { label: t.metricTotal, value: formatInteger(fleet.first.total_count) },
          {
            label: t.metricOnline,
            value: count((runner) => runner.effective_status === "online"),
            ...(partial ? { detail: partial } : {}),
          },
          {
            label: t.metricUpdates,
            value: count((runner) => runner.update_available),
            ...(partial ? { detail: partial } : {}),
          },
          {
            label: t.metricConnectors,
            value: formatInteger(
              runners.reduce((sum, runner) => sum + runner.connectors.total, 0)
            ),
            ...(partial ? { detail: partial } : {}),
          },
        ]
      }
    />
  );
}

function FleetPanel({
  fleet,
  api,
  canManage,
  expanded,
  onToggle,
  onAction,
}: {
  fleet: Fleet;
  api: RunnerApi;
  canManage: boolean;
  expanded: string | null;
  onToggle: (id: string) => void;
  onAction: (kind: "rotate" | "revoke" | "remove", runner: BftRunner) => void;
}) {
  const runners = fleet.runners;
  const columns = canManage ? 6 : 5;
  return (
    <section aria-labelledby="bft-fleet-title" className="bft-panel bft-panel-table">
      <div className="bft-panel-header">
        <h2 id="bft-fleet-title">{t.listTitle}</h2>
        {fleet.first ? (
          <span className="bft-count">{formatInteger(fleet.first.total_count)}</span>
        ) : null}
      </div>
      {!runners ? (
        <div className="bft-rows-skeleton">
          {Array.from({ length: 4 }, (_, index) => (
            <Skeleton height={14} key={index} />
          ))}
        </div>
      ) : runners.length === 0 ? (
        <div className="bft-state">
          <h2>{t.emptyTitle}</h2>
          <p>{canManage ? t.emptyBody : t.emptyMemberBody}</p>
        </div>
      ) : (
        <ScrollArea
          className="bft-panel-scroll"
          edgeEffect="none"
          orientation="vertical"
          scrollbarVisibility="hover"
          viewportClassName="bft-scroll-viewport"
        >
          <table className="bft-table bft-runners">
            <thead>
              <tr>
                <th scope="col">{t.columnName}</th>
                <th className="bft-col-runner-status" scope="col">
                  {t.columnStatus}
                </th>
                <th className="bft-col-version" scope="col">
                  {t.columnVersion}
                </th>
                <th className="bft-col-num bft-col-connectors" scope="col">
                  {t.columnConnectors}
                </th>
                <th className="bft-col-refreshed" scope="col">
                  {t.columnLastSeen}
                </th>
                {canManage ? (
                  <th className="bft-col-menu" scope="col">
                    <span className="bft-sr-only">{t.columnActions}</span>
                  </th>
                ) : null}
              </tr>
            </thead>
            <tbody>
              {runners.map((runner) => (
                <Fragment key={runner.id}>
                  <RunnerRow
                    canManage={canManage}
                    expanded={expanded === runner.id}
                    onAction={onAction}
                    onToggle={() => onToggle(runner.id)}
                    runner={runner}
                  />
                  {expanded === runner.id ? (
                    <tr className="bft-runner-detail-row">
                      <td colSpan={columns} id={`bft-runner-${runner.id}`}>
                        <RunnerDetail api={api} runner={runner} />
                      </td>
                    </tr>
                  ) : null}
                </Fragment>
              ))}
            </tbody>
          </table>
          <ScrollAreaLoadMore
            failed={fleet.more.failed}
            hasMore={fleet.hasMore}
            loading={fleet.more.loading}
            onLoadMore={fleet.loadMore}
            quiet
          />
          {fleet.more.loading ? (
            <output className="bft-quiet bft-audit-more">{t.loadingMore}</output>
          ) : fleet.more.failed ? (
            <div className="bft-quiet-row bft-audit-more" role="alert">
              <p className="bft-quiet bft-quiet-inline">{t.loadMoreFailed}</p>
              <button
                className="bft-btn bft-btn-sm"
                onClick={fleet.loadMore}
                type="button"
              >
                {messages.states.retry}
              </button>
            </div>
          ) : null}
        </ScrollArea>
      )}
    </section>
  );
}

function RunnerRow({
  runner,
  canManage,
  expanded,
  onToggle,
  onAction,
}: {
  runner: BftRunner;
  canManage: boolean;
  expanded: boolean;
  onToggle: () => void;
  onAction: (kind: "rotate" | "revoke" | "remove", runner: BftRunner) => void;
}) {
  const name = runnerName(runner);
  const host = [runner.host_identity, runner.os_summary].filter(Boolean).join(" · ");
  const seen = runner.last_seen_at ? formatRelative(runner.last_seen_at) : undefined;
  const keyActive = runner.credential?.active === true && !!runner.credential.key_id;
  return (
    <tr data-expanded={expanded || undefined}>
      <td>
        <button
          aria-controls={expanded ? `bft-runner-${runner.id}` : undefined}
          aria-expanded={expanded}
          aria-label={t.showConnectors(name)}
          className="bft-runner-toggle"
          onClick={onToggle}
          type="button"
        >
          <ChevronRightSmallIcon className="bft-runner-chevron" />
          <span className="bft-runner-name">
            <span className="bft-truncate" title={name}>
              {name}
            </span>
            {host ? (
              <span className="bft-runner-host bft-truncate" title={host}>
                {host}
              </span>
            ) : null}
          </span>
        </button>
      </td>
      <td className="bft-col-runner-status">
        <RunnerStatus status={runner.effective_status} />
      </td>
      <td className="bft-col-version">
        <span className="bft-runner-version">
          <span className="bft-truncate" title={runner.version ?? undefined}>
            {runner.version ?? "—"}
          </span>
          {runner.update_available ? (
            <span className="bft-update">{t.updateAvailable}</span>
          ) : null}
        </span>
      </td>
      <td className="bft-col-num bft-col-connectors">
        {formatInteger(runner.connectors.total)}
      </td>
      <td className="bft-col-refreshed" title={runner.last_seen_at ?? undefined}>
        {seen ?? t.never}
      </td>
      {canManage ? (
        <td className="bft-col-menu">
          <MenuTrigger>
            <Button
              aria-label={t.actionsFor(name)}
              hierarchy="tertiary-gray"
              iconLeading={<MoreHorizontalIcon />}
              iconOnly
              size="xs"
            />
            <MenuPopover className="bft-menu-popover" placement="bottom end">
              <Menu aria-label={t.actionsFor(name)}>
                <MenuItem
                  id="rotate"
                  isDisabled={!keyActive}
                  onAction={() => onAction("rotate", runner)}
                >
                  {t.rotateKey}
                </MenuItem>
                <MenuItem
                  id="revoke"
                  isDisabled={!keyActive}
                  onAction={() => onAction("revoke", runner)}
                >
                  {t.revokeKey}
                </MenuItem>
                <MenuSeparator />
                <MenuItem
                  id="remove"
                  onAction={() => onAction("remove", runner)}
                  tone="destructive"
                >
                  {t.removeRunner}
                </MenuItem>
              </Menu>
            </MenuPopover>
          </MenuTrigger>
        </td>
      ) : null}
    </tr>
  );
}

function RunnerStatus({ status }: { status: BftRunnerStatus }) {
  return (
    <span className="bft-status" data-tone={runnerTones[status]}>
      <span className="bft-truncate">{t.statuses[status]}</span>
    </span>
  );
}

function RunnerDetail({ runner, api }: { runner: BftRunner; api: RunnerApi }) {
  const components = Object.entries(runner.component_versions);
  const credential = runner.credential;
  const keyCreated = credential?.created_at
    ? formatRelative(credential.created_at)
    : undefined;
  return (
    <div className="bft-runner-detail">
      <dl className="bft-kv bft-runner-facts">
        {runner.host_identity || runner.os_summary ? (
          <div>
            <dt>{t.detailHost}</dt>
            <dd>
              {[runner.host_identity, runner.os_summary].filter(Boolean).join(" · ")}
            </dd>
          </div>
        ) : null}
        <div>
          <dt>{t.detailCapacity}</dt>
          <dd>{t.capacityValue(runner.current_connector_count, runner.capacity)}</dd>
        </div>
        {components.length > 0 ? (
          <div>
            <dt>{t.detailComponents}</dt>
            <dd title={components.map(([key, value]) => `${key} ${value}`).join(", ")}>
              {components.map(([key, value]) => `${key} ${value}`).join(", ")}
            </dd>
          </div>
        ) : null}
        {credential ? (
          <div>
            <dt>{t.detailKey}</dt>
            <dd>
              {credential.active
                ? keyCreated
                  ? t.keyActive(keyCreated)
                  : t.keyActiveUndated
                : t.keyNone}
            </dd>
          </div>
        ) : null}
      </dl>
      <ConnectorList api={api} runner={runner} />
    </div>
  );
}

function ConnectorList({ runner, api }: { runner: BftRunner; api: RunnerApi }) {
  const [entries, setEntries] = useState<BftRunnerConnector[]>();
  const [cursor, setCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [failed, setFailed] = useState(false);
  const controller = useRef<AbortController | null>(null);
  const load = useRef(api.connectors);
  load.current = api.connectors;

  const fetchPage = useCallback(
    (after: string | null) => {
      const abort = new AbortController();
      controller.current?.abort();
      controller.current = abort;
      setLoading(true);
      setFailed(false);
      load.current(runner.id, after, abort.signal).then(
        (page) => {
          if (abort.signal.aborted) return;
          setEntries((previous) => {
            const known = after ? (previous ?? []) : [];
            const seen = new Set(known.map((entry) => entry.id));
            return [...known, ...page.entries.filter((entry) => !seen.has(entry.id))];
          });
          setCursor(page.next_cursor);
          setLoading(false);
        },
        () => {
          if (abort.signal.aborted) return;
          setFailed(true);
          setLoading(false);
        }
      );
    },
    [runner.id]
  );

  useEffect(() => {
    fetchPage(null);
    return () => controller.current?.abort();
  }, [fetchPage]);

  const onLoadMore = () => {
    if (cursor && !loading) fetchPage(cursor);
  };

  return (
    <section aria-label={t.connectorsTitle} className="bft-connectors">
      <h3 className="bft-connectors-title">
        {t.connectorsTitle}
        <span className="bft-count">{formatInteger(runner.connectors.total)}</span>
      </h3>
      {!entries ? (
        failed ? (
          <div className="bft-quiet-row bft-connectors-state" role="alert">
            <p className="bft-quiet bft-quiet-inline">{t.connectorsLoadFailed}</p>
            <button
              className="bft-btn bft-btn-sm"
              onClick={() => fetchPage(null)}
              type="button"
            >
              {messages.states.retry}
            </button>
          </div>
        ) : (
          <div className="bft-rows-skeleton bft-rows-skeleton-flush">
            <Skeleton height={12} width="60%" />
            <Skeleton height={12} width="45%" />
          </div>
        )
      ) : entries.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.connectorsEmpty}</p>
      ) : (
        <ScrollArea
          className="bft-connectors-scroll"
          edgeEffect="none"
          orientation="vertical"
          scrollbarVisibility="hover"
          viewportClassName="bft-connectors-viewport"
        >
          <ul className="bft-connector-list">
            {entries.map((entry) => (
              <li className="bft-connector" key={entry.id}>
                <span
                  className="bft-truncate bft-connector-name"
                  title={entry.name ?? entry.id}
                >
                  {entry.name ?? entry.id}
                </span>
                <span
                  className="bft-truncate bft-connector-swarm"
                  title={entry.project_name ?? undefined}
                >
                  {entry.project_name ?? t.noSwarm}
                </span>
                <span
                  className="bft-status bft-connector-status"
                  data-tone={connectorTone(entry.provisioning_status)}
                >
                  <span className="bft-truncate">
                    {t.connectorStatuses[entry.provisioning_status] ??
                      humanize(entry.provisioning_status)}
                  </span>
                </span>
              </li>
            ))}
          </ul>
          <ScrollAreaLoadMore
            failed={failed}
            hasMore={cursor !== null}
            loading={loading}
            onLoadMore={onLoadMore}
            quiet
          />
          {loading ? (
            <output className="bft-quiet bft-connectors-more">
              {t.connectorsLoadingMore}
            </output>
          ) : failed ? (
            <div className="bft-quiet-row bft-connectors-more" role="alert">
              <p className="bft-quiet bft-quiet-inline">{t.connectorsLoadFailed}</p>
              <button className="bft-btn bft-btn-sm" onClick={onLoadMore} type="button">
                {messages.states.retry}
              </button>
            </div>
          ) : null}
        </ScrollArea>
      )}
    </section>
  );
}
