import type { ServerResponse } from "node:http";
import type { SessionHistoryRecord } from "@comma/native-bridge";
import { chatSmokeWorkspaceChat, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

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

const writeLiveFrame = (
  response: ServerResponse,
  liveRecords: SessionHistoryRecord[]
) =>
  response.write(
    `event: history\ndata: ${JSON.stringify({
      conversation_id: chatSmokeWorkspaceChat.id,
      participant_id: "ptp-router-smoke",
      phase: "recent",
      records: [],
      live_records: liveRecords,
      server_time_ms: Date.now(),
      checkpoint: null,
    })}\n\n`
  );

export async function startSessionStressStub(
  records = sessionStressRecords(),
  requests: URL[] = [],
  port = 0
) {
  let events: ServerResponse | undefined;
  let live: SessionHistoryRecord[] | undefined;
  const stub = await startChatSmokeStub({
    port,
    sessionEmail: "session-stress@comma.local",
    priorUserMessage: `Session 分页压测 · ${records.length} 条模拟记录（测试数据）`,
    priorAssistantReply:
      "打开 Router 的 Session。每页 50 条，点击加载更早记录；包含并行工具、异步回执、错误和 migration notice。",
    sessionHistory(url) {
      requests.push(url);
      const end = Number(url.searchParams.get("before") ?? records.length + 1) - 1;
      const start = Math.max(0, end - Number(url.searchParams.get("limit")));
      return {
        body: {
          conversation_id: chatSmokeWorkspaceChat.id,
          participant_id: "ptp-router-smoke",
          records: records.slice(start, end),
          has_more: start > 0,
          next_before: start > 0 ? String(start + 1) : null,
        },
      };
    },
    sessionHistoryEvents(_url, response) {
      events = response;
      response.on("close", () => {
        if (events === response) events = undefined;
      });
      const now = Date.now();
      const recent = records.filter(
        (record) =>
          (record.execution?.observed_at_ms ?? record.timestamp_ms ?? 0) >=
          now - 180_000
      );
      for (let index = 0; index < recent.length; index += 50)
        response.write(
          `event: history\ndata: ${JSON.stringify({
            conversation_id: chatSmokeWorkspaceChat.id,
            participant_id: "ptp-router-smoke",
            phase: "recent",
            records: recent.slice(index, index + 50),
            live_records: [],
            server_time_ms: now,
            checkpoint: null,
          })}\n\n`
        );
      // The runtime reopens the stream after its own timeout and keeps no live
      // state across that gap; a real server reports the running tools again.
      if (live) writeLiveFrame(response, live);
    },
  });
  return Object.assign(stub, {
    /** Report the running tools on the history stream, as a live session does
     * between pages. Each frame publishes a new snapshot to the page; a stream
     * that is reconnecting receives the current state when it reopens. */
    pushHistoryFrame(liveRecords: SessionHistoryRecord[]) {
      live = liveRecords;
      if (events && !events.destroyed) writeLiveFrame(events, liveRecords);
    },
  });
}
