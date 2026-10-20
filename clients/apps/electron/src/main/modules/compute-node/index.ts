import { ComputeNodeCommandError } from "./command";
import {
  absentObservation,
  type ComputeNodeRuntimeAdapter,
  type ComputeNodeRuntimeObservation,
} from "./runtime-adapter";
export {
  ComputeNodeCommandError,
  defaultAgentVMMHostLifecyclePath,
  runCommand,
} from "./command";
export {
  AgentVMMCommandAdapter,
  type ComputeNodeRuntimeAdapter,
  type ComputeNodeRuntimeObservation,
} from "./runtime-adapter";
import { AsyncLocalStorage } from "node:async_hooks";
import type { HostPreparation, HostPreparationState } from "./host-preparation";
import { randomUUID } from "node:crypto";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type {
  ComputeNodeConfigureInput,
  ComputeNodeExpectedBinding,
  ComputeNodeOperation,
  ComputeNodeProblem,
  ComputeNodeState,
} from "@comma/native-bridge";
import { z } from "zod";
import { readIntentFile } from "./intent-file";
import { redactNativeObservation } from "../observability";
import {
  computeNodeOperationSchema,
  computeNodeStateSchema,
} from "@comma/native-bridge";

class ComputeNodeBindingChangedError extends Error {}
export class ComputeNodeSessionChangedError extends Error {
  constructor() {
    super("The compute node session changed. Review the current node.");
  }
}

export type ComputeNodeWorkActivity = "idle" | "active" | "unknown";

import {
  ComputeNodeAuthorizationNotFoundError,
  type ComputeNodeInstallAuthorizationOwner,
} from "./install-authorization";
export {
  ComputeNodeInstallAuthorization,
  type ComputeNodeInstallAuthorizationOwner,
} from "./install-authorization";

const savedId = z.string().min(1).max(200);
const persistedIntentSchema = z.strictObject({
  desiredEnabled: z.boolean(),
  installOperationId: savedId.optional(),
  installAppliedOperationId: savedId.optional(),
  registrationId: savedId.optional(),
  workspaceId: savedId.optional(),
  operation: computeNodeOperationSchema.optional(),
  remoteRevocationConfirmed: z.boolean().optional(),
  initializationPending: z.boolean().optional(),
  receiptMissing: z.boolean().optional(),
  /** One user-initiated enable already restarted an install whose material handoff expired. */
  handoffRestartUsed: z.boolean().optional(),
  recoveryPending: z
    .strictObject({
      operationId: savedId,
      workspaceId: savedId,
      registrationId: savedId,
      environmentId: savedId,
    })
    .optional(),
  revision: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
  version: z.union([z.literal(1), z.literal(2), z.literal(3), z.literal(4)]),
  accountOwner: z
    .strictObject({ audience: z.string().min(1).max(2048), subject: savedId })
    .optional(),
});
type PersistedIntent = z.infer<typeof persistedIntentSchema>;

export interface ComputeNodeServiceOptions {
  adapter: ComputeNodeRuntimeAdapter;
  preparation?: HostPreparation;
  installationBlocked?: (operationId: string) => Promise<boolean>;
  /** Rejects while local Host maintenance forbids a new installation. */
  assertInstallationAllowed?: () => Promise<void>;
  /** Main's diagnostic log. It receives bounded, redacted lines only. */
  log?: (line: string) => void;
  filePath: string;
  onStateChanged?: ((state: ComputeNodeState) => void) | undefined;
  installAuthorization?: ComputeNodeInstallAuthorizationOwner | undefined;
  platform?: NodeJS.Platform | undefined;
  arch?: string | undefined;
  initializationWaitMs?: number;
  authorityGeneration?: () => string | undefined;
  accountOwner?: { audience: string; subject: string };
}

export class ComputeNodeService {
  private intent: PersistedIntent = { desiredEnabled: false, revision: 1, version: 3 };
  private snapshot: ComputeNodeState;
  private intentReadable = true;
  private tail: Promise<unknown> = Promise.resolve();
  private workActivity: ComputeNodeWorkActivity = "unknown";
  private productUnavailable = false;
  private installationBlocked = false;
  private installationPhase:
    | import("./install-authorization").ComputeNodeInstallAuthorizationPhase
    | undefined;
  private installationErrorCode: string | undefined;
  private loggedInstallationFailure: string | undefined;
  private refreshPromise: Promise<ComputeNodeState> | undefined;
  private observationFresh = false;
  private observedAt?: string;
  private readonly operationAuthority = new AsyncLocalStorage<{
    generation: string | undefined;
  }>();

  private constructor(private readonly options: ComputeNodeServiceOptions) {
    this.options = {
      ...options,
      adapter: this.fenceEffects(options.adapter, "runtime"),
      ...(options.installAuthorization
        ? {
            installAuthorization: this.fenceEffects(
              options.installAuthorization,
              "authorization"
            ),
          }
        : {}),
      ...(options.preparation
        ? { preparation: this.fenceEffects(options.preparation) }
        : {}),
    };
    if (options.accountOwner)
      this.intent = { ...this.intent, version: 4, accountOwner: options.accountOwner };
    const eligible =
      (options.platform ?? process.platform) === "darwin" &&
      (options.arch ?? process.arch) === "arm64";
    this.snapshot = computeNodeStateSchema.parse({
      desiredEnabled: false,
      preparation: options.preparation?.state(),
      eligibility: eligible
        ? { eligible: true }
        : { eligible: false, reason: "Compute node requires Apple silicon macOS." },
      observed: absentObservation,
      facets: facetsFor(eligible ? "not_set" : "action_required", absentObservation),
      revision: 1,
      status: eligible ? "not_set" : "action_required",
    });
  }

  static async open(options: ComputeNodeServiceOptions) {
    const service = new ComputeNodeService(options);
    await service.initialize();
    if (service.snapshot.eligibility.eligible) {
      void service.run(() => service.reconcile()).catch(() => undefined);
    }
    return service;
  }

