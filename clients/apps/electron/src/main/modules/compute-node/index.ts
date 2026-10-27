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
import {
  HostPreflightError,
  type HostPreparation,
  type HostPreparationState,
} from "./host-preparation";
import { HostMaintenanceIncompatibleError } from "./host-maintenance-protocol";
import {
  HostRecoveryInterruptsWorkError,
  HostTargetOlderThanDataError,
  MaintenanceRecordUnreadableError,
} from "./host-maintenance";
import { realMainClock, type MainClock } from "../../clock";
import { createHash, randomUUID } from "node:crypto";
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
  ComputeNodeCloudRefusalError,
  type ComputeNodeInstallAuthorizationOwner,
} from "./install-authorization";
export {
  ComputeNodeInstallAuthorization,
  type ComputeNodeInstallAuthorizationOwner,
} from "./install-authorization";

const savedId = z.string().min(1).max(200);
/** The newest intent version this Comma writes. A newer record is read and never rewritten. */
const INTENT_VERSION = 4;
/**
 * Main's saved compute intent. Unknown fields (from a newer Comma) are ignored, and fields an older Comma wrote
 * but this one no longer uses are dropped. Only a known field with a wrong value makes the record unreadable.
 */
const persistedIntentSchema = z.object({
  desiredEnabled: z.boolean(),
  installOperationId: savedId.optional(),
  installAppliedOperationId: savedId.optional(),
  registrationId: savedId.optional(),
  workspaceId: savedId.optional(),
  operation: z.object(computeNodeOperationSchema.shape).optional(),
  remoteRevocationConfirmed: z.boolean().optional(),
  receiptMissing: z.boolean().optional(),
  /**
   * One user-initiated enable already started one automatic new installation, after an expired material handoff or
   * an expired authorization. Explicit enable clears it.
   */
  automaticReinstallUsed: z.boolean().optional(),
  /**
   * The installation that Main replaced because its local registration was lost (a Host reset or local data loss).
   * That first replacement uses neither `automaticReinstallUsed` nor an ended continuation. A later loss of another
   * installation uses the per-enable budget, until Main's own next Host reset clears this field.
   */
  registrationLossReplaced: savedId.optional(),
  /**
   * The installation whose local registration Main's own Host data reset deleted. A revoked or terminal server
   * record of it is the reset's consequence, not a manager decision: Main replaces it whatever revocation reason
   * the server records. It names one installation, so it ends when Main retires or removes that installation.
   */
  hostResetInstallation: savedId.optional(),
  /** The earlier name of `automaticReinstallUsed`; read once and migrated. */
  handoffRestartUsed: z.boolean().optional(),
  /** Main's automatic continuation of the current entry into processing (see {@link CONTINUATION_ATTEMPTS}). */
  continuation: z
    .object({
      attempts: z.number().int().min(0).max(1_000),
      deadlineAt: z.number().int().min(0),
    })
    .optional(),
  /** Automatic continuation reached its budget. Only the user's retry or a ready node clears it. */
  continuationExhausted: z.boolean().optional(),
  recoveryPending: z
    .object({
      operationId: savedId,
      workspaceId: savedId,
      registrationId: savedId,
      environmentId: savedId,
    })
    .optional(),
  revision: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
  version: z.number().int().min(1),
  accountOwner: z
    .object({ audience: z.string().min(1).max(2048), subject: savedId })
    .optional(),
});
type PersistedIntent = Omit<
  z.infer<typeof persistedIntentSchema>,
  "handoffRestartUsed"
>;

/**
 * Main continues a processing operation by itself (RFC42 §3.2): after startup, a Session change, network recovery,
 * a changed node, and on one backoff timer per account intent. Backoff doubles from 1 s to the connector's 30 s cap.
 *
 * Budget: {@link CONTINUATION_ATTEMPTS} automatic effect attempts per entry into processing. Their backoff covers
 * 1 + 2 + 4 + 8 + 16 + 7 × 30 = 241 s, about four minutes, which a Wi-Fi reconnect, a Mac wake or a server
 * rolling update fits in, while a lasting failure reaches the user in minutes. Waiting for the server (enrollment,
 * the initial Shell) does not use attempts; {@link CONTINUATION_DEADLINE_MS} bounds the whole entry.
 * Server-side counters stay terminal: a `retry_limit_reached` receipt stops continuation.
 *
 * Cardinality: one timer per account intent, and one node per Mac per account. Each tick reads the product
 * operation once and the local Host status once: at most 2 product reads per minute at the cap, 6 in the first
 * minute, and none once the node is ready with its Shell, or after the deadline.
 */
const CONTINUATION_ATTEMPTS = 12;
/**
 * One overall deadline per entry into processing, which the UI shows as `deadlineAt`. It covers waiting for another
 * preparer, the Host download (2 GiB) and publish (10 min), the install (3 min) and the server's 15 min handoff.
 */
const CONTINUATION_DEADLINE_MS = 45 * 60_000;
const continuationDelay = (step: number) =>
  Math.min(30_000, 1_000 * 2 ** Math.max(0, step));

/** A needs-attention result that continuation cannot resolve. The user's explicit action clears it. */
type Attention = {
  problem: ComputeNodeProblem;
  issue: NonNullable<ComputeNodeState["issue"]>;
  actions: NonNullable<ComputeNodeState["recoveryActions"]>;
  diskRequirement?: ComputeNodeState["diskRequirement"];
};
/** `replace_lost`: replace an installation whose local registration was lost (see `registrationLossReplaced`). */
type ContinuationNeed = "none" | "wait" | "effect" | "replace" | "replace_lost";

