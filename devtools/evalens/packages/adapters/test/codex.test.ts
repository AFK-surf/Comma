import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, test } from "bun:test";
import { CodexAppServerAdapter, CodexCliAdapter } from "@evalens/adapters/codex";

const tempDirs: string[] = [];

afterEach(async () => {
  await Promise.all(
    tempDirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true }))
  );
});

describe.serial("CodexCliAdapter", () => {
  test("runs codex exec in an isolated workspace and collects task artifacts", async () => {
    const fixtureDir = await tempDir("evalens-codex-fixture-");
    await writeFile(join(fixtureDir, "README.md"), "seed\n", "utf8");
    const argsPath = join(await tempDir("evalens-codex-log-"), "args.txt");
    const cwdPath = join(await tempDir("evalens-codex-log-"), "cwd.txt");
    const fakeCodex = await createFakeCodex(`
printf '%s\\n' "$@" > "$EVALENS_FAKE_CODEX_ARGS"
pwd > "$EVALENS_FAKE_CODEX_CWD"
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then
    shift
    out="\${1:-}"
  fi
  shift || true
done
if [ -z "$out" ]; then
  echo "missing --output-last-message" >&2
  exit 9
fi
printf 'final answer' > "$out"
printf 'seed\\nupdated\\n' > README.md
printf 'new\\n' > created.txt
printf '%s\\n' '{"type":"thread.started","thread_id":"thread-123"}' '{"type":"error","message":"soft warning"}' '{"type":"done"}'
printf 'warning\\n' >&2
`);
    const adapter = new CodexCliAdapter({
      command: fakeCodex.command,
      model: "gpt-5",
      profile: "delivery",
      env: {
        ...fakeCodex.env,
        EVALENS_FAKE_CODEX_ARGS: argsPath,
        EVALENS_FAKE_CODEX_CWD: cwdPath,
      },
      configOverrides: ['model_reasoning_effort="low"'],
    });

    const result = await adapter.runTask({
      task: "implement feature",
      fixtureDir,
      files: [{ path: "src/input.txt", content: "hello\n" }],
      model: "gpt-5.1",
      verifyCommand: "test -f created.txt && printf verified",
      metadata: { caseId: "case-a" },
    });

    expect(await realpath((await readFile(cwdPath, "utf8")).trim())).toBe(
      await realpath(result.workspaceDir)
    );
    const args = (await readFile(argsPath, "utf8")).trimEnd().split("\n");
    expect(args).toEqual(
      expect.arrayContaining([
        "exec",
        "--cd",
        result.workspaceDir,
        "--sandbox",
        "workspace-write",
        "--skip-git-repo-check",
        "--ephemeral",
        "--json",
        "--model",
        "gpt-5.1",
        "--profile",
        "delivery",
        "-c",
        'approval_policy="never"',
        "-c",
        'model_reasoning_effort="low"',
      ])
    );
    expect(args.at(-2)).toBe("--");
    expect(args.at(-1)).toBe("implement feature");
    expect(await readFile(join(result.workspaceDir, "src/input.txt"), "utf8")).toBe(
      "hello\n"
    );
    expect(result.finalAnswer).toBe("final answer");
    expect(result.stdout).toContain('"type":"thread.started"');
    expect(result.stderr).toBe("warning\n");
    expect(result.threadId).toBe("thread-123");
    expect(result.codexErrorMessage).toBe("soft warning");
    expect(result.events).toEqual([
      { type: "thread.started", thread_id: "thread-123" },
      { type: "error", message: "soft warning" },
      { type: "done" },
    ]);
    expect(await readFile(join(result.workspaceDir, "README.md"), "utf8")).toBe(
      "seed\nupdated\n"
    );
    expect(await readFile(join(result.workspaceDir, "created.txt"), "utf8")).toBe(
      "new\n"
    );
    expect(result.verifyResult).toMatchObject({
      command: "test -f created.txt && printf verified",
      exitCode: 0,
      stdout: "verified",
    });
    expect(result.metadata).toEqual({ caseId: "case-a" });
  });

  test("rejects inline files that escape the workspace", async () => {
    const workspaceDir = join(
      await tempDir("evalens-codex-workspace-parent-"),
      "workspace"
    );
    const adapter = new CodexCliAdapter();

    await expect(
      adapter.runTask({
        task: "write outside workspace",
        workspaceDir,
        files: [{ path: "../escape.txt", content: "nope" }],
      })
    ).rejects.toThrow("escapes workspace");
  });

  test("rejects an explicit workspaceDir that already exists", async () => {
    const workspaceDir = await tempDir("evalens-codex-workspace-");
    const adapter = new CodexCliAdapter();

    await expect(
      adapter.runTask({
        task: "existing workspace",
        workspaceDir,
      })
    ).rejects.toThrow(/EEXIST|exists/u);
  });

  test("records failing verification without throwing", async () => {
    const workspaceDir = join(
      await tempDir("evalens-codex-workspace-parent-"),
      "workspace"
    );
    const fakeCodex = await createFakeCodex(`
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then
    shift
    out="\${1:-}"
  fi
  shift || true
done
printf 'done' > "$out"
`);
    const adapter = new CodexCliAdapter({
      command: fakeCodex.command,
      env: fakeCodex.env,
      ephemeral: false,
      sandbox: "read-only",
    });

    const result = await adapter.runTask({
      task: "verify failure",
      workspaceDir,
      verifyCommand: "printf checked; printf failed >&2; exit 2",
    });

    expect(result.exitCode).toBe(0);
    expect(result.verifyResult).toMatchObject({
      command: "printf checked; printf failed >&2; exit 2",
      exitCode: 2,
      signal: null,
      stdout: "checked",
      stderr: "failed",
    });
    expect(result.verifyResult?.durationMs).toEqual(expect.any(Number));
  });
});