  recoverBinding(
    expected: import("./install-authorization").RecoveredComputeBinding,
    consume: () => Promise<import("./install-authorization").RecoveredComputeBinding>
  ) {
    return this.run(async () => {
      this.requireIntentReadable();
      this.intent.recoveryPending = {
        operationId: expected.id,
        workspaceId: expected.scope_key,
        registrationId: expected.registration_id,
        environmentId: expected.environment_id,
      };
      await this.persistIntent();
      const accepted = await consume();
      if (
        accepted.id !== expected.id ||
        accepted.registration_id !== expected.registration_id ||
        accepted.environment_id !== expected.environment_id ||
        accepted.scope_key !== expected.scope_key
      )
        throw new Error("Recovery binding changed.");
      // The effect may already be committed after logout. Only the original account receives it.
      await this.applyRecoveredBinding(accepted);
      this.requireCurrentAuthority();
      return this.reconcile();
    });
  }

  private async applyRecoveredBinding(
    binding: import("./install-authorization").RecoveredComputeBinding
  ) {
    this.requireIntentReadable();
    // Persist an accepted cloud transfer to this original account even if its Session ended.
    // Preserve an earlier failed request as evidence; never replay it as this recovered installation.
    if (
      this.intent.installOperationId &&
      this.intent.installOperationId !== binding.id
    ) {
      const archive = `${this.options.filePath}.recoveries`;
      await mkdir(archive, { recursive: true });
      const file = join(
        archive,
        `${Buffer.from(this.intent.installOperationId).toString("base64url")}.json`
      );
      await writeFile(`${file}.tmp`, JSON.stringify(this.intent), { mode: 0o600 });
      await rename(`${file}.tmp`, file);
    }
    this.intent = {
      version: this.options.accountOwner ? 4 : 3,
      ...(this.options.accountOwner ? { accountOwner: this.options.accountOwner } : {}),
      revision: this.intent.revision + 1,
      desiredEnabled: binding.status !== "stopped",
      workspaceId: binding.scope_key,
      installOperationId: binding.id,
      installAppliedOperationId: binding.id,
      registrationId: binding.registration_id,
    };
    await this.writeIntent(false);
  }

  state(): ComputeNodeState {
    return structuredClone(this.snapshot);
  }

  refresh() {
    if (this.refreshPromise) return this.refreshPromise;
    const result = this.run(async () => {
      try {
        return await this.reconcile(false);
      } catch {
        this.observationFresh = false;
        this.workActivity = "unknown";
        return this.publish("action_required", {
          ...this.snapshot.observed,
          readability: "unreadable",
        });
      }
    });
    this.refreshPromise = result;
    void result
      .finally(() => {
        this.refreshPromise = undefined;
      })
      .catch(() => undefined);
    return result;
  }

  configure(input: ComputeNodeConfigureInput) {
    return this.run(() => this.configureInternal(input, true));
  }

  private async configureInternal(input: ComputeNodeConfigureInput, explicit: boolean) {
    {
      this.requireEligible();
      this.requireIntentReadable();
      if (this.intent.recoveryPending)
        throw new Error(
          "Check the accepted recovery result before changing this connection."
        );
      if (!input.desiredEnabled) return this.drainInternal();
      if (!input.workspaceId) {
        throw new Error("Select a workspace before enabling this compute node.");
      }
      if (!this.options.installAuthorization) {
        throw new Error("Compute node product authorization is unavailable.");
      }
      if (this.intent.workspaceId && this.intent.workspaceId !== input.workspaceId) {
        throw new Error("Remove the existing compute node before changing workspace.");
      }

      if (await this.readInstallationFence())
        return this.publish("action_required", await this.observeAfterFailure());

      if (this.intent.installOperationId) {
        const current = await this.options.adapter.observe(this.intent.registrationId);
        if (this.installationFailure(current)?.retryable === false)
          return this.publish("action_required", current);
      }

      // Persist the user's target before crossing the helper side-effect
      // boundary. A process exit after install but before the final
      // observation must recover toward enabled, not toward the old value.
      const wasEnabled = this.intent.desiredEnabled;
      delete this.intent.remoteRevocationConfirmed;
      // Each user-initiated enable allows one automatic restart after an expired material handoff.
      if (explicit) delete this.intent.handoffRestartUsed;
      this.intent.desiredEnabled = true;
      this.intent.workspaceId = input.workspaceId;
      if (
        !this.intent.installOperationId &&
        this.intent.operation?.kind === "configure"
      ) {
        // A lost authorization response must retry the same server idempotency
        // key. No registration exists until exchange, so replacing this key
        // would strand a pending operation instead of converging it.
        this.intent.operation.outcome = "pending";
      } else {
        this.beginOperation("configure");
      }
      this.publish("processing");
      await this.persistIntent();
      let observed: ComputeNodeRuntimeObservation;
      let stage = "preparation";
      try {
        await this.options.preparation?.ensure((preparation) =>
          this.reportPreparation(preparation)
        );
        const operation = this.intent.operation;
        if (!operation) {
          throw new Error("Compute node authorization identity is unavailable.");
        }
        stage = "inspect";
        let projection =
          this.intent.installOperationId && this.snapshot.status !== "removed"
            ? await this.options.installAuthorization.inspect({
                operationId: this.intent.installOperationId,
                workspaceId: input.workspaceId,
              })
            : undefined;
        if (projection && handoffExpired(projection)) {
          // The server revoked this Registration and cannot resume the operation.
          // Keep it as evidence and request a new installation with this fresh request id.
          await this.archiveInstallation();
          projection = undefined;
        }
        if (projection && this.intent.installOperationId) {
          const operationId = this.intent.installOperationId;
          if (projection.authorizationStatus === "requested") {
            stage = "retry";
            const authorization = await this.options.installAuthorization.retry({
              operationId,
              workspaceId: input.workspaceId,
            });
            this.intent.registrationId = authorization.registrationId;
            await this.persistIntent();
            stage = "install";
            await this.options.adapter.install(operationId, authorization.descriptor);
            this.intent.installAppliedOperationId = operationId;
          } else if (projection.authorizationStatus === "exchange_committed") {
            stage = "resume";
            await this.options.adapter.resume(operationId, operation.requestId);
            this.intent.installAppliedOperationId = operationId;
          } else if (projection.authorizationStatus === "handed_off") {
            const needsResume = this.intent.installAppliedOperationId !== operationId;
            if (this.intent.installAppliedOperationId !== operationId) {
              stage = "resume";
              // ACK records durable material delivery, not completed enrollment.
              // The helper owns the original plan and refuses an absent or invalid one.
              await this.options.adapter.resume(operationId, operation.requestId);
              this.intent.installAppliedOperationId = operationId;
              delete this.intent.receiptMissing;
              await this.persistIntent();
            }
            // Do not restart a healthy connection just to retry its Shell.
            // Re-enabling admission does not depend on initial Shell creation.
            if (needsResume || !wasEnabled || projection.status !== "ready") {
              stage = "enable";
              await this.options.installAuthorization.configure({
                enabled: true,
                operationId,
                workspaceId: input.workspaceId,
              });
              await this.options.adapter.enable(
                operation.requestId,
                this.intent.registrationId
              );
            }
          } else {
            throw new Error(
              projection.authorizationStatus === "revoked"
                ? "Compute node installation was removed."
                : "Compute node installation requires operator action."
            );
          }
        } else {
          stage = "authorize";
          const authorization = await this.options.installAuthorization.authorize({
            requestId: operation.requestId,
            workspaceId: input.workspaceId,
          });
          this.intent.installOperationId = authorization.operationId;
          this.intent.registrationId = authorization.registrationId;
          operation.operationId = authorization.operationId;
          await this.persistIntent();
          stage = "install";
          await this.options.adapter.install(
            authorization.operationId,
            authorization.descriptor
          );
          this.intent.installAppliedOperationId = authorization.operationId;
        }
        stage = "observe";
        observed = await this.options.adapter.observe(this.intent.registrationId);
      } catch (error) {
        const problem = isUnknownFailure(error) ? "setup_unknown" : "setup_failed";
        this.logSetupFailure(problem, stage, error);
        observed = await this.observeAfterFailure();
        this.finishOperation(isUnknownFailure(error) ? "unknown" : "failed");
        await this.persistIntent();
        if (await this.readInstallationFence())
          return this.publish("action_required", observed);
        this.publish("action_required", observed, problem);
        throw error;
      }
      observed = await this.observeProductStatus(observed);
      if (observed.salix === "degraded") {
        this.logSetupFailure(
          "authorization_attention",
          "product_status",
          this.installationErrorCode ?? this.installationPhase ?? "unavailable"
        );
        this.finishOperation("failed");
        await this.persistIntent();
        this.publish("action_required", observed, "authorization_attention");
        throw new Error("Compute node product authorization requires attention.");
      }
      this.intent.initializationPending = true;
      await this.persistIntent();
      try {
        await this.initializeWorkload();
        delete this.intent.initializationPending;
        this.finishOperation("succeeded");
      } catch (error) {
        this.logSetupFailure("operation_failed", "initialize_shell", error);
        this.finishOperation("failed");
        await this.persistIntent();
        throw error;
      }
      await this.persistIntent();
      return this.reconcile();
    }
  }

