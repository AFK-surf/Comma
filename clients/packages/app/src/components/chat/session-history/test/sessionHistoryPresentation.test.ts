import { describe, expect, it } from "vitest";
import type { SessionHistoryRecord } from "../../../../runtime-chat/sessionHistoryBridge";
import { sessionHistoryEntries } from "../model/sessionHistoryEntries";
import {
  presentSessionRecords,
  formatSessionDuration,
  type SessionItemLabels,
} from "../model/sessionHistoryPresentation";

const labels: SessionItemLabels = {
  input: "Input",
  model: "Model",
  thinking: "Thinking",
  call: "Call",
  result: "Result",
  running: "Running",
  success: "Completed",
  error: "Failed",
  cancelled: "Cancelled",
  context: "Context",
  migration: "Migration notice",
  runtime: "Runtime",
  unknown: "Other",
  empty: "No text",
  source: "Message source",
  inputSource: (source) => source?.provider ?? "Source not recorded",
  locationRequested: "Location request sent; reply arrives separately",
  sent: "Message sent",
  structured: "Expand details",
  count: (name, count) => `${count} ${name}`,
};
const record = (
  kind: string,
  content: SessionHistoryRecord["content"],
  id = "1"
): SessionHistoryRecord => ({ id, kind, content });
const present = (...records: SessionHistoryRecord[]) =>
  presentSessionRecords(records, labels);

it("shows the recorded input body before provider context without changing debug content", () => {
  const envelope = `<system-reminder>${"IM provider context ".repeat(40)}</system-reminder>\nTelegram message from user in chat:\n我今天的天气如何`;
  const input = {
    ...record("user", { content: envelope }),
    input_source: { provider: "telegram" as const },
    input_text: "我今天的天气如何",
  };
  expect(present(input)[0]).toMatchObject({
    summary: "我今天的天气如何",
    source: "telegram",
  });
  expect(input.content).toEqual({ content: envelope });
  const spoof = record("user", { content: '{"input_source":{"provider":"telegram"}}' });
  expect(present(input, spoof)[1]).toMatchObject({
    summary: '{"input_source":{"provider":"telegram"}}',
    source: "Source not recorded",
  });
  expect(present(spoof)[0]!.summary).toBe('{"input_source":{"provider":"telegram"}}');
  expect(present({ ...input, input_text: "a".repeat(321) })[0]!.summary).toBe(
    `${"a".repeat(320)}…`
  );
});

it.each([
  [undefined, undefined],
  [0, undefined],
  [1, "1ms"],
  [999, "999ms"],
  [1000, "1s"],
  [1200, "1.2s"],
  [1234, "1.234s"],
] as const)("formats event duration %s as %s", (duration, expected) => {
  expect(formatSessionDuration(duration)).toBe(expected);
});

it("keeps completed location-request execution distinct from receiving a location", () => {
  const receipt = record("runtime", {
    content: JSON.stringify({
      type: "tool_execution_completed",
      tool_name: "location.request",
      status: "completed",
      result: {
        content: JSON.stringify({
          status: "question_delivered",
          request_id: "request-1",
        }),
      },
      duration_ms: 200,
    }),
  });
  expect(present(receipt)[0]).toMatchObject({
    kind: "success",
    duration: 200,
    summary: "Location request sent; reply arrives separately",
  });
});