export interface ComputeNodeServiceOptions {
  adapter: ComputeNodeRuntimeAdapter;
  preparation?: HostPreparation;
  installationBlocked?: (operationId: string) => Promise<boolean>;
  /** Rejects while local Host maintenance forbids a new installation. */
  assertInstallationAllowed?: () => Promise<void>;
  /** Main's diagnostic log. It receives bounded, redacted lines only. */
  log?: (line: string) => void;
  /** Main's clock for continuation timers and deadlines. */
  clock?: MainClock;
  /** Starts update/preserve of an installed Host that lacks the maintenance protocol. */
  updateHost?: () => Promise<unknown>;
  /**
   * Resumes Main's own pending Host maintenance request, or recovers a stuck one. Resolves whether one was pending.
   * `workActive` reports running work; a recovery then rejects with `HostRecoveryInterruptsWorkError`.
   */
  resumeMaintenance?: (workActive: () => boolean) => Promise<boolean>;
  filePath: string;
  onStateChanged?: ((state: ComputeNodeState) => void) | undefined;
  installAuthorization?: ComputeNodeInstallAuthorizationOwner | undefined;
  platform?: NodeJS.Platform | undefined;
  arch?: string | undefined;
  authorityGeneration?: () => string | undefined;
  accountOwner?: { audience: string; subject: string };
}

export class ComputeNodeService {
  private intent: PersistedIntent = { desiredEnabled: false, revision: 1, version: 3 };
  private snapshot: ComputeNodeState;
  private intentReadable = true;
  /** A newer Comma wrote the intent. This version reads it and never rewrites it. */
  private intentReadOnly = false;
  private attention: Attention | undefined;
  /** The last failed attempt's problem, shown while Main continues and after its budget ends. */
  private lastProblem: ComputeNodeProblem | undefined;
  private revocationReason: "authorization_expired" | "revoked" | undefined;
  /** The server refused to enable this installation because its registration is gone or terminal. */
  private staleOperationId: string | undefined;
  private productReadFailed = false;
  private cancelContinuation: (() => void) | undefined;
  private waitPolls = 0;
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

  private readonly clock: MainClock;

  private constructor(private readonly options: ComputeNodeServiceOptions) {
    this.clock = options.clock ?? realMainClock;
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
    return this.run(async () => {
      try {
        const state = await this.configureInternal(input, true);
        return input.desiredEnabled ? await this.settle(state) : state;
      } catch (error) {
        if (!input.desiredEnabled || isFenceError(error)) throw error;
        // A retryable failure stays processing: continuation resumes the same plan.
        // Only a result the user must handle rejects the user's action.
        this.recordAttention(error);
        const state = await this.reconcile();
        if (state.status === "processing") return state;
        throw error;
      }
    });
  }

  /** Archives Main's unreadable intent and starts it clean. It changes no Host or cloud state. */
  resetLocalRecord() {
    return this.run(async () => {
      if (!this.intentReadable) {
        try {
          await rename(
            this.options.filePath,
            `${this.options.filePath}.unreadable-${this.clock.now()}`
          );
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        }
        this.intent = {
          desiredEnabled: false,
          revision: this.intent.revision + 1,
          version: this.options.accountOwner ? INTENT_VERSION : 3,
          ...(this.options.accountOwner
            ? { accountOwner: this.options.accountOwner }
            : {}),
        };
        this.intentReadable = true;
        this.intentReadOnly = false;
      }
      return this.reconcile();
    });
  }

  /** Network recovery: the next continuation step runs now instead of after its backoff. */
  networkRecovered() {
    if (this.cancelContinuation) this.schedule(0);
  }

  /**
   * Main's own Host data reset succeeded. It deleted the local registration, so the next loss that Main observes is
   * the reset's consequence: the replacement is free again, and it starts now instead of at the next detection.
   */
  hostDataReset() {
    // Cleared before the serialized step, so a continuation step that ran the reset sees it too.
    const replaced = this.intent.registrationLossReplaced;
    delete this.intent.registrationLossReplaced;
    const installation = this.intent.installOperationId;
    const marked = !!installation && this.intent.hostResetInstallation !== installation;
    if (installation) this.intent.hostResetInstallation = installation;
    return this.run(async () => {
      if (
        (replaced !== undefined || marked) &&
        this.intentReadable &&
        !this.intentReadOnly
      )
        await this.persistIntent();
      return this.reconcile();
    });
  }