  /** Archives the current installation and detaches it, the way an explicit removal keeps its record. */
  private async archiveInstallation() {
    const operationId = this.intent.installOperationId;
    if (!operationId) return;
    const directory = `${this.options.filePath}.removals`;
    await mkdir(directory, { recursive: true });
    const file = join(
      directory,
      `${Buffer.from(operationId).toString("base64url")}.json`
    );
    await writeFile(`${file}.tmp`, JSON.stringify(this.intent), { mode: 0o600 });
    this.requireCurrentAuthority();
    await rename(`${file}.tmp`, file);
    delete this.intent.installOperationId;
    delete this.intent.installAppliedOperationId;
    delete this.intent.registrationId;
    delete this.intent.initializationPending;
    delete this.intent.receiptMissing;
    this.installationPhase = undefined;
    this.installationErrorCode = undefined;
  }

  /**
   * The server revoked the current install because its material handoff expired.
   * Start one new installation for the same workspace per user-initiated enable.
   */
  private async restartExpiredInstallation(): Promise<ComputeNodeState | undefined> {
    const workspaceId = this.intent.workspaceId;
    if (
      !this.handoffExpiredHere() ||
      !workspaceId ||
      this.intent.handoffRestartUsed ||
      this.intent.recoveryPending ||
      this.installationBlocked ||
      !this.snapshot.eligibility.eligible ||
      !this.intentReadable
    )
      return undefined;
    try {
      await this.options.assertInstallationAllowed?.();
    } catch {
      // Local Host maintenance owns the Host now. A later observation retries.
      this.requireCurrentAuthority();
      return undefined;
    }
    this.requireCurrentAuthority();
    await this.archiveInstallation();
    this.intent.handoffRestartUsed = true;
    this.beginOperation("configure");
    await this.persistIntent();
    try {
      return await this.configureInternal({ desiredEnabled: true, workspaceId }, false);
    } catch (error) {
      if (
        error instanceof ComputeNodeBindingChangedError ||
        error instanceof ComputeNodeSessionChangedError
      )
        throw error;
      // The setup path already logged and published its failure. Show the current result.
      return this.reconcile(false);
    }
  }

  /** The current account's install operation expired before its material handoff, with enable still desired. */
  private handoffExpiredHere() {
    return (
      this.intent.desiredEnabled &&
      !!this.intent.installOperationId &&
      !this.intent.remoteRevocationConfirmed &&
      this.intent.operation?.kind !== "remove" &&
      this.intent.operation?.kind !== "drain" &&
      handoffExpired({
        authorizationStatus: this.installationPhase,
        errorCode: this.installationErrorCode,
      })
    );
  }

  private logSetupFailure(problem: ComputeNodeProblem, stage: string, error: unknown) {
    const message =
      error instanceof Error ? error.message : typeof error === "string" ? error : "";
    this.options.log?.(
      `compute-node setup failed: problem=${problem} stage=${redactDiagnostic(stage).slice(0, 64)} message=${JSON.stringify(redactDiagnostic(message))}`
    );
  }