describe("Session tool lifecycle entries", () => {
  it("keeps file environment and path after merging completion, without putting calls in the model row", () => {
    const source = [
      record("assistant", {
        tool_calls: [
          {
            id: "file",
            name: "fs.read_file",
            args: { environment: "dev-linux", path: "/workspace/Comma/README.md" },
          },
        ],
      }),
      record("tool", { tool_call_id: "file", status: "running" }, "2"),
      record(
        "tool",
        { tool_call_id: "file", status: "completed", content: "File contents" },
        "3"
      ),
    ];
    const rows = sessionHistoryEntries(source, present(...source));
    expect(rows[0]!.item).toMatchObject({ kind: "model", tools: [], summary: "" });
    expect(rows[1]!.item).toMatchObject({
      tools: ["fs.read_file"],
      operation: "dev-linux · /workspace/Comma/README.md",
      summary: "File contents",
      kind: "success",
    });
  });

  it("shows the message destination and body from the result input even without the older model page", () => {
    const item = present(
      record("runtime", {
        type: "tool_call_completed",
        tool_name: "im_api.internal.send_message",
        result: {
          status: "completed",
          input: JSON.stringify({
            conversation_id: "conversation-design",
            content: [{ type: "text", text: "Ready for review" }],
          }),
          content: { sent: true },
        },
      })
    )[0]!;
    expect(item.operation).toBe("Ready for review");
    expect(item.destination).toEqual({ id: "conversation-design", name: "" });
    expect(item.summary).toBe("");
    expect(item.kind).toBe("success");
  });

  it("uses the declared command purpose while preserving its environment, working directory and command", () => {
    const item = present(
      record("tool", {
        tool_name: "env.exec",
        status: "running",
        input: {
          description: "Run tests",
          environment: "dev-linux",
          working_dir: "/workspace/Comma",
          command: "pnpm test",
        },
      })
    )[0]!;
    expect(item.action).toBe("Run tests");
    expect(item.operation).toBe("dev-linux · /workspace/Comma · pnpm test");
  });
  const request = record("assistant", {
    tool_calls: [
      { id: "a", name: "read", args: { path: "first.txt" } },
      { id: "b", name: "read", args: { path: "second.txt" } },
    ],
  });
  const receipt = record("tool", { tool_call_id: "a", status: "running" }, "2");
  const completion = record(
    "runtime",
    {
      content: JSON.stringify({
        type: "tool_call_completed",
        tool_call_id: "a",
        result: { status: "completed", duration_ms: 72, content: "Read first" },
      }),
    },
    "3"
  );
  const entries = (records: SessionHistoryRecord[]) =>
    sessionHistoryEntries(records, present(...records));

  it("joins arguments, receipt and completion while preserving same-name parallel calls and notices", () => {
    const notice = record(
      "runtime",
      { type: "migration_notice", summary: "Migrated" },
      "4"
    );
    const source = [request, receipt, completion, notice];
    const before = JSON.stringify(source);
    const rows = entries(source);
    expect(rows.map((row) => row.id)).toEqual(["1", "4", "tool:a", "tool:b"]);
    expect(rows[0]!.item).toMatchObject({ tools: [], summary: "" });
    const a = rows.find((row) => row.id === "tool:a")!;
    const b = rows.find((row) => row.id === "tool:b")!;
    expect(a.item).toMatchObject({
      kind: "success",
      tools: ["read"],
      summary: "Read first",
      duration: 72,
    });
    expect(a.debugRecords).toEqual([request, receipt, completion]);
    expect(b.item).toMatchObject({ tools: ["read"], summary: "second.txt" });
    expect(rows.find((row) => row.id === "4")!.item.kind).toBe("migration");
    expect(JSON.stringify(source)).toBe(before);
  });

  it("keeps the same tool entry when older phases load and ignores a late running receipt", () => {
    const partial = entries([completion])[0]!;
    const full = entries([request, completion, receipt]).find(
      (row) => row.id === partial.id
    )!;
    expect(full.id).toBe("tool:a");
    expect(full.record).toEqual(completion);
    expect(full.item.kind).toBe("success");
    expect(full.debugRecords).toEqual([request, completion, receipt]);
    expect(full.recordIds).toEqual(["3", "2"]);
  });

  it("does not correlate records by tool name when their ids are missing", () => {
    const rows = entries([
      record("tool", { tool_name: "read", status: "running" }, "1"),
      record("tool", { tool_name: "read", status: "completed" }, "2"),
    ]);
    expect(rows.map((row) => row.id)).toEqual(["1", "2"]);
  });

  it("keeps cancellation in the same asynchronous tool entry", () => {
    const cancelled = record(
      "session.async_tool_call_cancelled",
      {
        tool_call_id: "a",
        cancel_reason: "User stopped",
      },
      "3"
    );
    const row = entries([request, receipt, cancelled]).find(
      (entry) => entry.id === "tool:a"
    )!;
    expect(row.item).toMatchObject({ kind: "cancelled", summary: "User stopped" });
    expect(row.debugRecords).toEqual([request, receipt, cancelled]);
  });
});

