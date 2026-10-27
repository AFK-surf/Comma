import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { sessionExpectation } from "@comma/session-contract";
import { describe, expect, it } from "vitest";
import type { ProductInboxListResult } from "../src/contract.ts";
import { FakeMain } from "../src/testing/fake-main.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const workspace = { group_id: "g", id: "wsp", name: "Work", status: "ready" };
const otherWorkspace = { group_id: "g2", id: "wsp2", name: "Side", status: "ready" };
const ensureHome = "/v1/comma/groups/g/assistant-chat";
const messages = "/v1/comma/groups/g/conversations/home/messages";
const request = "0b8f2c4e-4f1a-4c6d-9b7e-2a1d3c5e7f90";
const words = "Book a table for four";
const home = {
  group_id: "g",
  id: "home",
  kind: "user_chat",
  title: "Home",
  status: "active",
};
const receipt = { ...home, accepted_message_id: "m-new" };
const body = {
  message: { type: "text", text: words },
  client_request_id: request,
  message_type: "quick_chat",
  client_timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
};

function setup(nativeSession = false) {
  const host = new FakeHost({ sessionSource: nativeSession ? "core" : "host" });
  const main = nativeSession ? new FakeMain(host) : undefined;
  if (main) {
    main.active = {
      audience: main.origin,
      token: "old-account-token",
      sessionId: "session-user-1",
      userId: "user-1",
      email: "user-1@example.test",
      expiresAtEpochSeconds: 4_000_000_000,
    };
    host.api.on("GET", "/v1/comma/auth/session", () => {
      const active = main.active;
      return active
        ? json(200, {
            expires_at: active.expiresAtEpochSeconds,
            session_id: active.sessionId,
            user: {
              id: active.userId,
              email: active.email,
              name: "Member",
              status: "active",
            },
          })
        : json(401, { error: "unauthorized" });
    });
    host.api.on("POST", "/v1/comma/auth/logout", { signed_out: true });
  }
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
  host.api.on("GET", "/v1/comma/groups/g/conversations", { data: [] });
  host.api.onStream("/v1/comma/groups/g/conversations/events");
  host.api.on("POST", ensureHome, home);
  host.api.on("POST", messages, json(202, receipt));
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const key = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(key, v),
      () => undefined
    );
    return () => values.get(key) as T;
  };
  if (!main) core.observeSession(signedIn());
  const send = (id = request, text = words, selectedWorkspace?: string) =>
    client
      .call("quickChat.sendMessage", {
        client_request_id: id,
        text,
        ...(selectedWorkspace ? { workspace: selectedWorkspace } : {}),
      })
      .then(
        (value) => ({ value }),
        (error: { code: string; status?: number }) => ({ error })
      );
  return { core, main, time: host.time!, api: host.api, client, watch, send };
}

