import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatRuntimeSnapshot } from "@comma/chat-contract";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  signedOut,
  startTestCore,
} from "../../src/testing/index.ts";
import { comparable, replay } from "../../src/testing/replay.ts";
import type { WorkspaceChatValue } from "../../src/contract.ts";

const base = "/v1/comma/groups/grp_1/conversations/cnv_1";
const events = `${base}/events`;
const feed = "/v1/comma/groups/grp_1/conversations/events";
const target = { workspaceId: "wsp_1", groupId: "grp_1", conversationId: "cnv_1" };

const message = (
  id: string,
  role: "user" | "assistant",
  text: string,
  clientRequestId?: string
) => ({
  message_id: id,
  kind: "message",
  actor_type: role === "assistant" ? "agent" : "user",
  content: [{ type: "text", text }],
  ...(clientRequestId ? { client_request_id: clientRequestId } : {}),
  created_at: 1,
});
const conversation = (messages: unknown[], extra: Record<string, unknown> = {}) => ({
  group_id: "grp_1",
  id: "cnv_1",
  kind: "user_chat",
  title: "Thread",
  status: "completed",
  messages,
  ...extra,
});

function setup(host = new FakeHost(), surface = "win_main") {
  host.api.onStream(events).onStream(feed);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host, surface), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const key = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(key, v),
      (e) => values.set(key, { error: e.code })
    );
    return () => values.get(key) as T;
  };
  const lease = {
    ...target,
    subscriberId: `${surface}:grp_1/cnv_1`,
    leaseId: crypto.randomUUID(),
  };
  const labeled = watch<{ session: unknown; snapshot: ChatRuntimeSnapshot }>({
    topic: "chat",
    surface,
  });
  const chat = () => labeled()?.snapshot;
  /** The window's view of the conversation, as the `chatView.*` calls name it. */
  const named = { workspace: "wsp_1", group: "grp_1", conversation: "cnv_1", surface };
  /** Shows the conversation in the window (its view retains it); the view's value. */
  const show = () =>
    watch<{ state: { draft: string } | null }>({ topic: "chatView", ...named });
  /** A call on the window's view. */
  const act = (name: string, params: Record<string, unknown> = {}) =>
    client.call(`chatView.${name}`, { ...named, ...params });
  const shown = () =>
    chat()?.sessions.find((session) => session.conversationId === "cnv_1")?.state;
  return {
    labeled,
    host,
    core,
    client,
    time: host.time!,
    api: host.api,
    lease,
    chat,
    shown,
    surface,
    show,
    act,
  };
}
const texts = (state: { messages: { text: string }[] } | undefined) =>
  state?.messages.map((m) => m.text);

