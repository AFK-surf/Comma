import type { SessionHistoryRecord } from "../../../../runtime-chat/sessionHistoryBridge";
import { sessionHistoryEntries } from "../model/sessionHistoryEntries";
import type {
  SessionItemKind,
  SessionItemPresentation,
} from "../model/sessionHistoryPresentation";

export type SessionTimelineSpan = {
  id: string;
  targetId: string;
  recordIds: string[];
  index: number;
  lane: number;
  track: number;
  start: number;
  end: number;
  kind: SessionItemKind;
  shape: "point" | "interval" | "open";
};

/** Epoch-time projection of the same entries as the ledger. Tool lifecycle
 * records share one bar; unrelated runtime notices remain independent. */
export function sessionTimeline(
  records: readonly SessionHistoryRecord[],
  items: readonly SessionItemPresentation[],
  window?: { start: number; end: number },
  now?: number
) {
  const spans: SessionTimelineSpan[] = [];
  const unknown: { id: string; index: number }[] = [];
  sessionHistoryEntries(records, items).forEach((entry) => {
    const { record, index, item } = entry;
    // Tool arguments belong to a model request, not a measured tool start.
    if (entry.tool && record.kind === "assistant") return;
    const execution = record.execution;
    const time = record.timestamp_ms;
    const model =
      record.kind === "assistant" || item.kind === "model" || item.kind === "thinking";
    const addEvent = (
      start: number,
      end: number,
      shape: SessionTimelineSpan["shape"]
    ) => {
      if (window && (end < window.start || start > window.end)) return;
      spans.push({
        id: entry.tool ? entry.id : `record:${record.id}`,
        targetId: entry.id,
        recordIds: [entry.id, ...entry.recordIds.filter((id) => id !== entry.id)],
        index,
        lane: entry.tool || record.kind === "tool" ? 2 : model ? 1 : 0,
        track: 0,
        start,
        end,
        kind: item.kind,
        shape,
      });
    };
    if (execution)
      addEvent(
        execution.started_at_ms,
        execution.live && now !== undefined
          ? Math.max(execution.observed_at_ms, now)
          : execution.observed_at_ms,
        execution.completed_at_ms === null ? "open" : "interval"
      );
    else if (time != null) addEvent(time, time, "point");
    else unknown.push({ id: entry.id, index });
  });
  // Stable interval partitioning: overlaps never serialize into one fake span.
  const tracks = [1, 1, 1];
  for (let lane = 0; lane < tracks.length; lane++) {
    const ends: { time: number; point: boolean }[] = [];
    for (const span of spans
      .filter((value) => value.lane === lane)
      .toSorted((a, b) => a.start - b.start || a.end - b.end)) {
      let track = ends.findIndex(
        (end) => end.time < span.start || (end.time === span.start && !end.point)
      );
      if (track < 0) track = ends.length;
      ends[track] = { time: span.end, point: span.start === span.end };
      span.track = track;
    }
    tracks[lane] = Math.max(1, ends.length);
  }
  let start = Infinity,
    end = -Infinity;
  for (const span of spans) {
    start = Math.min(start, span.start);
    end = Math.max(end, span.end);
  }
  return {
    spans,
    unknown,
    tracks,
    start: spans.length ? start : 0,
    end: spans.length ? Math.max(start + 1, end) : 1,
  };
}

/** Fold only a quiet boundary after a final model response and before a new
 * user input. Gaps inside a turn can be unmeasured model work, not idle.
 * Open or overlapping work keeps the boundary on the real-time scale. */
