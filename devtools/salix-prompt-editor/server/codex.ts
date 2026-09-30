import { mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { z } from "zod";
import type { JobKindSchema } from "../shared/schema";
import { JOB_ROOT } from "./paths";

type CodexPhase = z.infer<typeof JobKindSchema> | "explain";

export type CodexRunOptions<T> = {
  jobId: string;
  phase: CodexPhase;
  runKey?: string;
  cwd: string;
  sandbox: "read-only" | "workspace-write";
  promptPath: string;
  outputSchemaPath: string;
  resultSchema: z.ZodType<T>;
  onLog: (message: string) => void;
  promptSuffix?: string;
  model?: string;
  reasoningEffort?: "none" | "low" | "medium" | "high";
  persistSession?: boolean;
  resumeSessionId?: string;
  onSessionId?: (sessionId: string) => void;
};

type ProcessCapture = {
  stdout: string;
  stderr: string;
  exitCode: number;
};

function eventSummary(value: unknown): string | null {
  if (!value || typeof value !== "object") return null;
  const event = value as Record<string, unknown>;
  const type = typeof event.type === "string" ? event.type : "event";

  if (type === "turn.started") return "Codex 已开始处理";
  if (type === "turn.completed") return "Codex 已完成推理";
  if (type === "turn.failed") return "Codex 任务失败";

  const item =
    event.item && typeof event.item === "object"
      ? (event.item as Record<string, unknown>)
      : null;
  if (!item) return null;

  const itemType = typeof item.type === "string" ? item.type : "item";
  if (itemType === "command_execution") {
    const command = typeof item.command === "string" ? item.command : "命令";
    return `执行：${command.slice(0, 160)}`;
  }
  if (itemType === "agent_message") {
    const text = typeof item.text === "string" ? item.text : "";
    return text ? `Codex：${text.replace(/\s+/g, " ").slice(0, 180)}` : null;
  }
  if (type === "item.started") return `开始：${itemType}`;
  if (type === "item.completed") return `完成：${itemType}`;
  return null;
}

async function captureStream(
  stream: ReadableStream<Uint8Array>,
  onLine?: (line: string) => void,
): Promise<string> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let pending = "";
  let output = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    const chunk = decoder.decode(value, { stream: true });
    output += chunk;
    pending += chunk;
    const lines = pending.split("\n");
    pending = lines.pop() ?? "";
    for (const line of lines) onLine?.(line);
  }

  const tail = decoder.decode();
  output += tail;
  pending += tail;
  if (pending) onLine?.(pending);
  return output;
}

async function runProcess(
  cmd: string[],
  cwd: string,
  stdin: string,
  onLog: (message: string) => void,
): Promise<ProcessCapture> {
  const proc = Bun.spawn({
    cmd,
    cwd,
    env: { ...process.env },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });

  proc.stdin.write(stdin);
  proc.stdin.end();

  const stdoutPromise = captureStream(proc.stdout, (line) => {
    try {
      const summary = eventSummary(JSON.parse(line));
      if (summary) onLog(summary);
    } catch {
      // Codex JSONL can include a final partial line; the final result file is authoritative.
    }
  });
  const stderrPromise = captureStream(proc.stderr);
  const [stdout, stderr, exitCode] = await Promise.all([
    stdoutPromise,
    stderrPromise,
    proc.exited,
  ]);

  return { stdout, stderr, exitCode };
}

function parseJsonResult(text: string): unknown {
  const trimmed = text.trim();
  if (!trimmed) throw new Error("Codex 没有返回结构化完成信息");
  const unfenced = trimmed
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "");
  return JSON.parse(unfenced);
}

function sessionIdFromJsonl(stdout: string): string | null {
  for (const line of stdout.split("\n")) {
    try {
      const event = JSON.parse(line) as Record<string, unknown>;
      if (event.type === "thread.started" && typeof event.thread_id === "string") {
        return event.thread_id;
      }
    } catch {
      // Ignore non-JSON and partial event lines.
    }
  }
  return null;
}

export async function runCodex<T>(options: CodexRunOptions<T>): Promise<T> {
  const codex = Bun.which("codex");
  if (!codex) throw new Error("PATH 中找不到 codex CLI");

  await mkdir(JOB_ROOT, { recursive: true });
  const resultPath = resolve(
    JOB_ROOT,
    `${options.jobId}-${options.runKey ?? options.phase}.json`,
  );
  const prompt = `${await Bun.file(options.promptPath).text()}${options.promptSuffix ?? ""}`;
  const commonArgs = [
    "--ignore-user-config",
    ...(options.model ? ["--model", options.model] : []),
    "--json",
    "--output-schema",
    options.outputSchemaPath,
    "--output-last-message",
    resultPath,
    "-c",
    'approval_policy="never"',
    ...(options.reasoningEffort
      ? ["-c", `model_reasoning_effort="${options.reasoningEffort}"`]
      : []),
  ];
  const cmd = options.resumeSessionId
    ? [codex, "exec", "resume", ...commonArgs, options.resumeSessionId, "-"]
    : [
        codex,
        "exec",
        "--cd",
        options.cwd,
        "--sandbox",
        options.sandbox,
        ...(options.persistSession ? [] : ["--ephemeral"]),
        ...commonArgs,
        "-",
      ];

  const phaseLabel =
    options.phase === "extract"
      ? "全量提取"
      : options.phase === "apply"
        ? "Apply"
        : "行解释";
  options.onLog(`启动 Codex ${phaseLabel}任务`);
  const capture = await runProcess(cmd, options.cwd, prompt, options.onLog);
  if (capture.exitCode !== 0) {
    const detail = capture.stderr.trim().slice(-1_500);
    throw new Error(
      `Codex 退出码 ${capture.exitCode}${detail ? `：${detail}` : ""}`,
    );
  }

  const sessionId = sessionIdFromJsonl(capture.stdout) ?? options.resumeSessionId;
  if (options.persistSession && !sessionId) {
    throw new Error("Codex 未返回可续接的解释 session id");
  }
  if (sessionId) options.onSessionId?.(sessionId);

  const resultFile = Bun.file(resultPath);
  if (!(await resultFile.exists())) {
    throw new Error("Codex 未生成结构化结果文件");
  }
  const parsed = options.resultSchema.safeParse(
    parseJsonResult(await resultFile.text()),
  );
  if (!parsed.success) {
    throw new Error(`Codex 完成信息不符合 schema：${z.prettifyError(parsed.error)}`);
  }
  return parsed.data;
}
