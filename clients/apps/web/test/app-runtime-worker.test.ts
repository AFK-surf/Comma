import { expect, it, vi } from "vitest";
import { attachWebAppRuntime } from "../src/app-runtime-worker";
import { createWebAppRuntimeBridge } from "../src/app-runtime-bridge";

const session = {
  audience: "https://api.comma.test",
  sessionId: "current",
  authorityInstanceId: "tab-a",
  generation: 2,
};
const target = { groupId: "g", conversationId: "c", participantId: "p" };
const page = {
  conversation_id: "c",
  participant_id: "p",
  records: [{ id: "1", kind: "tool", content: "current record" }],
  has_more: false,
  next_before: null,
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status });
const idleStream = (signal: AbortSignal | null | undefined) =>
  new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        signal?.addEventListener("abort", () => controller.close(), { once: true });
      },
    }),
    { headers: { "content-type": "text/event-stream" } }
  );

function host(fetch: typeof globalThis.fetch) {
  let connect!: (event: MessageEvent) => void;
  const close = attachWebAppRuntime(
    {
      addEventListener(_type, listener) {
        connect = listener;
      },
    },
    { apiBaseUrl: session.audience, fetch }
  );
  const clients: ReturnType<typeof createWebAppRuntimeBridge>[] = [];
  return {
    connect(onSessionRejection = vi.fn()) {
      const channel = new MessageChannel();
      connect({ ports: [channel.port1] } as unknown as MessageEvent);
      const client = createWebAppRuntimeBridge(
        { port: channel.port2 },
        { onSessionRejection }
      );
      clients.push(client);
      return {
        ...client,
        processedMessage(type: string) {
          return new Promise<void>((resolve) => {
            const listener = (event: MessageEvent) => {
              if (event.data.type === type) {
                channel.port1.removeEventListener("message", listener);
                resolve();
              }
            };
            channel.port1.addEventListener("message", listener);
          });
        },
      };
    },
    close() {
      for (const client of clients) client.disconnect();
      close();
    },
  };
}

it("a new state subscriber receives the owner's current history without another fetch", async () => {
  const fetch = vi.fn(async (url: RequestInfo | URL) =>
    String(url).endsWith("/auth/session") ? json({ session_id: "current" }) : json(page)
  );
  const runtime = host(fetch);
  const client = runtime.connect();
  try {
    await client.bridge.sessionHistory.load({ ...target, session, mode: "preview" });
    const observed = vi.fn();
    const unsubscribe = client.bridge.sessionHistory.state.subscribe(observed, {
      ...target,
      session,
    });
    await vi.waitFor(() =>
      expect(observed).toHaveBeenCalledWith(
        expect.objectContaining({
          snapshot: expect.objectContaining({ records: page.records }),
        })
      )
    );
    expect(fetch).toHaveBeenCalledTimes(2);
    unsubscribe();
  } finally {
    runtime.close();
  }
});

it("unsubscribing during admission does not start background Inbox demand", async () => {
  let complete!: (response: Response) => void;
  const fetch = vi.fn(
    () =>
      new Promise<Response>((resolve) => {
        complete = resolve;
      })
  );
  const runtime = host(fetch);
  const client = runtime.connect();
  try {
    const unsubscribe = client.bridge.productInbox.state.subscribe(vi.fn(), {
      session,
    });
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledOnce());
    const processed = client.processedMessage("unsubscribe");
    unsubscribe();
    await processed;
    complete(json({ session_id: "current" }));
    await client.bridge.sessionHistory.state({ ...target, session });
    expect(fetch).toHaveBeenCalledOnce();
  } finally {
    runtime.close();
  }
});

