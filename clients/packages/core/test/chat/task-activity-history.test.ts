// A Task's Activity in a window's view (`chatView`): the history before the transcript it holds is read for the
// Activity alone, in pages cut to what it reads, back to the Task's first message.
import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatViewValue } from "../../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
  type SeenRequest,
} from "../../src/testing/index.ts";

const base = "/v1/comma/groups/grp_1/conversations/cnv_task";
const view = {
  topic: "chatView",
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_task",
  surface: "win_main",
};
const named = {
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_task",
  surface: "win_main",
};

const message = (
  seq: number,
  content: unknown[],
  extra: Record<string, unknown> = {}
) => ({
  message_id: `m${seq}`,
  seq,
  kind: "message",
  actor_type: "agent",
  agent_id: "agt_worker",
  role_label: "worker",
  content,
  created_at: 1_720_000_000 + seq,
  ...extra,
});
const text = (seq: number) => message(seq, [{ type: "text", text: `message ${seq}` }]);
const milestone = (seq: number, title: string) =>
  message(seq, [{ type: "milestone", title }]);
const brief = message(1, [{ type: "text", text: "Write the invites." }], {
  agent_id: "agt_router",
  role_label: "delegator",
  metadata: { message_type: "task_command" },
});

/** The Task's 500 messages: the brief, a milestone and its result early on, another near the end. */
const all = Array.from({ length: 500 }, (_, i) => {
  const seq = i + 1;
  if (seq === 1) return brief;
  if (seq === 50) return milestone(50, "Wrote the agenda");
  if (seq === 480) return milestone(480, "Wrote Alice's invite");
  return text(seq);
});

/** A Task of `messages` whose read holds the latest 100; `serve` answers its Activity pages. */
async function setup(
  messages: ReturnType<typeof message>[],
  serve: (before: number, limit: number) => ReturnType<typeof message>[] | "fail" = (
    before,
    limit
  ) => messages.filter((m) => m.seq < before).slice(-limit)
) {
  const host = new FakeHost();
  const pages: URLSearchParams[] = [];
  const first = messages[0]!.seq;
  host.api.on("GET", `${base}/messages`, (request: SeenRequest) => {
    const q = new URLSearchParams(request.path.split("?")[1]);
    pages.push(q);
    const page = serve(Number(q.get("before")), Number(q.get("limit")));
    if (page === "fail") return json(500, { error: "unavailable" });
    return json(200, {
      data: page,
      covered: page.length ? { first: page[0]!.seq, last: page.at(-1)!.seq } : null,
      bounds: { first, last: messages.at(-1)!.seq },
      has_older: page.length > 0 && page[0]!.seq > first,
    });
  });
  host.api.onStream("/v1/comma/groups/grp_1/conversations/events").on("GET", base, {
    group_id: "grp_1",
    id: "cnv_task",
    kind: "agent_task",
    title: "Invites",
    status: "active",
    messages: messages.slice(-100),
  });
  const core = startTestCore(host);
  core.observeSession(signedIn());
  const client = new CoreClient(inProcessOpener(core, host, "win_main"), {
    schedule: () => undefined,
  });
  let value: ChatViewValue | undefined;
  client.subscribe(
    view,
    (v) => (value = v as ChatViewValue),
    () => undefined
  );
  const time = host.time!;
  await time.pass(1_600);
  return {
    pages,
    state: () => value!.state!,
    read: async () => {
      await client.call("chatView.readTaskActivity", named);
      await time.pass(100);
    },
  };
}

describe("a Task's Activity in a window's view", () => {
  it("reads the history before the transcript for the Activity alone, once, back to the Task's first message", async () => {
    const t = await setup(all);
    const { pages } = t;
    const titles = () =>
      t
        .state()
        .taskActivity?.groups.flatMap((group) =>
          group.entries.map((entry) => entry.title)
        );
    expect(titles()).toEqual(["Wrote Alice's invite"]);

    await t.read();

    expect(pages.map((q) => [q.get("before"), q.get("limit"), q.get("view")])).toEqual([
      ["401", "200", "activity"],
      ["201", "200", "activity"],
    ]);
    // Both milestones followed the brief; before the read, the Activity could not tell.
    expect(t.state().taskActivity?.groups).toEqual([
      {
        request: { messageId: "m1", kind: "brief", text: "", at: 1_720_000_001 },
        entries: [
          { title: "Wrote the agenda", at: 1_720_000_050, messageId: "m51" },
          { title: "Wrote Alice's invite", at: 1_720_000_480, messageId: "m481" },
        ],
      },
    ]);
    // The transcript still holds what it held.
    expect(t.state().messages.map((m) => m.seq)[0]).toBe(401);

    // Read once: the next call reads nothing.
    const read = pages.length;
    await t.read();
    expect(pages).toHaveLength(read);
  });
  it("reads a long Task's history to its first message, however many pages it takes", async () => {
    const long = Array.from({ length: 40_200 }, (_, i) => {
      const seq = i + 1;
      if (seq === 1) return brief;
      if (seq === 2) return milestone(2, "Wrote the agenda");
      return text(seq);
    });
    const t = await setup(long);

    await t.read();

    expect(t.pages).toHaveLength(201);
    expect(t.state().taskActivity?.groups).toEqual([
      {
        request: { messageId: "m1", kind: "brief", text: "", at: 1_720_000_001 },
        entries: [{ title: "Wrote the agenda", at: 1_720_000_002, messageId: "m3" }],
      },
    ]);
  });

  it("keeps what it read when a page reaches no further back, and goes on at the next call", async () => {
    let stuck = true;
    const t = await setup(all, (before, limit) =>
      // The server answers the same page once, whatever it was asked.
      stuck && before < 401
        ? all.filter((m) => m.seq >= 201 && m.seq < 401).slice(-limit)
        : all.filter((m) => m.seq < before).slice(-limit)
    );

    await t.read();
    expect(t.pages.map((q) => q.get("before"))).toEqual(["401", "201"]);
    expect(t.state().taskActivity?.groups[0]?.request).toBeUndefined();
    expect(t.state().taskActivity?.earlier).toBe("unread");

    stuck = false;
    await t.read();
    expect(t.pages.map((q) => q.get("before"))).toEqual(["401", "201", "201"]);
    expect(t.state().taskActivity?.groups[0]?.request?.kind).toBe("brief");
  });
  it("says what it has not read when a read fails, and reads it when asked again", async () => {
    // The transcript holds no milestone; the only one is long before it.
    const quiet = all.map((m) => (m.seq === 480 ? text(480) : m));
    let failing = true;
    const t = await setup(quiet, (before, limit) =>
      failing && before < 401
        ? "fail"
        : quiet.filter((m) => m.seq < before).slice(-limit)
    );
    expect(t.state().taskActivity).toBeUndefined();

    await t.read();
    expect(t.state().taskActivity).toMatchObject({ groups: [], earlier: "unread" });

    failing = false;
    await t.read();
    expect(t.pages.map((q) => q.get("before"))).toEqual(["401", "201", "201"]);
    expect(t.state().taskActivity).toEqual({
      key: expect.any(String),
      groups: [
        {
          request: { messageId: "m1", kind: "brief", text: "", at: 1_720_000_001 },
          entries: [{ title: "Wrote the agenda", at: 1_720_000_050, messageId: "m51" }],
        },
      ],
    });
  });
});
