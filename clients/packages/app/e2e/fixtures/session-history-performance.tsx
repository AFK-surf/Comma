import { useLayoutEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { initializeCommaI18n } from "@comma/i18n";
import { CoreProvider } from "@comma/core-client";
import type { SessionHistoryRecord, SessionHistoryValue } from "@comma/core-client";
// A fixture page builds with the web app's aliases, which leave test packages out.
import { createScriptedCore } from "../../../test-utils/src/scripted-core";
import { ChatProvider } from "../../src/components/chat/ChatProvider";
import { SessionHistoryPage } from "../../src/components/chat/session-history/SessionHistory";
import { sessionStressRecords } from "./session-history-stress-records";
import "../../src/styles.css";

initializeCommaI18n(["en"]);
const count = Number(new URLSearchParams(location.search).get("count") ?? 100);
// `?stress=N`: the first N records of the stress history, every page already read (a cold render of all of them).
const stress = Number(new URLSearchParams(location.search).get("stress") ?? 0);
const now = Date.now();
const session = {
  audience: location.origin,
  authorityInstanceId: "session-history-performance",
  generation: 1,
  sessionId: "11111111-1111-4111-8111-111111111111",
};
const target = {
  groupId: "group",
  conversationId: "conversation",
  participantId: "participant",
};
const records: SessionHistoryRecord[] = Array.from({ length: count }, (_, index) => {
  const started = now - (count - index) * 2000;
  return {
    id: `${index + 1}`,
    kind: "tool",
    content: {
      tool_call_id: `tool-${index}`,
      tool_name: "read",
      status: "success",
      result: { content: `Read file ${index}` },
    },
    timestamp_ms: started,
    execution: {
      id: `tool-${index}`,
      lane: "tool",
      started_at_ms: started,
      observed_at_ms: started + 100,
      completed_at_ms: started + 100,
      duration_ms: 100,
    },
  };
});
const live: SessionHistoryRecord = {
  id: "live",
  kind: "tool",
  content: { tool_call_id: "live", tool_name: "read", status: "running" },
  timestamp_ms: now - 1000,
  execution: {
    id: "live",
    lane: "tool",
    started_at_ms: now - 1000,
    observed_at_ms: now,
    completed_at_ms: null,
    duration_ms: 1000,
    live: true,
  },
};
let snapshot: SessionHistoryValue = {
  ...target,
  records: stress
    ? sessionStressRecords(Math.ceil(stress / 10)).slice(0, stress)
    : records,
  recentRecords: [],
  liveRecords: stress ? [] : [live],
  clockOffsetMs: 0,
  streamStatus: "live",
  hasMore: false,
  nextBefore: null,
  status: "ready",
  loaded: "detail",
  error: null,
};
// The client core as the page sees it: the history's value, then each change.
const core = createScriptedCore({
  values: (topic) => (topic.topic === "history" ? snapshot : undefined),
  calls: async () => null,
});
declare global {
  interface Window {
    sessionHistoryStress: {
      setVisible(active: boolean): void;
      pause(): void;
      resume(): void;
      complete(): void;
      startModel(): void;
      startFutureOverlap(): number;
      heartbeat(): void;
      append(): void;
    };
  }
}
function publish(next: SessionHistoryValue) {
  snapshot = next;
  core.emit("history", snapshot);
}
window.sessionHistoryStress = {
  setVisible: () => undefined,
  startFutureOverlap: () => {
    const current = Date.now();
    publish({
      ...snapshot,
      records: [
        ...records.map((record, index) =>
          index === 0 ? { ...record, execution: null } : record
        ),
        {
          id: "future-model",
          kind: "assistant",
          content: { text: "Future observed response" },
          timestamp_ms: current + 10000,
          execution: {
            id: "future-model",
            lane: "model",
            started_at_ms: current + 10000,
            observed_at_ms: current + 11000,
            completed_at_ms: current + 11000,
            first_token_at_ms: current + 10500,
            duration_ms: 1000,
          },
        },
      ],
      liveRecords: [
        {
          ...live,
          id: "overlapping-model",
          kind: "assistant",
          content: { text: "Live response" },
          timestamp_ms: current - 100,
          execution: {
            id: "overlapping-model",
            lane: "model",
            started_at_ms: current - 100,
            observed_at_ms: current,
            completed_at_ms: null,
            first_token_at_ms: null,
            duration_ms: 100,
            live: true,
          },
        },
      ],
      streamStatus: "live",
    });
    return current;
  },
  startModel: () =>
    publish({
      ...snapshot,
      liveRecords: [
        {
          ...live,
          id: "live-model",
          kind: "assistant",
          content: {
            tool_calls: [{ id: "pending-tool", name: "read", arguments: {} }],
          },
          execution: {
            ...live.execution!,
            id: "live-model",
            lane: "model",
            first_token_at_ms: null,
          },
        },
      ],
    }),
  pause: () => publish({ ...snapshot, streamStatus: "reconnecting" }),
  resume: () => publish({ ...snapshot, streamStatus: "live" }),
  complete: () =>
    publish({
      ...snapshot,
      liveRecords: [],
      records: [
        ...records,
        {
          ...live,
          content: {
            tool_call_id: "live",
            tool_name: "read",
            status: "success",
            result: { content: "Finished live read" },
          },
          execution: {
            ...live.execution!,
            live: false,
            completed_at_ms: Date.now(),
            duration_ms: Date.now() - live.execution!.started_at_ms,
          },
        },
      ],
    }),
  // The core sends a change only for records that changed: a copy changes none.
  heartbeat: () => publish(structuredClone(snapshot)),
  append: () => {
    const copy = structuredClone(snapshot);
    const started = Date.now();
    const id = String(copy.records.length + 1);
    publish({
      ...copy,
      records: [
        ...copy.records,
        {
          id,
          kind: "tool",
          content: {
            tool_call_id: `appended-${id}`,
            tool_name: "read",
            status: "success",
            result: { content: `Read appended file ${id}` },
          },
          timestamp_ms: started,
          execution: {
            id: `appended-${id}`,
            lane: "tool",
            started_at_ms: started,
            observed_at_ms: started + 100,
            completed_at_ms: started + 100,
            duration_ms: 100,
          },
        },
      ],
    });
  },
};
function Fixture() {
  const [active, setActive] = useState(true);
  useLayoutEffect(() => {
    window.sessionHistoryStress.setVisible = setActive;
  }, []);
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        height: "100vh",
        width: "min(1000px, 100vw)",
      }}
    >
      <CoreProvider client={core.client}>
        <ChatProvider productLease={session}>
          <section
            hidden={!active}
            style={{
              display: active ? "flex" : "none",
              flex: 1,
              minHeight: 0,
              flexDirection: "column",
            }}
          >
            <SessionHistoryPage
              active={active}
              groupId={target.groupId}
              participant={{ ...target, name: "Performance session" }}
            />
          </section>
        </ChatProvider>
      </CoreProvider>
    </div>
  );
}
createRoot(document.getElementById("root")!).render(<Fixture />);
