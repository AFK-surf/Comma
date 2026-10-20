import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type {
  StationChatsValue,
  StationDecisionsValue,
  StationJobsValue,
} from "../src/contract.ts";
import {
  FakeHost,
  FakeStations,
  fakeCredential,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
  TestTime,
} from "../src/testing/index.ts";

const WS = "wsp_1";
const ME = "user-1@example.test";
const HOUR = 3_600_000;

function setup() {
  // Noon in this device's time zone: a minute ago is today and 26 hours ago is yesterday wherever the test runs.
  const host = new FakeHost({ time: new TestTime(new Date(2026, 0, 1, 12).getTime()) });
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

const message = (seq: number, text: string, extra: Record<string, unknown> = {}) => ({
  seq,
  ts: `ts${seq}`,
  authorKind: "agent",
  author: "s_1",
  authorName: "Opus",
  text,
  createdAt: 1_000 * seq,
  ...extra,
});

const row = (id: string, thread: number, extra: Record<string, unknown> = {}) => ({
  id,
  session: id,
  thread,
  title: `Chat ${id}`,
  agents: [],
  last: { seq: 1, text: "Hello  <@U1> there", createdAt: 0 },
  unread: false,
  lastActiveAt: 0,
  creator: { id: "user-1", email: ME, name: "Ada" },
  ...extra,
});

const running = {
  key: "s_1",
  runtime: "claude",
  process: "running",
  pending: 0,
  lastTurn: null,
};
const done = {
  key: "s_2",
  runtime: "codex",
  process: "cold",
  pending: 0,
  lastTurn: { outcome: "done", ending: "all_done", endedAt: 5, detail: null },
};

describe("Station activity", () => {
  it("lists the chats by day from the station, and applies its events as they come", async () => {
    const t = setup();
    const now = t.time.now();
    t.a.chats = [
      row("s_1", 1, { agents: [running], lastActiveAt: now - 60_000 }),
      row("s_2", 2, { agents: [done], lastActiveAt: now - 26 * HOUR, unread: true }),
      row("s_3", 3, { agents: [done], lastActiveAt: now - 60_000 }),
    ];
    const chats = t.watch<StationChatsValue>({ topic: "stationChats", workspace: WS });
    await t.time.pass(100);
    expect(chats()).toMatchObject({ workspace: WS, loading: false });
    const days = chats()!.days;
    expect(days.map((d) => [d.daysAgo, d.items.map((i) => i.id)])).toEqual([
      [0, ["s_1", "s_3"]],
      [1, ["s_2"]],
    ]);
    expect(days[0]!.items[0]).toMatchObject({
      station: "st_a",
      stationName: "Studio",
      stationOnline: true,
      tone: "busy",
      settled: false,
      line: null,
      preview: "Hello there",
    });
    // Done and seen: faded, and says so.
    expect(days[0]!.items[1]).toMatchObject({
      settled: true,
      tone: null,
      line: { kind: "done" },
    });
    expect(days[1]!.items[0]).toMatchObject({ tone: "done", settled: false });

    // A row the station changed replaces the one shown.
    t.a.feed!.say(
      "chat",
      row("s_1", 1, { agents: [done], lastActiveAt: now, unread: true })
    );
    await t.time.pass(100);
    expect(chats()!.days[0]!.items.find((i) => i.id === "s_1")).toMatchObject({
      tone: "done",
    });
    t.a.feed!.say("chat-removed", { id: "s_3" });
    await t.time.pass(100);
    expect(chats()!.days[0]!.items.map((i) => i.id)).toEqual(["s_1"]);

    // The stream ends: a second later it opens again and reads the chats again (the station replays nothing).
    t.a.chats = [row("s_1", 1, { agents: [done], lastActiveAt: now })];
    t.a.feed!.end();
    await t.time.pass(1_100);
    expect(t.a.feeds).toHaveLength(2);
    expect(t.a.asked.filter((r) => r === "GET /chats")).toHaveLength(2);
    expect(chats()!.days[0]!.items[0]).toMatchObject({
      id: "s_1",
      tone: null,
      settled: true,
    });
  });

  it("lists the cards waiting for the viewer, the set-aside ones last, and answers them on the station", async () => {
    const t = setup();
    const card = (seq: number, extra: Record<string, unknown> = {}) => ({
      seq,
      message: message(seq, `Pick one for ${seq}?\nmore`),
      before: [
        message(seq - 1, "Context", { authorKind: "person", authorName: "Ada" }),
      ],
      card: {
        type: "options",
        options: [
          { label: "Ship", recommended: true },
          { label: "Wait" },
          { label: "Drop it", action: "close" },
        ],
      },
      ...extra,
    });
    t.a.chats = [
      row("s_1", 1, { card: card(4) }),
      row("s_2", 2, { card: card(7) }),
      // Someone else decides this one.
      row("s_3", 3, {
        card: { ...card(9), card: { type: "text", assignee: "lin@example.test" } },
      }),
      // An agent's question with no card is answered in words.
      row("s_4", 4, {
        need: { seq: 12, message: message(12, "Which branch?"), before: [] },
      }),
    ];
    const decisions = t.watch<StationDecisionsValue>({
      topic: "stationDecisions",
      workspace: WS,
    });
    await t.time.pass(100);
    expect(decisions()!.items.map((i) => [i.thread, i.seq])).toEqual([
      [1, 4],
      [2, 7],
      [4, 12],
    ]);
    expect(decisions()!.items[0]).toMatchObject({
      session: "s_1",
      title: "Chat s_1",
      deferred: false,
      message: { seq: 4, author: "Opus", text: "Pick one for 4?\nmore" },
      before: [{ seq: 3, author: "Ada", text: "Context" }],
      card: {
        type: "options",
        options: [
          { label: "Wait" },
          { label: "Drop it" },
          { label: "Ship", recommended: true },
        ],
        decider: { kind: "you" },
      },
    });
    expect(decisions()!.items[2]!.card).toEqual({
      type: "text",
      decider: { kind: "you" },
    });

    // Set aside: listed last.
    await t.client.call("stations.defer", {
      workspace: WS,
      station: "st_a",
      thread: 1,
      seq: 4,
    });
    await t.time.pass(100);
    expect(decisions()!.items.map((i) => [i.thread, i.deferred])).toEqual([
      [2, false],
      [4, false],
      [1, true],
    ]);

    // An option is sent as a message quoting the card, once (its key), and the card leaves the list.
    await t.client.call("stations.answer", {
      workspace: WS,
      station: "st_a",
      thread: 1,
      seq: 4,
      option: "Ship",
    });
    expect(t.a.writes[0]).toMatchObject({
      method: "POST",
      path: "/threads/1/messages",
      body: {
        text: "Ship",
        quotes: [
          {
            author: "Opus",
            text: "Pick one for 4?\nmore",
            comment: "",
            role: "agent",
            ts: "ts4",
          },
        ],
      },
      key: expect.stringMatching(/^[0-9a-f]{32}$/),
    });
    await t.time.pass(100);
    expect(decisions()!.items.map((i) => i.thread)).toEqual([2, 4]);

    // An option that closes the card closes it; a reply is words; a dismissal is the station's.
    await t.client.call("stations.answer", {
      workspace: WS,
      station: "st_a",
      thread: 2,
      seq: 7,
      option: "Drop it",
    });
    await t.client.call("stations.reply", {
      workspace: WS,
      station: "st_a",
      thread: 4,
      seq: 12,
      text: " main ",
    });
    expect(t.a.writes.slice(1)).toMatchObject([
      {
        method: "PUT",
        path: "/threads/2/closed-card",
        body: { n: 7, option: "Drop it" },
      },
      { method: "POST", path: "/threads/4/messages", body: { text: "main" } },
    ]);
    await t.client.call("stations.dismiss", {
      workspace: WS,
      station: "st_a",
      thread: 3,
      seq: 9,
    });
    expect(t.a.writes.at(-1)).toMatchObject({
      method: "PUT",
      path: "/threads/3/dismissed",
      body: { n: 9 },
    });
    await expect(
      t.client.call("stations.answer", {
        workspace: WS,
        station: "st_a",
        thread: 1,
        seq: 5,
        option: "Ship",
      })
    ).rejects.toMatchObject({ code: "already_answered" });
  });

  it("lists jobs that ran an hour or more, services first, their ages moving with the time", async () => {
    const t = setup();
    const now = t.time.now();
    t.a.jobs = [
      {
        id: "j1",
        name: "build",
        state: "running",
        port: null,
        watch: false,
        startedAt: now - 2 * HOUR,
        chat: { title: "Fix CI", archived: null },
      },
      {
        id: "j2",
        name: "web",
        state: "running",
        // Any port makes a job a service; which one does not matter here.
        port: 0,
        watch: false,
        startedAt: now - 30 * HOUR,
      },
      {
        id: "j3",
        name: "fresh",
        state: "running",
        port: null,
        watch: false,
        startedAt: now - 59 * 60_000,
      },
      {
        id: "j4",
        name: "watched",
        state: "running",
        port: null,
        watch: true,
        startedAt: now - 5 * HOUR,
      },
    ];
    const jobs = t.watch<StationJobsValue>({ topic: "stationJobs", workspace: WS });
    await t.time.pass(100);
    expect(jobs()!.groups).toEqual([
      {
        kind: "services",
        jobs: [
          {
            id: "j2",
            name: "web",
            state: "running",
            station: "st_a",
            stationName: null,
            chat: null,
            age: { unit: "days", n: 1 },
          },
        ],
      },
      {
        kind: "jobs",
        jobs: [
          {
            id: "j1",
            name: "build",
            state: "running",
            station: "st_a",
            stationName: null,
            chat: { title: "Fix CI", archived: false },
            age: { unit: "hours", n: 2 },
          },
        ],
      },
    ]);
    // A minute on, the fresh one has run an hour.
    await t.time.pass(61_000, 1_000);
    expect(jobs()!.groups[1]!.jobs.map((j) => j.id)).toEqual(["j1", "j3"]);

    // A job event reads the jobs again, once for a burst.
    t.a.jobs = [];
    t.a.feed!.say("job", { id: "j1" });
    t.a.feed!.say("job-removed", { id: "j2", session: "s" });
    await t.time.pass(1_100);
    expect(t.a.asked.filter((r) => r === "GET /jobs")).toHaveLength(2);
    expect(jobs()!.groups).toEqual([]);
  });

  it("starts a new chat on the station's first runtime", async () => {
    const t = setup();
    t.a.runtimes = ["codex", "claude"];
    t.watch({ topic: "stations", workspace: WS });
    await t.time.pass(100);
    expect(
      await t.client.call("stations.newChat", { workspace: WS, station: "st_a" })
    ).toEqual({
      session: "s_claude_100",
      thread: 100,
    });
    t.a.runtimes = [];
    await expect(
      t.client.call("stations.newChat", { workspace: WS, station: "st_a" })
    ).rejects.toMatchObject({ code: "no_runtime" });
  });
});
