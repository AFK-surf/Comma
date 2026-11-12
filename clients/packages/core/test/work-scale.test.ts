// What a change costs must follow what changed, not how much the core holds (testing/work.ts): the same change made
// with twice the data costs the same work, counted, never timed.
import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import {
  FakeHost,
  FakeStations,
  fakeCredential,
  json,
  inProcessOpener,
  signedIn,
  startTestCore,
  TestTime,
  workOf,
  type WorkMeter,
} from "../src/testing/index.ts";

const base = "/v1/comma/groups/grp_1/conversations/cnv_1";
const events = `${base}/events`;
const feed = "/v1/comma/groups/grp_1/conversations/events";
const named = {
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_1",
  surface: "win_main",
};

const message = (i: number) => ({
  message_id: `m${i}`,
  kind: "message",
  actor_type: i % 2 === 0 ? "user" : "agent",
  content: [
    { type: "text", text: `Message ${i}, which says a little about what it is about.` },
  ],
  created_at: i,
});

/** Everything counted, as one comparable value. */
const counted = (work: WorkMeter) => ({
  topics: Object.fromEntries(
    [...work.topics].map(([name, t]) => [
      name,
      {
        ...t,
        unkeyed: [...t.unkeyed],
        remadeIn: Object.fromEntries(t.remadeIn),
        remadeLists: Object.fromEntries(t.remadeLists),
      },
    ])
  ),
  tables: Object.fromEntries(work.tables),
  shared: work.shared,
  looked: work.looked,
});

/** A window showing a conversation of `n` messages while a reply streams into it, 20 words, a frame each. */
async function streaming(n: number) {
  const host = new FakeHost();
  host.api.onStream(events).onStream(feed);
  const conversation = {
    group_id: "grp_1",
    id: "cnv_1",
    kind: "user_chat",
    title: "Thread",
    // Waiting on the agent: a reply streams in as a draft.
    status: "waiting",
    messages: Array.from({ length: n }, (_, i) => message(i)),
  };
  host.api.on("GET", base, conversation);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = (topic: Topic) =>
    client.subscribe(
      topic,
      (v) => values.set(topicKey(topic), v),
      () => undefined
    );
  core.observeSession(signedIn());
  watch({ topic: "chatView", ...named });
  await host.time!.pass(1_500);
  const stream = host.api.open(events)!;
  // The stream's own snapshot first: drafts count from it.
  stream.named("snapshot", {
    ...conversation,
    type: "snapshot",
    conversation_id: "cnv_1",
  });
  // What it keeps of the snapshot is written once, before the reply.
  await host.time!.pass(1_500);
  stream.named("message_draft_started", {
    type: "message_draft_started",
    conversation_id: "cnv_1",
    draft_id: "d1",
    response_key: "r1",
    source_message_ids: [`m${n - 2}`],
    status: "started",
    text: "",
  });
  await host.time!.pass(100);
  const work = await workOf(core).during(async () => {
    let text = "";
    for (let i = 0; i < 20; i++) {
      text += "word ";
      stream.named("message_draft_delta", {
        type: "message_draft_delta",
        conversation_id: "cnv_1",
        draft_id: "d1",
        response_key: "r1",
        source_message_ids: [`m${n - 2}`],
        status: "delta",
        revision: i,
        text,
      });
      await host.time!.pass(100);
    }
  });
  client.close();
  return counted(work);
}

/** What a conversation's stream says first: its messages (`after_seq`: only those after it). */
const snapshot = (messages: unknown[], extra: Record<string, unknown> = {}) => ({
  type: "snapshot",
  conversation_id: "cnv_1",
  group_id: "grp_1",
  status: "completed",
  messages,
  ...extra,
});

/** A window showing a conversation of `n` messages while 10 new ones come, each as its stream says it and resumes. */
async function arriving(n: number) {
  const host = new FakeHost();
  const seqd = (i: number) => ({ ...message(i), seq: i + 1 });
  const all = (from: number, to: number) =>
    Array.from({ length: to - from }, (_, i) => seqd(from + i));
  host.api.onStream(events).onStream(feed);
  host.api.on("GET", base, {
    group_id: "grp_1",
    id: "cnv_1",
    kind: "user_chat",
    title: "Thread",
    status: "completed",
    messages: all(0, n),
  });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  client.subscribe(
    { topic: "chatView", ...named },
    () => undefined,
    () => undefined
  );
  core.observeSession(signedIn());
  await host.time!.pass(1_500);
  host.api.open(events)!.named("snapshot", snapshot(all(0, n)));
  // What it keeps of the snapshot is written once, before the messages.
  await host.time!.pass(1_500);
  const work = await workOf(core).during(async () => {
    for (let i = n; i < n + 10; i++) {
      host.api.open(events)!.named("conversation_invalidated", {
        type: "conversation_invalidated",
      });
      await host.time!.pass(1_500);
      host.api
        .open(events)!
        .named("snapshot", snapshot(all(i, i + 1), { after_seq: i }));
      await host.time!.pass(100);
    }
  });
  client.close();
  return counted(work);
}

/** A window showing a conversation of `n` messages while a person types 20 characters into its draft. */
async function typing(n: number) {
  const host = new FakeHost();
  host.api.onStream(events).onStream(feed);
  host.api.on("GET", base, {
    group_id: "grp_1",
    id: "cnv_1",
    kind: "user_chat",
    title: "Thread",
    status: "completed",
    messages: Array.from({ length: n }, (_, i) => message(i)),
  });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  client.subscribe(
    { topic: "chatView", ...named },
    () => undefined,
    () => undefined
  );
  core.observeSession(signedIn());
  await host.time!.pass(1_500);
  const work = await workOf(core).during(async () => {
    let draft = "";
    for (let i = 0; i < 20; i++) {
      draft += "a";
      await client.call("chatView.setDraft", { ...named, draft });
      await host.time!.pass(100);
    }
  });
  client.close();
  return counted(work);
}

