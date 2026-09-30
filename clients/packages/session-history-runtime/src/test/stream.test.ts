import { expect, it, vi } from "vitest";
import { SessionHistoryRuntime } from "../index";
import { readHistoryStream } from "../stream";
import type { SessionHistoryStreamFrame } from "@comma/native-bridge";

const input = {
  groupId: "g",
  conversationId: "c",
  participantId: "p",
  session: {
    audience: "https://api.comma.test",
    authorityInstanceId: "host",
    sessionId: "a",
    generation: 1,
  },
};
const record = (id: number) => ({
  id: String(id),
  kind: "user",
  content: `输入 ${id}`,
  timestamp_ms: Date.now(),
});
const frame = (
  phase: SessionHistoryStreamFrame["phase"],
  ids: number[],
  checkpoint: string | null = null
): SessionHistoryStreamFrame => ({
  conversation_id: "c",
  participant_id: "p",
  phase,
  records: ids.map(record),
  checkpoint,
  live_records: [],
  server_time_ms: Date.now(),
});

it("parses fragmented UTF-8 SSE frames using the host's authenticated fetch", async () => {
  const encoded = new TextEncoder().encode(
    `: heartbeat\n\nevent: history\ndata: ${JSON.stringify(frame("recent", [1]))}\n\n`
  );
  const fetcher = vi.fn(
    async () =>
      new Response(
        new ReadableStream({
          start(controller) {
            for (const byte of encoded) controller.enqueue(new Uint8Array([byte]));
            controller.close();
          },
        })
      )
  );
  const receive = vi.fn();
  await readHistoryStream(
    fetcher,
    new URL(input.session.audience),
    { headers: { authorization: "Bearer host-only" } },
    receive
  );
  expect(receive).toHaveBeenCalledTimes(1);
  expect(receive.mock.calls[0]![0].records[0].content).toBe("输入 1");
  expect(fetcher.mock.calls[0]).toBeDefined();
});

it("shares one stream, retains manual pages during replay and fences disconnected callbacks", async () => {
  vi.useFakeTimers();
  const controller = new AbortController();
  const connections: {
    url: URL;
    publish: (value: SessionHistoryStreamFrame) => void;
    close(): void;
  }[] = [];
  let resolvePage!: (response: Response) => void;
  const runtime = new SessionHistoryRuntime({
    authority: {
      acquireProductCredential: () => ({
        audience: input.session.audience,
        token: "host-only",
        signal: controller.signal,
      }),
      isCurrentProductCredential: (c) => !c.signal.aborted,
    },
    fetch: async () =>
      new Promise((resolve) => {
        resolvePage = resolve;
      }),
    stream: async (_fetch, url, init, publish) =>
      new Promise<void>((resolve) => {
        connections.push({ url, publish, close: resolve });
        init.signal!.addEventListener("abort", () => resolve(), { once: true });
      }),
  });
  try {
    runtime.retain({ ...input, consumerId: "a" });
    runtime.retain({ ...input, consumerId: "b" });
    expect(connections).toHaveLength(1);
    const initial = runtime.load({ ...input, mode: "latest" });
    connections[0]!.publish(frame("recent", [1, 2, 3, 4]));
    resolvePage(
      new Response(
        JSON.stringify({
          conversation_id: "c",
          participant_id: "p",
          records: [record(2), record(3)],
          has_more: true,
          next_before: "2",
        })
      )
    );
    await initial;
    // Recent 1 is not an automatic older page; concurrent new 4 is not lost.
    expect(runtime.state(input).snapshot.records.map((r) => r.id)).toEqual([
      "2",
      "3",
      "4",
    ]);
    connections[0]!.publish(frame("checkpoint", [], "4"));
    const older = runtime.load({ ...input, mode: "older" });
    connections[0]!.publish(frame("update", [5]));
    resolvePage(
      new Response(
        JSON.stringify({
          conversation_id: "c",
          participant_id: "p",
          records: [record(1)],
          has_more: false,
          next_before: null,
        })
      )
    );
    await older;
    connections[0]!.close();
    await vi.advanceTimersByTimeAsync(1000);
    expect(connections).toHaveLength(2);
    expect(connections[1]!.url.searchParams.get("after")).toBe("4");
    connections[0]!.publish(frame("update", [9]));
    connections[1]!.publish(frame("update", [5, 6]));
    expect(runtime.state(input).snapshot.records.map((r) => r.id)).toEqual([
      "1",
      "2",
      "3",
      "4",
      "5",
      "6",
    ]);
    expect(runtime.state(input).snapshot.nextBefore).toBeNull();
    runtime.release({ ...input, consumerId: "a" });
    connections[1]!.publish(frame("update", [7]));
    expect(runtime.state(input).snapshot.records.at(-1)?.id).toBe("7");
    runtime.release({ ...input, consumerId: "b" });
    connections[1]!.publish(frame("update", [8]));
    expect(runtime.state(input).snapshot.records).toEqual([]);
  } finally {
    runtime.close();
    vi.useRealTimers();
  }
});