describe("a conversation kept on the device", () => {
  it("opens from the device at once, offline too, after the core starts again", async () => {
    const host = new FakeHost();
    host.api.on(
      "GET",
      base,
      conversation([message("m1", "user", "Hi"), message("m2", "assistant", "Hello")])
    );
    const first = setup(host);
    first.core.observeSession(signedIn());
    await first.client.call("chat.retain", first.lease);
    await first.time.pass(1_500);
    expect(texts(first.shown())).toEqual(["Hi", "Hello"]);
    first.client.close();
    first.core.close();

    // The device is offline now; the conversation still shows what it showed while it tries again.
    host.api.on("GET", base, offline());
    const again = setup(host);
    again.core.observeSession(signedIn());
    await again.client.call("chat.retain", again.lease);
    await again.time.pass(100);
    expect(texts(again.shown())).toEqual(["Hi", "Hello"]);
    expect(again.shown()).toMatchObject({
      connection: "reconnecting",
      status: "ready",
    });
  });

  it("sends a message that was under way again, with the same request id, once the core starts again", async () => {
    const host = new FakeHost();
    host.api.on("GET", base, conversation([]));
    host.api.on("POST", `${base}/messages`, offline());
    const first = setup(host);
    first.core.observeSession(signedIn());
    first.show();
    await first.time.pass(100);
    void first.act("send", { text: "Still there?" }).catch(() => undefined);
    // The device stops before the server answers.
    const hold = host.api.hold("POST", `${base}/messages`);
    await first.time.pass(1_500);
    const sent = host.api.seen("POST", `${base}/messages`);
    const requestId = (sent[0]!.body as { client_request_id: string })
      .client_request_id;
    first.client.close();
    first.core.close();
    hold();

    host.api.on("POST", `${base}/messages`, () =>
      json(200, conversation([message("m1", "user", "Still there?", requestId)]))
    );
    const again = setup(host);
    again.core.observeSession(signedIn());
    await again.client.call("chat.retain", again.lease);
    await again.time.pass(1_500);
    const resent = host.api.seen("POST", `${base}/messages`).slice(sent.length);
    expect(
      resent.map((r) => (r.body as { client_request_id: string }).client_request_id)
    ).toContain(requestId);
    expect(texts(again.shown())).toEqual(["Still there?"]);
  });

  it("keeps a send on the device the moment it starts: a device that stops a moment later sends it again", async () => {
    const host = new FakeHost();
    host.api.on("GET", base, conversation([]));
    const hold = host.api.hold("POST", `${base}/messages`);
    host.api.on("POST", `${base}/messages`, offline());
    const first = setup(host);
    first.core.observeSession(signedIn());
    first.show();
    await first.time.pass(100);
    void first.act("send", { text: "Right away" }).catch(() => undefined);
    // The device stops (no orderly close) well within the second a draft waits to be written.
    await first.time.pass(10);
    const sent = host.api.seen("POST", `${base}/messages`);
    const requestId = (sent[0]!.body as { client_request_id: string })
      .client_request_id;
    first.client.close();
    first.core.runner.shutdown();
    hold();

    host.api.on("POST", `${base}/messages`, () =>
      json(200, conversation([message("m1", "user", "Right away", requestId)]))
    );
    const again = setup(host);
    again.core.observeSession(signedIn());
    await again.client.call("chat.retain", again.lease);
    await again.time.pass(1_500);
    expect(
      host.api
        .seen("POST", `${base}/messages`)
        .slice(sent.length)
        .map((r) => (r.body as { client_request_id: string }).client_request_id)
    ).toContain(requestId);
  });

  it("ends a group's feed when the group is refused (403), keeping nothing of it", async () => {
    const host = new FakeHost();
    host.api.on("GET", base, conversation([message("m1", "user", "Hi")]));
    const t = setup(host);
    host.api.onStream(feed, 403);
    t.core.observeSession(signedIn());
    await t.client.call("chat.retain", t.lease);
    await t.time.pass(1_500);
    await t.client.call("chat.release", t.lease);
    await t.time.pass(31_000, 1_000);
    const opened = host.api.seen("GET", feed).length;
    await t.time.pass(120_000, 1_000);
    // Refused: not asked again, and the group's conversation is no longer kept.
    expect(host.api.seen("GET", feed).length).toBe(opened);
    host.api.on("GET", base, offline());
    await t.client.call("chat.retain", { ...t.lease, leaseId: crypto.randomUUID() });
    await t.time.pass(100);
    expect(texts(t.shown()) ?? []).toEqual([]);
  });

  it("ends a group's feed once the group has no kept conversation left", async () => {
    const host = new FakeHost();
    host.api.on("GET", base, conversation([message("m1", "user", "Hi")]));
    const t = setup(host);
    t.core.observeSession(signedIn());
    await t.client.call("chat.retain", t.lease);
    await t.time.pass(1_500);
    await t.client.call("chat.release", t.lease);
    await t.time.pass(31_000, 1_000);
    const open = host.api.open(feed)!;
    open.event({
      type: "conversation_changed",
      group_id: "grp_1",
      conversation_id: "cnv_1",
      kind: "user_chat",
      change: "delete",
      version: "v.2",
    });
    await t.time.pass(100);
    expect(open.closed).toBe(true);
    await t.time.pass(60_000, 1_000);
    expect(host.api.open(feed)).toBeUndefined();
  });

  it("is read again in the background when the group's feed says it changed, while no window shows it", async () => {
    const host = new FakeHost();
    let messages = [message("m1", "user", "Hi")];
    host.api.on("GET", base, () => json(200, conversation(messages)));
    const t = setup(host);
    t.core.observeSession(signedIn());
    await t.client.call("chat.retain", t.lease);
    await t.time.pass(1_500);
    await t.client.call("chat.release", t.lease);
    // The view's lease ends after its 30 s.
    await t.time.pass(31_000, 1_000);
    expect(t.chat()?.sessions).toEqual([]);

    messages = [
      message("m1", "user", "Hi"),
      message("m2", "assistant", "Answered while away"),
    ];
    const changes = host.api.open(`${feed}`)!;
    changes.event({
      type: "conversation_changed",
      group_id: "grp_1",
      conversation_id: "cnv_1",
      kind: "user_chat",
      change: "message",
      seq: 2,
      version: "v.1",
    });
    await t.time.pass(100);
    expect(host.api.seen("GET", base).length).toBeGreaterThanOrEqual(2);

    // Offline now: opening it shows what the background read kept.
    host.api.on("GET", base, offline());
    await t.client.call("chat.retain", { ...t.lease, leaseId: crypto.randomUUID() });
    await t.time.pass(100);
    expect(texts(t.shown())).toEqual(["Hi", "Answered while away"]);
  });
});

