import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { realMainClock, type MainClock } from "../../clock";

export class ComputeNodeCommandError extends Error {
  constructor(
    message: string,
    readonly reason: "outcome_unknown" | "command_failed",
    readonly native?: { code: string; reason: string }
  ) {
    super(message);
  }
}

/**
 * Shared product-neutral install location for the signed Agent VMM Host.app.
 * The desktop client and the macOS provisioner must resolve the same path;
 * neither side may depend on a Debug App or a user-selected bundle path.
 */
export function defaultAgentVMMHostLifecyclePath(home = homedir()): string {
  return join(
    home,
    "Library",
    "Application Support",
    "Agent VMM Host",
    "current",
    "Agent VMM Host.app",
    "Contents",
    "Helpers",
    "agent-vmm-lifecycle"
  );
}

export function runCommand(
  file: string,
  args: string[],
  stdin?: string,
  timeoutMs = 15_000,
  options: { cwd?: string; env?: NodeJS.ProcessEnv; clock?: MainClock } = {}
): Promise<string> {
  const { clock = realMainClock, ...spawnOptions } = options;
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, {
      ...spawnOptions,
      detached: process.platform !== "win32",
      stdio: ["pipe", "pipe", "pipe"],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let settled = false;
    const finish = (callback: () => void) => {
      if (settled) return;
      settled = true;
      cancelTimeout();
      callback();
    };
    const signalProcessTree = (signal: NodeJS.Signals) => {
      if (child.pid && process.platform !== "win32") {
        try {
          process.kill(-child.pid, signal);
        } catch {
          child.kill(signal);
        }
      } else {
        child.kill(signal);
      }
    };
    const terminate = () => {
      signalProcessTree("SIGTERM");
      // A helper that ignores SIGTERM must die even while a test clock stands still.
      realMainClock.setTimer(1_000, () => signalProcessTree("SIGKILL"));
    };
    const cancelTimeout = clock.setTimer(timeoutMs, () => {
      terminate();
      finish(() =>
        reject(
          new ComputeNodeCommandError(
            `Agent VMM command timed out after ${timeoutMs}ms.`,
            "outcome_unknown"
          )
        )
      );
    });
    child.stdout.on("data", (chunk: Buffer) => appendCommandOutput(stdout, chunk));
    child.stderr.on("data", (chunk: Buffer) => appendCommandOutput(stderr, chunk));
    child.once("error", (error) => finish(() => reject(error)));
    child.once("close", (code) => {
      if (code === 0) finish(() => resolve(Buffer.concat(stdout).toString("utf8")));
      else
        finish(() =>
          reject(
            new ComputeNodeCommandError(
              Buffer.concat(stderr).toString("utf8").trim().slice(-4096) ||
                `Agent VMM command failed (${code ?? "signal"}).`,
              code === null ? "outcome_unknown" : "command_failed",
              readNativeCommandError(Buffer.concat(stdout).toString("utf8"))
            )
          )
        );
    });
    child.stdin.end(stdin);
  });
}

function readNativeCommandError(
  stdout: string
): { code: string; reason: string } | undefined {
  try {
    const value = JSON.parse(stdout) as {
      error?: { code?: unknown; reason?: unknown; message?: unknown };
      failureCode?: unknown;
      failureStage?: unknown;
    };
    if (typeof value.error?.code === "string" && typeof value.error.reason === "string")
      return { code: value.error.code, reason: value.error.reason };
    // A maintenance refusal such as `owner_busy` names only its code and message.
    if (typeof value.error?.code === "string")
      return { code: value.error.code, reason: "operation_failed" };
    if (typeof value.failureCode === "string")
      return {
        code: value.failureCode,
        reason:
          typeof value.failureStage === "string"
            ? value.failureStage
            : "operation_failed",
      };
  } catch {
    /* Old helpers do not return structured errors. Their outcome remains unavailable. */
  }
  return undefined;
}

function appendCommandOutput(chunks: Buffer[], chunk: Buffer) {
  chunks.push(chunk.subarray(-256 * 1024));
  while (
    chunks.length > 1 &&
    chunks.reduce((size, item) => size + item.length, 0) > 256 * 1024
  )
    chunks.shift();
}
