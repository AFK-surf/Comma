import { describe, expect, it } from "vitest";
import {
  isPollingTerminalTaskStatus,
  normalizeTaskStatus,
  taskStatusBucket,
} from "../taskStatus";

describe("task status semantics", () => {
  it("normalizes server status casing and surrounding whitespace once", () => {
    expect(normalizeTaskStatus("  READY_FOR_REVIEW  ")).toBe("ready_for_review");
  });

  it.each([
    ["active", "in_progress"],
    ["ready_for_review", "needs_review"],
    ["escalated", "needs_review"],
    ["completed", "done"],
    ["archived", "archived"],
    ["failed", "cancelled"],
    ["unknown_status", "backlog"],
  ] as const)("maps %s to the %s display bucket", (status, bucket) => {
    expect(taskStatusBucket(status)).toBe(bucket);
  });

  it.each([
    "completed",
    "failed",
    "cancelled",
    "ready_for_review",
    "escalated",
    "done",
    "archived",
    "succeeded",
    "  ARCHIVED  ",
  ])("stops list polling for terminal status %s", (status) => {
    expect(isPollingTerminalTaskStatus(status)).toBe(true);
  });

  it.each(["active", "in_progress", "running", "idle", "unknown_status"])(
    "keeps list polling for non-terminal status %s",
    (status) => {
      expect(isPollingTerminalTaskStatus(status)).toBe(false);
    }
  );
});
