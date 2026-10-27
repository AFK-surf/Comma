// The notices the core words for messages a conversation gains (`chatAppended`), which Electron's Main shows as
// system banners: which messages get one, its title, its body and the language of its reply field.
import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatAppendedValue } from "../../src/contract.ts";
import { FakeDesktop } from "../../src/testing/fake-desktop.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../../src/testing/index.ts";

const base = "/v1/comma/groups/grp_1/conversations/cnv_1";
const events = `${base}/events`;
const feed = "/v1/comma/groups/grp_1/conversations/events";
const target = { workspaceId: "wsp_1", groupId: "grp_1", conversationId: "cnv_1" };

const message = (id: string, text: string, extra: Record<string, unknown> = {}) => ({
  message_id: id,
  kind: "message",
  actor_type: "agent",
  agent_id: "agt_1",
  content: [{ type: "text", text }],
  created_at: 1,
  ...extra,
});
const userMessage = (id: string, text: string) => ({
  message_id: id,
  kind: "message",
  actor_type: "user",
  content: [{ type: "text", text }],
  created_at: 1,
});
const snapshot = (messages: unknown[]) => ({
  type: "snapshot",
  conversation_id: "cnv_1",
  group_id: "grp_1",
  status: "open",
  messages,
});

/**
 * A core whose Main client keeps conversation cnv_1 (`kind`, `title` as the server names it) and follows its notices.
 * `desktop`: the core runs in the desktop app (its product name).
 */
async function setup({
  kind = "user_chat",
  title = "Bridge chat",
  desktop = true,
}: { kind?: string; title?: string; desktop?: boolean } = {}) {
  const host = new FakeHost();
  if (desktop) host.desktop = new FakeDesktop();
  let shown: unknown[] = [userMessage("m0", "Hi")];
  host.api
    .onStream(events)
    .onStream(feed)
    .on("GET", base, () =>
      json(200, {
        group_id: "grp_1",
        id: "cnv_1",
        kind,
        title,
        status: "open",
        messages: shown,
      })
    );
  const core = startTestCore(host);
  core.observeSession(signedIn());
  // Main's own client: bound to no window.
  const main = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  let appended: ChatAppendedValue[] = [];
  main.subscribe(
    { topic: "chatAppended" },
    (value) => (appended = (value as { appended: ChatAppendedValue[] }).appended),
    () => undefined
  );
  await main.call("chat.retain", {
    ...target,
    subscriberId: "main:grp_1/cnv_1",
    leaseId: "00000000-0000-4000-8000-000000000001",
  });
  const time = host.time!;
  await time.pass(1_500);
  let version = 0;
  /** The server tells the conversation changed: its stream's snapshot (Home chat), or a Task's invalidation. */
  const changed = async () => {
    if (kind === "agent_task") {
      version += 1;
      for (const stream of host.api.streams)
        if (stream.path === feed && !stream.closed)
          stream.event({
            type: "conversation_list_invalidated",
            group_id: "grp_1",
            kind: "agent_task",
            version: String(version),
          });
    } else host.api.open(events)!.named("snapshot", snapshot(shown));
    await time.pass(100);
  };
  // The conversation's history: what it had before is no news.
  await changed();
  return {
    main,
    notices: () => appended.flatMap((entry) => entry.notices),
    appended: () => appended,
    /** The conversation gains `messages`. */
    arrive: async (...messages: unknown[]) => {
      shown = [...shown, ...messages];
      await changed();
    },
  };
}

