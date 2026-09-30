import { describe, expect, it, vi } from "vitest";
import { SessionHistoryRuntime } from "../index";
import type {
  SessionHistoryInput,
  SessionHistoryStreamFrame,
} from "@comma/native-bridge";

const input: SessionHistoryInput = {
  groupId: "g",
  conversationId: "c",
  participantId: "p",
  session: {
    audience: "https://api.comma.test",
    authorityInstanceId: "host",
    sessionId: "session-a",
    generation: 1,
  },
};
function page(ids: number[], more = false) {
  return new Response(
    JSON.stringify({
      conversation_id: "c",
      participant_id: "p",
      records: ids.map((id) => ({
        id: String(id),
        kind: "assistant",
        content: { content: `Record ${id}` },
      })),
      has_more: more,
      next_before: more ? String(ids[0]) : null,
    }),
    { status: 200 }
  );
}
function setup(fetch: typeof globalThis.fetch) {
  let session = input.session;
  let controller = new AbortController();
  const authority = {
    acquireProductCredential(expected: { expectedSessionId: string }) {
      return expected.expectedSessionId === session.sessionId
        ? {
            audience: session.audience,
            token: "host-only-secret",
            signal: controller.signal,
          }
        : null;
    },
    isCurrentProductCredential(credential: { signal: AbortSignal }) {
      return credential.signal === controller.signal && !credential.signal.aborted;
    },
  };
  let onFrame: ((frame: SessionHistoryStreamFrame) => void) | undefined;
  return {
    runtime: new SessionHistoryRuntime({
      authority,
      fetch,
      stream: async (_fetch, _url, init, receive) => {
        onFrame = receive;
        await new Promise<void>((resolve) =>
          init.signal!.addEventListener("abort", () => resolve(), { once: true })
        );
      },
    }),
    frame(frame: Partial<SessionHistoryStreamFrame>) {
      onFrame!({
        conversation_id: "c",
        participant_id: "p",
        records: [],
        live_records: [],
        server_time_ms: Date.now(),
        phase: "checkpoint",
        checkpoint: null,
        ...frame,
      });
    },
    changeSession() {
      controller.abort();
      controller = new AbortController();
      session = { ...session, sessionId: "session-b" };
      return { ...input, session };
    },
  };
}