describe("a window", () => {
  it("acts only as itself: another window's subscriber or surface is refused", async () => {
    const t = setup();
    t.api.on("GET", base, conversation([]));
    t.core.observeSession(signedIn());
    const otherWindow = { ...t.lease, subscriberId: "win_other:grp_1/cnv_1" };
    await expect(t.client.call("chat.retain", otherWindow)).rejects.toMatchObject({
      code: "forbidden",
    });
    const view = t.show();
    await t.time.pass(100);
    await expect(
      t.act("setDraft", { draft: "forged", surface: "win_other" })
    ).rejects.toMatchObject({ code: "forbidden" });
    await t.act("setDraft", { draft: "mine" });
    await t.time.pass(100);
    expect(view()?.state?.draft).toBe("mine");
  });

  it("keeps its conversation's one stream when it lets go and retains it again within the release delay", async () => {
    const t = setup();
    t.api.on("GET", base, conversation([message("m1", "user", "Hi")]));
    t.core.observeSession(signedIn());
    await t.client.call("chat.retain", t.lease);
    await t.time.pass(100);
    // A remount (React StrictMode's simulated cleanup) lets go and retains at once, under a new lease each time.
    let lease = t.lease;
    for (let round = 0; round < 2; round += 1) {
      await t.client.call("chat.release", lease);
      lease = { ...t.lease, leaseId: crypto.randomUUID() };
      await t.client.call("chat.retain", lease);
    }
    await t.time.pass(31_000, 1_000);
    expect(texts(t.shown())).toEqual(["Hi"]);
    expect(t.api.seen("GET", events)).toHaveLength(1);
    expect(t.api.open(events)).toBeDefined();
  });
});

describe("one session reported by several windows", () => {
  it("keeps each window's conversation when another tab's authority reports the same session", async () => {
    const t = setup();
    t.api.on("GET", base, conversation([message("m1", "user", "Kept")]));
    t.core.observeSession(signedIn());
    t.show();
    await t.time.pass(100);
    // Another tab's session authority: its own instance and generation, the same session.
    t.core.observeSession({
      ...signedIn("user-1", { generation: 7 }),
      authority: { authorityInstanceId: "authority-2", kind: "electron_main" },
    });
    await t.act("setDraft", { draft: "still mine" });
    await t.time.pass(100);
    expect(t.shown()?.draft).toBe("still mine");
    expect(texts(t.shown())).toEqual(["Kept"]);
  });
});

describe("a window's session", () => {
  const current = { audience: "https://api.comma.test", sessionId: "session-user-1" };

  it("refuses a window of a session the core is no longer on, and keeps its own", async () => {
    const t = setup();
    t.api.on("GET", base, conversation([message("m1", "user", "Mine")]));
    t.core.observeSession(signedIn());
    // A stale tab, still on the session before this one.
    await expect(
      t.client.call("chat.retain", {
        ...t.lease,
        session: { ...current, sessionId: "obsolete" },
      })
    ).rejects.toMatchObject({ code: "session_changed" });
    await t.time.pass(100);
    expect(t.chat()?.sessions).toEqual([]);
    t.show();
    await t.time.pass(100);
    expect(texts(t.shown())).toEqual(["Mine"]);
    expect(t.labeled()?.session).toEqual(current);
    // Signed out: the window's session is no longer the core's.
    t.core.observeSession(signedOut());
    await t.time.pass(100);
    expect(t.labeled()?.session).toBeNull();
    await expect(
      t.act("setDraft", { session: current, draft: "after sign-out" })
    ).rejects.toMatchObject({ code: "session_changed" });
  });

  it("shows and keeps nothing of a read that answers after the sign-out it started before", async () => {
    const host = new FakeHost();
    const t = setup(host);
    const release = t.api.hold("GET", base);
    t.api.on("GET", base, conversation([message("m1", "user", "Of the old account")]));
    t.core.observeSession(signedIn());
    await t.client.call("chat.retain", { ...t.lease, session: current });
    await t.time.pass(100);
    t.core.observeSession(signedOut());
    await t.time.pass(100);
    release();
    await t.time.pass(1_500);
    expect(t.chat()?.sessions).toEqual([]);
    // Signed in again: the device kept nothing of the read.
    t.api.on("GET", base, offline());
    t.core.observeSession(signedIn());
    await t.client.call("chat.retain", {
      ...t.lease,
      leaseId: crypto.randomUUID(),
      session: current,
    });
    await t.time.pass(100);
    expect(texts(t.shown()) ?? []).toEqual([]);
  });

  it("takes a window's release of its lease from the session before, on the same account", async () => {
    const t = setup();
    t.api.on("GET", base, conversation([message("m1", "user", "Mine")]));
    t.core.observeSession(signedIn());
    await t.client.call("chat.retain", { ...t.lease, session: current });
    await t.time.pass(1_500);
    expect(t.api.open(events)).toBeDefined();
    // Signed in again on the same account: a new session, the account (and its leases) kept.
    t.core.observeSession(
      signedIn("user-1", { sessionId: "session-user-1-again", generation: 2 })
    );
    await t.time.pass(100);
    // The window still names the session it retained under: letting go is taken, and the stream ends.
    await t.client.call("chat.release", { ...t.lease, session: current });
    await t.time.pass(31_000, 1_000);
    expect(t.chat()?.sessions).toEqual([]);
    expect(t.api.open(events)).toBeUndefined();
    // Acting is not: the old session cannot write.
    await expect(
      t.act("setDraft", { session: current, draft: "stale" })
    ).rejects.toMatchObject({ code: "session_changed" });
  });
});

