import { describe, expect, it } from "vitest";
import type { SessionHistoryRecord } from "../../../session-history/useSessionHistory";
import { sessionHistoryEntries } from "../../../session-history/model/sessionHistoryEntries";
import {
  presentSessionRecords,
  type SessionItemLabels,
} from "../../../session-history/model/sessionHistoryPresentation";
import { latestWorkerStep, workerProgress, type WorkerStep } from "../workerProgress";

const epoch = 1_788_564_963_000;
// The labels only name rows in the debug ledger; steps never show them.
const labels = new Proxy({} as SessionItemLabels, {
  get: (_target, key) =>
    key === "count" ? () => "" : key === "inputSource" ? undefined : String(key),
});

let clock = 0;
function call(
  id: string,
  name: string,
  args: Record<string, string | { type: string; text: string }[]>
) {
  clock += 1000;
  return {
    id: `${id}:call`,
    kind: "assistant",
    content: { tool_calls: [{ id, name, args }] },
    timestamp_ms: epoch + clock,
    execution: model(`${id}:model`, clock - 500, clock),
  } satisfies SessionHistoryRecord;
}
function result(id: string, status: "completed" | "failed" | "running") {
  clock += 1000;
  return {
    id: `${id}:result`,
    kind: "tool",
    content: { type: `tool_call_${status}`, tool_call_id: id, status },
    timestamp_ms: epoch + clock,
    execution: {
      id,
      lane: "tool",
      started_at_ms: epoch + clock - 900,
      observed_at_ms: epoch + clock,
      completed_at_ms: status === "running" ? null : epoch + clock,
      duration_ms: status === "running" ? 0 : 900,
    },
  } satisfies SessionHistoryRecord;
}
function model(id: string, start: number, end: number | null, live?: boolean) {
  return {
    id,
    lane: "model" as const,
    started_at_ms: epoch + start,
    observed_at_ms: epoch + (end ?? start),
    completed_at_ms: end === null ? null : epoch + end,
    duration_ms: end === null ? 0 : end - start,
    ...(live === undefined ? {} : { live }),
  };
}
function progress(records: SessionHistoryRecord[]) {
  return workerProgress(
    sessionHistoryEntries(records, presentSessionRecords(records, labels))
  );
}

describe("workerProgress", () => {
  it("words the finished steps from what the Worker wrote for people", () => {
    clock = 0;
    const steps = progress([
      {
        id: "input",
        kind: "user",
        content: { content: "Check my PRs" },
        timestamp_ms: epoch,
      },
      call("list", "fs.list_files", { path: "/workspace" }),
      result("list", "completed"),
      call("exec", "env.exec", {
        command: "gh pr list --state open --json number",
        description: "Check the open pull requests",
      }),
      result("exec", "completed"),
      call("read", "fs.read_file", { path: "/workspace/reports/pr-checks.json" }),
      result("read", "completed"),
      call("grep", "fs.grep", { pattern: "flaky" }),
      result("grep", "failed"),
      call("send", "im_api.internal.send_message", {
        content: [{ type: "text", text: "Found 6 open\npull requests" }],
      }),
      result("send", "completed"),
      // A tool without reader words is not a step.
      call("snapshot", "browser.snapshot", { url: "https://example.com" }),
      result("snapshot", "completed"),
    ]);
    expect(
      steps.steps.map(({ kind, detail, failed }) => ({ kind, detail, failed }))
    ).toEqual([
      { kind: "browse", detail: undefined, failed: false },
      { kind: "command", detail: "Check the open pull requests", failed: false },
      { kind: "read", detail: "pr-checks.json", failed: false },
      { kind: "search", detail: "flaky", failed: true },
      { kind: "update", detail: "Found 6 open pull requests", failed: false },
    ]);
    // The model requests between the tools are not steps.
    expect(steps.current).toBeUndefined();
  });

  it("calls a step current only on the owner's live evidence", () => {
    clock = 0;
    const finished = [
      call("read", "fs.read_file", { path: "/a/notes.md" }),
      result("read", "completed"),
    ];
    const exec = call("exec", "env.exec", { description: "Build the chart" });
    // The owner's overlay for the same call, from the live stream.
    const overlay = (live: boolean): SessionHistoryRecord => ({
      id: `execution:tool:exec:${String(live)}`,
      kind: "tool",
      content: { tool_call_id: "exec", tool_name: "env.exec", status: "running" },
      timestamp_ms: epoch + clock + 100,
      execution: {
        id: "exec",
        lane: "tool",
        started_at_ms: epoch + clock + 100,
        observed_at_ms: epoch + clock + 100,
        completed_at_ms: null,
        duration_ms: 0,
        live,
      },
    });
    expect(progress([...finished, exec, overlay(true)]).current).toMatchObject({
      kind: "command",
      detail: "Build the chart",
    });

    // A durable running receipt, a call without a result, and an overlay from
    // a reconnecting stream prove nothing: neither current nor finished.
    for (const unknown of [
      [exec, result("exec", "running")],
      [exec],
      [exec, overlay(false)],
    ]) {
      const view = progress([...finished, ...unknown]);
      expect(view.current).toBeUndefined();
      expect(view.steps.map((step) => step.detail)).toEqual(["notes.md"]);
    }

    const thinking = (live?: boolean): SessionHistoryRecord => ({
      id: `thinking:${String(live)}`,
      kind: "assistant",
      content: {},
      timestamp_ms: epoch + 9000,
      execution: model("thinking", 9000, null, live),
    });
    const now = progress([...finished, thinking(true)]).current;
    expect(now).toBeDefined();
    expect(now?.kind).toBe("thinking");
    expect(progress([...finished, thinking()]).current).toBeUndefined();
    expect(progress([...finished, thinking(false)]).current).toBeUndefined();
  });

  it("shows a row the described step in progress, else the last finished step", () => {
    const step = (
      id: string,
      kind: WorkerStep["kind"],
      detail?: string
    ): WorkerStep => ({
      id,
      at: epoch,
      kind,
      detail,
    });
    const finished = [
      step("a", "read", "notes.md"),
      step("b", "command", "Build the chart"),
    ];
    expect(
      latestWorkerStep({
        steps: finished,
        current: step("c", "command", "Draw the chart"),
      })?.id
    ).toBe("c");
    // Thinking or an undescribed tool says less than the step before it.
    expect(
      latestWorkerStep({ steps: finished, current: step("c", "thinking") })?.id
    ).toBe("b");
    expect(latestWorkerStep({ steps: [], current: step("c", "thinking") })?.id).toBe(
      "c"
    );
    expect(latestWorkerStep({ steps: [], current: undefined })).toBeUndefined();
  });
});
