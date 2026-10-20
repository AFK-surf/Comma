import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { StationChatValue } from "../src/contract.ts";
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
const ME = "user-1@example.test";

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
  const client = new CoreClient(inProcessOpener(core, host), {
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
  return { host, core, client, time, stations, a, watch };
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
    t.a.chats = [
      {
        id: "s_1",
        session: "s_1",
        thread: 7,
        title: "Fix CI",
        agents: [
          {
            key: "s_1",
            runtime: "claude",
            model: "opus",
            effort: "high",
            process: "running",
            pending: 0,
            lastTurn: null,
          },
        ],
        last: null,
        unread: false,
        lastActiveAt: 0,
      },
    ];
    const chat = t.watch<StationChatValue>({
      topic: "stationChat",
      workspace: WS,
      station: "st_a",
      thread: "7",
    });
    await t.time.pass(100);
    expect(chat()).toMatchObject({
      thread: 7,
      title: "Fix CI",
      link: { state: "online" },
      more: true,
      loading: false,
      agents: [
        {
          session: "s_1",
          name: "opus · high",
          state: { status: "running" },
          running: true,
        },
      ],
    });
    expect(chat()!.messages.map((m) => m.seq)).toEqual(
      Array.from({ length: 50 }, (_, i) => i + 11)
    );
    expect(chat()!.messages[0]).toMatchObject({
      kind: "person",
      mine: true,
      author: "Ada",
    });
    expect(chat()!.messages[1]).toMatchObject({
      kind: "agent",
      mine: false,
      author: "Opus",
    });

    await t.client.call("stations.older", {
      workspace: WS,
      station: "st_a",
      thread: 7,
    });
    await t.time.pass(100);
    expect(chat()!.messages).toHaveLength(60);
    expect(chat()!.more).toBe(false);

    // A new entry the station says; then one after a gap, whose missed entry is read.
    t.a.feed!.say("thread", { id: 7, entries: [t.a.entry(61, "agent", "m61")] });
    await t.time.pass(100);
    expect(chat()!.messages.at(-1)).toMatchObject({ seq: 61, text: "m61" });
    t.a.threads
      .get(7)!
      .entries.push(t.a.entry(62, "agent", "m62"), t.a.entry(63, "agent", "m63"));
    t.a.feed!.say("thread", { id: 7, entries: [t.a.entry(63, "agent", "m63")] });
    await t.time.pass(100);
    expect(
      chat()!
        .messages.slice(-3)
        .map((m) => m.seq)
    ).toEqual([61, 62, 63]);
    expect(t.a.asked).toContain("GET /threads/7/entries?after=61");

    // Seen to its end: marked read once for the newest.
    await t.client.call("stations.read", { workspace: WS, station: "st_a", thread: 7 });
    await t.client.call("stations.read", { workspace: WS, station: "st_a", thread: 7 });
    expect(t.a.writes.filter((w) => w.path === "/threads/7/read")).toEqual([
      { method: "PUT", path: "/threads/7/read", body: { n: 63 } },
    ]);
  });

  it("sends through the outbox: once the chat holds the message it leaves; a failed one is sent again as itself", async () => {
    const t = setup();
    t.a.threads.set(7, {
      title: "Fix CI",
      entries: [t.a.entry(1, "agent", "Hi")],
      read: 1,
    });
    const chat = t.watch<StationChatValue>({
      topic: "stationChat",
      workspace: WS,
      station: "st_a",
      thread: "7",
    });
    await t.time.pass(100);
    await t.client.call("stations.send", {
      workspace: WS,
      station: "st_a",
      thread: 7,
      text: " Also the docs ",
      attachments: [{ name: "a.png", path: "/uploads/a.png", size: 3 }],
    });
    await t.time.pass(100);
    expect(t.a.writes[0]).toMatchObject({
      method: "POST",
      path: "/threads/7/messages",
      body: {
        text: "Also the docs",
        attachments: [{ name: "a.png", path: "/uploads/a.png", size: 3 }],
      },
    });
    expect(chat()!.outbox).toEqual([]);
    expect(chat()!.messages.at(-1)).toMatchObject({
      text: "Also the docs",
      mine: true,
    });

    // The station refuses it for now: it stays, failed; sent again, it carries the same key.
    const keys: (string | undefined)[] = [];
    t.a.on("POST", "/threads/7/messages", (request) => {
      keys.push(request.headers.find(([n]) => n === "idempotency-key")?.[1]);
      return {
        status: 503,
        body: new TextEncoder().encode(JSON.stringify({ error: "station starting" })),
      };
    });
    await t.client.call("stations.send", {
      workspace: WS,
      station: "st_a",
      thread: 7,
      text: "Second",
    });
    await t.time.pass(100);
    expect(chat()!.outbox).toMatchObject([
      {
        id: expect.stringMatching(/^out-/),
        text: "Second",
        state: "failed",
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
    const id = chat()!.outbox[0]!.id;
    await t.client.call("stations.retry", {
      workspace: WS,
      station: "st_a",
      thread: 7,
      id,
    });
    await t.time.pass(1_100);
    expect(chat()!.outbox).toEqual([]);
    expect(chat()!.messages.at(-1)).toMatchObject({ seq: 1001, text: "Second" });
    expect(keys).toHaveLength(2);
    expect(keys[1]).toBe(keys[0]);
  });

  it("makes the chat of a session that has none when the first message goes", async () => {
    const t = setup();
    t.a.chats = [
      {
        id: "s_9",
        session: "s_9",
        thread: null,
        title: null,
        agents: [{ key: "s_9", runtime: "codex", pending: 0, lastTurn: null }],
        last: null,
        unread: false,
        lastActiveAt: 0,
      },
    ];
    const chat = t.watch<StationChatValue>({
      topic: "stationChat",
      workspace: WS,
      station: "st_a",
      session: "s_9",
    });
    await t.time.pass(100);
    expect(chat()).toMatchObject({
      thread: null,
      messages: [],
      agents: [{ session: "s_9" }],
    });
    await t.client.call("stations.send", {
      workspace: WS,
      station: "st_a",
      session: "s_9",
      text: "Go",
    });
    await t.time.pass(100);
    expect(t.a.made).toEqual(["s_9"]);
    expect(chat()).toMatchObject({ thread: 100 });
    expect(chat()!.messages.map((m) => m.text)).toEqual(["Go"]);
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
          dismissed: true,
        },
      },
    ];
    const chat = t.watch<StationChatValue>({
      topic: "stationChat",
      workspace: WS,
      station: "st_a",
      thread: "7",
    });
    t.watch({ topic: "stationChats", workspace: WS });
    await t.time.pass(100);
    const states = chat()!
      .messages.filter((m) => m.card)
      .map((m) => m.cardState);
    expect(states).toEqual([
      { resolved: true, outcome: { kind: "chose", by: null, label: "Ship" } },
      { resolved: true, outcome: { kind: "replied", by: "Lin" } },
      { resolved: true, outcome: { kind: "replaced" } },
      { resolved: false, dismissed: true },
    ]);
    expect(chat()!.messages[0]!.card).toMatchObject({
      options: [{ label: "Wait" }, { label: "Ship", recommended: true }],
    });
  });

  it("puts a file on the station and stops an agent", async () => {
    const t = setup();
    t.a.on("POST", "/sessions/s_1/stop", () => ({
      status: 200,
      body: new TextEncoder().encode(JSON.stringify({ ok: true })),
    }));
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
    await t.client.call("stations.stopAgent", {
      workspace: WS,
      station: "st_a",
      session: "s_1",
    });
    expect(t.a.asked).toContain("POST /sessions/s_1/stop");
  });
});
