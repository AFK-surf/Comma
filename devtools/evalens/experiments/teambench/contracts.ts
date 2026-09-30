import { z } from "zod";

import {
  DEFAULT_TEAM_BENCH_CONNECTOR_SERVER,
  DEFAULT_TEAM_BENCH_RUNTIME_IMAGE,
  TEAM_BENCH_SALIX_ENVIRONMENT_ALIAS,
} from "./runtime";

export const TEAM_BENCH_MODEL = "gpt-5.5";
export const TEAM_BENCH_REASONING_EFFORT = "medium";
export const TEAM_BENCH_NATIVE_FULL_PROMPT_PROFILE = "model-neutral-v1";
export const TEAM_BENCH_NATIVE_PROMPT_PROFILE = "model-neutral-tool-semantic-only-v1";
export const TEAM_BENCH_NATIVE_PROMPT_PROFILES = [
  TEAM_BENCH_NATIVE_FULL_PROMPT_PROFILE,
  TEAM_BENCH_NATIVE_PROMPT_PROFILE,
] as const;
export const TEAM_BENCH_SOURCE_REVISION = "d185aef1916fd86a9ba554d581fd256319a973af";
export const TEAM_BENCH_SOURCE_URL = "https://github.com/ybkim95/TeamBench.git";

export const TeamBenchNativeRunParams = z
  .object({
    model: z.string().min(1).default(TEAM_BENCH_MODEL),
    reasoningEffort: z.string().min(1).default(TEAM_BENCH_REASONING_EFFORT),
    promptProfile: z
      .enum(TEAM_BENCH_NATIVE_PROMPT_PROFILES)
      .default(TEAM_BENCH_NATIVE_PROMPT_PROFILE),
    timeoutMs: z.number().int().positive().default(1_800_000),
    traceLimit: z.number().int().positive().max(500).default(500),
    maxArtifactFiles: z.number().int().positive().default(20_000),
    maxArtifactBytes: z.number().int().positive().default(1_073_741_824),
    runtimeImage: z.string().min(1).default(DEFAULT_TEAM_BENCH_RUNTIME_IMAGE),
    salixConnectorServer: z.url().default(DEFAULT_TEAM_BENCH_CONNECTOR_SERVER),
    salixConnectTimeoutMs: z.number().int().positive().default(30_000),
    graderTimeoutMs: z.number().int().positive().default(300_000),
  })
  .strict();

export type TeamBenchNativeRunParams = z.infer<typeof TeamBenchNativeRunParams>;

export type TeamBenchTarget = "salix" | "codex";
export type TeamBenchRole = "planner" | "executor" | "verifier";

export type TeamBenchAgentRecord = {
  role: TeamBenchRole;
  agentId: string;
  sessionIds: string[];
};

type TeamBenchResultBase = {
  target: TeamBenchTarget;
  itemId: string;
  taskId: string;
  seed: number;
  sourceRevision: string;
  model: string;
  reasoningEffort: string;
  answer: string;
  timedOut: boolean;
  agents: TeamBenchAgentRecord[];
  artifactLayout: {
    workspaceRoot: string;
    submissionRoot: string;
  };
  executionEnvironment: {
    kind: "salix-local-docker" | "codex-local-workspace";
    environmentId?: string;
    deviceId?: string;
    alias?: string;
    image?: string;
    graderTimeoutMs?: number;
  };
  usage: {
    scope: "planner" | "thread_tree";
    inputTokens: number;
    outputTokens: number;
    totalTokens: number;
  };
};

type TeamBenchCollaboration = {
  delegated: boolean;
  topologySatisfied: boolean;
  protocolViolations: string[];
  settledAtPlannerReturn: boolean | null;
  activeWorkerIds: string[];
  systemErrorWorkerIds: string[];
  unknownWorkerStateIds: string[];
};

export type TeamBenchNativeResult = TeamBenchResultBase & {
  protocol: "native";
  collaboration: TeamBenchCollaboration;
};

export type TeamBenchRunResult = TeamBenchNativeResult;

const SALIX_EXECUTOR_ENVIRONMENT_GUIDANCE = `The group has a connector-backed Linux environment whose alias is "${TEAM_BENCH_SALIX_ENVIRONMENT_ALIAS}" and whose initial /workspace mirrors your initial VFS /workspace. Your VFS remains the authoritative submission. Edit files with VFS fs tools. Before testing, use device.list to find that device and device.get to select its command environment. Retain the device_id and environment_id and supply both identities with every remote operation. Use env.copy to copy every file you created or changed from VFS into its /workspace, and use env.exec to run commands there. Never leave a final deliverable only in the remote environment. If the expected environment is absent, report an infrastructure failure instead of pretending tests passed.
`;

