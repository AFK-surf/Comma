import { sessionProductLease, type SessionProductLease } from "@comma/session-contract";
import { describe, expect, it, vi } from "vitest";
import type {
  LocalDataProductWorkspaceInput,
  LocalDataRepository,
  LocalDataRepositoryHealth,
  LocalDataWriteAck,
  LocalProductInboxItem,
  ProductInboxCacheApplyInput,
} from "../../shared/local-data";
import {
  ProductInboxNativeDemandProvider,
  ProductInboxRuntime,
  ProductInboxRuntimeFailure,
} from "../modules/product-inbox";
import {
  MainProductCredentialAuthority,
  type MainProductCredentialLease,
} from "../modules/session";

const AUDIENCE = "https://api.comma.test";
const credentialA = {
  audience: AUDIENCE,
  email: "a@comma.test",
  expiresAtEpochSeconds: 1_900_000_000,
  sessionId: "session-a",
  token: "bearer-a-secret",
  userId: "verified-user-a",
} as const;
const credentialB = {
  ...credentialA,
  email: "b@comma.test",
  sessionId: "session-b",
  token: "bearer-b-secret",
  userId: "verified-user-b",
} as const;

describe("ProductInboxRuntime session settlement", () => {
  it("preserves task labels, platform and archive facts through offline restoration", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const localData = new FakeLocalDataRepository();
    const fetchImpl = vi.fn(async (input: Parameters<typeof fetch>[0]) => {
      const url = new URL(String(input));
      if (url.pathname === "/v1/comma/workspaces") return jsonResponse(workspacePage());
      if (url.pathname.endsWith("/task-summaries")) {
        expect(url.searchParams.get("ids")).toBe("old-task");
        return jsonResponse({
          data: [
            {
              ...conversationPage().data[0],
              id: "old-task",
              origin: "slack",
              labels: ["lbl_work"],
              client_platform: "macos",
              meeting: { phase: "dismissed", owner_user_id: "must-not-project" },
              status: "archived",
              archive_availability: { allowed: false, reason: "already_archived" },
            },
          ],
        });
      }
      expect(url.searchParams.get("archive")).toBe("include");
      return jsonResponse({
        ...conversationPage(),
        has_more: true,
        next_cursor: "next-page",
      });
    });
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData,
    });
    const result = await runtime.refresh({
      session: lease,
      conversationIds: ["old-task"],
    });
    expect(
      result.snapshot.items.find((item) => item.conversationId === "old-task")
    ).toMatchObject({
      status: "archived",
      archiveAvailability: { allowed: false },
      archiveVersion: 1_700_000_100,
      origin: "slack",
      meetingPhase: "dismissed",
      labels: ["lbl_work"],
      clientPlatform: "macos",
    });
    expect(
      result.snapshot.items.find((item) => item.conversationId === "cnv_1")
    ).not.toHaveProperty("origin");
    expect(result.snapshot.nextCursor).toBe("next-page");
    expect(result.snapshot.hasMore).toBe(true);
    const persisted = localData.applied.at(-1)!;
    localData.cachedWorkspaces.push(...persisted.workspaces.items);
    for (const item of result.snapshot.items) {
      localData.cachedItems.push({
        ...item,
        audience: AUDIENCE,
        raw: persisted.conversations!.items.find(
          (record) => record.id === item.conversationId
        )!.raw,
      });
    }
    const offline = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      localData,
      fetch: vi.fn().mockRejectedValue(new Error("offline")),
    });
    const restored = await offline.refresh(lease);
    expect(restored.snapshot.source).toBe("cache");
    expect(
      restored.snapshot.items.find((item) => item.conversationId === "old-task")
    ).toMatchObject({
      status: "archived",
      archiveAvailability: { allowed: false, reason: "already_archived" },
      archiveVersion: 1_700_000_100,
      origin: "slack",
      meetingPhase: "dismissed",
      labels: ["lbl_work"],
      clientPlatform: "macos",
    });
    expect(
      restored.snapshot.items.find((item) => item.conversationId === "cnv_1")
    ).not.toHaveProperty("origin");
    offline.close();
    runtime.close();
  });
  it("drops a delayed A response after login B before cache, state, or publish", async () => {
    const { authority, lease: leaseA } = signedInAuthority(credentialA);
    const pendingWorkspaces = deferred<Response>();
    const fetchImpl = vi.fn(() => pendingWorkspaces.promise);
    const localData = new FakeLocalDataRepository();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData,
    });
    const delivered = vi.fn();
    runtime.subscribe(leaseA, delivered);
    runtime.get(leaseA);

    const refreshA = runtime.refresh(leaseA);
    expect(fetchImpl).toHaveBeenCalledOnce();

    const snapshotB = authority.acceptVerifiedCredential(credentialB);
    const leaseB = requiredLease(snapshotB);
    pendingWorkspaces.resolve(jsonResponse(workspacePage()));

    await expect(refreshA).rejects.toMatchObject({
      code: "stale_session_lease",
    });
    expect(localData.applied).toEqual([]);
    expect(delivered).toHaveBeenCalledTimes(1);
    expect(() => runtime.get(leaseA)).toThrow(ProductInboxRuntimeFailure);
    expect(runtime.get(leaseB)).toMatchObject({
      session: leaseB,
      snapshot: { source: "unavailable" },
    });
  });

  it("bounds a hanging 200 body, clears the same-key refresh, and allows retry", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const deadlines = new ManualScheduler();
    const localData = new FakeLocalDataRepository();
    const caller = new AbortController();
    const requestSignals: AbortSignal[] = [];
    let requestCount = 0;
    let hangingBody: ReadableStreamDefaultController<Uint8Array> | undefined;
    const fetchImpl = vi.fn(
      async (
        input: Parameters<typeof fetch>[0],
        init?: Parameters<typeof fetch>[1]
      ) => {
        requestCount += 1;
        if (init?.signal) requestSignals.push(init.signal);
        if (requestCount === 1) {
          return new Response(
            new ReadableStream<Uint8Array>({
              start(controller) {
                hangingBody = controller;
              },
            }),
            {
              headers: { "content-type": "application/json" },
              status: 200,
            }
          );
        }
        const url = new URL(String(input));
        return jsonResponse(
          url.pathname === "/v1/comma/workspaces" ? workspacePage() : conversationPage()
        );
      }
    );
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData,
      requestTimeoutMs: 25,
      scheduleDeadline: (expire, delayMs) => deadlines.schedule(expire, delayMs),
    });

    const firstRefresh = runtime.refresh(lease, caller.signal);
    await vi.waitFor(() => {
      expect(fetchImpl).toHaveBeenCalledOnce();
      expect(hangingBody).toBeDefined();
    });
    expect(deadlines.pendingDelays).toEqual([25]);
    expect(requestSignals[0]?.aborted).toBe(false);

    deadlines.runNext();
    await expect(firstRefresh).resolves.toMatchObject({
      snapshot: {
        errorCode: "network_unavailable",
        items: [],
        source: "error",
      },
    });
    expect(requestSignals[0]?.aborted).toBe(true);
    expect(caller.signal.aborted).toBe(false);
    expect(localData.applied).toEqual([]);
    expect(deadlines.pendingCount).toBe(0);
    hangingBody?.error(new Error("release hanging ProductInbox test body"));

    const retry = runtime.refresh(lease);
    expect(retry).not.toBe(firstRefresh);
    await expect(retry).resolves.toMatchObject({
      snapshot: {
        activeWorkspaceId: "wsp_1",
        source: "live-sync",
      },
    });
    expect(fetchImpl).toHaveBeenCalledTimes(3);
    expect(localData.applied).toHaveLength(1);
    expect(deadlines.pendingCount).toBe(0);
  });

  it("keeps a newer Workspace projection when an older refresh settles late", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const delayedWorkspaceA = deferred<Response>();
    let workspaceRequestCount = 0;
    const fetchImpl = vi.fn(async (input: Parameters<typeof fetch>[0]) => {
      const url = new URL(String(input));
      if (url.pathname === "/v1/comma/workspaces") {
        workspaceRequestCount += 1;
        if (workspaceRequestCount === 1) return delayedWorkspaceA.promise;
        return jsonResponse({
          data: [
            { group_id: "grp_1", id: "wsp_1", name: "First" },
            { group_id: "grp_2", id: "wsp_2", name: "Selected" },
          ],
        });
      }
      if (url.pathname === "/v1/comma/groups/grp_2/conversations") {
        return jsonResponse({
          data: [
            {
              id: "cnv_2",
              kind: "user_chat",
              status: "idle",
              title: "Selected workspace",
              group_id: "grp_2",
            },
          ],
        });
      }
      throw new Error(`Unexpected ProductInbox request: ${url.pathname}`);
    });
    const localData = new FakeLocalDataRepository();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData,
    });
    const delivered = vi.fn();
    runtime.subscribe(lease, delivered);

    const refreshA = runtime.refresh({ session: lease, workspaceId: "wsp_1" });
    await vi.waitFor(() => expect(fetchImpl).toHaveBeenCalledTimes(1));
    const refreshB = runtime.refresh({ session: lease, workspaceId: "wsp_2" });
    await expect(refreshB).resolves.toMatchObject({
      snapshot: {
        activeWorkspaceId: "wsp_2",
        items: [{ conversationId: "cnv_2", workspaceId: "wsp_2" }],
      },
    });

    delayedWorkspaceA.resolve(
      jsonResponse({
        data: [
          { group_id: "grp_1", id: "wsp_1", name: "First" },
          { group_id: "grp_2", id: "wsp_2", name: "Selected" },
        ],
      })
    );
    await expect(refreshA).rejects.toMatchObject({
      code: "superseded_refresh",
    });

    expect(
      fetchImpl.mock.calls
        .map(([input]) => new URL(String(input)).pathname)
        .filter((pathname) => pathname === "/v1/comma/groups/grp_1/conversations")
    ).toEqual([]);
    expect(localData.applied).toHaveLength(1);
    expect(localData.applied[0]?.conversations?.workspaceId).toBe("wsp_2");
    expect(runtime.get(lease)).toMatchObject({
      snapshot: { activeWorkspaceId: "wsp_2" },
    });
    expect(delivered).toHaveBeenCalledTimes(2);
  });

  it("closes the current product gate before durable handling of a 401", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const durableInvalidation = deferred<void>();
    const reportUnauthorized = vi.fn(async (credential: MainProductCredentialLease) => {
      authority.beginInvalidation(leaseExpectation(credential));
      await durableInvalidation.promise;
    });
    const fetchImpl = vi.fn(async () => new Response(null, { status: 401 }));
    const localData = new FakeLocalDataRepository();
    const runtime = new ProductInboxRuntime({
      authority,
      fetch: fetchImpl as typeof fetch,
      localData,
      reportUnauthorized,
    });

    const refresh = runtime.refresh(lease);
    await vi.waitFor(() => {
      expect(reportUnauthorized).toHaveBeenCalledOnce();
    });

    expect(authority.getSnapshot()).toMatchObject({
      phase: "invalidating",
    });
    expect(
      authority.acquireProductCredential({
        authorityInstanceId: lease.authorityInstanceId,
        expectedAudience: lease.audience,
        expectedSessionId: lease.sessionId,
        generation: lease.generation,
      })
    ).toBeNull();
    expect(fetchImpl).toHaveBeenCalledOnce();
    expect(localData.applied).toEqual([]);

    durableInvalidation.resolve(undefined);
    await expect(refresh).rejects.toMatchObject({
      code: "stale_session_lease",
    });
    expect(fetchImpl).toHaveBeenCalledOnce();
  });

  it("ignores a delayed 401 from a stale product lease", async () => {
    const { authority, lease: leaseA } = signedInAuthority(credentialA);
    const pendingResponse = deferred<Response>();
    const reportUnauthorized = vi.fn(
      async (_credential: MainProductCredentialLease) => {}
    );
    const fetchImpl = vi.fn(() => pendingResponse.promise);
    const runtime = new ProductInboxRuntime({
      authority,
      fetch: fetchImpl as typeof fetch,
      localData: new FakeLocalDataRepository(),
      reportUnauthorized,
    });

    const refreshA = runtime.refresh(leaseA);
    await vi.waitFor(() => {
      expect(fetchImpl).toHaveBeenCalledOnce();
    });
    authority.acceptVerifiedCredential(credentialB);
    pendingResponse.resolve(new Response(null, { status: 401 }));

    await expect(refreshA).rejects.toMatchObject({
      code: "stale_session_lease",
    });
    expect(reportUnauthorized).not.toHaveBeenCalled();
    expect(authority.getSnapshot()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: credentialB.sessionId },
    });
  });

  it("keeps Electron's bearer session current for a Web-only session_changed 409", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const reportUnauthorized = vi.fn(async () => undefined);
    const runtime = new ProductInboxRuntime({
      authority,
      fetch: vi.fn(
        async () =>
          new Response(JSON.stringify({ error: "session_changed" }), {
            headers: { "content-type": "application/json" },
            status: 409,
          })
      ),
      localData: new FakeLocalDataRepository(),
      reportUnauthorized,
      schedule: () => () => undefined,
    });

    const envelope = await runtime.refresh(lease);

    expect(envelope.snapshot).toMatchObject({ source: "error" });
    expect(reportUnauthorized).not.toHaveBeenCalled();
    expect(authority.getSnapshot()).toMatchObject({
      phase: "signed_in",
      session: { sessionId: credentialA.sessionId },
    });
  });

  it("uses verified userId and the exact (principalId, audience, lease) cache partition", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const fetchImpl = successfulFetch();
    const localData = new FakeLocalDataRepository();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl,
      localData,
      now: () => 1_700_000_000_000,
    });

    const envelope = await runtime.refresh(lease);

    expect(envelope).toMatchObject({
      session: lease,
      snapshot: {
        activeWorkspaceId: "wsp_1",
        items: [{ conversationId: "cnv_1", workspaceId: "wsp_1" }],
        lastSyncedAt: 1_700_000_000_000,
        source: "live-sync",
      },
    });
    expect(localData.applied).toHaveLength(1);
    expect(localData.applied[0]).toMatchObject({
      audience: AUDIENCE,
      principalId: credentialA.userId,
      session: lease,
      conversations: { mode: "replace" },
      workspaces: { mode: "replace" },
    });
    expect(JSON.stringify(localData.applied[0])).not.toContain(credentialA.token);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
    for (const [, init] of fetchImpl.mock.calls) {
      expect(init).toMatchObject({
        credentials: "omit",
        redirect: "manual",
      });
      expect(init?.headers).toMatchObject({
        authorization: `Bearer ${credentialA.token}`,
      });
    }
  });

  it("uses lease-local ETags and skips cache writes and publication for 304 or identical 200", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const requestCounts = new Map<string, number>();
    const fetchImpl = vi.fn(
      async (
        input: Parameters<typeof fetch>[0],
        init?: Parameters<typeof fetch>[1]
      ) => {
        const url = new URL(String(input));
        const key = url.pathname;
        if (key.endsWith("/conversations/events")) {
          return openEventStream(init?.signal);
        }
        const count = (requestCounts.get(key) ?? 0) + 1;
        requestCounts.set(key, count);
        const etag =
          key === "/v1/comma/workspaces" ? '"workspaces-v1"' : '"conversations-v1"';
        const nextEtag = `${etag.slice(0, -1)}-v2"`;

        if (count === 1) {
          expect(new Headers(init?.headers).get("if-none-match")).toBeNull();
          return jsonResponse(
            key === "/v1/comma/workspaces" ? workspacePage() : conversationPage(),
            { etag }
          );
        }
        expect(new Headers(init?.headers).get("if-none-match")).toBe(
          count <= 3 ? etag : nextEtag
        );
        if (count === 2 || count === 4) {
          return new Response(null, { status: 304 });
        }
        return jsonResponse(
          key === "/v1/comma/workspaces" ? workspacePage() : conversationPage(),
          { etag: nextEtag }
        );
      }
    );
    const localData = new FakeLocalDataRepository();
    const scheduler = new ManualScheduler();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData,
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });
    const listener = vi.fn();
    const unsubscribe = runtime.subscribe(lease, listener);

    const first = await runtime.refresh(lease);
    const notModified = await runtime.refresh(lease);
    const identical = await runtime.refresh(lease);

    expect(notModified).toEqual(first);
    expect(identical).toEqual(first);
    expect(localData.applied).toHaveLength(1);
    expect(listener).toHaveBeenCalledTimes(2);
    expect(
      fetchImpl.mock.calls.filter(([input]) =>
        new URL(String(input)).pathname.endsWith("/conversations/events")
      )
    ).toHaveLength(1);
    expect(
      fetchImpl.mock.calls.filter(
        ([input]) => !new URL(String(input)).pathname.endsWith("/conversations/events")
      )
    ).toHaveLength(6);

    localData.recover();
    await runtime.refresh(lease);
    expect(localData.applied).toHaveLength(2);
    expect(listener).toHaveBeenCalledTimes(2);
    expect(
      fetchImpl.mock.calls.filter(
        ([input]) => !new URL(String(input)).pathname.endsWith("/conversations/events")
      )
    ).toHaveLength(8);

    unsubscribe();
    runtime.close();
    expect(scheduler.pendingCount).toBe(0);
  });

  it("preserves platform origin while stripping unrelated public resource fields before caching", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const fetchImpl = vi.fn(async (input: Parameters<typeof fetch>[0]) => {
      const url = new URL(String(input));
      if (url.pathname === "/v1/comma/workspaces") {
        return jsonResponse({
          data: [
            {
              billing_account_id: "billing-1",
              group_id: "grp_1",
              id: "wsp_1",
              members: [
                { role: "owner", status: "active", user_id: credentialA.userId },
              ],
              name: "Comma workspace",
              owner_user_id: credentialA.userId,
              status: "ready",
            },
          ],
        });
      }
      return jsonResponse({
        data: [
          {
            created_at: 1_700_000_000,
            created_by: credentialA.userId,
            freshness: {
              refreshed_at: 1_700_000_100,
              state: "fresh",
            },
            id: "cnv_1",
            kind: "agent_task",
            message_count: 3,
            origin: "telegram",
            schedule: { state: "scheduled" },
            status: "working",
            title: "Review session contract",
            updated_at: 1_700_000_100,
            group_id: "grp_1",
          },
        ],
        has_more: false,
        next_cursor: null,
      });
    });
    const localData = new FakeLocalDataRepository();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData,
    });

    const envelope = await runtime.refresh(lease);

    expect(envelope.snapshot).toMatchObject({
      items: [
        {
          conversationId: "cnv_1",
          freshness: "fresh",
          origin: "telegram",
          workspaceId: "wsp_1",
        },
      ],
      source: "live-sync",
      workspaces: [{ id: "wsp_1", name: "Comma workspace" }],
    });
    expect(localData.applied[0]?.workspaces.items[0]?.raw).toEqual({
      group_id: "grp_1",
      id: "wsp_1",
      name: "Comma workspace",
    });
    expect(localData.applied[0]?.conversations?.items[0]?.raw).not.toHaveProperty(
      "message_count"
    );
    expect(localData.applied[0]?.conversations?.items[0]?.raw).toMatchObject({
      freshness: { state: "fresh" },
      origin: "telegram",
    });
    expect(localData.applied[0]?.conversations?.items[0]?.raw).not.toHaveProperty(
      "freshness.refreshed_at"
    );
  });

  it("keeps partial Salix pages as merge writes with the validated cursor", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const fetchImpl = vi.fn(async (input: Parameters<typeof fetch>[0]) => {
      const url = new URL(String(input));
      if (url.pathname === "/v1/comma/workspaces") {
        return jsonResponse({ ...workspacePage(), has_more: true });
      }
      if (url.searchParams.get("cursor") === "cursor-2") {
        return jsonResponse({
          data: [
            {
              id: "cnv_2",
              kind: "user_chat",
              status: "idle",
              title: "Tail",
              group_id: "grp_1",
            },
          ],
          has_more: false,
          next_cursor: null,
        });
      }
      return jsonResponse({
        ...conversationPage(),
        has_more: true,
        next_cursor: "cursor-2",
      });
    });
    const localData = new FakeLocalDataRepository();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData,
    });

    const envelope = await runtime.refresh(lease);

    expect(envelope.snapshot).toMatchObject({
      hasMore: true,
      nextCursor: "cursor-2",
    });
    expect(localData.applied[0]).toMatchObject({
      conversations: { mode: "merge" },
      workspaces: { mode: "merge" },
    });

    await runtime.refresh({ cursor: "cursor-2", session: lease });
    expect(localData.applied[1]).toMatchObject({
      conversations: {
        items: [{ id: "cnv_1" }, { id: "cnv_2" }],
        mode: "replace",
      },
    });
  });

  it.each([
    {
      label: "redirect",
      response: new Response(null, {
        headers: { location: "https://other.comma.test/reflected" },
        status: 302,
      }),
    },
    {
      label: "reflected bearer field",
      response: jsonResponse({
        ...workspacePage(),
        access_token: credentialA.token,
      }),
    },
    {
      label: "bearer reflected through an otherwise allowed field",
      response: jsonResponse({
        data: [{ group_id: "grp_1", id: "wsp_1", name: credentialA.token }],
      }),
    },
  ])(
    "rejects a $label without persisting or reflecting secrets",
    async ({ response }) => {
      const { authority, lease } = signedInAuthority(credentialA);
      const fetchImpl = vi.fn(
        async (
          _input: Parameters<typeof fetch>[0],
          _init?: Parameters<typeof fetch>[1]
        ) => response
      );
      const localData = new FakeLocalDataRepository();
      const runtime = new ProductInboxRuntime({
        ...testRuntimeSession(authority),
        fetch: fetchImpl as typeof fetch,
        localData,
      });

      const envelope = await runtime.refresh(lease);

      expect(envelope.snapshot).toMatchObject({
        errorCode: "protocol_mismatch",
        items: [],
        source: "error",
      });
      expect(localData.applied).toEqual([]);
      expect(JSON.stringify(envelope)).not.toContain(credentialA.token);
      expect(fetchImpl.mock.calls[0]?.[1]).toMatchObject({
        credentials: "omit",
        redirect: "manual",
      });
    }
  );
});

