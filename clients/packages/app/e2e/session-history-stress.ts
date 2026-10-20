import type { ServerResponse } from "node:http";
import type { SessionHistoryRecord } from "@comma/core-client";
import { sessionStressRecords } from "./fixtures/session-history-stress-records";
import { chatSmokeWorkspaceChat, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

export {
  sessionStressLiveRecord,
  sessionStressRecords,
} from "./fixtures/session-history-stress-records";

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
