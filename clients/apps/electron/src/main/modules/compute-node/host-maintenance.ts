import {
  assertMaintenanceCapable,
  nativeReceiptSchema,
} from "./host-maintenance-protocol";
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
import { AgentVMMHostPreparation, type HostCommand } from "./host-preparation";
import publishedHost from "../../../../../../../.github/agent-vmm-host.json";
import type { LocalComputeOperator } from "./local-operator";

const journalSchema = z.strictObject({
  version: z.literal(1),
  requestId: z.string().uuid(),
  action: z.enum(["update", "reinstall", "uninstall"]),
  dataPolicy: z.enum(["preserve", "reset"]),
  selectedReleaseId: z.string(),
  targetApp: z.string(),
  artifact: z.strictObject({
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
  operation: hostMaintenanceStateSchema.shape.operation.unwrap(),
});
type Journal = z.infer<typeof journalSchema>;
const ownerPolicySchema = z.object({
  version: z.literal(1),
  activeRequest: z.string().optional(),
  latestRequest: z.string().optional(),
  uninstalled: z.boolean(),
  completedRequests: z.record(z.string(), z.boolean()).optional(),
  supersededRequests: z.record(z.string(), z.string()).optional(),
});
type OwnerPolicy = z.infer<typeof ownerPolicySchema>;
class MaintenanceReplacedError extends Error {}

/** This local operator is deliberately independent of the product Session.
 * Native lifecycle owns VM stopping, data deletion, replay fences and completion.
 * Main owns the trusted confirmation and verified artifact delivery, including
 * a receipt that survives an absent/broken application and an interrupted download.
 */
export class LocalHostMaintenance {
  private executing: Promise<HostMaintenanceState> | undefined;
  constructor(
    private readonly preparation: AgentVMMHostPreparation,
    private readonly journalDirectory: string,
    private readonly run: HostCommand,
    private readonly confirm?: (input: HostMaintenanceInput) => Promise<boolean>,
    private readonly localDisposals?: Pick<
      LocalComputeOperator,
      "currentDisposalRequest" | "supersedeAfterHostReset"
    >
  ) {}

  private get journalPath() {
    return join(this.journalDirectory, "comma.json");
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
    await assertMaintenanceCapable(
      this.preparation.config.lifecyclePath,
      this.run,
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
      throw new Error(
        "The local maintenance receipt is unreadable. Keep it for recovery.",
        { cause: error }
      );
    }
  }
  private async save(journal: Journal) {
    await mkdir(this.journalDirectory, { recursive: true, mode: 0o700 });
    await writeFile(`${this.journalPath}.tmp`, JSON.stringify(journal), {
      mode: 0o600,
    });
    await rename(`${this.journalPath}.tmp`, this.journalPath);
  }

  async state(): Promise<HostMaintenanceState> {
    const journal = await this.journal();
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
    return hostMaintenanceStateSchema.parse({
      installation,
      ...(installedReleaseId ? { installedReleaseId } : {}),
      selectedReleaseId: publishedHost.release_id,
      updateAvailable:
        installation === "installed" && installedReleaseId !== publishedHost.release_id,
      ...(journal && !obsolete ? { operation: journal.operation } : {}),
    });
  }

  maintain(input: HostMaintenanceInput) {
    return this.exclusive(async () => {
      hostMaintenanceInputSchema.parse(input);
      const previous = await this.journal();
      const policy = await this.policy();
      let supersedesRequestId: string | undefined;
      if (
        policy?.activeRequest ||
        (previous && previous.operation.outcome !== "succeeded")
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
        } else if (latest?.outcome !== "succeeded") {
          if (
            latest ||
            policy?.activeRequest ||
            previous?.operation.outcome !== "failed"
          )
            throw new Error(
              "Continue the existing maintenance operation before starting another."
            );
        }
        if (
          (supersedesRequestId || latest === null) &&
          !(
            input.action === "uninstall" ||
            (input.action === "reinstall" && input.dataPolicy === "reset")
          )
        )
          throw new Error(
            "Continue the existing maintenance operation before starting another."
          );
      }
      if (previous) await this.settleReset(previous);
      if (!this.confirm || !(await this.confirm(input))) return this.state();
      if (previous) await this.archive(previous);
      const requestId = randomUUID();
      const journal: Journal = {
        version: 1,
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
      return this.execute(journal);
    });
  }

  resume(requestId: string) {
    return this.exclusive(async () => {
      const journal = await this.journal();
      if (!journal || journal.requestId !== requestId)
        throw new Error("The original maintenance confirmation is unavailable.");
      if (journal.operation.outcome === "succeeded") {
        await this.settleReset(journal);
        return this.state();
      }
      return this.execute(journal);
    });
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
      this.executing = undefined;
    }
  }

  private helper(journal: Journal) {
    if (!journal.sourceApp) throw new Error("Maintenance bundle is not prepared.");
    return join(journal.sourceApp, "Contents", "Helpers", "agent-vmm-lifecycle");
  }

  private async ownerReceipt(sourceApp: string, requestId?: string) {
    const value = JSON.parse(
      await this.run(
        join(sourceApp, "Contents", "Helpers", "agent-vmm-lifecycle"),
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
    if (
      receipt.requestId !== journal.requestId ||
      receipt.action !== journal.action ||
      receipt.dataPolicy !== journal.dataPolicy ||
      receipt.supersedesRequestId !== journal.supersedesRequestId ||
      receipt.targetApp !== journal.targetApp ||
      (journal.action !== "uninstall" &&
        (receipt.sourceApp !== journal.sourceApp ||
          receipt.targetReleaseId !== journal.targetReleaseId ||
          receipt.artifactSha256 !== journal.artifactSha256 ||
          receipt.artifactSize !== journal.artifactSize))
    )
      throw new Error("Maintenance receipt does not match the confirmed scope.");
    if (receipt.outcome === "superseded")
      throw new MaintenanceReplacedError(
        "This maintenance operation was replaced. Continue the latest local maintenance operation."
      );
    const phase: Journal["operation"]["phase"] =
      receipt.outcome === "succeeded"
        ? "completed"
        : receipt.outcome === "failed"
          ? "failed"
          : receipt.stage === "stopping"
            ? "stopping"
            : receipt.stage === "removing" || receipt.stage === "resetting"
              ? "removing"
              : receipt.stage === "replacing" || receipt.stage === "restoring"
                ? "installing"
                : "checking";
    return {
      requestId: journal.requestId,
      action: journal.action,
      dataPolicy: journal.dataPolicy,
      phase,
      outcome: receipt.outcome,
      ...(receipt.failureMessage
        ? { problem: receipt.failureMessage.slice(0, 2000) }
        : {}),
    };
  }

  private async execute(journal: Journal) {
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
          journal.operation = {
            ...journal.operation,
            phase: "checking",
            outcome: "pending",
          };
          delete journal.operation.problem;
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
        };
      }
    }
    await this.save(journal);
    await this.settleReset(journal);
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