describe("shared Session history owner", () => {
  it("coalesces detail demands that arrive while the preview is still loading", async () => {
    let release!: (response: Response) => void;
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            release = resolve;
          })
      )
      .mockResolvedValueOnce(page([1, 2, 3, 4, 5]));
    const { runtime } = setup(fetch);
    const preview = runtime.load({ ...input, mode: "preview" });
    const first = runtime.load({ ...input, mode: "latest" });
    const second = runtime.load({ ...input, mode: "latest" });
    release(page([3, 4, 5], true));
    await Promise.all([preview, first, second]);
    expect(fetch).toHaveBeenCalledTimes(2);
    expect(runtime.state(input).snapshot.records).toHaveLength(5);
    runtime.close();
  });

  it("does not apply a retired target's reply after a new view opens the same Participant", async () => {
    let release!: (response: Response) => void;
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            release = resolve;
          })
      )
      .mockResolvedValueOnce(page([8]));
    const { runtime } = setup(fetch);
    const demand = { ...input, consumerId: "view" };
    runtime.retain(demand);
    const old = runtime.load({ ...input, mode: "latest" });
    runtime.release(demand);
    runtime.retain(demand);
    await runtime.load({ ...input, mode: "latest" });
    release(page([1]));
    await old;
    expect(runtime.state(input).snapshot.records.map((record) => record.id)).toEqual([
      "8",
    ]);
    runtime.close();
  });

  it("deduplicates two windows and loads bounded reverse pages in chronological order", async () => {
    let release!: (value: Response) => void;
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            release = resolve;
          })
      )
      .mockResolvedValueOnce(page([3, 4, 5], true))
      .mockResolvedValueOnce(page([1, 2]));
    const { runtime } = setup(fetch);
    const observed: string[][] = [];
    runtime.subscribe((value) =>
      observed.push(value.snapshot.records.map((record) => record.id))
    );
    const first = runtime.load({ ...input, mode: "preview" });
    const second = runtime.load({ ...input, mode: "preview" });
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(new URL(String(fetch.mock.calls[0]![0])).searchParams.get("limit")).toBe(
      "3"
    );
    release(page([3, 4, 5], true));
    await Promise.all([first, second]);
    await runtime.load({ ...input, mode: "latest" });
    expect(new URL(String(fetch.mock.calls[1]![0])).searchParams.get("limit")).toBe(
      "50"
    );
    await Promise.all([
      runtime.load({ ...input, mode: "older" }),
      runtime.load({ ...input, mode: "older" }),
    ]);
    expect(fetch).toHaveBeenCalledTimes(3);
    expect(new URL(String(fetch.mock.calls[2]![0])).searchParams.get("before")).toBe(
      "3"
    );
    expect(runtime.state(input).snapshot.records.map((record) => record.id)).toEqual([
      "1",
      "2",
      "3",
      "4",
      "5",
    ]);
    expect(observed.at(-1)).toEqual(["1", "2", "3", "4", "5"]);
    runtime.close();
  });

  it("rejects a late response from a previous account and never publishes it", async () => {
    let release!: (response: Response) => void;
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            release = resolve;
          })
      )
      .mockResolvedValueOnce(page([9]));
    const { runtime, changeSession } = setup(fetch);
    const listener = vi.fn();
    runtime.subscribe(listener);
    const old = runtime.load({ ...input, mode: "latest" });
    const next = changeSession();
    await runtime.load({ ...next, mode: "latest" });
    listener.mockClear();
    release(page([1]));
    await old;
    expect(listener).not.toHaveBeenCalled();
    expect(runtime.state(next).snapshot.records.map((record) => record.id)).toEqual([
      "9",
    ]);
    expect(() => runtime.state(input)).toThrow();
    runtime.close();
  });

  it("retains the current page on failure and retries the same cursor", async () => {
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(page([3, 4], true))
      .mockRejectedValueOnce(new Error("offline"))
      .mockResolvedValueOnce(page([1, 2]));
    const { runtime } = setup(fetch);
    await runtime.load({ ...input, mode: "latest" });
    const failed = await runtime.load({ ...input, mode: "older" });
    expect(failed.snapshot.status).toBe("error");
    expect(failed.snapshot.records.map((record) => record.id)).toEqual(["3", "4"]);
    const retried = await runtime.load({ ...input, mode: "older" });
    expect(retried.snapshot.records.map((record) => record.id)).toEqual([
      "1",
      "2",
      "3",
      "4",
    ]);
    expect(new URL(String(fetch.mock.calls[1]![0])).search).toEqual(
      new URL(String(fetch.mock.calls[2]![0])).search
    );
    runtime.close();
  });

  it("publishes a stream frame only when it changes the snapshot", async () => {
    const { runtime, frame } = setup(
      vi.fn<typeof globalThis.fetch>().mockResolvedValueOnce(page([1, 2]))
    );
    const published = vi.fn();
    runtime.subscribe(published);
    runtime.retain({ ...input, consumerId: "view" });
    await runtime.load({ ...input, mode: "latest" });
    frame({ phase: "update", checkpoint: "2" });
    const settled = runtime.state(input).snapshot;
    expect(settled.streamStatus).toBe("live");
    published.mockClear();
    // Heartbeats repeat the checkpoint and live overlay every few seconds, and
    // each publish sends the whole snapshot to every window.
    frame({ checkpoint: "2" });
    frame({ checkpoint: "2" });
    expect(published).not.toHaveBeenCalled();
    expect(runtime.state(input).snapshot.revision).toBe(settled.revision);
    const live = {
      id: "live",
      kind: "tool",
      content: { status: "running" },
      execution: {
        id: "call",
        lane: "tool" as const,
        started_at_ms: 1,
        observed_at_ms: 2,
        completed_at_ms: null,
        duration_ms: 1,
        live: true,
      },
    };
    frame({ checkpoint: "2", live_records: [live] });
    frame({ checkpoint: "2", live_records: [structuredClone(live)] });
    expect(published).toHaveBeenCalledTimes(1);
    frame({
      phase: "update",
      checkpoint: "3",
      records: [
        { id: "2", kind: "assistant", content: { content: "Record 2, revised" } },
        { id: "3", kind: "assistant", content: { content: "Record 3" } },
      ],
    });
    expect(published).toHaveBeenCalledTimes(2);
    expect(
      runtime.state(input).snapshot.records.map((record) => record.content)
    ).toEqual([
      { content: "Record 1" },
      { content: "Record 2, revised" },
      { content: "Record 3" },
    ]);
    runtime.close();
  });
});
