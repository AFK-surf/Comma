import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { CodingPullRequestValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const WS = "wsp_1";
const SESSION = `/v1/comma/workspaces/${WS}/coding/sessions/cnv_1`;
const CHANGES = `${SESSION}/changes`;
const PR = `${SESSION}/pull-request`;
const HEAD = "b".repeat(40);

/** The branch's pull request as the server answers it. */
const answered = (more: Record<string, unknown> = {}) => ({
  url: "https://github.com/acme/api/pull/7",
  number: 7,
  title: "Back off",
  body: "Make it back off",
  head_sha: HEAD,
  state: "open",
  mergeable: "mergeable",
  checks: { passed: 3, failed: 0, total: 3 },
  new_commits: false,
  ...more,
});

const changes = (pullRequest: unknown) => ({
  source: "sandbox",
  base: "main",
  branch: "comma/retry",
  files: [],
  pull_request: pullRequest,
  commits: [],
  uncommitted: false,
});

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  // Each surface's subscriptions, by topic: a surface going lets go of its own.
  const stops = new Map<string, (() => void)[]>();
  const watch = (topic: Topic) => {
    const key = topicKey(topic);
    const stop = client.subscribe(
      topic,
      (v) => values.set(key, v),
      () => undefined
    );
    stops.set(key, [...(stops.get(key) ?? []), stop]);
    return () => values.get(key) as CodingPullRequestValue | undefined;
  };
  const unwatch = (topic: Topic) => {
    for (const stop of stops.get(topicKey(topic)) ?? []) stop();
    stops.delete(topicKey(topic));
  };
  core.observeSession(signedIn());
  return { client, time: host.time!, api: host.api, watch, unwatch };
}

const shown: Topic = { topic: "codingPullRequest", workspace: WS, task: "cnv_1" };
const watched: Topic = {
  topic: "codingPullRequestWatch",
  workspace: WS,
  task: "cnv_1",
};
const task = { workspaceId: WS, taskId: "cnv_1" };

describe("a coding Task's pull request", () => {
  it("is learned from the whole branch's changes for every surface, and reads asked together share one request", async () => {
    const t = setup();
    t.api.on("GET", CHANGES, changes(answered()));
    const value = t.watch(shown);
    await t.time.pass(100);
    expect(value()).toEqual({ known: false, pr: null, busy: false });

    // The Task panel's line and the prompt read after the same turn: one request answers both.
    const release = t.api.hold("GET", CHANGES);
    const reads = [
      t.client.call("coding.changes", task),
      t.client.call("coding.changes", task),
    ];
    await t.time.pass(100);
    release();
    await Promise.all(reads);
    expect(t.api.seen("GET", CHANGES)).toHaveLength(1);
    await t.time.pass(100);
    expect(value()).toMatchObject({
      known: true,
      busy: false,
      pr: { number: 7, headSha: HEAD, state: "open" },
    });

    // One commit's changes say nothing of the pull request.
    t.api.on("GET", `${CHANGES}?commit=${"a".repeat(40)}`, changes(null));
    await t.client.call("coding.changes", { ...task, commit: "a".repeat(40) });
    await t.time.pass(100);
    expect(value()?.pr?.number).toBe(7);
  });

  it("keeps what a later answer learned: a read that started before a merge does not undo it", async () => {
    const t = setup();
    t.api.on("GET", CHANGES, changes(answered()));
    t.api.on("POST", `${PR}/merge`, {
      method: "squash",
      pull_request: answered({ state: "merged", checks: null }),
    });
    const value = t.watch(shown);
    const release = t.api.hold("GET", CHANGES);
    const before = t.client.call("coding.changes", task);
    await t.time.pass(100);
    await t.client.call("coding.mergePullRequest", {
      ...task,
      number: 7,
      headSha: HEAD,
    });
    release();
    await before;
    await t.time.pass(100);
    expect(value()?.pr?.state).toBe("merged");
  });

  it("runs one request that changes it at a time, busy meanwhile, and refuses another", async () => {
    const t = setup();
    t.api.on("PATCH", PR, { pull_request: answered({ title: "Faster retries" }) });
    t.api.on("POST", `${PR}/merge`, { method: "squash", pull_request: answered() });
    const value = t.watch(shown);
    const release = t.api.hold("PATCH", PR);
    const editing = t.client.call("coding.updatePullRequest", {
      ...task,
      title: "Faster retries",
    });
    await t.time.pass(100);
    expect(value()?.busy).toBe(true);
    await expect(
      t.client.call("coding.mergePullRequest", { ...task, number: 7, headSha: HEAD })
    ).rejects.toMatchObject({ code: "busy" });
    expect(t.api.seen("POST", `${PR}/merge`)).toHaveLength(0);
    release();
    await editing;
    await t.time.pass(100);
    expect(value()).toMatchObject({ busy: false, pr: { title: "Faster retries" } });
  });

  it("shows one just made at once, and reads it again for its head, checks and mergeability", async () => {
    const t = setup();
    t.api.on("POST", PR, {
      url: "https://github.com/acme/api/pull/7",
      number: 7,
      title: "Back off",
    });
    const release = t.api.hold("GET", PR);
    t.api.on("GET", PR, { pull_request: answered({ state: "draft" }) });
    const value = t.watch(shown);
    await t.client.call("coding.pullRequest", { ...task, draft: true });
    await t.time.pass(100);
    expect(value()?.pr).toMatchObject({ number: 7, state: "draft", headSha: null });
    release();
    await t.time.pass(100);
    expect(value()?.pr).toMatchObject({ number: 7, state: "draft", headSha: HEAD });
  });

  it("is read every 30 s while watched and its checks run, and not once they finish or nobody watches", async () => {
    const t = setup();
    let checks = { passed: 1, failed: 0, total: 3 };
    t.api.on("GET", CHANGES, changes(answered({ checks })));
    t.api.on("GET", PR, () => json(200, { pull_request: answered({ checks }) }));
    t.watch(shown);
    await t.client.call("coding.changes", task);
    // Shown but not watched (its window behind): nothing is read on a timer.
    await t.time.pass(90_000);
    expect(t.api.seen("GET", PR)).toHaveLength(0);

    // Two surfaces watch it: one read per 30 s, whatever their number.
    t.watch(watched);
    t.watch({ ...watched });
    await t.time.pass(30_000);
    expect(t.api.seen("GET", PR)).toHaveLength(1);
    await t.time.pass(30_000);
    expect(t.api.seen("GET", PR)).toHaveLength(2);

    // Its checks finish: no more reads.
    checks = { passed: 3, failed: 0, total: 3 };
    await t.time.pass(30_000);
    expect(t.api.seen("GET", PR)).toHaveLength(3);
    await t.time.pass(90_000);
    expect(t.api.seen("GET", PR)).toHaveLength(3);

    // Checks run again (a new push): the watch reads again, until nobody watches.
    checks = { passed: 0, failed: 0, total: 3 };
    await t.client.call("coding.changes", task);
    await t.time.pass(30_000);
    expect(t.api.seen("GET", PR)).toHaveLength(4);
    // Both surfaces go (or their window goes behind): the watch ends with them.
    t.unwatch(watched);
    await t.time.pass(90_000);
    expect(t.api.seen("GET", PR)).toHaveLength(4);
  });
});
