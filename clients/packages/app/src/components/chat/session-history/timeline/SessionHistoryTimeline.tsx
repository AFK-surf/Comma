import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { SessionHistoryRecord } from "../../../../runtime-chat/sessionHistoryBridge";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Button, ScrollArea, Tooltip } from "@comma/ui";
import type { SessionItemPresentation } from "../model/sessionHistoryPresentation";
import { useSessionHistoryClock } from "./sessionHistoryClock";
import { useSessionTimelineHover } from "./SessionTimelineHover";
import {
  sessionTimeline,
  sessionTimelineAxis,
  sessionTimelineBars,
  sessionIdleMarkers,
  sessionZoomAxis,
  sessionWheelWindow,
  type SessionTimelineSpan,
} from "./sessionHistoryTimelineModel";

export function SessionHistoryTimeline({
  active = true,
  records,
  items,
  selected,
  onSelect,
  onRange,
  clockOffsetMs = 0,
}: {
  active?: boolean;
  records: readonly SessionHistoryRecord[];
  items: readonly SessionItemPresentation[];
  selected: string | undefined;
  onSelect(id: string): void;
  onRange(ids: ReadonlySet<string> | undefined): void;
  clockOffsetMs?: number;
}) {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const [range, setRange] = useState<{ start: number; end: number }>();
  const [activeIdle, setActiveIdle] = useState<number>();
  const drag = useRef<number | undefined>(undefined);
  const now =
    useSessionHistoryClock(active && records.some((r) => r.execution?.live)) +
    clockOffsetMs;
  const complete = useMemo(
    () => sessionTimeline(records, items, undefined, now),
    [records, items, now]
  );
  const baseAxis = useMemo(() => sessionTimelineAxis(complete), [complete]);
  const trackRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const measure = useCallback(() => setWidth(trackRef.current?.clientWidth ?? 0), []);
  const [zoom, setZoom] = useState<{ start: number; end: number }>();
  const model = useMemo(
    () =>
      zoom
        ? {
            ...complete,
            ...zoom,
            spans: complete.spans.filter(
              (span) => span.end >= zoom.start && span.start <= zoom.end
            ),
          }
        : complete,
    [complete, zoom]
  );
  const zoomable = baseAxis.position(complete.end) > baseAxis.position(complete.start);
  const axis = useMemo(
    () => sessionZoomAxis(baseAxis, model.start, model.end),
    [baseAxis, model.start, model.end]
  );
  const paintProjection = useRef<
    | {
        records: typeof records;
        items: typeof items;
        zoom: typeof zoom;
        width: number;
        axis: typeof axis;
        model: typeof model;
      }
    | undefined
  >(undefined);
  const previousPaint = paintProjection.current;
  // A live/open span already forbids later idle folds. With unchanged source
  // and zoom, clock ticks only change the affine scale between the same folds.
  // Endpoint drift therefore bounds every paint position. Reserve half a pixel
  // for rounding each painted edge: total error stays below one CSS pixel.
  const drift = previousPaint
    ? Math.max(
        Math.abs(previousPaint.axis.position(model.start) - axis.position(model.start)),
        Math.abs(previousPaint.axis.position(model.end) - axis.position(model.end))
      ) * width
    : Infinity;
  if (
    !previousPaint ||
    previousPaint.records !== records ||
    previousPaint.items !== items ||
    previousPaint.zoom !== zoom ||
    previousPaint.width !== width ||
    drift >= 0.5 ||
    previousPaint.model.spans.length !== model.spans.length ||
    model.tracks.some((count, lane) => previousPaint.model.tracks[lane] !== count) ||
    model.spans.some((span, index) => {
      const previous = previousPaint.model.spans[index];
      return (
        !previous ||
        previous.id !== span.id ||
        previous.track !== span.track ||
        Math.abs(previousPaint.axis.position(previous.end) - axis.position(span.end)) *
          width >=
          0.5
      );
    })
  ) {
    paintProjection.current = { records, items, zoom, width, axis, model };
  }
  const { axis: paintAxis, model: paintModel } = paintProjection.current!;
  const inspector = useSessionTimelineHover(model.spans, records, items);
  const idleMarkers = useMemo(() => sessionIdleMarkers(axis, width), [axis, width]);
  const highlightedIdle = idleMarkers.find((marker) => marker.start === activeIdle);
  const unmeasuredModels = records.filter(
    (record, index) =>
      (record.kind === "assistant" ||
        items[index]!.kind === "model" ||
        items[index]!.kind === "thinking") &&
      record.execution?.lane !== "model"
  );
  const heights = complete.tracks.map((count) => count * 24 + 8);
  const offsets = heights.map((_, index) =>
    heights.slice(0, index).reduce((sum, height) => sum + height, 16)
  );
  const plotHeight = heights.reduce((sum, height) => sum + height, 16);
  const reset = () => {
    setRange(undefined);
    setActiveIdle(undefined);
    onRange(undefined);
  };
  const changeZoom = (next: typeof zoom) => {
    setZoom(next);
    reset();
  };
  useEffect(() => {
    setRange(undefined);
    setActiveIdle(undefined);
    onRange(undefined);
  }, [records, onRange]);
  useEffect(() => {
    const track = trackRef.current;
    if (!track || !zoomable) return;
    const wheel = (event: WheelEvent) => {
      event.preventDefault();
      event.stopPropagation();
      const bounds = track.getBoundingClientRect();
      const pointer = (event.clientX - bounds.left) / bounds.width;
      const pan = event.shiftKey || Math.abs(event.deltaX) > Math.abs(event.deltaY);
      const units =
        event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? bounds.width : 1;
      const delta = (pan ? event.deltaX || event.deltaY : event.deltaY) * units;
      setZoom((current) => {
        const from = current ? baseAxis.position(current.start) : 0;
        const to = current ? baseAxis.position(current.end) : 1;
        const next = sessionWheelWindow(
          from,
          to,
          pointer,
          pan ? delta / bounds.width : delta,
          pan
        );
        return next.from === 0 && next.to === 1
          ? undefined
          : { start: baseAxis.timeAt(next.from), end: baseAxis.timeAt(next.to) };
      });
      setRange(undefined);
      setActiveIdle(undefined);
      onRange(undefined);
    };
    track.addEventListener("wheel", wheel, { passive: false });
    return () => track.removeEventListener("wheel", wheel);
  }, [baseAxis, onRange, zoomable]);
  return (
    <section className="comma-session-overview" aria-label={m.session_timeline_title()}>
      <div className="comma-session-overview-toolbar">
        <strong>{m.session_timeline_title()}</strong>
        <span title={m.session_timeline_time_hint()}>{m.session_timeline_time()}</span>
        <div className="comma-session-zoom">
          <button
            type="button"
            disabled={!zoomable}
            onClick={() =>
              changeZoom({
                start: axis.timeAt(range?.start ?? 0.5),
                end: axis.timeAt(range?.end ?? 1),
              })
            }
          >
            {m.session_timeline_zoom_in()}
          </button>
          <button
            type="button"
            disabled={!zoom}
            onClick={() => {
              const size = Math.min(1, (axis.to - axis.from) * 2);
              const center = (axis.from + axis.to) / 2;
              const start = Math.max(0, Math.min(1 - size, center - size / 2));
              changeZoom(
                size === 1
                  ? undefined
                  : {
                      start: baseAxis.timeAt(start),
                      end: baseAxis.timeAt(start + size),
                    }
              );
            }}
          >
            {m.session_timeline_zoom_out()}
          </button>
          <button type="button" disabled={!zoom} onClick={() => changeZoom(undefined)}>
            {m.session_timeline_zoom_all()}
          </button>
        </div>
        {range && (
          <button type="button" onClick={reset}>
            {m.session_timeline_reset()}
          </button>
        )}
      </div>
      <div
        className="comma-session-overview-axis"
        aria-label={m.session_timeline_scale()}
      >
        {model.spans.length ? (
          [0, 0.25, 0.5, 0.75, 1].map((fraction) => (
            <span
              key={fraction}
              title={new Date(axis.timeAt(fraction)).toLocaleString(locale)}
            >
              {new Date(axis.timeAt(fraction)).toLocaleTimeString(locale, {
                hour12: false,
              })}
            </span>
          ))
        ) : (
          <span>{m.session_timeline_no_time()}</span>
        )}
      </div>
      <ScrollArea
        edgeEffect="none"
        className="comma-session-overview-scroll"
        style={{ height: Math.min(plotHeight, 280) }}
        onViewportResize={measure}
      >
        <div className="comma-session-overview-plot" style={{ height: plotHeight }}>
          <div className="comma-session-overview-labels" aria-hidden>
            {[
              m.session_timeline_input(),
              m.session_timeline_model(),
              m.session_timeline_tools(),
            ].map((label, index) => (
              <span key={label} style={{ top: offsets[index], height: heights[index] }}>
                {label}
              </span>
            ))}
          </div>
          <div
            className="comma-session-overview-track"
            ref={trackRef}
            data-testid="session-timeline-track"
            data-start-ms={model.start}
            data-end-ms={model.end}
            data-axis-from={axis.from}
            data-axis-to={axis.to}
            onDoubleClick={reset}
            onPointerDown={(event) => {
              if (event.button !== 0 || (event.target as HTMLElement).closest("button"))
                return;
              const bounds = event.currentTarget.getBoundingClientRect();
              drag.current = (event.clientX - bounds.left) / bounds.width;
              event.currentTarget.setPointerCapture(event.pointerId);
            }}
            onPointerMove={(event) => {
              if (drag.current === undefined) return;
              const bounds = event.currentTarget.getBoundingClientRect();
              const current = Math.max(
                0,
                Math.min(1, (event.clientX - bounds.left) / bounds.width)
              );
              setRange({
                start: Math.min(drag.current, current),
                end: Math.max(drag.current, current),
              });
            }}
            onPointerUp={(event) => {
              if (drag.current === undefined) return;
              const bounds = event.currentTarget.getBoundingClientRect();
              const current = Math.max(
                0,
                Math.min(1, (event.clientX - bounds.left) / bounds.width)
              );
              const from = Math.min(drag.current, current),
                to = Math.max(drag.current, current);
              drag.current = undefined;
              if ((to - from) * bounds.width < 4) {
                reset();
                return;
              }
              onRange(
                new Set(
                  model.spans
                    .filter(
                      (span) =>
                        axis.position(span.end) >= from &&
                        axis.position(span.start) <= to
                    )
                    .flatMap((span) => span.recordIds)
                )
              );
            }}
            onPointerCancel={() => {
              drag.current = undefined;
              reset();
            }}
          >
            {range && (
              <div
                className="comma-session-overview-selection"
                style={{
                  left: `${range.start * 100}%`,
                  width: `${(range.end - range.start) * 100}%`,
                }}
              />
            )}
            {heights.map((height, lane) => (
              <div
                key={lane}
                className="comma-session-lane"
                data-lane-background={lane}
                aria-hidden="true"
                style={{ top: offsets[lane], height }}
              />
            ))}
            {highlightedIdle?.intervals.map((interval) => (
              <div
                key={interval.start}
                className="comma-session-idle-range"
                data-testid="session-timeline-idle-range"
                data-start-ms={interval.start}
                data-end-ms={interval.end}
                aria-hidden="true"
                style={{
                  left: `${interval.left * 100}%`,
                  width: `${(interval.right - interval.left) * 100}%`,
                }}
              />
            ))}
            {idleMarkers.map((gap) => {
              const duration = gap.duration;
              const hours = Math.floor(duration / 3_600_000);
              const minutes = Math.floor((duration % 3_600_000) / 60_000);
              const seconds = (duration % 60_000) / 1000;
              const formatted = (
                [
                  [hours, "hour"],
                  [minutes, "minute"],
                  [seconds, "second"],
                ] as const
              )
                .filter(([value]) => value > 0)
                .map(([value, unit]) =>
                  new Intl.NumberFormat(locale, {
                    style: "unit",
                    unit,
                    unitDisplay: "short",
                    maximumFractionDigits: 3,
                  }).format(value)
                )
                .join(" ");
              const label =
                gap.count === 1
                  ? m.session_timeline_idle({ duration: formatted })
                  : m.session_timeline_idle_group({
                      count: gap.count,
                      duration: formatted,
                    });
              return (
                <div
                  key={gap.start}
                  className="comma-session-idle"
                  data-testid="session-timeline-idle-divider"
                  style={{ left: `${gap.position * 100}%` }}
                >
                  <Tooltip
                    content={label}
                    onOpenChange={(open) => {
                      if (open) inspector.dismiss();
                      setActiveIdle((current) =>
                        open ? gap.start : current === gap.start ? undefined : current
                      );
                    }}
                    supportingText={`${new Date(gap.start).toLocaleString(locale)} → ${new Date(gap.end).toLocaleString(locale)}`}
                    placement="bottom"
                  >
                    <Button
                      hierarchy="tertiary-gray"
                      className="comma-session-idle-dot"
                      aria-label={label}
                      data-testid="session-timeline-idle"
                      data-duration-ms={duration}
                      data-gap-count={gap.count}
                    >
                      <span aria-hidden="true" />
                    </Button>
                  </Tooltip>
                </div>
              );
            })}
            <SessionTimelineBars
              model={paintModel}
              axis={paintAxis}
              width={width}
              records={records}
              items={items}
              selected={selected}
              bind={inspector.bind}
              dismiss={inspector.dismiss}
              onSelect={onSelect}
              active={active}
              clockOffsetMs={clockOffsetMs}
            />
          </div>
        </div>
      </ScrollArea>
      {inspector.tooltip}
      <div className="comma-session-overview-caption">
        <span>{m.session_timeline_loaded({ count: records.length })}</span>
        {model.unknown.length > 0 ? (
          <button type="button" onClick={() => onSelect(model.unknown[0]!.id)}>
            {m.session_timeline_unknown({ count: model.unknown.length })}
          </button>
        ) : (
          <span>
            {highlightedIdle
              ? m.session_timeline_idle_highlight()
              : m.session_timeline_hint()}
          </span>
        )}
      </div>
      {unmeasuredModels.length > 0 && (
        <div className="comma-session-overview-caption">
          <button type="button" onClick={() => onSelect(unmeasuredModels[0]!.id)}>
            {m.session_timeline_unmeasured_models({ count: unmeasuredModels.length })}
          </button>
        </div>
      )}
    </section>
  );
}

