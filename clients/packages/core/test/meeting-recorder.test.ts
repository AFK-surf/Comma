// Electron's meeting recorder in the core (meeting/recorder.ts, tasks.ts, outputs.ts): which meeting is offered, when
// capture starts and stops, and the meeting's Task, on a TestClock, against Main's meeting parts as the core sees them
// (testing/meeting.ts) and a Task API that follows the server's meeting plan.
import { CoreClient } from "@comma/core-kernel/client";
import { utf8 } from "@comma/core-kernel";
import { describe, expect, it } from "vitest";
import type { MeetingRecorderValue } from "../src/contract.ts";
import type { MeetingPresenceMeeting } from "../src/host.ts";
import { MEETING_JOURNAL_KEY } from "../src/meeting/tasks.ts";
import {
  FakeHost,
  FakeMeetingMain,
  inProcessOpener,
  json,
  meetingFixture,
  offline,
  signedIn,
  signedOut,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const { meeting, recording, capture } = meetingFixture;
const groups = "/v1/comma/groups/group/meeting-tasks";

/** When a meeting entered at the TestClock's start started, as `locale` words it on this device. */
const started = (locale: string) =>
  new Intl.DateTimeFormat(locale, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(Date.UTC(2026, 0, 1));

type Receipt = {
  group_id: string;
  task_id: string;
  status: string;
  meeting: {
    occurrence_id: string;
    name: string;
    archive_date: string;
    started_at: number;
    phase: string;
    version: number;
  };
};

/** The Task API as the server plans meetings: one Task per occurrence, newer versions only, closed Tasks refuse. */
function taskServer(host: FakeHost) {
  const tasks = new Map<string, Receipt>();
  const commands: string[] = [];
  host.api.on("POST", "/v1/comma/me/bootstrap", {
    status: "ready",
    workspace: { id: "workspace", group_id: "group", name: "Main" },
  });
  host.api.on("POST", groups, (request) => {
    const entry = request.body as Receipt["meeting"];
    let task = tasks.get(entry.occurrence_id);
    if (!task) {
      task = {
        group_id: "group",
        task_id: `task-${tasks.size}`,
        status: "active",
        meeting: { ...entry, phase: "awaiting_recording", version: 0 },
      };
      tasks.set(entry.occurrence_id, task);
      commands.push(`enter ${task.task_id}`);
    }
    return json(200, task);
  });
  host.api.on("POST", `${groups}/*`, (request) => {
    const id = decodeURIComponent(request.path.split("/").at(-1)!);
    const command = request.body as {
      action: string;
      version: number;
      smart_summary?: boolean;
    };
    const task = tasks.get(id);
    if (!task) return json(404, { error: "not_found" });
    const received = `${task.task_id} ${command.action} v${command.version}`;
    if (command.version <= task.meeting.version) {
      commands.push(`${received} unchanged`);
      return json(200, task);
    }
    const closed =
      task.status === "archived" ||
      !["awaiting_recording", "recording", "paused"].includes(task.meeting.phase);
    if (closed) {
      commands.push(`${received} rejected`);
      return json(409, { error: "meeting_closed" });
    }
    commands.push(received);
    const phase =
      command.action === "finalize"
        ? command.smart_summary
          ? "processing"
          : "saved"
        : (({ dismiss: "dismissed", discard: "discarded" } as Record<string, string>)[
            command.action
          ] ?? command.action);
    const next = {
      ...task,
      status: phase === "dismissed" ? "archived" : task.status,
      meeting: { ...task.meeting, phase, version: command.version },
    };
    tasks.set(id, next);
    return json(200, next);
  });
  return { tasks, commands };
}

function setup(
  options: {
    initial?: MeetingPresenceMeeting[];
    auto?: boolean;
    host?: FakeHost;
    main?: FakeMeetingMain;
  } = {}
) {
  const host = options.host ?? new FakeHost();
  const main = options.main ?? new FakeMeetingMain();
  host.meeting = main;
  const server = taskServer(host);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  let value: MeetingRecorderValue | undefined;
  client.subscribe(
    { topic: "meetingRecorder" },
    (v) => (value = v as MeetingRecorderValue),
    () => undefined
  );
  core.observeSession(signedIn("alice"));
  const preferences = {
    meetingStartRecording: options.auto ? ("auto" as const) : ("reminder" as const),
    meetingHideRecorder: false,
    meetingSmartSummary: true,
  };
  main.emit({ kind: "preferences", preferences });
  main.emit({ kind: "clientVisible", visible: true });
  main.emit({ kind: "capture", state: { ...capture, status: "idle" } });
  let revision = 1;
  const present = (meetings: MeetingPresenceMeeting[]) =>
    main.emit({
      kind: "presence",
      state: { available: true, revision: ++revision, meetings },
    });
  present(options.initial ?? [meeting]);
  const time = host.time!;
  const state = () => value!;
  const act = async (
    action: "start" | "dismiss" | "pause" | "resume" | "stop" | "discard",
    key = meeting.key
  ) => {
    const done = client.call("meetingRecorder.action", {
      action,
      meetingKey: key,
      generation: state().generation,
    });
    await time.pass(100);
    return done;
  };
  const journal = () =>
    JSON.parse(new TextDecoder().decode(host.storage.get(MEETING_JOURNAL_KEY)!)) as {
      entry: { occurrence_id: string };
      version: number;
      final?: { recordingId: string };
      receipt?: Receipt;
    }[];
  return {
    host,
    main,
    core,
    client,
    server,
    time,
    state,
    act,
    present,
    preferences,
    journal,
    async settle(ms = 100) {
      await time.pass(ms);
    },
    setPreferences(patch: Partial<typeof preferences>) {
      Object.assign(preferences, patch);
      main.emit({ kind: "preferences", preferences: { ...preferences } });
    },
  };
}

describe("the meeting recorder", () => {
  it("prompts for a meeting present at launch and enters its Task, never recording until Start", async () => {
    const t = setup();
    await t.settle();
    expect(t.state()).toMatchObject({
      phase: "detected",
      meeting: { key: meeting.key },
      taskSync: {
        status: "synced",
        task: { groupId: "group", taskId: "task-0", workspaceId: "workspace" },
      },
    });
    expect(t.main.seen("start")).toEqual([]);
    await t.act("start");
    expect(t.main.seen("start")).toEqual([
      expect.objectContaining({
        meeting: expect.objectContaining({ key: meeting.key }),
      }),
    ]);
    expect(t.state().phase).toBe("recording");
    expect(t.server.commands).toEqual(["enter task-0", "task-0 recording v1"]);
  });

  it("names a meeting's Task by its platform and start, never by the browser it runs in", async () => {
    const titles = async (entered: MeetingPresenceMeeting, locale = "en") => {
      const t = setup({ initial: [] });
      await t.client.call("chat.locale", { locale });
      t.present([entered]);
      await t.settle();
      return [...t.server.tasks.values()].map((task) => task.meeting.name);
    };
    const chrome = { ...meeting, name: "Google Chrome", kind: "browser" as const };
    expect(await titles(chrome, "zh-CN")).toEqual([`会议 · ${started("zh-CN")}`]);
    expect(await titles(meeting)).toEqual([`Zoom meeting · ${started("en")}`]);
    // Comma's own browser knows its page's platform.
    const page = { ...chrome, name: "Google Meet", browserTabId: "meet" };
    expect(await titles(page)).toEqual([`Google Meet meeting · ${started("en")}`]);
  });

  it("starts a meeting joined after launch only in Auto, once, and not during another capture", async () => {
    const t = setup({ initial: [] });
    await t.settle();
    t.present([meeting]);
    await t.settle();
    expect(t.state().phase).toBe("detected");
    expect(t.main.seen("start")).toHaveLength(0);

    const auto = setup({ initial: [], auto: true });
    auto.present([meeting]);
    await auto.settle();
    auto.present([meeting]);
    await auto.settle();
    expect(auto.main.seen("start")).toHaveLength(1);
    expect(auto.state().phase).toBe("recording");

    const manual = setup({ initial: [], auto: true });
    manual.main.emit({ kind: "capture", state: { ...capture, status: "recording" } });
    manual.present([meeting]);
    await manual.settle();
    expect(manual.main.seen("start")).toHaveLength(0);
  });

  it("keeps the recording when another tab joins and offers the queued meeting after Stop", async () => {
    const first = { ...meeting, key: "tab-a:room", kind: "browser" as const };
    const second = { ...first, key: "tab-b:room" };
    const t = setup({ initial: [first] });
    await t.settle();
    await t.act("start", first.key);
    t.present([first, second]);
    await t.settle();
    expect(t.state().meeting?.key).toBe(first.key);
    await t.act("stop", first.key);
    expect(t.state()).toMatchObject({
      phase: "detected",
      meeting: { key: second.key },
    });
    expect(t.main.seen("start")).toHaveLength(1);
  });

  it("serializes Stop from two windows and shows one receipt once Drive saved it, then its Task", async () => {
    const t = setup();
    await t.settle();
    await t.act("start");
    const release = t.main.hold("stop");
    const first = t.act("stop");
    await t.act("stop");
    expect(t.state()).toMatchObject({ phase: "saving", saved: null });
    release();
    await first;
    await t.settle();
    expect(t.main.seen("stop")).toHaveLength(1);
    expect(t.state()).toMatchObject({
      phase: "idle",
      saved: {
        recording,
        summary: "queued",
        task: { groupId: "group", taskId: "task-0", workspaceId: "workspace" },
      },
    });
    expect(t.server.commands.at(-1)).toBe("task-0 finalize v2");
    const finalize = t.host.api.seen("POST", `${groups}/*`).at(-1)!.body;
    expect(finalize).toMatchObject({
      action: "finalize",
      smart_summary: true,
      file: { localFileRef: `lfi1_${"a".repeat(43)}` },
      recording: { driveFile: recording.driveFile },
    });
    // The snapshot and registration happen before the finalize, for the same session.
    expect(t.main.calls.map((c) => c.op)).toEqual(
      expect.arrayContaining(["snapshot", "register", "markBound"])
    );
    await t.client.call("meetingRecorder.acknowledgeSaved", { receiptId: 99 });
    expect(t.state().saved).not.toBeNull();
    const ack = t.client.call("meetingRecorder.acknowledgeSaved", {
      receiptId: t.state().saved!.receiptId,
    });
    await t.settle();
    await ack;
    expect(t.state().saved).toBeNull();
  });

  it("does not request a summary when Smart summary is off, and pauses without stopping", async () => {
    const t = setup();
    t.setPreferences({ meetingSmartSummary: false, meetingHideRecorder: true });
    await t.settle();
    await t.act("start");
    expect(t.state()).toMatchObject({ phase: "recording", hideRecorder: true });
    await t.act("pause");
    expect(t.state().phase).toBe("paused");
    await t.act("resume");
    expect(t.state().phase).toBe("recording");
    t.main.on("pause", () => ({
      failure: { kind: "failed", reason: "Temporary pause failure" },
    }));
    await t.act("pause");
    expect(t.state()).toMatchObject({
      phase: "recording",
      error: "Temporary pause failure",
    });
    await t.act("stop");
    await t.settle();
    expect(t.host.api.seen("POST", `${groups}/*`).at(-1)!.body).toMatchObject({
      action: "finalize",
      smart_summary: false,
    });
    expect(t.server.commands).toEqual([
      "enter task-0",
      "task-0 recording v1",
      "task-0 paused v2",
      "task-0 recording v3",
      "task-0 finalize v4",
    ]);
  });

  it("dismisses or discards without a file, and does not offer that meeting again", async () => {
    for (const intent of ["dismiss", "discard"] as const) {
      const t = setup();
      await t.settle();
      if (intent === "discard") await t.act("start");
      await t.act(intent);
      t.present([meeting]);
      await t.settle();
      expect(t.state()).toMatchObject({ phase: "idle", saved: null });
      expect(t.main.seen("stop")).toEqual([]);
      expect(t.server.commands.at(-1)).toBe(
        intent === "dismiss" ? "task-0 dismiss v1" : "task-0 discard v2"
      );
    }
  });

  it("stops after the meeting's 5 s ending grace, and a capped capture once", async () => {
    const t = setup();
    await t.settle();
    await t.act("start");
    t.present([{ ...meeting, status: "ending" }]);
    await t.time.pass(4_999);
    expect(t.main.seen("stop")).toHaveLength(0);
    await t.time.pass(1);
    await t.settle();
    expect(t.main.seen("stop")).toHaveLength(1);

    const capped = setup();
    await capped.settle();
    await capped.act("start");
    capped.main.emit({
      kind: "capture",
      state: { ...capture, status: "recording", capped: true },
    });
    await capped.settle();
    expect(capped.main.seen("stop")).toHaveLength(1);
  });

  it("cancels a start that completes after sign-out, and a failed start can be dismissed", async () => {
    const t = setup();
    await t.settle();
    const release = t.main.hold("start");
    const starting = t.client.call("meetingRecorder.action", {
      action: "start",
      meetingKey: meeting.key,
      generation: t.state().generation,
    });
    await t.settle();
    expect(t.main.seen("start")).toHaveLength(1);
    t.core.observeSession(signedIn("bob"));
    release();
    await t.settle();
    await starting;
    expect(t.main.seen("cancel")).toHaveLength(1);
    expect(t.state().phase).not.toBe("recording");

    const failed = setup();
    await failed.settle();
    failed.main.on("start", () => ({
      failure: { kind: "failed", reason: "Recorder window unavailable" },
    }));
    await failed.act("start");
    expect(failed.state()).toMatchObject({
      phase: "error",
      error: "Recorder window unavailable",
    });
    await failed.act("dismiss");
    expect(failed.state().phase).toBe("idle");
  });

  it("lets Stop end a pending microphone switch without reviving the saved capture", async () => {
    const t = setup();
    await t.settle();
    await t.act("start");
    const release = t.main.hold("selectMicrophone");
    const selecting = t.client.call("meetingRecorder.selectMicrophone", {
      deviceId: "studio",
      meetingKey: meeting.key,
      generation: t.state().generation,
    });
    await t.settle();
    await t.act("stop");
    expect(t.main.seen("stop")).toHaveLength(1);
    expect(t.state().phase).toBe("idle");
    release();
    await t.settle();
    await selecting;
    expect(t.state().phase).toBe("idle");
    expect(t.state().saved).not.toBeNull();
  });

  it("adopts the capture Main kept for a meeting when the core starts again", async () => {
    const host = new FakeHost();
    const main = new FakeMeetingMain();
    const t = setup({ host, main });
    await t.settle();
    main.emit({
      kind: "capture",
      state: { ...capture, status: "recording" },
      meetingKey: meeting.key,
    });
    await t.settle();
    expect(t.state()).toMatchObject({
      phase: "recording",
      meeting: { key: meeting.key },
    });
    await t.act("stop");
    expect(main.seen("stop")).toHaveLength(1);
  });
});

describe("the meeting Task lane", () => {
  it("retries a refused registration twice after 5 s and 15 s with the same saved command", async () => {
    const t = setup();
    await t.settle();
    await t.act("start");
    let registrations = 0;
    t.main.on("register", () => {
      registrations++;
      return { failure: { kind: "registration", retryable: true } };
    });
    await t.act("stop");
    await t.settle();
    expect(t.state().saved).toMatchObject({
      summary: "error",
      summaryError:
        "Meeting submission (register): The Connector or file registration is temporarily unavailable.",
    });
    await t.time.pass(5_000, 500);
    expect(registrations).toBe(2);
    await t.time.pass(15_000, 1_000);
    expect(registrations).toBe(3);
    await t.time.pass(60_000, 1_000);
    expect(registrations).toBe(3);
    expect(t.main.seen("snapshot")).toHaveLength(1);

    // A retry the person asks for goes; it reuses the same recording id and file.
    const saved = t.journal()[0]!;
    t.main.on("register", () => null);
    const retried = t.client.call("meetingRecorder.retryTaskSync", {});
    await t.settle();
    await retried;
    expect(t.state().saved).toMatchObject({ summary: "queued" });
    expect(t.journal()[0]!.final?.recordingId).toBe(saved.final?.recordingId);
    expect(t.server.commands.at(-1)).toBe("task-0 finalize v2");
  });

  it("stops retrying a failed finalize once the session it failed in ended", async () => {
    const t = setup();
    await t.settle();
    await t.act("start");
    let registrations = 0;
    t.main.on("register", () => {
      registrations++;
      return { failure: { kind: "registration", retryable: true } };
    });
    await t.act("stop");
    await t.settle();
    expect(registrations).toBe(1);
    t.core.observeSession(signedOut());
    await t.time.pass(60_000, 1_000);
    expect(registrations).toBe(1);
  });

  it("does not retry a refused submission on its own, and words it without the server's body", async () => {
    const t = setup();
    await t.settle();
    await t.act("start");
    t.host.api.on("POST", `${groups}/*`, (request) =>
      (request.body as { action: string }).action === "finalize"
        ? json(403, { error: "secret detail" })
        : json(200, { status: "x" })
    );
    await t.act("stop");
    await t.settle();
    await t.time.pass(60_000, 1_000);
    expect(t.state().saved?.summaryError).toBe(
      "Meeting submission (submit): HTTP 403."
    );
    expect(
      t.host.api
        .seen("POST", `${groups}/*`)
        .filter((r) => (r.body as { action: string }).action === "finalize")
    ).toHaveLength(1);
  });

  it("keeps the journal across a restart, asks about continuity and reuses the original Task", async () => {
    const t = setup();
    await t.settle();
    t.core.close();
    const host = new FakeHost({ storage: t.host.storage });
    const main = new FakeMeetingMain();
    const again = setup({ host, main, initial: [{ ...meeting, key: "zoom:restart" }] });
    // The server still has the Task the first run entered.
    for (const [id, task] of t.server.tasks) again.server.tasks.set(id, task);
    await again.settle();
    expect(main.seen("recover")).toEqual([{ name: "Zoom" }]);
    await again.act("start", "zoom:restart");
    expect(again.state().taskSync?.task?.taskId).toBe("task-0");
    expect(again.server.commands).toEqual(["task-0 recording v1"]);
  });

  it("carries Main's journal from before the core over once, its queued commands included", async () => {
    const host = new FakeHost();
    const main = new FakeMeetingMain();
    const legacy = [
      {
        account: "https://api.comma.test:alice",
        key: "zoom:old",
        app: "Zoom",
        entry: {
          occurrence_id: "occurrence-old",
          name: "Zoom",
          started_at: 1,
          archive_date: "2026-09-27",
        },
        workspace: { id: "workspace", group_id: "group" },
        receipt: {
          group_id: "group",
          task_id: "task-old",
          status: "active",
          meeting: {
            occurrence_id: "occurrence-old",
            name: "Zoom",
            archive_date: "2026-09-27",
            started_at: 1,
            phase: "recording",
            version: 1,
          },
        },
        outputs: [],
        version: 2,
        action: "paused",
      },
    ];
    main.on("legacy", () => JSON.stringify(legacy));
    const t = setup({ host, main, initial: [] });
    t.server.tasks.set("occurrence-old", legacy[0]!.receipt);
    await t.settle();
    expect(t.server.commands).toEqual(["task-old paused v2"]);
    expect(t.journal()[0]!.entry.occurrence_id).toBe("occurrence-old");
    // Once kept on the device, Main's file is not read again.
    t.core.close();
    const next = new FakeMeetingMain();
    next.on("legacy", () => {
      throw new Error("read again");
    });
    const again = setup({
      host: new FakeHost({ storage: host.storage }),
      main: next,
      initial: [],
    });
    await again.settle();
    expect(next.seen("legacy")).toEqual([]);
  });

  it("keeps an unreadable journal's bytes and records audio without a Task", async () => {
    const host = new FakeHost();
    host.storage.set(MEETING_JOURNAL_KEY, utf8("invalid journal"));
    const t = setup({ host });
    await t.settle();
    expect(t.state().taskSync).toMatchObject({
      status: "error",
      error: expect.stringContaining("Saved meeting sync data could not be read"),
    });
    await t.act("start");
    expect(t.state().phase).toBe("recording");
    expect(new TextDecoder().decode(host.storage.get(MEETING_JOURNAL_KEY))).toBe(
      "invalid journal"
    );
    expect(t.server.commands).toEqual([]);
  });

  it("sends a meeting offered again after dismissal to a new Task, never to the archived one", async () => {
    const t = setup();
    await t.settle();
    await t.act("dismiss");
    t.present([]);
    await t.settle();
    t.present([meeting]);
    await t.settle();
    await t.act("start");
    await t.act("stop");
    await t.settle();
    expect(t.server.commands).toEqual([
      "enter task-0",
      "task-0 dismiss v1",
      "enter task-1",
      "task-1 recording v1",
      "task-1 finalize v2",
    ]);
    expect(t.state().saved).toMatchObject({
      task: { taskId: "task-1" },
      summary: "queued",
    });
  });

  it("saves the agent's outputs next to the recording in Drive, only exact names, then says so", async () => {
    const t = setup();
    await t.settle();
    await t.act("start");
    const conversation = "/v1/comma/groups/group/conversations/task-0";
    const files = ["transcript.txt", "transcript.json", "summary.md"];
    t.host.api.on("GET", conversation, {
      status: "ready_for_review",
      messages: [
        {
          message_id: "user",
          actor_type: "user",
          content: files.map((ext) => ({ type: "file", path: `/a/meeting.${ext}` })),
        },
        {
          message_id: "result",
          actor_type: "agent",
          content: [
            { type: "file", path: "/a/wrong.md" },
            ...files.map((ext) => ({ type: "file", path: `/a/meeting.${ext}` })),
          ],
        },
      ],
    });
    t.host.api.on("GET", `${conversation}/messages/result/attachments/*`, {
      status: 200,
      headers: [],
      body: utf8("output"),
    });
    await t.act("stop");
    await t.settle(1_000);
    expect(t.main.seen("write").map((w) => w.path)).toEqual([
      "recording/2026-09-09/meeting.transcript.txt",
      "recording/2026-09-09/meeting.transcript.json",
      "recording/2026-09-09/meeting.summary.md",
    ]);
    expect(
      t.host.api.requests
        .filter((r) => r.path.includes("/attachments/"))
        .map((r) => r.path.split("/").at(-1))
    ).toEqual(["1", "2", "3"]);
    expect(t.state().saved).toMatchObject({ archive: "done", summary: "queued" });
  });

  it("names the Task by its summary's heading, unless the person renamed it or it is archived", async () => {
    const renames = async (
      task: { title?: string; status?: string } = {},
      patchStatus = 200
    ) => {
      const t = setup();
      await t.settle();
      await t.act("start");
      const conversation = "/v1/comma/groups/group/conversations/task-0";
      t.host.api.on("GET", conversation, () =>
        json(200, {
          status: task.status ?? "ready_for_review",
          title: task.title ?? [...t.server.tasks.values()][0]!.meeting.name,
          messages: [
            {
              message_id: "result",
              actor_type: "agent",
              content: ["transcript.txt", "transcript.json", "summary.md"].map(
                (ext) => ({ type: "file", file_name: `meeting.${ext}` })
              ),
            },
          ],
        })
      );
      t.host.api.on("GET", `${conversation}/messages/result/attachments/*`, (r) => ({
        status: 200,
        headers: [],
        body: utf8(
          r.path.endsWith("/2") ? "# Q4 roadmap review\n\n- Ship the beta" : "output"
        ),
      }));
      t.host.api.on("PATCH", conversation, json(patchStatus, {}));
      await t.act("stop");
      await t.settle(1_000);
      expect(t.state().saved).toMatchObject({ archive: "done" });
      return t.host.api.seen("PATCH", conversation).map((r) => r.body);
    };
    expect(await renames()).toEqual([{ title: "Q4 roadmap review" }]);
    expect(await renames({ title: "Design sync" })).toEqual([]);
    expect(await renames({ status: "archived" })).toEqual([]);
    // A title the server refuses still leaves every output saved.
    expect(await renames({}, 409)).toEqual([{ title: "Q4 roadmap review" }]);
  });

  it("keeps a failed Drive write retryable without claiming the archive", async () => {
    const t = setup();
    await t.settle();
    await t.act("start");
    const conversation = "/v1/comma/groups/group/conversations/task-0";
    t.host.api.on("GET", conversation, {
      status: "ready_for_review",
      messages: [
        {
          message_id: "result",
          actor_type: "agent",
          content: ["transcript.txt", "transcript.json", "summary.md"].map((ext) => ({
            type: "file",
            file_name: `meeting.${ext}`,
          })),
        },
      ],
    });
    t.host.api.on("GET", `${conversation}/messages/result/attachments/*`, offline());
    await t.act("stop");
    await t.settle(1_000);
    expect(t.state().saved).toMatchObject({ archive: "error" });
    t.host.api.on("GET", `${conversation}/messages/result/attachments/*`, {
      status: 200,
      headers: [],
      body: utf8("output"),
    });
    const retried = t.client.call("meetingRecorder.retryTaskSync", {});
    await t.settle(1_000);
    await retried;
    expect(t.state().saved).toMatchObject({ archive: "done" });
    expect(t.main.seen("write")).toHaveLength(3);
  });

  it("shows a Task that ended without outputs once, then archives them quietly once it attached them", async () => {
    const t = setup();
    await t.settle();
    await t.act("start");
    const conversation = "/v1/comma/groups/group/conversations/task-0";
    const attach = (attached: boolean) =>
      t.host.api.on("GET", conversation, {
        status: "ready_for_review",
        messages: attached
          ? [
              {
                message_id: "result",
                actor_type: "agent",
                content: ["transcript.txt", "transcript.json", "summary.md"].map(
                  (ext) => ({ type: "file", file_name: `meeting.${ext}` })
                ),
              },
            ]
          : [],
      });
    attach(false);
    t.host.api.on("GET", `${conversation}/messages/result/attachments/*`, {
      status: 200,
      headers: [],
      body: utf8("output"),
    });
    await t.act("stop");
    await t.settle(1_000);
    const shown = t.state().saved;
    expect(shown).toMatchObject({ archive: "missing" });
    expect(t.main.seen("write")).toEqual([]);
    // Kept, so a launch knows it was shown.
    expect(t.journal()[0]).toMatchObject({ archiveFailureShown: true });

    // A later try (a new session, as at launch) with the Task still without outputs: read again, not shown again.
    t.core.observeSession(signedIn("alice"));
    await t.settle(1_000);
    expect(t.host.api.seen("GET", conversation)).toHaveLength(2);
    expect(t.state().saved).toBe(shown);
    // A person's Retry shows it again.
    const retried = t.client.call("meetingRecorder.retryTaskSync", {});
    await t.settle(1_000);
    await retried;
    expect(t.host.api.seen("GET", conversation)).toHaveLength(3);
    expect(t.state().saved).toMatchObject({ archive: "missing" });
    expect(t.state().saved?.receiptId).not.toBe(shown?.receiptId);

    // The person continued the Task and it attached its outputs: the next try saves them without a Retry.
    attach(true);
    t.core.observeSession(signedIn("alice"));
    await t.settle(1_000);
    expect(t.state().saved).toMatchObject({ archive: "done" });
    expect(t.main.seen("write")).toHaveLength(3);
    expect(t.journal()[0]).not.toHaveProperty("archiveFailureShown");
  });
});

describe("a run of the meeting recorder, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    await t.settle();
    await t.act("start");
    await t.act("pause");
    await t.act("stop");
    await t.settle(1_000);
    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});
