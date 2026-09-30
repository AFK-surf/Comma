import {
  sessionProductLeaseSchema,
  type SessionProductLease,
} from "@comma/session-contract";
import { z } from "zod";
import { describe, expect, it, vi } from "vitest";
import { createCommaApi } from "@comma/app/api";
import { ConversationChannel } from "@comma/app/chat-runtime";
import { NativeSessionAdmissionError } from "../modules/ipc";
import {
  createCurrentMainSessionApiBinding,
  createMainSessionFetch,
  MainNativeSessionAdmissionGuard,
  MainProductCredentialAuthority,
  type MainSessionBoundApi,
  type MainProductCredentialLease,
} from "../modules/session";

const audience = "https://api.comma.example";

describe("Main Session transport", () => {
  it("keeps unchanged Task refreshes live without retrying or warning", async () => {
    vi.useFakeTimers();
    const { credential, session } = createSession();
    const etag = '"task-unchanged"';
    const upstream = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if (new Headers(init?.headers).get("if-none-match") === etag) {
        return new Response(null, { headers: { etag }, status: 304 });
      }
      const response = jsonResponse({
        group_id: "group-1",
        id: "task-1",
        kind: "agent_task",
        messages: [],
        status: "completed",
        title: "Unchanged task",
      });
      response.headers.set("etag", etag);
      return response;
    });
    const api = createCommaApi({
      baseUrl: audience,
      fetch: createMainSessionFetch({ credential, fetch: upstream, session }),
      token: "main_secret",
    });
    // Leave the unrelated Group stream idle while exercising explicit refresh.
    api.streamConversationListEvents = async (_groupId, options) =>
      new Promise<void>((resolve) => {
        options.signal?.addEventListener("abort", () => resolve(), { once: true });
      });
    const channel = new ConversationChannel({
      api,
      conversationId: "task-1",
      env: { jitterMs: () => 0 },
      groupId: "group-1",
      initialKind: "agent_task",
      workspaceId: "workspace-1",
    });
    const warnings: unknown[] = [];
    channel.subscribe(() => {
      if (channel.getSnapshot().syncWarning) {
        warnings.push(channel.getSnapshot().syncWarning);
      }
    });

    try {
      channel.start();
      await vi.advanceTimersByTimeAsync(0);
      const conversation = channel.getSnapshot().conversation;
      expect(conversation?.title).toBe("Unchanged task");

      channel.refresh();
      await vi.advanceTimersByTimeAsync(0);
      expect(upstream).toHaveBeenCalledTimes(2);
      expect(channel.getSnapshot()).toMatchObject({
        connection: "live",
        lastBackoffMs: 0,
        status: "ready",
        syncWarning: undefined,
      });
      expect(channel.getSnapshot().conversation).toBe(conversation);
      await vi.advanceTimersByTimeAsync(30_000);
      expect(upstream).toHaveBeenCalledTimes(2);
      expect(warnings).toEqual([]);
    } finally {
      channel.stop();
      vi.useRealTimers();
    }
  });

  it.each([300, 301, 302, 303, 305, 307, 308])(
    "still rejects HTTP %s without following its Location",
    async (status) => {
      const { credential, session } = createSession();
      const upstream = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
        expect(init?.redirect).toBe("manual");
        return new Response(null, {
          headers: { location: "https://other.example/private" },
          status,
        });
      });
      const mainFetch = createMainSessionFetch({
        credential,
        fetch: upstream,
        session,
      });

      await expect(mainFetch(`${audience}/v1/comma/workspaces`)).rejects.toThrow(
        "Main Session transport rejected an HTTP redirect."
      );
      expect(upstream).toHaveBeenCalledOnce();
    }
  );

  it("uses only the admitted Main bearer and strips ambient authority headers", async () => {
    const { credential, session } = createSession();
    const upstream = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      expect(init).toMatchObject({
        credentials: "omit",
        redirect: "manual",
        signal: credential.signal,
      });
      expect(headers.get("authorization")).toBe("Bearer main_secret");
      expect(headers.get("cookie")).toBeNull();
      expect(headers.get("proxy-authorization")).toBeNull();
      expect(headers.get("x-renderer-secret")).toBeNull();
      expect(headers.get("accept")).toBe("application/json");
      return jsonResponse({ ok: true });
    });
    const mainFetch = createMainSessionFetch({
      credential,
      fetch: upstream as typeof fetch,
      session,
    });

    const response = await mainFetch(`${audience}/v1/comma/workspaces`, {
      headers: {
        accept: "application/json",
        authorization: "Bearer renderer_secret",
        cookie: "ambient=secret",
        "proxy-authorization": "Basic secret",
        "x-renderer-secret": "secret",
      },
    });

    await expect(response.json()).resolves.toEqual({ ok: true });
    expect(upstream).toHaveBeenCalledTimes(1);
  });

  it("rejects an escaped audience and makes zero upstream requests", async () => {
    const { credential, session } = createSession();
    const upstream = vi.fn();
    const mainFetch = createMainSessionFetch({
      credential,
      fetch: upstream as typeof fetch,
      session,
    });

    await expect(
      mainFetch("https://other.example/v1/comma/workspaces")
    ).rejects.toThrow("escaped its credential audience");
    expect(upstream).not.toHaveBeenCalled();
  });

  it("settles a delayed body before making it visible", async () => {
    const { authority, credential, session } = createSession();
    const body = deferred<Response>();
    const mainFetch = createMainSessionFetch({
      credential,
      fetch: vi.fn(() => body.promise) as typeof fetch,
      session,
    });
    const response = mainFetch(`${audience}/v1/comma/workspaces`);

    authority.beginInvalidation(expectation(credential));
    body.resolve(jsonResponse({ account: "stale" }));

    await expect(response).rejects.toBeInstanceOf(NativeSessionAdmissionError);
  });

  it("replaces a delayed body failure with the exact stale-Session admission error", async () => {
    const { authority, credential, session } = createSession();
    const bodyFailure = deferred<ArrayBuffer>();
    const upstreamResponse = jsonResponse({ ignored: true });
    const readBody = vi
      .spyOn(upstreamResponse, "arrayBuffer")
      .mockImplementation(() => bodyFailure.promise);
    const mainFetch = createMainSessionFetch({
      credential,
      fetch: vi.fn(async () => upstreamResponse),
      session,
    });
    const response = mainFetch(`${audience}/v1/comma/workspaces`);
    await vi.waitFor(() => expect(readBody).toHaveBeenCalledOnce());

    authority.beginInvalidation(expectation(credential));
    bodyFailure.reject(new Error("body transport failed"));

    await expect(response).rejects.toBeInstanceOf(NativeSessionAdmissionError);
  });

  it("settles every SSE chunk and aborts stale delivery", async () => {
    const { authority, credential, session } = createSession();
    let streamController!: ReadableStreamDefaultController<Uint8Array>;
    const source = new ReadableStream<Uint8Array>({
      start(controller) {
        streamController = controller;
      },
    });
    const mainFetch = createMainSessionFetch({
      credential,
      fetch: vi.fn(
        async () =>
          new Response(source, {
            headers: { "content-type": "text/event-stream" },
          })
      ) as typeof fetch,
      session,
    });
    const response = await mainFetch(`${audience}/v1/events`);
    const reader = response.body?.getReader();
    if (!reader) throw new Error("Expected stream body.");

    streamController.enqueue(new TextEncoder().encode("data: first\n\n"));
    await expect(reader.read()).resolves.toMatchObject({ done: false });
    authority.beginInvalidation(expectation(credential));
    streamController.enqueue(new TextEncoder().encode("data: stale\n\n"));
    await expect(reader.read()).rejects.toBeInstanceOf(NativeSessionAdmissionError);
  });

  it("reports a current 401 against the exact credential", async () => {
    const { credential, session } = createSession();
    const mainFetch = createMainSessionFetch({
      credential,
      fetch: vi.fn(async () => jsonResponse({ error: "unauthorized" }, 401)),
      session,
    });

    await expect(mainFetch(`${audience}/v1/comma/workspaces`)).resolves.toMatchObject({
      status: 401,
    });
    expect(session.reportUnauthorized).toHaveBeenCalledWith(credential);
  });

  it("settles a parsed API result before a background Main consumer can observe it", async () => {
    const { authority, credential, session } = createSession();
    const lease = productLease(credential);
    const guard = new MainNativeSessionAdmissionGuard(authority);
    let binding: MainSessionBoundApi | undefined;
    const upstream = vi.fn(async () =>
      jsonResponse({
        data: [
          {
            description: "private",
            location: "skills/private/SKILL.md",
            name: "Private",
            skill_id: "skill_private",
          },
        ],
      })
    );
    await guard.run({
      contract: {
        channel: "comma:test:capture-main-api",
        input: z.strictObject({ session: sessionProductLeaseSchema }),
        output: z.string(),
        sessionAdmission: "required",
      },
      handler: () => {
        binding = createCurrentMainSessionApiBinding({
          fetch: upstream as typeof fetch,
          session,
        });
        return "captured";
      },
      input: { session: lease },
    });
    if (!binding) throw new Error("Expected a captured Main Session API.");
    const bound: MainSessionBoundApi = binding;
    expect(bound.session).toEqual(lease);
    expect(bound.session).not.toHaveProperty("token");

    const parsed = deferred<void>();
    const releaseParsed = deferred<void>();
    const originalJson = Response.prototype.json;
    const readJson = vi
      .spyOn(Response.prototype, "json")
      .mockImplementation(async function (this: Response) {
        const value = await originalJson.call(this);
        parsed.resolve();
        await releaseParsed.promise;
        return value;
      });

    try {
      const result = bound.api.listWorkspaceSkills("wsp_1");
      await parsed.promise;
      authority.beginInvalidation(expectation(credential));
      releaseParsed.resolve();

      await expect(result).rejects.toBeInstanceOf(NativeSessionAdmissionError);
      expect(upstream).toHaveBeenCalledOnce();
    } finally {
      readJson.mockRestore();
    }
  });
});