describe("a sign-out", () => {
  it("withholds every conversation while it is under way or ended undecided, and shows them again once signed in", async () => {
    const t = setup();
    t.api.on("GET", base, conversation([message("m1", "user", "Private")]));
    t.core.observeSession(signedIn());
    const view = t.show();
    await t.time.pass(100);
    await t.act("setDraft", { draft: "unsent" });
    await t.time.pass(100);
    expect(texts(t.shown())).toEqual(["Private"]);
    expect(view()?.state?.draft).toBe("unsent");

    const header = {
      ...signedIn(),
      generation: 2,
      revision: 2,
      principal: null,
      session: null,
    };
    t.core.observeSession({ ...header, phase: "signing_out" });
    await t.time.pass(100);
    expect(t.chat()?.sessions).toEqual([]);
    expect(view()?.state).toBeNull();

    t.core.observeSession({
      ...header,
      phase: "indeterminate",
      problem: {
        code: "credential_mutation_uncertain",
        operation: "sign_out",
        recovery: "reconcile",
        retryable: false,
      },
    });
    await t.time.pass(100);
    expect(t.chat()?.sessions).toEqual([]);

    t.core.observeSession(signedIn("user-1", { generation: 3 }));
    await t.time.pass(100);
    expect(texts(t.shown())).toEqual(["Private"]);
  });
});

describe("a workspace image", () => {
  it("is read for the account and drawn again by the host before a window sees it", async () => {
    const host = new FakeHost();
    const source = Uint8Array.of(137, 80, 78, 71);
    const preview = Uint8Array.of(137, 80, 78, 71, 13, 10, 26, 10);
    const { Effect } = await import("effect");
    host.renderImagePreview = (input) =>
      Effect.sync(() => {
        expect(input).toEqual({ bytes: source, mediaType: "image/png" });
        return preview;
      });
    host.api.on("GET", "/v1/comma/groups/grp_1/files", {
      status: 200,
      headers: [["content-type", "image/png"]],
      body: source,
    });
    const t = setup(host);
    t.core.observeSession(signedIn());
    const path = `/uploads/${"p".repeat(22)}-photo.png`;
    const read = t.client.call("chat.readGroupImage", {
      groupId: "grp_1",
      path,
      source: "group-file",
    });
    await t.time.pass(100);
    expect(new Uint8Array((await read) as Uint8Array)).toEqual(preview);
    expect(t.api.seen("GET", "/v1/comma/groups/grp_1/files")[0]!.path).toContain(
      encodeURIComponent(path)
    );
  });
});

describe("a task's conversation", () => {
  it("keeps a refresh the server says changed nothing (304) live, without retrying or warning", async () => {
    const host = new FakeHost();
    let reads = 0;
    host.api.on("GET", base, (request) => {
      reads++;
      if (
        reads > 1 &&
        request.headers?.some(([k, v]) => k === "if-none-match" && v === '"t1"')
      )
        return { status: 304, headers: [["etag", '"t1"']], body: new Uint8Array() };
      return {
        status: 200,
        headers: [["etag", '"t1"']],
        body: new TextEncoder().encode(
          JSON.stringify(
            conversation([], { kind: "agent_task", title: "Unchanged task" })
          )
        ),
      };
    });
    const t = setup(host);
    t.core.observeSession(signedIn());
    t.show();
    await t.time.pass(100);
    expect(t.shown()?.conversation?.title).toBe("Unchanged task");
    await t.act("refresh");
    await t.time.pass(100);
    expect(reads).toBe(2);
    expect(t.shown()).toMatchObject({
      connection: "live",
      lastBackoffMs: 0,
      status: "ready",
    });
    expect(t.shown()?.syncWarning).toBeUndefined();
  });
});