describe("ProductInboxRuntime demand provider", () => {
  it("refreshes from Group task-list SSE invalidation without recurring list polling", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const scheduler = new ManualScheduler();
    let eventController: ReadableStreamDefaultController<Uint8Array> | undefined;
    let conversationReads = 0;
    let eventStreams = 0;
    let releaseFirstInvalidationRead: (() => void) | undefined;
    const firstInvalidationReadGate = new Promise<void>((resolve) => {
      releaseFirstInvalidationRead = resolve;
    });
    const fetchImpl = vi.fn(
      async (
        input: Parameters<typeof fetch>[0],
        init?: Parameters<typeof fetch>[1]
      ) => {
        const url = new URL(String(input));
        if (url.pathname === "/v1/comma/workspaces") {
          return jsonResponse(workspacePage());
        }
        if (url.pathname === "/v1/comma/groups/grp_1/conversations") {
          conversationReads += 1;
          if (conversationReads === 2) await firstInvalidationReadGate;
          return jsonResponse(conversationPage());
        }
        if (url.pathname === "/v1/comma/groups/grp_1/conversations/events") {
          eventStreams += 1;
          return new Response(
            new ReadableStream<Uint8Array>({
              start(controller) {
                eventController = controller;
                init?.signal?.addEventListener("abort", () => controller.close(), {
                  once: true,
                });
              },
            }),
            {
              headers: { "content-type": "text/event-stream" },
              status: 200,
            }
          );
        }
        return new Response(null, { status: 404 });
      }
    );
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData: new FakeLocalDataRepository(),
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });
    const unsubscribe = runtime.subscribe(lease, vi.fn());

    scheduler.runNext();
    await vi.waitFor(() => {
      expect(conversationReads).toBe(1);
      expect(eventStreams).toBe(1);
      expect(eventController).toBeDefined();
    });
    eventController?.enqueue(
      new TextEncoder().encode(
        'event: conversation_list_resync_required\ndata: {"type":"conversation_list_resync_required","group_id":"grp_1","kind":"agent_task","version":"owner-a.1"}\n\n'
      )
    );

    await vi.waitFor(() => {
      expect(conversationReads).toBe(2);
    });
    eventController?.enqueue(
      new TextEncoder().encode(
        'event: conversation_list_invalidated\ndata: {"type":"conversation_list_invalidated","group_id":"grp_1","kind":"agent_task","version":"owner-a.2"}\n\n'
      )
    );
    releaseFirstInvalidationRead?.();

    await vi.waitFor(() => {
      expect(conversationReads).toBe(3);
    });
    unsubscribe();
    runtime.close();
  });

  it("replays an unsettled Task invalidation through SSE reconnect", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const scheduler = new ManualScheduler();
    const eventControllers: ReadableStreamDefaultController<Uint8Array>[] = [];
    let conversationReads = 0;
    const fetchImpl = vi.fn(
      async (
        input: Parameters<typeof fetch>[0],
        init?: Parameters<typeof fetch>[1]
      ) => {
        const url = new URL(String(input));
        if (url.pathname === "/v1/comma/workspaces") {
          return jsonResponse(workspacePage());
        }
        if (url.pathname === "/v1/comma/groups/grp_1/conversations") {
          conversationReads += 1;
          if (conversationReads === 2) {
            return new Response('{"error":"temporary_unavailable"}', {
              headers: { "content-type": "application/json" },
              status: 503,
            });
          }
          return jsonResponse(conversationPage());
        }
        if (url.pathname === "/v1/comma/groups/grp_1/conversations/events") {
          return new Response(
            new ReadableStream<Uint8Array>({
              start(controller) {
                eventControllers.push(controller);
                init?.signal?.addEventListener("abort", () => controller.close(), {
                  once: true,
                });
              },
            }),
            {
              headers: { "content-type": "text/event-stream" },
              status: 200,
            }
          );
        }
        return new Response(null, { status: 404 });
      }
    );
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData: new FakeLocalDataRepository(),
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });
    const unsubscribe = runtime.subscribe(lease, vi.fn());

    scheduler.runNext();
    await vi.waitFor(() => {
      expect(conversationReads).toBe(1);
      expect(eventControllers).toHaveLength(1);
    });
    eventControllers[0]?.enqueue(
      new TextEncoder().encode(
        'event: conversation_list_invalidated\ndata: {"type":"conversation_list_invalidated","group_id":"grp_1","kind":"agent_task","version":"owner-a.1"}\n\n'
      )
    );

    await vi.waitFor(() => {
      expect(conversationReads).toBe(2);
      expect(scheduler.pendingDelays).toEqual([1_000]);
    });
    scheduler.runNext();
    await vi.waitFor(() => expect(eventControllers).toHaveLength(2));
    eventControllers[1]?.enqueue(
      new TextEncoder().encode(
        'event: conversation_list_resync_required\ndata: {"type":"conversation_list_resync_required","group_id":"grp_1","kind":"agent_task","version":"owner-a.1"}\n\n'
      )
    );

    await vi.waitFor(() => expect(conversationReads).toBe(3));
    expect(scheduler.pendingCount).toBe(0);
    unsubscribe();
    runtime.close();
  });

  it("retries a canonical read that failed before any Task stream existed", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const scheduler = new ManualScheduler();
    let workspaceReads = 0;
    let eventStreams = 0;
    const fetchImpl = vi.fn(
      async (
        input: Parameters<typeof fetch>[0],
        init?: Parameters<typeof fetch>[1]
      ) => {
        const url = new URL(String(input));
        if (url.pathname === "/v1/comma/workspaces") {
          workspaceReads += 1;
          if (workspaceReads === 1) throw new TypeError("offline");
          return jsonResponse(workspacePage());
        }
        if (url.pathname === "/v1/comma/groups/grp_1/conversations") {
          return jsonResponse(conversationPage());
        }
        if (url.pathname === "/v1/comma/groups/grp_1/conversations/events") {
          eventStreams += 1;
          return new Response(
            new ReadableStream<Uint8Array>({
              start(controller) {
                init?.signal?.addEventListener("abort", () => controller.close(), {
                  once: true,
                });
              },
            }),
            {
              headers: { "content-type": "text/event-stream" },
              status: 200,
            }
          );
        }
        return new Response(null, { status: 404 });
      }
    );
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData: new FakeLocalDataRepository(),
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });
    const unsubscribe = runtime.subscribe(lease, vi.fn());

    scheduler.runNext();
    await vi.waitFor(() => {
      expect(workspaceReads).toBe(1);
      // Nothing settled live, so no stream exists to replay the read: the
      // projection would stay on cache until a consumer remounted.
      expect(scheduler.pendingDelays).toEqual([1_000]);
    });
    expect(eventStreams).toBe(0);

    scheduler.runNext();
    await vi.waitFor(() => {
      expect(workspaceReads).toBe(2);
      expect(eventStreams).toBe(1);
    });
    // A settled read hands recovery back to the stream; nothing keeps ticking.
    expect(scheduler.pendingCount).toBe(0);
    unsubscribe();
    runtime.close();
  });

  it("retries a selected Group read that the previous Group stream cannot recover", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const scheduler = new ManualScheduler();
    let selectedGroupReads = 0;
    const eventGroups: string[] = [];
    const fetchImpl = vi.fn(
      async (
        input: Parameters<typeof fetch>[0],
        init?: Parameters<typeof fetch>[1]
      ) => {
        const url = new URL(String(input));
        if (url.pathname === "/v1/comma/workspaces") {
          return jsonResponse({
            data: [
              { group_id: "grp_1", id: "wsp_1", name: "First" },
              { group_id: "grp_2", id: "wsp_2", name: "Selected" },
            ],
          });
        }
        if (url.pathname === "/v1/comma/groups/grp_1/conversations") {
          return jsonResponse(conversationPage());
        }
        if (url.pathname === "/v1/comma/groups/grp_2/conversations") {
          selectedGroupReads += 1;
          if (selectedGroupReads === 1) throw new TypeError("offline");
          return jsonResponse({
            data: [
              {
                ...conversationPage().data[0],
                group_id: "grp_2",
                id: "cnv_2",
                title: "Selected Task",
              },
            ],
            has_more: false,
            next_cursor: null,
          });
        }
        const eventMatch = url.pathname.match(
          /^\/v1\/comma\/groups\/(grp_[12])\/conversations\/events$/
        );
        if (eventMatch) {
          eventGroups.push(eventMatch[1]!);
          return openEventStream(init?.signal);
        }
        return new Response(null, { status: 404 });
      }
    );
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData: new FakeLocalDataRepository(),
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });
    const unsubscribe = runtime.subscribe(lease, vi.fn());

    scheduler.runNext();
    await vi.waitFor(() => expect(eventGroups).toEqual(["grp_1"]));

    await runtime.refresh({ session: lease, workspaceId: "wsp_2" });
    expect(selectedGroupReads).toBe(1);
    expect(scheduler.pendingDelays).toEqual([1_000]);

    scheduler.runNext();
    await vi.waitFor(() => {
      expect(selectedGroupReads).toBe(2);
      expect(eventGroups).toEqual(["grp_1", "grp_2"]);
      expect(runtime.get(lease)).toMatchObject({
        snapshot: {
          activeWorkspaceId: "wsp_2",
          items: [{ conversationId: "cnv_2", groupId: "grp_2" }],
          source: "live-sync",
        },
      });
    });

    unsubscribe();
    runtime.close();
  });

  it("lets new demand pull a backed-off retry forward", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const scheduler = new ManualScheduler();
    const fetchImpl = vi.fn(async () => {
      throw new TypeError("offline");
    });
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as unknown as typeof fetch,
      localData: new FakeLocalDataRepository(),
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });
    const unsubscribe = runtime.subscribe(lease, vi.fn());

    scheduler.runNext();
    await vi.waitFor(() => {
      expect(scheduler.pendingDelays).toEqual([1_000]);
    });

    // A retention arriving mid-backoff wants the projection now; the retry's
    // deadline is not its floor.
    runtime.retain(lease);
    expect(scheduler.pendingDelays).toEqual([0]);

    unsubscribe();
    runtime.release(lease);
    runtime.close();
  });

  it("walks the retry backoff up and starts a fresh ramp after demand ends", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const scheduler = new ManualScheduler();
    const fetchImpl = vi.fn(async () => {
      throw new TypeError("offline");
    });
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as unknown as typeof fetch,
      localData: new FakeLocalDataRepository(),
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });
    const unsubscribe = runtime.subscribe(lease, vi.fn());

    scheduler.runNext();
    await vi.waitFor(() => {
      expect(scheduler.pendingDelays).toEqual([1_000]);
    });

    scheduler.runNext();
    await vi.waitFor(() => {
      expect(scheduler.pendingDelays).toEqual([2_000]);
    });

    unsubscribe();
    expect(scheduler.pendingDelays).toEqual([]);

    // The next consumer recovers on its own ramp instead of inheriting the
    // ceiling this one walked up to.
    const resubscribed = runtime.subscribe(lease, vi.fn());
    scheduler.runNext();
    await vi.waitFor(() => {
      expect(scheduler.pendingDelays).toEqual([1_000]);
    });

    resubscribed();
    runtime.close();
  });

  it("binds one retention per native subscriber and publishes only settled envelopes", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const scheduler = new ManualScheduler();
    const publish = vi.fn();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: successfulFetch(),
      localData: new FakeLocalDataRepository(),
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });
    const provider = new ProductInboxNativeDemandProvider({
      publish,
      runtime,
    });

    const first = provider.retain({ session: lease }, "webcontents:7");
    const duplicate = provider.retain({ session: lease }, "webcontents:7");
    provider.retain({ session: lease }, "webcontents:8");

    expect(first).toEqual(duplicate);
    expect(scheduler.pendingCount).toBe(1);
    expect(publish).toHaveBeenCalledTimes(2);
    expect(publish.mock.calls).toEqual([
      ["webcontents:7", first],
      ["webcontents:8", first],
    ]);

    scheduler.runNext();
    await vi.waitFor(() => {
      expect(publish).toHaveBeenCalledTimes(4);
    });
    for (const [, envelope] of publish.mock.calls) {
      expect(envelope).toMatchObject({ session: lease });
      expect(JSON.stringify(envelope)).not.toContain(credentialA.token);
    }

    expect(provider.release({ session: lease }, "webcontents:7")).toBe(true);
    expect(provider.release({ session: lease }, "webcontents:7")).toBe(false);
    provider.releaseAll("webcontents:8");
    expect(provider.state({ session: lease })).toMatchObject({
      session: lease,
    });

    const refreshed = await provider.refresh({ session: lease });
    expect(refreshed).toMatchObject({
      session: lease,
      snapshot: { source: "live-sync" },
    });
  });

  it("preserves workspace and cursor inputs across native refresh", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const fetchImpl = vi.fn(async (input: Parameters<typeof fetch>[0]) => {
      const url = new URL(String(input));
      if (url.pathname === "/v1/comma/workspaces") {
        return jsonResponse({
          data: [
            { group_id: "grp_1", id: "wsp_1", name: "First" },
            { group_id: "grp_2", id: "wsp_2", name: "Requested" },
          ],
        });
      }
      return jsonResponse({
        data: [
          {
            id: "cnv_2",
            kind: "user_chat",
            status: "idle",
            title: "Requested page",
            group_id: "grp_2",
          },
        ],
        has_more: false,
        next_cursor: null,
      });
    });
    const localData = new FakeLocalDataRepository();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData,
    });
    const provider = new ProductInboxNativeDemandProvider({
      publish: vi.fn(),
      runtime,
    });

    const result = await provider.refresh({
      cursor: "cursor-1",
      limit: 7,
      session: lease,
      workspaceId: "wsp_2",
    });

    expect(result.snapshot).toMatchObject({
      activeWorkspaceId: "wsp_2",
      items: [{ conversationId: "cnv_2", workspaceId: "wsp_2" }],
    });
    const conversationUrl = new URL(String(fetchImpl.mock.calls[1]?.[0]));
    expect(conversationUrl.pathname).toBe("/v1/comma/groups/grp_2/conversations");
    expect(conversationUrl.searchParams.get("cursor")).toBe("cursor-1");
    expect(conversationUrl.searchParams.get("limit")).toBe("7");
    expect(localData.applied[0]?.conversations?.mode).toBe("merge");

    await expect(
      provider.refresh({
        reflectedToken: credentialA.token,
        session: lease,
      } as never)
    ).rejects.toThrow();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("coalesces retain/subscribe demand onto one scheduler and one sync", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const fetchImpl = successfulFetch();
    const localData = new FakeLocalDataRepository();
    const scheduler = new ManualScheduler();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl,
      localData,
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });
    const listener = vi.fn();

    runtime.retain(lease);
    runtime.retain(lease);
    const unsubscribe = runtime.subscribe(lease, listener);
    expect(scheduler.pendingCount).toBe(1);
    expect(listener).toHaveBeenCalledTimes(1);

    scheduler.runNext();
    await vi.waitFor(() => {
      expect(localData.applied).toHaveLength(1);
    });

    expect(
      fetchImpl.mock.calls.filter(([url]) =>
        String(url).endsWith("/v1/comma/workspaces")
      )
    ).toHaveLength(1);
    expect(listener).toHaveBeenCalledTimes(2);
    expect(scheduler.pendingCount).toBe(0);
    expect(localData.applied).toHaveLength(1);
    expect(listener).toHaveBeenCalledTimes(2);

    runtime.release(lease);
    runtime.release(lease);
    unsubscribe();
    expect(scheduler.pendingCount).toBe(0);
  });

  it("coalesces the same degraded cache fingerprint until utility recovery", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const fetchImpl = successfulFetch();
    const localData = new FakeLocalDataRepository();
    const scheduler = new ManualScheduler();
    const listener = vi.fn();
    localData.failWrites(new Error("local-data unavailable"));
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl,
      localData,
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });
    const unsubscribe = runtime.subscribe(lease, listener);

    scheduler.runNext();
    await vi.waitFor(() => {
      expect(localData.applied).toHaveLength(1);
      expect(scheduler.pendingCount).toBe(0);
    });
    expect(listener).toHaveBeenLastCalledWith({
      session: lease,
      snapshot: expect.objectContaining({
        errorCode: "utility_unavailable",
        source: "live-sync",
      }),
    });

    localData.recover();
    expect(scheduler.pendingDelays).toEqual([0]);
    scheduler.runNext();
    await vi.waitFor(() => {
      expect(localData.applied).toHaveLength(2);
      expect(listener).toHaveBeenLastCalledWith({
        session: lease,
        snapshot: expect.objectContaining({
          source: "live-sync",
        }),
      });
    });
    expect(listener.mock.lastCall?.[0].snapshot.errorCode).toBeUndefined();

    unsubscribe();
    runtime.close();
  });

  it("refreshes the selected workspace from task SSE without replaying a page cursor", async () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const scheduler = new ManualScheduler();
    let eventController: ReadableStreamDefaultController<Uint8Array> | undefined;
    const fetchImpl = vi.fn(async (input: Parameters<typeof fetch>[0]) => {
      const url = new URL(String(input));
      if (url.pathname === "/v1/comma/workspaces") {
        return jsonResponse({
          data: [
            { group_id: "grp_1", id: "wsp_1", name: "First" },
            { group_id: "grp_2", id: "wsp_2", name: "Selected" },
          ],
        });
      }
      if (url.pathname === "/v1/comma/groups/grp_2/conversations") {
        return jsonResponse({
          data: [
            {
              id: "cnv_2",
              kind: "user_chat",
              status: "idle",
              title: "Selected workspace",
              group_id: "grp_2",
            },
          ],
          has_more: false,
          next_cursor: null,
        });
      }
      if (url.pathname === "/v1/comma/groups/grp_2/conversations/events") {
        return new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              eventController = controller;
            },
          }),
          { headers: { "content-type": "text/event-stream" } }
        );
      }
      return new Response(null, { status: 404 });
    });
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl as typeof fetch,
      localData: new FakeLocalDataRepository(),
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });

    runtime.retain(lease);
    await runtime.refresh({
      cursor: "page-2",
      session: lease,
      workspaceId: "wsp_2",
    });
    expect(scheduler.pendingCount).toBe(0);

    await vi.waitFor(() => expect(eventController).toBeDefined());
    eventController?.enqueue(
      new TextEncoder().encode(
        'event: conversation_list_invalidated\ndata: {"type":"conversation_list_invalidated","group_id":"grp_2","kind":"agent_task","version":"owner-b.1"}\n\n'
      )
    );
    await vi.waitFor(() => {
      expect(
        fetchImpl.mock.calls.filter(
          ([input]) =>
            new URL(String(input)).pathname === "/v1/comma/groups/grp_2/conversations"
        )
      ).toHaveLength(2);
    });

    const conversationUrls = fetchImpl.mock.calls
      .map(([input]) => new URL(String(input)))
      .filter((url) => url.pathname.endsWith("/conversations"));
    expect(conversationUrls).toHaveLength(2);
    expect(conversationUrls[0]?.searchParams.get("cursor")).toBe("page-2");
    expect(conversationUrls[1]?.searchParams.get("cursor")).toBeNull();
    expect(
      conversationUrls.some(
        (url) => url.pathname === "/v1/comma/groups/grp_1/conversations"
      )
    ).toBe(false);

    runtime.release(lease);
    runtime.close();
  });

  it("cancels retained demand released before the shared scheduler fires", () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const fetchImpl = successfulFetch();
    const scheduler = new ManualScheduler();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl,
      localData: new FakeLocalDataRepository(),
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });

    runtime.retain(lease);
    runtime.release(lease);
    scheduler.runAll();

    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("stops scheduled demand without network after the exact authority lease changes", () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const fetchImpl = successfulFetch();
    const scheduler = new ManualScheduler();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: fetchImpl,
      localData: new FakeLocalDataRepository(),
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });

    runtime.retain(lease);
    authority.acceptVerifiedCredential(credentialB);
    scheduler.runNext();

    expect(fetchImpl).not.toHaveBeenCalled();
    expect(scheduler.pendingCount).toBe(0);
  });

  it("bounds subscribers and replays only token-free exact envelopes", () => {
    const { authority, lease } = signedInAuthority(credentialA);
    const scheduler = new ManualScheduler();
    const runtime = new ProductInboxRuntime({
      ...testRuntimeSession(authority),
      fetch: successfulFetch(),
      localData: new FakeLocalDataRepository(),
      maxSubscribers: 1,
      schedule: (run, delayMs) => scheduler.schedule(run, delayMs),
    });
    const first = vi.fn();

    const unsubscribe = runtime.subscribe(lease, first);
    expect(first).toHaveBeenCalledWith({
      session: lease,
      snapshot: { items: [], source: "unavailable" },
    });
    expect(() => runtime.subscribe(lease, vi.fn())).toThrow(
      expect.objectContaining({ code: "subscriber_limit" })
    );
    unsubscribe();
  });
});

