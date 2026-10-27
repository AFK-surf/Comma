import { nativeReceiptSchema } from "./host-maintenance-protocol";
import { ComputeNodeCommandError } from "./command";
import { randomUUID } from "node:crypto";
import {
  access,
  lstat,
  mkdir,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
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
import publishedHost from "../../../../../../../.github/agent-vmm-host.json";
import type { LocalComputeOperator } from "./local-operator";

/** Main's maintenance receipt. A newer Comma may add fields: they are ignored, and a newer version is only read. */
const JOURNAL_VERSION = 1;
const journalSchema = z.object({
  version: z.number().int().min(1),
  requestId: z.string().uuid(),
  action: z.enum(["update", "reinstall", "uninstall"]),
  dataPolicy: z.enum(["preserve", "reset"]),
  selectedReleaseId: z.string(),
  targetApp: z.string(),
  artifact: z.object({
    release_id: z.string(),
    path: z.string(),
    sha256: z.string(),
    size: z.number(),
  }),
  sourceApp: z.string().optional(),
  targetReleaseId: z.string().optional(),
  artifactSha256: z.string().optional(),
  artifactSize: z.number().optional(),
  disposalRequestId: z.string().uuid().optional(),
  supersedesRequestId: z
    .string()
    .regex(/^[A-Za-z0-9_-]{1,128}$/)
    .optional(),
  /**
   * Main's automatic recovery of a stuck request (`episode`), one step per journal. A step that the native owner
   * accepted is not repeated in the same episode, also after a relaunch.
   */
  recovery: z
    .object({
      episode: z.string().regex(/^[A-Za-z0-9_-]{1,128}$/),
      step: z.enum(["update", "reset"]),
      /** Native submissions of this request. An update that fails retryably this often counts as failed. */
      attempts: z.number().int().min(0).max(1_000).optional(),
    })
    .optional(),
  /**
   * Main keeps any native failure code, such as `owner_busy`; the renderer sees only the codes it maps.
   * `retryable`: the same request may run again; Main resumes it with its own request id.
   */
  operation: hostMaintenanceStateSchema.shape.operation
    .unwrap()
    .omit({ failureCode: true })
    .extend({
      failureCode: z.string().max(128).optional(),
      retryable: z.boolean().optional(),
    })
    .strip(),
});
type Journal = z.infer<typeof journalSchema>;
const APP_NAME = "Agent VMM Host.app";
/** A request id that Main stages under its own `.maintenance-<requestId>` directory. */
const MAIN_REQUEST_ID = /^[a-f0-9-]{36}$/;
/** The bounds of stopping a stale executor: SIGTERM, then SIGKILL, then the exit check. */
const STOP_TERM_MS = 3_000;
const STOP_KILL_MS = 2_000;
const STOP_POLL_MS = 100;
/** Submissions of one step while the native owner reports `owner_busy`, each after stopping the executor. */
const OWNER_BUSY_ATTEMPTS = 3;
/** Retryable failures of one automatic recovery update after which Main takes the reset step (§3.15). */
const RECOVERY_UPDATE_ATTEMPTS = 3;
/** How long a forced uninstall waits for Main's own interrupted maintenance call to return. */
const INTERRUPT_WAIT_MS = 10_000;
/** The native owner's policy. Main only reads it: unknown fields and newer versions keep the fields it knows. */
const ownerPolicySchema = z.object({
  version: z.number().int().min(1),
  activeRequest: z.string().optional(),
  latestRequest: z.string().optional(),
  uninstalled: z.boolean(),
  blockedInstalls: z.record(z.string(), z.boolean()).optional(),
  completedRequests: z.record(z.string(), z.boolean()).optional(),
  supersededRequests: z.record(z.string(), z.string()).optional(),
});
type OwnerPolicy = z.infer<typeof ownerPolicySchema>;
class MaintenanceReplacedError extends Error {}

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

/** The stuck request and the next recovery step of its episode. */
interface StuckRequest {
  requestId: string;
  episode: string;
  next: "update" | "reset" | "exhausted";
}

/** Main's maintenance receipt is unreadable. `resetRecord` archives it. */
export class MaintenanceRecordUnreadableError extends Error {}

/** The selected Host release cannot open this Mac's local data, so it is not installed automatically. */
export class HostTargetOlderThanDataError extends Error {
  constructor() {
    super("The selected Agent VMM Host version is older than this Mac's local data.");
  }
}

/** The Host local data schema range that a helper's `version --json` reports. Helpers before the fixes have none. */
const supportedSchemaOf = (value: unknown) => {
  const range = (value as { supportedSchema?: { min?: unknown; max?: unknown } } | null)
    ?.supportedSchema;
  return Number.isSafeInteger(range?.max)
    ? {
        min: Number.isSafeInteger(range?.min) ? (range!.min as number) : 0,
        max: range!.max as number,
      }
    : undefined;
};

/** An automatic recovery would interrupt work that the server reports. Only the user may decide that. */
export class HostRecoveryInterruptsWorkError extends Error {
  constructor() {
    super("Recovering local Host maintenance would interrupt running work.");
  }
}

/** This local operator is deliberately independent of the product Session.
 * Native lifecycle owns VM stopping, data deletion, replay fences and completion.
 * Main owns the trusted confirmation and verified artifact delivery, including
 * a receipt that survives an absent/broken application and an interrupted download.
 *
 * Main also owns the automatic recovery of a stuck request (`detectStuck`): it stops only the stale executor under
 * its own `.maintenance-<requestId>` directory, then supersedes the request with update/preserve to the pinned
 * release when that release can open the local data, and else (or when that update fails) with reinstall/reset.
 * Each episode has one update step and one reset step. The journal records their requests and retry attempts.
 *
 * A failed request that the native owner may retry runs again with its own request id: once per continuation round,
 * on "Continue maintenance", and when the person asks for the same action again. Only a request frozen on another
 * release than the pinned one is replaced, with the same action and data policy (`forward`).
 */
export class LocalHostMaintenance {
  private executing: Promise<HostMaintenanceState> | undefined;
  /** Main runs a failed request again or replaces it: the person sees preparation, not the old failure. */
  private continuing = false;
  /** A forced uninstall interrupted the running call: automatic recovery takes no further step. */
  private interrupted = false;
  private readonly resetListeners = new Set<() => void>();
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

  /**
   * Calls `listener` once each time a reinstall/reset that Main runs (its recovery step, or a person's confirmed
   * reset) succeeds. The reset deleted every local registration, so their installations need a replacement.
   */
  onHostReset(listener: () => void) {
    this.resetListeners.add(listener);
    return () => {
      this.resetListeners.delete(listener);
    };
  }

  /** Notifies the reset listeners when this run of `journal` confirmed its reset. */
  private resetConfirmed(journal: Journal, before: Journal["operation"]["outcome"]) {
    if (
      journal.dataPolicy !== "reset" ||
      before === "succeeded" ||
      journal.operation.outcome !== "succeeded"
    )
      return;
    for (const listener of this.resetListeners) listener();
  }

  private get journalPath() {
    return join(this.journalDirectory, "comma.json");
  }
  async installationBlocked(operationId: string) {
    // Native owns the permanent replay fence. Do not infer it from a missing plan or registration.
    return (await this.policy())?.blockedInstalls?.[operationId] === true;
  }

  async assertInstallationAllowed() {
    const policy = await this.policy();
    if (policy?.activeRequest || policy?.uninstalled)
      throw new Error(
        "Continue local Host maintenance or explicitly reinstall Agent VMM before enabling this connection."
      );
    try {
      await lstat(this.preparation.config.appPath);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      // Ordinary preparation publishes a missing Host via the new native owner.
      return this.assertJournalAllowsSetup(policy);
    }
    await this.preparation.probe.assert(
      this.preparation.config.lifecyclePath,
      this.preparation.config.serviceArgs
    );
    return this.assertJournalAllowsSetup(policy);
  }

  private supersededAndSettled(journal: Journal, policy?: OwnerPolicy) {
    return !!(
      policy?.supersededRequests?.[journal.requestId] &&
      policy.latestRequest &&
      policy.completedRequests?.[policy.latestRequest] === true &&
      !policy.activeRequest &&
      !policy.uninstalled
    );
  }

  private async assertJournalAllowsSetup(policy?: OwnerPolicy) {
    const journal = await this.journal();
    if (journal && this.supersededAndSettled(journal, policy)) return;
    // The native preflight refused before any effect; the installed Host stays usable.
    if (journal?.operation.failureCode === "target_older_than_data") return;
    if (
      journal &&
      journal.operation.outcome !== "succeeded" &&
      (await this.state()).operation?.outcome === "succeeded"
    )
      return;
    if (journal && journal.operation.outcome !== "succeeded")
      throw new Error(
        "Complete local Host maintenance or explicitly reinstall Agent VMM before enabling this connection."
      );
  }

  private async policy() {
    try {
      return ownerPolicySchema.parse(
        JSON.parse(await readFile(join(this.journalDirectory, "state.json"), "utf8"))
      );
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw new Error(
        "Local Host maintenance policy is unreadable; automatic setup is paused.",
        { cause: error }
      );
    }
  }
  private async journal() {
    try {
      return journalSchema.parse(JSON.parse(await readFile(this.journalPath, "utf8")));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw new MaintenanceRecordUnreadableError(
        "The local maintenance record is unreadable. Reset the local record to continue.",
        { cause: error }
      );
    }
  }
  private async save(journal: Journal) {
    // A newer Comma owns a newer receipt: this version reads it and never rewrites it.
    if (journal.version > JOURNAL_VERSION)
      throw new Error("A newer Comma version owns this maintenance operation.");
    await mkdir(this.journalDirectory, { recursive: true, mode: 0o700 });
    await writeFile(`${this.journalPath}.tmp`, JSON.stringify(journal), {
      mode: 0o600,
    });
    await rename(`${this.journalPath}.tmp`, this.journalPath);
  }

  async state(): Promise<HostMaintenanceState> {
    let journal: Journal | undefined;
    let recordUnreadable = false;
    try {
      journal = await this.journal();
    } catch (error) {
      if (!(error instanceof MaintenanceRecordUnreadableError)) throw error;
      recordUnreadable = true;
    }
    let obsolete = false;
    if (journal) {
      try {
        obsolete = this.supersededAndSettled(journal, await this.policy());
      } catch {
        /* An unreadable owner policy cannot retire the old operation projection. */
      }
    }
    let installation: HostMaintenanceState["installation"] = "unreadable";
    let installedReleaseId: string | undefined;
    try {
      if ((await lstat(this.preparation.config.appPath)).isSymbolicLink())
        throw new Error("Invalid Host path.");
      installedReleaseId = JSON.parse(
        await this.run(
          this.preparation.config.lifecyclePath,
          ["version", "--json"],
          undefined,
          5_000
        )
      ).release_id;
      if (typeof installedReleaseId !== "string" || !installedReleaseId)
        throw new Error("Unknown Host version.");
      installation = "installed";
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        // A broken helper inside an existing bundle is not an absent installation.
        try {
          await lstat(this.preparation.config.appPath);
        } catch (appError) {
          if ((appError as NodeJS.ErrnoException).code === "ENOENT")
            installation = "not_installed";
        }
      }
    }
    const hostStartFailure =
      installation === "installed" ? (await this.hostStatus())?.failure : undefined;
    // Observation never prepares, installs or resumes a maintenance operation.
    if (!obsolete && journal?.sourceApp && journal.operation.outcome !== "succeeded") {
      try {
        const receipt = await this.run(
          this.helper(journal),
          ["maintenance-status", "--service-type", "auto"],
          JSON.stringify({ requestId: journal.requestId }),
          5_000
        );
        const observed = this.acceptReceipt(journal, receipt);
        journal.operation = observed;
      } catch {
        /* Keep Main's last confirmed receipt; unknown is not success. */
      }
    }
    // Settle only the local receipt projection of an already confirmed reset.
    // This does not perform Host maintenance or resume the old disposal plan.
    if (journal && !obsolete) await this.settleReset(journal);
    let operation =
      journal && !obsolete ? projectOperation(journal.operation) : undefined;
    // Main replaces this failed request now: the person sees preparation, not a failure to act on.
    if (operation && this.continuing && operation.outcome === "failed")
      operation = {
        requestId: operation.requestId,
        action: operation.action,
        dataPolicy: operation.dataPolicy,
        phase: "preparing",
        outcome: "pending",
      };
    return hostMaintenanceStateSchema.parse({
      ...(this.executing && operation?.phase === "preparing"
        ? { preparationPhase: this.preparation.state().phase }
        : {}),
      installation,
      ...(installedReleaseId ? { installedReleaseId } : {}),
      selectedReleaseId: publishedHost.release_id,
      // A pinned release that refused this Mac's data is not offered as an update.
      updateAvailable:
        installation === "installed" &&
        installedReleaseId !== publishedHost.release_id &&
        !(await this.refusedRelease()),
      ...(operation ? { operation } : {}),
      ...(journal &&
      !obsolete &&
      journal.recovery?.step === "reset" &&
      journal.operation.outcome === "succeeded"
        ? { automaticReset: true }
        : {}),
      ...(hostStartFailure ? { hostStartFailure } : {}),
      ...(recordUnreadable ? { recordUnreadable } : {}),
    });
  }

  /**
   * The installed Host's status: its start failure on incompatible local data, its local data schema (unknown when
   * the helper reports none or cannot read it) and whether the Host serves.
   */
  private async hostStatus(helper = this.preparation.config.lifecyclePath) {
    let value: {
      hostHealthy?: unknown;
      dataSchema?: unknown;
      dataSchemaIssue?: unknown;
      hostStartFailure?: { code?: unknown; dataSchema?: unknown };
    } | null;
    try {
      value = JSON.parse(
        await this.run(
          helper,
          ["status", ...this.preparation.config.serviceArgs],
          undefined,
          5_000
        )
      );
    } catch {
      return undefined;
    }
    const failure = value?.hostStartFailure;
    const code =
      failure?.code === "data_newer_than_host" ||
      failure?.code === "data_requires_conversion"
        ? failure.code
        : undefined;
    return {
      failure: code,
      dataSchema:
        value?.dataSchemaIssue === undefined && Number.isSafeInteger(value?.dataSchema)
          ? (value!.dataSchema as number)
          : Number.isSafeInteger(failure?.dataSchema)
            ? (failure!.dataSchema as number)
            : undefined,
      healthy: value?.hostHealthy === true && !failure,
    };
  }

  /**
   * Continuation's update/preserve, started without a dialog: it keeps local data and Main checks first that
   * the server reports no active work. It refuses a target whose supported schema is older than the local data the
   * Host reports, and a release that already refused this Mac's data. The native owner's own preflight still
   * refuses a target that cannot open the data (`target_older_than_data`).
   */
  automaticUpdate() {
    return this.exclusive(async () => {
      const previous = await this.journal();
      const policy = await this.policy();
      if (policy?.activeRequest || policy?.uninstalled)
        throw new Error("Continue local Host maintenance before updating.");
      if (previous && previous.operation.outcome === "pending")
        return this.execute(previous);
      if (await this.refusedRelease()) throw new HostTargetOlderThanDataError();
      if (previous) await this.archive(previous);
      const dataSchema = (await this.hostStatus())?.dataSchema;
      const requestId = randomUUID();
      const input = { action: "update", dataPolicy: "preserve" } as const;
      const journal: Journal = {
        version: JOURNAL_VERSION,
        requestId,
        ...input,
        selectedReleaseId: publishedHost.release_id,
        artifact: publishedHost,
        targetApp: this.preparation.config.appPath,
        operation: { requestId, ...input, phase: "preparing", outcome: "pending" },
      };
      await this.save(journal);
      try {
        await this.execute(journal, async (sourceApp) => {
          if (dataSchema === undefined) return;
          const supported = supportedSchemaOf(
            JSON.parse(
              await this.run(
                this.helperIn(sourceApp),
                ["version", "--json"],
                undefined,
                5_000
              )
            )
          );
          if (supported !== undefined && supported.max < dataSchema)
            throw new HostTargetOlderThanDataError();
        });
      } catch (error) {
        if (!(error instanceof HostTargetOlderThanDataError)) throw error;
      }
      if (journal.operation.failureCode !== "target_older_than_data")
        return this.state();
      await this.retireRefusal(journal);
      throw new HostTargetOlderThanDataError();
    });
  }

  /**
   * Continues Main's own pending maintenance request after a restart, or recovers a stuck one. Returns whether
   * maintenance was pending. `workActive` reports whether the server reports running work; a recovery then stops
   * with `HostRecoveryInterruptsWorkError`, since only the user may interrupt it.
   */
  async continuePending(workActive: () => boolean = () => false) {
    if (this.executing) return true;
    let journal: Journal | undefined;
    try {
      journal = await this.journal();
    } catch {
      return false;
    }
    const stuck = await this.detectStuck(journal).catch(() => undefined);
    if (stuck && stuck.next !== "exhausted") {
      await this.exclusive(async () => {
        await this.recover(workActive);
        return this.state();
      });
      return true;
    }
    if (!journal) return false;
    if (journal.operation.outcome !== "pending") {
      // A failed request runs again with its own request id, once per continuation round. Running work, or a
      // replacement that needs the person's confirmation, waits for the person's action.
      if (
        !(await this.retryOwned(journal)) ||
        (forwardRequired(journal) && confirmationRequired(journal)) ||
        workActive()
      )
        return false;
    }
    await this.resume(journal.requestId, workActive, false);
    return true;
  }

  /**
   * Main's own failed request that the native owner may run again (its receipt is retryable, or the owner never
   * accepted it), and that no other request replaced.
   */
  private async retryOwned(journal: Journal) {
    if (journal.operation.outcome !== "failed") return false;
    const policy = await this.policy().catch(() => undefined);
    if (policy?.uninstalled && journal.action !== "uninstall") return false;
    const active = policy?.activeRequest;
    if (
      active &&
      active !== journal.requestId &&
      active !== journal.supersedesRequestId
    )
      return false;
    const receipt = await this.receiptOf(journal.requestId);
    return receipt
      ? receipt.outcome === "failed" && receipt.retryable === true
      : journal.operation.retryable === true;
  }

  /**
   * Fix-forward of a failed request whose frozen helper is from another release than the pinned one: running that
   * helper again cannot reach a released fix, so Main replaces the request with the same action and data policy on
   * the pinned release. Main's own recovery step stays in its episode. A person's reset or uninstall needs the
   * person's confirmation again; the automatic path does not replace it.
   */
  private async forward(
    journal: Journal,
    workActive: () => boolean,
    interactive: boolean
  ) {
    if (journal.recovery)
      return this.recover(workActive, {
        requestId: journal.requestId,
        episode: journal.recovery.episode,
        next: journal.recovery.step,
      });
    const input = { action: journal.action, dataPolicy: journal.dataPolicy };
    if (
      confirmationRequired(journal) &&
      (!interactive || !this.confirm || !(await this.confirm(input)))
    )
      return;
    await this.archive(journal);
    const requestId = randomUUID();
    const next: Journal = {
      version: JOURNAL_VERSION,
      requestId,
      ...input,
      selectedReleaseId: publishedHost.release_id,
      artifact: publishedHost,
      targetApp: this.preparation.config.appPath,
      operation: { requestId, ...input, phase: "preparing", outcome: "pending" },
      supersedesRequestId: journal.requestId,
    };
    if (input.dataPolicy === "reset") {
      const disposalRequestId =
        journal.disposalRequestId ??
        (await this.localDisposals?.currentDisposalRequest());
      if (disposalRequestId) next.disposalRequestId = disposalRequestId;
    }
    await this.save(next);
    await this.submit(next);
    if (next.operation.failureCode === "target_older_than_data")
      await this.retireRefusal(next);
  }

  /** Archives Main's unreadable maintenance record. The native owner keeps its own receipt and policy. */
  async resetRecord() {
    try {
      await this.journal();
      return false;
    } catch (error) {
      if (!(error instanceof MaintenanceRecordUnreadableError)) throw error;
    }
    await rename(
      this.journalPath,
      `${this.journalPath}.unreadable-${this.clock.now()}`
    );
    return true;
  }

  /** The pinned release already refused this Mac's data: Main does not offer or start it again. */
  private async refusedRelease() {
    try {
      const kept = JSON.parse(
        await readFile(join(this.journalDirectory, "comma-kept.json"), "utf8")
      ) as { releaseId?: unknown };
      return kept.releaseId === publishedHost.release_id;
    } catch {
      return false;
    }
  }

  /** A preflight refusal changed nothing: Main closes its receipt and keeps the installed Host. */
  private async retireRefusal(journal: Journal) {
    await this.archive(journal);
    await writeFile(
      join(this.journalDirectory, "comma-kept.json"),
      JSON.stringify({ releaseId: journal.selectedReleaseId }),
      { mode: 0o600 }
    );
    await rm(this.journalPath, { force: true });
  }

  /**
   * Starts one confirmed maintenance request. An uninstall is always possible: while another maintenance call of
   * Main runs, Main confirms first, stops that request's executor and then supersedes it.
   */
  async maintain(input: HostMaintenanceInput) {
    hostMaintenanceInputSchema.parse(input);
    if (this.executing && input.action === "uninstall") {
      if (!this.confirm || !(await this.confirm(input))) return this.state();
      await this.interruptExecution();
      return this.exclusive(() => this.maintainLocked(input, true));
    }
    return this.exclusive(() => this.maintainLocked(input, false));
  }

  private async maintainLocked(input: HostMaintenanceInput, confirmed: boolean) {
    const previous = await this.journal();
    const policy = await this.policy();
    let supersedesRequestId: string | undefined;
    let stopExecutor = false;
    /** The person asks again for the failed request's own action on the same release. */
    let again = false;
    if (
      policy?.activeRequest ||
      (previous &&
        previous.operation.outcome !== "succeeded" &&
        // A preflight refusal changed nothing and does not fence a new request.
        previous.operation.failureCode !== "target_older_than_data")
    ) {
      // A new explicit action may prepare a read-only preview before its final
      // confirmation. Always use this client's verified helper, since an old
      // helper cannot interpret newer owner journals. Reuse one cache per digest.
      const hash = publishedHost.sha256;
      const previewId = `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20, 32)}`;
      const observation: {
        receipt: Awaited<ReturnType<LocalHostMaintenance["ownerReceipt"]>>;
      } = { receipt: null };
      try {
        await this.preparation.stageMaintenance(
          previewId,
          () => {},
          publishedHost,
          async ({ sourceApp }) => {
            observation.receipt = await this.ownerReceipt(sourceApp);
          }
        );
      } catch (error) {
        throw new Error(
          "Continue the existing maintenance operation before starting another; its current owner state cannot be confirmed.",
          { cause: error }
        );
      }
      const latest = observation.receipt;
      if (latest?.requestId === previous?.requestId && previous) {
        previous.operation = this.acceptReceipt(previous, JSON.stringify(latest));
        await this.save(previous);
      }
      if (latest?.outcome === "failed") {
        supersedesRequestId = latest.requestId;
        again =
          !!previous &&
          latest.requestId === previous.requestId &&
          latest.retryable === true &&
          previous.action === input.action &&
          previous.dataPolicy === input.dataPolicy &&
          !forwardRequired(previous);
      } else if (latest?.outcome === "pending") {
        // A pending request runs on. Only an uninstall or a stuck request lets the person replace it.
        if (
          input.action !== "uninstall" &&
          !(await this.detectStuck(previous).catch(() => undefined))
        )
          throw new Error(
            "Continue the existing maintenance operation before starting another."
          );
        supersedesRequestId = latest.requestId;
        stopExecutor = true;
      } else if (latest?.outcome !== "succeeded") {
        if (latest || policy?.activeRequest || previous?.operation.outcome !== "failed")
          throw new Error(
            "Continue the existing maintenance operation before starting another."
          );
      }
    }
    if (previous) await this.settleReset(previous);
    if (!confirmed && (!this.confirm || !(await this.confirm(input))))
      return this.state();
    if (again && previous) {
      // Main runs that request again with its own request id, not a new request that replaces it.
      const continuing = this.continuing;
      this.continuing = true;
      try {
        await this.submit(previous);
      } finally {
        this.continuing = continuing;
      }
      return this.state();
    }
    if (stopExecutor && supersedesRequestId)
      await this.stopExecutor(supersedesRequestId);
    if (previous) await this.archive(previous);
    const requestId = randomUUID();
    await rm(join(this.journalDirectory, "comma-kept.json"), { force: true });
    const journal: Journal = {
      version: JOURNAL_VERSION,
      requestId,
      ...input,
      selectedReleaseId: publishedHost.release_id,
      artifact: publishedHost,
      targetApp: this.preparation.config.appPath,
      operation: { requestId, ...input, phase: "preparing", outcome: "pending" },
      ...(supersedesRequestId ? { supersedesRequestId } : {}),
    };
    if (input.dataPolicy === "reset") {
      const disposalRequestId = await this.localDisposals?.currentDisposalRequest();
      if (disposalRequestId) journal.disposalRequestId = disposalRequestId;
    }
    // Freeze the user's complete scope before any artifact or lifecycle effects.
    await this.save(journal);
    await this.submit(journal);
    if (journal.operation.failureCode === "target_older_than_data")
      await this.retireRefusal(journal);
    return this.state();
  }

  /**
   * Continues Main's original request. A stuck request is recovered instead, so a frozen helper from before the
   * fixes does not run again; a request that ends stuck is recovered in the same call.
   */
  resume(
    requestId: string,
    workActive: () => boolean = () => false,
    interactive = true
  ) {
    return this.exclusive(async () => {
      const journal = await this.journal();
      if (!journal || journal.requestId !== requestId)
        throw new Error("The original maintenance confirmation is unavailable.");
      if (journal.operation.outcome === "succeeded") {
        await this.settleReset(journal);
        return this.state();
      }
      const continuing = this.continuing;
      this.continuing = true;
      try {
        if (forwardRequired(journal) && (await this.retryOwned(journal)))
          await this.forward(journal, workActive, interactive);
        else {
          if (!(await this.detectStuck(journal).catch(() => undefined)))
            await this.execute(journal);
          await this.recover(workActive);
        }
      } finally {
        this.continuing = continuing;
      }
      return this.state();
    });
  }

  private async exclusive(action: () => Promise<HostMaintenanceState>) {
    if (this.executing) throw new Error("Local maintenance is already running.");
    this.interrupted = false;
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
      this.executing = undefined;
    }
  }

  /** Stops Main's running maintenance call for a forced uninstall, within a bound. */
  private async interruptExecution() {
    this.interrupted = true;
    const journal = await this.journal().catch(() => undefined);
    if (journal) await this.stopExecutor(journal.requestId);
    if (journal?.supersedesRequestId)
      await this.stopExecutor(journal.supersedesRequestId);
    for (
      let waited = 0;
      this.executing && waited < INTERRUPT_WAIT_MS;
      waited += STOP_POLL_MS
    )
      await this.processes.sleep(STOP_POLL_MS);
  }

  /**
   * The native owner's active request when it is stuck: (a) failed with `host_start_failed` or
   * `target_older_than_data`; (b) pending with a frozen Main helper from before the fixes (no `supportedSchema`)
   * while the Host does not serve; (c) pending with no live executor, when Main cannot continue it itself. Main's
   * own pending request and its own recovery step are continuations, not stuck requests.
   */
  private async detectStuck(journal?: Journal): Promise<StuckRequest | undefined> {
    const active = (await this.policy())?.activeRequest;
    if (!active) return undefined;
    const receipt = await this.receiptOf(active);
    if (!receipt) return undefined;
    if (receipt.outcome === "failed") {
      if (
        receipt.failureCode !== "host_start_failed" &&
        receipt.failureCode !== "target_older_than_data" &&
        // Main's own recovery update that failed retryably too often is a failed update: the reset step follows.
        !(journal?.requestId === active && updateSpent(journal))
      )
        return undefined;
    } else if (receipt.outcome === "pending") {
      // Another owner's executor is not Main's to judge; its native lock fences it.
      if (!(await this.stagedByMain(active))) return undefined;
      const own = journal?.requestId === active;
      if (own && journal.recovery) return undefined;
      if (!(await this.predatesFixes(active)) || (await this.hostStatus())?.healthy) {
        if (own || (await this.executorRunning(active))) return undefined;
      }
    } else return undefined;
    return { requestId: active, ...nextStep(journal, active) };
  }

  /** Main staged this request's helper under its own `.maintenance-<requestId>` directory. */
  private async stagedByMain(requestId: string) {
    if (!MAIN_REQUEST_ID.test(requestId)) return false;
    try {
      await access(this.frozenHelper(requestId));
      return true;
    } catch {
      return false;
    }
  }

  /** The receipt of one request, read with its frozen Main helper, or else with the installed helper. */
  private async receiptOf(requestId: string) {
    // Not staged by Main: the installed helper reads the shared owner.
    const helper = (await this.stagedByMain(requestId))
      ? this.frozenHelper(requestId)
      : this.preparation.config.lifecyclePath;
    try {
      const receipt = nativeReceiptSchema.parse(
        JSON.parse(
          await this.run(
            helper,
            ["maintenance-status", "--service-type", "auto"],
            JSON.stringify({ requestId }),
            5_000
          )
        )
      );
      return receipt.requestId === requestId ? receipt : undefined;
    } catch {
      return undefined;
    }
  }

  /** A frozen helper that reports no supported schema, or none at all, predates the bounded restore. */
  private async predatesFixes(requestId: string) {
    try {
      return (
        supportedSchemaOf(
          JSON.parse(
            await this.run(
              this.frozenHelper(requestId),
              ["version", "--json"],
              undefined,
              5_000
            )
          )
        ) === undefined
      );
    } catch {
      return true;
    }
  }

  private frozenHelper(requestId: string) {
    return this.helperIn(
      join(this.preparation.config.directory, `.maintenance-${requestId}`, APP_NAME)
    );
  }

  private async executorRunning(requestId: string) {
    if (!MAIN_REQUEST_ID.test(requestId)) return false;
    return (
      (await this.processes.find(this.frozenHelper(requestId)).catch(() => [])).length >
      0
    );
  }

  /**
   * Stops the executor of one request: only processes whose executable is that request's helper under Main's own
   * `.maintenance-<requestId>` directory. SIGTERM, then SIGKILL, then a check that each one exited.
   */
  private async stopExecutor(requestId: string) {
    if (!MAIN_REQUEST_ID.test(requestId)) return;
    let pids = await this.processes.find(this.frozenHelper(requestId)).catch(() => []);
    if (!pids.length) return;
    for (const pid of pids) this.processes.signal(pid, "SIGTERM");
    pids = await this.waitForExit(pids, STOP_TERM_MS);
    for (const pid of pids) this.processes.signal(pid, "SIGKILL");
    pids = await this.waitForExit(pids, STOP_KILL_MS);
    if (pids.length)
      throw new Error("The previous local maintenance process did not stop.");
  }

  private async waitForExit(pids: number[], ms: number) {
    for (let waited = 0; ; waited += STOP_POLL_MS) {
      pids = pids.filter((pid) => this.processes.signal(pid, 0));
      if (!pids.length || waited >= ms) return pids;
      await this.processes.sleep(STOP_POLL_MS);
    }
  }

  /**
   * The automatic recovery of a stuck request, inside `exclusive`. It runs no step while the server reports
   * active work, and none after a forced uninstall interrupted it. `start` is a failed recovery step that Main
   * replaces on the pinned release (fix-forward) instead of detecting a stuck request.
   */
  private async recover(workActive: () => boolean, start?: StuckRequest) {
    let stuck =
      start ?? (await this.detectStuck(await this.journal()).catch(() => undefined));
    if (!stuck || stuck.next === "exhausted" || this.interrupted) return;
    if (workActive()) throw new HostRecoveryInterruptsWorkError();
    const continuing = this.continuing;
    this.continuing = true;
    try {
      if (stuck.next === "update") {
        const result = await this.recoveryStep(stuck, "update");
        if (result !== "failed" || this.interrupted) return;
        // A retryable failure, such as a stop that did not finish, is resumed with the same request id in a later
        // round, until it failed `RECOVERY_UPDATE_ATTEMPTS` times. An update that cannot succeed (refused, or a
        // Host that cannot start) is replaced by a reset at once.
        const update = await this.journal();
        if (update?.operation.retryable && !updateSpent(update)) return;
        // A refused update leaves the stuck request active; an accepted update that failed is active now.
        const policy = await this.policy();
        stuck = {
          ...stuck,
          requestId: policy?.activeRequest ?? policy?.latestRequest ?? stuck.requestId,
        };
      }
      await this.recoveryStep(stuck, "reset");
    } finally {
      this.continuing = continuing;
    }
  }

  /** One recovery step. A request the native owner never accepted (pending, `owner_busy`) is submitted again. */
  private async recoveryStep(stuck: StuckRequest, step: "update" | "reset") {
    const previous = await this.journal();
    let journal: Journal;
    if (
      previous?.recovery?.episode === stuck.episode &&
      previous.recovery.step === step &&
      previous.supersedesRequestId === stuck.requestId &&
      resumable(previous)
    )
      journal = previous;
    else {
      if (previous) await this.archive(previous);
      const requestId = randomUUID();
      const input =
        step === "update"
          ? ({ action: "update", dataPolicy: "preserve" } as const)
          : ({ action: "reinstall", dataPolicy: "reset" } as const);
      journal = {
        version: JOURNAL_VERSION,
        requestId,
        ...input,
        selectedReleaseId: publishedHost.release_id,
        artifact: publishedHost,
        targetApp: this.preparation.config.appPath,
        operation: { requestId, ...input, phase: "preparing", outcome: "pending" },
        supersedesRequestId: stuck.requestId,
        recovery: { episode: stuck.episode, step },
      };
      if (step === "reset") {
        await rm(join(this.journalDirectory, "comma-kept.json"), { force: true });
        const disposalRequestId = await this.localDisposals?.currentDisposalRequest();
        if (disposalRequestId) journal.disposalRequestId = disposalRequestId;
      }
      await this.save(journal);
    }
    await this.submit(
      journal,
      step === "update" ? (sourceApp) => this.assertOpensData(sourceApp) : undefined
    );
    return journal.operation.failureCode === "owner_busy"
      ? "busy"
      : journal.operation.outcome;
  }

  /**
   * Submits one request. When the native owner reports `owner_busy`, Main stops the superseded request's executor
   * and submits again, at most `OWNER_BUSY_ATTEMPTS` times. A precheck refusal stays in the journal.
   */
  private async submit(
    journal: Journal,
    precheck?: (sourceApp: string) => Promise<void>
  ) {
    for (let attempt = 1; ; attempt++) {
      if (journal.supersedesRequestId)
        await this.stopExecutor(journal.supersedesRequestId);
      try {
        await this.execute(journal, precheck);
      } catch (error) {
        if (!(error instanceof HostTargetOlderThanDataError)) throw error;
      }
      if (
        journal.operation.failureCode !== "owner_busy" ||
        attempt >= OWNER_BUSY_ATTEMPTS ||
        this.interrupted
      )
        return;
    }
  }

  /** The pinned release reports a schema range that holds this Mac's local data. Unknown data is not opened. */
  private async assertOpensData(sourceApp: string) {
    const helper = this.helperIn(sourceApp);
    const supported = supportedSchemaOf(
      JSON.parse(await this.run(helper, ["version", "--json"], undefined, 5_000))
    );
    const dataSchema = (await this.hostStatus(helper))?.dataSchema;
    if (
      !supported ||
      dataSchema === undefined ||
      dataSchema > supported.max ||
      (dataSchema !== 0 && dataSchema < supported.min)
    )
      throw new HostTargetOlderThanDataError();
  }

  private helperIn(sourceApp: string) {
    return join(sourceApp, "Contents", "Helpers", "agent-vmm-lifecycle");
  }

  private helper(journal: Journal) {
    if (!journal.sourceApp) throw new Error("Maintenance bundle is not prepared.");
    return this.helperIn(journal.sourceApp);
  }

  private async ownerReceipt(sourceApp: string, requestId?: string) {
    const value = JSON.parse(
      await this.run(
        this.helperIn(sourceApp),
        ["maintenance-status", "--service-type", "auto"],
        JSON.stringify(requestId ? { requestId } : {}),
        5_000
      )
    );
    if (value === null) return null;
    const receipt = nativeReceiptSchema.parse(value);
    if (
      !/^[A-Za-z0-9_-]{1,128}$/.test(receipt.requestId) ||
      (requestId && receipt.requestId !== requestId) ||
      receipt.targetApp !== this.preparation.config.appPath ||
      (receipt.action !== "uninstall" &&
        (!receipt.sourceApp ||
          !receipt.targetReleaseId ||
          !receipt.artifactSha256 ||
          !receipt.artifactSize))
    )
      throw new Error("The current local maintenance receipt is invalid.");
    return receipt;
  }

  private async archive(journal: Journal) {
    const directory = join(this.journalDirectory, "comma-history");
    await mkdir(directory, { recursive: true, mode: 0o700 });
    try {
      await writeFile(
        join(directory, `${journal.requestId}.json`),
        JSON.stringify(journal),
        {
          flag: "wx",
          mode: 0o600,
        }
      );
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    }
  }

  private acceptReceipt(journal: Journal, value: string): Journal["operation"] {
    const receipt = nativeReceiptSchema.parse(JSON.parse(value));
    // The native owner addresses receipts by request id and validated the frozen scope when it accepted it.
    if (receipt.requestId !== journal.requestId)
      throw new Error("Maintenance receipt belongs to another request.");
    if (receipt.outcome === "superseded")
      throw new MaintenanceReplacedError(
        "This maintenance operation was replaced. Continue the latest local maintenance operation."
      );
    const stage = phaseOfStage(receipt.stage);
    return {
      requestId: journal.requestId,
      action: journal.action,
      dataPolicy: journal.dataPolicy,
      phase:
        receipt.outcome === "succeeded"
          ? "completed"
          : receipt.outcome === "failed"
            ? "failed"
            : stage === "preparing"
              ? "checking"
              : stage,
      outcome: receipt.outcome,
      ...(receipt.outcome === "failed"
        ? { failedPhase: stage, retryable: receipt.retryable === true }
        : {}),
      ...(receipt.failureMessage
        ? { problem: receipt.failureMessage.slice(0, 2000) }
        : {}),
      ...(receipt.outcome === "failed" && receipt.failureCode
        ? { failureCode: receipt.failureCode }
        : {}),
    };
  }

  /** `precheck` runs on the staged bundle before the native owner starts; its refusal leaves no effect. */
  private async execute(
    journal: Journal,
    precheck?: (sourceApp: string) => Promise<void>
  ) {
    const before = journal.operation.outcome;
    try {
      if (journal.sourceApp) {
        try {
          journal.operation = this.acceptReceipt(
            journal,
            await this.run(
              this.helper(journal),
              ["maintenance-status", "--service-type", "auto"],
              JSON.stringify({ requestId: journal.requestId }),
              5_000
            )
          );
          if (journal.operation.outcome === "succeeded") {
            await this.save(journal);
            await this.settleReset(journal);
            this.resetConfirmed(journal, before);
            return this.state();
          }
        } catch (error) {
          if (error instanceof MaintenanceReplacedError) throw error;
          /* Restore the same frozen artifact when the helper is missing. */
        }
      }
      await this.preparation.stageMaintenance(
        journal.requestId,
        () => {},
        journal.artifact,
        async (staged) => {
          if (journal.sourceApp && journal.sourceApp !== staged.sourceApp)
            throw new Error(
              "Maintenance recovery material changed its confirmed location."
            );
          Object.assign(journal, staged);
          await this.save(journal);
          await access(this.helper(journal));
          await precheck?.(staged.sourceApp);
          journal.operation = {
            ...journal.operation,
            phase: "checking",
            outcome: "pending",
          };
          delete journal.operation.problem;
          delete journal.operation.failureCode;
          delete journal.operation.failedPhase;
          delete journal.operation.retryable;
          if (journal.recovery)
            journal.recovery.attempts = (journal.recovery.attempts ?? 0) + 1;
          await this.save(journal);
          const receipt = await this.run(
            this.helper(journal),
            ["maintenance", "--service-type", "auto"],
            JSON.stringify({
              version: 1,
              requestId: journal.requestId,
              action: journal.action,
              dataPolicy: journal.dataPolicy,
              targetApp: journal.targetApp,
              ...(journal.supersedesRequestId
                ? { supersedesRequestId: journal.supersedesRequestId }
                : {}),
              ...(journal.action !== "uninstall"
                ? {
                    sourceApp: journal.sourceApp,
                    targetReleaseId: journal.targetReleaseId,
                    artifactSha256: journal.artifactSha256,
                    artifactSize: journal.artifactSize,
                  }
                : {}),
              confirmSharedHost: true,
              ...(journal.dataPolicy === "reset" ? { confirmDataDeletion: true } : {}),
            }),
            15 * 60_000
          );
          journal.operation = this.acceptReceipt(journal, receipt);
        }
      );
    } catch (error) {
      if (error instanceof HostTargetOlderThanDataError) {
        journal.operation = {
          ...journal.operation,
          phase: "failed",
          outcome: "failed",
          problem: error.message,
          failureCode: "target_older_than_data",
          failedPhase: "preparing",
          retryable: false,
        };
        await this.save(journal);
        throw error;
      }
      if (
        error instanceof ComputeNodeCommandError &&
        error.native?.code === "owner_busy"
      ) {
        // The native owner accepted nothing: another executor holds its lock.
        if (journal.recovery?.attempts)
          journal.recovery.attempts = journal.recovery.attempts - 1;
        journal.operation = {
          ...journal.operation,
          phase: "failed",
          outcome: "failed",
          problem: "Another local maintenance process is still running.",
          failureCode: "owner_busy",
          failedPhase: "preparing",
          retryable: true,
        };
        await this.save(journal);
        return this.state();
      }
      try {
        journal.operation = this.acceptReceipt(
          journal,
          await this.run(
            this.helper(journal),
            ["maintenance-status", "--service-type", "auto"],
            JSON.stringify({ requestId: journal.requestId }),
            5_000
          )
        );
      } catch {
        journal.operation = {
          ...journal.operation,
          phase: "failed",
          outcome: "failed",
          problem: (error instanceof Error
            ? error.message
            : "Local maintenance could not be confirmed."
          ).slice(0, 2000),
          // The native owner has no result for this request: Main prepares and submits it again.
          failedPhase: "preparing",
          retryable: true,
        };
        delete journal.operation.failureCode;
      }
    }
    await this.save(journal);
    await this.settleReset(journal);
    this.resetConfirmed(journal, before);
    return this.state();
  }

  private async settleReset(journal: Journal) {
    if (
      journal.dataPolicy === "reset" &&
      journal.operation.outcome === "succeeded" &&
      journal.disposalRequestId
    )
      await this.localDisposals?.supersedeAfterHostReset(
        journal.disposalRequestId,
        journal.requestId
      );
  }
}

