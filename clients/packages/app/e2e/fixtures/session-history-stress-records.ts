import type { SessionHistoryRecord } from "@comma/core-client";

/** Explicit test data, shared by the browser regression and manual stress preview. */
export function sessionStressRecords(
  turns = 500,
  epoch = 1_788_564_963_000
): SessionHistoryRecord[] {
  const records: SessionHistoryRecord[] = [];
  for (let turn = 0; turn < turns; turn++) {
    const start = epoch + turn * 12_000;
    const execution = (
      id: string,
      lane: "model" | "tool",
      from: number,
      to: number,
      done = true
    ) => ({
      id,
      lane,
      started_at_ms: start + from,
      observed_at_ms: start + to,
      completed_at_ms: done ? start + to : null,
      duration_ms: to - from,
    });
    const add = (
      kind: string,
      content: SessionHistoryRecord["content"],
      offset: number,
      timing?: SessionHistoryRecord["execution"]
    ) => {
      records.push({
        id: String(records.length + 1),
        kind,
        content,
        created_at: start + offset,
        timestamp_ms: start + offset,
        execution: timing ?? null,
      });
    };
    const a = `stress-${turn}-a`,
      b = `stress-${turn}-b`;
    add("summary", { content: `压测上下文 ${turn + 1}` }, 0);
    add("user", { content: `压测输入 ${turn + 1} · 分页 / 并行工具 / 异步结果` }, 0);
    add(
      "assistant",
      {
        model: "模拟模型",
        input_tokens: 12000 + turn * 20,
        output_tokens: 160,
        cache_read_input_tokens: 9600 + turn * 16,
        cache_write_input_tokens: 0,
        tool_calls: [
          {
            id: a,
            name: "read",
            args: { environment: "test-workspace", path: `fixtures/${turn}/a.txt` },
          },
          {
            id: b,
            name: "read",
            args: { environment: "test-workspace", path: `fixtures/${turn}/b.txt` },
          },
        ],
      },
      1600,
      {
        ...execution(`model-${turn}`, "model", 20, 1600),
        first_token_at_ms: start + 1200,
      }
    );
    add(
      "tool",
      { tool_call_id: a, status: "running", tool_name: "read" },
      1602,
      execution(a, "tool", 1601, 1602, false)
    );
    add(
      "tool",
      { tool_call_id: b, status: "running", tool_name: "read" },
      1604,
      execution(b, "tool", 1603, 1604, false)
    );
    add(
      "runtime",
      {
        type: "tool_call_completed",
        tool_call_id: a,
        tool_name: "read",
        result: {
          status: "completed",
          content: `压测结果 ${turn + 1} A · ${"完整 JSON 长行 ".repeat(30)}`,
        },
      },
      1801,
      execution(a, "tool", 1601, 1801)
    );
    add(
      "runtime",
      {
        type: "tool_call_completed",
        tool_call_id: b,
        tool_name: "read",
        result:
          turn % 10 === 0
            ? { status: "failed", error_message: "压测错误样例" }
            : { status: "completed", content: `压测结果 ${turn + 1} B` },
      },
      2103,
      execution(b, "tool", 1603, 2103)
    );
    add(
      "runtime",
      { type: "migration_notice", summary: `压测 migration notice ${turn + 1}` },
      2110
    );
    add("runtime", { type: "notice", content: `压测 runtime 消息 ${turn + 1}` }, 2120);
    add(
      "assistant",
      {
        content: "",
        model: "模拟模型",
        input_tokens: 13000 + turn * 20,
        output_tokens: 240,
        cache_read_input_tokens: 10400 + turn * 16,
        cache_write_input_tokens: 0,
      },
      3500,
      execution(`final-${turn}`, "model", 2200, 3500)
    );
  }
  return records;
}

/** One running tool, as the live stream reports it after every loaded page. */
export function sessionStressLiveRecord(now = Date.now()): SessionHistoryRecord {
  return {
    id: "stress-live",
    kind: "tool",
    content: { status: "running", tool_name: "read", tool_call_id: "stress-live" },
    created_at: now,
    timestamp_ms: now,
    execution: {
      id: "stress-live",
      lane: "tool",
      started_at_ms: now - 1000,
      observed_at_ms: now,
      completed_at_ms: null,
      duration_ms: 1000,
      live: true,
    },
  };
}
