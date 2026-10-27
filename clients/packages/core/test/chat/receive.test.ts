// Files the computer received (AirDrop) for a window's chat (`chat.intake.receive`): the core picks the draft they go
// to, holds it while the person changes conversation, says what room it has, and attaches what Electron's Main
// registered; the draft's send waits until they are in.
import type { ChatRuntimeSnapshot } from "@comma/chat-contract";
import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import {
  FakeHost,
  inProcessOpener,
  signedIn,
  signedOut,
  startTestCore,
} from "../../src/testing/index.ts";

const group = "/v1/comma/groups/grp_1/conversations";
const ref = (letter: string) => `lfi1_${letter.repeat(43)}`;
const report = {
  kind: "local_file" as const,
  file: {
    localFileRef: ref("a"),
    name: "report.pdf",
    size: 12,
    mediaType: "application/pdf",
  },
};
const file = (name: string, isDirectory = false) => ({ name, isDirectory });

/** The window's lease on a conversation, as it names it. */
const lease = (conversationId: string, leaseId: string) => ({
  workspaceId: "wsp_1",
  groupId: "grp_1",
  conversationId,
  subscriberId: `win_main:grp_1/${conversationId}`,
  leaseId,
});

function setup() {
  const host = new FakeHost();
  // Home chat as the server stores it, a second chat, and a Task.
  for (const [id, kind, title] of [
    ["cnv_1", "user_chat", "Bridge chat"],
    ["cnv_2", "user_chat", "Other"],
    ["cnv_3", "agent_task", "Plan the offsite"],
  ]) {
    host.api.onStream(`${group}/${id}/events`);
    host.api.on("GET", `${group}/${id}`, {
      group_id: "grp_1",
      id,
      kind,
      title,
      status: "completed",
      messages: [],
    });
  }
  host.api.onStream(`${group}/events`);
  const sent = host.api.hold("POST", `${group}/cnv_1/messages`);
  host.api.on("POST", `${group}/cnv_1/messages`, {
    group_id: "grp_1",
    id: "cnv_1",
    kind: "user_chat",
    title: "Bridge chat",
    status: "active",
    messages: [],
  });
  const core = startTestCore(host);
  const time = host.time!;
  const window = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  // Main's own client: bound to no window.
  const main = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  let snapshot: ChatRuntimeSnapshot | undefined;
  window.subscribe(
    { topic: "chat", surface: "win_main" },
    (value) => (snapshot = (value as { snapshot: ChatRuntimeSnapshot }).snapshot),
    () => undefined
  );
  const draft = (conversationId = "cnv_1") =>
    snapshot?.sessions.find((s) => s.conversationId === conversationId)?.state;
  /** A call's outcome once the core had time to answer it. */
  const ask = async (on: CoreClient, name: string, params: unknown) => {
    const answer = on.call(name, params).then(
      (value) => ({ value }),
      (error: { code: string; message: string }) => ({
        error: error.code,
        message: error.message,
      })
    );
    await time.pass(100);
    return answer;
  };
  const first = lease("cnv_1", "00000000-0000-4000-8000-000000000001");
  const second = lease("cnv_2", "00000000-0000-4000-8000-000000000002");
  const start = async () => {
    core.observeSession(signedIn());
    await ask(window, "chat.retain", first);
  };
  /** The window's view of cnv_1, as its calls name it. */
  const named = {
    workspace: "wsp_1",
    group: "grp_1",
    conversation: "cnv_1",
    surface: "win_main",
  };
  /** The window shows cnv_1 (its view retains it). */
  const show = async () => {
    core.observeSession(signedIn());
    window.subscribe(
      { topic: "chatView", ...named },
      () => undefined,
      () => undefined
    );
    await time.pass(100);
  };
  const act = (name: string, params: Record<string, unknown>) =>
    ask(window, `chatView.${name}`, { ...named, ...params });
  const receive = (files = [file("report.pdf")]) =>
    ask(main, "chat.intake.receive", { surfaceId: "win_main", files });
  return {
    host,
    core,
    time,
    window,
    main,
    draft,
    ask,
    first,
    second,
    start,
    show,
    act,
    receive,
    sent: () => host.api.seen("POST", `${group}/cnv_1/messages`),
    releaseSend: sent,
  };
}

