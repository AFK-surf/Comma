import { afterEach, expect, it, vi } from "vitest";
import { attachWebAppRuntime } from "../src/app-runtime-worker";
import { createWebAppRuntimeBridge } from "../src/app-runtime-bridge";

afterEach(() => vi.unstubAllGlobals());
it("two tabs with different UI authorities share one worker-owned page request", async () => {
  let resolve!: (response: Response) => void;
  const fetch = vi.fn((input: RequestInfo | URL) =>
    String(input).endsWith("/v1/comma/auth/session")
      ? Promise.resolve(new Response(JSON.stringify({ session_id: "cookie-session" })))
      : new Promise<Response>((done) => {
          resolve = done;
        })
  );
  vi.stubGlobal("fetch", fetch);
  let connect!: (event: MessageEvent) => void;
  const closeHost = attachWebAppRuntime(
    {
      addEventListener(_type, listener) {
        connect = listener;
      },
    },
    { apiBaseUrl: "https://api.comma.test", fetch }
  );
  const channels = [new MessageChannel(), new MessageChannel()];
  const bridges = channels.map((channel) => {
    connect({ ports: [channel.port1] } as unknown as MessageEvent);
    return createWebAppRuntimeBridge({ port: channel.port2 }).bridge.sessionHistory;
  });
  const target = { groupId: "g", conversationId: "c", participantId: "p" };
  const session = {
    audience: "https://api.comma.test",
    sessionId: "cookie-session",
    authorityInstanceId: "tab-a",
    generation: 1,
  };
  try {
    const a = bridges[0]!.load({ ...target, session, mode: "preview" });
    const b = bridges[1]!.load({
      ...target,
      session: { ...session, authorityInstanceId: "tab-b", generation: 5 },
      mode: "preview",
    });
    await vi.waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
    resolve(
      new Response(
        JSON.stringify({
          conversation_id: "c",
          participant_id: "p",
          records: [{ id: "1", kind: "tool", content: "done" }],
          has_more: false,
          next_before: null,
        })
      )
    );
    const [first, second] = await Promise.all([a, b]);
    expect(first.snapshot).toEqual(second.snapshot);
    expect(first.session.authorityInstanceId).toBe("tab-a");
    expect(second.session.authorityInstanceId).toBe("tab-b");
    expect(fetch).toHaveBeenCalledTimes(2);
  } finally {
    closeHost();
    for (const channel of channels) {
      channel.port1.close();
      channel.port2.close();
    }
  }
});
