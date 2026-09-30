import { expect, it } from "vitest";
import {
  sessionTimelineAxis,
  sessionTimelineBars,
  sessionIdleMarkers,
  sessionZoomAxis,
  sessionWheelWindow,
  type SessionTimelineSpan,
} from "../timeline/sessionHistoryTimelineModel";

const span = (
  lane: number,
  start: number,
  end = start,
  kind: SessionTimelineSpan["kind"] = "model",
  shape: SessionTimelineSpan["shape"] = "interval"
): SessionTimelineSpan => ({
  id: `${lane}:${start}`,
  targetId: `${lane}:${start}`,
  recordIds: [],
  index: 0,
  lane,
  track: 0,
  start,
  end,
  kind,
  shape,
});

it("keeps short bars at four pixels without changing time or vertical tracks", () => {
  const timeline = model([
    span(1, 0, 10000),
    span(2, 500, 501, "success"),
    span(2, 502, 502, "running", "point"),
  ]);
  const bars = sessionTimelineBars(timeline, sessionTimelineAxis(timeline), 400);
  const tools = bars.filter((item) => item.lane === 2);
  expect(tools.map((item) => item.width)).toEqual([4, 4]);
  expect(tools.map((item) => item.track)).toEqual([0, 0]);
  expect(tools.map((item) => [item.start, item.end])).toEqual([
    [500, 501],
    [502, 502],
  ]);
});

it("groups dense idle markers without losing gap counts or including active time", () => {
  const spans = Array.from({ length: 125 }, (_, index) => [
    span(1, index * 10_000, index * 10_000 + 1000),
    span(0, (index + 1) * 10_000, (index + 1) * 10_000, "input", "point"),
  ]).flat();
  const axis = sessionTimelineAxis(model(spans));
  const markers = sessionIdleMarkers(axis, 800);
  expect(markers.length).toBeLessThanOrEqual(17);
  expect(markers.reduce((sum, marker) => sum + marker.count, 0)).toBe(125);
  expect(markers.reduce((sum, marker) => sum + marker.duration, 0)).toBe(125 * 9000);
  expect(markers.flatMap((marker) => marker.intervals)).toEqual(axis.folds);
  expect(axis.folds.every((gap) => gap.left === gap.right)).toBe(true);
  for (let index = 1; index < markers.length; index++)
    expect(
      (markers[index]!.position - markers[index - 1]!.position) * 800
    ).toBeGreaterThanOrEqual(48);
});

it("keeps the mouse time stationary when zooming a folded axis", () => {
  const base = sessionTimelineAxis(
    model([
      span(1, 0, 1000),
      span(0, 10_000, 10_000, "input", "point"),
      span(1, 10_000, 12_000),
    ])
  );
  const pointer = 0.3;
  const before = base.timeAt(pointer);
  const window = sessionWheelWindow(0, 1, pointer, -300);
  const zoomed = sessionZoomAxis(
    base,
    base.timeAt(window.from),
    base.timeAt(window.to)
  );
  expect(zoomed.timeAt(pointer)).toBeCloseTo(before, 6);
  expect(zoomed.position(before)).toBeCloseTo(pointer, 6);
  expect(window.to - window.from).toBeLessThan(1);
});

it("pans without changing zoom and clamps to the loaded window", () => {
  const panned = sessionWheelWindow(0.2, 0.6, 0.5, 0.5, true);
  expect(panned.from).toBeCloseTo(0.4);
  expect(panned.to).toBeCloseTo(0.8);
  const end = sessionWheelWindow(0.2, 0.6, 0.5, 100, true);
  expect(end.from).toBeCloseTo(0.6);
  expect(end.to).toBe(1);
  expect(sessionWheelWindow(0.2, 0.6, 0.5, 10000)).toEqual({ from: 0, to: 1 });
});
const model = (spans: SessionTimelineSpan[]) => ({
  spans,
  unknown: [],
  tracks: [1, 1, 1],
  start: 0,
  end: Math.max(1, ...spans.map((item) => item.end)),
});

