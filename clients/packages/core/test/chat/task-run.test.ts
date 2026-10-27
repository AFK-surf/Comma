import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ChatViewValue } from "../../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../../src/testing/index.ts";

const base = "/v1/comma/groups/grp_1/conversations/cnv_1";
const view = {
  workspace: "wsp_1",
  group: "grp_1",
  conversation: "cnv_1",
  surface: "win_main",
};
const command = {
  message_id: "msg_command",
  seq: 1,
  actor_type: "agent",
  role_label: "delegator",
  kind: "message",
  content: [{ type: "text", text: "Summarise the week." }],
  metadata: { message_type: "task_command" },
};
const blocked = {
  message_id: "msg_blocked",
  seq: 2,
  actor_type: "agent",
  role_label: "worker",
  kind: "message",
  content: [{ type: "text", text: "⚠️ cannot start: no account" }],
  metadata: {
    message_type: "task_run_blocked",
    task_run_blocked: { error: "No account is chosen to run Codex on this computer." },
  },
};
const switched = {
  message_id: "msg_switched",
  seq: 3,
  actor_type: "system",
  kind: "message",
  content: [{ type: "text", text: "A person switched this Task." }],
  metadata: { message_type: "task_run_switched" },
};
const task = (updatedAt: number, messages: unknown[]) => ({
  group_id: "grp_1",
  id: "cnv_1",
  kind: "agent_task",
  title: "Switch me",
  status: "active",
  updated_at: updatedAt,
  messages,
});

