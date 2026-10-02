import { ScrollArea, ScrollAreaLoadMore } from "@comma/ui";
import { useEffect, useRef, useState } from "react";
import type {
  BftAuditEntry,
  BftAuditPage,
  BftHealth,
  BftHealthStatus,
  BftSignalStatus,
} from "./api";
import { formatRelative, humanize } from "./format";
import { messages } from "./messages";
import { RunnersPanel } from "./OverviewPage";
import type { Resource } from "./resource";
import { ErrorState, Skeleton } from "./states";

const t = messages.health;

type Tone = "ok" | "warn" | "error" | "neutral";

const statusTones: Record<BftHealthStatus, Tone> = {
  healthy: "ok",
  degraded: "warn",
  action_required: "warn",
  critical: "error",
  unknown: "neutral",
};

const signalTones: Record<BftSignalStatus, Tone> = {
  ok: "ok",
  degraded: "warn",
  unknown: "neutral",
};

const severityTone = (severity: string): Tone => {
  switch (severity.toLowerCase()) {
    case "critical":
    case "error":
      return "error";
    case "warning":
    case "warn":
    case "degraded":
      return "warn";
    default:
      return "neutral";
  }
};

const severityLabel = (severity: string) =>
  t.severities[severity.toLowerCase()] ?? humanize(severity);

function Severity({ value }: { value: string }) {
  return (
    <span className="bft-status" data-tone={severityTone(value)}>
      <span className="bft-truncate">{severityLabel(value)}</span>
    </span>
  );
}

const relative = (iso: string) => formatRelative(iso) ?? "—";

export function HealthPage({
  org,
  orgName,
  health,
  audit,
  onRetry,
  onRetryAudit,
  loadAudit,
}: {
  org: string;
  orgName: string | undefined;
  health: Resource<BftHealth>;
  audit: Resource<BftAuditPage>;
  onRetry: () => void;
  onRetryAudit: () => void;
  loadAudit: (cursor: string, signal: AbortSignal) => Promise<BftAuditPage>;
}) {
  const data = health.state === "ready" ? health.data : undefined;
  return (
    <div className="bft-page">
      <div className="bft-page-header">
        <div className="bft-page-heading">
          <h1>{t.title}</h1>
          <p>{orgName ? t.description(orgName) : <Skeleton width={220} />}</p>
        </div>
        <div className="bft-page-actions">
          {data ? (
            <a className="bft-btn" href={data.audit_export_href}>
              {t.exportAudit}
            </a>
          ) : null}
        </div>
      </div>
      {health.state === "error" ? (
        <div className="bft-panel bft-panel-fill">
          <ErrorState onRetry={onRetry} />
        </div>
      ) : (
        <div className="bft-overview-grid">
          <div className="bft-overview-main">
            <StatusPanel data={data} />
            <EventsPanel events={data?.events} />
          </div>
          <div className="bft-health-rail">
            <RunnersPanel org={org} runners={data?.runners} />
            <AuditPanel
              first={audit}
              key={org}
              loadMore={loadAudit}
              onRetry={onRetryAudit}
            />
          </div>
        </div>
      )}
    </div>
  );
}

function StatusPanel({ data }: { data: BftHealth | undefined }) {
  return (
    <section aria-labelledby="bft-health-status" className="bft-panel">
      <div className="bft-health-summary">
        {data ? (
          <>
            <h2 className="bft-health-status" id="bft-health-status">
              <span className="bft-sr-only">{t.statusTitle}: </span>
              <span className="bft-status" data-tone={statusTones[data.health.status]}>
                {t.statuses[data.health.status]}
              </span>
            </h2>
            {data.health.reasons.length > 0 ? (
              <ScrollArea
                edgeEffect="none"
                orientation="vertical"
                scrollbarVisibility="hover"
                viewportClassName="bft-health-reasons-viewport"
              >
                <ul className="bft-health-reasons">
                  {data.health.reasons.map((reason, index) => (
                    <li key={`${index}:${reason}`}>{reason}</li>
                  ))}
                </ul>
              </ScrollArea>
            ) : (
              <p className="bft-health-reasons">{t.noReasons}</p>
            )}
          </>
        ) : (
          <>
            <h2 className="bft-sr-only" id="bft-health-status">
              {t.statusTitle}
            </h2>
            <Skeleton height={18} width={160} />
            <Skeleton width="55%" />
          </>
        )}
      </div>
      <ul aria-label={t.signalsLabel} className="bft-signals">
        {data
          ? data.signals.map((signal) => (
              <li className="bft-signal" key={signal.key}>
                <div className="bft-signal-head">
                  <span
                    className="bft-status bft-signal-label"
                    data-tone={signalTones[signal.status]}
                    title={`${signal.label}: ${t.signalStatuses[signal.status]}`}
                  >
                    <span className="bft-truncate">{signal.label}</span>
                    <span className="bft-sr-only">
                      {" "}
                      {t.signalStatuses[signal.status]}
                    </span>
                  </span>
                  <span
                    className="bft-signal-time"
                    title={signal.observed_at ?? undefined}
                  >
                    {signal.observed_at ? relative(signal.observed_at) : t.notObserved}
                  </span>
                </div>
                <p className="bft-signal-detail" title={signal.detail}>
                  {signal.detail}
                </p>
              </li>
            ))
          : Array.from({ length: 4 }, (_, index) => (
              <li aria-busy="true" className="bft-signal" key={index}>
                <Skeleton width="50%" />
                <Skeleton width="80%" />
              </li>
            ))}
      </ul>
    </section>
  );
}

