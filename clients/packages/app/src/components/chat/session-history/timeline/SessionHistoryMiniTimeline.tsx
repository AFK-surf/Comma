import { useMemo } from "react";
import type { SessionHistoryRecord } from "../../../../runtime-chat/sessionHistoryBridge";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type { SessionItemPresentation } from "../model/sessionHistoryPresentation";
import { sessionTimeline } from "./sessionHistoryTimelineModel";
import { useSessionHistoryClock } from "./sessionHistoryClock";
import { useSessionTimelineHover } from "./SessionTimelineHover";

export function SessionHistoryMiniTimeline({
  records,
  items,
  clockOffsetMs = 0,
}: {
  records: readonly SessionHistoryRecord[];
  items: readonly SessionItemPresentation[];
  clockOffsetMs?: number;
}) {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const now = useSessionHistoryClock() + clockOffsetMs;
  const start = now - 180_000;
  const model = useMemo(
    () => sessionTimeline(records, items, { start, end: now }, now),
    [records, items, start, now]
  );
  const spans = model.spans;
  const inspector = useSessionTimelineHover(spans, records, items);
  const position = (time: number) => Math.max(0, Math.min(1, (time - start) / 180_000));
  const heights = model.tracks.map((count) => count * 8 + 8);
  const offsets = heights.map((_, index) =>
    heights.slice(0, index).reduce((a, b) => a + b, 0)
  );
  return (
    <div
      className="comma-session-mini"
      data-testid="session-history-mini-timeline"
      data-start-ms={start}
      data-end-ms={now}
      aria-label={m.session_timeline_title()}
    >
      {
        <>
          <div className="comma-session-mini-heading">{m.session_mini_window()}</div>
          <div className="comma-session-mini-axis">
            {[0, 0.5, 1].map((fraction) => (
              <time key={fraction}>
                {new Date(start + fraction * 180_000).toLocaleTimeString(locale, {
                  hour12: false,
                })}
              </time>
            ))}
          </div>
          <div
            className="comma-session-mini-plot"
            style={{ height: heights.reduce((a, b) => a + b, 0) }}
          >
            <div className="comma-session-mini-labels" aria-hidden="true">
              {[
                m.session_timeline_input(),
                m.session_timeline_model(),
                m.session_timeline_tools(),
              ].map((label, lane) => (
                <span key={label} style={{ top: offsets[lane], height: heights[lane] }}>
                  {label}
                </span>
              ))}
            </div>
            <div className="comma-session-mini-track">
              {heights.map((height, lane) => (
                <div
                  key={lane}
                  className="comma-session-lane"
                  data-lane-background={lane}
                  aria-hidden="true"
                  style={{ top: offsets[lane], height }}
                />
              ))}
              {spans.map((span) => {
                const record = records[span.index]!;
                const unknownEnd =
                  span.shape === "open" ||
                  (span.lane === 1 && record.execution?.lane !== "model") ||
                  (span.shape === "point" && span.kind === "running");
                return (
                  <button
                    type="button"
                    key={span.id}
                    className="comma-session-overview-span"
                    data-span-id={span.id}
                    data-lane={span.lane}
                    data-track={span.track}
                    data-kind={span.lane === 1 ? "model" : span.kind}
                    data-display-shape={unknownEnd ? "open" : span.shape}
                    data-start-ms={span.start}
                    data-end-ms={span.end}
                    aria-label={`${items[span.index]!.label} · ${items[span.index]!.summary}`}
                    {...inspector.bind(span.id)}
                    style={{
                      left: `min(${position(span.start) * 100}%, calc(100% - 4px))`,
                      width: `max(4px, ${(position(span.end) - position(span.start)) * 100}%)`,
                      top: offsets[span.lane]! + 4 + span.track * 8,
                    }}
                  />
                );
              })}
            </div>
          </div>
        </>
      }
      {inspector.tooltip}
    </div>
  );
}
