import type { SessionProductLease } from "@comma/session-contract";
import { afterEach, describe, expect, it, vi } from "vitest";
import { attachWebAppRuntime } from "../src/app-runtime-worker";
import { createWebAppRuntimeBridge } from "../src/app-runtime-bridge";

const session: SessionProductLease = {
  audience: "https://api.comma.test",
  authorityInstanceId: "web-cookie-session",
  generation: 1,
  sessionId: "11111111-1111-4111-8111-111111111111",
};

describe("Web ProductInbox SharedWorker bridge", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("carries the shared projection contract over MessagePort", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = new URL(String(input));
        if (url.pathname === "/v1/comma/auth/session")
          return jsonResponse({ session_id: session.sessionId });
        if (url.pathname === "/v1/comma/workspaces") {
          return jsonResponse({
            data: [{ group_id: "grp-web", id: "ws-web", name: "Web Workspace" }],
          });
        }
        if (url.pathname === "/v1/comma/groups/grp-web/conversations") {
          return jsonResponse({
            data: [
              {
                group_id: "grp-web",
                id: "task-web",
                kind: "agent_task",
                status: "active",
                title: "SharedWorker task",
                updated_at: 1_000,
              },
            ],
          });
        }
        if (url.pathname === "/v1/comma/groups/grp-web/conversations/events") {
          return new Response(
            new ReadableStream<Uint8Array>({
              start(controller) {
                init?.signal?.addEventListener("abort", () => controller.close(), {
                  once: true,
                });
              },
            }),
            { headers: { "content-type": "text/event-stream" } }
          );
        }
        return jsonResponse({ error: "not found" }, { status: 404 });
      })
    );
    let connect: ((event: MessageEvent) => void) | undefined;
    const scope: Parameters<typeof attachWebAppRuntime>[0] = {
      addEventListener(_type, listener) {
        connect = listener;
      },
    };
    const closeHost = attachWebAppRuntime(scope, { apiBaseUrl: session.audience });
    const channel = new MessageChannel();
    connect?.({ ports: [channel.port1] } as unknown as MessageEvent);
    const bridge = createWebAppRuntimeBridge({ port: channel.port2 }).bridge
      .productInbox;
    const observed: string[][] = [];
    const unsubscribe = bridge.state.subscribe(
      (envelope) => {
        observed.push(envelope.snapshot.items.map((item) => item.title));
      },
      { session }
    );

    try {
      const envelope = await bridge.retain({ session });
      expect(envelope.snapshot.items.map((item) => item.title)).toEqual([
        "SharedWorker task",
      ]);
      await vi.waitFor(() => {
        expect(observed.some((titles) => titles.includes("SharedWorker task"))).toBe(
          true
        );
      });
    } finally {
      unsubscribe();
      await bridge.release({ session });
      closeHost();
      channel.port1.close();
      channel.port2.close();
    }
  });

  it("forwards a worker session rejection to the renderer lifecycle adapter", async () => {
    const channel = new MessageChannel();
    const onSessionRejection = vi.fn();
    createWebAppRuntimeBridge({ port: channel.port2 }, { onSessionRejection });

    try {
      channel.port1.postMessage({ session, status: 409, type: "session-rejected" });
      await vi.waitFor(() => {
        expect(onSessionRejection).toHaveBeenCalledWith({ session, status: 409 });
      });
    } finally {
      channel.port1.close();
      channel.port2.close();
    }
  });
});

function jsonResponse(body: unknown, init: ResponseInit = {}) {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    ...init,
  });
}