describe("a run of a conversation, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const host = new FakeHost();
    host.api.on("GET", base, conversation([message("m1", "user", "Hi")]));
    host.api.on("POST", `${base}/messages`, (request) =>
      json(
        200,
        conversation([
          message("m1", "user", "Hi"),
          message(
            "m2",
            "user",
            "Again",
            (request.body as { client_request_id: string }).client_request_id
          ),
        ])
      )
    );
    const t = setup(host);
    t.core.observeSession(signedIn());
    await t.time.pass(100);
    t.show();
    await t.time.pass(100);
    await t.act("send", { text: "Again" });
    await t.time.pass(1_500);
    expect(texts(t.shown())).toEqual(["Hi", "Again"]);
    // A draft is written once it has rested (a timer on the Clock).
    await t.act("setDraft", { draft: "next" });
    await t.time.pass(1_500);

    const recorded = t.core.recorder!;
    const kinds = new Set(recorded.inputs.map((input) => input.kind));
    expect([...kinds]).toEqual(
      expect.arrayContaining(["tick", "response", "stream", "random", "ui"])
    );
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});

/** A group's chat as the server makes it. */
const groupChat = (group: string) => ({
  group_id: group,
  id: `cnv_public_${group}`,
  title: "聊天",
  status: "active",
  kind: "user_chat",
  messages: [],
});

/** The workspace's Task create as the server keeps it: one Task per request id, or a refusal. */
function makingTasks(api: ReturnType<typeof setup>["api"], refusal?: string) {
  const made = new Map<string, string>();
  api.on("POST", "/v1/comma/workspaces/wsp_1/tasks", (request) => {
    if (refusal) return json(409, { error: "refused", message: refusal });
    const id = (request.body as { client_request_id: string }).client_request_id;
    if (!made.has(id)) made.set(id, `cnv_task_${made.size + 1}`);
    return json(201, { task_id: made.get(id), group_id: "grp_1" });
  });
}