class FakeLocalDataRepository implements LocalDataRepository {
  readonly applied: ProductInboxCacheApplyInput[] = [];
  readonly cachedItems: LocalProductInboxItem[] = [];
  readonly cachedWorkspaces: LocalDataProductWorkspaceInput[] = [];
  readonly recoveryListeners = new Set<(workerGeneration: number) => void>();
  #health: LocalDataRepositoryHealth = {
    status: "ready",
    workerGeneration: 1,
  };
  #writeFailure: Error | undefined;

  async applyProductInboxSync(
    input: ProductInboxCacheApplyInput
  ): Promise<LocalDataWriteAck> {
    this.applied.push(structuredClone(input));
    if (this.#writeFailure) throw this.#writeFailure;
    return {
      operationId: `write-${this.applied.length}`,
      session: input.session,
      workerGeneration: 1,
    };
  }

  async close() {}

  health(): LocalDataRepositoryHealth {
    return { ...this.#health };
  }

  async listProductInboxItems() {
    return structuredClone(this.cachedItems);
  }

  async listProductWorkspaces() {
    return structuredClone(this.cachedWorkspaces);
  }

  onRecovered(listener: (workerGeneration: number) => void) {
    this.recoveryListeners.add(listener);
    return () => {
      this.recoveryListeners.delete(listener);
    };
  }

  recover() {
    this.#writeFailure = undefined;
    this.#health = {
      status: "ready",
      workerGeneration: this.#health.workerGeneration + 1,
    };
    for (const listener of this.recoveryListeners) {
      listener(this.#health.workerGeneration);
    }
  }

  failWrites(error: Error) {
    this.#writeFailure = error;
    this.#health = {
      error: error.message,
      status: "degraded",
      workerGeneration: this.#health.workerGeneration,
    };
  }

  async referencedBlobIds() {
    return [];
  }

  async schemaVersion() {
    return 9;
  }
}