const SALIX_VERIFIER_ENVIRONMENT_GUIDANCE = `The group has a connector-backed Linux environment whose alias is "${TEAM_BENCH_SALIX_ENVIRONMENT_ALIAS}" and whose initial /workspace mirrors the initial task workspace. After copying each Executor deliverable into your VFS, use device.list to find that device and device.get to select its command environment. Retain the device_id and environment_id and supply both identities with every remote operation. Use env.copy to copy the deliverables into its /workspace, and use env.exec to run verification commands there. Do not implement fixes and do not leave the attestation only in the remote environment. If the expected environment is absent, record an infrastructure failure instead of pretending tests passed.
`;

const SALIX_FULL_EXECUTOR_ENVIRONMENT_GUIDANCE = `The group has a connector-backed Linux environment whose alias is "${TEAM_BENCH_SALIX_ENVIRONMENT_ALIAS}" and whose initial /workspace mirrors your initial VFS /workspace. Your VFS remains the authoritative submission. Edit files with VFS fs tools. Before testing, call device.list, select the device with that alias, and call device.get with its device_id to select the command environment. Retain both device_id and environment_id. For env.exec supply device_id and environment=environment_id; for VFS-to-device env.copy also supply dst_device_id. Then copy every file you created or changed from VFS to the same absolute /workspace path in that environment with env.copy. Run commands there with env.exec and working_dir="/workspace"; every env.exec description must be at most 19 characters. Never call env.exec with environment="vfs" and never leave a final deliverable only in the remote environment. If the expected environment is absent, report an infrastructure failure instead of pretending tests passed.
`;

const SALIX_FULL_VERIFIER_ENVIRONMENT_GUIDANCE = `The group has a connector-backed Linux environment whose alias is "${TEAM_BENCH_SALIX_ENVIRONMENT_ALIAS}" and whose initial /workspace mirrors the initial task workspace. After copying each Executor deliverable into your VFS, call device.list, select the device with that alias, and call device.get with its device_id to select the command environment. Retain both device_id and environment_id. For env.exec supply device_id and environment=environment_id; for VFS-to-device env.copy also supply dst_device_id. Copy each deliverable from your VFS to the same absolute /workspace path in that environment. Run verification commands with env.exec and working_dir="/workspace"; every env.exec description must be at most 19 characters. Never call env.exec with environment="vfs". Do not implement fixes and do not leave the attestation only in the remote environment. If the expected environment is absent, record an infrastructure failure instead of pretending tests passed.
`;

const PLANNER_CORE = `You are the Planner and the only user-facing agent in a native TeamBench team.

The team already has exactly two worker roles: Executor and Verifier. Delegate implementation to Executor, then independent validation to Verifier. Do not implement, edit files, run tests, or produce the attestation yourself.

Before delegating, read /task/spec.md, /task/brief.md, and every public task input that exists under /task. Project paths named by the spec are under /workspace, not /task. Turn the requirements into a task-specific, actionable delegation with exact input and output paths, behavior, edge cases, acceptance criteria, and checks. A declared exception must observably override the ordinary rule; explain any ambiguity and require Verifier to check the chosen interpretation.`;

const PLANNER_FINISH = `Only after Executor reports completion, delegate Verifier. Identify Executor and every expected deliverable path, and provide a task-specific validation plan covering relevant requirements, edge cases, changed paths, tests, and /submission/attestation.json. Evalens will not copy files or inject follow-up messages after this turn starts.

Return only after both workers finish and Verifier reports its verdict. Summarize the result and remaining concerns.`;

function salixPlannerPrompt(toolGuidance: string): string {
  return `${PLANNER_CORE}\n\n${toolGuidance}\n\n${PLANNER_FINISH}`;
}

function salixExecutorPrompt(environment: string, reporting: string): string {
  return `You are the Executor in a native TeamBench team.

Read /task/brief.md and inspect /workspace. Project files and supporting documents named by the spec are under /workspace, not /task. Use fs.list_files to resolve a path before reading it. Implement the task in /workspace. Do not make the acceptance decision or write /submission/attestation.json.

${environment}

When finished, report a concise summary, checks, and every changed file. ${reporting}
Keep completed files in your authoritative /workspace for Verifier.`;
}

function salixVerifierPrompt(
  handoff: string,
  environment: string,
  reporting: string
): string {
  return `You are the Verifier in a native TeamBench team.

Read /task/spec.md. Project files and supporting documents named by the spec are under /workspace, not /task. Use fs.list_files to resolve a path before reading it. ${handoff} Inspect the result and run independent checks. Do not implement fixes.

${environment}

Write /submission/attestation.json as valid JSON containing at least:
{"verdict":"pass"|"fail","summary":"...","tests":[{"command":"...","result":"..."}],"concerns":["..."]}

${reporting}`;
}

