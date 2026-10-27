// A Task a station hosts, as the pages that show a Task see it: its conversation view (`chatView`) is its station's
// chat in a Task conversation's shape, and what a page does to a Task (sends, files picked or given, a question card's
// answer, its name, labels and status) is done on the station.
import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { Effect } from "effect";
import { describe, expect, it } from "vitest";
import type { ChatQuestionPart } from "@comma/chat-contract";
import type {
  ArchivedTasksValue,
  ChatViewValue,
  DownloadValue,
  FileStreamValue,
  ProductInboxListResult,
  TaskPinsValue,
  TaskSummariesValue,
  TaskWorkersValue,
} from "../src/contract.ts";
import {
  attachTextsToMessage,
  composeMessageWithQuotes,
} from "../src/chat/model/protocol.ts";
import type { ChatPickAnswer } from "../src/host.ts";
import { FakeDesktop } from "../src/testing/fake-desktop.ts";
import {
  FakeDownloads,
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
const ID = "station:st_a:7";
const view = { workspace: WS, group: GROUP, conversation: ID, surface: "win_main" };
const card = {
  type: "options",
  options: [{ label: "Ship", recommended: true }, { label: "Wait" }],
};

function setup(
  options: { desktop?: FakeDesktop; list?: boolean; downloads?: boolean } = {}
) {
  const host = new FakeHost();
  // A phone's storage for downloads.
  if (options.downloads) host.downloads = new FakeDownloads(host.api);
  // The host draws an image's preview: here its bytes, marked.
  host.renderImagePreview = (image) => Effect.succeed(Uint8Array.of(9, ...image.bytes));
  if (options.desktop) host.desktop = options.desktop;
  const time = host.time!;
  const stations = new FakeStations(() => time.now());
  host.stationMesh = stations.ports;
  const seconds = () => Math.floor(time.now() / 1000);
  host.api
    .on("GET", "/v1/comma/stations/me", {
      user: { id: "user-1", email: "user-1@example.test", name: "Ada" },
      workspaces: [{ id: WS, name: "Main", role: "owner" }],
      relay_urls: [],
    })
    .on("GET", "/v1/comma/workspaces", {
      data: [{ id: WS, group_id: GROUP, name: "Main", status: "ready" }],
    })
    .on("GET", `/v1/comma/groups/${GROUP}/conversations`, json(200, { data: [] }))
    .onStream(`/v1/comma/groups/${GROUP}/conversations/events`)
    .on("GET", `/v1/comma/groups/${GROUP}/station-tasks`, {
      tasks: [
        {
          station_id: "st_a",
          device_id: null,
          thread: "7",
          task: "EMBER/7.0",
          title: "Fix CI",
          status: "in_progress",
          created_by: "user-1@example.test",
          created_at: 1_000,
          last_activity_at: 3_000,
          runtime: "claude",
          model: "opus",
          labels: [],
          rev: 1,
        },
      ],
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
  a.threads.set(7, {
    title: "Fix CI",
    entries: [
      a.entry(1, "person", "Fix the build"),
      a.entry(2, "agent", "**Done**"),
      a.entry(3, "agent", "Ship it?", { card }),
    ],
    read: 3,
  });
  a.chats = [
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
      card: {
        seq: 3,
        message: {
          seq: 3,
          ts: "ts3",
          authorKind: "agent",
          author: "s_1",
          authorName: "Opus",
          text: "Ship it?",
          createdAt: 3_000,
        },
        before: [],
        card,
      },
      last: null,
      unread: false,
      lastActiveAt: 0,
    },
  ];
  const core = startTestCore(host);
  core.observeSession(signedIn());
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
  // The Task list as the pages show it, with the station-hosted Tasks among the others.
  if (options.list !== false) watch({ topic: "tasks", workspace: WS, hosted: "1" });
  const chat = watch<ChatViewValue>({ topic: "chatView", ...view });
  return { host, core, a, time, client, watch, state: () => chat()!.state! };
}

describe("a Task a station hosts", () => {
  it("runs on another computer's station, which runs it from then on, and on its own again", async () => {
    const t = setup();
    t.host.api.on("GET", `/v1/comma/workspaces/${WS}/devices/dev_lab`, {
      device_id: "dev_lab",
      name: "Lab",
      status: "connected",
      allows_operations: true,
      station_id: "st_b",
      device_runtimes: [],
    });
    await t.time.pass(100);
    const row = t.a.chats[0] as Record<string, unknown>;
    const runs: unknown[] = [];
    t.a.on("POST", "/threads/7/run", (_request, body) => {
      runs.push(body);
      const station = (body as { station?: string }).station;
      // Its station says where it runs now, as its row.
      t.a.feed!.say(
        "chat",
        station
          ? {
              ...row,
              runsOn: { station, session: "s_b", runtime: "codex", model: null },
            }
          : row
      );
      return {
        status: 200,
        headers: [],
        body: new TextEncoder().encode(
          JSON.stringify({ id: 7, title: "Fix CI", last: 3, read: 3 })
        ),
      };
    });
    // Another computer: the station it runs, as Comma's server knows it, is asked to run it.
    await t.client.call("chatView.setTaskRun", {
      ...view,
      run: {
        runsOn: { kind: "station", deviceId: "dev_lab" },
        model: { kind: "runtime", provider: "codex" },
      },
    });
    await t.time.pass(100);
    expect(runs).toEqual([{ station: "st_b", runtime: "codex", model: null }]);
    expect(t.state().taskRun).toEqual({
      place: { kind: "station", deviceId: "st_b" },
      model: { kind: "runtime", provider: "codex" },
    });
    // At work there while what was said there is not answered; its agent here is not its run.
    expect(t.state().reply?.working).toBe(false);
    t.a.feed!.say("thread", {
      id: 7,
      entries: [t.a.entry(4, "person", "And the docs")],
    });
    await t.time.pass(100);
    expect(t.state().reply?.working).toBe(true);
    t.a.feed!.say("thread", {
      id: 7,
      entries: [
        t.a.entry(5, "agent", "Docs done.", { author: "st_b/s_b", ending: "all_done" }),
      ],
    });
    await t.time.pass(100);
    expect(t.state().reply?.working).toBe(false);
    // Its own computer again: it runs there with what was picked.
    await t.client.call("chatView.setTaskRun", {
      ...view,
      run: {
        runsOn: { kind: "station", deviceId: "st_a" },
        model: { kind: "runtime", provider: "claude", model: "opus" },
      },
    });
    await t.time.pass(100);
    expect(runs.at(-1)).toEqual({ runtime: "claude", model: "opus" });
    expect(t.state().taskRun?.place).toMatchObject({
      kind: "station",
      deviceId: "st_a",
    });
    // Never inside Comma.
    await expect(
      t.client.call("chatView.setTaskRun", {
        ...view,
        run: { runsOn: { kind: "salix" }, model: null },
      })
    ).rejects.toMatchObject({ code: "unsupported" });
  });

  it("shows in its conversation view as a Task's conversation", async () => {
    const t = setup();
    await t.time.pass(500);
    const state = t.state();
    expect(state.conversation).toMatchObject({
      id: ID,
      group_id: GROUP,
      kind: "agent_task",
      title: "Fix CI",
      status: "active",
    });
    expect(state.serverMessages.map((m) => [m.messageId, m.role, m.text])).toEqual([
      ["7:1", "user", "Fix the build"],
      ["7:2", "assistant", "**Done**"],
      ["7:3", "assistant", "Ship it?"],
    ]);
    expect(state.serverMessages[0]!.display).toMatchObject({ body: "Fix the build" });
    expect(state.serverMessages[1]!.markdown).toEqual([["p", [["b", ["Done"]]]]]);
    // A card with options to pick from is a question card.
    const question = state.serverMessages[2]!.parts!.find(
      (part): part is ChatQuestionPart => part.kind === "question"
    );
    expect(question).toMatchObject({
      messageId: "7:3",
      choices: [
        { id: "0", label: "Wait" },
        { id: "1", label: "Ship", recommended: true },
      ],
      allowOther: true,
      state: { status: "open" },
    });
    // Its agent at work is its Worker at work.
    expect(state.reply).toMatchObject({ working: true });
    expect(state.connection).toBe("live");
    // Where it runs is its run's place: its machine, with the model its station runs.
    expect(state.taskRun).toEqual({
      place: { kind: "station", deviceId: "st_a", name: "Studio" },
      model: { kind: "runtime", provider: "claude", name: "opus" },
    });
    // What its station cannot take, its page does not offer: a run inside Comma.
    expect(state.unsupported).toEqual(["comma"]);
    await expect(
      t.client.call("chatView.setTaskRun", {
        ...view,
        run: { runsOn: { kind: "salix" }, model: null },
      })
    ).rejects.toMatchObject({ code: "unsupported" });
    // Another runtime or model there: its session takes it from its next turn.
    const settings: unknown[] = [];
    t.a.on("POST", "/sessions/s_1/settings", (_request, body) => {
      settings.push(body);
      return {
        status: 200,
        headers: [],
        body: new TextEncoder().encode(JSON.stringify({ ok: true })),
      };
    });
    await t.client.call("chatView.setTaskRun", {
      ...view,
      run: {
        runsOn: { kind: "station", deviceId: "st_a" },
        model: { kind: "runtime", provider: "codex" },
      },
    });
    await t.time.pass(100);
    expect(t.state().taskRun?.model).toEqual({ kind: "runtime", provider: "codex" });
    await t.client.call("chatView.setTaskRun", {
      ...view,
      run: {
        runsOn: { kind: "station", deviceId: "st_a" },
        model: { kind: "runtime", provider: "codex", model: "gpt-5.5" },
      },
    });
    await t.client.call("chatView.setTaskRun", {
      ...view,
      run: {
        runsOn: { kind: "station", deviceId: "st_a" },
        model: { kind: "runtime", provider: "claude", model: "sonnet" },
      },
    });
    await t.time.pass(100);
    expect(settings).toEqual([
      { runtime: "codex", model: null },
      { model: "gpt-5.5" },
      { runtime: "claude", model: "sonnet" },
    ]);
    expect(t.state().taskRun?.model).toEqual({
      kind: "runtime",
      provider: "claude",
      name: "sonnet",
    });

    // Picked on its card, the option is the station's card's answer.
    await t.client.call("chatView.answerQuestion", {
      ...view,
      questionMessageId: "7:3",
      choiceIds: ["1"],
    });
    await t.time.pass(100);
    expect(
      t.a.writes.find((w) => w.path === "/threads/7/messages")?.body
    ).toMatchObject({
      text: "Ship",
    });
  });

  it("shows people's words as any Task's, and threads its messages as Salix threads a conversation's", async () => {
    const t = setup();
    t.a.threads.get(7)!.entries.push(
      // Written on a Task's page: a passage quoted, and a Routine item attached.
      t.a.entry(
        4,
        "person",
        attachTextsToMessage(composeMessageWithQuotes("Why?", ["Done"]), [
          { source: "Linear", text: "COMMA-1" },
        ])
      ),
      t.a.entry(5, "agent", "Because"),
      // Written on the station's own page: a reply to a whole message, one to a passage, and a mark on a web page.
      t.a.entry(6, "person", "Thanks", {
        quotes: [{ ts: "ts2", author: "Opus", text: "**Done**", role: "agent" }],
      }),
      t.a.entry(7, "person", "This part", {
        quotes: [{ ts: "ts5", author: "Opus", text: "Becau", role: "agent" }],
      }),
      t.a.entry(8, "person", "Fix this", {
        quotes: [{ author: "example.com", text: "Header", role: "page" }],
      }),
      // Its station says what it answers: the last message its agent was handed (6, while 7 and 8 waited).
      t.a.entry(9, "agent", "Glad it helps", { answers: 6 })
    );
    await t.time.pass(500);
    const shown = (n: number) => t.state().serverMessages.find((m) => m.seq === n)!;
    expect(shown(4).display).toEqual({
      body: "Why?",
      quotes: ["Done"],
      texts: [{ source: "Linear", text: "COMMA-1" }],
      files: [],
    });
    expect(shown(4).parts).toEqual([{ kind: "markdown", text: "Why?" }]);
    // An agent's post answers the last message it was given; a quote answers what it quotes, its words shown unless
    // they are the whole message.
    expect(
      [1, 2, 4, 5, 6, 7, 8, 9].map((n) => [
        shown(n).replyToMessageId,
        shown(n).threadRootMessageId,
        shown(n).display?.quotes,
      ])
    ).toEqual([
      [undefined, "7:1", []],
      ["7:1", "7:1", undefined],
      [undefined, "7:4", ["Done"]],
      ["7:4", "7:4", undefined],
      ["7:2", "7:1", []],
      ["7:5", "7:4", ["Becau"]],
      [undefined, "7:8", ["Header"]],
      ["7:6", "7:1", undefined],
    ]);

    // A reply from the page quotes what it answers, as the station's page does, and joins its thread.
    await t.client.call("chatView.send", {
      ...view,
      text: "And the docs?",
      clientRequestId: "req-0001",
      replyToMessageId: "7:2",
    });
    await t.time.pass(100);
    expect(t.a.writes.at(-1)?.body).toEqual({
      text: "And the docs?",
      quotes: [{ ts: "ts2", author: "Opus", text: "**Done**", role: "agent" }],
    });
    expect(t.state().serverMessages.at(-1)).toMatchObject({
      text: "And the docs?",
      replyToMessageId: "7:2",
      threadRootMessageId: "7:1",
      display: { quotes: [] },
    });

    // A card's option picked on its card: the answer is a Salix answer's, in the card's thread.
    await t.client.call("chatView.answerQuestion", {
      ...view,
      questionMessageId: "7:3",
      choiceIds: ["1"],
    });
    await t.time.pass(100);
    const answer = t.state().serverMessages.at(-1)!;
    expect(answer).toMatchObject({
      text: "Ship",
      replyToMessageId: "7:3",
      threadRootMessageId: "7:1",
      display: { body: "Ship", quotes: [] },
    });
    expect(answer.parts?.at(-1)).toEqual({
      kind: "question-answer",
      questionMessageId: "7:3",
      choiceIds: ["1"],
      skipped: false,
    });
  });

  it("takes pictures for a card's answer in its own words, apart from the draft, and sends them with it", async () => {
    const t = setup();
    await t.time.pass(500);
    await t.client.call("chatView.attach", {
      ...view,
      questionMessageId: "7:3",
      files: [{ name: "shot.png", size: 3, bytes: new Uint8Array([1, 2, 3]) }],
    });
    await t.time.pass(500);
    expect(t.state().questionAttachments?.["7:3"]).toMatchObject([
      {
        name: "shot.png",
        isImage: true,
        status: "uploaded",
        path: "/uploads/shot.png",
      },
    ]);
    expect(t.state().draftAttachments).toEqual([]);

    await t.client.call("chatView.answerQuestion", {
      ...view,
      questionMessageId: "7:3",
      choiceIds: [],
      other: "Like this",
    });
    await t.time.pass(100);
    expect(t.a.writes.at(-1)?.body).toEqual({
      text: "Like this",
      attachments: [{ name: "shot.png", path: "/uploads/shot.png", size: 3 }],
      quotes: [
        { author: "Opus", text: "Ship it?", comment: "", role: "agent", ts: "ts3" },
      ],
    });
    expect(t.state().questionAttachments).toBeUndefined();
    const answer = t.state().serverMessages.at(-1)!;
    expect(answer.attachments).toMatchObject([{ fileName: "shot.png" }]);
    expect(answer.parts?.at(-1)).toEqual({
      kind: "question-answer",
      questionMessageId: "7:3",
      choiceIds: [],
      other: "Like this",
      skipped: false,
    });
  });

  it("gives its agent the skills a message tags, as Salix does, and shows the message as written", async () => {
    const t = setup();
    const skills = `/v1/comma/workspaces/${WS}/skills`;
    t.host.api
      .on("GET", skills, {
        data: [
          {
            skill_id: "sk_1",
            name: "release-notes",
            location: "/skills/release-notes",
          },
        ],
      })
      .on("GET", `${skills}/sk_1`, {
        skill_id: "sk_1",
        name: "release-notes",
        location: "/skills/release-notes",
        content: "# Release notes\nWrite them short.",
        files: ["SKILL.md", "template.md", "logo.png"],
      })
      .on("GET", `${skills}/sk_1/file`, (request) =>
        request.path.endsWith("path=template.md")
          ? json(200, { path: "template.md", content: "## Changes" })
          : json(422, { error: "not_text" })
      );
    await t.time.pass(500);
    await t.client.call("chatView.send", {
      ...view,
      text: "/release-notes for 1.2",
      clientRequestId: "req-0001",
      skills: [{ location: "/skills/release-notes" }, { location: "/skills/gone" }],
    });
    await t.time.pass(100);
    expect((t.a.writes.at(-1)!.body as { text: string }).text).toBe(
      [
        "/release-notes for 1.2",
        "",
        "[[comma-protocol]]",
        "The user tagged these skills for this message. Activate each one now: read its SKILL.md, given below with its " +
          "files (the workspace that keeps it is not on this machine), and follow it while doing the work:",
        "- release-notes — /skills/release-notes",
        "",
        '<skill name="release-notes" location="/skills/release-notes">',
        "SKILL.md:",
        "# Release notes",
        "Write them short.",
        "",
        "template.md:",
        "## Changes",
        "",
        "logo.png: not included (not a text file)",
        "</skill>",
      ].join("\n")
    );
    // The page shows what was written, as any Task's; the message left the outbox.
    expect(t.state().pending).toEqual([]);
    expect(t.state().serverMessages.at(-1)).toMatchObject({
      text: "/release-notes for 1.2",
      clientRequestId: "req-0001",
      display: { body: "/release-notes for 1.2" },
    });
  });

  it("sends files given with a message alone, which go up to the station first", async () => {
    const t = setup();
    await t.time.pass(500);
    await t.client.call("chatView.send", {
      ...view,
      text: "This button",
      clientRequestId: "req-0001",
      files: [{ name: "shot.png", size: 3, bytes: new Uint8Array([1, 2, 3]) }],
    });
    await t.time.pass(100);
    expect(t.a.writes.find((w) => w.path === "/threads/7/messages")?.body).toEqual({
      text: "This button",
      attachments: [{ name: "shot.png", path: "/uploads/shot.png", size: 3 }],
    });
    expect(t.state().serverMessages.at(-1)).toMatchObject({
      text: "This button",
      attachments: [{ fileName: "shot.png", blockType: "image" }],
    });
  });

  it("sends what is written with the files that went up to the station, a part at a time", async () => {
    const t = setup();
    await t.time.pass(500);
    await t.client.call("chatView.attach", {
      ...view,
      files: [{ name: "a.txt", size: 5, bytes: new TextEncoder().encode("hello") }],
    });
    // A file the app holds goes up a part at a time: one of 5 MB is two parts.
    const big = new Uint8Array(5 * 1024 * 1024).fill(7);
    const ref = `lfi1_${"a".repeat(43)}`;
    t.host.localFiles.set(ref, big);
    await t.client.call("chatView.attachLocalFiles", {
      ...view,
      files: [
        {
          localFileRef: ref,
          mediaType: "application/zip",
          name: "b.zip",
          size: big.length,
        },
      ],
    });
    await t.time.pass(500);
    expect(t.state().draftAttachments.map((f) => [f.name, f.status, f.path])).toEqual([
      ["a.txt", "uploaded", "/uploads/a.txt"],
      ["b.zip", "uploaded", "/uploads/b.zip"],
    ]);
    expect(t.a.asked.filter((r) => r.startsWith("POST /uploads/parts")).length).toBe(3);

    await t.client.call("chatView.setDraft", { ...view, draft: "Also these" });
    await t.time.pass(100);
    expect(t.state().draft).toBe("Also these");
    await t.client.call("chatView.send", {
      ...view,
      text: "Also these",
      clientRequestId: "req-0001",
    });
    await t.time.pass(100);
    expect(t.a.writes.find((w) => w.path === "/threads/7/messages")?.body).toEqual({
      text: "Also these",
      attachments: [
        { name: "a.txt", path: "/uploads/a.txt", size: 5 },
        { name: "b.zip", path: "/uploads/b.zip", size: big.length },
      ],
    });
    expect(t.state().draft).toBe("");
    expect(t.state().draftAttachments).toEqual([]);
    // The message keeps the id it was sent under, from its send into the chat.
    expect(t.state().serverMessages.at(-1)).toMatchObject({
      clientRequestId: "req-0001",
      text: "Also these",
    });
  });

  it("reads its facts from its station's list while its page alone shows it", async () => {
    const t = setup({ list: false });
    await t.time.pass(500);
    expect(t.state().conversation).toMatchObject({ title: "Fix CI", status: "active" });
    expect(t.state().taskRun?.place).toEqual({
      kind: "station",
      deviceId: "st_a",
      name: "Studio",
    });
  });

  it("takes the files a desktop pick gives, a part at a time, and a send waits for the pick under way", async () => {
    const desktop = new FakeDesktop();
    const t = setup({ desktop });
    // Main's own client, bound to no window: it checks the intake as it registers each file.
    const main = new CoreClient(inProcessOpener(t.core, t.host), {
      schedule: () => undefined,
    });
    let answer!: (picked: ChatPickAnswer) => void;
    desktop.pick = () => new Promise((resolve) => (answer = resolve));
    await t.time.pass(500);
    const picking = t.client.call("chatView.pickAttachments", view);
    await t.time.pass(100);
    const [request] = desktop.picks;
    // The room a message to a station has: eight files.
    expect(request).toMatchObject({
      surfaceId: "win_main",
      workspaceId: WS,
      maxFiles: 8,
      maxUploadFiles: 8,
    });
    expect(
      await main.call("chat.intake.check", { intakeId: request!.intakeId })
    ).toMatchObject({ maxFiles: 8, maxUploadFiles: 8 });

    // Sent while the dialog is open, the message waits for what it picks.
    const sending = t.client.call("chatView.send", {
      ...view,
      text: "With the notes",
      clientRequestId: "req-0002",
    });
    await t.time.pass(100);
    expect(t.a.writes.some((w) => w.path === "/threads/7/messages")).toBe(false);
    const ref = `lfi1_${"b".repeat(43)}`;
    t.host.localFiles.set(ref, new TextEncoder().encode("notes"));
    answer({
      cancelled: false,
      errors: [],
      items: [
        { kind: "upload", name: "shot.png", size: 3, bytes: Uint8Array.of(1, 2, 3) },
        {
          kind: "local_file",
          file: {
            localFileRef: ref,
            mediaType: "text/plain",
            name: "notes.txt",
            size: 5,
          },
        },
      ],
    });
    await t.time.pass(500);
    await picking;
    await sending;
    expect(t.a.writes.find((w) => w.path === "/threads/7/messages")?.body).toEqual({
      text: "With the notes",
      attachments: [
        { name: "shot.png", path: "/uploads/shot.png", size: 3 },
        { name: "notes.txt", path: "/uploads/notes.txt", size: 5 },
      ],
    });
    expect(t.state().draftAttachments).toEqual([]);
  });

  it("keeps a failed file for each one a pick could not get, which picking again settles", async () => {
    const desktop = new FakeDesktop();
    const t = setup({ desktop });
    desktop.pick = () => ({
      cancelled: false,
      errors: [
        {
          errorClass: "local_file_too_large",
          isImage: false,
          message: "The file is too large.",
          name: "huge.bin",
          retryable: true,
        },
      ],
      items: [],
    });
    await t.time.pass(500);
    await t.client.call("chatView.pickAttachments", view);
    await t.time.pass(100);
    const [failed] = t.state().draftAttachments;
    expect(failed).toMatchObject({
      name: "huge.bin",
      status: "failed",
      error: "The file is too large.",
    });
    // Nothing goes while it stands.
    await expect(
      t.client.call("chatView.send", {
        ...view,
        text: "Here",
        clientRequestId: "req-0003",
      })
    ).rejects.toMatchObject({ code: "upload" });

    // Tried again, it is picked again: what that pick gives takes its place.
    desktop.pick = () => ({
      cancelled: false,
      errors: [],
      items: [
        { kind: "upload", name: "small.bin", size: 2, bytes: Uint8Array.of(1, 2) },
      ],
    });
    await t.client.call("chatView.retryAttachment", {
      ...view,
      attachmentId: failed!.id,
    });
    await t.time.pass(500);
    expect(desktop.picks).toHaveLength(2);
    expect(t.state().draftAttachments.map((f) => [f.name, f.status])).toEqual([
      ["small.bin", "uploaded"],
    ]);
  });

  it("opens its messages' files from its station, as any Task's from Comma's server", async () => {
    const t = setup();
    const thread = t.a.threads.get(7)!;
    thread.entries.push(
      t.a.entry(4, "agent", "The screenshot", {
        attachments: [
          { name: "shot.png", path: "/work/s_1/uploads/2026-10-25-shot.png", size: 3 },
        ],
      }),
      t.a.entry(5, "person", "My notes", {
        attachments: [
          {
            name: "notes.txt",
            path: "/work/s_1/uploads/2026-10-25-notes.txt",
            size: 5,
          },
        ],
      })
    );
    // A file sent to a session is kept in its uploads, by the name the station gave it.
    t.a.files.set("s_1/2026-10-25-shot.png", {
      type: "image/png",
      bytes: Uint8Array.of(1, 2, 3),
    });
    t.a.files.set("s_1/2026-10-25-notes.txt", {
      type: "text/plain",
      bytes: new TextEncoder().encode("notes"),
    });
    await t.time.pass(500);
    const shot = t.state().serverMessages.find((m) => m.messageId === "7:4");
    expect(shot?.attachments).toMatchObject([
      { attachmentIndex: 0, blockType: "image", fileName: "shot.png" },
    ]);
    const source = {
      source: "attachment",
      group: GROUP,
      conversation: ID,
      message: "7:4",
      index: 0,
    };
    expect(await t.client.call("files.read", source)).toEqual({
      bytes: Uint8Array.of(1, 2, 3),
      type: "image/png",
    });
    expect(
      await t.client.call("files.readRange", {
        source: { ...source, message: "7:5" },
        offset: 1,
        length: 3,
      })
    ).toEqual({ bytes: new TextEncoder().encode("ote"), type: "text/plain", size: 5 });
    await expect(
      t.client.call("files.read", { ...source, message: "7:5", index: 1 })
    ).rejects.toMatchObject({ code: "not_found" });
    // A span is read as its station gives a part.
    expect(t.a.asked).toContain(
      "GET /sessions/s_1/parts?name=2026-10-25-notes.txt&offset=1&length=3"
    );
    // It has no link a browser downloads it from: the web reads it a part at a time.
    await expect(t.client.call("files.link", source)).rejects.toMatchObject({
      code: "no_link",
    });
    // Its picture shows in the chat as the host draws it from the bytes its station gave.
    const drawn = t.client.call("chat.readGroupImage", {
      source: "attachment",
      groupId: GROUP,
      conversationId: ID,
      messageId: "7:4",
      index: 0,
      fileName: "shot.png",
    });
    await t.time.pass(100);
    expect(new Uint8Array((await drawn) as Uint8Array)).toEqual(
      Uint8Array.of(9, 1, 2, 3)
    );
    // Comma's server is never asked for them.
    expect(t.host.api.requests.some((r) => r.path.includes("/attachments/"))).toBe(
      false
    );
  });

  it("downloads its messages' files to a phone from its station, never from Comma's server", async () => {
    const t = setup({ downloads: true });
    t.a.threads.get(7)!.entries.push(
      t.a.entry(4, "agent", "The screenshot", {
        attachments: [
          { name: "shot.png", path: "/work/s_1/uploads/2026-10-25-shot.png", size: 3 },
        ],
      })
    );
    // Larger than a part (here 4 bytes): it comes a part at a time.
    t.a.partBytes = 4;
    const clip = Uint8Array.of(1, 2, 3, 4, 5, 6);
    t.a.files.set("s_1/2026-10-25-shot.png", { type: "image/png", bytes: clip });
    const source = {
      source: "attachment",
      group: GROUP,
      conversation: ID,
      message: "7:4",
      index: 0,
    };
    const shown = t.watch<DownloadValue>({
      topic: "download",
      source: JSON.stringify(source),
    });
    await t.time.pass(500);
    await t.client.call("downloads.start", { source, name: "shot.png" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      status: "ready",
      received: clip.length,
      total: clip.length,
    });
    const downloads = t.host.downloads as FakeDownloads;
    expect([...downloads.files.values()]).toEqual([clip]);
    expect(
      t.a.asked.filter((r) => r.startsWith("GET /sessions/s_1/parts"))
    ).toHaveLength(2);
    expect(downloads.requests).toEqual([]);
  });

  it("saves its messages' files into Downloads on the desktop a part at a time, at any size", async () => {
    const desktop = new FakeDesktop();
    const t = setup({ desktop });
    t.a.threads.get(7)!.entries.push(
      t.a.entry(4, "agent", "The recording", {
        attachments: [
          { name: "run.mp4", path: "/work/s_1/uploads/2026-10-25-run.mp4", size: 1 },
        ],
      })
    );
    // Its station gives it 4 bytes a part.
    t.a.partBytes = 4;
    const clip = Uint8Array.of(1, 2, 3, 4, 5, 6, 7, 8, 9);
    t.a.files.set("s_1/2026-10-25-run.mp4", { type: "video/mp4", bytes: clip });
    await t.time.pass(500);
    const source = {
      source: "attachment",
      group: GROUP,
      conversation: ID,
      message: "7:4",
      index: 0,
    };
    expect(await t.client.call("files.save", { source, name: "run.mp4" })).toEqual({
      downloadRef: "download:run.mp4",
      fileName: "run.mp4",
    });
    expect(desktop.saved).toEqual([{ fileName: "run.mp4", content: clip }]);
    expect(
      t.a.asked.filter((r) => r.startsWith("GET /sessions/s_1/parts"))
    ).toHaveLength(3);

    // Gone from its station meanwhile: nothing is saved.
    t.a.files.delete("s_1/2026-10-25-run.mp4");
    await expect(
      t.client.call("files.save", { source, name: "run.mp4" })
    ).rejects.toMatchObject({ code: "not_found" });
    expect(desktop.saved).toHaveLength(1);
  });

  it("plays its messages' videos on the desktop as Main asks the core for each range", async () => {
    const desktop = new FakeDesktop();
    const t = setup({ desktop });
    t.a.threads.get(7)!.entries.push(
      t.a.entry(4, "agent", "The recording", {
        attachments: [
          { name: "run.mp4", path: "/work/s_1/uploads/2026-10-25-run.mp4", size: 9 },
        ],
      })
    );
    t.a.files.set("s_1/2026-10-25-run.mp4", {
      type: "video/mp4",
      bytes: Uint8Array.of(1, 2, 3, 4, 5, 6, 7, 8, 9),
    });
    const source = JSON.stringify({
      source: "attachment",
      group: GROUP,
      conversation: ID,
      message: "7:4",
      index: 0,
    });
    const stream = t.watch<FileStreamValue>({
      topic: "fileStream",
      source,
      type: "video/mp4",
    });
    await t.time.pass(500);
    expect(stream()).toMatchObject({ status: "ready" });
    // Main reads it from the core: no API path, no signed URL.
    expect(desktop.streams.get(stream()!.url!)).toEqual({
      core: source,
      type: "video/mp4",
    });
    // The range Main asks for is read from its station as a part.
    expect(
      await t.client.call("files.readRange", {
        source: JSON.parse(source),
        offset: 3,
        length: 4,
      })
    ).toEqual({ bytes: Uint8Array.of(4, 5, 6, 7), type: "video/mp4", size: 9 });
  });

  it("reads its chat back to a message not loaded yet, as a reply's quote or an Activity step asks", async () => {
    const t = setup();
    const thread = t.a.threads.get(7)!;
    for (let n = 4; n <= 60; n++) thread.entries.push(t.a.entry(n, "agent", `m${n}`));
    await t.time.pass(500);
    expect(t.state().serverMessages.some((m) => m.messageId === "7:2")).toBe(false);
    const around = (await t.client.call("chat.messageContext", {
      groupId: GROUP,
      conversationId: ID,
      messageId: "7:2",
      conversationKind: "agent_task",
    })) as { messageId: string }[];
    expect(around.map((m) => m.messageId)).toContain("7:2");
    expect(t.host.api.requests.some((r) => r.path.includes("/context"))).toBe(false);
    // Its view shows what was read back too.
    await t.time.pass(100);
    expect(t.state().serverMessages[0]?.messageId).toBe("7:1");
    expect(t.state().history?.hasOlder).toBe(false);
  });

  it("takes another conversation's files: each read from where it is kept, then sent up", async () => {
    const t = setup();
    t.host.api.on(
      "GET",
      `/v1/comma/groups/${GROUP}/conversations/cnv_1/messages/m1/attachments/0`,
      {
        status: 200,
        headers: [["content-type", "text/plain"]],
        body: new TextEncoder().encode("hello"),
      }
    );
    await t.time.pass(500);
    await t.client.call("chatView.attachConversationFiles", {
      ...view,
      files: [
        { conversationId: "cnv_1", messageId: "m1", index: 0, name: "a.txt", size: 5 },
      ],
    });
    await t.time.pass(500);
    expect(t.state().draftAttachments.map((f) => [f.name, f.status, f.path])).toEqual([
      ["a.txt", "uploaded", "/uploads/a.txt"],
    ]);
  });

  it("is named, labelled, stopped and ended on its station, and its facts read from there", async () => {
    const t = setup();
    const summaries = t.watch<TaskSummariesValue>({
      topic: "taskSummaries",
      group: GROUP,
      ids: ID,
    });
    const workers = t.watch<TaskWorkersValue>({
      topic: "taskWorkers",
      group: GROUP,
      ids: ID,
    });
    await t.time.pass(500);
    expect(summaries()?.summaries).toMatchObject([
      { id: ID, title: "Fix CI", status: "active", status_bucket: "in_progress" },
    ]);
    // It has no Worker of Comma's.
    expect(workers()?.[ID]).toBeNull();
    // Comma's server is never asked of it.
    expect(
      t.host.api.requests.some(
        (r) => r.path.includes("station%3A") || r.path.includes(ID)
      )
    ).toBe(false);

    t.a.on("PUT", "/threads/7/title", () => ({
      status: 200,
      headers: [],
      body: new TextEncoder().encode("{}"),
    }));
    await t.client.call("tasks.rename", {
      group: GROUP,
      conversation: ID,
      title: "Fix CI again",
    });
    await t.client.call("taskLabels.assign", {
      group: GROUP,
      conversation: ID,
      labels: ["lbl_ci"],
    });
    await t.client.call("chatView.setTaskStatus", {
      ...view,
      status: "completed",
      expectedUpdatedAt: 3_000,
    });
    t.a.on("POST", "/sessions/s_1/stop", () => ({
      status: 200,
      headers: [],
      body: new TextEncoder().encode("{}"),
    }));
    await t.client.call("tasks.cancel", { group: GROUP, conversation: ID });
    expect(t.a.asked).toEqual(
      expect.arrayContaining([
        "PUT /threads/7/title",
        "PUT /threads/7/labels",
        "PUT /threads/7/status",
        "POST /sessions/s_1/stop",
      ])
    );
    await t.time.pass(100);
    expect(summaries()?.summaries[0]).toMatchObject({
      title: "Fix CI again",
      labels: ["lbl_ci"],
      status_bucket: "done",
    });
  });

  it("is pinned for the person on its station, among the Group's pins", async () => {
    const t = setup();
    t.host.api.on("GET", `/v1/comma/groups/${GROUP}/conversation-pins`, {
      data: [{ conversation: { id: "cnv_1", group_id: GROUP } }],
    });
    for (const method of ["PUT", "DELETE"])
      t.a.on(method, "/sessions/s_1/pin", () => ({
        status: 200,
        headers: [],
        body: new TextEncoder().encode("{}"),
      }));
    await t.time.pass(500);
    const pins = t.watch<TaskPinsValue>({ topic: "taskPins", group: GROUP });
    await t.time.pass(500);
    expect(pins()).toEqual({ status: "ready", ids: ["cnv_1"] });

    await t.client.call("tasks.pin", { group: GROUP, conversation: ID, pinned: true });
    expect(t.a.asked).toContain("PUT /sessions/s_1/pin");
    await t.time.pass(100);
    expect(pins()?.ids).toEqual(["cnv_1", ID]);
    await t.client.call("tasks.pin", { group: GROUP, conversation: ID, pinned: false });
    expect(t.a.asked).toContain("DELETE /sessions/s_1/pin");
    await t.time.pass(100);
    expect(pins()?.ids).toEqual(["cnv_1"]);
  });

  it("waits for its review once its chat asks its person nothing, and an accepted review marks it done there", async () => {
    const t = setup();
    // Its station says it needs its person; its chat asks nothing (no card waits).
    t.host.api.on("GET", `/v1/comma/groups/${GROUP}/station-tasks`, {
      tasks: [
        {
          station_id: "st_a",
          device_id: null,
          thread: "7",
          task: "EMBER/7.0",
          title: "Fix CI",
          status: "needs_review",
          created_by: "user-1@example.test",
          created_at: 1_000,
          last_activity_at: 3_000,
          runtime: "claude",
          model: "opus",
          labels: [],
          rev: 2,
        },
      ],
    });
    t.a.chats = t.a.chats.map((chat) => ({ ...(chat as object), card: null }));
    const list = t.watch<ProductInboxListResult>({
      topic: "tasks",
      workspace: WS,
      hosted: "1",
    });
    await t.time.pass(500);
    expect(t.state().conversation).toMatchObject({
      status: "ready_for_review",
      review_version: 3_000,
    });
    expect(list()?.items[0]).toMatchObject({
      status: "ready_for_review",
      reviewVersion: 3_000,
    });

    await t.client.call("chatView.acceptTaskReview", { ...view, reviewVersion: 3_000 });
    await t.time.pass(100);
    expect(t.a.writes.find((w) => w.path === "/threads/7/status")?.body).toEqual({
      status: "done",
    });
    expect(t.state().conversation?.status).toBe("completed");
  });

  it("is archived on its station: it leaves the Task list for the archived one at once, and comes back", async () => {
    const t = setup();
    const list = t.watch<ProductInboxListResult>({
      topic: "tasks",
      workspace: WS,
      hosted: "1",
    });
    const archived = t.watch<ArchivedTasksValue>({
      topic: "archivedTasks",
      workspace: WS,
    });
    await t.time.pass(500);
    const listed = () => list()?.items.map((item) => item.conversationId);
    expect(listed()).toEqual([ID]);
    expect(archived()?.tasks).toEqual([]);

    let answer!: () => void;
    t.a.on(
      "POST",
      "/threads/7/archive",
      () =>
        new Promise((resolve) => {
          answer = () =>
            resolve({ status: 200, headers: [], body: new TextEncoder().encode("{}") });
        })
    );
    const archiving = t.client.call("tasks.archive", {
      group: GROUP,
      conversation: ID,
      action: "archive",
      version: 3_000,
    });
    await t.time.pass(100);
    // Before its station answers.
    expect(listed()).toEqual([]);
    expect(archived()?.tasks).toMatchObject([{ id: ID, status: "archived" }]);
    answer();
    expect(await archiving).toBe(true);
    expect(t.a.asked).toContain("POST /threads/7/archive");
    // Its page says it is archived, as any archived Task's.
    await t.time.pass(100);
    expect(t.state().conversation?.status).toBe("archived");

    await t.client.call("tasks.archive", {
      group: GROUP,
      conversation: ID,
      action: "unarchive",
      version: 3_000,
    });
    await t.time.pass(100);
    expect(t.a.asked).toContain("DELETE /threads/7/archive");
    expect(listed()).toEqual([ID]);
    expect(archived()?.tasks).toEqual([]);

    // Refused by its station, it is where it was.
    t.a.on("POST", "/threads/7/archive", () => ({
      status: 500,
      headers: [],
      body: new TextEncoder().encode(JSON.stringify({ error: "disk full" })),
    }));
    await expect(
      t.client.call("tasks.archive", {
        group: GROUP,
        conversation: ID,
        action: "archive",
        version: 3_000,
      })
    ).rejects.toMatchObject({ message: "disk full" });
    await t.time.pass(100);
    expect(listed()).toEqual([ID]);
  });
});