describe("a Quick Chat message", () => {
  it("sends the words to Home and returns their receipt before the Router creates a Task", async () => {
    const t = setup();
    const tasks = t.watch<ProductInboxListResult>({ topic: "tasks" });
    await t.time.pass(100);
    const answer = t.send();
    await t.time.pass(100);
    expect(await answer).toEqual({
      value: {
        workspace_id: "wsp",
        group_id: "g",
        conversation_id: "home",
        message_id: "m-new",
      },
    });
    expect(tasks()?.items).toEqual([]);
    expect(
      t.api.requests.filter((r) => r.method === "POST").map((r) => r.path)
    ).toEqual([`${ensureHome}?message_limit=1`, `${messages}?message_limit=1`]);
    expect(t.api.seen("POST", messages).map((r) => r.body)).toEqual([body]);
    expect(t.api.seen("GET", "/v1/comma/groups/g/task-summaries")).toEqual([]);
  });

  it("lists the Task the Router made from the words with the id of their message", async () => {
    const t = setup();
    const task = {
      group_id: "g",
      id: "task",
      kind: "agent_task",
      title: "Book a table",
      status: "active",
      parent_message_id: "m-new",
    };
    t.api.on("GET", "/v1/comma/groups/g/conversations", { data: [task, home] });
    const tasks = t.watch<ProductInboxListResult>({ topic: "tasks" });
    await t.time.pass(100);
    expect(
      tasks()?.items.map(({ conversationId, parentMessageId }) => ({
        conversationId,
        parentMessageId,
      }))
    ).toEqual([
      { conversationId: "task", parentMessageId: "m-new" },
      { conversationId: "home", parentMessageId: undefined },
    ]);
  });

  it("uses the named workspace and preserves local and server workspace refusals", async () => {
    const t = setup();
    const otherHome = "/v1/comma/groups/g2/assistant-chat";
    const otherMessages = "/v1/comma/groups/g2/conversations/home2/messages";
    t.api.on("GET", "/v1/comma/workspaces", { data: [workspace, otherWorkspace] });
    t.api.on("POST", otherHome, { ...home, group_id: "g2", id: "home2" });
    t.api.on("POST", otherMessages, json(202, { accepted_message_id: "m-other" }));

    const named = t.send(request, words, "wsp2");
    await t.time.pass(100);
    expect(await named).toEqual({
      value: {
        workspace_id: "wsp2",
        group_id: "g2",
        conversation_id: "home2",
        message_id: "m-other",
      },
    });
    expect(t.api.seen("POST", ensureHome)).toEqual([]);

    const unknown = t.send(request, words, "wsp-gone");
    await t.time.pass(100);
    expect(await unknown).toMatchObject({ error: { code: "not_found" } });
    expect(t.api.seen("POST", otherHome)).toHaveLength(1);

    t.api.on("POST", otherHome, json(403, { error: "forbidden" }));
    const forbidden = t.send(request, words, "wsp2");
    await t.time.pass(100);
    expect(await forbidden).toMatchObject({
      error: { code: "forbidden", status: 403 },
    });
    expect(t.api.seen("POST", otherMessages)).toHaveLength(1);
  });

  it("matches concurrent sends by accepted_message_id, even when the conversation tail belongs to another send", async () => {
    const t = setup();
    t.api.on("POST", messages, (r) => {
      const id = (r.body as { client_request_id: string }).client_request_id;
      return json(202, {
        ...home,
        accepted_message_id: `m-${id}`,
        messages: [{ id: "m-someone-else", sender_id: "someone-else" }],
      });
    });
    const releaseFirst = t.api.hold("POST", messages);
    const first = t.send("first", "First request");
    await t.time.pass(100);
    const second = t.send("second", "Second request");
    await t.time.pass(100);
    expect(await second).toMatchObject({ value: { message_id: "m-second" } });
    releaseFirst();
    await t.time.pass(100);
    expect(await first).toMatchObject({ value: { message_id: "m-first" } });
  });

  it("retries one server error after a second, keeping the original Home, request id and words when focus changes", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/workspaces", { data: [workspace, otherWorkspace] });
    const answers = [json(502, { error: "bad_gateway" }), json(202, receipt)];
    t.api.on("POST", messages, () => answers.shift()!);
    const answer = t.send();
    await t.time.pass(900);
    expect(t.api.seen("POST", messages)).toHaveLength(1);
    const focused = t.client.call("tasks.focus", { workspace: "wsp2" });
    t.api.on("POST", ensureHome, { ...home, id: "replacement-home" });
    await t.time.pass(200);
    await focused;
    expect(await answer).toMatchObject({
      value: { workspace_id: "wsp", conversation_id: "home", message_id: "m-new" },
    });
    expect(t.api.seen("POST", ensureHome)).toHaveLength(1);
    expect(t.api.seen("POST", messages).map((r) => r.body)).toEqual([body, body]);
  });

  it("retries a timed out send with the same identity and stops after a second network failure", async () => {
    const t = setup();
    t.api.hold("POST", messages);
    const slow = t.send();
    await t.time.pass(30_900);
    expect(t.api.seen("POST", messages)).toHaveLength(1);
    await t.time.pass(200);
    expect(await slow).toMatchObject({ value: { message_id: "m-new" } });
    expect(t.api.seen("POST", messages).map((r) => r.body)).toEqual([body, body]);

    t.api.on("POST", messages, offline());
    const unreachable = t.send();
    await t.time.pass(1_100);
    expect(await unreachable).toMatchObject({ error: { code: "network" } });
    expect(t.api.seen("POST", messages).map((r) => r.body)).toEqual([
      body,
      body,
      body,
      body,
    ]);
    await t.time.pass(5_000);
    expect(t.api.seen("POST", messages)).toHaveLength(4);
  });

  it("returns a 404 without replacing the request id or automatically sending again", async () => {
    const t = setup();
    t.api.on("POST", messages, json(404, { error: "not_found" }));
    const refused = t.send();
    await t.time.pass(1_100);
    expect(await refused).toMatchObject({ error: { code: "not_found", status: 404 } });
    expect(t.api.seen("POST", messages).map((r) => r.body)).toEqual([body]);

    t.api.on("POST", messages, json(202, receipt));
    const retried = t.send();
    await t.time.pass(100);
    expect(await retried).toMatchObject({ value: { message_id: "m-new" } });
    expect(t.api.seen("POST", messages).map((r) => r.body)).toEqual([body, body]);
  });

  it.each(["Home confirmation", "message retry delay"] as const)(
    "keeps the old send bound to its session during %s when another account signs in",
    async (phase) => {
      // Run Electron's lifecycle and its existing Main fixture so sign-out closes
      // the lease. The observer-only FakeHost delegates that boundary to its host.
      const t = setup(true);
      await t.time.pass(100);
      const initial = t.core.electronSession!.snapshot();
      if (initial.phase !== "signed_in")
        throw new Error("Expected the startup probe to sign in");
      expect(t.main!.gateLease()?.sessionId).toBe("session-user-1");
      const release =
        phase === "Home confirmation" ? t.api.hold("POST", ensureHome) : undefined;
      if (phase === "message retry delay") {
        const answers = [json(502, { error: "bad_gateway" }), json(202, receipt)];
        t.api.on("POST", messages, () => answers.shift() ?? json(202, receipt));
      }
      const oldSend = t.send();
      await t.time.pass(100);
      expect(t.api.seen("POST", ensureHome)).toHaveLength(1);
      const oldMessageCount = phase === "Home confirmation" ? 0 : 1;
      expect(t.api.seen("POST", messages)).toHaveLength(oldMessageCount);

      const signOut = t.client.call("session.signOut", {
        expected: sessionExpectation(initial),
      });
      await t.time.pass(50);
      expect(await signOut).toMatchObject({ ok: true, value: { phase: "signed_out" } });
      t.main!.active = {
        audience: t.main!.origin,
        token: "new-account-token",
        sessionId: "session-user-2",
        userId: "user-2",
        email: "user-2@example.test",
        expiresAtEpochSeconds: 4_000_000_000,
      };
      const signIn = t.client.call("session.reconcile", { reason: "peer_mutation" });
      await t.time.pass(50);
      expect(await signIn).toMatchObject({
        ok: true,
        value: { phase: "signed_in", principal: { userId: "user-2" } },
      });
      expect(t.main!.gateLease()?.sessionId).toBe("session-user-2");
      release?.();
      await t.time.pass(2_000);
      expect(await oldSend).toMatchObject({ error: { code: "signed_out" } });
      const oldAttempts = t.api.seen("POST", messages);
      if (phase === "Home confirmation") expect(oldAttempts).toEqual([]);
      // FakeMain checks admission when the request effect is built, not on each
      // retry. Main's protocol tests cover its network fence; here every old
      // attempt must retain the old lease and its result must be refused.
      expect(new Set(oldAttempts.map((r) => r.lease.sessionId))).toEqual(
        new Set(phase === "Home confirmation" ? [] : ["session-user-1"])
      );

      const newSend = t.send("new-account-request", "New account's words");
      await t.time.pass(100);
      expect(await newSend).toMatchObject({ value: { message_id: "m-new" } });
      expect(t.api.seen("POST", messages).at(-1)).toMatchObject({
        body: {
          client_request_id: "new-account-request",
          message: { type: "text", text: "New account's words" },
        },
        lease: { sessionId: "session-user-2" },
      });
    }
  );

  it("fails an answer without an explicit receipt instead of treating the latest message as its own", async () => {
    const t = setup();
    t.api.on("POST", messages, json(202, { ...home, messages: [{ id: "m-tail" }] }));
    const answer = t.send();
    await t.time.pass(1_100);
    expect(await answer).toMatchObject({ error: { code: "bad_response" } });
    expect(t.api.seen("POST", messages)).toHaveLength(1);
  });
});

describe("a live dictation ticket", () => {
  const tickets = "/v1/comma/me/dictation/tickets";

  it("comes from the member's session with the socket to open", async () => {
    const t = setup();
    const ticket = {
      url: "wss://api.comma.test/v1/comma/dictation",
      ticket: "dictation_id.secret",
      expires_at: 1_787_563_320,
    };
    t.api.on("POST", tickets, json(201, ticket));
    await t.time.pass(100);
    const answer = t.client.call("quickChat.dictationTicket", {});
    await t.time.pass(100);
    expect(await answer).toEqual(ticket);
  });

  it("fails where the server has no live dictation", async () => {
    const t = setup();
    t.api.on("POST", tickets, json(503, { error: "dictation_unavailable" }));
    await t.time.pass(100);
    const answer = t.client.call("quickChat.dictationTicket", {}).then(
      () => "answered",
      (error: { status?: number }) => error.status
    );
    await t.time.pass(100);
    expect(await answer).toBe(503);
  });
});