// Keep the complete button group stable between visible pixel changes. Live
// labels and timestamps subscribe at their leaves, so they still update at 100 ms.
const SessionTimelineBars = memo(function SessionTimelineBars({
  model,
  axis: paintAxis,
  width,
  records,
  items,
  selected,
  bind,
  dismiss,
  onSelect,
  active,
  clockOffsetMs,
}: {
  model: ReturnType<typeof sessionTimeline>;
  axis: ReturnType<typeof sessionZoomAxis>;
  width: number;
  records: readonly SessionHistoryRecord[];
  items: readonly SessionItemPresentation[];
  selected: string | undefined;
  bind: ReturnType<typeof useSessionTimelineHover>["bind"];
  dismiss(): void;
  onSelect(id: string): void;
  active: boolean;
  clockOffsetMs: number;
}) {
  const bars = sessionTimelineBars(model, paintAxis, width);
  const heights = model.tracks.map((count) => count * 24 + 8);
  const offsets = heights.map((_, index) =>
    heights.slice(0, index).reduce((sum, height) => sum + height, 16)
  );
  return bars.map((span) => {
    const record = records[span.index]!;
    const execution = record.execution;
    const firstToken =
      span.lane === 1 && execution?.lane === "model"
        ? execution.first_token_at_ms
        : null;
    const left = Math.round(span.left);
    return (
      <SessionTimelineBar
        key={span.id}
        record={record}
        item={items[span.index]!}
        id={span.id}
        targetId={span.targetId}
        lane={span.lane}
        track={span.track}
        shape={span.shape}
        kind={span.kind}
        start={span.start}
        end={record.execution?.live ? record.execution.observed_at_ms : span.end}
        active={active && record.execution?.live === true}
        clockOffsetMs={clockOffsetMs}
        left={left}
        width={Math.round(span.left + span.width) - left}
        top={offsets[span.lane]! + 4 + span.track * 24}
        selected={selected !== undefined && span.recordIds.includes(selected)}
        startVisible={execution != null && execution.started_at_ms >= model.start}
        endVisible={
          execution?.completed_at_ms != null && execution.completed_at_ms <= model.end
        }
        firstTokenLeft={
          firstToken != null && firstToken >= model.start && firstToken <= model.end
            ? Math.round(paintAxis.position(firstToken) * width) - left
            : undefined
        }
        bind={bind}
        dismiss={dismiss}
        onSelect={onSelect}
      />
    );
  });
});