function RowsSkeleton({ rows = 3 }: { rows?: number }) {
  return (
    <div className="bft-rows-skeleton">
      {Array.from({ length: rows }, (_, index) => (
        <Skeleton height={14} key={index} />
      ))}
    </div>
  );
}

function EventsPanel({ events }: { events: BftHealth["events"] | undefined }) {
  return (
    <section
      aria-labelledby="bft-events-title"
      className="bft-panel bft-panel-table bft-panel-split"
    >
      <div className="bft-panel-header">
        <h2 id="bft-events-title">{t.eventsTitle}</h2>
        {events && events.length > 0 ? (
          <span className="bft-count">{events.length}</span>
        ) : null}
      </div>
      {!events ? (
        <RowsSkeleton />
      ) : events.length === 0 ? (
        <p className="bft-quiet">{t.eventsEmpty}</p>
      ) : (
        <ScrollArea
          className="bft-panel-scroll"
          edgeEffect="none"
          orientation="vertical"
          scrollbarVisibility="hover"
          viewportClassName="bft-scroll-viewport"
        >
          <table className="bft-table bft-events">
            <thead>
              <tr>
                <th className="bft-col-time" scope="col">
                  {t.columnTime}
                </th>
                <th className="bft-col-severity" scope="col">
                  {t.columnSeverity}
                </th>
                <th scope="col">{t.columnProblem}</th>
              </tr>
            </thead>
            <tbody>
              {events.map((event) => (
                <tr key={event.id}>
                  <td className="bft-col-time" title={event.occurred_at}>
                    {relative(event.occurred_at)}
                  </td>
                  <td className="bft-col-severity">
                    <Severity value={event.severity} />
                  </td>
                  <td>
                    {event.href ? (
                      <a className="bft-link" href={event.href} title={event.title}>
                        {event.title}
                      </a>
                    ) : (
                      <span className="bft-event-title" title={event.title}>
                        {event.title}
                      </span>
                    )}
                    <span className="bft-event-summary" title={event.summary}>
                      {event.summary}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </ScrollArea>
      )}
    </section>
  );
}

/** Pages appended after the first one, and the cursor for the next. */
interface AuditMore {
  entries: BftAuditEntry[];
  /** `undefined` until a page was appended: continue from the first page. */
  cursor: string | null | undefined;
}

function AuditPanel({
  first,
  onRetry,
  loadMore,
}: {
  first: Resource<BftAuditPage>;
  onRetry: () => void;
  loadMore: (cursor: string, signal: AbortSignal) => Promise<BftAuditPage>;
}) {
  const [more, setMore] = useState<AuditMore>({ entries: [], cursor: undefined });
  const [loading, setLoading] = useState(false);
  const [failed, setFailed] = useState(false);
  const controller = useRef<AbortController | null>(null);

  useEffect(() => () => controller.current?.abort(), []);

  const page = first.state === "ready" ? first.data : undefined;
  const entries = page ? [...page.entries, ...more.entries] : undefined;
  const cursor = more.cursor === undefined ? (page?.next_cursor ?? null) : more.cursor;

  const onLoadMore = () => {
    if (!cursor || loading || !entries) return;
    const abort = new AbortController();
    controller.current = abort;
    setLoading(true);
    setFailed(false);
    loadMore(cursor, abort.signal).then(
      (next) => {
        if (abort.signal.aborted) return;
        // A cursor can overlap the previous page; never render an entry twice.
        const seen = new Set(entries.map((entry) => entry.id));
        setMore((previous) => ({
          entries: [
            ...previous.entries,
            ...next.entries.filter((entry) => !seen.has(entry.id)),
          ],
          cursor: next.next_cursor,
        }));
        setLoading(false);
      },
      () => {
        if (abort.signal.aborted) return;
        setFailed(true);
        setLoading(false);
      }
    );
  };

  return (
    <section
      aria-labelledby="bft-audit-title"
      className="bft-panel bft-panel-table bft-audit"
    >
      <div className="bft-panel-header">
        <h2 id="bft-audit-title">{t.auditTitle}</h2>
      </div>
      {first.state === "error" ? (
        <ErrorState onRetry={onRetry} />
      ) : !entries ? (
        <RowsSkeleton rows={4} />
      ) : entries.length === 0 ? (
        <p className="bft-quiet">{t.auditEmpty}</p>
      ) : (
        <ScrollArea
          className="bft-panel-scroll"
          edgeEffect="none"
          orientation="vertical"
          scrollbarVisibility="hover"
          viewportClassName="bft-scroll-viewport"
        >
          <ul className="bft-list">
            {entries.map((entry) => (
              <li className="bft-audit-entry" key={entry.id}>
                <div className="bft-audit-line">
                  <span className="bft-audit-action bft-truncate" title={entry.action}>
                    {entry.action}
                  </span>
                  <span className="bft-audit-time" title={entry.created_at}>
                    {relative(entry.created_at)}
                  </span>
                </div>
                <div
                  className="bft-audit-meta bft-truncate"
                  title={`${entry.actor} · ${entry.resource}`}
                >
                  {entry.actor} · {entry.resource}
                </div>
              </li>
            ))}
          </ul>
          {/* The next page loads as the reader nears the end; BFT shows its
              own localized loading and failure rows around the trigger. */}
          <ScrollAreaLoadMore
            failed={failed}
            hasMore={cursor !== null}
            loading={loading}
            onLoadMore={onLoadMore}
            quiet
          />
          {loading ? (
            <output className="bft-quiet bft-audit-more">{t.auditLoadingMore}</output>
          ) : failed ? (
            <div className="bft-quiet-row bft-audit-more" role="alert">
              <p className="bft-quiet bft-quiet-inline">{t.auditLoadMoreFailed}</p>
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
