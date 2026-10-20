import { HostError } from "@comma/core-kernel";
import { CoreClient, type Opener } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatRuntimeSnapshot } from "@comma/chat-contract";
import type { Core } from "../../src/core.ts";
import type { ChatPickAnswer } from "../../src/host.ts";
import { FakeDesktop } from "../../src/testing/fake-desktop.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../../src/testing/index.ts";

const base = "/v1/comma/groups/grp_1/conversations/cnv_1";
const files = "/v1/comma/groups/grp_1/files";
const ref = `lfi1_${"A".repeat(43)}`;

/** A channel whose loss the test says (`lose`): the window's client hears its core's process went. */
function losable(core: Core, host: FakeHost, surface?: string) {
  let fail: ((reason: string) => void) | undefined;
  const open: Opener = (onMessage, onFail) => {
    fail = onFail;
    return inProcessOpener(core, host, surface)(onMessage);
  };
  return { open, lose: () => fail?.("The core's process went.") };
}

const client = (open: Opener) => new CoreClient(open, { schedule: () => undefined });

function setup(host = new FakeHost(), withDesktop = true) {
  const desktop = new FakeDesktop();
  if (withDesktop) host.desktop = desktop;
  host.api
    .onStream(`${base}/events`)
    .onStream("/v1/comma/groups/grp_1/conversations/events");
  host.api.on("GET", base, {
    group_id: "grp_1",
    id: "cnv_1",
    kind: "user_chat",
    title: "Thread",
    status: "completed",
    messages: [],
  });
  const core = startTestCore(host);
  const windowChannel = losable(core, host, "win_main");
  const window = client(windowChannel.open);
  // Main's own client: bound to no window.
  const main = client(inProcessOpener(core, host));
  const other = client(inProcessOpener(core, host, "win_other"));
  let snapshot: ChatRuntimeSnapshot | undefined;
  window.subscribe(
    { topic: "chat", surface: "win_main" },
    (value) => (snapshot = (value as { snapshot: ChatRuntimeSnapshot }).snapshot),
    () => undefined
  );
  // The window's view of the conversation, as the core names its subscriber.
  const subscriberId = "win_main:grp_1/cnv_1";
  const shown = () => {
    const session = snapshot?.sessions.find((s) => s.conversationId === "cnv_1");
    return (
      session?.surfaceProjections?.find((p) => p.subscriberId === subscriberId)
        ?.state ?? session?.state
    );
  };
  const time = host.time!;
  /** A call's outcome once the core had time to answer it. */
  const ask = async (on: CoreClient, name: string, params: unknown) => {
    const answer = on.call(name, params).then(
      (value) => ({ value }),
      (error: { code: string }) => ({ error: error.code })
    );
    await time.pass(100);
    return answer;
  };
  /** The window's view of the conversation, as its calls name it. */
  const pick = {
    workspace: "wsp_1",
    group: "grp_1",
    conversation: "cnv_1",
    surface: "win_main",
  };
  const start = async () => {
    core.observeSession(signedIn());
    // The window shows the conversation: its view retains it.
    window.subscribe(
      { topic: "chatView", ...pick },
      () => undefined,
      () => undefined
    );
    await time.pass(100);
  };
  return {
    host,
    desktop,
    core,
    window,
    lose: windowChannel.lose,
    main,
    other,
    shown,
    time,
    ask,
    pick,
    start,
  };
}