// Keep historical buttons stable while the presentation clock extends live work.
// Only paint coordinates are pixel-aligned; all times retain their precision.
const SessionTimelineBar = memo(function SessionTimelineBar({
  record,
  item,
  id,
  targetId,
  lane,
  track,
  shape,
  kind,
  start,
  end: observedEnd,
  active,
  clockOffsetMs,
  left,
  width,
  top,
  selected,
  startVisible,
  endVisible,
  firstTokenLeft,
  bind,
  dismiss,
  onSelect,
}: {
  record: SessionHistoryRecord;
  item: SessionItemPresentation;
  id: string;
  targetId: string;
  lane: number;
  track: number;
  shape: SessionTimelineSpan["shape"];
  kind: SessionTimelineSpan["kind"];
  start: number;
  end: number;
  active: boolean;
  clockOffsetMs: number;
  left: number;
  width: number;
  top: number;
  selected: boolean;
  startVisible: boolean;
  endVisible: boolean;
  firstTokenLeft: number | undefined;
  bind: ReturnType<typeof useSessionTimelineHover>["bind"];
  dismiss(): void;
  onSelect(id: string): void;
}) {
  const m = useCommaMessages();
  const execution = record.execution;
  const now =
    useSessionHistoryClock(active && execution?.live === true) + clockOffsetMs;
  const end = execution?.live ? Math.max(observedEnd, now) : observedEnd;
  const request = lane === 1;
  const measuredRequest = request && execution?.lane === "model";
  const firstToken = measuredRequest ? execution.first_token_at_ms : null;
  const unknownEnd =
    shape === "open" ||
    (request && !measuredRequest) ||
    (shape === "point" && item.kind === "running");
  const timing =
    shape === "point"
      ? m.session_timeline_point()
      : `${end - start} ms${shape === "open" ? ` · ${m.session_timeline_open()}` : ""}`;
  const phases = measuredRequest
    ? [
        `${m.session_request_start()}: ${new Date(execution.started_at_ms).toISOString()}`,
        firstToken != null
          ? m.session_request_ttft({
              duration: firstToken - execution.started_at_ms,
            })
          : null,
        execution.completed_at_ms != null
          ? `${m.session_request_end()}: ${new Date(execution.completed_at_ms).toISOString()}`
          : m.session_timeline_open(),
      ]
        .filter(Boolean)
        .join("\n")
    : "";
  const label = `${request ? m.session_item_model() : `${item.label} · ${item.tools.join(" · ")} ${item.summary}`}\n${new Date(start).toISOString()} · ${timing}${phases ? `\n${phases}` : ""}${unknownEnd && !measuredRequest ? `\n${m.session_timeline_open()}` : ""}`;
  return (
    <button
      type="button"
      className="comma-session-overview-span"
      data-kind={request ? "model" : kind}
      data-display-shape={unknownEnd ? "open" : shape}
      data-record-target={targetId}
      data-span-id={id}
      data-lane={lane}
      data-track={track}
      data-shape={shape}
      data-start-ms={start}
      data-end-ms={end}
      aria-label={label}
      {...bind(id)}
      aria-pressed={selected}
      style={{ left, width, top }}
      onClick={() => {
        dismiss();
        onSelect(targetId);
      }}
    >
      {measuredRequest && (
        <>
          {startVisible && (
            <span
              className="comma-session-request-phase"
              data-phase="start"
              title={m.session_request_start()}
            />
          )}
          {firstTokenLeft !== undefined && firstToken != null && (
            <span
              className="comma-session-request-phase"
              data-phase="ttft"
              data-time-ms={firstToken}
              title={m.session_request_ttft({
                duration: firstToken - execution.started_at_ms,
              })}
              style={{ left: firstTokenLeft }}
            />
          )}
          {endVisible && (
            <span
              className="comma-session-request-phase"
              data-phase="end"
              title={m.session_request_end()}
            />
          )}
        </>
      )}
    </button>
  );
});