class ManualScheduler {
  readonly #scheduled: Array<{
    cancelled: boolean;
    delayMs: number;
    run: () => void;
  }> = [];

  get pendingCount() {
    return this.#scheduled.filter(({ cancelled }) => !cancelled).length;
  }

  get pendingDelays() {
    return this.#scheduled
      .filter(({ cancelled }) => !cancelled)
      .map(({ delayMs }) => delayMs);
  }

  schedule(run: () => void, delayMs: number) {
    const scheduled = { cancelled: false, delayMs, run };
    this.#scheduled.push(scheduled);
    return () => {
      scheduled.cancelled = true;
    };
  }

  runNext() {
    const index = this.#scheduled.findIndex(({ cancelled }) => !cancelled);
    if (index < 0) throw new Error("No ProductInbox work is scheduled.");
    const [scheduled] = this.#scheduled.splice(index, 1);
    scheduled?.run();
  }

  runAll() {
    for (const scheduled of this.#scheduled.splice(0)) {
      if (!scheduled.cancelled) scheduled.run();
    }
  }
}

function signedInAuthority(credential: typeof credentialA | typeof credentialB) {
  const authority = new MainProductCredentialAuthority({
    authorityInstanceId: "main-authority",
    trustedAudience: AUDIENCE,
  });
  const snapshot = authority.acceptVerifiedCredential(credential);
  return { authority, lease: requiredLease(snapshot) };
}

