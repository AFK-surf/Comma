import {
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
  type HTMLAttributes,
} from "react";
import { Tooltip } from "@comma/ui";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { SessionHistoryRecord } from "../../../../runtime-chat/sessionHistoryBridge";
import {
  formatSessionDuration,
  type SessionItemPresentation,
} from "../model/sessionHistoryPresentation";
import type { SessionTimelineSpan } from "./sessionHistoryTimelineModel";
import { useSessionToolLabel } from "../model/sessionHistoryToolLabel";
import { SessionModelMetrics } from "../SessionModelMetrics";
import { useSessionOperation } from "../SessionOperationContext";

const compactDuration = (value: number | undefined) =>
  formatSessionDuration(
    value !== undefined && value >= 1000 ? Math.round(value / 100) * 100 : value
  );

/** One inspector per chart, regardless of the number of visible bars. It reads
 * the current projection so SSE updates and the shared clock also update an open card. */
export function useSessionTimelineHover(
  spans: readonly SessionTimelineSpan[],
  records: readonly SessionHistoryRecord[],
  items: readonly SessionItemPresentation[]
) {
  const [active, setActive] = useState<{ id: string; element: HTMLElement }>();
  const closing = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const descriptionId = useId();
  const keepOpen = useCallback(() => clearTimeout(closing.current), []);
  const closeSoon = useCallback(() => {
    keepOpen();
    closing.current = setTimeout(() => setActive(undefined), 100);
  }, [keepOpen]);
  useEffect(() => () => clearTimeout(closing.current), []);
  const span = active && spans.find((candidate) => candidate.id === active.id);
  const bind = useCallback(
    (
      id: string
    ): HTMLAttributes<HTMLElement> & { "data-inspected": boolean | undefined } => ({
      "aria-describedby": active?.id === id ? descriptionId : undefined,
      "data-inspected": active?.id === id || undefined,
      onMouseEnter: (event) => {
        keepOpen();
        setActive({ id, element: event.currentTarget });
      },
      onMouseLeave: closeSoon,
      onFocus: (event) => {
        keepOpen();
        setActive({ id, element: event.currentTarget });
      },
      onClick: (event) => {
        keepOpen();
        setActive({ id, element: event.currentTarget });
      },
      onBlur: closeSoon,
      onKeyDown: (event) => {
        if (event.key === "Escape") {
          keepOpen();
          setActive(undefined);
        }
      },
    }),
    [active?.id, descriptionId, keepOpen, closeSoon]
  );
  const dismiss = useCallback(() => {
    keepOpen();
    setActive(undefined);
  }, [keepOpen]);
  return {
    bind,
    dismiss,
    tooltip:
      span && active ? (
        <Tooltip
          isOpen
          delay={0}
          placement="bottom"
          triggerRef={{ current: active.element }}
          onOpenChange={(open) => {
            if (!open) setActive(undefined);
          }}
          content={
            <span id={descriptionId} onMouseEnter={keepOpen} onMouseLeave={closeSoon}>
              <SessionTimelineHoverContent
                span={span}
                record={records[span.index]!}
                item={items[span.index]!}
              />
            </span>
          }
        >
          <span aria-hidden="true" />
        </Tooltip>
      ) : null,
  };
}

function SessionTimelineHoverContent({
  span,
  record,
  item,
}: {
  span: SessionTimelineSpan;
  record: SessionHistoryRecord;
  item: SessionItemPresentation;
}) {
  const m = useCommaMessages();
  const toolLabel = useSessionToolLabel();
  const locale = useCommaLocale();
  const execution = record.execution;
  const point = span.shape === "point";
  const unknownEnd =
    span.shape === "open" ||
    (span.lane === 1 && !execution) ||
    (point && item.kind === "running");
  const duration = compactDuration(
    point ? undefined : execution?.live ? span.end - span.start : execution?.duration_ms
  );
  const time = (value: number) =>
    new Date(value).toLocaleTimeString(locale, {
      hour12: false,
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
  const status = execution?.live
    ? m.session_item_running()
    : execution?.completed_at_ms != null
      ? item.kind === "error" || item.kind === "cancelled"
        ? item.label
        : m.session_item_success()
      : unknownEnd
        ? m.session_inspector_unfinished()
        : undefined;
  const toolName = item.tools.join(" · ");
  const operation = useSessionOperation(item);
  const label =
    span.lane === 1
      ? m.session_item_model()
      : span.lane === 2
        ? m.session_timeline_tools()
        : item.label;
  const summary =
    item.summary !== item.label && item.summary !== toolName && item.summary !== label
      ? item.summary
      : undefined;
  const firstToken =
    execution?.lane === "model" ? execution.first_token_at_ms : undefined;
  const ttft = firstToken != null ? firstToken - span.start : undefined;
  return (
    <span className="comma-session-inspector" data-testid="session-timeline-inspector">
      <span className="comma-session-inspector-heading">
        <span
          className="comma-session-inspector-type"
          data-kind={span.lane === 1 ? "model" : span.kind}
        >
          <i aria-hidden="true" />
          {label}
        </span>
        {status && status !== label && (
          <span
            className="comma-session-inspector-status"
            data-live={execution?.live || undefined}
          >
            {status}
          </span>
        )}
      </span>
      {toolName && (
        <span className="comma-session-inspector-tool" title={toolName}>
          {item.action || item.tools.map(toolLabel).join(" · ")}
        </span>
      )}
      {operation && (
        <span className="comma-session-inspector-operation">{operation}</span>
      )}
      {summary && summary !== item.operation && (
        <span className="comma-session-inspector-summary">{summary}</span>
      )}
      {(duration || ttft != null) && (
        <span className="comma-session-inspector-metrics">
          {duration && (
            <span className="comma-session-inspector-metric">
              <span>
                {!execution?.live && execution?.completed_at_ms == null
                  ? m.session_inspector_observed()
                  : m.session_inspector_duration()}
              </span>
              <strong data-testid="session-inspector-duration">{duration}</strong>
            </span>
          )}
          {ttft != null && (
            <span className="comma-session-inspector-metric">
              <span>{m.session_inspector_ttft()}</span>
              <strong>{compactDuration(ttft) ?? "0ms"}</strong>
            </span>
          )}
        </span>
      )}
      <span className="comma-session-inspector-time">
        <time
          title={`${m.session_inspector_start()} · ${new Date(span.start).toLocaleString(locale)}`}
          dateTime={new Date(span.start).toISOString()}
        >
          {time(span.start)}
        </time>
        {execution?.completed_at_ms != null && (
          <>
            <span aria-hidden="true">→</span>
            <time
              title={m.session_inspector_end()}
              dateTime={new Date(execution.completed_at_ms).toISOString()}
            >
              {time(execution.completed_at_ms)}
            </time>
          </>
        )}
      </span>
      {span.lane === 1 && <SessionModelMetrics record={record} detail />}
      {unknownEnd && !execution?.live && (
        <span className="comma-session-inspector-note">
          {m.session_inspector_missing_end()}
        </span>
      )}
    </span>
  );
}