describe("the work a change costs", () => {
  it("types into the draft of a conversation of 200 messages at what it costs in one of 100", async () => {
    const small = await typing(100);
    expect(small.topics.chatView?.emissions).toBeGreaterThanOrEqual(20);
    expect(await typing(200)).toEqual(small);
  });

  it("takes in a new message of a conversation of 400 messages at what it costs in one of 200", async () => {
    const small = await arriving(200);
    expect(small.topics.chatView?.emissions).toBeGreaterThanOrEqual(10);
    expect(await arriving(400)).toEqual(small);
  });

  it("streams a reply into a conversation of 200 messages at what it costs in one of 100", async () => {
    const small = await streaming(100);
    expect(small.topics.chatView?.emissions).toBeGreaterThanOrEqual(20);
    expect(await streaming(200)).toEqual(small);
  });
});

/** A workspace of `n` Tasks whose list is shown while one of them changes 10 times (the stream says the list changed). */
async function taskChanging(n: number) {
  const host = new FakeHost();
  const list = "/v1/comma/groups/grp_a/conversations";
  const stream = "/v1/comma/groups/grp_a/conversations/events";
  host.api
    .on("GET", "/v1/comma/workspaces", {
      data: [{ group_id: "grp_a", id: "wsp_a", name: "Alpha", status: "ready" }],
    })
    .onStream(stream);
  let title = "0";
  // As the server pages it: the 50 changed last, and a cursor past them.
  host.api.on("GET", list, () =>
    json(200, {
      data: Array.from({ length: n }, (_, i) => ({
        group_id: "grp_a",
        id: `c${i}`,
        kind: "agent_task",
        status: "running",
        title: i === 0 ? `Changed ${title}` : `Task c${i}`,
        updated_at: 1_700_000_000 - i,
      })).slice(0, 50),
      has_more: n > 50,
      next_cursor: "c49",
    })
  );
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  client.subscribe(
    { topic: "tasks", workspace: "wsp_a" },
    () => undefined,
    () => undefined
  );
  core.observeSession(signedIn());
  await host.time!.pass(1_500);
  const listEvents = host.api.open(stream)!;
  const work = await workOf(core).during(async () => {
    for (let i = 1; i <= 10; i++) {
      title = String(i);
      listEvents.event({
        type: "conversation_list_invalidated",
        group_id: "grp_a",
        kind: "agent_task",
        version: `v${i}`,
      });
      await host.time!.pass(200);
    }
  });
  client.close();
  return counted(work);
}

describe("the work a Task's change costs", () => {
  it("is the same in a workspace of 400 Tasks as in one of 200", async () => {
    const small = await taskChanging(200);
    expect(small.topics.tasks?.emissions).toBeGreaterThanOrEqual(10);
    expect(await taskChanging(400)).toEqual(small);
  });
});

/** A station with `n` chats in the Stations list while one of them comes back to life, 10 events of it. */
async function stationChatting(n: number) {
  const ws = "wsp_1";
  const me = "user-1@example.test";
  const host = new FakeHost({ time: new TestTime(new Date(2026, 0, 1, 12).getTime()) });
  const time = host.time!;
  const stations = new FakeStations(() => time.now());
  host.stationMesh = stations.ports;
  const seconds = () => Math.floor(time.now() / 1000);
  host.api
    .on("GET", "/v1/comma/stations/me", {
      user: { id: "user-1", email: me, name: "Ada" },
      workspaces: [{ id: ws, name: "Main", role: "owner" }],
      relay_urls: [],
    })
    .on("GET", `/v1/comma/workspaces/${ws}/stations`, {
      stations: [{ id: "st_a", name: "Studio", version: "1", online: true }],
    })
    .onStream(`/v1/comma/workspaces/${ws}/stations/events`)
    .on("POST", `/v1/comma/workspaces/${ws}/station-credential`, (request) =>
      json(200, {
        credential: fakeCredential({
          ws,
          device: (request.body as { device: string }).device,
          role: "owner",
          exp: seconds() + 86_400,
        }),
        expires_at: seconds() + 86_400,
      })
    );
  const station = stations.station("st_a", ws);
  const row = (i: number, at: number) => ({
    id: `s_${i}`,
    session: `s_${i}`,
    thread: i,
    title: `Chat ${i}`,
    agents: [],
    last: { seq: 1, text: "Hello there", createdAt: 0 },
    unread: false,
    lastActiveAt: at,
    creator: { id: "user-1", email: me, name: "Ada" },
  });
  const now = time.now();
  station.chats = Array.from({ length: n }, (_, i) =>
    row(i + 1, now - (i + 1) * 60_000)
  );
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  client.subscribe(
    { topic: "stationChats", workspace: ws },
    () => undefined,
    () => undefined
  );
  core.observeSession(signedIn());
  // The rows it keeps are written once they rest, before the window counted here.
  await time.pass(3_000);
  const work = await workOf(core).during(async () => {
    for (let i = 1; i <= 10; i++) {
      station.feed!.say("chat", row(n, time.now()), `ab.${i}`);
      await time.pass(100);
    }
  });
  client.close();
  return counted(work);
}

describe("the work a station's chat event costs", () => {
  it("is the same with 400 chats on the station as with 200", async () => {
    const small = await stationChatting(200);
    expect(small.topics.stationChats?.emissions).toBeGreaterThanOrEqual(10);
    expect(await stationChatting(400)).toEqual(small);
  });
});