function testRuntimeSession(authority: MainProductCredentialAuthority) {
  return {
    authority,
    reportUnauthorized: async (credential: MainProductCredentialLease) => {
      authority.beginInvalidation(leaseExpectation(credential));
    },
  };
}

function leaseExpectation(credential: MainProductCredentialLease) {
  return {
    authorityInstanceId: credential.authorityInstanceId,
    expectedAudience: credential.audience,
    expectedSessionId: credential.sessionId,
    generation: credential.generation,
  };
}

function requiredLease(
  snapshot: ReturnType<MainProductCredentialAuthority["getSnapshot"]>
): SessionProductLease {
  const lease = sessionProductLease(snapshot);
  if (!lease) throw new Error("Expected a signed-in ProductInbox test session.");
  return lease;
}

function successfulFetch() {
  return vi.fn(async (input: URL | RequestInfo, init?: RequestInit) => {
    const url = new URL(String(input));
    if (url.pathname === "/v1/comma/workspaces") {
      return jsonResponse(workspacePage());
    }
    if (url.pathname === "/v1/comma/groups/grp_1/conversations") {
      return jsonResponse(conversationPage());
    }
    if (url.pathname === "/v1/comma/groups/grp_1/conversations/events") {
      return openEventStream(init?.signal);
    }
    return new Response(null, { status: 404 });
  }) as unknown as ReturnType<typeof vi.fn<typeof fetch>>;
}