/** The failed request's frozen helper is from another release than the pinned one. */
function forwardRequired(journal: Journal) {
  return journal.artifact.release_id !== publishedHost.release_id;
}

/** A person's own reset or uninstall: its replacement needs a new confirmation. Main's recovery is owner-approved. */
function confirmationRequired(journal: Journal) {
  return (
    !journal.recovery &&
    (journal.dataPolicy === "reset" || journal.action === "uninstall")
  );
}

/** Main's automatic recovery update failed retryably `RECOVERY_UPDATE_ATTEMPTS` times. */
function updateSpent(journal: Journal) {
  return (
    journal.recovery?.step === "update" &&
    journal.operation.outcome === "failed" &&
    (journal.recovery.attempts ?? 0) >= RECOVERY_UPDATE_ATTEMPTS
  );
}

/** Main runs this request again with its own request id: it is pending, or failed and the owner may retry it. */
function resumable(journal: Journal) {
  return (
    journal.operation.outcome === "pending" ||
    journal.operation.failureCode === "owner_busy" ||
    (journal.operation.outcome === "failed" && journal.operation.retryable === true)
  );
}

/**
 * The next recovery step for the stuck `active` request. A journal of the same episode either is the active
 * request (its step was accepted and is stuck now) or names it (its step was refused, failed before the native
 * owner accepted it, or is still to be submitted).
 */