describe.serial("CodexAppServerAdapter", () => {
  test("configures a prepared workspace and exposes native collaboration state", async () => {
    const workspaceDir = await tempDir("evalens-codex-app-workspace-");
    await mkdir(join(workspaceDir, ".codex", "agents"), { recursive: true });
    await writeFile(
      join(workspaceDir, ".codex", "config.toml"),
      [
        "[agents]",
        "max_threads = 3",
        "max_depth = 1",
        "",
        "[agents.reviewer]",
        'description = "Review the implementation"',
        'config_file = "./agents/reviewer.toml"',
      ].join("\n"),
      "utf8"
    );
    await writeFile(
      join(workspaceDir, ".codex", "agents", "reviewer.toml"),
      [
        'developer_instructions = "Inspect and report defects."',
        'model = "gpt-5.5"',
        'model_reasoning_effort = "medium"',
      ].join("\n"),
      "utf8"
    );
    const requestLogPath = join(
      await tempDir("evalens-codex-app-log-"),
      "requests.jsonl"
    );
    const fakeCodex = await createFakeCodexAppServer(requestLogPath);
    const adapter = new CodexAppServerAdapter({
      command: fakeCodex.command,
      env: fakeCodex.env,
      model: "gpt-5.5",
      sandbox: "workspace-write",
      approvalPolicy: "never",
      ephemeral: false,
    });

    try {
      const thread = await adapter.startThread({
        workspaceDir,
        reasoningEffort: "medium",
        configOverrides: {
          "features.multi_agent": true,
          "agents.max_threads": 3,
          "agents.default_subagent_model": "gpt-5.5",
          "agents.default_subagent_reasoning_effort": "medium",
        },
      });

      expect(thread).toEqual({ threadId: "root-thread", workspaceDir });
      expect(
        await readFile(join(workspaceDir, ".codex", "agents", "reviewer.toml"), "utf8")
      ).toContain('developer_instructions = "Inspect and report defects."');
      expect(
        await readFile(join(workspaceDir, ".codex", "config.toml"), "utf8")
      ).toContain('config_file = "./agents/reviewer.toml"');

      const turn = await adapter.runTurn({
        threadId: thread.threadId,
        message: "Delegate the review.",
        reasoningEffort: "medium",
      });

      expect(turn.answer).toBe("review complete");
      expect(turn).toMatchObject({
        timedOut: false,
        inputTokens: 10,
        outputTokens: 5,
        totalTokens: 15,
        aggregateInputTokens: 17,
        aggregateOutputTokens: 8,
        aggregateTotalTokens: 25,
        usageByThread: {
          "root-thread": { inputTokens: 10, outputTokens: 5, totalTokens: 15 },
          "child-thread": { inputTokens: 7, outputTokens: 3, totalTokens: 10 },
        },
      });
      expect(turn.collaborationEvents).toEqual([
        {
          lifecycle: "started",
          threadId: "root-thread",
          turnId: "turn-1",
          id: "collab-1",
          tool: "spawnAgent",
          status: "inProgress",
          senderThreadId: "root-thread",
          receiverThreadIds: [],
          prompt: "Review the implementation.",
          model: "gpt-5.5",
          reasoningEffort: "medium",
          agentsStates: {},
        },
        {
          lifecycle: "completed",
          threadId: "root-thread",
          turnId: "turn-1",
          id: "collab-1",
          tool: "spawnAgent",
          status: "completed",
          senderThreadId: "root-thread",
          receiverThreadIds: ["child-thread"],
          prompt: "Review the implementation.",
          model: "gpt-5.5",
          reasoningEffort: "medium",
          agentsStates: {
            "child-thread": { status: "completed", message: "looks good" },
          },
        },
      ]);

      const activeTree = await adapter.observeThreadTree(thread.threadId);
      expect(activeTree).toMatchObject({
        settled: false,
        activeThreadIds: ["child-thread"],
        systemErrorThreadIds: [],
        unknownStatusThreadIds: [],
      });
      expect(activeTree.threads).toEqual([
        expect.objectContaining({
          id: "root-thread",
          sessionId: "session-1",
          cwd: workspaceDir,
          turns: expect.any(Array),
        }),
        expect.objectContaining({
          id: "child-thread",
          sessionId: "session-1",
          parentThreadId: "root-thread",
          cwd: workspaceDir,
          agentRole: "reviewer",
          agentNickname: "Ada",
          status: { type: "active", activeFlags: [] },
          turns: expect.any(Array),
        }),
      ]);

      const settledTree = await adapter.observeThreadTree(thread.threadId);
      expect(settledTree.settled).toBe(true);
      expect(settledTree.activeThreadIds).toEqual([]);
      expect(settledTree.trajectories).toEqual([
        expect.objectContaining({
          id: "root-thread",
          steps: expect.arrayContaining([
            expect.objectContaining({ type: "user", content: "Delegate the review." }),
            expect.objectContaining({
              type: "tool_call",
              name: "collaboration.spawnAgent",
            }),
            expect.objectContaining({
              type: "assistant",
              content: "review complete",
              model: "gpt-5.5",
            }),
          ]),
        }),
        expect.objectContaining({
          id: "child-thread",
          steps: expect.arrayContaining([
            expect.objectContaining({
              type: "user",
              content: "Review the implementation.",
            }),
            expect.objectContaining({
              type: "tool_call",
              name: "commandExecution",
            }),
            expect.objectContaining({
              type: "tool_result",
              name: "commandExecution",
              status: "completed",
            }),
            expect.objectContaining({
              type: "assistant",
              content: "looks good",
              model: "gpt-5.5",
            }),
          ]),
        }),
      ]);
      await expect(adapter.compactThread(thread.threadId, 20)).rejects.toThrow(
        "notification timed out"
      );
      await adapter.deleteThread(thread.threadId);
    } finally {
      await adapter.close();
    }

    const requests = (await readFile(requestLogPath, "utf8"))
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line) as Record<string, unknown>);
    for (const method of ["thread/start", "turn/start"]) {
      const request = requests.find((entry) => entry.method === method);
      expect(request).toBeDefined();
      expect(request?.params).not.toHaveProperty("environments");
    }
    expect(requests).toContainEqual(
      expect.objectContaining({
        method: "thread/start",
        params: expect.objectContaining({
          cwd: workspaceDir,
          model: "gpt-5.5",
          approvalPolicy: "never",
          sandbox: "workspace-write",
          ephemeral: false,
          config: expect.objectContaining({
            model_reasoning_effort: "medium",
            "features.multi_agent": true,
            "agents.max_threads": 3,
            "agents.default_subagent_model": "gpt-5.5",
            "agents.default_subagent_reasoning_effort": "medium",
          }),
        }),
      })
    );
    expect(requests).toContainEqual(
      expect.objectContaining({
        method: "thread/list",
        params: expect.objectContaining({
          ancestorThreadId: "root-thread",
        }),
      })
    );
    const descendantListRequest = requests.find(
      (entry) =>
        entry.method === "thread/list" &&
        (entry.params as Record<string, unknown> | undefined)?.ancestorThreadId ===
          "root-thread"
    );
    expect(descendantListRequest?.params).not.toHaveProperty("sourceKinds");
    expect(requests).not.toContainEqual(
      expect.objectContaining({
        method: "thread/read",
        params: expect.objectContaining({ threadId: "unrelated-thread" }),
      })
    );
  });

  test("can return the observed partial turn when completion times out", async () => {
    const workspaceDir = await tempDir("evalens-codex-timeout-workspace-");
    const requestLogPath = join(
      await tempDir("evalens-codex-timeout-log-"),
      "requests.jsonl"
    );
    const fakeCodex = await createFakeCodexAppServer(requestLogPath);
    const adapter = new CodexAppServerAdapter({
      command: fakeCodex.command,
      env: fakeCodex.env,
      model: "gpt-5.5",
      ephemeral: false,
    });

    try {
      const thread = await adapter.startThread({ workspaceDir, ephemeral: false });
      const turn = await adapter.runTurn({
        threadId: thread.threadId,
        message: "Delegate the review.",
        timeoutMs: 1,
        returnOnTimeout: true,
      });

      expect(turn).toMatchObject({
        threadId: "root-thread",
        turnId: "turn-1",
        timedOut: true,
      });
      expect(turn.events).toEqual(
        expect.arrayContaining([expect.objectContaining({ method: "item/started" })])
      );
    } finally {
      await adapter.close();
    }
  });
});