describe("the workspace's chat", () => {
  const workspaces = [
    { group_id: "grp_1", id: "wsp_1", name: "Main", status: "ready" },
    { group_id: "grp_2", id: "wsp_2", name: "Requested", status: "ready" },
  ];
  function resolving() {
    const t = setup();
    t.api.on("POST", "/v1/comma/me/bootstrap", {
      status: "ready",
      workspace: workspaces[0],
    });
    t.api.on("GET", "/v1/comma/workspaces", { data: workspaces });
    t.api.on("POST", "/v1/comma/groups/*", (request) =>
      json(200, groupChat(request.path.split("/")[4]!))
    );
    t.core.observeSession(signedIn());
    const resolve = async (params: object = {}) => {
      const answer = t.client.call("chat.resolveWorkspaceChat", params);
      await t.time.pass(100);
      return answer;
    };
    return { ...t, resolve };
  }

  it("starts a Task in the cloud with its model and answers the Task, posting nothing to the chat", async () => {
    const t = resolving();
    makingTasks(t.api);
    const started = t.client.call("chat.startTask", {
      workspaceId: "wsp_1",
      key: "task-key-1",
      model: { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
      text: " fix the build ",
    });
    await t.time.pass(500);
    // The Task, for the window to open at once.
    await expect(started).resolves.toEqual({
      groupId: "grp_1",
      conversationId: "cnv_task_1",
    });
    expect(
      t.api
        .seen("POST", "/v1/comma/workspaces/wsp_1/tasks")
        .map((request) => request.body)
    ).toEqual([
      {
        client_request_id: "task-key-1",
        text: "fix the build",
        model: { id: "claude-opus-5-5" },
      },
    ]);
    expect(
      t.api
        .seen("POST", "/v1/comma/groups/*")
        .filter((request) => request.path.endsWith("/messages"))
    ).toEqual([]);
  });

  it("makes a cloud Task once under its key, however often it is asked", async () => {
    const t = resolving();
    makingTasks(t.api);
    const start = () =>
      t.client.call("chat.startTask", {
        workspaceId: "wsp_1",
        key: "task-key-1",
        model: { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
        text: "fix the build",
      });
    const first = start();
    await t.time.pass(500);
    const again = start();
    await t.time.pass(500);
    // The server kept one Task: both answers name it.
    expect(await Promise.all([first, again])).toMatchObject([
      { conversationId: "cnv_task_1" },
      { conversationId: "cnv_task_1" },
    ]);
    expect(
      t.api
        .seen("POST", "/v1/comma/workspaces/wsp_1/tasks")
        .map((request) => request.body)
        .map((body) => (body as { client_request_id: string }).client_request_id)
    ).toEqual(["task-key-1", "task-key-1"]);
  });

  it("starts a cloud Task with the files uploaded for it, listed as the composer lists them", async () => {
    const t = resolving();
    makingTasks(t.api);
    const path = `/uploads/${"f".repeat(22)}-spec.pdf`;
    t.api.on("POST", "/v1/comma/groups/grp_1/files", {
      path,
      name: "spec.pdf",
      size: 3,
    });
    const uploaded = t.client.call("chat.uploadTaskFile", {
      workspaceId: "wsp_1",
      name: "spec.pdf",
      bytes: new Uint8Array([1, 2, 3]),
    });
    await t.time.pass(500);
    await expect(uploaded).resolves.toEqual({ name: "spec.pdf", path, size: 3 });

    // The files alone are its first message.
    const started = t.client.call("chat.startTask", {
      workspaceId: "wsp_1",
      key: "task-key-2",
      model: { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
      text: "",
      uploads: [{ name: "spec.pdf", path }],
    });
    await t.time.pass(500);
    await expect(started).resolves.toMatchObject({ conversationId: "cnv_task_1" });
    expect(
      t.api
        .seen("POST", "/v1/comma/workspaces/wsp_1/tasks")
        .map((request) => request.body)
    ).toEqual([
      {
        client_request_id: "task-key-2",
        text: `I've attached some files:\n\nAttached files in your workspace:\n- spec.pdf (workspace file: ${path})`,
        model: { id: "claude-opus-5-5" },
      },
    ]);
  });

  it("fails a cloud Task the server refused with why, in its words", async () => {
    const t = resolving();
    makingTasks(t.api, "no plan serves claude-opus-5-5");
    const refused = t.client
      .call("chat.startTask", {
        workspaceId: "wsp_1",
        key: "task-key-3",
        model: { id: "claude-opus-5-5", name: "Claude Opus 5.5" },
        text: "fix the build",
      })
      .then(
        () => undefined,
        (failure: unknown) => failure
      );
    await t.time.pass(500);
    expect(await refused).toMatchObject({
      code: "refused",
      message: "no plan serves claude-opus-5-5",
    });
  });

  it("turns away a file for a cloud Task the composer would not take, before it uploads", async () => {
    const t = resolving();
    const refused = t.client
      .call("chat.uploadTaskFile", {
        workspaceId: "wsp_1",
        name: "setup.exe",
        bytes: new Uint8Array([1, 2, 3]),
      })
      .then(
        () => undefined,
        (failure: unknown) => failure
      );
    await t.time.pass(500);
    expect(await refused).toMatchObject({
      code: "invalid_params",
      message: "This file type is not supported",
    });
    expect(t.api.seen("POST", "/v1/comma/groups/grp_1/files")).toHaveLength(0);
  });

  it("is resolved for a window that asks before the core heard of its sign-in", async () => {
    const t = setup();
    t.api.on("POST", "/v1/comma/me/bootstrap", {
      status: "ready",
      workspace: workspaces[0],
    });
    t.api.on("GET", "/v1/comma/workspaces", { data: workspaces });
    t.api.on("POST", "/v1/comma/groups/*", (request) =>
      json(200, groupChat(request.path.split("/")[4]!))
    );
    const answer = t.client.call("chat.resolveWorkspaceChat", {});
    await t.time.pass(500);
    t.core.observeSession(signedIn());
    await t.time.pass(500);
    await expect(answer).resolves.toMatchObject({
      status: "ready",
      workspaceId: "wsp_1",
    });
  });

  it("is resolved for a window that asks while the core is still opening the account", async () => {
    const host = new FakeHost();
    host.openDbMs = 500;
    const t = setup(host);
    t.api.on("POST", "/v1/comma/me/bootstrap", {
      status: "ready",
      workspace: workspaces[0],
    });
    t.api.on("GET", "/v1/comma/workspaces", { data: workspaces });
    t.api.on("POST", "/v1/comma/groups/*", (request) =>
      json(200, groupChat(request.path.split("/")[4]!))
    );
    t.core.observeSession(signedIn());
    const answer = t.client.call("chat.resolveWorkspaceChat", {});
    await t.time.pass(1_000);
    await expect(answer).resolves.toMatchObject({
      status: "ready",
      workspaceId: "wsp_1",
      conversationId: "cnv_public_grp_1",
    });
  });

  it("waits out a workspace being made, at most 10 seconds, before it asks the server again", async () => {
    const t = resolving();
    const ask = (afterProvisioning: number) =>
      t.client.call("chat.resolveWorkspaceChat", { afterProvisioning });
    const answer = ask(60);
    await t.time.pass(9_900, 100);
    expect(t.api.seen("POST", "/v1/comma/me/bootstrap")).toHaveLength(0);
    await t.time.pass(200);
    await expect(answer).resolves.toMatchObject({
      status: "ready",
      workspaceId: "wsp_1",
    });
    expect(t.api.seen("POST", "/v1/comma/me/bootstrap")).toHaveLength(1);
  });

  it("is the server's default workspace's, made by the server, whatever was selected on the device", async () => {
    const t = resolving();
    await expect(t.resolve()).resolves.toMatchObject({
      status: "ready",
      groupId: "grp_1",
      workspaceId: "wsp_1",
      conversationId: "cnv_public_grp_1",
    });
    expect(t.api.seen("POST", "/v1/comma/me/bootstrap")).toHaveLength(1);
    expect(t.api.seen("GET", "/v1/comma/workspaces")).toHaveLength(0);
    expect(t.api.seen("POST", "/v1/comma/groups/grp_1/assistant-chat")).toHaveLength(1);
  });

  it("is only the asked workspace's on an explicit route scope, and none when there is no such", async () => {
    const t = resolving();
    await expect(t.resolve({ workspaceId: "wsp_2" })).resolves.toMatchObject({
      status: "ready",
      groupId: "grp_2",
      workspaceId: "wsp_2",
      conversationId: "cnv_public_grp_2",
    });
    await expect(t.resolve({ workspaceId: "wsp_missing" })).resolves.toEqual({
      status: "hidden",
    });
    expect(t.api.seen("POST", "/v1/comma/me/bootstrap")).toHaveLength(0);
    expect(t.api.seen("POST", "/v1/comma/groups/grp_1/assistant-chat")).toHaveLength(0);
  });

  it("says a workspace is still being made, without entering a chat", async () => {
    const t = resolving();
    t.api.on("POST", "/v1/comma/me/bootstrap", {
      status: "provisioning",
      retry_after_seconds: 2,
      workspace: {
        group_id: "grp_reserved",
        id: "wsp_reserved",
        name: "Default",
        status: "provisioning",
      },
    });
    await expect(t.resolve()).resolves.toEqual({
      groupId: "grp_reserved",
      retryAfterSeconds: 2,
      status: "provisioning",
      workspaceId: "wsp_reserved",
    });
    expect(
      t.api.seen("POST", "/v1/comma/groups/grp_reserved/assistant-chat")
    ).toHaveLength(0);
  });

  it("is unauthorized on a 401 and hidden on a 403 or 404, with no chat made on the device", async () => {
    for (const [status, expected] of [
      [401, "unauthorized"],
      [403, "hidden"],
      [404, "hidden"],
    ] as const) {
      const t = resolving();
      t.api.on("POST", "/v1/comma/groups/*", json(status, { error: "request_failed" }));
      await expect(t.resolve()).resolves.toEqual({ status: expected });
    }
  });
});

const watchChat = (t: ReturnType<typeof setup>, workspace?: string) => {
  let value: WorkspaceChatValue | undefined;
  t.client.subscribe(
    { topic: "workspaceChat", ...(workspace ? { workspace } : {}) },
    (v) => (value = v as WorkspaceChatValue),
    () => undefined
  );
  return () => value;
};

describe("the account's chat with Comma", () => {
  const main = { group_id: "grp_1", id: "wsp_1", name: "Main", status: "ready" };
  const serve = (host: FakeHost) => {
    host.api.on("POST", "/v1/comma/me/bootstrap", { status: "ready", workspace: main });
    host.api.on("GET", "/v1/comma/workspaces", { data: [main] });
    host.api.on("POST", "/v1/comma/groups/*", (request) =>
      json(200, groupChat(request.path.split("/")[4]!))
    );
  };

  it("is resolved once signed in, kept on the device, and shown from it at once the next time, offline too", async () => {
    const host = new FakeHost();
    serve(host);
    const first = setup(host);
    const shown = watchChat(first);
    await first.time.pass(100);
    expect(shown()).toEqual({ status: "loading", chat: null, kept: false });
    first.core.observeSession(signedIn());
    await first.time.pass(100);
    expect(shown()).toEqual({
      status: "ready",
      chat: {
        workspaceId: "wsp_1",
        groupId: "grp_1",
        conversationId: "cnv_public_grp_1",
      },
      kept: false,
    });
    first.client.close();
    first.core.close();

    host.api.on("POST", "/v1/comma/me/bootstrap", offline());
    const again = setup(host);
    const kept = watchChat(again);
    again.core.observeSession(signedIn());
    await again.time.pass(100);
    // The chat found before stays shown when the server cannot confirm it, and a retry asks again.
    expect(kept()).toMatchObject({
      status: "error",
      chat: { conversationId: "cnv_public_grp_1" },
      kept: true,
    });
    serve(host);
    await again.client.call("workspaceChat.retry", {});
    await again.time.pass(100);
    expect(kept()).toMatchObject({ status: "ready", kept: false });
  });

  it("waits as long as the server says while the workspace is made, then opens its chat", async () => {
    const host = new FakeHost();
    serve(host);
    host.api.on("POST", "/v1/comma/me/bootstrap", {
      status: "provisioning",
      retry_after_seconds: 3,
      workspace: { ...main, status: "provisioning" },
    });
    const t = setup(host);
    const shown = watchChat(t);
    t.core.observeSession(signedIn());
    await t.time.pass(100);
    expect(shown()).toEqual({
      status: "provisioning",
      chat: null,
      kept: false,
      provisioning: { workspaceId: "wsp_1", groupId: "grp_1", retryAfterSeconds: 3 },
    });
    host.api.on("POST", "/v1/comma/me/bootstrap", { status: "ready", workspace: main });
    await t.time.pass(2_800);
    expect(t.api.seen("POST", "/v1/comma/me/bootstrap")).toHaveLength(1);
    await t.time.pass(300);
    expect(t.api.seen("POST", "/v1/comma/me/bootstrap")).toHaveLength(2);
    expect(shown()).toMatchObject({
      status: "ready",
      chat: { conversationId: "cnv_public_grp_1" },
    });
  });

  it("is asked again on a retry after the server refused it", async () => {
    const host = new FakeHost();
    serve(host);
    host.api.on("POST", "/v1/comma/groups/*", json(403, { error: "forbidden" }));
    const t = setup(host);
    const shown = watchChat(t);
    t.core.observeSession(signedIn());
    await t.time.pass(100);
    expect(shown()).toEqual({ status: "hidden", chat: null, kept: false });
    host.api.on("POST", "/v1/comma/groups/*", (request) =>
      json(200, groupChat(request.path.split("/")[4]!))
    );
    await t.client.call("workspaceChat.retry", {});
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      status: "ready",
      chat: { conversationId: "cnv_public_grp_1" },
    });
  });

  it("is the asked workspace's, hidden when the account has none such, and nothing of one account for the next", async () => {
    const host = new FakeHost();
    serve(host);
    const t = setup(host);
    const asked = watchChat(t, "wsp_missing");
    t.core.observeSession(signedIn());
    await t.time.pass(100);
    expect(asked()).toEqual({ status: "hidden", chat: null, kept: false });
    t.core.observeSession(signedOut());
    await t.time.pass(100);
    expect(asked()).toEqual({ status: "loading", chat: null, kept: false });
  });
});

describe("a draft the app suggests", () => {
  it("is added once the conversation is ready, keeping the draft there, and only once", async () => {
    const t = setup();
    t.api.on("GET", base, conversation([]));
    t.core.observeSession(signedIn());
    const release = t.api.hold("GET", base);
    const view = t.show();
    const shownDraft = () => view()?.state?.draft;
    await t.time.pass(10);
    let done = false;
    const prefill = (draft: string) => t.act("prefillDraft", { draft });
    const first = prefill("Connect another device").then(() => (done = true));
    await t.time.pass(1_000, 100);
    expect(done).toBe(false);
    release();
    await t.time.pass(100);
    await first;
    expect(shownDraft()).toBe("Connect another device");

    await t.act("setDraft", { draft: "Mine" });
    await t.time.pass(100);
    expect(shownDraft()).toBe("Mine");
    await prefill("Connect another device");
    await prefill("Connect another device");
    await t.time.pass(100);
    expect(shownDraft()).toBe("Mine\n\nConnect another device");
  });

  it("fails when the conversation is not ready within 10 seconds", async () => {
    const t = setup();
    t.api.on("GET", base, conversation([]));
    t.core.observeSession(signedIn());
    t.api.hold("GET", base);
    const view = t.show();
    const shownDraft = () => view()?.state?.draft;
    await t.time.pass(10);
    let failure: unknown;
    void t
      .act("prefillDraft", { draft: "Hi" })
      .catch((error: unknown) => (failure = error));
    await t.time.pass(9_900, 100);
    expect(failure).toBeUndefined();
    await t.time.pass(200, 100);
    expect(failure).toMatchObject({ message: "Chat did not become ready." });
    expect(shownDraft() ?? "").toBe("");
  });
});
