import { Buffer } from "node:buffer";
import { chmod, mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";

import { EvalensConfigSchema, parseCliExperimentRequest, runCli } from "@evalens/cli";

const EVALENS_ROOT = path.resolve(import.meta.dirname, "..");
const BASE64_PATTERN =
  /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const ALLOWLISTED_EXPERIMENTS = new Map([
  ["basic", "examples/basic.exp.ts"],
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
]);

const WorkflowInputSchema = z
  .object({
    EXPERIMENT_NAME: z.string().min(1),
    EXPERIMENT_MODULE: z.string().min(1),
    EVALENS_REQUEST: z.string().min(1),
    EVALENS_CONFIG_BASE64: z.string().min(1),
    RUNNER_TEMP: z.string().min(1),
  })
  .strict();

const CodexAuthJsonSchema = z
  .object({
    auth_mode: z.literal("chatgpt"),
    tokens: z
      .object({
        refresh_token: z.string().min(1),
      })
      .loose(),
  })
  .loose();

type CommandEnvironment = Record<string, string | undefined>;

export interface ExperimentWorkflowDependencies {
  runCodex(args: readonly string[], environment: CommandEnvironment): Promise<void>;
  runEvalens(args: readonly string[], environment: CommandEnvironment): Promise<void>;
}

export interface PreparedExperimentWorkflow {
  codexHome: string;
  configPath: string;
  experimentPath: string;
  requestPath: string;
}

function parseJson(value: string, label: string): unknown {
  try {
    return JSON.parse(value);
  } catch {
    throw new Error(`${label} must be valid JSON`);
  }
}

function decodeConfig(encodedConfig: string): unknown {
  if (!BASE64_PATTERN.test(encodedConfig)) {
    throw new Error("EVALENS_CONFIG_BASE64 must be valid base64");
  }

  let configText: string;
  try {
    configText = new TextDecoder("utf-8", { fatal: true }).decode(
      Buffer.from(encodedConfig, "base64")
    );
  } catch {
    throw new Error("decoded Evalens config must be valid UTF-8");
  }
  if (configText.length === 0) {
    throw new Error("decoded Evalens config must not be empty");
  }
  return parseJson(configText, "decoded Evalens config");
}

async function writePrivateJson(filePath: string, value: unknown) {
  await writeFile(filePath, `${JSON.stringify(value)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  await chmod(filePath, 0o600);
}

export async function prepareExperimentWorkflow(
  rawInput: unknown
): Promise<PreparedExperimentWorkflow> {
  const input = WorkflowInputSchema.parse(rawInput);
  if (ALLOWLISTED_EXPERIMENTS.get(input.EXPERIMENT_NAME) !== input.EXPERIMENT_MODULE) {
    throw new Error(`Experiment is not allowlisted: ${input.EXPERIMENT_NAME}`);
  }

  const config = EvalensConfigSchema.parse(decodeConfig(input.EVALENS_CONFIG_BASE64));
  const codexConfig = config.adapters?.codex;
  if (!codexConfig) {
    throw new Error("Evalens config must contain adapters.codex");
  }
  const { authJson, ...runtimeCodexConfig } = codexConfig;
  const codexAuthJson = CodexAuthJsonSchema.parse(authJson);
  const runtimeConfig = {
    ...config,
    adapters: {
      ...config.adapters,
      codex: runtimeCodexConfig,
    },
  };
  const request = parseCliExperimentRequest(
    parseJson(input.EVALENS_REQUEST, "EVALENS_REQUEST")
  );

  const codexHome = path.join(input.RUNNER_TEMP, "codex-home");
  const configPath = path.join(input.RUNNER_TEMP, "evalens.config.json");
  const requestPath = path.join(input.RUNNER_TEMP, "evalens.request.json");
  await mkdir(codexHome, { recursive: true, mode: 0o700 });
  await chmod(codexHome, 0o700);
  await writePrivateJson(path.join(codexHome, "auth.json"), codexAuthJson);
  await writePrivateJson(configPath, runtimeConfig);
  await writePrivateJson(requestPath, request);

  return {
    codexHome,
    configPath,
    experimentPath: path.join(EVALENS_ROOT, input.EXPERIMENT_MODULE),
    requestPath,
  };
}

async function runCommand(
  command: string,
  args: readonly string[],
  environment: CommandEnvironment
) {
  const subprocess = Bun.spawn([command, ...args], {
    cwd: EVALENS_ROOT,
    env: environment,
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const exitCode = await subprocess.exited;
  if (exitCode !== 0) {
    throw new Error(`${command} ${args.join(" ")} exited with code ${exitCode}`);
  }
}

async function runEvalens(args: readonly string[]) {
  await runCli([...args]);
}

const defaultDependencies: ExperimentWorkflowDependencies = {
  runCodex: (args, environment) => runCommand("codex", args, environment),
  runEvalens,
};

export async function runExperimentWorkflow(
  rawInput: unknown,
  dependencies: ExperimentWorkflowDependencies = defaultDependencies
) {
  const prepared = await prepareExperimentWorkflow(rawInput);
  const runtimeEnvironment: CommandEnvironment = {
    ...process.env,
    CODEX_HOME: prepared.codexHome,
  };
  delete runtimeEnvironment.EVALENS_CONFIG_BASE64;

  const previousCodexHome = process.env.CODEX_HOME;
  const previousEncodedConfig = process.env.EVALENS_CONFIG_BASE64;
  try {
    process.env.CODEX_HOME = prepared.codexHome;
    delete process.env.EVALENS_CONFIG_BASE64;
    await dependencies.runCodex(["--version"], runtimeEnvironment);
    await dependencies.runCodex(["login", "status"], runtimeEnvironment);
    await dependencies.runEvalens(
      [
        "run",
        prepared.experimentPath,
        "--config",
        prepared.configPath,
        "--request-file",
        prepared.requestPath,
      ],
      runtimeEnvironment
    );
    return prepared;
  } finally {
    if (previousCodexHome === undefined) delete process.env.CODEX_HOME;
    else process.env.CODEX_HOME = previousCodexHome;
    if (previousEncodedConfig === undefined) {
      delete process.env.EVALENS_CONFIG_BASE64;
    } else {
      process.env.EVALENS_CONFIG_BASE64 = previousEncodedConfig;
    }
  }
}

function workflowInputFromEnvironment() {
  return {
    EXPERIMENT_NAME: process.env.EXPERIMENT_NAME,
    EXPERIMENT_MODULE: process.env.EXPERIMENT_MODULE,
    EVALENS_REQUEST: process.env.EVALENS_REQUEST,
    EVALENS_CONFIG_BASE64: process.env.EVALENS_CONFIG_BASE64,
    RUNNER_TEMP: process.env.RUNNER_TEMP,
  };
}

function githubErrorMessage(error: unknown) {
  const message = error instanceof Error ? error.message : "Unknown workflow error";
  return message.replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A");
}

if (import.meta.main) {
  try {
    await runExperimentWorkflow(workflowInputFromEnvironment());
  } catch (error) {
    console.error(`::error::${githubErrorMessage(error)}`);
    process.exitCode = 1;
  }
}