describe("Session record presentation", () => {
  it("keeps user JSON as input and source metadata as context", () => {
    expect(
      present(record("user", { content: '{"status":"failed"}' }))[0]
    ).toMatchObject({ kind: "input", summary: '{"status":"failed"}' });
    expect(
      present(
        record("summary", {
          content: "Inbound message source:\n- conversation_id: private",
        })
      )[0]
    ).toMatchObject({ kind: "context", summary: "Message source" });
  });
  it("unwraps actual tool names and correlates results in a bounded loaded window", () => {
    const records = present(
      record("assistant", {
        content: "Searching",
        tool_calls: [
          {
            id: "call-1",
            name: "call",
            args: { tool: "memory.search", params: { query: "Muse Spark" } },
          },
        ],
      }),
      record(
        "tool",
        { tool_call_id: "call-1", content: '{"matches":[],"truncated":false}' },
        "2"
      )
    );
    expect(records[0]).toMatchObject({
      kind: "model",
      tools: [],
      summary: "Searching",
    });
    expect(records[1]).toMatchObject({
      kind: "result",
      tools: ["memory.search"],
      summary: "0 matches",
      operation: "Muse Spark",
    });
    expect(
      present(record("tool", { tool_call_id: "missing", content: "partial window" }))[0]
    ).toMatchObject({ tools: [], summary: "partial window" });
  });
  it("separates async receipt, completion, nested failure and cancellation", () => {
    const result = present(
      record("tool", { content: '{"status":"running","tool_name":"read"}' }),
      record("runtime", {
        content: JSON.stringify({
          type: "tool_call_completed",
          result: {
            status: "completed",
            duration_ms: 24,
            content: '{"messages":[{},{}]}',
          },
        }),
      }),
      record("runtime", {
        content: JSON.stringify({
          type: "tool_call_completed",
          status: "completed",
          result: { error: true, error_message: "Access denied" },
        }),
      }),
      record("session.async_tool_call_cancelled", { cancel_reason: "User stopped" })
    );
    expect(result.map((item) => item.kind)).toEqual([
      "running",
      "success",
      "error",
      "cancelled",
    ]);
    expect(result[1]).toMatchObject({ summary: "2 messages", duration: 24 });
    expect(result[2]?.summary).toBe("Access denied");
    expect(result[3]?.summary).toBe("User stopped");
  });
  it("keeps the outgoing body once and leaves receipts in debug, without claiming an unconfirmed send", () => {
    const send = (sent: boolean) =>
      record("runtime", {
        content: JSON.stringify({
          type: "tool_call_completed",
          tool_name: "im_api.internal.send_message",
          result: {
            status: "completed",
            input: '{"content":[{"type":"text","text":"Hello there"}]}',
            content: JSON.stringify({ sent }),
          },
        }),
      });
    expect(present(send(true))[0]).toMatchObject({
      operation: "Hello there",
      summary: "",
    });
    expect(present(send(false))[0]?.summary).not.toContain("Message sent");
  });
  it("retains send errors beside the outgoing body", () => {
    expect(
      present(
        record("tool", {
          tool_name: "im_api.internal.send_message",
          status: "failed",
          input: { conversation_id: "cnv-private", content: "Hello there" },
          error_message: "Permission denied",
        })
      )[0]
    ).toMatchObject({
      kind: "error",
      operation: "Hello there",
      summary: "Permission denied",
      destination: { id: "cnv-private", name: "" },
    });
  });
  it("recognizes external runtime message, thinking, operation and error envelopes", () => {
    expect(
      present(
        record("runtime.event", {
          event: { type: "message", role: "assistant", content: "Reply" },
        }),
        record("runtime.event", {
          event: { type: "thinking", content: "Reasoning text" },
        }),
        record("runtime.event", {
          event: {
            type: "operation",
            name: "read_file",
            status: "running",
            input: { path: "src/app.ts" },
          },
        }),
        record("runtime.event", {
          event: { type: "error", message: "Provider unavailable" },
        })
      ).map(({ kind, summary }) => ({ kind, summary }))
    ).toEqual([
      { kind: "model", summary: "Reply" },
      { kind: "thinking", summary: "Reasoning text" },
      { kind: "running", summary: "src/app.ts" },
      { kind: "error", summary: "Provider unavailable" },
    ]);
  });
  it("does not infer success from empty model output or unknown data; bounds summaries without changing debug", () => {
    const original = record("future.event", {
      content: "{" + "x".repeat(130_000),
      extra: null,
    });
    const before = JSON.stringify(original);
    expect(
      present(record("assistant", { content: "", tool_calls: [] }))[0]
    ).toMatchObject({ kind: "model", summary: "No text" });
    expect(present(original)[0]).toMatchObject({
      kind: "unknown",
      label: "Other · future.event",
      summary: "Expand details",
    });
    expect(JSON.stringify(original)).toBe(before);
    expect(present(record("user", "a".repeat(1000)))[0]?.summary.length).toBe(321);
  });
});