  private async initializeWorkload() {
    // One enable action waits for one node (at most 30 s, on the client core's Clock) and initializes it once.
    // The mutation requires explicit retry on failure.
    await this.options.installAuthorization!.initializeWorkload({
      operationId: this.intent.installOperationId!,
      workspaceId: this.intent.workspaceId!,
      ...(this.options.initializationWaitMs === undefined
        ? {}
        : { waitMs: this.options.initializationWaitMs }),
    });
  }

  rebuild() {
    return this.run(async () => {
      this.requireEligible();
      this.requireIntentReadable();
      if (!this.options.preparation)
        throw new Error("Host build configuration is unavailable.");
      this.beginOperation("rebuild");
      await this.persistIntent();
      this.publish("processing");
      try {
        await this.options.preparation.rebuild((preparation) =>
          this.reportPreparation(preparation)
        );
        this.finishOperation("succeeded");
        await this.persistIntent();
        return this.reconcile();
      } catch (error) {
        this.finishOperation("failed");
        await this.persistIntent();
        this.publish(
          "action_required",
          await this.observeAfterFailure(),
          "rebuild_failed",
          errorDetail(error)
        );
        throw error;
      }
    });
  }

  private reportPreparation(preparation: HostPreparationState) {
    this.snapshot = { ...this.snapshot, preparation };
    this.publish("processing");
  }

  repair() {
    return this.run(async () => {
      this.requireEligible();
      this.requireIntentReadable();
      this.beginOperation("repair");
      this.publish("processing");
      await this.persistIntent();
      try {
        await this.options.adapter.repair(this.intent.operation?.requestId);
      } catch (error) {
        const observed = await this.observeAfterFailure();
        if (
          isUnknownFailure(error) &&
          observed.readability === "readable" &&
          observed.salix === "ready"
        ) {
          this.finishOperation("succeeded");
          await this.persistIntent();
          return this.reconcile();
        }
        this.finishOperation(isUnknownFailure(error) ? "unknown" : "failed");
        await this.persistIntent();
        this.publish("action_required", observed, "repair_failed", errorDetail(error));
        throw error;
      }
      this.finishOperation("succeeded");
      return this.reconcile();
    });
  }

  drain(expected?: ComputeNodeExpectedBinding) {
    return this.run(() => {
      this.requireBinding(expected);
      return this.drainInternal();
    });
  }

  remove(expected?: ComputeNodeExpectedBinding) {
    return this.run(async () => {
      this.requireBinding(expected);
      this.requireEligible();
      this.requireIntentReadable();
      if (
        this.intent.operation?.kind === "remove" &&
        this.intent.operation.outcome !== "succeeded"
      ) {
        this.intent.operation.outcome = "pending";
      } else this.beginOperation("remove");
      this.intent.desiredEnabled = false;
      this.publish("processing");
      await this.persistIntent();
      let unavailableRegistration = false;
      try {
        const workspaceId = this.intent.workspaceId;
        const installOperationId = this.intent.installOperationId;
        if (!workspaceId || !installOperationId || !this.options.installAuthorization) {
          throw new Error("Compute node product authorization is unavailable.");
        }
        try {
          if (!this.intent.remoteRevocationConfirmed) {
            await this.options.installAuthorization.revoke({
              operationId: installOperationId,
              workspaceId,
            });
            this.intent.remoteRevocationConfirmed = true;
            await this.persistIntent();
          }
        } catch (error) {
          // A scoped 404 can hide an inaccessible registration. Only an explicit
          // removal may detach it locally; never claim remote revocation.
          if (!(error instanceof ComputeNodeAuthorizationNotFoundError)) throw error;
          unavailableRegistration = true;
        }
        const local = await this.options.adapter.observe(this.intent.registrationId);
        if (local.registration === "unreadable" || local.readability !== "readable") {
          throw new Error(
            "The local registration could not be read. Check the Host connection."
          );
        }
        if (unavailableRegistration && local.registration !== "absent") {
          throw new Error(
            "This session cannot revoke the registration. Use local VMM management."
          );
        }
        if (local.registration !== "absent")
          await this.options.adapter.remove(
            this.intent.operation?.requestId,
            this.intent.registrationId
          );
      } catch (error) {
        const observed = await this.observeAfterFailure();
        this.finishOperation(isUnknownFailure(error) ? "unknown" : "failed");
        await this.persistIntent();
        this.publish("action_required", observed, "removal_failed", errorDetail(error));
        throw error;
      }
      let observed = await this.options.adapter.observe(this.intent.registrationId);
      if (!unavailableRegistration)
        observed = await this.observeProductStatus(observed);
      if (
        observed.readability !== "readable" ||
        !this.localRemovalConfirmed(observed)
      ) {
        this.finishOperation("unknown");
        await this.persistIntent();
        return this.publish("action_required", observed, "removal_unconfirmed");
      }
      this.finishOperation("succeeded");
      this.intent.remoteRevocationConfirmed = !unavailableRegistration;
      if (unavailableRegistration && this.intent.operation) {
        // Preserve the original account's unresolved cloud result before clearing its current binding.
        const directory = `${this.options.filePath}.removals`;
        await mkdir(directory, { recursive: true });
        this.requireCurrentAuthority();
        const address = Buffer.from(this.intent.operation.requestId).toString(
          "base64url"
        );
        const target = join(directory, `${address}.json`);
        await writeFile(`${target}.tmp`, JSON.stringify(this.intent), { mode: 0o600 });
        this.requireCurrentAuthority();
        await rename(`${target}.tmp`, target);
      }
      delete this.intent.workspaceId;
      delete this.intent.installOperationId;
      delete this.intent.installAppliedOperationId;
      delete this.intent.registrationId;
      delete this.intent.initializationPending;
      delete this.intent.receiptMissing;
      await this.persistIntent();
      return this.publish(
        "removed",
        observed,
        unavailableRegistration ? "remote_revocation_unconfirmed" : undefined
      );
    });
  }