describe("the notices for messages a conversation gains", () => {
  it("words a message the Router sends in Home chat as Comma, with the message's words", async () => {
    const t = await setup();
    await t.arrive(message("m1", "**Router** replied."));

    // The server names the Home conversation for storage ("Bridge chat"), not for the person.
    expect(t.appended()).toEqual([
      {
        seq: expect.any(Number),
        target,
        notices: [
          {
            messageId: "m1",
            title: "Comma",
            body: "Router replied.",
            replyPlaceholder: "Reply",
          },
        ],
      },
    ]);
  });

  it("names a Task's Router message by the Task's title, and the app when the Task has none", async () => {
    const titled = await setup({ kind: "agent_task", title: "Plan the offsite" });
    await titled.arrive(message("m1", "Done.", { role_label: "delegator" }));
    expect(titled.notices()).toMatchObject([
      { title: "Plan the offsite", body: "Done." },
    ]);

    const untitled = await setup({ kind: "agent_task", title: "  " });
    await untitled.arrive(message("m1", "Done.", { role_label: "delegator" }));
    expect(untitled.notices()).toMatchObject([{ title: "Comma Test" }]);

    const elsewhere = await setup({ kind: "agent_task", title: "", desktop: false });
    await elsewhere.arrive(message("m1", "Done.", { role_label: "delegator" }));
    expect(elsewhere.notices()).toMatchObject([{ title: "Comma" }]);
  });

  it("words no notice for a Worker's step, the person's own message, or files without words", async () => {
    const task = await setup({ kind: "agent_task", title: "Task" });
    await task.arrive(
      message("m1", "Reading the files.", { role_label: "worker" }),
      userMessage("m2", "Thanks")
    );
    expect(task.appended()).toEqual([]);
    await task.arrive(message("m5", "Finished.", { role_label: "delegator" }));
    expect(task.notices().map((notice) => notice.messageId)).toEqual(["m5"]);

    const home = await setup();
    await home.arrive({
      ...message("m3", ""),
      content: [{ type: "file", file_name: "report.pdf" }],
    });
    expect(home.appended()).toEqual([]);
    // A later Router message still gets its notice.
    await home.arrive(message("m4", "Here it is."));
    expect(home.notices().map((notice) => notice.messageId)).toEqual(["m4"]);
  });

  it("words each notice in the language chat is in when the message arrives", async () => {
    const t = await setup();
    await t.arrive(message("m1", "One."));
    await t.main.call("chat.locale", { locale: "zh-CN" });
    await t.arrive(message("m2", "Two."));

    expect(t.notices().map((notice) => notice.replyPlaceholder)).toEqual([
      "Reply",
      "回复",
    ]);
  });

  it("gives one notice per Router message that arrived together", async () => {
    const t = await setup();
    await t.arrive(message("m1", "First."), message("m2", "Second."));

    expect(t.appended()).toHaveLength(1);
    expect(t.notices().map((notice) => notice.body)).toEqual(["First.", "Second."]);
  });

  it("gives no notice, after the core starts again, for history older than what the device kept", async () => {
    const host = new FakeHost();
    host.desktop = new FakeDesktop();
    // More Router messages than the device keeps (500); a read returns up to 1000.
    let shown: unknown[] = Array.from({ length: 600 }, (_, i) =>
      message(`m${i + 1}`, `Reply ${i + 1}.`, { seq: i + 1 })
    );
    host.api
      .onStream(events)
      .onStream(feed)
      .on("GET", base, () =>
        json(200, {
          group_id: "grp_1",
          id: "cnv_1",
          kind: "user_chat",
          title: "Bridge chat",
          status: "open",
          messages: shown,
        })
      );
    const start = async (leaseId: string) => {
      const core = startTestCore(host);
      core.observeSession(signedIn());
      const main = new CoreClient(inProcessOpener(core, host), {
        schedule: () => undefined,
      });
      let appended: ChatAppendedValue[] = [];
      main.subscribe(
        { topic: "chatAppended" },
        (value) => (appended = (value as { appended: ChatAppendedValue[] }).appended),
        () => undefined
      );
      await main.call("chat.retain", {
        ...target,
        subscriberId: "main:grp_1/cnv_1",
        leaseId,
      });
      await host.time!.pass(1_500);
      return {
        core,
        main,
        notices: () =>
          appended.flatMap((entry) => entry.notices.map((n) => n.messageId)),
      };
    };
    const first = await start("00000000-0000-4000-8000-000000000001");
    first.main.close();
    first.core.close();

    const again = await start("00000000-0000-4000-8000-000000000002");
    host.api.open(events)!.named("snapshot", snapshot(shown));
    await host.time!.pass(100);
    expect(again.notices()).toEqual([]);

    // What the conversation gains after that still gets its notice.
    shown = [...shown, message("m601", "New.", { seq: 601 })];
    host.api.open(events)!.named("snapshot", snapshot(shown));
    await host.time!.pass(100);
    expect(again.notices()).toEqual(["m601"]);
  });
});