export function sessionTimelineAxis(model: ReturnType<typeof sessionTimeline>) {
  const gaps: { start: number; end: number }[] = [];
  const inputs = [
    ...new Set(
      model.spans.filter((span) => span.kind === "input").map((span) => span.start)
    ),
  ].toSorted((a, b) => a - b);
  // Sweep once: a live clock must not rescan every execution for every input.
  const byEnd = model.spans.toSorted((a, b) => a.end - b.end);
  const byStart = model.spans.toSorted((a, b) => a.start - b.start);
  let endIndex = 0,
    startIndex = 0,
    start = -Infinity,
    maximumEnd = -Infinity;
  let finalModel = false,
    open = false;
  for (const input of inputs) {
    while (endIndex < byEnd.length && byEnd[endIndex]!.end < input) {
      const span = byEnd[endIndex++]!;
      if (span.end !== start) finalModel = false;
      start = span.end;
      finalModel ||= span.lane === 1 && span.kind === "model";
    }
    while (startIndex < byStart.length && byStart[startIndex]!.start < input) {
      const span = byStart[startIndex++]!;
      maximumEnd = Math.max(maximumEnd, span.end);
      open ||= span.shape === "open";
    }
    if (finalModel && input - start >= 1000 && !open && maximumEnd <= start)
      gaps.push({ start, end: input });
  }
  const activeDuration =
    model.end - model.start - gaps.reduce((sum, gap) => sum + gap.end - gap.start, 0);
  if (activeDuration === 0)
    return {
      folds: gaps.map((gap) => ({ ...gap, left: 0.5, right: 0.5 })),
      position: (_time: number) => 0.5,
      timeAt: (_fraction: number) => model.end,
    };
  const scale = 1 / activeDuration;
  let foldedDuration = 0;
  const removedThrough: number[] = [];
  const folds = gaps.map((gap) => {
    const left = (gap.start - model.start - foldedDuration) * scale;
    foldedDuration += gap.end - gap.start;
    removedThrough.push(foldedDuration);
    return { ...gap, left, right: left };
  });
  const position = (time: number) => {
    // Each bar asks for both edges. Locate the first fold that has not ended
    // instead of scanning all earlier quiet intervals for every edge.
    let from = 0,
      to = folds.length;
    while (from < to) {
      const middle = Math.floor((from + to) / 2);
      if (folds[middle]!.end < time) from = middle + 1;
      else to = middle;
    }
    const gap = folds[from];
    if (gap && time >= gap.start && time <= gap.end) return gap.left;
    const removed = removedThrough[from - 1] ?? 0;
    return (time - model.start - removed) * scale;
  };
  const timeAt = (fraction: number) => {
    let from = 0,
      to = folds.length;
    while (from < to) {
      const middle = Math.floor((from + to) / 2);
      if (folds[middle]!.left < fraction) from = middle + 1;
      else to = middle;
    }
    const gap = folds[from];
    // Keep the first matching boundary when adjacent folds share a position.
    // Selection resolves to its following input, never to hidden idle time.
    if (gap && fraction === gap.left) return gap.end;
    const removed = removedThrough[from - 1] ?? 0;
    return model.start + fraction / scale + removed;
  };
  return { folds, position, timeAt };
}

/** Project horizontal positions without changing the assigned vertical tracks. */
export function sessionTimelineBars(
  model: ReturnType<typeof sessionTimeline>,
  axis: ReturnType<typeof sessionTimelineAxis>,
  width: number
) {
  return model.spans.map((span) => {
    const left = Math.max(0, axis.position(span.start));
    const right = Math.min(1, axis.position(span.end));
    const visibleWidth = Math.min(width, Math.max(4, (right - left) * width));
    return {
      ...span,
      left: Math.min(left * width, width - visibleWidth),
      width: visibleWidth,
    };
  });
}

/** Aggregate decoration by screen space, without changing the time axis or bars. */
export function sessionIdleMarkers(
  axis: ReturnType<typeof sessionTimelineAxis>,
  width: number
) {
  const markers: {
    start: number;
    end: number;
    position: number;
    duration: number;
    count: number;
    intervals: ReturnType<typeof sessionTimelineAxis>["folds"];
  }[] = [];
  for (const gap of axis.folds) {
    const position = (gap.left + gap.right) / 2;
    const previous = markers.at(-1);
    if (previous && (position - previous.position) * width < 48) {
      previous.end = gap.end;
      previous.duration += gap.end - gap.start;
      previous.count++;
      previous.intervals.push(gap);
    } else
      markers.push({
        start: gap.start,
        end: gap.end,
        position,
        duration: gap.end - gap.start,
        count: 1,
        intervals: [gap],
      });
  }
  return markers;
}

export function sessionZoomAxis(
  base: ReturnType<typeof sessionTimelineAxis>,
  start: number,
  end: number
) {
  const from = base.position(start),
    to = base.position(end);
  if (from === to) return { ...base, from: 0, to: 1 };
  const span = to - from;
  return {
    from,
    to,
    position: (time: number) => (base.position(time) - from) / span,
    timeAt: (fraction: number) => base.timeAt(from + fraction * span),
    folds: base.folds
      .filter((gap) => gap.end > start && gap.start < end)
      .map((gap) => ({
        start: Math.max(start, gap.start),
        end: Math.min(end, gap.end),
        left: Math.max(0, (gap.left - from) / span),
        right: Math.min(1, (gap.right - from) / span),
      })),
  };
}

/** Wheel scaling is in folded-axis coordinates so the cursor time stays fixed. */
export function sessionWheelWindow(
  from: number,
  to: number,
  pointer: number,
  delta: number,
  pan = false
) {
  const size = to - from;
  const nextSize = pan
    ? size
    : Math.min(1, Math.max(0.00001, size * Math.exp(delta * 0.002)));
  const left = pan ? from + delta * size : from + pointer * (size - nextSize);
  const start = Math.max(0, Math.min(1 - nextSize, left));
  return { from: start, to: start + nextSize };
}