export const PLANNER_PROMPT = salixPlannerPrompt(
  `Use agent.list once to identify the two preconfigured workers: first Executor, then Verifier. Delegate with im_api.internal.task.create using connect_id="internal" and wait for each visible task response. Tell Verifier to copy Executor deliverables into its VFS with env.copy.`
);
export const FULL_PLANNER_PROMPT = salixPlannerPrompt(
  `Use agent.list once to identify the two preconfigured workers: first Executor, then Verifier. Invoke every Salix business tool through the outer call tool with non-empty arguments. Delegate with {"tool":"im_api.internal.task.create","params":{"connect_id":"internal","agent_id":"<worker agent_id>","content":"<complete instruction>"}} and wait for each visible response. Tell Verifier to use env.copy with src_environment="vfs", dst_environment="vfs", and src_agent_ref_id=<executor ref>.`
);
export const EXECUTOR_PROMPT = salixExecutorPrompt(
  SALIX_EXECUTOR_ENVIRONMENT_GUIDANCE,
  "Send it to Planner through the inbound task conversation with im_api.internal.send_message."
);
export const FULL_EXECUTOR_PROMPT = salixExecutorPrompt(
  SALIX_FULL_EXECUTOR_ENVIRONMENT_GUIDANCE,
  `Send it through the outer call tool as {"tool":"im_api.internal.send_message","params":{"connect_id":"internal","conversation_id":"<inbound conversation id>","content":"<completion report>"}}.`
);
export const VERIFIER_PROMPT = salixVerifierPrompt(
  "Use env.copy to copy every deliverable identified by Planner from Executor's VFS into your VFS.",
  SALIX_VERIFIER_ENVIRONMENT_GUIDANCE,
  "Report the verdict and evidence to Planner through the inbound task conversation with im_api.internal.send_message."
);
export const FULL_VERIFIER_PROMPT = salixVerifierPrompt(
  'For every deliverable identified by Planner, call env.copy with src_environment="vfs", dst_environment="vfs", src_agent_ref_id set to Executor, and matching source/destination paths.',
  SALIX_FULL_VERIFIER_ENVIRONMENT_GUIDANCE,
  `Report through the outer call tool as {"tool":"im_api.internal.send_message","params":{"connect_id":"internal","conversation_id":"<inbound conversation id>","content":"<verdict and evidence>"}}.`
);

export function salixNativePrompts(
  profile: (typeof TEAM_BENCH_NATIVE_PROMPT_PROFILES)[number]
): { planner: string; executor: string; verifier: string } {
  return profile === TEAM_BENCH_NATIVE_FULL_PROMPT_PROFILE
    ? {
        planner: FULL_PLANNER_PROMPT,
        executor: FULL_EXECUTOR_PROMPT,
        verifier: FULL_VERIFIER_PROMPT,
      }
    : {
        planner: PLANNER_PROMPT,
        executor: EXECUTOR_PROMPT,
        verifier: VERIFIER_PROMPT,
      };
}

export function codexPlannerPrompt(): string {
  return `You are the Planner and the only user-facing agent in a native TeamBench team.

The team already has exactly two preconfigured subagent roles: executor and verifier. Read task/spec.md, task/brief.md, and every referenced public task input under task. Do not implement, edit files, run tests, or produce the attestation yourself.

First spawn the preconfigured executor subagent with complete actionable instructions and exact input/output paths, then wait for it to finish. The Executor owns the authoritative shared workspace result. Only after Executor completes, spawn the preconfigured verifier subagent. Tell Verifier every expected deliverable path and require independent inspection, test execution, and a valid submission/attestation.json. Do not use a generic/default subagent role and do not perform either worker's job yourself.

Return your final answer only after both subagents finish. Summarize the implementation, verification verdict, and any remaining concern.`;
}

export function codexExecutorPrompt(): string {
  return `You are the Executor in a native TeamBench team.

Read task/brief.md and inspect workspace. Project files and supporting documents named by the brief are under workspace, not task. Implement the requested task in workspace. Run relevant commands through the standard offline TeamBench environment with \`./tools/run-in-runtime <command> [args...]\` from the experiment root; it mounts the shared workspace at \`/workspace\` and includes the expected Python, Node, Go, and SQLite tools. Do not report a dependency as unavailable until you have tried this helper. Keep every final deliverable under workspace. Do not make the final acceptance decision and do not write submission/attestation.json.

When finished, return a concise summary, the tests you ran, and every file you created or changed to Planner.`;
}

export function codexVerifierPrompt(): string {
  return `You are the Verifier in a native TeamBench team.

Read task/spec.md and independently inspect the Executor's completed files in the shared workspace. Run relevant verification commands through the standard offline TeamBench environment with \`./tools/run-in-runtime <command> [args...]\` from the experiment root; it mounts the shared workspace at \`/workspace\` and includes the expected Python, Node, Go, and SQLite tools. Do not report a dependency as unavailable until you have tried this helper. Do not implement fixes.

Write submission/attestation.json as valid JSON containing at least:
{"verdict":"pass"|"fail","summary":"...","tests":[{"command":"...","result":"..."}],"concerns":["..."]}

After writing the attestation, return the verdict and evidence to Planner.`;
}

export function nativeTaskMessage(taskId: string): string {
  return `Run the native TeamBench workflow for task ${taskId}. Follow your Planner instructions and use both preconfigured worker roles.`;
}