  abandon(expected: ComputeNodeExpectedBinding) {
    return this.run(async () => {
      this.requireBinding(expected);
      this.requireIntentReadable();
      const operationId = this.intent.installOperationId,
        workspaceId = this.intent.workspaceId;
      if (
        !operationId ||
        !workspaceId ||
        this.intent.installAppliedOperationId ||
        this.intent.recoveryPending ||
        !this.options.installAuthorization?.abandon
      )
        throw new Error("This unfinished request cannot be closed here.");
      // The cloud owner checks original subject, scope, and absence of any accepted exchange under its row lock.
      await this.options.installAuthorization.abandon({ operationId, workspaceId });
      await this.completeAbandon();
      this.requireCurrentAuthority();
      return this.publish("removed");
    });
  }

  private async completeAbandon() {
    this.intent.remoteRevocationConfirmed = true;
    const directory = `${this.options.filePath}.removals`;
    await mkdir(directory, { recursive: true });
    const file = join(
      directory,
      `${Buffer.from(this.intent.installOperationId!).toString("base64url")}.json`
    );
    await writeFile(`${file}.tmp`, JSON.stringify(this.intent), { mode: 0o600 });
    await rename(`${file}.tmp`, file);
    this.intent.desiredEnabled = false;
    delete this.intent.workspaceId;
    delete this.intent.installOperationId;
    delete this.intent.registrationId;
    delete this.intent.initializationPending;
    delete this.intent.receiptMissing;
    this.beginOperation("remove");
    this.finishOperation("succeeded");
    await this.writeIntent(false);
  }