it("a stale tab cannot replace a verified owner or move its UI generation backwards", async () => {
  const fetch = vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
    if (String(url).endsWith("/auth/session"))
      return json(
        { session_id: "current" },
        new Headers(init?.headers).get("x-comma-expected-auth-session-id") === "current"
          ? 200
          : 409
      );
    return json(page);
  });
  const runtime = host(fetch);
  const first = runtime.connect();
  const rejected = vi.fn();
  const stale = runtime.connect(rejected);
  try {
    await first.bridge.sessionHistory.load({ ...target, session, mode: "preview" });
    await expect(
      stale.bridge.sessionHistory.load({
        ...target,
        session: { ...session, sessionId: "obsolete" },
        mode: "preview",
      })
    ).rejects.toThrow("Session admission failed");
    await vi.waitFor(() =>
      expect(rejected).toHaveBeenCalledWith({
        session: { ...session, sessionId: "obsolete" },
        status: 409,
      })
    );
    await expect(
      first.bridge.sessionHistory.state({
        ...target,
        session: { ...session, generation: 1 },
      })
    ).rejects.toThrow("Stale view generation");
    expect(
      (await first.bridge.sessionHistory.state({ ...target, session })).snapshot.records
    ).toHaveLength(1);
    expect(fetch).toHaveBeenCalledTimes(3);
  } finally {
    runtime.close();
  }
});

it("releasing the same consumer name in one tab keeps the peer's pending history request", async () => {
  let complete!: (response: Response) => void;
  let signal: AbortSignal | null | undefined;
  const fetch = vi.fn((url: RequestInfo | URL, init?: RequestInit) => {
    if (String(url).endsWith("/auth/session"))
      return Promise.resolve(json({ session_id: "current" }));
    if (new URL(String(url)).pathname.endsWith("/events"))
      return Promise.resolve(idleStream(init?.signal));
    signal = init?.signal;
    return new Promise<Response>((resolve) => {
      complete = resolve;
    });
  });
  const runtime = host(fetch);
  const first = runtime.connect();
  const second = runtime.connect();
  try {
    const input = { ...target, session, consumerId: "same-name" };
    await first.bridge.sessionHistory.retain(input);
    await second.bridge.sessionHistory.retain(input);
    const pending = second.bridge.sessionHistory.load({
      ...target,
      session,
      mode: "preview",
    });
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(3));
    await first.bridge.sessionHistory.release(input);
    first.disconnect();
    expect(signal?.aborted).toBe(false);
    complete(json(page));
    expect((await pending).snapshot.records).toHaveLength(1);
  } finally {
    runtime.close();
  }
});

it("backend rejection invalidates the host and notifies every admitted tab", async () => {
  const fetch = vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
    if (String(url).endsWith("/auth/session")) return json({ session_id: "current" });
    if (new URL(String(url)).pathname.endsWith("/events"))
      return idleStream(init?.signal);
    return json({ error: "session_changed" }, 409);
  });
  const runtime = host(fetch);
  const rejectedA = vi.fn();
  const rejectedB = vi.fn();
  const first = runtime.connect(rejectedA);
  const second = runtime.connect(rejectedB);
  try {
    await first.bridge.sessionHistory.retain({ ...target, session, consumerId: "a" });
    await second.bridge.sessionHistory.retain({ ...target, session, consumerId: "b" });
    await expect(
      first.bridge.sessionHistory.load({ ...target, session, mode: "preview" })
    ).rejects.toThrow();
    await vi.waitFor(() => {
      expect(rejectedA).toHaveBeenCalledWith({ session, status: 409 });
      expect(rejectedB).toHaveBeenCalledWith({ session, status: 409 });
    });
  } finally {
    runtime.close();
  }
});

it("logout while first admission is pending cannot install its delayed successful response", async () => {
  let complete!: (response: Response) => void;
  const fetch = vi.fn(
    () =>
      new Promise<Response>((resolve) => {
        complete = resolve;
      })
  );
  const runtime = host(fetch);
  const client = runtime.connect();
  try {
    const pending = client.bridge.sessionHistory.state({ ...target, session });
    const rejection = expect(pending).rejects.toThrow(
      "Session changed during admission"
    );
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledOnce());
    const invalidated = client.processedMessage("invalidate");
    client.invalidate(session);
    await invalidated;
    complete(json({ session_id: "current" }));
    await rejection;
    const next = client.bridge.sessionHistory.state({ ...target, session });
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
    complete(json({ session_id: "current" }));
    expect((await next).snapshot.records).toHaveLength(0);
  } finally {
    runtime.close();
  }
});
