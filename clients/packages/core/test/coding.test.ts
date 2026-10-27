import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { CodingChanges, CodingHistory } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const WS = "wsp_1";
const BASE = `/v1/comma/workspaces/${WS}/coding`;

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn());
  return { host, client };
}

/** A tool call as the station sends it: its arguments as pretty JSON. */
const toolCall = (id: string, tool: string, args: unknown, at: string) => ({
  at,
  kind: "tool_call",
  text: JSON.stringify(args, null, 2),
  tool,
  callId: id,
});

describe("coding sessions", () => {
  it("lists the account's repositories and a repository's branches, a page at a time", async () => {
    const t = setup();
    t.host.api
      .on("GET", `${BASE}/repos`, {
        repos: [
          {
            owner: "acme",
            name: "api",
            default_branch: "main",
            private: true,
            pushed_at: "2026-10-01",
          },
        ],
      })
      .on("GET", `${BASE}/repos/acme/api/branches`, {
        branches: ["main", "release/2.1"],
      });

    expect(await t.client.call("coding.repos", { workspaceId: WS })).toEqual([
      { owner: "acme", name: "api", defaultBranch: "main", private: true },
    ]);
    expect(
      await t.client.call("coding.branches", {
        workspaceId: WS,
        owner: "acme",
        name: "api",
        page: 2,
      })
    ).toEqual(["main", "release/2.1"]);
    expect(t.host.api.requests.map((r) => r.path)).toContain(
      `${BASE}/repos/acme/api/branches?page=2`
    );
  });

  it("starts a session once per key, with its repository and runtime, as the person's", async () => {
    const t = setup();
    t.host.api.on(
      "POST",
      `${BASE}/sessions`,
      json(201, { task_id: "cnv_1", group_id: "grp_1" })
    );
    const made = await t.client.call("coding.start", {
      workspaceId: WS,
      key: "k1",
      text: "Fix the flaky retry test",
      repo: { owner: "acme", name: "api", baseRef: "main" },
      model: { provider: "claude" },
    });
    expect(made).toEqual({ taskId: "cnv_1", groupId: "grp_1" });
    expect(t.host.api.requests.at(-1)?.body).toEqual({
      client_request_id: "k1",
      text: "Fix the flaky retry test",
      repo: { owner: "acme", name: "api", base_ref: "main" },
      model: { provider: "claude" },
    });
  });

  it("says why a session did not start: no GitHub account connected", async () => {
    const t = setup();
    t.host.api.on(
      "POST",
      `${BASE}/sessions`,
      json(409, { error: "github_not_connected" })
    );
    await expect(
      t.client.call("coding.start", {
        workspaceId: WS,
        key: "k2",
        text: "go",
        repo: { owner: "acme", name: "api" },
      })
    ).rejects.toMatchObject({ code: "github_not_connected" });
  });

  it("reads where a session stands, its changes, and makes a pull request and a terminal link", async () => {
    const t = setup();
    t.host.api
      .on("GET", `${BASE}/sessions/cnv_1`, {
        repo: { owner: "acme", name: "api", base_ref: "main", branch: "comma/x" },
        state: "stopped",
        reason: null,
      })
      .on("GET", `${BASE}/sessions/cnv_1/changes`, {
        source: "github",
        truncated: false,
        files: [
          {
            path: "a.ts",
            status: "modified",
            additions: 2,
            deletions: 1,
            patch: "@@ -1 +1,2 @@",
          },
        ],
        commits: [
          {
            sha: "a".repeat(40),
            title: "Back off",
            author: "Ann",
            at: "2026-10-23T10:00:00Z",
          },
        ],
        uncommitted: false,
        // An older sandbox counts no failed or skipped checks.
        pull_request: {
          url: "https://github.com/acme/api/pull/7",
          number: 7,
          title: "Retry with backoff",
          state: "open",
          mergeable: "conflicting",
          checks: { passed: 1, total: 2 },
        },
      })
      .on("POST", `${BASE}/sessions/cnv_1/pull-request`, {
        url: "https://github.com/acme/api/pull/7",
        number: 7,
        title: "Retry with backoff",
      })
      .on("POST", `${BASE}/sessions/cnv_1/terminal`, {
        url: "https://l4es.test/c#a=x&sandbox=t-1-g1",
      });

    expect(
      await t.client.call("coding.session", { workspaceId: WS, taskId: "cnv_1" })
    ).toEqual({
      repo: { owner: "acme", name: "api", baseRef: "main", branch: "comma/x" },
      state: "stopped",
      reason: null,
    });
    const changes = (await t.client.call("coding.changes", {
      workspaceId: WS,
      taskId: "cnv_1",
    })) as CodingChanges;
    expect(changes.source).toBe("github");
    expect(changes.files[0]).toEqual({
      path: "a.ts",
      status: "modified",
      additions: 2,
      deletions: 1,
      patch: "@@ -1 +1,2 @@",
    });
    expect(changes.pullRequest).toEqual({
      url: "https://github.com/acme/api/pull/7",
      number: 7,
      title: "Retry with backoff",
      body: null,
      headSha: null,
      state: "open",
      mergeable: "conflicting",
      checks: { passed: 1, failed: 0, skipped: 0, total: 2 },
      newCommits: false,
    });
    expect(changes.commits).toEqual([
      {
        sha: "a".repeat(40),
        title: "Back off",
        author: "Ann",
        at: "2026-10-23T10:00:00Z",
      },
    ]);
    // One commit, or what is not committed, is asked for by name; a short sha is not sent.
    await t.client.call("coding.changes", {
      workspaceId: WS,
      taskId: "cnv_1",
      commit: "a".repeat(40),
    });
    expect(t.host.api.requests.at(-1)?.path).toBe(
      `${BASE}/sessions/cnv_1/changes?commit=${"a".repeat(40)}`
    );
    await t.client.call("coding.changes", {
      workspaceId: WS,
      taskId: "cnv_1",
      uncommitted: true,
    });
    expect(t.host.api.requests.at(-1)?.path).toBe(
      `${BASE}/sessions/cnv_1/changes?uncommitted=1`
    );
    await t.client.call("coding.changes", {
      workspaceId: WS,
      taskId: "cnv_1",
      commit: "aaaaaaa",
    });
    expect(t.host.api.requests.at(-1)?.path).toBe(`${BASE}/sessions/cnv_1/changes`);
    expect(
      await t.client.call("coding.pullRequest", {
        workspaceId: WS,
        taskId: "cnv_1",
        draft: true,
      })
    ).toEqual({
      url: "https://github.com/acme/api/pull/7",
      number: 7,
      title: "Retry with backoff",
    });
    expect(
      t.host.api.seen("POST", `${BASE}/sessions/cnv_1/pull-request`).at(-1)?.body
    ).toEqual({
      draft: true,
    });
    expect(
      await t.client.call("coding.terminal", { workspaceId: WS, taskId: "cnv_1" })
    ).toEqual({
      url: "https://l4es.test/c#a=x&sandbox=t-1-g1",
    });
  });

  it("edits, makes ready and merges the branch's pull request on GitHub, sandbox or not", async () => {
    const t = setup();
    const merged = {
      url: "https://github.com/acme/api/pull/7",
      number: 7,
      title: "Back off between retries",
      body: "",
      head_sha: "b".repeat(40),
      state: "merged",
      mergeable: "unknown",
      checks: null,
      new_commits: true,
    };
    t.host.api
      .on("PATCH", `${BASE}/sessions/cnv_1/pull-request`, {
        pull_request: { ...merged, state: "open", new_commits: false },
      })
      .on("POST", `${BASE}/sessions/cnv_1/pull-request/merge`, {
        method: "squash",
        pull_request: merged,
      });

    const edited = await t.client.call("coding.updatePullRequest", {
      workspaceId: WS,
      taskId: "cnv_1",
      title: "Back off between retries",
      body: "",
      ready: true,
    });
    // A cleared description is sent as it is.
    expect(t.host.api.requests.at(-1)?.body).toEqual({
      title: "Back off between retries",
      body: "",
      ready: true,
    });
    expect(edited).toMatchObject({ state: "open", body: "", newCommits: false });
    // A merge names the pull request confirmed and the head it was at; without them nothing is sent.
    await expect(
      t.client.call("coding.mergePullRequest", {
        workspaceId: WS,
        taskId: "cnv_1",
        number: 7,
        headSha: "bbbbbbb",
      })
    ).rejects.toThrow();
    expect(t.host.api.requests.at(-1)?.method).toBe("PATCH");
    expect(
      await t.client.call("coding.mergePullRequest", {
        workspaceId: WS,
        taskId: "cnv_1",
        number: 7,
        headSha: "b".repeat(40),
      })
    ).toEqual({
      method: "squash",
      pullRequest: {
        url: "https://github.com/acme/api/pull/7",
        number: 7,
        title: "Back off between retries",
        body: "",
        headSha: "b".repeat(40),
        state: "merged",
        mergeable: "unknown",
        checks: null,
        newCommits: true,
      },
    });
    expect(t.host.api.requests.at(-1)?.body).toEqual({
      number: 7,
      head_sha: "b".repeat(40),
    });
  });

  it("reads a page of a session's execution history as items: what was said, steps grouped, the agent's words", async () => {
    const t = setup();
    t.host.api.on("GET", `${BASE}/sessions/cnv_1/history`, {
      available: true,
      start: 10,
      total: 18,
      entries: [
        { at: "2026-10-22T00:00:00Z", kind: "user", text: "fix the flaky test" },
        {
          at: "2026-10-22T00:00:01Z",
          kind: "thinking",
          text: "Look at the test first.",
        },
        toolCall(
          "c1",
          "Bash",
          { command: "bash -lc 'npm test'" },
          "2026-10-22T00:00:02Z"
        ),
        {
          at: "2026-10-22T00:00:05Z",
          kind: "tool_result",
          text: "1 failing",
          ok: false,
          callId: "c1",
        },
        toolCall(
          "c2",
          "Edit",
          { file_path: "src/a.ts", old_string: "a\nb\nc", new_string: "a\nB\nc" },
          "2026-10-22T00:00:06Z"
        ),
        {
          at: "2026-10-22T00:00:06Z",
          kind: "tool_result",
          text: "ok",
          ok: true,
          callId: "c2",
        },
        toolCall(
          "c3",
          "Read",
          { file_path: "src/b.ts", offset: 10, limit: 20 },
          "2026-10-22T00:00:07Z"
        ),
        {
          at: "2026-10-22T00:00:08Z",
          kind: "assistant",
          text: "Fixed the flaky test.",
        },
      ],
      usage: {
        modelCalls: 3,
        inputTokens: 900,
        cachedTokens: 600,
        outputTokens: 50,
        model: "gpt-5.6-sol",
      },
    });

    const page = (await t.client.call("coding.history", {
      workspaceId: WS,
      taskId: "cnv_1",
    })) as CodingHistory;
    expect(page.start).toBe(10);
    expect(page.usage?.cachedTokens).toBe(600);
    expect(page.items.map((i) => i.kind)).toEqual(["received", "group", "text"]);
    const group = page.items[1]!;
    if (group.kind !== "group") throw new Error("not a group");
    expect(group.failures).toBe(1);
    // The Read was cut off by the agent's answer: no result, still pending.
    expect(group.pending).toBe(1);
    expect(group.steps.map((s) => s.kind)).toEqual([
      "thinking",
      "tool",
      "tool",
      "tool",
    ]);
    expect(group.steps[1]).toMatchObject({
      tool: "Bash",
      hint: "'npm test'",
      body: { kind: "command", command: "'npm test'" },
      result: "1 failing",
      failed: true,
      durationMs: 3000,
    });
    expect(group.steps[2]).toMatchObject({
      hint: "src/a.ts",
      body: { kind: "edit", path: "src/a.ts", diff: " a\n-b\n+B\n c" },
    });
    expect(group.steps[3]).toMatchObject({
      body: { kind: "read", path: "src/b.ts", lines: "10–30" },
      pending: true,
    });
    // Ids are the entries' indexes, so a page read before this one joins it without clashes.
    expect(page.items[0]!.id).toBe("h10");

    // Earlier entries are read before the page's start.
    await t.client.call("coding.history", {
      workspaceId: WS,
      taskId: "cnv_1",
      before: 10,
    });
    expect(t.host.api.requests.at(-1)?.path).toBe(
      `${BASE}/sessions/cnv_1/history?before=10`
    );
  });
});
