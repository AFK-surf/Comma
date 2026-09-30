import { ProductInboxRuntime } from "@comma/product-inbox-runtime";
import type { SessionProductLease } from "@comma/session-contract";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  WebCookieProductCredentialAuthority,
  WebMemoryProductInboxStorage,
} from "../src/product-inbox-host";

const session: SessionProductLease = {
  audience: "https://api.comma.test",
  authorityInstanceId: "web-cookie-session",
  generation: 1,
  sessionId: "11111111-1111-4111-8111-111111111111",
};

describe("Web ProductInbox host", () => {
  afterEach(() => vi.restoreAllMocks());

  it("runs the shared runtime with cookie transport and refreshes from Group SSE", async () => {
    const authority = new WebCookieProductCredentialAuthority();
    authority.activate(session);
    const credential = authority.acquireProductCredential({
      authorityInstanceId: session.authorityInstanceId,
      expectedAudience: session.audience,
      expectedSessionId: session.sessionId,
      generation: session.generation,
    });
    expect(credential).not.toBeNull();
    expect(authority.isCurrentProductCredential(credential!)).toBe(true);
    let title = "Initial task title";
    let conversationReads = 0;
    let eventController: ReadableStreamDefaultController<Uint8Array> | undefined;
    const fetchMock = vi.fn(async function (
      this: unknown,
      input: RequestInfo | URL,
      _init?: RequestInit
    ): Promise<Response> {
      expect(this).toBeUndefined();
      const url = new URL(String(input));
      if (url.pathname === "/v1/comma/workspaces") {
        return jsonResponse({
          data: [{ group_id: "grp-web", id: "ws-web", name: "Web Workspace" }],
          has_more: false,
          next_cursor: null,
        });
      }
      if (url.pathname === "/v1/comma/groups/grp-web/conversations") {
        conversationReads += 1;
        return jsonResponse({
          data: [
            {
              group_id: "grp-web",
              id: "task-web",
              kind: "agent_task",
              status: "active",
              title,
              updated_at: conversationReads,
            },
          ],
          has_more: false,
          next_cursor: null,
        });
      }
      if (url.pathname === "/v1/comma/groups/grp-web/conversations/events") {
        return new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              eventController = controller;
            },
          }),
          { headers: { "content-type": "text/event-stream" } }
        );
      }
      return jsonResponse({ error: "not found" }, { status: 404 });
    });
    const runtime = new ProductInboxRuntime({
      authority,
      fetch: fetchMock,
      localData: new WebMemoryProductInboxStorage(),
      reportUnauthorized: async () => authority.invalidate(),
      schedule: () => () => undefined,
    });
    const snapshots: string[][] = [];
    const unsubscribe = runtime.subscribe(session, (envelope) => {
      snapshots.push(envelope.snapshot.items.map((item) => item.title));
    });

    try {
      const initial = await runtime.refresh(session);
      expect(initial.snapshot).toMatchObject({ source: "live-sync" });
      expect(initial.snapshot.items.map((item) => item.title)).toEqual([
        "Initial task title",
      ]);
      expect(eventController).toBeDefined();
      for (const [, init] of fetchMock.mock.calls) {
        expect(init?.credentials).toBe("include");
        const headers = new Headers(init?.headers);
        expect(headers.has("authorization")).toBe(false);
        expect(headers.get("x-comma-expected-auth-session-id")).toBe(session.sessionId);
        expect(headers.get("x-comma-session-lifecycle-version")).toBe("1");
        expect(headers.get("x-comma-session-transport")).toBe("cookie");
      }

      title = "Renamed task title";
      eventController?.enqueue(
        new TextEncoder().encode(
          'event: conversation_list_invalidated\ndata: {"type":"conversation_list_invalidated","group_id":"grp-web","kind":"agent_task","version":"owner.2"}\n\n'
        )
      );

      await vi.waitFor(() => {
        expect(snapshots.some((items) => items.includes("Renamed task title"))).toBe(
          true
        );
      });
      expect(conversationReads).toBe(2);
    } finally {
      unsubscribe();
      runtime.close();
    }
  });

  it("reports an exact cookie-session change back to the Web lifecycle", async () => {
    const authority = new WebCookieProductCredentialAuthority();
    authority.activate(session);
    const rejection = vi.fn();
    const stopRejections = authority.onSessionRejection(rejection);
    const runtime = new ProductInboxRuntime({
      authority,
      fetch: vi.fn(async () =>
        jsonResponse({ error: "session_changed" }, { status: 409 })
      ),
      localData: new WebMemoryProductInboxStorage(),
      reportSessionChanged: async (credential) =>
        authority.reportSessionRejection(credential, 409),
      reportUnauthorized: async (credential) =>
        authority.reportSessionRejection(credential, 401),
      schedule: () => () => undefined,
    });

    try {
      await expect(runtime.refresh(session)).rejects.toMatchObject({
        code: "stale_session_lease",
      });
      expect(rejection).toHaveBeenCalledOnce();
      expect(rejection).toHaveBeenCalledWith({ session, status: 409 });
      expect(
        authority.acquireProductCredential({
          authorityInstanceId: session.authorityInstanceId,
          expectedAudience: session.audience,
          expectedSessionId: session.sessionId,
          generation: session.generation,
        })
      ).toBeNull();
    } finally {
      stopRejections();
      runtime.close();
    }
  });
});

function jsonResponse(body: unknown, init: ResponseInit = {}) {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    ...init,
  });
}
