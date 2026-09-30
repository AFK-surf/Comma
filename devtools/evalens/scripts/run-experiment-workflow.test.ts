import { afterEach, describe, expect, test } from "bun:test";
import { Buffer } from "node:buffer";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import {
  prepareExperimentWorkflow,
  runExperimentWorkflow,
  type ExperimentWorkflowDependencies,
} from "./run-experiment-workflow";

const temporaryDirectories: string[] = [];

function encodeConfig(config: unknown) {
  return Buffer.from(JSON.stringify(config), "utf8").toString("base64");
}

function workflowInput(runnerTemp: string) {
  return {
    EXPERIMENT_NAME: "basic",
    EXPERIMENT_MODULE: "examples/basic.exp.ts",
    EVALENS_REQUEST: JSON.stringify({
      filter: ["case-a"],
      run: { model: "gpt-5.4" },
      eval: {},
    }),
    EVALENS_CONFIG_BASE64: encodeConfig({
      local: { outputDir: "runs" },
      adapters: {
        codex: {
          authJson: {
            auth_mode: "chatgpt",
            tokens: { refresh_token: "refresh-token" },
          },
          env: { CODEX_TEST: "enabled" },
        },
      },
    }),
    RUNNER_TEMP: runnerTemp,
  };
}

async function createTemporaryDirectory() {
  const directory = await mkdtemp(path.join(os.tmpdir(), "evalens-workflow-test-"));
  temporaryDirectories.push(directory);
  return directory;
}

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  );
});

describe("Evalens experiment workflow", () => {
  test("materializes private auth and a sanitized runtime config", async () => {
    const runnerTemp = await createTemporaryDirectory();
    const prepared = await prepareExperimentWorkflow(workflowInput(runnerTemp));

    expect(JSON.parse(await readFile(prepared.configPath, "utf8"))).toEqual({
      concurrency: 1,
      local: { outputDir: "runs" },
      adapters: {
        codex: {
          command: "codex",
          env: { CODEX_TEST: "enabled" },
          sandbox: "workspace-write",
          approvalPolicy: "never",
          skipGitRepoCheck: true,
        },
      },
    });
    expect(
      JSON.parse(await readFile(path.join(prepared.codexHome, "auth.json"), "utf8"))
    ).toEqual({
      auth_mode: "chatgpt",
      tokens: { refresh_token: "refresh-token" },
    });
    expect((await stat(prepared.codexHome)).mode & 0o777).toBe(0o700);
    expect((await stat(prepared.configPath)).mode & 0o777).toBe(0o600);
    expect((await stat(path.join(prepared.codexHome, "auth.json"))).mode & 0o777).toBe(
      0o600
    );
  });

  test("rejects non-allowlisted modules and malformed requests", async () => {
    const runnerTemp = await createTemporaryDirectory();
    await expect(
      prepareExperimentWorkflow({
        ...workflowInput(runnerTemp),
        EXPERIMENT_MODULE: "experiments/tool-calling.exp.ts",
      })
    ).rejects.toThrow("Experiment is not allowlisted");
    await expect(
      prepareExperimentWorkflow({
        ...workflowInput(runnerTemp),
        EVALENS_REQUEST: JSON.stringify({ filter: [], run: {}, eval: {} }),
      })
    ).rejects.toThrow();
  });

  test.each([
    ["salix-tool-calling", "experiments/tool-calling.exp.ts"],
    [
      "salix-openai-context-compression",
      "experiments/context-compression/salix-openai.exp.ts",
    ],
    [
      "salix-summary-context-compression",
      "experiments/context-compression/salix-summary.exp.ts",
    ],
    ["codex-task-completion", "experiments/task-completion/codex.exp.ts"],
    ["salix-task-completion", "experiments/task-completion/salix.exp.ts"],
    ["salix-worker-task-completion", "experiments/task-completion/salix-worker.exp.ts"],
    [
      "slack-agent-workflows-live",
      "experiments/slack-integration/slack-agent-workflows.exp.ts",
    ],
  ])("accepts the allowlisted experiment %s", async (experimentName, module) => {
    const runnerTemp = await createTemporaryDirectory();
    const prepared = await prepareExperimentWorkflow({
      ...workflowInput(runnerTemp),
      EXPERIMENT_NAME: experimentName,
      EXPERIMENT_MODULE: module,
    });

    expect(prepared.experimentPath).toEndWith(module);
  });

  test("checks Codex and invokes Evalens without exposing the config secret", async () => {
    const runnerTemp = await createTemporaryDirectory();
    const calls: Array<{ command: string; args: readonly string[] }> = [];
    const dependencies: ExperimentWorkflowDependencies = {
      runCodex: async (args, environment) => {
        expect(environment.CODEX_HOME).toBe(path.join(runnerTemp, "codex-home"));
        expect(environment.EVALENS_CONFIG_BASE64).toBeUndefined();
        expect(process.env.EVALENS_CONFIG_BASE64).toBeUndefined();
        calls.push({ command: "codex", args });
      },
      runEvalens: async (args, environment) => {
        expect(environment.EVALENS_CONFIG_BASE64).toBeUndefined();
        expect(process.env.EVALENS_CONFIG_BASE64).toBeUndefined();
        calls.push({ command: "evalens", args });
      },
    };

    const prepared = await runExperimentWorkflow(
      workflowInput(runnerTemp),
      dependencies
    );

    expect(calls).toEqual([
      { command: "codex", args: ["--version"] },
      { command: "codex", args: ["login", "status"] },
      {
        command: "evalens",
        args: [
          "run",
          prepared.experimentPath,
          "--config",
          prepared.configPath,
          "--request-file",
          prepared.requestPath,
        ],
      },
    ]);
  });
});
