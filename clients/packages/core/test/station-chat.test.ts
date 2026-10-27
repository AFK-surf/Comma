// A station's chat as the page of the Task it hosts shows it (`chatView`): its latest page, older pages as asked and
// new entries as the station says them, what is sent from here through its outbox, how each card stands, files put on
// the station, and its Activity read back to its brief. What any Task's page does with it is station-conversation's.
import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatQuestionPart } from "@comma/chat-contract";
import type { ChatViewValue } from "../src/contract.ts";
import {
  FakeHost,
  FakeStations,
  fakeCredential,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const WS = "wsp_1";
const GROUP = "grp_1";
const ME = "user-1@example.test";
const ID = "station:st_a:7";
const view = { workspace: WS, group: GROUP, conversation: ID, surface: "win_main" };

function setup() {
  const host = new FakeHost();
  const time = host.time!;
  const stations = new FakeStations(() => time.now());
  host.stationMesh = stations.ports;
  const seconds = () => Math.floor(time.now() / 1000);
  host.api
    .on("GET", "/v1/comma/stations/me", {
      user: { id: "user-1", email: ME, name: "Ada" },
      workspaces: [{ id: WS, name: "Main", role: "owner" }],
      relay_urls: [],
    })
    .on("GET", "/v1/comma/workspaces", {
      data: [{ id: WS, group_id: GROUP, name: "Main", status: "ready" }],
    })
    .on("GET", `/v1/comma/groups/${GROUP}/station-tasks`, { tasks: [] })
    .on("GET", `/v1/comma/workspaces/${WS}/stations`, {
      stations: [{ id: "st_a", name: "Studio", version: "1", online: true }],
    })
    .onStream(`/v1/comma/workspaces/${WS}/stations/events`)
    .on("POST", `/v1/comma/workspaces/${WS}/station-credential`, (request) =>
      json(200, {
        credential: fakeCredential({
          ws: WS,
          device: (request.body as { device: string }).device,
          role: "owner",
          exp: seconds() + 86_400,
        }),
        expires_at: seconds() + 86_400,
      })
    );
  const a = stations.station("st_a", WS);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const k = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return () => values.get(k) as T;
  };
  core.observeSession(signedIn());
  /** The Task's page, shown: what it shows now. */
  const open = () => {
    const chat = watch<ChatViewValue>({ topic: "chatView", ...view });
    return () => chat()!.state!;
  };
  return { host, core, client, time, stations, a, watch, open };
}

const card = {
  type: "options",
  options: [{ label: "Ship", recommended: true }, { label: "Wait" }],
};