async function tempDir(prefix: string): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), prefix));
  tempDirs.push(dir);
  await mkdir(dir, { recursive: true });
  return dir;
}

async function createFakeCodex(
  body: string
): Promise<{ command: string; env: Record<string, string> }> {
  const binDir = await tempDir("evalens-codex-bin-");
  const commandPath = join(binDir, "fake-codex");
  await writeFile(commandPath, `#!/bin/sh\nset -eu\n${body}\n`, "utf8");
  await chmod(commandPath, 0o755);
  return {
    command: "fake-codex",
    env: {
      PATH: `${binDir}:${process.env["PATH"] ?? ""}`,
    },
  };
}

async function createFakeCodexAppServer(
  requestLogPath: string
): Promise<{ command: string; env: Record<string, string> }> {
  const binDir = await tempDir("evalens-codex-app-bin-");
  const commandPath = join(binDir, "fake-codex-app-server");
  await writeFile(
    commandPath,
    `#!/usr/bin/env bun
import { appendFile } from "node:fs/promises";
import { createInterface } from "node:readline";

const requestLogPath = process.env["EVALENS_FAKE_CODEX_REQUEST_LOG"];
if (!requestLogPath) throw new Error("missing request log path");
let rootCwd = "";
let threadListCalls = 0;

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\\n");
}

const input = createInterface({ input: process.stdin });
input.on("line", async (line) => {
  const message = JSON.parse(line);
  await appendFile(requestLogPath, line + "\\n", "utf8");
  if (typeof message.id !== "number") return;

  if (message.method === "initialize") {
    send({ id: message.id, result: {} });
    return;
  }
  if (message.method === "thread/start") {
    rootCwd = message.params.cwd;
    send({
      id: message.id,
      result: {
        thread: {
          id: "root-thread",
          sessionId: "session-1",
          parentThreadId: null,
          cwd: rootCwd,
          ephemeral: false,
          status: { type: "idle" },
          turns: [],
        },
      },
    });
    return;
  }
  if (message.method === "turn/start") {
    send({
      id: message.id,
      result: { turn: { id: "turn-1", status: "inProgress" } },
    });
    const collab = {
      type: "collabAgentToolCall",
      id: "collab-1",
      tool: "spawnAgent",
      senderThreadId: "root-thread",
      prompt: "Review the implementation.",
      model: "gpt-5.5",
      reasoningEffort: "medium",
    };
    send({
      method: "item/started",
      params: {
        threadId: "root-thread",
        turnId: "turn-1",
        item: {
          ...collab,
          status: "inProgress",
          receiverThreadIds: [],
          agentsStates: {},
        },
      },
    });
    setTimeout(() => {
      send({
        method: "thread/started",
        params: {
          thread: {
            id: "child-thread",
            sessionId: "session-1",
            parentThreadId: "root-thread",
            cwd: rootCwd,
            agentRole: "reviewer",
            agentNickname: "Ada",
            status: { type: "active", activeFlags: [] },
          },
        },
      });
      send({
        method: "item/completed",
        params: {
          threadId: "root-thread",
          turnId: "turn-1",
          item: {
            ...collab,
            status: "completed",
            receiverThreadIds: ["child-thread"],
            agentsStates: {
              "child-thread": { status: "completed", message: "looks good" },
            },
          },
        },
      });
      send({
        method: "thread/tokenUsage/updated",
        params: {
          threadId: "root-thread",
          tokenUsage: {
            total: { inputTokens: 10, outputTokens: 5, totalTokens: 15 },
          },
        },
      });
      send({
        method: "thread/tokenUsage/updated",
        params: {
          threadId: "child-thread",
          tokenUsage: {
            total: { inputTokens: 7, outputTokens: 3, totalTokens: 10 },
          },
        },
      });
      send({
        method: "item/completed",
        params: {
          threadId: "root-thread",
          turnId: "turn-1",
          item: {
            type: "agentMessage",
            id: "answer-1",
            text: "review complete",
          },
        },
      });
      send({
        method: "turn/completed",
        params: {
          threadId: "root-thread",
          turn: { id: "turn-1", status: "completed", durationMs: 42 },
        },
      });
    }, 25);
    return;
  }
  if (message.method === "thread/list") {
    threadListCalls += 1;
    const childActive = threadListCalls === 1;
    send({
      id: message.id,
      result: {
        data: [
          {
            id: "child-thread",
            sessionId: "session-1",
            parentThreadId: "root-thread",
            cwd: rootCwd,
            agentRole: "reviewer",
            agentNickname: "Ada",
            status: childActive
              ? { type: "active", activeFlags: [] }
              : { type: "idle" },
            turns: [],
          },
        ],
        nextCursor: null,
      },
    });
    return;
  }
  if (message.method === "thread/read") {
    const threadId = message.params.threadId;
    const isChild = threadId === "child-thread";
    const childActive = isChild && threadListCalls === 1;
    const turns = isChild
      ? [
          {
            id: "child-turn",
            status: childActive ? "inProgress" : "completed",
            startedAt: 100,
            completedAt: childActive ? null : 101,
            durationMs: childActive ? null : 1_000,
            items: [
              {
                type: "userMessage",
                id: "child-user",
                content: [{ type: "text", text: "Review the implementation." }],
              },
              {
                type: "commandExecution",
                id: "child-command",
                command: "bun test",
                cwd: rootCwd,
                source: "unifiedExec",
                status: childActive ? "inProgress" : "completed",
                aggregatedOutput: childActive ? null : "1 pass",
                exitCode: childActive ? null : 0,
                durationMs: childActive ? null : 100,
              },
              ...(childActive
                ? []
                : [
                    {
                      type: "agentMessage",
                      id: "child-answer",
                      text: "looks good",
                    },
                  ]),
            ],
          },
        ]
      : [
          {
            id: "turn-1",
            status: "completed",
            startedAt: 99,
            completedAt: 102,
            durationMs: 3_000,
            items: [
              {
                type: "userMessage",
                id: "root-user",
                content: [{ type: "text", text: "Delegate the review." }],
              },
              {
                type: "collabAgentToolCall",
                id: "collab-1",
                tool: "spawnAgent",
                status: "completed",
                senderThreadId: "root-thread",
                receiverThreadIds: ["child-thread"],
                prompt: "Review the implementation.",
                model: "gpt-5.5",
                reasoningEffort: "medium",
                agentsStates: {
                  "child-thread": { status: "completed", message: "looks good" },
                },
              },
              {
                type: "agentMessage",
                id: "root-answer",
                text: "review complete",
              },
            ],
          },
        ];
    send({
      id: message.id,
      result: {
        thread: {
          id: threadId,
          sessionId: "session-1",
          parentThreadId: isChild ? "root-thread" : null,
          cwd: rootCwd,
          source: isChild ? "subAgent" : "appServer",
          agentRole: isChild ? "reviewer" : null,
          agentNickname: isChild ? "Ada" : null,
          status: childActive
            ? { type: "active", activeFlags: [] }
            : { type: "idle" },
          createdAt: 99,
          model: "gpt-5.5",
          turns,
        },
      },
    });
    return;
  }
  if (
    message.method === "thread/compact/start" ||
    message.method === "thread/delete"
  ) {
    send({ id: message.id, result: {} });
    return;
  }
  send({
    id: message.id,
    error: { code: -32601, message: "unsupported " + message.method },
  });
});
`,
    "utf8"
  );
  await chmod(commandPath, 0o755);
  return {
    command: "fake-codex-app-server",
    env: {
      PATH: `${binDir}:${process.env["PATH"] ?? ""}`,
      EVALENS_FAKE_CODEX_REQUEST_LOG: requestLogPath,
    },
  };
}
