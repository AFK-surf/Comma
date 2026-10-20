import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TaskWorkersValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const events = "/v1/comma/groups/g/conversations/events";

const statuses = (conversation: string, state: "active" | "stopped", bound = true) => ({
  type: "task_participant_statuses",
  group_id: "g",
  conversation_id: conversation,
  bound_worker: bound
    ? { participant_id: "ptp_worker", actor_id: "actor_worker", name: "Codex Worker" }
    : null,
  participants: [
    {
      conversation_id: conversation,
      participant_id: "ptp_worker",
      name: "Codex Worker",
      actor_role: "worker",
      state,
      status: "",
      updated_at: 1,
    },
  ],
});

function setup(status = 200) {
  const host = new FakeHost();
  host.api.onStream(events, status);
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
    return () => values.get(key) as TaskWorkersValue | undefined;
  };
  const unwatch = (topic: Topic) => stops.get(topicKey(topic))?.();
  core.observeSession(signedIn());
  const feeds = () =>
    host.api.requests
      .filter((r) => r.path.startsWith(`${events}?`))
      .map((r) => new URL(`https://x${r.path}`).searchParams.get("conversation_id"));
  return { time: host.time!, api: host.api, watch, unwatch, feeds };
}

const focus = (ids: string): Topic => ({ topic: "taskWorkers", group: "g", ids });

describe("the Workers a chat's activity focus follows", () => {
  it("follows at most two Tasks, each from its own feed, and shows each bound Worker", async () => {
    const t = setup();
    const value = t.watch(focus("t1,t2,t3"));
    await t.time.pass(100);
    expect(t.feeds()).toEqual(["t1", "t2"]);
    expect(t.api.requests[0]!.path).toContain("wait=30000");

    const [t1, t2] = t.api.streams;
    // The run names the maker of the Worker's model, whose mark stands for it.
    t2!.named("task_participant_statuses", {
      ...statuses("t2", "active"),
      run: {
        place: { kind: "salix" },
        model: { kind: "catalog", name: "Claude Sonnet", vendor: "anthropic" },
      },
    });
    // A snapshot of another Task never lands on this one.
    t1!.named("task_participant_statuses", statuses("t2", "stopped"));
    t1!.named("task_participant_statuses", statuses("t1", "active", false));
    await t.time.pass(100);
    expect(value()).toEqual({
      t1: null,
      t2: {
        active: true,
        avatarId: "actor_worker",
        name: "Codex Worker",
        participantId: "ptp_worker",
        vendor: "anthropic",
      },
    });
  });

  it("reads a finished long-poll again no sooner than a second after it began, keeps the last snapshot, and stops once unshown", async () => {
    const t = setup();
    const value = t.watch(focus("t1"));
    await t.time.pass(100);
    t.api.open(events)!.named("task_participant_statuses", statuses("t1", "active"));
    await t.time.pass(100);
    t.api.open(events)!.end();
    await t.time.pass(500, 100);
    expect(t.feeds()).toHaveLength(1);
    expect(value()?.t1?.active).toBe(true);
    await t.time.pass(500, 100);
    expect(t.feeds()).toHaveLength(2);

    // A long-poll that ran its whole wait reads again at once.
    await t.time.pass(30_000, 1_000);
    t.api.open(events)!.end();
    await t.time.pass(100);
    expect(t.feeds()).toHaveLength(3);

    t.unwatch(focus("t1"));
    await t.time.pass(100);
    expect(t.api.open(events)).toBeUndefined();
    await t.time.pass(30_000, 1_000);
    expect(t.feeds()).toHaveLength(3);
  });

  it("waits 1, 2, 4… up to 15 seconds after failures", async () => {
    const t = setup(503);
    t.watch(focus("t1"));
    await t.time.pass(100);
    const at: number[] = [];
    let seen = t.feeds().length;
    for (let ms = 100; ms <= 50_000; ms += 100) {
      await t.time.pass(100, 100);
      if (t.feeds().length > seen) {
        seen = t.feeds().length;
        at.push(ms);
      }
    }
    // Reads at about 1, 3, 7, 15, 30 and 45 s after the first.
    expect(at.map((ms) => Math.round(ms / 1_000))).toEqual([1, 3, 7, 15, 30, 45]);
  });
});