it("folds the idle between inputs while preserving execution proportions and inverse selection", () => {
  const axis = sessionTimelineAxis(
    model([
      span(0, 0, 0, "input", "point"),
      span(1, 0, 1000),
      span(0, 7_200_000, 7_200_000, "context", "point"),
      span(0, 7_200_000, 7_200_000, "input", "point"),
      span(1, 7_200_000, 7_218_000),
      span(2, 7_218_000, 7_218_080, "success"),
    ])
  );
  expect(axis.folds).toHaveLength(1);
  expect(axis.folds[0]).toMatchObject({ start: 1000, end: 7_200_000 });
  expect(axis.position(7_218_000) - axis.position(7_200_000)).toBeGreaterThan(0.9);
  expect(
    (axis.position(7_218_000) - axis.position(7_200_000)) /
      (axis.position(1000) - axis.position(0))
  ).toBeCloseTo(18);
  expect(axis.folds[0]!.left).toBe(axis.folds[0]!.right);
  for (const time of [1000, 3_600_000, 7_200_000]) {
    expect(axis.position(time)).toBe(axis.position(7_200_000));
    expect(axis.timeAt(axis.position(time))).toBe(7_200_000);
  }
  for (const time of [0, 500, 7_200_000, 7_210_000, 7_218_080])
    expect(axis.timeAt(axis.position(time))).toBeCloseTo(time, 5);
});

it("does not fold unmeasured work inside a turn", () => {
  const axis = sessionTimelineAxis(
    model([
      span(0, 0, 0, "input", "point"),
      span(1, 10_000, 10_000, "call", "point"),
      span(1, 20_000, 20_000, "model", "point"),
    ])
  );
  expect(axis.folds).toHaveLength(0);
  expect(axis.position(10_000)).toBe(0.5);
});

it("preserves collapsed boundary selection across consecutive idle intervals", () => {
  const axis = sessionTimelineAxis(
    model([
      span(1, 0, 1000),
      span(0, 10_000, 10_000, "input", "point"),
      span(1, 10_000, 10_000, "model", "point"),
      span(0, 20_000, 20_000, "input", "point"),
      span(1, 20_000, 22_000),
      span(0, 30_000, 30_000, "input", "point"),
      span(1, 30_000, 32_000),
    ])
  );
  // No measured work separates the first two gaps. Their shared position must
  // select the first following input, as a click on that boundary always did.
  expect(axis.folds.map(({ start, end }) => [start, end])).toEqual([
    [1000, 10_000],
    [10_000, 20_000],
    [22_000, 30_000],
  ]);
  for (const time of [1000, 5000, 10_000, 15_000, 20_000]) {
    expect(axis.position(time)).toBeCloseTo(0.2);
    expect(axis.timeAt(axis.position(time))).toBe(10_000);
  }
  for (const time of [22_000, 25_000, 30_000]) {
    expect(axis.position(time)).toBeCloseTo(0.6);
    expect(axis.timeAt(axis.position(time))).toBe(30_000);
  }
  for (const time of [-1000, 0, 500, 20_001, 21_000, 30_001, 32_000, 33_000])
    expect(axis.timeAt(axis.position(time))).toBeCloseTo(time, 6);
});

it("does not treat context on the input lane as a new user turn", () => {
  const axis = sessionTimelineAxis(
    model([span(1, 0, 1000), span(0, 20_000, 20_000, "context", "point")])
  );
  expect(axis.folds).toHaveLength(0);
});

it.each(["open", "interval"] as const)(
  "does not fold across %s asynchronous or parallel work",
  (shape) => {
    const axis = sessionTimelineAxis(
      model([
        span(1, 0, 1000),
        span(2, 500, shape === "open" ? 900 : 21_000, "running", shape),
        span(0, 20_000, 20_000, "input", "point"),
      ])
    );
    expect(axis.folds).toHaveLength(0);
  }
);

it("handles simultaneous inputs and a window containing only idle endpoints", () => {
  const axis = sessionTimelineAxis(
    model([
      span(1, 0, 0, "model", "point"),
      span(0, 10_000, 10_000, "input", "point"),
      span(0, 10_000, 10_000, "input", "point"),
    ])
  );
  expect(axis.folds).toHaveLength(1);
  expect(axis.position(0)).toBe(0.5);
  expect(axis.position(10_000)).toBe(0.5);
  expect(axis.timeAt(0.5)).toBe(10_000);
  const zoomed = sessionZoomAxis(axis, 0, 10_000);
  expect(zoomed.position(10_000)).toBe(0.5);
  expect(zoomed.timeAt(0.5)).toBe(10_000);
});