describe("files received for a window's chat", () => {
  it("join the draft the window shows, which is sent only with them, as the person wrote it", async () => {
    const t = setup();
    await t.show();
    await t.act("setDraft", { draft: "Review this" });

    const received = await t.receive();
    expect(received).toEqual({
      value: { intakeId: expect.any(String), title: "Comma", workspaceId: "wsp_1" },
    });
    const intakeId = (received as { value: { intakeId: string } }).value.intakeId;
    expect(t.draft()?.attachmentIntakeInFlight).toBe(true);
    // The draft has room for all a pick may add.
    expect(await t.ask(t.main, "chat.intake.check", { intakeId })).toEqual({
      value: { maxFiles: 50, maxTotalSize: 1024 * 1024 * 1024, maxUploadFiles: 8 },
    });

    // The files are still on their way: the draft is not sent without them.
    expect(await t.act("send", { text: "Review this" })).toMatchObject({
      error: "chat_refused",
    });
    expect(t.sent()).toEqual([]);

    expect(
      await t.ask(t.main, "chat.intake.attach", { intakeId, items: [report] })
    ).toMatchObject({ value: { revision: expect.any(Number) } });
    await t.ask(t.main, "chat.intake.settle", {
      intakeId,
      outcome: { cancelled: false, errorCount: 0 },
    });
    await t.ask(t.main, "chat.intake.release", { intakeId });
    expect(t.draft()).toMatchObject({
      draft: "Review this",
      draftAttachments: [{ name: "report.pdf" }],
    });
    expect(t.draft()?.attachmentIntakeInFlight).toBeUndefined();
    expect(t.sent()).toEqual([]);

    const sending = t.act("send", { text: "Review this" });
    await t.time.pass(100);
    t.releaseSend();
    await t.time.pass(100);
    expect(await sending).toEqual({ value: expect.anything() });
    expect(t.sent()).toHaveLength(1);
    expect(t.sent()[0]!.body).toMatchObject({
      message: {
        content: [
          { type: "text", text: "Review this" },
          expect.objectContaining({ type: "local_file", display_name: "report.pdf" }),
        ],
      },
    });
  });

  it("declined, leave the draft as it was and no intake open", async () => {
    const t = setup();
    await t.show();
    await t.act("setDraft", { draft: "Keep me" });
    const received = await t.receive();
    const intakeId = (received as { value: { intakeId: string } }).value.intakeId;

    await t.ask(t.main, "chat.intake.settle", {
      intakeId,
      outcome: { cancelled: true, errorCount: 0 },
    });
    await t.ask(t.main, "chat.intake.release", { intakeId });

    expect(t.draft()).toMatchObject({ draft: "Keep me", draftAttachments: [] });
    expect(t.draft()?.attachmentIntakeInFlight).toBeUndefined();
    expect(await t.ask(t.main, "chat.intake.check", { intakeId })).toMatchObject({
      error: "not_found",
    });
  });

  it("are not attached once the window shows another conversation", async () => {
    const t = setup();
    await t.start();
    const received = await t.receive();
    const intakeId = (received as { value: { intakeId: string } }).value.intakeId;

    await t.ask(t.window, "chat.release", t.first);
    await t.ask(t.window, "chat.retain", t.second);

    expect(await t.ask(t.main, "chat.intake.check", { intakeId })).toMatchObject({
      error: "chat_refused",
      message: expect.stringContaining("changed"),
    });
    expect(
      await t.ask(t.main, "chat.intake.attach", { intakeId, items: [report] })
    ).toMatchObject({ message: expect.stringContaining("changed") });
    expect(t.draft("cnv_1")?.draftAttachments ?? []).toEqual([]);
    expect(t.draft("cnv_2")?.draftAttachments).toEqual([]);
  });

  it("are not attached after the account changed", async () => {
    const t = setup();
    await t.start();
    const received = await t.receive();
    const intakeId = (received as { value: { intakeId: string } }).value.intakeId;

    // Another account takes the device: the core lets this one's chats go.
    t.core.observeSession(signedOut());
    await t.time.pass(100);

    expect(await t.ask(t.main, "chat.intake.check", { intakeId })).toMatchObject({
      error: "not_found",
    });
    expect(
      await t.ask(t.main, "chat.intake.attach", { intakeId, items: [report] })
    ).toMatchObject({ error: "not_found" });
  });

  it("are refused when the window shows no conversation, or one is a folder", async () => {
    const t = setup();
    t.core.observeSession(signedIn());
    expect(await t.receive()).toEqual({ value: { refused: "no_chat" } });

    await t.ask(t.window, "chat.retain", t.first);
    expect(await t.receive([file("report.pdf"), file("Folder", true)])).toEqual({
      value: { refused: "directory", title: "Comma" },
    });
    expect(t.draft()?.attachmentIntakeInFlight).toBeUndefined();
  });

  it("name Home chat Comma, not its stored server title, and a Task by its own title", async () => {
    const t = setup();
    await t.start();
    expect(await t.receive()).toMatchObject({ value: { title: "Comma" } });

    const task = setup();
    task.core.observeSession(signedIn());
    await task.ask(
      task.window,
      "chat.retain",
      lease("cnv_3", "00000000-0000-4000-8000-000000000003")
    );
    expect(await task.receive()).toMatchObject({
      value: { title: "Plan the offsite" },
    });
  });

  it("get the room the draft has when they arrive", async () => {
    const t = setup();
    await t.start();
    const received = await t.receive();
    const intakeId = (received as { value: { intakeId: string } }).value.intakeId;
    // The person attached a file of their own meanwhile.
    await t.ask(t.window, "chat.attachLocalFiles", {
      ...t.first,
      surfaceId: "win_main",
      files: [
        {
          localFileRef: ref("b"),
          name: "existing.pdf",
          size: 100,
          mediaType: "application/pdf",
        },
      ],
    });

    expect(await t.ask(t.main, "chat.intake.check", { intakeId })).toEqual({
      value: {
        maxFiles: 49,
        maxTotalSize: 1024 * 1024 * 1024 - 100,
        maxUploadFiles: 8,
      },
    });
  });
});