function openEventStream(signal?: AbortSignal | null) {
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        const close = () => {
          try {
            controller.close();
          } catch {
            // The stream may already have been closed by the test.
          }
        };
        if (signal?.aborted) close();
        else signal?.addEventListener("abort", close, { once: true });
      },
    }),
    {
      headers: { "content-type": "text/event-stream" },
      status: 200,
    }
  );
}

function workspacePage() {
  return {
    data: [{ group_id: "grp_1", id: "wsp_1", name: "Comma workspace" }],
    has_more: false,
    next_cursor: null,
  };
}

function conversationPage() {
  return {
    data: [
      {
        created_at: 1_700_000_000,
        freshness: { state: "fresh" as const },
        id: "cnv_1",
        kind: "agent_task" as const,
        status: "working",
        title: "Review session contract",
        updated_at: 1_700_000_100,
        group_id: "grp_1",
      },
    ],
    has_more: false,
    next_cursor: null,
  };
}

function jsonResponse(value: unknown, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(value), {
    headers: { "content-type": "application/json", ...headers },
    status: 200,
  });
}

function deferred<T>() {
  let resolvePromise!: (value: T) => void;
  const promise = new Promise<T>((resolve) => {
    resolvePromise = resolve;
  });
  return { promise, resolve: resolvePromise };
}