// The real core, its clock and its HTTP boundary; startTestCore also replays each run.
describe("a Task's model on the core protocol", () => {
  it("keeps a sandbox Task's run when its sandbox has no repository", async () => {
    const run = {
      place: { kind: "sandbox", state: "starting" },
      model: { kind: "runtime", provider: "claude", name: null, vendor: "anthropic" },
    };
    const host = new FakeHost();
    host.api
      .on("GET", base, { ...task(1, [command]), run })
      .onStream("/v1/comma/groups/grp_1/conversations/events");
    const core = startTestCore(host, { coalesceMs: 0 });
    const client = new CoreClient(inProcessOpener(core, host, view.surface), {
      schedule: () => undefined,
    });
    let shown: ChatViewValue | undefined;
    client.subscribe(
      { topic: "chatView", ...view },
      (value) => (shown = value as ChatViewValue),
      () => undefined
    );
    core.observeSession(signedIn());
    await host.time!.pass(0);
    expect(shown?.state?.taskRun?.place).toEqual({
      kind: "sandbox",
      state: "starting",
    });
    client.close();
  });

  it("shows a coding Task's sandbox from its detail, and again at once when the Task is opened again", async () => {
    const run = {
      place: {
        kind: "sandbox",
        repo: { owner: "acme", name: "api", base_ref: "main", branch: "comma/abc" },
        state: "ready",
      },
      model: {
        kind: "runtime",
        provider: "claude",
        name: "claude-opus-4-5",
        vendor: "anthropic",
      },
    };
    const sandbox = (updatedAt: number) => ({ ...task(updatedAt, [command]), run });
    const host = new FakeHost();
    host.api
      .on("GET", base, sandbox(1))
      .onStream("/v1/comma/groups/grp_1/conversations/events");
    const core = startTestCore(host, { coalesceMs: 0 });
    const client = new CoreClient(inProcessOpener(core, host, view.surface), {
      schedule: () => undefined,
    });
    let shown: ChatViewValue | undefined;
    client.subscribe(
      { topic: "chatView", ...view },
      (value) => (shown = value as ChatViewValue),
      () => undefined
    );
    core.observeSession(signedIn());
    await host.time!.pass(0);
    // No status frame came: the detail alone put the Task on its sandbox.
    expect(shown?.state?.taskRun).toMatchObject({
      place: {
        kind: "sandbox",
        repo: { owner: "acme", name: "api", baseRef: "main", branch: "comma/abc" },
        state: "ready",
      },
      model: { kind: "runtime", provider: "claude", name: "claude-opus-4-5" },
      vendor: "anthropic",
    });
    client.close();

    // Opened again on a detail that says nothing of the run: the sandbox shows from the last time, at once.
    const again = new FakeHost();
    again.api
      .on("GET", base, task(2, [command]))
      .onStream("/v1/comma/groups/grp_1/conversations/events");
    const secondCore = startTestCore(again, { coalesceMs: 0 });
    const secondClient = new CoreClient(
      inProcessOpener(secondCore, again, view.surface),
      {
        schedule: () => undefined,
      }
    );
    let shownAgain: ChatViewValue | undefined;
    secondClient.subscribe(
      { topic: "chatView", ...view },
      (value) => (shownAgain = value as ChatViewValue),
      () => undefined
    );
    secondCore.observeSession(signedIn());
    await again.time!.pass(0);
    expect(shownAgain?.state?.taskRun?.place.kind).toBe("sandbox");
    secondClient.close();
  });

  it("carries what a coding Task's sandbox and GitHub answered last, as its detail has it", async () => {
    const run = {
      place: {
        kind: "sandbox",
        repo: { owner: "acme", name: "api", base_ref: "main", branch: "comma/abc" },
        state: "stopped",
      },
      facts: {
        usage: {
          modelCalls: 36,
          inputTokens: 1_752_000,
          cachedTokens: 1_700_000,
          outputTokens: 9_100,
          model: null,
        },
        changes: { files: 24, additions: 2_676, deletions: 996 },
        pull_request: {
          url: "https://github.com/acme/api/pull/4057",
          number: 4057,
          title: "Continue the release work",
          head_sha: "a".repeat(40),
          state: "open",
          mergeable: "mergeable",
          checks: { passed: 98, total: 100 },
          new_commits: false,
        },
      },
    };
    const host = new FakeHost();
    host.api
      .on("GET", base, { ...task(1, [command]), run })
      .onStream("/v1/comma/groups/grp_1/conversations/events");
    const core = startTestCore(host, { coalesceMs: 0 });
    const client = new CoreClient(inProcessOpener(core, host, view.surface), {
      schedule: () => undefined,
    });
    let shown: ChatViewValue | undefined;
    client.subscribe(
      { topic: "chatView", ...view },
      (value) => (shown = value as ChatViewValue),
      () => undefined
    );
    core.observeSession(signedIn());
    await host.time!.pass(0);
    expect(shown?.state?.taskRun?.facts).toEqual({
      usage: run.facts.usage,
      changes: run.facts.changes,
      pullRequest: {
        url: "https://github.com/acme/api/pull/4057",
        number: 4057,
        title: "Continue the release work",
        body: null,
        headSha: "a".repeat(40),
        state: "open",
        mergeable: "mergeable",
        checks: { passed: 98, failed: 0, skipped: 0, total: 100 },
        newCommits: false,
      },
    });
    client.close();
  });

  it("says the model cannot start, runs the Task on another, and says why one was refused", async () => {
    const host = new FakeHost();
    host.api
      .on("GET", base, task(1, [command, blocked]))
      .onStream("/v1/comma/groups/grp_1/conversations/events");
    const core = startTestCore(host, { coalesceMs: 0 });
    const client = new CoreClient(inProcessOpener(core, host, view.surface), {
      schedule: () => undefined,
    });
    let shown: ChatViewValue | undefined;
    client.subscribe(
      { topic: "chatView", ...view },
      (value) => (shown = value as ChatViewValue),
      () => undefined
    );
    core.observeSession(signedIn());
    await host.time!.pass(0);
    expect(shown?.state?.taskRunBlocked).toEqual({
      messageId: "msg_blocked",
      error: "No account is chosen to run Codex on this computer.",
    });

    // A computer that is not connected takes nothing: the refusal says why, for the UI to word.
    host.api.on(
      "PUT",
      `${base}/run`,
      json(422, {
        error: "task_run_refused",
        code: "task_run_refused",
        reason: "device_offline",
        message: "that station is not connected now",
      })
    );
    await expect(
      client.call("chatView.setTaskRun", {
        ...view,
        run: {
          runsOn: { kind: "station", deviceId: "dev_studio" },
          model: { kind: "runtime", provider: "claude", model: "claude-opus-5-5" },
        },
      })
    ).rejects.toMatchObject({
      status: 422,
      detail: { code: "task_run_refused", reason: "device_offline" },
    });

    // Inside Comma with a catalog model: the Task is read again, and its model no longer stands in the way.
    host.api.on("PUT", `${base}/run`, json(200, task(2, [command, blocked, switched])));
    host.api.on("GET", base, task(2, [command, blocked, switched]));
    await client.call("chatView.setTaskRun", {
      ...view,
      run: { runsOn: { kind: "salix" }, model: { kind: "catalog", model: "gpt-5.5" } },
    });
    await host.time!.pass(0);
    expect(host.api.seen("PUT", `${base}/run`).map((request) => request.body)).toEqual([
      {
        runs_on: { kind: "station", device_id: "dev_studio" },
        model: { kind: "runtime", provider: "claude", model: "claude-opus-5-5" },
      },
      {
        runs_on: { kind: "salix" },
        model: { kind: "catalog", model: "gpt-5.5", allow_paid: true },
      },
    ]);
    expect(shown?.state?.taskRunBlocked).toBeUndefined();
    client.close();
  });
});