  /**
   * `replace`: a stale installation (lost local registration, or one the server refused as gone) may be retired and
   * replaced in this call. An explicit enable may; continuation only for its `replace` and `replace_lost` steps.
   */
  private async configureInternal(
    input: ComputeNodeConfigureInput,
    explicit: boolean,
    replace = explicit
  ) {
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

      const blocked = await this.readInstallationFence();
      const local = this.intent.installOperationId
        ? await this.options.adapter.observe(this.intent.registrationId)
        : undefined;
      // A replacement never replays the fenced installation, so a fence does not stop a lost registration's replacement.
      if (blocked && !(replace && local && this.registrationLost(local)))
        return this.publish("action_required", await this.observeAfterFailure());
      if (local && this.installationFailure(local)?.retryable === false)
        return this.publish("action_required", local);

      // Persist the user's target before crossing the helper side-effect
      // boundary. A process exit after install but before the final
      // observation must recover toward enabled, not toward the old value.
      const wasEnabled = this.intent.desiredEnabled;
      delete this.intent.remoteRevocationConfirmed;
      if (explicit) {
        // Each user-initiated enable allows one automatic new installation and a new continuation budget.
        delete this.intent.automaticReinstallUsed;
        delete this.intent.continuationExhausted;
        this.attention = undefined;
        this.lastProblem = undefined;
        this.intent.continuation = {
          attempts: 0,
          deadlineAt: this.clock.now() + CONTINUATION_DEADLINE_MS,
        };
      }
      this.intent.desiredEnabled = true;
      this.intent.workspaceId = input.workspaceId;
      const current = this.intent.operation;
      if (
        current?.kind === "configure" &&
        (!this.intent.installOperationId ||
          (!explicit && current.outcome !== "succeeded"))
      ) {
        // A lost authorization response must retry the same server idempotency
        // key. No registration exists until exchange, so replacing this key
        // would strand a pending operation instead of converging it. Continuation
        // also keeps the unfinished operation's local request id.
        current.outcome = "pending";
      } else {
        this.beginOperation("configure");
      }
      this.publish("processing");
      await this.persistIntent();
      let observed: ComputeNodeRuntimeObservation;
      let stage = "preparation";
      let projection:
        | Awaited<ReturnType<ComputeNodeInstallAuthorizationOwner["inspect"]>>
        | undefined;
      try {
        if (explicit) await this.options.assertInstallationAllowed?.();
        await this.options.preparation?.ensure(
          (preparation) => this.reportPreparation(preparation),
          this.intent.continuation
            ? { deadline: this.intent.continuation.deadlineAt }
            : {}
        );
        const operation = this.intent.operation;
        if (!operation) {
          throw new Error("Compute node authorization identity is unavailable.");
        }
        stage = "inspect";
        projection =
          this.intent.installOperationId && this.snapshot.status !== "removed"
            ? await this.options.installAuthorization.inspect({
                operationId: this.intent.installOperationId,
                workspaceId: input.workspaceId,
              })
            : undefined;
        const stale =
          !!projection &&
          !replaceable(projection) &&
          replace &&
          (this.staleHere(projection) ||
            (!!local && this.registrationLost(local, projection)) ||
            // The user's Enable again retires a connection that is no longer valid and starts a new one.
            (explicit && revokedWithoutReason(projection)));
        if (projection && (replaceable(projection) || stale)) {
          // The server revoked this installation for an expired handoff or authorization and cannot resume it, or
          // its registration is gone: a Host reset or local data loss removed it, or the server refused it as gone.
          // Retire it exactly, keep it as evidence, and request a new installation with this fresh request id.
          stage = "retire";
          await this.retireInstallation(projection, stale, explicit);
          projection = undefined;
        }
        if (projection && this.intent.installOperationId) {
          const operationId = this.intent.installOperationId;
          if (
            projection.authorizationStatus === "requested" ||
            ticketRetryExhausted(projection)
          ) {
            // The server's `retry` reopens the same operation: a fresh ticket under the same request.
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
            // The server creates the initial Shell; admission does not depend on it.
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
            if (projection.authorizationStatus === "revoked") {
              this.attention = managerRevoked(projection, this.resetHere())
                ? revokedAttention
                : invalidAttention;
              throw new Error("Compute node installation was removed.");
            }
            throw new Error("Compute node installation requires operator action.");
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
        if (isFenceError(error)) throw error;
        if (error instanceof ComputeNodeCloudRefusalError && error.terminal)
          this.recordRefusal(stage, error, projection);
        const problem =
          trustProblem(errorText(error)) ??
          (isUnknownFailure(error) ? "setup_unknown" : "setup_failed");
        this.logSetupFailure(problem, stage, error);
        this.lastProblem = problem;
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
      // The server creates the initial Shell when the installation first becomes ready; Main reads its phase.
      this.finishOperation("succeeded");
      this.lastProblem = undefined;
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
    delete this.intent.receiptMissing;
    delete this.intent.hostResetInstallation;
    this.installationPhase = undefined;
    this.installationErrorCode = undefined;
    this.revocationReason = undefined;
    this.staleOperationId = undefined;
  }

  /**
   * The remove flow for the exact old installation before a replacement: request revocation of an expired
   * authorization, then confirm that the local registration is absent or revoked (revoking it locally if needed).
   * Each step is idempotent: the local revocation uses one request id derived from the old installation.
   * `explicit`: the user's Enable again. Like an explicit removal, it detaches an old installation that this
   * account can no longer reach (a scoped 404) when its local registration is already gone; the server retires
   * its own record.
   */
  private async retireInstallation(
    projection: {
      authorizationStatus?: string;
      registrationRevocationReason?: string;
    },
    stale = false,
    explicit = false
  ) {
    const operationId = this.intent.installOperationId;
    const workspaceId = this.intent.workspaceId;
    if (!operationId || !workspaceId || !this.options.installAuthorization) return;
    let unreachable = false;
    if (stale || projection.registrationRevocationReason === "authorization_expired") {
      try {
        await this.options.installAuthorization.revoke({ operationId, workspaceId });
      } catch (error) {
        // A stale registration that the server no longer has, or already revoked, is retired.
        if (
          explicit &&
          !stale &&
          error instanceof ComputeNodeAuthorizationNotFoundError
        )
          unreachable = true;
        else if (!(stale && alreadyGone(error))) {
          // This account can no longer manage the old installation: no automatic replacement. Only an explicit
          // manager revocation names the manager; otherwise the connection is no longer valid.
          if (error instanceof ComputeNodeAuthorizationNotFoundError)
            this.attention = managerRevoked(projection, this.resetHere())
              ? revokedAttention
              : invalidAttention;
          throw error;
        }
      }
    }
    const registrationId = this.intent.registrationId;
    if (registrationId) {
      let local = await this.options.adapter.observe(registrationId);
      if (local.readability !== "readable" || local.registration === "unreadable")
        throw new Error(
          "The local registration could not be read. Check the Host connection."
        );
      // As in an explicit removal, a scoped 404 never authorizes removing a present local registration.
      if (unreachable && !this.localRemovalConfirmed(local))
        throw new Error(
          "This session cannot revoke the registration. Use local VMM management."
        );
      if (!this.localRemovalConfirmed(local)) {
        await this.options.adapter.remove(
          `req_${createHash("sha256").update(`retire:${operationId}`).digest("hex").slice(0, 32)}`,
          registrationId
        );
        local = await this.options.adapter.observe(registrationId);
        if (!this.localRemovalConfirmed(local))
          throw new Error("The old local registration is still present.");
      }
    }
    await this.archiveInstallation();
  }

  /**
   * The Host is healthy and reads no local registration for an installation that Main already applied, and the
   * server did not revoke it: a Host reset or local data loss removed it. Main replaces this stale installation.
   */
  private registrationLost(
    observed: ComputeNodeRuntimeObservation,
    projection: ProjectionCodes = {
      authorizationStatus: this.installationPhase,
      errorCode: this.installationErrorCode,
      registrationRevocationReason: this.revocationReason,
    }
  ) {
    const operationId = this.intent.installOperationId;
    return (
      !!operationId &&
      !!this.intent.registrationId &&
      this.intent.installAppliedOperationId === operationId &&
      this.intent.desiredEnabled &&
      !this.intent.remoteRevocationConfirmed &&
      !this.intent.recoveryPending &&
      this.intent.operation?.kind !== "remove" &&
      this.intent.operation?.kind !== "drain" &&
      observed.readability === "readable" &&
      observed.host === "ready" &&
      observed.registration === "absent" &&
      (projection.authorizationStatus === "handed_off" ||
        projection.authorizationStatus === "exchange_committed" ||
        replaceable(projection) ||
        // After Main's own reset, a revoked record of this installation is the reset's consequence.
        (projection.authorizationStatus === "revoked" && this.resetHere())) &&
      !managerRevoked(projection, this.resetHere())
    );
  }

  /** Main's own Host data reset deleted the local registration of the current installation. */
  private resetHere() {
    return (
      !!this.intent.installOperationId &&
      this.intent.hostResetInstallation === this.intent.installOperationId
    );
  }

  /** The server refused to enable the current installation because its registration is gone or terminal. */
  private staleHere(
    projection: ProjectionCodes = {
      registrationRevocationReason: this.revocationReason,
    }
  ) {
    return (
      !managerRevoked(projection, this.resetHere()) &&
      !!this.staleOperationId &&
      this.staleOperationId === this.intent.installOperationId &&
      this.intent.desiredEnabled &&
      this.intent.operation?.kind !== "remove" &&
      this.intent.operation?.kind !== "drain"
    );
  }

  /** A stale installation that Main replaces only once per enable, after which the user's Continue replaces it. */
  private replacementWaitsForUser(observed: ComputeNodeRuntimeObservation) {
    if (!this.intent.automaticReinstallUsed) return false;
    if (this.registrationLost(observed))
      return (
        this.intent.registrationLossReplaced !== undefined &&
        this.intent.registrationLossReplaced !== this.intent.installOperationId
      );
    return this.replaceableHere() || this.staleHere();
  }

  /**
   * A terminal server refusal ends continuation of this request. A registration that the server no longer has, or
   * holds as terminal, makes the installation stale: Main replaces it unless a workspace manager revoked it. Any
   * other refusal needs the user.
   */
  private recordRefusal(
    stage: string,
    error: ComputeNodeCloudRefusalError,
    projection: { registrationRevocationReason?: string } | undefined
  ) {
    if (
      stage === "enable" &&
      (error.reason === "registration_not_found" ||
        error.reason === "terminal_registration")
    ) {
      if (projection && managerRevoked(projection, this.resetHere()))
        this.attention = revokedAttention;
      else this.staleOperationId = this.intent.installOperationId;
      return;
    }
    this.attention = refusedAttention;
  }

  /** The current account's install was revoked for an expired handoff or authorization, with enable desired. */
  private replaceableHere() {
    return (
      this.intent.desiredEnabled &&
      !!this.intent.installOperationId &&
      !this.intent.remoteRevocationConfirmed &&
      this.intent.operation?.kind !== "remove" &&
      this.intent.operation?.kind !== "drain" &&
      replaceable({
        authorizationStatus: this.installationPhase,
        errorCode: this.installationErrorCode,
        registrationRevocationReason: this.revocationReason,
      })
    );
  }

  /**
   * A workspace manager revoked this registration, and Main did not reset the Host since. Main never replaces it.
   */
  private revokedHere() {
    return (
      this.revokedRecordHere() && managerRevoked(this.currentCodes(), this.resetHere())
    );
  }

  /**
   * The server revoked this registration without a reason that Main knows, and Main did not reset the Host since:
   * the connection is no longer valid. Main does not replace it by itself; the user's Enable again does.
   */
  private invalidHere() {
    return (
      this.revokedRecordHere() &&
      revokedWithoutReason(this.currentCodes()) &&
      !this.resetHere()
    );
  }

  private revokedRecordHere() {
    return (
      this.intent.desiredEnabled &&
      !!this.intent.installOperationId &&
      !this.intent.remoteRevocationConfirmed &&
      this.intent.operation?.kind !== "remove" &&
      this.installationPhase === "revoked"
    );
  }

  private currentCodes(): ProjectionCodes {
    return {
      authorizationStatus: this.installationPhase,
      errorCode: this.installationErrorCode,
      registrationRevocationReason: this.revocationReason,
    };
  }

  private logSetupFailure(problem: ComputeNodeProblem, stage: string, error: unknown) {
    const message =
      error instanceof Error ? error.message : typeof error === "string" ? error : "";
    this.options.log?.(
      `compute-node setup failed: problem=${problem} stage=${redactDiagnostic(stage).slice(0, 64)} message=${JSON.stringify(redactDiagnostic(message))}`
    );
  }

  /** Keeps the needs-attention results that continuation must not retry. */
  private recordAttention(error: unknown) {
    if (error instanceof HostPreflightError)
      this.attention = {
        problem: "insufficient_disk",
        issue: "insufficient_disk",
        actions: ["check_status"],
        diskRequirement: {
          requiredBytes: error.requiredBytes,
          availableBytes: error.availableBytes,
        },
      };
    else if (error instanceof MaintenanceRecordUnreadableError)
      this.attention = {
        problem: "intent_unreadable",
        issue: "local_record_unreadable",
        actions: ["reset_local_record"],
      };
    else if (error instanceof HostTargetOlderThanDataError)
      this.attention = {
        problem: "target_older_than_data",
        issue: "host_update_required",
        actions: ["reinstall_reset"],
      };
    else if (
      error instanceof HostRecoveryInterruptsWorkError ||
      (error instanceof HostMaintenanceIncompatibleError && !this.mayUpdateHost())
    )
      // Continuation updates an idle Host by itself; with running work, only the user may interrupt it.
      this.attention = {
        problem: "host_update_interrupts_work",
        issue: "host_update_required",
        actions: ["update_host"],
      };
  }

  /** The server reports no active work for this node, or no node exists yet. */
  private mayUpdateHost() {
    return (
      !!this.options.updateHost &&
      (!this.intent.installOperationId || this.workActivity === "idle")
    );
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
      // The user's explicit removal replaces any earlier result that waited for the user.
      this.attention = undefined;
      this.lastProblem = undefined;
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
      delete this.intent.receiptMissing;
      delete this.intent.hostResetInstallation;
      this.forgetInstallationResults();
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
    delete this.intent.receiptMissing;
    delete this.intent.hostResetInstallation;
    this.forgetInstallationResults();
    this.beginOperation("remove");
    this.finishOperation("succeeded");
    await this.writeIntent(false);
  }

  /** The node has no installation now: no earlier result of one waits for the user. */
  private forgetInstallationResults() {
    this.attention = undefined;
    this.lastProblem = undefined;
    this.staleOperationId = undefined;
  }

  private async initialize() {
    try {
      const { handoffRestartUsed, ...parsed } = persistedIntentSchema.parse(
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
      this.intentReadOnly = parsed.version > INTENT_VERSION;
      this.intent = {
        ...parsed,
        ...(handoffRestartUsed ? { automaticReinstallUsed: true } : {}),
        version: this.intentReadOnly
          ? parsed.version
          : this.options.accountOwner
            ? INTENT_VERSION
            : 3,
      };
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
      // The startup reconcile observes, then continues an enabled target by itself.
      this.publish(this.intent.desiredEnabled ? "processing" : "not_set");
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
        this.finishStop();
        await this.persistIntent();
        return this.reconcile();
      }
      this.finishOperation(isUnknownFailure(error) ? "unknown" : "failed");
      await this.persistIntent();
      this.publish("action_required", observed, "stop_failed", errorDetail(error));
      throw error;
    }
    this.finishStop();
    return this.reconcile();
  }

  /** The user stopped the node: an earlier result that waited for the user no longer applies. */
  private finishStop() {
    this.finishOperation("succeeded");
    this.attention = undefined;
    this.lastProblem = undefined;
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

  /** Reads the local and product facts of the current binding, without lifecycle effects. */
  private async observeCurrent() {
    await this.readInstallationFence();
    if (
      !this.intent.installOperationId &&
      this.intent.workspaceId &&
      this.intent.operation?.kind === "configure" &&
      this.options.installAuthorization?.inspectUnexchangedRequest
    ) {
      // An unknown authorization result: read the original request before anything continues it.
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
    const observed = await this.options.adapter.observe(this.intent.registrationId);
    return this.observeProductStatus(observed);
  }

  private async reconcile(
    settleOperation = true,
    current?: ComputeNodeRuntimeObservation
  ) {
    let observed = current ?? (await this.observeCurrent());
    if (settleOperation && this.confirmedOperation(observed)) {
      this.finishOperation("succeeded");
      await this.persistIntent();
    }
    if (observed.readability !== "readable") this.observationFresh = false;
    if (this.observationFresh)
      this.observedAt = new Date(this.clock.now()).toISOString();
    await this.planContinuation(this.continuationNeed(observed), observed);
    observed = { ...observed };
    let status: ComputeNodeState["status"];
    if (
      this.installationBlocked ||
      observed.readability === "unreadable" ||
      this.installationFailure(observed) ||
      observed.hostStartFailure ||
      this.attention ||
      this.intent.continuationExhausted ||
      this.revokedHere() ||
      this.invalidHere()
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
      this.replaceableHere() &&
        handoffExpired({
          authorizationStatus: this.installationPhase,
          errorCode: this.installationErrorCode,
        })
        ? "setup_handoff_expired"
        : undefined
    );
  }

  /** What continuation does next for this observation. Fenced and terminal states need nothing. */
  private continuationNeed(observed: ComputeNodeRuntimeObservation): ContinuationNeed {
    const operation = this.intent.operation;
    if (
      !this.snapshot.eligibility.eligible ||
      !this.intentReadable ||
      this.intentReadOnly ||
      this.intent.recoveryPending ||
      !this.intent.desiredEnabled ||
      !this.intent.workspaceId ||
      !this.options.installAuthorization ||
      operation?.kind === "remove" ||
      operation?.kind === "drain" ||
      this.attention ||
      observed.hostStartFailure ||
      this.productUnavailable
    )
      return "none";
    // A terminal helper receipt, such as `retry_limit_reached`, keeps the server's counter authoritative.
    if (this.installationFailure(observed)?.retryable === false) return "none";
    const lost = this.registrationLost(observed);
    const lossReplaced = this.intent.registrationLossReplaced;
    // The consequence of a Host reset or local data loss: the first replacement starts over, whatever ran before.
    if (lost && lossReplaced === undefined) return "replace_lost";
    if (this.intent.continuationExhausted) return "none";
    if (lost)
      // The same replacement continues. A loss of the next installation, without a Host reset, uses the budget.
      return lossReplaced === this.intent.installOperationId
        ? "replace_lost"
        : this.intent.automaticReinstallUsed
          ? "none"
          : "replace";
    if (this.installationBlocked) return "none";
    if (this.replaceableHere() || this.staleHere())
      return this.intent.automaticReinstallUsed ? "none" : "replace";
    if (this.revokedHere() || this.invalidHere()) return "none";
    if (observed.readability !== "readable" || this.productReadFailed) return "wait";
    if (
      observed.host === "ready" &&
      observed.connector === "ready" &&
      observed.salix === "ready"
    )
      // The server creates the initial Shell; Main waits while it reports it under way.
      return this.shellPhase === "not_initialized" || this.shellPhase === "preparing"
        ? "wait"
        : "none";
    if (!this.intent.installOperationId) return "effect";
    if (operation?.outcome !== "succeeded") return "effect";
    if (
      this.installationPhase === "requested" ||
      this.installationPhase === "exchange_committed" ||
      ticketRetryExhausted({
        authorizationStatus: this.installationPhase,
        errorCode: this.installationErrorCode,
      })
    )
      return "effect";
    if (this.installationPhase === "handed_off")
      // A running connector that the server still enrolls needs time, not another effect.
      return observed.salix === "enrolling" &&
        this.intent.installAppliedOperationId === this.intent.installOperationId &&
        observed.host === "ready" &&
        observed.connector === "ready"
        ? "wait"
        : "effect";
    return "none";
  }

  /** Keeps, arms or ends the continuation record for `need`, and schedules its next step. */
  private async planContinuation(
    need: ContinuationNeed,
    observed: ComputeNodeRuntimeObservation
  ) {
    const writable = this.intentReadable && !this.intentReadOnly;
    if (need === "none") {
      this.stopContinuation();
      const ready =
        observed.host === "ready" &&
        observed.connector === "ready" &&
        observed.salix === "ready";
      const persisted =
        !!this.intent.continuation?.attempts ||
        (ready && !!this.intent.continuationExhausted);
      delete this.intent.continuation;
      if (ready) delete this.intent.continuationExhausted;
      if (writable && persisted) await this.persistIntent();
      return;
    }
    const now = this.clock.now();
    if (need === "replace_lost" && this.intent.registrationLossReplaced === undefined) {
      // The new installation gets its own continuation record: the old installation's attempts and end do not count.
      delete this.intent.continuationExhausted;
      this.lastProblem = undefined;
      if (
        this.intent.continuation &&
        (this.intent.continuation.attempts > 0 ||
          now >= this.intent.continuation.deadlineAt)
      )
        delete this.intent.continuation;
    }
    // Arming does not write the intent: a read stays read-only. The first attempt persists the record.
    this.intent.continuation ??= {
      attempts: 0,
      deadlineAt: now + CONTINUATION_DEADLINE_MS,
    };
    const continuation = this.intent.continuation;
    if (
      now >= continuation.deadlineAt ||
      (need !== "wait" && continuation.attempts >= CONTINUATION_ATTEMPTS)
    ) {
      this.stopContinuation();
      delete this.intent.continuation;
      this.intent.continuationExhausted = true;
      this.options.log?.(
        `compute-node continuation stopped: attempts=${continuation.attempts} deadline=${now >= continuation.deadlineAt}`
      );
      await this.persistIntent();
      return;
    }
    if (need === "wait") {
      this.schedule(continuationDelay(this.waitPolls++));
    } else {
      this.waitPolls = 0;
      this.schedule(
        continuation.attempts === 0 ? 0 : continuationDelay(continuation.attempts - 1)
      );
    }
  }

  /** A result that left continuation armed without its next step is reconciled once more to plan that step. */
  private settle(state: ComputeNodeState) {
    return this.intent.continuation && !this.cancelContinuation
      ? this.reconcile()
      : state;
  }

  private stopContinuation() {
    this.cancelContinuation?.();
    this.cancelContinuation = undefined;
    this.waitPolls = 0;
  }

  /** Arms the one continuation timer of this intent. A step armed under another Session generation never runs. */
  private schedule(delayMs: number) {
    this.cancelContinuation?.();
    const generation = this.options.authorityGeneration?.();
    const cancel = this.clock.setTimer(delayMs, () => {
      if (this.cancelContinuation !== cancel) return;
      this.cancelContinuation = undefined;
      if (this.options.authorityGeneration?.() !== generation) return;
      void this.run(() => this.continueOnce()).catch(() => undefined);
    });
    this.cancelContinuation = cancel;
  }

  /** One continuation step: observe, run the effect the state needs within the budget, then plan the next step. */
  private async continueOnce() {
    const resumed = await this.options
      .resumeMaintenance?.(() => this.workActivity === "active")
      .catch((error: unknown) => {
        // Only the user may interrupt running work to recover the Host.
        if (error instanceof HostRecoveryInterruptsWorkError)
          this.recordAttention(error);
        return false;
      });
    if (resumed) this.requireCurrentAuthority();
    const observed = await this.observeCurrent();
    const need = this.continuationNeed(observed);
    const continuation = this.intent.continuation;
    if (
      (need !== "effect" && need !== "replace" && need !== "replace_lost") ||
      !continuation ||
      continuation.attempts >= CONTINUATION_ATTEMPTS ||
      this.clock.now() >= continuation.deadlineAt
    )
      return this.reconcile(true, observed);
    if (need === "replace_lost" && this.intent.registrationLossReplaced === undefined)
      // This replacement is free. A later loss of the new installation without a Host reset uses the budget.
      this.intent.registrationLossReplaced = this.intent.installOperationId;
    continuation.attempts += 1;
    await this.persistIntent();
    const workspaceId = this.intent.workspaceId!;
    try {
      await this.options.assertInstallationAllowed?.();
      if (need !== "effect") {
        // One automatic new installation per user enable, for an expired handoff or authorization, or a stale
        // registration. A new request id: the old one names the old installation on the server.
        if (need === "replace") this.intent.automaticReinstallUsed = true;
        this.beginOperation("configure");
        await this.persistIntent();
      }
      return await this.settle(
        await this.configureInternal(
          { desiredEnabled: true, workspaceId },
          false,
          need !== "effect"
        )
      );
    } catch (error) {
      if (isFenceError(error)) throw error;
      if (error instanceof HostMaintenanceIncompatibleError && this.mayUpdateHost()) {
        try {
          // The Host lacks the maintenance protocol and has no running work: update it, keep its data.
          await this.options.updateHost!();
        } catch (updateError) {
          this.requireCurrentAuthority();
          this.recordAttention(updateError);
          if (!this.attention)
            this.logSetupFailure("setup_failed", "host_update", updateError);
        }
      } else this.recordAttention(error);
      this.requireCurrentAuthority();
      return this.reconcile();
    }
  }

  private publish(
    status: ComputeNodeState["status"],
    observed: ComputeNodeRuntimeObservation = this.snapshot.observed,
    problem?: ComputeNodeProblem,
    problemDetail?: string
  ) {
    this.requireCurrentAuthority();
    // While Main continues the operation, a retryable failure is progress, not a request for the user.
    if (status === "action_required" && this.intent.continuation) status = "processing";
    // A result only the user can resolve names the cause, over the failed operation's generic code.
    if (this.attention) problem = this.attention.problem;
    if (!problem && observed.hostStartFailure) problem = "local_data_migration";
    if (!problem && this.revokedHere()) problem = "registration_revoked";
    if (!problem && this.invalidHere()) problem = "registration_invalid";
    // The last attempt's own cause stays visible while Main continues, and names why its budget ended.
    if (!problem && (status === "processing" || this.intent.continuationExhausted))
      problem = this.lastProblem;
    if (!problem && this.intent.continuationExhausted)
      problem = "automatic_retry_exhausted";
    const failure = this.installationFailure(observed);
    if (failure) {
      problem =
        trustProblem(failure.code) ??
        (!failure.retryable
          ? failure.code === "retry_limit_reached"
            ? "connection_retry_limit"
            : "setup_blocked"
          : failure.stage === "register"
            ? "connection_failed"
            : "components_failed");
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
      ...(status === "processing" && this.intent.continuation
        ? { deadlineAt: new Date(this.intent.continuation.deadlineAt).toISOString() }
        : {}),
      ...(this.attention?.diskRequirement
        ? { diskRequirement: this.attention.diskRequirement }
        : {}),
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
    if (!this.intentReadable)
      return {
        issue: "local_record_unreadable",
        recoveryActions: ["reset_local_record"],
      };
    if (observed.hostStartFailure)
      return { issue: "local_data_migration", recoveryActions: ["reinstall_reset"] };
    if (this.attention)
      return { issue: this.attention.issue, recoveryActions: this.attention.actions };
    if (this.revokedHere())
      return { issue: "revoked", recoveryActions: ["finish_remove", "check_status"] };
    if (this.invalidHere())
      // Enable again retires the old installation and starts a new one in one step.
      return {
        issue: "needs_attention",
        recoveryActions: ["continue_enable", "check_status"],
      };
    if (this.replacementWaitsForUser(observed))
      // Main replaces it once per enable. After that, the user's Continue starts a new installation.
      return {
        issue: "enable_incomplete",
        recoveryActions: ["continue_enable", "check_status"],
      };
    if (this.installationBlocked && this.intent.installOperationId)
      return {
        issue: "removal_incomplete",
        recoveryActions: ["finish_remove", "check_status"],
      };
    if (observed.reason === "capability_missing")
      return { issue: "capability_missing", recoveryActions: ["check_status"] };
    if (this.productUnavailable)
      return { issue: "authorization_unavailable", recoveryActions: ["check_status"] };
    if (this.intent.continuationExhausted)
      return {
        issue: "retry_budget_exhausted",
        recoveryActions: ["continue_enable", "check_status"],
      };
    if (this.intent.receiptMissing)
      return {
        issue: "enable_incomplete",
        recoveryActions: ["continue_enable", "check_status"],
      };
    if (this.shellPhase === "preparing" || this.shellPhase === "failed")
      // The server creates and retries the initial Shell; Main only reports its phase.
      return {
        issue: "shell_initialization_pending",
        recoveryActions: ["check_status"],
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
    this.revocationReason = undefined;
    this.productReadFailed = false;
    const owner = this.options.installAuthorization;
    const workspaceId = this.intent.workspaceId;
    const operationId = this.intent.installOperationId;
    if (this.intent.remoteRevocationConfirmed)
      return { ...observed, salix: "revoked" as const };
    if (!owner || !workspaceId || !operationId) return observed;
    try {
      const {
        status,
        workActivity,
        authorizationStatus,
        shellPhase,
        errorCode,
        registrationRevocationReason,
      } = await owner.inspect({
        operationId,
        workspaceId,
      });
      this.installationErrorCode = errorCode;
      this.revocationReason = registrationRevocationReason;
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
      this.productReadFailed = !this.productUnavailable;
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
        "Saved compute node intent is unreadable. Reset the local record before changing it."
      );
    if (this.intentReadOnly)
      throw new Error("A newer Comma version owns this compute node record.");
  }

  // Only accepted facts may be saved after a Session change, to this service's original account file.
  // The serialized owner prevents another operation from changing its target during this write.
  private async saveAcceptedResult(
    category: string | undefined,
    property: PropertyKey,
    args: unknown[],
    output: unknown
  ) {
    if (!this.intentReadable || this.intentReadOnly) return;
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
        // One Host capability probe per user action or continuation step.
        this.options.adapter.beginAction?.();
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

type ProjectionCodes = {
  authorizationStatus?: string | undefined;
  errorCode?: string | undefined;
  registrationRevocationReason?: string | undefined;
};

/** The server revoked this install because its material handoff expired. */
function handoffExpired(projection: ProjectionCodes) {
  return (
    projection.authorizationStatus === "action_required" &&
    projection.errorCode === "material_handoff_expired"
  );
}

/** Only an expired handoff or an expired authorization means a revoked install that a new installation replaces. */
function replaceable(projection: ProjectionCodes) {
  return (
    handoffExpired(projection) ||
    (projection.authorizationStatus === "revoked" &&
      projection.registrationRevocationReason === "authorization_expired")
  );
}

/** The server kept its four ticket generations; `retry` reopens the same operation with a fresh ticket. */
function ticketRetryExhausted(projection: ProjectionCodes) {
  return (
    projection.authorizationStatus === "action_required" &&
    projection.errorCode === "ticket_retry_exhausted"
  );
}

/** The server refused this request for good. The user's Continue starts the setup again. */
const refusedAttention: Attention = {
  problem: "setup_blocked",
  issue: "needs_attention",
  actions: ["continue_enable"],
};

/** The server no longer has this registration, or already revoked it. */
function alreadyGone(error: unknown) {
  return (
    error instanceof ComputeNodeAuthorizationNotFoundError ||
    (error instanceof ComputeNodeCloudRefusalError &&
      error.terminal &&
      (error.reason === "registration_not_found" ||
        error.reason === "terminal_registration" ||
        error.reason === "not_found"))
  );
}

const revokedAttention: Attention = {
  problem: "registration_revoked",
  issue: "revoked",
  actions: ["finish_remove", "check_status"],
};

/** The server revoked this registration without a known reason. Enable again replaces it. */
const invalidAttention: Attention = {
  problem: "registration_invalid",
  issue: "needs_attention",
  actions: ["continue_enable", "check_status"],
};

/**
 * The server records an explicit revocation (a workspace manager's), and Main did not reset the Host since. After
 * Main's own reset, the revocation is the reset's consequence, whatever reason the server records.
 */
function managerRevoked(projection: ProjectionCodes, reset: boolean) {
  return projection.registrationRevocationReason === "revoked" && !reset;
}

/** The server revoked this registration and gives no reason that Main knows. */
function revokedWithoutReason(projection: ProjectionCodes) {
  return (
    projection.authorizationStatus === "revoked" &&
    projection.registrationRevocationReason === undefined
  );
}

/**
 * The Host's bounded trust failure reasons (`stage=… reason=…`), mapped to the cause the user can act on.
 * Another reason keeps the generic setup problem.
 */
function trustProblem(text: string): ComputeNodeProblem | undefined {
  if (
    /\bstage=(?:anchor_time|membership_time)\b.*?\breason=(?:not_yet_valid|expired)\b/.test(
      text
    )
  )
    return "clock_skew";
  if (/\breason=subject_mismatch\b/.test(text)) return "identity_mismatch";
  return undefined;
}

function errorText(error: unknown) {
  return error instanceof Error
    ? error.message
    : typeof error === "string"
      ? error
      : "";
}

function isFenceError(error: unknown) {
  return (
    error instanceof ComputeNodeBindingChangedError ||
    error instanceof ComputeNodeSessionChangedError
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
