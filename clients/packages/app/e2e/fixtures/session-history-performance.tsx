import { useLayoutEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { initializeCommaI18n } from "@comma/i18n";
import type {
  CommaNativeBridge,
  SessionHistoryEnvelope,
  SessionHistoryRecord,
} from "@comma/native-bridge";
import { createCommaApi } from "../../src/api";
import { ChatProvider } from "../../src/components/chat/ChatProvider";
import { SessionHistoryPage } from "../../src/components/chat/session-history/SessionHistory";
import {
  sessionTimeline,
  sessionTimelineAxis,
  sessionTimelineBars,
  sessionIdleMarkers,
  sessionZoomAxis,
} from "../../src/components/chat/session-history/timeline/sessionHistoryTimelineModel";
import type { SessionItemPresentation } from "../../src/components/chat/session-history/model/sessionHistoryPresentation";
import { SessionHistoryBridgeProvider } from "../../src/runtime-chat/sessionHistoryBridge";
import "../../src/styles.css";

initializeCommaI18n(["en"]);
const count = Number(new URLSearchParams(location.search).get("count") ?? 100);
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
let envelope: SessionHistoryEnvelope = {
  session,
  snapshot: {
    ...target,
    records,
    recentRecords: [],
    liveRecords: [live],
    clockOffsetMs: 0,
    streamStatus: "live",
    hasMore: false,
    nextBefore: null,
    status: "ready",
    loaded: "detail",
    error: null,
    revision: 1,
  },
};
const listeners = new Set<(value: SessionHistoryEnvelope) => void>();
const get = async () => envelope;
const bridge: CommaNativeBridge["sessionHistory"] = {
  state: Object.assign(get, {
    get,
    subscribe: (listener: (value: SessionHistoryEnvelope) => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  }),
  retain: get,
  load: get,
  release: async () => true,
};
declare global {
  interface Window {
    sessionHistoryStress: {
      measureFoldedProjection(): Promise<{
        folds: number;
        bars: number;
        samples: number[];
        totalMs: number;
        checksum: number;
      }>;
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
function publish(snapshot: SessionHistoryEnvelope["snapshot"]) {
  envelope = {
    session,
    snapshot: { ...snapshot, revision: envelope.snapshot.revision + 1 },
  };
  for (const notify of listeners) notify(envelope);
}
window.sessionHistoryStress = {
  measureFoldedProjection,
  setVisible: () => undefined,
  startFutureOverlap: () => {
    const current = Date.now();
    publish({
      ...envelope.snapshot,
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
      ...envelope.snapshot,
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
  pause: () => publish({ ...envelope.snapshot, streamStatus: "reconnecting" }),
  resume: () => publish({ ...envelope.snapshot, streamStatus: "live" }),
  complete: () =>
    publish({
      ...envelope.snapshot,
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
  // Hosts deliver every snapshot as a structured clone (Electron IPC, the web
  // SharedWorker port), so unchanged records arrive as new objects.
  heartbeat: () => publish(structuredClone(envelope.snapshot)),
  append: () => {
    const snapshot = structuredClone(envelope.snapshot);
    const started = Date.now();
    const id = String(snapshot.records.length + 1);
    publish({
      ...snapshot,
      records: [
        ...snapshot.records,
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
const api = createCommaApi({
  baseUrl: location.origin,
  token: "",
  sessionTransport: {
    applyHeaders: () => undefined,
    credentials: "include",
    reportSessionRejection: () => undefined,
    signal: new AbortController().signal,
  },
});
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
      <ChatProvider api={api} productLease={session}>
        <SessionHistoryBridgeProvider bridge={bridge}>
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
        </SessionHistoryBridgeProvider>
      </ChatProvider>
    </div>
  );
}
createRoot(document.getElementById("root")!).render(<Fixture />);

async function measureFoldedProjection() {
  const epoch = 1_720_000_000_000;
  const mixed: SessionHistoryRecord[] = Array.from({ length: 5000 }, (_, index) => {
    const start = epoch + Math.floor(index / 2) * 5000;
    if (index % 2 === 0)
      return {
        id: String(index + 1),
        kind: "user",
        content: {},
        timestamp_ms: start,
      };
    const isLive = index === 4999;
    return {
      id: String(index + 1),
      kind: "assistant",
      content: {},
      timestamp_ms: start + 20,
      execution: {
        id: `model-${index}`,
        lane: "model",
        started_at_ms: start + 20,
        first_token_at_ms: start + 30,
        observed_at_ms: start + 100,
        completed_at_ms: isLive ? null : start + 100,
        duration_ms: 80,
        live: isLive,
      },
    };
  });
  const items: SessionItemPresentation[] = mixed.map((record) => ({
    kind: record.kind === "user" ? "input" : "model",
    label: record.kind,
    summary: "",
    tools: [],
    duration: record.execution?.duration_ms,
  }));
  const samples: number[] = [];
  let checksum = 0,
    folds = 0,
    bars = 0;
  // Three warm-up ticks precede the twenty measured projections. Fixture setup
  // and the model build are outside this coordinate-lookup regression budget.
  for (let tick = -3; tick < 20; tick++) {
    await new Promise(requestAnimationFrame);
    const model = sessionTimeline(
      mixed,
      items,
      undefined,
      mixed.at(-1)!.execution!.observed_at_ms + Math.max(0, tick) * 100
    );
    const base = sessionTimelineAxis(model);
    const axis = sessionZoomAxis(base, model.start, model.end);
    const begin = performance.now();
    const projected = sessionTimelineBars(model, axis, 1100);
    const markers = sessionIdleMarkers(axis, 1100);
    const ticks = [0, 0.25, 0.5, 0.75, 1].map((fraction) => axis.timeAt(fraction));
    if (tick >= 0) samples.push(performance.now() - begin);
    checksum +=
      projected.reduce((sum, bar) => sum + bar.left + bar.width, 0) +
      markers.length +
      ticks.reduce((sum, time) => sum + time, 0);
    folds = base.folds.length;
    bars = projected.length;
  }
  return {
    folds,
    bars,
    samples,
    totalMs: samples.reduce((sum, ms) => sum + ms, 0),
    checksum,
  };
}