  private async initialize() {
    try {
      const parsed = persistedIntentSchema.parse(
        JSON.parse(await readIntentFile(this.options.filePath))
      );
      const savedOwner = parsed.accountOwner;
      if (
        this.options.accountOwner &&
        (savedOwner?.audience !== this.options.accountOwner.audience ||
          savedOwner?.subject !== this.options.accountOwner.subject)
      ) {
        throw new Error("Saved intent belongs to another account.");
      }
      this.intent = { ...parsed, version: this.options.accountOwner ? 4 : 3 };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        this.intentReadable = false;
        this.publish(
          "action_required",
          undefined,
          "intent_unreadable",
          errorDetail(error)
        );
        return;
      }
    }
    if (this.snapshot.eligibility.eligible) {
      this.publish(this.intent.desiredEnabled ? "action_required" : "not_set");
    }
  }

  private async drainInternal() {
    this.requireEligible();
    this.requireIntentReadable();
    this.beginOperation("drain");
    this.intent.desiredEnabled = false;
    this.publish("processing");
    await this.persistIntent();
    try {
      const workspaceId = this.intent.workspaceId;
      const installOperationId = this.intent.installOperationId;
      if (!workspaceId || !installOperationId || !this.options.installAuthorization) {
        throw new Error("Compute node product authorization is unavailable.");
      }
      await this.options.installAuthorization.configure({
        enabled: false,
        operationId: installOperationId,
        workspaceId,
      });
      await this.options.adapter.drain(
        this.intent.operation?.requestId,
        this.intent.registrationId
      );
    } catch (error) {
      const observed = await this.observeAfterFailure();
      if (
        isUnknownFailure(error) &&
        observed.readability === "readable" &&
        (observed.registrationState === "draining" ||
          observed.registrationState === "revoked" ||
          observed.registration === "absent")
      ) {
        this.finishOperation("succeeded");
        await this.persistIntent();
        return this.reconcile();
      }
      this.finishOperation(isUnknownFailure(error) ? "unknown" : "failed");
      await this.persistIntent();
      this.publish("action_required", observed, "stop_failed", errorDetail(error));
      throw error;
    }
    this.finishOperation("succeeded");
    return this.reconcile();
  }

  private async readInstallationFence() {
    const operationId = this.intent.installOperationId;
    const blocked = !!(
      operationId && (await this.options.installationBlocked?.(operationId))
    );
    this.requireCurrentAuthority();
    this.installationBlocked = blocked;
    return blocked;
  }

  private async reconcile(settleOperation = true) {
    await this.readInstallationFence();
    if (
      !this.intent.installOperationId &&
      this.intent.workspaceId &&
      this.intent.operation?.kind === "configure" &&
      this.options.installAuthorization?.inspectUnexchangedRequest
    ) {
      try {
        const original =
          await this.options.installAuthorization.inspectUnexchangedRequest({
            workspaceId: this.intent.workspaceId,
            requestId: this.intent.operation.requestId,
          });
        this.intent.installOperationId = original.operationId;
        this.intent.registrationId = original.registrationId;
        this.intent.operation.operationId = original.operationId;
        await this.persistIntent();
      } catch {
        this.requireCurrentAuthority();
      }
    }
    const recovery = this.intent.recoveryPending;
    if (recovery && this.options.installAuthorization?.inspectRecoveredBinding) {
      try {
        const binding = await this.options.installAuthorization.inspectRecoveredBinding(
          { operationId: recovery.operationId, workspaceId: recovery.workspaceId }
        );
        if (
          binding.registration_id === recovery.registrationId &&
          binding.environment_id === recovery.environmentId &&
          binding.scope_key === recovery.workspaceId
        )
          await this.applyRecoveredBinding(binding);
      } catch {
        this.requireCurrentAuthority();
      }
    }
    this.observationFresh = true;
    let observed = await this.options.adapter.observe(this.intent.registrationId);
    observed = await this.observeProductStatus(observed);
    const restarted = await this.restartExpiredInstallation();
    if (restarted) return restarted;
    if (settleOperation && this.confirmedOperation(observed)) {
      this.finishOperation("succeeded");
      await this.persistIntent();
    }
    if (observed.readability !== "readable") this.observationFresh = false;
    if (this.observationFresh) this.observedAt = new Date().toISOString();
    let status: ComputeNodeState["status"];
    if (
      this.installationBlocked ||
      observed.readability === "unreadable" ||
      this.installationFailure(observed)
    )
      status = "action_required";
    else if (
      this.intent.operation?.outcome === "failed" ||
      this.intent.operation?.outcome === "unknown"
    )
      status = "action_required";
    else if (
      this.intent.operation?.kind === "remove" &&
      this.intent.operation.outcome === "succeeded"
    )
      status = "removed";
    else if (!this.intent.desiredEnabled)
      status =
        observed.host === "absent" && observed.connector === "absent"
          ? "not_set"
          : "stopped";
    else if (
      observed.host === "ready" &&
      observed.connector === "ready" &&
      observed.salix === "ready"
    )
      status = "ready";
    else if (observed.salix === "enrolling") status = "processing";
    else status = "action_required";
    return this.publish(
      status,
      observed,
      this.handoffExpiredHere() ? "setup_handoff_expired" : undefined
    );
  }

  private publish(
    status: ComputeNodeState["status"],
    observed = this.snapshot.observed,
    problem?: ComputeNodeProblem,
    problemDetail?: string
  ) {
    this.requireCurrentAuthority();
    const failure = this.installationFailure(observed);
    if (failure) {
      problem = !failure.retryable
        ? failure.code === "retry_limit_reached"
          ? "connection_retry_limit"
          : "setup_blocked"
        : failure.stage === "register"
          ? "connection_failed"
          : "components_failed";
      // Log each helper failure receipt once; observation republishes it on every read.
      const key = `${failure.operationId}/${failure.stage}/${failure.code}`;
      if (key !== this.loggedInstallationFailure) {
        this.loggedInstallationFailure = key;
        this.logSetupFailure(
          problem,
          failure.stage,
          `helper failure code ${failure.code}${failure.retryable ? " (retryable)" : ""}`
        );
      }
    }
    // registrationId remains Main-owned for runtime targeting and must not
    // leak into the renderer's strict native state schema.
    const stateObserved: ComputeNodeState["observed"] = {
      connector: observed.connector,
      host: observed.host,
      readability: observed.readability,
      salix: observed.salix,
    };
    this.snapshot = computeNodeStateSchema.parse({
      confirmationId: this.options.authorityGeneration?.(),
      bindingWorkspaceId: this.intent.workspaceId,
      bindingInstallationId: this.intent.installOperationId,
      bindingRevision: this.intent.revision,
      observedAt: this.observedAt,
      observationFresh: this.observationFresh,
      remoteRevocationConfirmed: this.intent.remoteRevocationConfirmed,
      canAbandonRequest: !!(
        !this.installationBlocked &&
        this.intent.installOperationId &&
        !this.intent.installAppliedOperationId &&
        !this.intent.recoveryPending &&
        this.options.installAuthorization?.abandon
      ),
      ...this.recoveryFor(status, observed),
      setup: {
        components:
          observed.host === "ready"
            ? "ready"
            : this.snapshot.preparation?.phase === "failed"
              ? "failed"
              : this.snapshot.preparation && this.snapshot.preparation.phase !== "idle"
                ? "preparing"
                : observed.host === "absent"
                  ? "not_started"
                  : "unknown",
        connection: failure
          ? "failed"
          : !this.observationFresh
            ? "unknown"
            : observed.salix === "ready"
              ? "ready"
              : observed.salix === "enrolling"
                ? "connecting"
                : observed.salix === "unregistered"
                  ? this.intent.operation?.kind === "configure" &&
                    ["failed", "unknown"].includes(this.intent.operation.outcome) &&
                    observed.host === "ready"
                    ? "failed"
                    : "not_started"
                  : observed.salix === "degraded" || observed.salix === "revoked"
                    ? "failed"
                    : "unknown",
        shell: this.shellPhase,
      },
      desiredEnabled: this.intent.desiredEnabled,
      eligibility: this.snapshot.eligibility,
      preparation: this.snapshot.preparation,
      observed: stateObserved,
      facets: facetsFor(status, observed, this.workActivity),
      ...(this.intent.operation ? { operation: this.intent.operation } : {}),
      ...(problem ? { problem } : {}),
      ...(problemDetail ? { problemDetail: problemDetail.slice(-4096) } : {}),
      revision: Math.max(this.snapshot.revision + 1, this.intent.revision),
      status,
    });
    this.options.onStateChanged?.(this.state());
    return this.state();
  }

  private recoveryFor(
    status: ComputeNodeState["status"],
    observed: ComputeNodeRuntimeObservation
  ): Pick<ComputeNodeState, "issue" | "recoveryActions"> {
    if (!this.snapshot.eligibility.eligible)
      return { issue: "unsupported", recoveryActions: [] };
    if (
      this.intent.operation?.kind === "remove" &&
      this.intent.operation.outcome !== "succeeded" &&
      this.intent.workspaceId
    )
      return {
        issue: "removal_incomplete",
        recoveryActions: ["finish_remove", "check_status"],
      };
    if (this.intent.recoveryPending)
      return { issue: "operation_unknown", recoveryActions: ["check_status"] };
    if (this.installationBlocked && this.intent.installOperationId)
      return {
        issue: "removal_incomplete",
        recoveryActions: ["finish_remove", "check_status"],
      };
    if (observed.reason === "capability_missing")
      return { issue: "capability_missing", recoveryActions: ["check_status"] };
    if (this.productUnavailable)
      return { issue: "authorization_unavailable", recoveryActions: ["check_status"] };
    if (this.handoffExpiredHere())
      // Main restarts once per enable. After that, the user's Continue starts a new installation.
      return {
        issue: "enable_incomplete",
        recoveryActions: ["continue_enable", "check_status"],
      };
    if (this.intent.receiptMissing)
      return {
        issue: "enable_incomplete",
        recoveryActions: ["continue_enable", "check_status"],
      };
    if (this.shellPhase === "preparing" || this.shellPhase === "failed")
      return {
        issue: "shell_initialization_pending",
        recoveryActions:
          this.shellPhase === "failed"
            ? ["continue_shell", "check_status"]
            : ["check_status"],
      };
    if (this.intent.initializationPending)
      return {
        issue: "shell_initialization_pending",
        recoveryActions: ["continue_shell", "check_status"],
      };
    const failure = this.installationFailure(observed);
    if (failure)
      return {
        issue: failure.stage === "register" ? "connection" : "enable_incomplete",
        recoveryActions: failure.retryable
          ? ["continue_enable", "check_status"]
          : ["check_status"],
      };
    const canContinue =
      this.intent.desiredEnabled &&
      this.intent.operation?.kind === "configure" &&
      !!this.intent.workspaceId;
    const recoveryActions: NonNullable<ComputeNodeState["recoveryActions"]> =
      canContinue ? ["continue_enable", "check_status"] : ["check_status"];
    if (this.intent.operation?.outcome === "unknown") {
      const canResume =
        canContinue &&
        (!this.intent.installOperationId ||
          this.installationPhase === "requested" ||
          this.installationPhase === "exchange_committed" ||
          this.installationPhase === "handed_off");
      return {
        issue: "operation_unknown",
        recoveryActions: canResume
          ? ["continue_enable", "check_status"]
          : ["check_status"],
      };
    }
    if (status !== "action_required") return { recoveryActions: ["check_status"] };
    if (this.snapshot.preparation?.phase === "failed")
      return { issue: "preparation_failed", recoveryActions };
    if (!this.observationFresh || observed.connector !== "ready")
      return { issue: "connection", recoveryActions };
    if (observed.salix === "degraded" || observed.salix === "revoked")
      return { issue: "authorization", recoveryActions: ["check_status"] };
    return {
      issue: canContinue ? "enable_incomplete" : "needs_attention",
      recoveryActions,
    };
  }

  private installationFailure(observed: ComputeNodeRuntimeObservation) {
    const failure = observed.installationFailure;
    return observed.readability === "readable" &&
      this.intent.desiredEnabled &&
      this.intent.operation?.kind !== "remove" &&
      failure?.operationId === this.intent.installOperationId
      ? failure
      : undefined;
  }

  private async persistIntent() {
    this.requireCurrentAuthority();
    this.intent.revision = Math.max(
      this.intent.revision + 1,
      this.snapshot.revision + 1
    );
    await this.writeIntent(true);
  }

  private async writeIntent(requireCurrent: boolean) {
    this.requireIntentReadable();
    await mkdir(dirname(this.options.filePath), { recursive: true });
    const temporary = `${this.options.filePath}.tmp`;
    await writeFile(temporary, JSON.stringify(this.intent), { mode: 0o600 });
    if (requireCurrent) this.requireCurrentAuthority();
    await rename(temporary, this.options.filePath);
  }

  private beginOperation(kind: ComputeNodeOperation["kind"]) {
    this.intent.operation = {
      // The local lifecycle has no provider transport epoch. Use the persisted
      // local revision as its positive, monotonic correlation fence instead of
      // emitting the invalid sentinel rejected by SalixStore.ComputeContract.
      connectionEpoch: String(
        Math.max(1, this.snapshot.revision, this.intent.revision)
      ),
      kind,
      leaseGeneration: 0,
      operationId: `cmpop_${randomUUID()}`,
      outcome: "pending",
      requestId: `req_${randomUUID()}`,
      targetRef: "compute-node/local",
      targetRevision: Math.max(this.snapshot.revision, this.intent.revision),
    };
  }

  private finishOperation(outcome: ComputeNodeOperation["outcome"]) {
    if (this.intent.operation) this.intent.operation.outcome = outcome;
  }

  private confirmedOperation(observed: ComputeNodeRuntimeObservation) {
    const operation = this.intent.operation;
    if (
      !operation ||
      (operation.outcome !== "pending" && operation.outcome !== "unknown")
    ) {
      return false;
    }
    if (observed.readability !== "readable") return false;
    if (operation.kind === "drain") {
      return (
        observed.registrationState === "draining" ||
        observed.registrationState === "revoked" ||
        observed.registration === "absent"
      );
    }
    if (operation.kind === "remove") return this.removalConfirmed(observed);
    // Install/configure success requires the helper's exact operation result;
    // generic ready facts do not prove the requested release/digest.
    return false;
  }

  private removalConfirmed(observed: ComputeNodeRuntimeObservation) {
    // Product removal revokes the exact registration. The shared Host may
    // remain installed for registrations owned by other products/scopes.
    return (
      this.intent.remoteRevocationConfirmed === true &&
      this.localRemovalConfirmed(observed)
    );
  }

  private localRemovalConfirmed(observed: ComputeNodeRuntimeObservation) {
    return (
      observed.readability === "readable" &&
      (observed.registration === "absent" || observed.registrationState === "revoked")
    );
  }

  private async observeAfterFailure() {
    try {
      return await this.options.adapter.observe(this.intent.registrationId);
    } catch {
      return {
        ...this.snapshot.observed,
        readability: "unreadable" as const,
        registration: "unreadable" as const,
      };
    }
  }

  private shellPhase: NonNullable<ComputeNodeState["setup"]>["shell"] = "unknown";

  private async observeProductStatus(observed: ComputeNodeRuntimeObservation) {
    this.workActivity = "unknown";
    this.productUnavailable = false;
    this.installationPhase = undefined;
    this.installationErrorCode = undefined;
    const owner = this.options.installAuthorization;
    const workspaceId = this.intent.workspaceId;
    const operationId = this.intent.installOperationId;
    if (this.intent.remoteRevocationConfirmed)
      return { ...observed, salix: "revoked" as const };
    if (!owner || !workspaceId || !operationId) return observed;
    try {
      const { status, workActivity, authorizationStatus, shellPhase, errorCode } =
        await owner.inspect({
          operationId,
          workspaceId,
        });
      this.installationErrorCode = errorCode;
      this.workActivity = workActivity;
      this.shellPhase = shellPhase ?? "unknown";
      this.installationPhase = authorizationStatus;
      return {
        ...observed,
        salix:
          status === "ready"
            ? ("ready" as const)
            : status === "removed"
              ? ("revoked" as const)
              : status === "action_required"
                ? ("degraded" as const)
                : ("enrolling" as const),
      };
    } catch (error) {
      this.productUnavailable = error instanceof ComputeNodeAuthorizationNotFoundError;
      this.observationFresh = false;
      return { ...observed, salix: "degraded" as const };
    }
  }

  private requireBinding(expected?: ComputeNodeExpectedBinding) {
    if (
      this.options.authorityGeneration &&
      expected?.confirmationId !== this.options.authorityGeneration()
    ) {
      throw new ComputeNodeBindingChangedError(
        "The compute node confirmation expired. Review the current node."
      );
    }
    if (
      expected &&
      (expected.workspaceId !== this.intent.workspaceId ||
        expected.installationId !== (this.intent.installOperationId ?? null))
    )
      throw new ComputeNodeBindingChangedError(
        "Compute node binding changed. Review the current node before confirming again."
      );
    if (expected && expected.bindingRevision !== this.intent.revision) {
      throw new ComputeNodeBindingChangedError(
        "The compute node confirmation expired. Review the current node."
      );
    }
  }

  private requireEligible() {
    if (!this.snapshot.eligibility.eligible) {
      throw new Error(
        this.snapshot.eligibility.reason ?? "Compute node is unsupported."
      );
    }
  }

  private requireCurrentAuthority() {
    if (!this.options.authorityGeneration) return;
    const current = this.options.authorityGeneration();
    const frozen = this.operationAuthority.getStore();
    if (!current || (frozen && frozen.generation !== current))
      throw new ComputeNodeSessionChangedError();
  }

  private requireIntentReadable() {
    if (!this.intentReadable)
      throw new Error(
        "Saved compute node intent is unreadable. Repair its storage before changing it."
      );
  }

  // Only accepted facts may be saved after a Session change, to this service's original account file.
  // The serialized owner prevents another operation from changing its target during this write.
  private async saveAcceptedResult(
    category: string | undefined,
    property: PropertyKey,
    args: unknown[],
    output: unknown
  ) {
    if (!this.intentReadable) return;
    let changed = false;
    if (
      category === "authorization" &&
      (property === "authorize" || property === "retry")
    ) {
      const result = output as { operationId: string; registrationId: string };
      this.intent.installOperationId = result.operationId;
      this.intent.registrationId = result.registrationId;
      changed = true;
    } else if (category === "authorization" && property === "abandon") {
      await this.completeAbandon();
      return;
    } else if (category === "authorization" && property === "revoke") {
      this.intent.remoteRevocationConfirmed = true;
      changed = true;
    } else if (
      category === "runtime" &&
      (property === "install" || property === "resume")
    ) {
      this.intent.installAppliedOperationId = args[0] as string;
      changed = true;
    }
    if (changed) {
      if (this.intent.operation) this.intent.operation.outcome = "unknown";
      this.intent.revision += 1;
      await this.writeIntent(false);
    }
  }

  private fenceEffects<T extends object>(owner: T, category?: string): T {
    return new Proxy(owner, {
      get: (target, property) => {
        const value = Reflect.get(target, property);
        if (typeof value !== "function") return value;
        return (...args: unknown[]) => {
          this.requireCurrentAuthority();
          const result: unknown = Reflect.apply(value, target, args);
          if (!(result instanceof Promise)) return result;
          return result.then(async (output) => {
            try {
              this.requireCurrentAuthority();
            } catch (error) {
              if (error instanceof ComputeNodeSessionChangedError)
                await this.saveAcceptedResult(category, property, args, output);
              throw error;
            }
            return output;
          });
        };
      },
    });
  }

  private run(operation: () => Promise<ComputeNodeState>) {
    const generation = this.options.authorityGeneration?.();
    const execute = () =>
      this.operationAuthority.run({ generation }, async () => {
        this.requireCurrentAuthority();
        try {
          return await operation();
        } catch (error) {
          this.requireCurrentAuthority();
          if (
            error instanceof ComputeNodeBindingChangedError ||
            error instanceof ComputeNodeSessionChangedError
          )
            throw error;
          this.publish(
            "action_required",
            undefined,
            error instanceof ComputeNodeCommandError && isUnknownFailure(error)
              ? "operation_unknown"
              : "operation_failed",
            error instanceof ComputeNodeCommandError ? undefined : errorDetail(error)
          );
          throw error;
        }
      });
    const result = this.tail.then(execute, execute);
    this.tail = result.catch(() => undefined);
    return result;
  }
}

