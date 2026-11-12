import { randomUUID } from "node:crypto";
import { access, lstat, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { z } from "zod";
import {
  hostMaintenanceInputSchema,
  hostMaintenanceStateSchema,
  type HostMaintenanceInput,
  type HostMaintenanceState,
} from "@comma/native-bridge";
import { clockSleep, realMainClock, type MainClock } from "../../clock";
import { AgentVMMHostPreparation, type HostCommand } from "./host-preparation";
import { parseNativeReceipt, type NativeReceipt } from "./host-maintenance-protocol";
import publishedHost from "../../../../../../../.github/agent-vmm-host.json";
import type { LocalComputeOperator } from "./local-operator";

const intentSchema = z.object({
  version: z.number().int().positive(),
  requestId: z.string().uuid(),
  action: z.enum(["update", "reinstall", "uninstall"]),
  dataPolicy: z.enum(["preserve", "reset"]),
  targetApp: z.string(),
  artifact: z.object({
    release_id: z.string(),
    path: z.string(),
    sha256: z.string(),
    size: z.number(),
  }),
  sourceApp: z.string().optional(),
  targetReleaseId: z.string().optional(),
  supersedesRequestId: z.string().optional(),
  disposalRequestId: z.string().optional(),
  deadlineAt: z.number().optional(),
});
type Intent = z.infer<typeof intentSchema>;
const APP_NAME = "Agent VMM Host.app";
const STOP_TERM_MS = 3_000,
  STOP_KILL_MS = 2_000,
  STOP_POLL_MS = 100;
/** The processes of this Mac that Main may observe and signal. Tests replace it. */
export interface HostProcessControl {
  /** The process ids whose executable is exactly `executable`. */
  find(executable: string): Promise<number[]>;
  /** Sends `signal` (0 only checks). Returns false when the process no longer exists. */
  signal(pid: number, signal: NodeJS.Signals | 0): boolean;
  sleep(ms: number): Promise<void>;
}

/** macOS process control: `ps` reports each executable path; only an exact path match is returned. */
export function systemProcessControl(run: HostCommand): HostProcessControl {
  return {
    async find(executable) {
      const output = await run(
        "/bin/ps",
        ["-axww", "-o", "pid=,comm="],
        undefined,
        5_000
      );
      const pids: number[] = [];
      for (const line of output.split("\n")) {
        const match = /^\s*(\d+) (.+)$/.exec(line);
        if (match && match[2] === executable && Number(match[1]) !== process.pid)
          pids.push(Number(match[1]));
      }
      return pids;
    },
    signal(pid, signal) {
      try {
        process.kill(pid, signal);
        return true;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ESRCH") return false;
        throw error;
      }
    },
    // Waits for other processes to end: real time, which a test clock standing still does not hold.
    sleep: (ms) => clockSleep(realMainClock, ms),
  };
}

export class MaintenanceRecordUnreadableError extends Error {}
export class HostTargetOlderThanDataError extends Error {}
export class HostUninstalledError extends Error {}
export class HostRecoveryInterruptsWorkError extends Error {}

/** Main stores the user's confirmed request and frozen artifact. Native alone owns execution verdicts. */
export class LocalHostMaintenance {
  private executing: Promise<HostMaintenanceState> | undefined;
  private readonly resetListeners = new Set<() => void>();
  private cancel: (() => void) | undefined;
  private backoff = 0;
  constructor(
    private readonly preparation: AgentVMMHostPreparation,
    private readonly journalDirectory: string,
    private readonly run: HostCommand,
    private readonly confirm?: (input: HostMaintenanceInput) => Promise<boolean>,
    private readonly localDisposals?: Pick<
      LocalComputeOperator,
      "currentDisposalRequest" | "supersedeAfterHostReset"
    >,
    private readonly processes: HostProcessControl = systemProcessControl(run),
    private readonly clock: MainClock = realMainClock
  ) {}
  onHostReset(listener: () => void) {
    this.resetListeners.add(listener);
    return () => {
      this.resetListeners.delete(listener);
    };
  }
  private get journalPath() {
    return join(this.journalDirectory, "comma.json");
  }
  private async intent(): Promise<Intent | undefined> {
    try {
      return intentSchema.parse(JSON.parse(await readFile(this.journalPath, "utf8")));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw new MaintenanceRecordUnreadableError(
        "The saved maintenance request is unreadable.",
        { cause: error }
      );
    }
  }
  private async save(intent: Intent) {
    if (intent.version > 2)
      throw new Error("A newer Comma owns this maintenance request.");
    await mkdir(this.journalDirectory, { recursive: true, mode: 0o700 });
    await writeFile(
      `${this.journalPath}.tmp`,
      JSON.stringify({ ...intent, version: 2 }),
      { mode: 0o600 }
    );
    await rename(`${this.journalPath}.tmp`, this.journalPath);
  }
  private helper(intent?: Intent) {
    return intent?.sourceApp
      ? join(intent.sourceApp, "Contents", "Helpers", "agent-vmm-lifecycle")
      : this.preparation.config.lifecyclePath;
  }
  private async receipt(intent?: Intent): Promise<NativeReceipt | undefined> {
    const output = JSON.parse(
      await this.run(
        this.helper(intent),
        ["maintenance-status", "--service-type", "auto"],
        JSON.stringify(intent ? { requestId: intent.requestId } : {}),
        5_000
      )
    );
    if (output === null) return undefined;
    // Unified native read also returns registration receipts. They remain native-owned and are not software tasks.
    if (!output.action || !["update", "reinstall", "uninstall"].includes(output.action))
      return undefined;
    const receipt = parseNativeReceipt(output);
    if (intent && receipt.requestId !== intent.requestId)
      throw new Error("Maintenance receipt belongs to another request.");
    return receipt;
  }
  async state(): Promise<HostMaintenanceState> {
    let intent: Intent | undefined,
      recordUnreadable = false;
    try {
      intent = await this.intent();
    } catch {
      recordUnreadable = true;
    }
    let installation: HostMaintenanceState["installation"] = "unreadable",
      installedReleaseId: string | undefined;
    try {
      await lstat(this.preparation.config.appPath);
      const output = JSON.parse(
        await this.run(
          this.preparation.config.lifecyclePath,
          ["version", "--json"],
          undefined,
          5_000
        )
      );
      if (typeof output.release_id === "string") {
        installedReleaseId = output.release_id;
        installation = "installed";
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT")
        installation = "not_installed";
    }
    let receipt: NativeReceipt | undefined;
    try {
      receipt = await this.receipt(intent);
    } catch {
      if (intent) recordUnreadable = true;
    }
    const operation =
      receipt && receipt.outcome !== "superseded"
        ? this.project(receipt)
        : intent && !recordUnreadable
          ? {
              requestId: intent.requestId,
              action: intent.action,
              dataPolicy: intent.dataPolicy,
              phase: "preparing" as const,
              outcome: "pending" as const,
            }
          : undefined;
    return hostMaintenanceStateSchema.parse({
      installation,
      installedReleaseId,
      selectedReleaseId:
        !this.preparation.config.sourcePath &&
        !this.preparation.config.downloadUrlOverride
          ? publishedHost.release_id
          : undefined,
      updateAvailable:
        !this.preparation.config.sourcePath &&
        !this.preparation.config.downloadUrlOverride &&
        installation === "installed" &&
        installedReleaseId !== publishedHost.release_id,
      ...(operation ? { operation } : {}),
      ...(recordUnreadable ? { recordUnreadable: true } : {}),
      ...(this.executing && !receipt
        ? { preparationPhase: this.preparation.state().phase }
        : {}),
    });
  }
  private project(
    receipt: NativeReceipt
  ): NonNullable<HostMaintenanceState["operation"]> {
    const phase = phaseOfStage(receipt.stage);
    return {
      requestId: receipt.requestId,
      action: receipt.action,
      dataPolicy: receipt.dataPolicy,
      phase:
        receipt.outcome === "succeeded"
          ? "completed"
          : receipt.outcome === "failed"
            ? "failed"
            : phase,
      outcome: receipt.outcome === "superseded" ? "failed" : receipt.outcome,
      ...(receipt.outcome === "failed" ? { failedPhase: phase } : {}),
      ...(receipt.failureMessage
        ? { problem: receipt.failureMessage.slice(0, 2000) }
        : {}),
      ...(receipt.failureCode === "host_start_failed" ||
      receipt.failureCode === "target_older_than_data"
        ? { failureCode: receipt.failureCode }
        : {}),
    };
  }
  automaticUpdate() {
    return this.maintain({ action: "update", dataPolicy: "preserve" });
  }
  async continuePending(_workActive: () => boolean = () => false) {
    if (this.executing) return true;
    const intent = await this.intent();
    if (!intent || !intent.deadlineAt || this.clock.now() >= intent.deadlineAt)
      return false;
    const receipt = await this.receipt(intent);
    if (
      receipt?.outcome === "succeeded" ||
      receipt?.outcome === "superseded" ||
      (receipt?.outcome === "failed" && !receipt.retryable)
    )
      return false;
    await this.exclusive(() => this.execute(intent));
    return true;
  }
  async maintain(input: HostMaintenanceInput) {
    hostMaintenanceInputSchema.parse(input);
    if (!this.confirm || !(await this.confirm(input))) return this.state();
    return this.beginConfirmed(input);
  }
  /** Setup may continue this owner's confirmed request; only an explicit interaction may confirm a new one. */
  async prepareForSetup(explicit: boolean, requireCurrent: () => void) {
    const previous = await this.intent();
    const receipt = previous ? await this.receipt(previous) : undefined;
    if (
      previous &&
      (!receipt ||
        receipt.outcome === "pending" ||
        (receipt.outcome === "failed" && receipt.retryable))
    ) {
      if (previous.action !== "reinstall" || previous.dataPolicy !== "preserve")
        return undefined;
      requireCurrent();
      if (this.executing) return this.state();
      if (explicit)
        return this.resume(previous.requestId, undefined, true, requireCurrent);
      if (!previous.deadlineAt || this.clock.now() >= previous.deadlineAt)
        return undefined;
      return this.exclusive(async () => {
        requireCurrent();
        return this.execute(previous, false, requireCurrent);
      });
    }
    if (!explicit) return undefined;
    const input: HostMaintenanceInput = { action: "reinstall", dataPolicy: "preserve" };
    if (!this.confirm || !(await this.confirm(input))) return undefined;
    requireCurrent();
    return this.beginConfirmed(input, requireCurrent);
  }
  private async beginConfirmed(
    input: HostMaintenanceInput,
    requireCurrent?: () => void
  ) {
    if (this.executing && input.action === "uninstall") {
      const previous = await this.intent();
      if (previous) await this.stopExecutor(previous.requestId);
      const current = this.executing;
      await Promise.race([current, clockSleep(this.clock, 10_000)]);
      if (this.running())
        throw new Error("The previous maintenance call did not stop.");
    }
    return this.exclusive(async () => {
      requireCurrent?.();
      const previous = await this.intent();
      const receipt = requireCurrent
        ? previous
          ? await this.receipt(previous)
          : undefined
        : await this.receipt(previous).catch(() => undefined);
      if (
        requireCurrent &&
        previous &&
        (!receipt ||
          receipt.outcome === "pending" ||
          (receipt.outcome === "failed" && receipt.retryable))
      ) {
        if (
          previous.action !== input.action ||
          previous.dataPolicy !== input.dataPolicy
        )
          return this.state();
        previous.deadlineAt = this.clock.now() + 45 * 60_000;
        requireCurrent();
        await this.save(previous);
        requireCurrent();
        return this.execute(previous, true, requireCurrent);
      }
      if (
        previous &&
        previous.action === input.action &&
        previous.dataPolicy === input.dataPolicy &&
        previous.artifact.release_id === publishedHost.release_id &&
        receipt?.outcome === "failed" &&
        receipt.retryable
      ) {
        previous.deadlineAt = this.clock.now() + 45 * 60_000;
        await this.save(previous);
        return this.execute(previous, true);
      }
      const requestId = randomUUID();
      const intent: Intent = {
        version: 2,
        requestId,
        ...input,
        artifact: publishedHost,
        targetApp: this.preparation.config.appPath,
        deadlineAt: this.clock.now() + 45 * 60_000,
      };
      if (
        receipt &&
        receipt.outcome !== "succeeded" &&
        receipt.outcome !== "superseded"
      ) {
        intent.supersedesRequestId = receipt.requestId;
        await this.stopExecutor(receipt.requestId);
      }
      if (input.dataPolicy === "reset") {
        const disposal = await this.localDisposals?.currentDisposalRequest();
        if (disposal) intent.disposalRequestId = disposal;
      }
      requireCurrent?.();
      await this.save(intent);
      requireCurrent?.();
      return this.execute(intent, false, requireCurrent);
    });
  }
  resume(
    requestId: string,
    _workActive: () => boolean = () => false,
    _interactive = true,
    requireCurrent: () => void = () => {}
  ) {
    return this.exclusive(async () => {
      const intent = await this.intent();
      if (!intent || intent.requestId !== requestId)
        throw new Error("The original maintenance confirmation is unavailable.");
      requireCurrent();
      intent.deadlineAt = this.clock.now() + 45 * 60_000;
      await this.save(intent);
      requireCurrent();
      return this.execute(intent, true, requireCurrent);
    });
  }
  // Native retains the authoritative receipt. No renderer action may erase it to imply absence.
  async resetRecord() {
    return false;
  }
  private async execute(
    intent: Intent,
    explicit = false,
    requireCurrent?: () => void
  ): Promise<HostMaintenanceState> {
    let before: NativeReceipt | undefined;
    try {
      before = await this.receipt(intent);
    } catch {
      /* An absent frozen helper is restored below. */
    }
    if (before?.outcome === "succeeded" || before?.outcome === "superseded")
      return this.state();
    if (before?.outcome === "failed" && !before.retryable) return this.state();
    try {
      await this.preparation.stageMaintenance(
        intent.requestId,
        () => {},
        intent.artifact,
        async (staged) => {
          requireCurrent?.();
          if (intent.sourceApp && intent.sourceApp !== staged.sourceApp)
            throw new Error("The confirmed maintenance artifact changed.");
          Object.assign(intent, staged);
          await this.save(intent);
          await access(this.helper(intent));
          requireCurrent?.();
          await this.run(
            this.helper(intent),
            ["host-maintain", "--service-type", "auto"],
            JSON.stringify({
              version: 1,
              requestId: intent.requestId,
              action: intent.action,
              dataPolicy: intent.dataPolicy,
              targetApp: intent.targetApp,
              ...(intent.supersedesRequestId
                ? { supersedesRequestId: intent.supersedesRequestId }
                : {}),
              ...(intent.action !== "uninstall"
                ? {
                    sourceApp: intent.sourceApp,
                    targetReleaseId: intent.targetReleaseId,
                  }
                : {}),
              confirmSharedHost: true,
              ...(explicit ? { continue: true } : {}),
              ...(intent.dataPolicy === "reset" ? { confirmDataDeletion: true } : {}),
            }),
            15 * 60_000
          );
        }
      );
    } catch {
      /* The native receipt, including an unknown result, is read below. */
    }
    const receipt = await this.receipt(intent);
    if (receipt?.outcome === "succeeded" && intent.dataPolicy === "reset") {
      if (intent.disposalRequestId)
        await this.localDisposals?.supersedeAfterHostReset(
          intent.disposalRequestId,
          intent.requestId
        );
      for (const listener of this.resetListeners) listener();
    }
    this.cancel?.();
    this.cancel = undefined;
    if (
      (!receipt || receipt.outcome === "pending" || receipt.retryable) &&
      intent.deadlineAt &&
      this.clock.now() < intent.deadlineAt
    ) {
      this.cancel = this.clock.setTimer(
        Math.min(30_000, 1_000 * 2 ** Math.min(this.backoff++, 5)),
        () => {
          this.cancel = undefined;
          void this.continuePending().catch(() => undefined);
        }
      );
    }
    return this.state();
  }
  private running() {
    return !!this.executing;
  }
  private async exclusive(action: () => Promise<HostMaintenanceState>) {
    if (this.executing) throw new Error("Local maintenance is already running.");
    const work = (async () => {
      await mkdir(this.journalDirectory, { recursive: true, mode: 0o700 });
      const lock = new DatabaseSync(join(this.journalDirectory, "comma.sqlite"));
      try {
        lock.exec("BEGIN IMMEDIATE");
        return await action();
      } finally {
        lock.close();
      }
    })();
    this.executing = work;
    try {
      return await work;
    } finally {
      if (this.executing === work) this.executing = undefined;
    }
  }
  private frozenHelper(requestId: string) {
    return join(
      this.preparation.config.directory,
      `.maintenance-${requestId}`,
      APP_NAME,
      "Contents",
      "Helpers",
      "agent-vmm-lifecycle"
    );
  }
  private async stopExecutor(requestId: string) {
    if (!/^[a-f0-9-]{36}$/.test(requestId)) return;
    let pids = await this.processes.find(this.frozenHelper(requestId));
    for (const pid of pids) this.processes.signal(pid, "SIGTERM");
    pids = await this.waitForExit(pids, STOP_TERM_MS);
    for (const pid of pids) this.processes.signal(pid, "SIGKILL");
    pids = await this.waitForExit(pids, STOP_KILL_MS);
    if (pids.length) throw new Error("The previous maintenance process did not stop.");
  }
  private async waitForExit(pids: number[], ms: number) {
    for (let waited = 0; ; waited += STOP_POLL_MS) {
      pids = pids.filter((pid) => this.processes.signal(pid, 0));
      if (!pids.length || waited >= ms) return pids;
      await this.processes.sleep(STOP_POLL_MS);
    }
  }
}
function phaseOfStage(
  stage: string
): "preparing" | "stopping" | "removing" | "installing" | "checking" {
  return stage === "stop"
    ? "stopping"
    : stage === "reset"
      ? "removing"
      : ["replace", "restore"].includes(stage)
        ? "installing"
        : stage === "settled"
          ? "checking"
          : "preparing";
}
