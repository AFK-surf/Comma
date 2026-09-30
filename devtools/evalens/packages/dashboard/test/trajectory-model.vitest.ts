import { describe, expect, test } from "vitest";
import {
  buildTrajectoryEvents,
  defaultTrajectoryMode,
  eventMatches,
  formatTrajectoryParseError,
  hasTimestampRegression,
  mergeTrajectoryEvents,
  parseTrajectories,
} from "../src/trajectory/model";

const at = (seconds: number) => new Date(`2026-07-11T00:00:0${seconds}.000Z`);

describe("trajectory model", () => {
  test("defaults one trajectory to grouped and multiple trajectories to merged", () => {
    expect(defaultTrajectoryMode(1)).toBe("grouped");
    expect(defaultTrajectoryMode(2)).toBe("merged");
  });

  test("parses trajectories with the core schema and reports a precise path", () => {
    const parsed = parseTrajectories([
      { id: "router", steps: [{ type: "user", content: "hello", timestamp: at(1) }] },
    ]);
    expect(parsed.trajectories[0]?.steps[0]?.timestamp).toBeInstanceOf(Date);
    expect(() =>
      parseTrajectories([{ id: "router", steps: [{ type: "user" }] }])
    ).toThrow();
    try {
      parseTrajectories([{ id: "router", steps: [{ type: "user" }] }]);
    } catch (error) {
      expect(formatTrajectoryParseError(error)).toContain(
        "trajectory[0].steps[0].content"
      );
    }
  });

  test("rejects duplicate trajectory ids instead of replacing a lane", () => {
    try {
      parseTrajectories([
        { id: "duplicate", steps: [] },
        { id: "duplicate", steps: [] },
      ]);
      throw new Error("expected duplicate trajectory ids to fail");
    } catch (error) {
      expect(formatTrajectoryParseError(error)).toContain(
        "trajectory[1].id: duplicate trajectory id: duplicate"
      );
    }
  });

  test("keeps grouped order and detects timestamp regressions", () => {
    const events = buildTrajectoryEvents(
      {
        id: "router",
        steps: [
          { type: "user", content: "later", timestamp: at(2) },
          { type: "assistant", content: "earlier", timestamp: at(1) },
        ],
      },
      0
    );
    expect(events.map((event) => event.stepIndex)).toEqual([0, 1]);
    expect(hasTimestampRegression(events)).toBe(true);
  });

  test("sorts merged events by time, lane selector order, then step index", () => {
    const router = buildTrajectoryEvents(
      {
        id: "router",
        steps: [
          { type: "user", content: "first", timestamp: at(1) },
          { type: "assistant", content: "second", timestamp: at(1) },
        ],
      },
      1
    );
    const worker = buildTrajectoryEvents(
      { id: "worker", steps: [{ type: "system", content: "same", timestamp: at(1) }] },
      0
    );
    expect(
      mergeTrajectoryEvents(
        new Map([
          ["router", router],
          ["worker", worker],
        ]),
        ["worker", "router"]
      ).map((event) => event.key)
    ).toEqual(["worker:0", "router:0", "router:1"]);
  });

  test("pairs tool calls and results while retaining all abnormal results", () => {
    const events = buildTrajectoryEvents(
      {
        id: "worker",
        steps: [
          {
            type: "tool_call",
            id: "call-1",
            name: "search",
            arguments: { q: "needle" },
            timestamp: at(1),
          },
          {
            type: "tool_result",
            toolCallId: "call-1",
            name: "other",
            output: { result: true },
            timestamp: at(3),
          },
          {
            type: "tool_result",
            toolCallId: "call-1",
            name: "search",
            output: "duplicate",
            timestamp: at(4),
          },
          {
            type: "tool_result",
            toolCallId: "missing",
            name: "search",
            output: null,
            timestamp: at(5),
          },
          {
            type: "tool_call",
            id: "call-2",
            name: "write",
            arguments: {},
            timestamp: at(6),
          },
        ],
      },
      0
    );
    expect(events[0]).toMatchObject({
      durationMs: 2000,
      durationDerived: true,
      warnings: ["name-mismatch"],
    });
    expect(events[1]?.warnings).toEqual(["duplicate-result"]);
    expect(events[2]?.warnings).toEqual(["orphan-result"]);
    expect(events[3]?.warnings).toEqual(["pending"]);
  });

  test("searches trajectory ids and visible step fields but not timestamps", () => {
    const [event] = buildTrajectoryEvents(
      {
        id: "worker-1",
        steps: [
          {
            type: "assistant",
            content: "A useful answer",
            model: "gpt-5",
            timestamp: at(1),
          },
        ],
      },
      0
    );
    expect(eventMatches(event!, "worker-1")).toBe(true);
    expect(eventMatches(event!, "useful")).toBe(true);
    expect(eventMatches(event!, "gpt-5")).toBe(true);
    expect(eventMatches(event!, "2026-07-11")).toBe(false);
  });
});