function facetsFor(
  status: ComputeNodeState["status"],
  observed: ComputeNodeRuntimeObservation,
  workActivity: ComputeNodeWorkActivity = "unknown"
): ComputeNodeState["facets"] {
  const connection =
    observed.connector === "ready"
      ? "connected"
      : observed.connector === "degraded"
        ? "degraded"
        : observed.connector === "stopped"
          ? "connecting"
          : "disconnected";
  const runtimeReadiness =
    observed.host === "ready" &&
    observed.connector === "ready" &&
    observed.salix === "ready"
      ? "ready"
      : observed.host === "degraded" || observed.salix === "degraded"
        ? "degraded"
        : observed.host === "stopped" || observed.salix === "enrolling"
          ? "starting"
          : "unavailable";
  const installationHealth =
    observed.readability === "unreadable"
      ? "degraded"
      : observed.host === "absent" && observed.connector === "absent"
        ? "absent"
        : status === "processing"
          ? "installing"
          : observed.host === "ready" && observed.connector === "ready"
            ? "healthy"
            : "degraded";

  return {
    admission: status === "ready" ? "accepting" : "closed",
    connection,
    installationHealth,
    runtimeReadiness,
    // Workload activity is supplied by the independent Workload projection;
    // Node readiness never manufactures an activity result.
    workActivity,
  };
}

/** Only this server code means a revoked install that a new installation can replace. */
function handoffExpired(projection: {
  authorizationStatus?: string | undefined;
  errorCode?: string | undefined;
}) {
  return (
    projection.authorizationStatus === "action_required" &&
    projection.errorCode === "material_handoff_expired"
  );
}

/** A log-safe diagnostic: secret-looking values redacted, at most 512 characters. */
function redactDiagnostic(text: string) {
  const redacted = redactNativeObservation(text) as string;
  return redacted
    .replace(
      /("?[\w-]*(?:secret|token|password|credential|descriptor|material|authorization)[\w-]*"?\s*[:=]\s*)("[^"]*"|[^\s,;}]+)/gi,
      "$1[redacted]"
    )
    .replace(/[A-Za-z0-9+/_-]{32,}={0,2}/g, "[redacted]")
    .slice(0, 512);
}

/** The raw error text, kept for diagnostics beside a problem code. */
function errorDetail(error: unknown) {
  return error instanceof Error ? error.message : undefined;
}

function isUnknownFailure(error: unknown) {
  return error instanceof ComputeNodeCommandError && error.reason === "outcome_unknown";
}