describe("a window's file pick", () => {
  it("attaches the uploads and local files Main's dialog gave, and only Main acts on its intake meanwhile", async () => {
    const t = setup();
    t.host.api.on(
      "POST",
      files,
      json(200, {
        name: "photo.png",
        path: `/uploads/${"u".repeat(22)}-photo.png`,
        size: 3,
      })
    );
    let answer!: (picked: ChatPickAnswer) => void;
    t.desktop.pick = () => new Promise((resolve) => (answer = resolve));
    await t.start();

    const picked = t.ask(t.window, "chatView.pickAttachments", t.pick);
    await t.time.pass(100);
    const [request] = t.desktop.picks;
    expect(request).toEqual({
      intakeId: expect.any(String),
      surfaceId: "win_main",
      workspaceId: "wsp_1",
      lease: expect.objectContaining({ sessionId: "session-user-1" }),
      maxFiles: 50,
      maxTotalSize: 1024 * 1024 * 1024,
      maxUploadFiles: 8,
    });
    expect(t.shown()?.attachmentIntakeInFlight).toBe(true);
    const intake = { intakeId: request!.intakeId };
    // Main checks the intake before each registration; neither window may touch it.
    expect(await t.ask(t.main, "chat.intake.check", intake)).toEqual({
      value: { maxFiles: 50, maxTotalSize: 1024 * 1024 * 1024, maxUploadFiles: 8 },
    });
    expect(await t.ask(t.window, "chat.intake.check", intake)).toEqual({
      error: "not_found",
    });
    expect(await t.ask(t.other, "chat.intake.check", intake)).toEqual({
      error: "not_found",
    });
    expect(await t.ask(t.other, "chat.intake.release", intake)).toEqual({
      error: "not_found",
    });
    expect(
      await t.ask(t.other, "localFiles.register", {
        workspace: "wsp_1",
        localFileRef: ref,
        connectorRunId: "run_1",
        deviceId: "dev_1",
        ...intake,
      })
    ).toEqual({ error: "local_file_unavailable" });
    expect(
      t.host.api.seen("POST", "/v1/comma/workspaces/wsp_1/local-file-refs")
    ).toEqual([]);

    answer({
      cancelled: false,
      errors: [],
      items: [
        { kind: "upload", name: "photo.png", size: 3, bytes: Uint8Array.of(1, 2, 3) },
        {
          kind: "local_file",
          file: {
            localFileRef: ref,
            mediaType: "text/plain",
            name: "notes.txt",
            size: 7,
          },
        },
      ],
    });
    await t.time.pass(100);
    expect(await picked).toEqual({ value: true });
    expect(t.shown()?.draftAttachments.map((file) => file.name)).toEqual([
      "photo.png",
      "notes.txt",
    ]);
    expect(t.shown()?.attachmentIntakeInFlight).toBeUndefined();
    expect(t.host.api.seen("POST", files)).toHaveLength(1);
    // Settled, the intake is gone for Main too.
    expect(await t.ask(t.main, "chat.intake.check", intake)).toEqual({
      error: "not_found",
    });
  });

  it("attaches nothing and leaves no intake open when the person cancels the dialog", async () => {
    const t = setup();
    await t.start();
    const picked = await t.ask(t.window, "chatView.pickAttachments", t.pick);
    expect(picked).toEqual({ value: true });
    expect(t.shown()?.draftAttachments).toEqual([]);
    expect(t.shown()?.attachmentIntakeInFlight).toBeUndefined();
    const { intakeId } = t.desktop.picks[0]!;
    expect(await t.ask(t.main, "chat.intake.check", { intakeId })).toEqual({
      error: "not_found",
    });
  });

  it("keeps a failed row for each file Main could not take", async () => {
    const t = setup();
    t.desktop.pick = () => ({
      cancelled: false,
      errors: [
        {
          errorClass: "local_file_too_large",
          isImage: false,
          message: "Selected local files exceed the remaining combined limit.",
          name: "huge.bin",
          retryable: true,
        },
      ],
      items: [],
    });
    await t.start();
    const picked = await t.ask(t.window, "chatView.pickAttachments", t.pick);
    const { intakeId } = t.desktop.picks[0]!;
    expect(picked).toEqual({ value: true });
    expect(t.shown()?.draftAttachments).toEqual([
      expect.objectContaining({
        id: `chat-intake-failure:${intakeId}:0`,
        name: "huge.bin",
        status: "failed",
      }),
    ]);
  });

  it("settles the intake as failed when Main's dialog fails", async () => {
    const t = setup();
    t.desktop.pick = () => new HostError("The window is not open.");
    await t.start();
    const picked = await t.ask(t.window, "chatView.pickAttachments", t.pick);
    expect(picked).toEqual({ error: expect.any(String) });
    const { intakeId } = t.desktop.picks[0]!;
    expect(t.shown()?.draftAttachments).toEqual([
      expect.objectContaining({
        id: `chat-intake-failure:${intakeId}:0`,
        status: "failed",
      }),
    ]);
    expect(t.shown()?.attachmentIntakeInFlight).toBeUndefined();
  });

  it("rejects a pick the core's restart cut short, and the new core knows no such intake", async () => {
    const host = new FakeHost();
    const t = setup(host);
    t.desktop.pick = () => new Promise(() => undefined);
    await t.start();
    const picked = t.window.call("chatView.pickAttachments", t.pick).then(
      () => "answered",
      (error: { code: string }) => error.code
    );
    // The conversation's streams are open before the core goes (a replay ends where the log's run closed).
    await t.time.pass(1_000);
    const { intakeId } = t.desktop.picks[0]!;
    t.core.close();
    t.lose();
    expect(await picked).not.toBe("answered");
    expect(t.desktop.picksGivenUp).toBe(1);

    const again = setup(host);
    await again.start();
    expect(await again.ask(again.main, "chat.intake.check", { intakeId })).toEqual({
      error: "not_found",
    });
  });

  it("is refused without the desktop app's dialog", async () => {
    const t = setup(new FakeHost(), false);
    await t.start();
    expect(await t.ask(t.window, "chatView.pickAttachments", t.pick)).toEqual({
      error: "unsupported",
    });
  });
});
