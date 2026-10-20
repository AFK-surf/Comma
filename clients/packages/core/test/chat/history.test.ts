// A conversation's history in a window's view (`chatView`): messages by seq, the page before the oldest one read as
// the window asks, a gap between what was read closed by paging, and what the device keeps of it.
import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatViewValue } from "../../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
  type SeenRequest,
} from "../../src/testing/index.ts";

const base = "/v1/comma/groups/grp_1/conversations/cnv_1";
const events = `${base}/events`;
const view = {
  topic: "chatView",
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_1",
  surface: "win_main",
};
const named = {
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_1",
  surface: "win_main",
};

const message = (seq: number, extra: Record<string, unknown> = {}) => ({
  message_id: `m${seq}`,
  seq,
  kind: "message",
  actor_type: "agent",
  agent_id: "agt_1",
  content: [{ type: "text", text: `message ${seq}` }],
  created_at: seq,
  ...extra,
});
const run = (first: number, last: number) =>
  Array.from({ length: last - first + 1 }, (_, i) => message(first + i));
const snapshot = (messages: unknown[]) => ({
  type: "snapshot",
  conversation_id: "cnv_1",
  group_id: "grp_1",
  status: "open",
  messages,
});
const query = (request: SeenRequest) => new URLSearchParams(request.path.split("?")[1]);

/** Answers `GET …/messages` from `all` by seq, as the server pages them. */
function servePages(
  host: FakeHost,
  all: () => ReturnType<typeof message>[],
  reachable: () => boolean = () => true
) {
  host.api.on("GET", `${base}/messages`, (request: SeenRequest) => {
    if (!reachable()) return offline();
    const list = all().toSorted((a, b) => a.seq - b.seq);
    const q = query(request);
    const limit = Number(q.get("limit"));
    let page = list.slice(-limit);
    if (q.has("before"))
      page = list.filter((m) => m.seq < Number(q.get("before"))).slice(-limit);
    if (q.has("after"))
      page = list.filter((m) => m.seq > Number(q.get("after"))).slice(0, limit);
    const bounds = list.length ? { first: list[0]!.seq, last: list.at(-1)!.seq } : null;
    return json(200, {
      data: page,
      covered: page.length ? { first: page[0]!.seq, last: page.at(-1)!.seq } : null,
      bounds,
      has_older: page.length > 0 && page[0]!.seq > (bounds?.first ?? 0),
    });
  });
}

