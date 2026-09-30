import { describe, expect, it } from "vitest";
import type { TaskStatusBucket } from "../../task-workspace/taskStatus";
import { statusIds } from "../StatusIndicator";
import { indicatorIdToTaskStatus, taskStatusToIndicatorId } from "../statusMapping";

const BUCKETS: TaskStatusBucket[] = [
  "backlog",
  "in_progress",
  "needs_review",
  "done",
  "cancelled",
];

describe("status indicator ↔ task status binding", () => {
  it("maps every task status bucket to a distinct indicator id", () => {
    const ids = BUCKETS.map(taskStatusToIndicatorId);
    expect(new Set(ids).size).toBe(BUCKETS.length);
    for (const id of ids) {
      expect(statusIds).toContain(id);
    }
  });

  it("round-trips every bucket through the indicator id", () => {
    for (const bucket of BUCKETS) {
      expect(indicatorIdToTaskStatus(taskStatusToIndicatorId(bucket))).toBe(bucket);
    }
  });

  it("round-trips every indicator id through the bucket", () => {
    for (const id of statusIds) {
      expect(taskStatusToIndicatorId(indicatorIdToTaskStatus(id))).toBe(id);
    }
  });
});