describe("Station chat", () => {
  it("shows the latest page, older pages as asked, and new entries as the station says them", async () => {
    const t = setup();
    const entries = Array.from({ length: 60 }, (_, i) =>
      t.a.entry(i + 1, i % 2 === 0 ? "person" : "agent", `m${i + 1}`)
    );
    t.a.threads.set(7, { title: "Fix CI", entries, read: 60 });
    const state = t.open();
    await t.time.pass(100);
    expect(state().history?.hasOlder).toBe(true);
    expect(state().serverMessages.map((m) => m.seq)).toEqual(
      Array.from({ length: 50 }, (_, i) => i + 11)
    );
    expect(state().serverMessages[0]).toMatchObject({ role: "user", text: "m11" });
    expect(state().serverMessages[1]).toMatchObject({ role: "assistant", text: "m12" });

    await t.client.call("chatView.older", view);
    await t.time.pass(100);
    expect(state().serverMessages).toHaveLength(60);
    expect(state().history?.hasOlder).toBe(false);

    // A new entry the station says; then one after a gap, whose missed entry is read.
    t.a.feed!.say("thread", { id: 7, entries: [t.a.entry(61, "agent", "m61")] });
    await t.time.pass(100);
    expect(state().serverMessages.at(-1)).toMatchObject({ seq: 61, text: "m61" });
    t.a.threads
      .get(7)!
      .entries.push(t.a.entry(62, "agent", "m62"), t.a.entry(63, "agent", "m63"));
    t.a.feed!.say("thread", { id: 7, entries: [t.a.entry(63, "agent", "m63")] });
    await t.time.pass(100);
    expect(
      state()
        .serverMessages.slice(-3)
        .map((m) => m.seq)
    ).toEqual([61, 62, 63]);
    expect(t.a.asked).toContain("GET /threads/7/entries?after=61");
  });

  it("sends through the outbox: once the chat holds the message it leaves; a failed one is sent again as itself", async () => {
    const t = setup();
    t.a.threads.set(7, {
      title: "Fix CI",
      entries: [t.a.entry(1, "agent", "Hi")],
      read: 1,
    });
    const state = t.open();
    await t.time.pass(100);
    await t.client.call("chatView.send", {
      ...view,
      text: " Also the docs ",
      clientRequestId: "req-0001",
    });
    await t.time.pass(100);
    expect(t.a.writes[0]).toMatchObject({
      method: "POST",
      path: "/threads/7/messages",
      body: { text: "Also the docs" },
    });
    expect(state().pending).toEqual([]);
    // Named by the id it was sent under, in the chat after.
    expect(state().serverMessages.at(-1)).toMatchObject({
      role: "user",
      text: "Also the docs",
      clientRequestId: "req-0001",
    });

    // The station refuses it for now: it stays, failed; sent again under its id before the station took it, it is the
    // same message; sent again as a retry, it carries the same key.
    const keys: (string | undefined)[] = [];
    t.a.on("POST", "/threads/7/messages", (request) => {
      keys.push(request.headers.find(([n]) => n === "idempotency-key")?.[1]);
      return {
        status: 503,
        body: new TextEncoder().encode(JSON.stringify({ error: "station starting" })),
      };
    });
    const second = { ...view, text: "Second", clientRequestId: "req-0002" };
    await t.client.call("chatView.send", second);
    await t.time.pass(100);
    await t.client.call("chatView.send", second);
    await t.time.pass(100);
    expect(state().pending).toMatchObject([
      {
        clientRequestId: "req-0002",
        text: "Second",
        status: "failed",
        error: "station starting",
      },
    ]);
    t.a.on("POST", "/threads/7/messages", (request) => {
      keys.push(request.headers.find(([n]) => n === "idempotency-key")?.[1]);
      const entry = t.a.entry(1001, "person", "Second");
      t.a.threads.get(7)!.entries.push(entry);
      t.a.feed?.say("thread", { id: 7, entries: [entry] });
      return {
        status: 200,
        body: new TextEncoder().encode(JSON.stringify({ n: 1001 })),
      };
    });
    await t.client.call("chatView.retry", { ...view, clientRequestId: "req-0002" });
    await t.time.pass(1_100);
    expect(state().pending).toEqual([]);
    expect(state().serverMessages.at(-1)).toMatchObject({
      seq: 1001,
      text: "Second",
      clientRequestId: "req-0002",
    });
    expect(keys).toHaveLength(2);
    expect(keys[1]).toBe(keys[0]);
  });

  it("says how each card stands: waiting, chosen, replied or replaced", async () => {
    const t = setup();
    t.a.threads.set(7, {
      title: "Pick",
      entries: [
        t.a.entry(1, "agent", "First?", { card }),
        t.a.entry(2, "person", "Ship", { quotes: [{ ts: "ts1" }] }),
        t.a.entry(3, "agent", "Second?", { card }),
        t.a.entry(4, "person", "Maybe later", {
          author: "lin@example.test",
          authorName: "Lin",
        }),
        t.a.entry(5, "agent", "Third?", { card }),
        t.a.entry(6, "agent", "Fourth?", { card }),
      ],
      read: 6,
    });
    // Its station says the last card waits.
    t.a.chats = [
      {
        id: "s_1",
        session: "s_1",
        thread: 7,
        title: "Pick",
        agents: [],
        last: null,
        unread: false,
        lastActiveAt: 0,
        card: {
          seq: 6,
          message: {
            seq: 6,
            ts: "ts6",
            authorKind: "agent",
            author: "s_1",
            authorName: "Opus",
            text: "Fourth?",
            createdAt: 6,
          },
          before: [],
          card,
        },
      },
    ];
    const state = t.open();
    await t.time.pass(100);
    const questions = state().serverMessages.flatMap((m) =>
      (m.parts ?? []).filter(
        (part): part is ChatQuestionPart => part.kind === "question"
      )
    );
    expect(questions.map((q) => q.state)).toEqual([
      { status: "answered", choiceIds: ["1"] },
      { status: "replied" },
      { status: "replaced" },
      { status: "open" },
    ]);
  });

  it("puts a file on the station for a new Task's first message", async () => {
    const t = setup();
    t.watch({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(
      await t.client.call("stations.upload", {
        workspace: WS,
        station: "st_a",
        name: "notes v2.txt",
        bytes: btoa("abc"),
      })
    ).toEqual({ name: "notes v2.txt", path: "/uploads/notes v2.txt", size: 3 });
    expect(t.a.asked).toContain("POST /uploads?name=notes%20v2.txt");
  });

  it("shows a station-hosted Task's milestones as its Activity, read back to its brief, each step named as the page names its message", async () => {
    const t = setup();
    const milestones = (n: number, titles: string[]) =>
      t.a.entry(n, "agent", "", { kind: "milestone", text: null, milestones: titles });
    const entries = [
      t.a.entry(1, "person", "Send the invites"),
      milestones(2, ["Wrote the invite for Bob"]),
      t.a.entry(3, "agent", "Sent Bob's invite"),
      ...Array.from({ length: 52 }, (_, i) =>
        t.a.entry(i + 4, i % 2 === 0 ? "person" : "agent", `m${i + 4}`)
      ),
      t.a.entry(56, "agent", "Also invite Cy", {
        author: "salix/Router",
        authorName: "Router",
        request: true,
      }),
      milestones(57, ["Wrote the invite for Cy"]),
      t.a.entry(58, "agent", "Sent Cy's invite", { milestones: ["Sent the invites"] }),
      t.a.entry(59, "person", "thanks"),
      milestones(60, ["Archived the drafts"]),
    ];
    t.a.threads.set(7, { title: "Invites", entries, read: 60 });
    const state = t.open();
    await t.time.pass(100);
    const steps = () =>
      state().taskActivity?.groups.map((group) => [
        group.request?.kind,
        group.request?.text,
        group.entries.map((entry) => [entry.title, entry.messageId]),
      ]);

    // Milestones alone are shown only in the Activity.
    expect(
      state()
        .serverMessages.map((m) => m.seq)
        .slice(-4)
    ).toEqual([55, 56, 58, 59]);
    expect(state().history?.hasOlder).toBe(true);
    // From what the chat holds: the Router's request and a person's later message, each step opening the agent's
    // next post, or the last one shown while none has come; each named as the page names the message.
    expect(steps()).toEqual([
      [
        "follow_up",
        "Also invite Cy",
        [
          ["Wrote the invite for Cy", "7:58"],
          ["Sent the invites", "7:58"],
        ],
      ],
      ["follow_up", "thanks", [["Archived the drafts", "7:59"]]],
    ]);
    expect(state().taskActivity?.earlier).toBeUndefined();

    // The rest is read for the Activity alone: the brief and its steps; the chat holds what it held.
    await t.client.call("chatView.readTaskActivity", view);
    await t.time.pass(100);
    expect(t.a.asked).toContain("GET /threads/7/entries?before=11&limit=500");
    expect(steps()![0]).toEqual(["brief", "", [["Wrote the invite for Bob", "7:3"]]]);
    expect(steps()).toHaveLength(3);
    expect(state().taskActivity?.earlier).toBeUndefined();
    expect(state().serverMessages[0]!.seq).toBe(11);
  });
});