function createSession() {
  const authority = new MainProductCredentialAuthority({
    authorityInstanceId: "authority-1",
    trustedAudience: audience,
  });
  const snapshot = authority.acceptVerifiedCredential({
    audience,
    email: "peng@example.com",
    expiresAtEpochSeconds: 1_900_000_000,
    sessionId: "session-1",
    token: "main_secret",
    userId: "user-1",
  });
  if (snapshot.phase !== "signed_in") throw new Error("Expected signed in.");
  const credential = authority.acquireProductCredential({
    authorityInstanceId: snapshot.authority.authorityInstanceId,
    expectedAudience: snapshot.session.audience,
    expectedSessionId: snapshot.session.sessionId,
    generation: snapshot.generation,
  });
  if (!credential) throw new Error("Expected credential.");
  return {
    authority,
    credential,
    session: {
      authority,
      reportUnauthorized: vi.fn(async () => {}),
    },
  };
}

function expectation(credential: MainProductCredentialLease) {
  return {
    authorityInstanceId: credential.authorityInstanceId,
    expectedAudience: credential.audience,
    expectedSessionId: credential.sessionId,
    generation: credential.generation,
  };
}

function productLease(credential: MainProductCredentialLease): SessionProductLease {
  return {
    audience: credential.audience,
    authorityInstanceId: credential.authorityInstanceId,
    generation: credential.generation,
    sessionId: credential.sessionId,
  };
}

function jsonResponse(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {
    headers: { "content-type": "application/json" },
    status,
  });
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}