function nextStep(
  journal: Journal | undefined,
  active: string
): Pick<StuckRequest, "episode" | "next"> {
  const recovery = journal?.recovery;
  if (
    !recovery ||
    (journal.requestId !== active && journal.supersedesRequestId !== active)
  )
    return { episode: active, next: "update" };
  const unaccepted = journal.requestId !== active && resumable(journal);
  return {
    episode: recovery.episode,
    next: unaccepted
      ? recovery.step
      : recovery.step === "update"
        ? "reset"
        : "exhausted",
  };
}

/** The step of a native receipt stage. A stage before the first effect, such as `accepted`, is preparation. */
function phaseOfStage(stage: string): NonNullable<Journal["operation"]["failedPhase"]> {
  switch (stage) {
    case "stopping":
      return "stopping";
    case "removing":
    case "resetting":
      return "removing";
    case "replacing":
    case "restoring":
      return "installing";
    case "verifying":
    case "complete":
      return "checking";
    default:
      return "preparing";
  }
}

/** The renderer sees only the failure code it maps to an action, and the step where a request failed. */
function projectOperation(
  operation: Journal["operation"]
): NonNullable<HostMaintenanceState["operation"]> {
  const { failureCode, retryable: _retryable, ...rest } = operation;
  return operation.outcome === "failed" && failureCode === "host_start_failed"
    ? { ...rest, failureCode }
    : rest;
}
