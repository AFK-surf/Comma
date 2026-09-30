import { describe, expect, test } from "bun:test";
import type { Trajectory } from "@evalens/core";

import { trajectoryHealth } from "./evaluation";

const at = new Date("2026-08-13T00:00:00Z");

describe("trajectoryHealth", () => {
  test("counts identical calls independent of object key order", () => {
    const trajectory: Trajectory = {
      id: "trajectory-1",
      steps: [
        {
          type: "tool_call",
          id: "1",
          name: "Exec",
          arguments: { a: 1, b: 2 },
          timestamp: at,
        },
        {
          type: "tool_result",
          toolCallId: "1",
          name: "Exec",
          output: "no",
          status: "error",
          timestamp: at,
        },
        {
          type: "tool_call",
          id: "2",
          name: "Exec",
          arguments: { b: 2, a: 1 },
          timestamp: at,
        },
        {
          type: "tool_result",
          toolCallId: "2",
          name: "Exec",
          output: "no",
          errorClass: "timeout",
          timestamp: at,
        },
      ],
    };

    expect(
      trajectoryHealth({ answer: "recovered", timedOut: false, targetRole: "router" }, [
        trajectory,
      ])
    ).toEqual({
      replied: true,
      maxIdenticalToolRepeats: 2,
      maxConsecutiveToolErrors: 2,
    });
  });

  test("a successful tool result breaks the error streak", () => {
    const trajectory: Trajectory = {
      id: "trajectory-2",
      steps: [
        {
          type: "tool_result",
          toolCallId: "1",
          name: "Exec",
          output: "no",
          status: "error",
          timestamp: at,
        },
        {
          type: "tool_result",
          toolCallId: "2",
          name: "Exec",
          output: "ok",
          status: "success",
          timestamp: at,
        },
        {
          type: "tool_result",
          toolCallId: "3",
          name: "Exec",
          output: "no",
          status: "error",
          timestamp: at,
        },
      ],
    };

    expect(
      trajectoryHealth({ answer: "", timedOut: true, targetRole: "worker" }, [
        trajectory,
      ])
    ).toMatchObject({ replied: false, maxConsecutiveToolErrors: 1 });
  });
});
