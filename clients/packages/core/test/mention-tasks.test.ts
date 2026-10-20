import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { MentionTask } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
  type SeenRequest,
} from "../src/testing/index.ts";

const workspace = { group_id: "g", id: "wsp", name: "Work", status: "ready" };
const list = "/v1/comma/groups/g/conversations";
const events = "/v1/comma/groups/g/conversations/events";
const menu: Topic = { topic: "mentionTasks", group: "g" };

const conversation = (id: string, extra: Record<string, unknown> = {}) => ({
  group_id: "g",
  id,
  kind: "agent_task",
  status: "running",
  title: `Task ${id}`,
  updated_at: 1,
  ...extra,
});

function setup() {
  const host = new FakeHost();
  // The list in focus asks with a query; the menu's read asks for the Group's list as is.
  let answer: (request: SeenRequest) => unknown = () =>
    json(200, { data: [conversation("t1")] });
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
  host.api.on("GET", list, (request: SeenRequest) =>
    request.path.includes("?") ? json(200, { data: [] }) : answer(request)
  );
  host.api.onStream(events);
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops = new Map<string, () => void>();
  const watch = (topic: Topic) => {
    const key = topicKey(topic);
    stops.set(
      key,
      client.subscribe(
        topic,
        (v) => values.set(key, v),
        () => undefined
      )
    );
    return () => values.get(key) as MentionTask[] | null | undefined;
  };
  const unwatch = (topic: Topic) => stops.get(topicKey(topic))?.();
  core.observeSession(signedIn());
  return {
    time: host.time!,
    api: host.api,
    watch,
    unwatch,
    answer: (next: typeof answer) => (answer = next),
    reads: () => host.api.requests.filter((r) => r.path === list).length,
  };
}

describe("the Tasks a message can mention", () => {
  it("lists a Group's Tasks newest first, and reads them again on a later showing once they are a minute old", async () => {
    const t = setup();
    t.answer(() =>
      json(200, {
        data: [
          conversation("old", { updated_at: 1 }),
          conversation("new", { updated_at: 5 }),
          conversation("chat", { kind: "user_chat" }),
          conversation("archived", { status: "archived" }),
          conversation("untitled", { title: "  " }),
        ],
      })
    );
    const value = t.watch(menu);
    await t.time.pass(100);
    expect(value()).toEqual([
      { id: "new", status: "running", title: "Task new", updatedAt: 5 },
      { id: "old", status: "running", title: "Task old", updatedAt: 1 },
    ]);

    t.unwatch(menu);
    await t.time.pass(30_000, 1_000);
    t.watch(menu);
    await t.time.pass(100);
    expect(t.reads()).toBe(1);

    t.unwatch(menu);
    await t.time.pass(31_000, 1_000);
    t.watch(menu);
    await t.time.pass(100);
    expect(t.reads()).toBe(2);
  });

  it("reads the shown Tasks again when the list in focus is read again, and keeps the last answer meanwhile", async () => {
    const t = setup();
    t.watch({ topic: "tasks", workspace: "" });
    const value = t.watch(menu);
    await t.time.pass(100);
    expect(value()?.map((task) => task.id)).toEqual(["t1"]);

    t.answer(() =>
      json(200, { data: [conversation("t1"), conversation("t2", { updated_at: 2 })] })
    );
    // The list's own read goes first, then the menu's.
    const listRead = t.api.hold("GET", list);
    const menuRead = t.api.hold("GET", list);
    t.api.open(events)!.event({
      type: "conversation_list_invalidated",
      group_id: "g",
      kind: "agent_task",
      version: "2",
    });
    await t.time.pass(100);
    listRead();
    await t.time.pass(100);
    expect(t.reads()).toBe(2);
    expect(value()?.map((task) => task.id)).toEqual(["t1"]);
    menuRead();
    await t.time.pass(100);
    expect(value()?.map((task) => task.id)).toEqual(["t2", "t1"]);
  });

  it("shows no Tasks when the read fails, and asks again on the next showing", async () => {
    const t = setup();
    t.answer(() => offline());
    const value = t.watch(menu);
    await t.time.pass(100);
    expect(value()).toEqual([]);

    t.unwatch(menu);
    t.answer(() => json(200, { data: [conversation("t1")] }));
    t.watch(menu);
    await t.time.pass(100);
    expect(t.reads()).toBe(2);
    expect(value()?.map((task) => task.id)).toEqual(["t1"]);
  });
});
