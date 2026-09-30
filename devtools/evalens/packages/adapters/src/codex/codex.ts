import { mkdtemp, rm } from "node:fs/promises";
import { Buffer } from "node:buffer";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { measure } from "@evalens/utils";
import { z } from "zod";
import { CodexCliAdapterConfig } from "./config";
import type { Codex } from "./types";
import {
  extractCodexErrorMessage,
  extractCodexThreadId,
  findCodexSessionLogPath,
  prepareWorkspace,
} from "./utils";

type ProcessResult = {
  stdout: Buffer;
  stderr: Buffer;
  exitCode: number | null;
  signal: string | null;
};

export class CodexCliAdapter {
  private readonly config: CodexCliAdapterConfig;

  constructor(options: Codex.CliAdapterOptions = {}) {
    this.config = CodexCliAdapterConfig.parse(options);
  }

  async runTask(input: Codex.TaskInput): Promise<Codex.RunResult> {
    const workspaceDir = await prepareWorkspace(input);
    const runDir = await mkdtemp(join(tmpdir(), "evalens-codex-run-"));
    const finalAnswerPath = join(runDir, "last-message.txt");

    try {
      const args = this.buildExecArgs(input, workspaceDir, finalAnswerPath);
      const measuredProcess = await measure(() =>
        this.runProcess(["/usr/bin/env", this.config.command, ...args], workspaceDir)
      );
      if (measuredProcess.status === "rejected") throw measuredProcess.reason;
      const processResult = measuredProcess.value;
      const { durationMs } = measuredProcess.timing;
      const stdout = processResult.stdout.toString("utf8");
      const stderr = processResult.stderr.toString("utf8");
      const finalAnswerFile = Bun.file(finalAnswerPath);
      const finalAnswer = (await finalAnswerFile.exists())
        ? await finalAnswerFile.text()
        : "";
      const parsedJsonl = Bun.JSONL.parseChunk(stdout);
      if (parsedJsonl.error || !parsedJsonl.done) {
        throw parsedJsonl.error ?? new SyntaxError("incomplete Codex JSONL output");
      }
      const events = z.array(z.json()).parse(parsedJsonl.values);
      const threadId = extractCodexThreadId(events, stdout);
      const codexErrorMessage = extractCodexErrorMessage(events);
      const codexSessionLogPath =
        threadId && !this.config.ephemeral
          ? await findCodexSessionLogPath(threadId)
          : undefined;
      const verifyResult = input.verifyCommand
        ? await this.runVerifyCommand(input.verifyCommand, workspaceDir)
        : undefined;

      return {
        task: input.task,
        workspaceDir,
        finalAnswer,
        stdout,
        stderr,
        events,
        threadId,
        codexErrorMessage,
        codexSessionLogPath,
        exitCode: processResult.exitCode,
        signal: processResult.signal,
        durationMs,
        verifyResult,
        metadata: input.metadata,
      };
    } finally {
      await rm(runDir, { recursive: true, force: true });
    }
  }

  private buildExecArgs(
    input: Codex.TaskInput,
    workspaceDir: string,
    finalAnswerPath: string
  ): string[] {
    const args = [
      "exec",
      "--cd",
      workspaceDir,
      "--sandbox",
      this.config.sandbox,
      "--json",
      "--output-last-message",
      finalAnswerPath,
    ];

    if (this.config.skipGitRepoCheck) {
      args.push("--skip-git-repo-check");
    }
    if (this.config.ephemeral) {
      args.push("--ephemeral");
    }

    const model = input.model ?? this.config.model;
    if (model) {
      args.push("--model", model);
    }
    if (this.config.profile) {
      args.push("--profile", this.config.profile);
    }
    args.push("-c", `approval_policy="${this.config.approvalPolicy}"`);
    for (const override of this.config.configOverrides) {
      args.push("-c", override);
    }

    args.push(...this.config.extraArgs, "--", input.task);
    return args;
  }

  private async runVerifyCommand(
    command: string,
    workspaceDir: string
  ): Promise<Codex.VerifyResult> {
    const shell = process.env["SHELL"] ?? "/bin/sh";
    const measuredProcess = await measure(() =>
      this.runProcess(["/usr/bin/env", shell, "-lc", command], workspaceDir)
    );
    if (measuredProcess.status === "rejected") throw measuredProcess.reason;
    const result = measuredProcess.value;
    const { durationMs } = measuredProcess.timing;

    return {
      command,
      exitCode: result.exitCode,
      signal: result.signal,
      stdout: result.stdout.toString("utf8"),
      stderr: result.stderr.toString("utf8"),
      durationMs,
    };
  }

  private async runProcess(cmd: string[], cwd: string): Promise<ProcessResult> {
    const proc = Bun.spawn({
      cmd,
      cwd,
      detached: true,
      env: { ...process.env, ...this.config.env },
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).arrayBuffer().then((value) => Buffer.from(value)),
      new Response(proc.stderr).arrayBuffer().then((value) => Buffer.from(value)),
      proc.exited.catch(() => proc.exitCode ?? 1),
    ]);

    return {
      stdout,
      stderr,
      exitCode: proc.exitCode,
      signal: proc.signalCode,
    };
  }
}