function setup(host = new FakeHost()) {
  host.api
    .onStream(events)
    .onStream("/v1/comma/groups/grp_1/conversations/events")
    .on("GET", base, {
      group_id: "grp_1",
      id: "cnv_1",
      kind: "user_chat",
      title: "Thread",
      status: "open",
      messages: [],
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
  return {
    host,
    core,
    client,
    time: host.time!,
    state: () => value!.state!,
    seqs: () => value!.state!.messages.map((m) => m.seq),
    stream: () => host.api.open(events)!,
  };
}

describe("a conversation's history in a window's view", () => {
  it("gives each message its seq, and reads the page before the oldest one when the window asks", async () => {
    const host = new FakeHost();
    servePages(host, () => run(1, 260));
    const t = setup(host);
    await t.time.pass(1_500);
    t.stream().named("snapshot", snapshot(run(211, 260)));
    await t.time.pass(100);
    expect(t.seqs()).toEqual(run(211, 260).map((m) => m.seq));
    expect(t.state().history).toEqual({
      hasOlder: true,
      loadingOlder: false,
      ranges: [[211, 260]],
    });

    await t.client.call("chatView.older", named);
    await t.time.pass(100);
    expect(t.seqs()[0]).toBe(111);
    expect(t.state().history?.ranges).toEqual([[111, 260]]);
    await t.client.call("chatView.older", named);
    await t.time.pass(100);
    expect(t.seqs()[0]).toBe(11);
    await t.client.call("chatView.older", named);
    await t.time.pass(100);
    expect(t.seqs()[0]).toBe(1);
    expect(t.state().history).toMatchObject({ hasOlder: false, ranges: [[1, 260]] });
    expect(t.seqs()).toHaveLength(260);
  });

  it("shows what was read on both sides of a gap, and closes it by paging forward from the older side", async () => {
    const host = new FakeHost();
    let all = run(1, 3);
    let paging = true;
    servePages(
      host,
      () => all,
      () => paging
    );
    const first = setup(host);
    await first.time.pass(1_500);
    first.stream().named("snapshot", snapshot(run(1, 3)));
    await first.time.pass(1_500);
    first.core.close();

    // Much was said while this device was away: the snapshot's window no longer reaches what it kept.
    all = run(1, 400);
    paging = false;
    const again = setup(host);
    await again.time.pass(1_500);
    again.stream().named("snapshot", snapshot(run(351, 400)));
    await again.time.pass(100);
    expect(again.state().history?.ranges).toEqual([
      [1, 3],
      [351, 400],
    ]);
    expect(again.seqs().slice(0, 4)).toEqual([1, 2, 3, 351]);

    // The next snapshot finds the server's pages again.
    paging = true;
    again.stream().named("snapshot", snapshot(run(351, 400)));
    await again.time.pass(1_000);
    expect(again.state().history?.ranges).toEqual([[1, 400]]);
    expect(again.seqs()).toHaveLength(400);
    const after = host.api
      .seen("GET", `${base}/messages`)
      .map((request) => query(request).get("after"));
    expect(after.filter(Boolean)[0]).toBe("3");
  });

  it("counts a hidden message as read: no gap opens around one the transcript does not show", async () => {
    const host = new FakeHost();
    const hidden = message(2, {
      actor_type: "system",
      kind: "app_event",
      metadata: { event_type: "provider.status" },
    });
    servePages(host, () => [message(1), hidden, message(3)]);
    const t = setup(host);
    await t.time.pass(1_500);
    t.stream().named("snapshot", snapshot([message(1), hidden, message(3)]));
    await t.time.pass(100);
    expect(t.seqs()).toEqual([1, 3]);
    expect(t.state().history?.ranges).toEqual([[1, 3]]);
    expect(host.api.seen("GET", `${base}/messages`)).toEqual([]);
  });

  it("carries an image's pixel size, and a reference's status", async () => {
    const host = new FakeHost();
    const t = setup(host);
    await t.time.pass(1_500);
    t.stream().named(
      "snapshot",
      snapshot([
        message(1, {
          content: [
            { type: "image", file_name: "a.png", width: 640, height: 480 },
            {
              type: "conversation_ref",
              conversation_id: "cnv_task",
              kind: "agent_task",
              title: "Task",
              status: "running",
              activity_status: "working",
            },
          ],
        }),
      ])
    );
    await t.time.pass(100);
    const shown = t.state().messages[0]!;
    expect(shown.attachments[0]).toMatchObject({ width: 640, height: 480 });
    expect(shown.refs[0]).toMatchObject({
      status: "running",
      activityStatus: "working",
    });
  });

  it("says who wrote each message and what the server says it is for", async () => {
    const t = setup(new FakeHost());
    await t.time.pass(1_500);
    t.stream().named(
      "snapshot",
      snapshot([
        message(1, { metadata: { message_type: "task_command" } }),
        message(2, { actor_type: "system", agent_id: undefined }),
      ])
    );
    await t.time.pass(100);
    expect(t.state().messages.map((m) => [m.actorType, m.messageType ?? null])).toEqual(
      [
        ["agent", "task_command"],
        ["system", null],
      ]
    );
  });

  it("shows a device setup offer as its latest update says it, and never the update itself", async () => {
    const host = new FakeHost();
    // oxlint-disable-next-line unicorn/consistent-function-scoping -- read beside the messages it makes
    const offer = (status: string, revision: number) => ({
      type: "device_setup_offer",
      offer_id: "off_1",
      name: "Comma Mini",
      model: "mini",
      short_id: "a1b2",
      reporter_device_id: "dev_phone",
      status,
      expires_at: 2_000_000_000,
      revision,
    });
    const t = setup(host);
    await t.time.pass(1_500);
    const offered = message(1, { content: [offer("open", 1)] });
    t.stream().named("snapshot", snapshot([offered]));
    await t.time.pass(100);
    expect(t.state().messages[0]!.parts).toEqual([
      {
        kind: "device-setup-offer",
        offer: {
          expiresAt: 2_000_000_000,
          model: "mini",
          name: "Comma Mini",
          offerId: "off_1",
          reporterDeviceId: "dev_phone",
          revision: 1,
          shortId: "A1B2",
          status: "open",
        },
      },
    ]);

    const updated = message(2, {
      actor_type: "system",
      kind: "app_event",
      content: [],
      metadata: { event_type: "device_setup_offer.updated", offer: offer("done", 2) },
    });
    t.stream().named("snapshot", snapshot([offered, updated]));
    await t.time.pass(100);
    expect(t.seqs()).toEqual([1]);
    expect(t.state().messages[0]!.parts).toMatchObject([
      { kind: "device-setup-offer", offer: { status: "done", revision: 2 } },
    ]);
  });
});
