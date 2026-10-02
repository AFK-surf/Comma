import { readIntentFile } from "./intent-file";
import { randomUUID } from "node:crypto";
import { link, mkdir, open, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type {
  LocalComputeOverview,
  LocalComputeDisposalResult,
} from "@comma/native-bridge";
import { z } from "zod";
import { ComputeNodeCommandError, runCommand } from "./command";

const decimal = z
  .string()
  .max(20)
  .regex(/^(0|[1-9][0-9]*)$/)
  .refine((value) => BigInt(value) <= 18446744073709551615n);
const environmentPage = z.object({
  bootId: z.string().default(""),
  collectedAt: z.string(),
  nextCursor: z.string().optional(),
  environments: z
    .array(
      z.object({
        id: z.string().min(1).max(200),
        origin: z.enum(["local", "remote"]),
        state: z.enum(["unknown", "observed_active", "retired", "vm_stopped"]),
        registrationId: z.string().optional(),
        allocationId: z.string().optional(),
        allocationGeneration: decimal.optional(),
        revision: decimal,
        privateDiskBytes: decimal.optional(),
        sampledAt: z.string().optional(),
      })
    )
    .max(32)
    .default([]),
});
const diskSummary = z.object({
  collectedAt: z.string(),
  bootId: z.string().default(""),
  guestStateFs: z
    .object({
      usedBytes: decimal,
      capacityBytes: decimal,
      importReservationBytes: decimal,
    })
    .optional(),
});
const planSchema = z.object({
  plan: z
    .object({
      targetKind: z.enum([
        "LOCAL_DISPOSAL_TARGET_KIND_ENVIRONMENT",
        "LOCAL_DISPOSAL_TARGET_KIND_REGISTRATION",
      ]),
      targetId: z.string().min(1).max(200),
      revision: decimal,
      namespaceId: z.string().optional(),
      environmentCount: decimal.default("0"),
      activityUnknown: z.boolean().optional(),
    })
    .passthrough(),
});
const receiptSchema = z.object({
  operation: z
    .object({ id: z.string().min(1), state: z.string().optional() })
    .passthrough(),
});
const savedSchema = z.object({
  request: z.object({
    requestId: z.string().uuid(),
    plan: planSchema.shape.plan,
    irreversibleConfirmation: z.literal(true),
  }),
  operationId: z.string().optional(),
});
const supersessionSchema = z.strictObject({
  version: z.literal(1),
  requestId: z.string().uuid(),
  resetRequestId: z.string().uuid(),
});
type SupersededDisposal = {
  outcome: "superseded";
  requestId: string;
  resetRequestId: string;
};
type Target = {
  kind: string;
  id: string;
  identity: string;
  workload?: import("./install-authorization").LocalWorkloadTarget;
};

/** Pure local operator authority. Cloud Session changes do not stop an accepted disposal. */
export class LocalComputeOperator {
  private targets = new Map<string, Target>();
  private supersessions = new Map<string, SupersededDisposal>();
  private inFlight:
    | { key: string; promise: Promise<LocalComputeDisposalResult> }
    | undefined;
  constructor(
    private readonly options: {
      lifecyclePath: string;
      journalDirectory: string;
      run?: typeof runCommand;
      confirm?: (preview: {
        kind: "environment" | "registration";
        label: string;
        environmentCount: string;
      }) => Promise<boolean>;
    }
  ) {}

  async command(command: string, body: unknown) {
    const output = await (this.options.run ?? runCommand)(
      this.options.lifecyclePath,
      [command, "--service-type", "agent"],
      JSON.stringify(body),
      20_000
    );
    return JSON.parse(output) as unknown;
  }

  async registrationPage(cursor?: string) {
    return z
      .object({
        registrations: z
          .array(
            z.object({
              id: z.string().min(1).max(200),
              revision: decimal.optional(),
              state: z.string().optional(),
            })
          )
          .max(32)
          .default([]),
        nextCursor: z.string().optional(),
      })
      .parse(
        await this.command("local-registrations", cursor ? { afterId: cursor } : {})
      );
  }

  async recoveryProof(
    challenge: import("./install-authorization").ComputeRecoveryChallenge["challenge"]
  ) {
    const result = z
      .object({
        identity: z.object({
          deviceId: z.string().min(1),
          rootPublicKey: z.string().min(1),
          rootKeyRevision: decimal,
          signatureSuite: z.string().optional(),
        }),
        signature: z.string().min(1),
      })
      .parse(await this.command("comma-recovery-proof", challenge));
    const revision = Number(result.identity.rootKeyRevision);
    if (!Number.isSafeInteger(revision) || revision <= 0)
      throw new Error("Host root revision is unavailable.");
    return {
      device_id: result.identity.deviceId,
      root_public_key: result.identity.rootPublicKey,
      root_key_revision: revision,
      signature: result.signature,
      nonce: challenge.nonce,
    };
  }

  async overview(input: { cursor?: string }): Promise<LocalComputeOverview> {
    const disposal = await this.latestDisposal();
    try {
      // One page and one fixed-size summary. No per-environment Guest calls or automatic pagination.
      const page = environmentPage.parse(
        await this.command(
          "local-environments",
          input.cursor ? { afterId: input.cursor } : {}
        )
      );
      const disk = diskSummary.parse(await this.command("local-disk", {}));
      const next = new Map<string, Target>();
      const environments = page.environments.map((row) => {
        const target = {
          kind:
            row.origin === "remote"
              ? "LOCAL_DISPOSAL_TARGET_KIND_REGISTRATION"
              : "LOCAL_DISPOSAL_TARGET_KIND_ENVIRONMENT",
          id: row.origin === "remote" ? (row.registrationId ?? "") : row.id,
          identity: JSON.stringify([
            page.bootId,
            row.id,
            row.registrationId,
            row.allocationId,
            row.allocationGeneration,
            row.revision,
          ]),
          ...(row.registrationId &&
          row.allocationId &&
          row.allocationGeneration &&
          row.allocationGeneration !== "0"
            ? {
                workload: {
                  registration_id: row.registrationId,
                  allocation_id: row.allocationId,
                  generation: row.allocationGeneration,
                },
              }
            : {}),
        };
        const prior = [...this.targets.entries()].find(
          ([, value]) => value.id === target.id && value.identity === target.identity
        );
        const key = prior?.[0] ?? randomUUID();
        next.set(key, prior?.[1] ?? target);
        return {
          key,
          label: row.id.slice(-8),
          origin: row.origin,
          state: row.state,
          ...(row.privateDiskBytes && row.sampledAt
            ? { privateDiskBytes: row.privateDiskBytes, sampledAt: row.sampledAt }
            : {}),
          canDisposeLocal: !!target.id,
          canReadWorkloads: false,
          canOperate: false,
        };
      });
      this.targets = next;
      return {
        availability: "available",
        collectedAt: disk.collectedAt,
        bootId: disk.bootId,
        ...(page.bootId === disk.bootId && disk.guestStateFs
          ? { disk: disk.guestStateFs }
          : {}),
        environments,
        ...(disposal ? { disposal } : {}),
        ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
      };
    } catch (error) {
      this.targets.clear();
      return {
        availability:
          error instanceof ComputeNodeCommandError &&
          error.native?.code === "Unimplemented"
            ? "capability_missing"
            : "unavailable",
        environments: [],
        ...(disposal ? { disposal } : {}),
      };
    }
  }

  workloadTarget(key: string) {
    return this.targets.get(key)?.workload;
  }

  /** Freeze one current local receipt without contacting or mutating the Host. */
  async currentDisposalRequest(): Promise<string | undefined> {
    try {
      return z
        .object({ requestId: z.string().uuid() })
        .parse(
          JSON.parse(
            await readIntentFile(join(this.options.journalDirectory, "current.json"))
          )
        ).requestId;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw error;
    }
  }

  /** Called only after the local maintenance owner confirms a complete data reset.
   * Keep the native receipt and current pointer; a later local task is independent.
   */
  async supersedeAfterHostReset(
    disposalRequestId: string,
    resetRequestId: string
  ): Promise<void> {
    const marker = supersessionSchema.parse({
      version: 1,
      requestId: disposalRequestId,
      resetRequestId,
    });
    const directory = join(this.options.journalDirectory, "superseded");
    const file = join(directory, `${disposalRequestId}.json`);
    // A failed write may already have fenced this process in memory. Retry the
    // durable write rather than treating that in-memory fence as persistence.
    try {
      const existing = supersessionSchema.parse(JSON.parse(await readIntentFile(file)));
      if (existing.requestId !== disposalRequestId)
        throw new Error("Local reset marker identity changed.");
      this.supersessions.set(disposalRequestId, {
        outcome: "superseded",
        requestId: disposalRequestId,
        resetRequestId: existing.resetRequestId,
      });
      return;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    // Stop this process from admitting a late resume while its marker is written.
    this.supersessions.set(disposalRequestId, {
      outcome: "superseded",
      requestId: disposalRequestId,
      resetRequestId,
    });
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const temporary = join(directory, `.${disposalRequestId}-${randomUUID()}.tmp`);
    try {
      const handle = await open(temporary, "wx", 0o600);
      try {
        await handle.writeFile(JSON.stringify(marker));
        await handle.sync();
      } finally {
        await handle.close();
      }
      try {
        await link(temporary, file);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        const existing = supersessionSchema.parse(
          JSON.parse(await readIntentFile(file))
        );
        if (existing.requestId !== disposalRequestId)
          throw new Error("Local reset marker identity changed.", { cause: error });
        this.supersessions.set(disposalRequestId, {
          outcome: "superseded",
          requestId: disposalRequestId,
          resetRequestId: existing.resetRequestId,
        });
      }
      const ownerDirectory = await open(directory, "r");
      try {
        await ownerDirectory.sync();
      } finally {
        await ownerDirectory.close();
      }
    } finally {
      await rm(temporary, { force: true });
    }
  }

  private async superseded(requestId: string): Promise<SupersededDisposal | undefined> {
    const known = this.supersessions.get(requestId);
    if (known) return known;
    try {
      const marker = supersessionSchema.parse(
        JSON.parse(
          await readIntentFile(
            join(this.options.journalDirectory, "superseded", `${requestId}.json`)
          )
        )
      );
      if (marker.requestId !== requestId)
        throw new Error("Local reset marker identity changed.");
      const result: SupersededDisposal = {
        outcome: "superseded",
        requestId,
        resetRequestId: marker.resetRequestId,
      };
      this.supersessions.set(requestId, result);
      return result;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT")
        return this.supersessions.get(requestId);
      throw error;
    }
  }

  dispose(input: { key: string }) {
    if (this.inFlight) {
      if (this.inFlight.key !== input.key)
        throw new Error("A local deletion confirmation is already open.");
      return this.inFlight.promise;
    }
    const pending = this.execute(input);
    this.inFlight = { key: input.key, promise: pending };
    void pending
      .finally(() => {
        if (this.inFlight?.promise === pending) this.inFlight = undefined;
      })
      .catch(() => undefined);
    return pending;
  }

  private async execute(input: { key: string }): Promise<LocalComputeDisposalResult> {
    const target = this.targets.get(input.key);
    if (!target || !this.options.confirm)
      throw new Error(
        "Open the current local environment and review its deletion scope."
      );
    const preview = planSchema.parse(
      await this.command("local-plan", { targetKind: target.kind, targetId: target.id })
    ).plan;
    if (
      preview.targetKind !== target.kind ||
      preview.targetId !== target.id ||
      preview.revision === "0"
    )
      throw new Error("Local deletion target changed.");
    const confirmed = await this.options.confirm({
      kind: target.kind.endsWith("REGISTRATION") ? "registration" : "environment",
      label: target.id.slice(-8),
      environmentCount: preview.environmentCount,
    });
    if (!confirmed) return { outcome: "cancelled" };
    if (this.targets.get(input.key) !== target)
      throw new Error("The local environment changed. Review its current scope.");
    const request = {
      requestId: randomUUID(),
      plan: preview,
      irreversibleConfirmation: true as const,
    };
    const file = join(this.options.journalDirectory, `${request.requestId}.json`);
    await this.save(file, { request });
    await this.savePointer(request.requestId);
    const superseded = await this.superseded(request.requestId);
    if (superseded) return superseded;
    try {
      const receipt = receiptSchema.parse(
        await this.command("local-execute", request)
      ).operation;
      await this.save(file, { request, operationId: receipt.id });
      const completedReset = await this.superseded(request.requestId);
      if (completedReset) return completedReset;
      return {
        outcome:
          receipt.state === "OPERATION_STATE_SUCCEEDED" ? "completed" : "pending",
        requestId: request.requestId,
        operationId: receipt.id,
      };
    } catch (error) {
      const completedReset = await this.superseded(request.requestId);
      if (completedReset) return completedReset;
      if (
        error instanceof ComputeNodeCommandError &&
        error.reason === "outcome_unknown"
      )
        return { outcome: "unknown", requestId: request.requestId };
      throw error;
    }
  }

  async resume(requestId: string): Promise<LocalComputeDisposalResult> {
    if (!z.string().uuid().safeParse(requestId).success)
      throw new Error("Invalid local deletion receipt.");
    const superseded = await this.superseded(requestId);
    if (superseded) return superseded;
    const file = join(this.options.journalDirectory, `${requestId}.json`);
    const saved = savedSchema.parse(JSON.parse(await readIntentFile(file)));
    if (saved.request.requestId !== requestId)
      throw new Error("Local deletion receipt identity changed.");
    const replaced = await this.superseded(requestId);
    if (replaced) return replaced;
    try {
      const response = saved.operationId
        ? await this.command("local-operation", { operationId: saved.operationId })
        : await this.command("local-execute", saved.request);
      const receipt = receiptSchema.parse(response).operation;
      if (saved.operationId && receipt.id !== saved.operationId)
        throw new Error("Local deletion receipt identity changed.");
      await this.save(file, { request: saved.request, operationId: receipt.id });
      return (
        (await this.superseded(requestId)) ?? {
          outcome:
            receipt.state === "OPERATION_STATE_SUCCEEDED" ? "completed" : "pending",
          requestId,
          operationId: receipt.id,
        }
      );
    } catch (error) {
      const completedReset = await this.superseded(requestId);
      if (completedReset) return completedReset;
      throw error;
    }
  }

  private async savePointer(requestId: string) {
    const file = join(this.options.journalDirectory, "current.json");
    await writeFile(`${file}.tmp`, JSON.stringify({ requestId }), { mode: 0o600 });
    await rename(`${file}.tmp`, file);
  }

  private async latestDisposal(): Promise<LocalComputeOverview["disposal"]> {
    try {
      const pointer = z
        .object({ requestId: z.string().uuid() })
        .parse(
          JSON.parse(
            await readIntentFile(join(this.options.journalDirectory, "current.json"))
          )
        );
      const superseded = await this.superseded(pointer.requestId);
      if (superseded) return superseded;
      const file = join(this.options.journalDirectory, `${pointer.requestId}.json`);
      const saved = savedSchema.parse(JSON.parse(await readIntentFile(file)));
      if (saved.request.requestId !== pointer.requestId) return undefined;
      if (!saved.operationId)
        return (
          (await this.superseded(pointer.requestId)) ?? {
            requestId: pointer.requestId,
            outcome: "unknown",
          }
        );
      let outcome: "completed" | "pending" | "unknown" = "unknown";
      try {
        const receipt = receiptSchema.parse(
          await this.command("local-operation", { operationId: saved.operationId })
        ).operation;
        if (receipt.id !== saved.operationId)
          return (
            (await this.superseded(pointer.requestId)) ?? {
              requestId: pointer.requestId,
              outcome: "unknown",
            }
          );
        outcome =
          receipt.state === "OPERATION_STATE_SUCCEEDED" ? "completed" : "pending";
      } catch {
        /* The original receipt remains queryable after its Host returns. */
      }
      return (
        (await this.superseded(pointer.requestId)) ?? {
          requestId: pointer.requestId,
          operationId: saved.operationId,
          outcome,
        }
      );
    } catch {
      return undefined;
    }
  }

  private async save(file: string, value: z.infer<typeof savedSchema>) {
    await mkdir(dirname(file), { recursive: true });
    await writeFile(`${file}.tmp`, JSON.stringify(value), { mode: 0o600 });
    await rename(`${file}.tmp`, file);
  }
}
