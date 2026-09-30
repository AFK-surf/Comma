import type { HostPreparation, HostPreparationState } from "./host-preparation";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { sessionProductLease } from "@comma/session-contract";
import type {
  ComputeNodeConfigureInput,
  ComputeNodeExpectedBinding,
  ComputeNodeOperation,
  ComputeNodeState,
} from "@comma/native-bridge";
import { computeNodeStateSchema } from "@comma/native-bridge";
import { z } from "zod";
import type { ElectronMainSessionService } from "../session";

class ComputeNodeBindingChangedError extends Error {}

export type ComputeNodeWorkActivity = "idle" | "active" | "unknown";

const WORK_ACTIVITY_TIMEOUT_MS = 2_000;
const COMMA_AGENT_VMM_SERVICE_ARGS = ["--service-type", "agent"] as const;
import {
  ComputeNodeAuthorizationNotFoundError,
  type ComputeNodeInstallAuthorizationOwner,
} from "./install-authorization";
export {
  ComputeNodeInstallAuthorization,
  type ComputeNodeInstallAuthorizationOwner,
} from "./install-authorization";

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

export interface ComputeNodeWorkloadObservation {
  activity: ComputeNodeWorkActivity;
  readable: boolean;
}

export interface ComputeNodeWorkloadObservationOwner {
  observe(registrationId?: string): Promise<ComputeNodeWorkloadObservation>;
}

export interface ComputeNodeRuntimeObservation {
  connector: ComputeNodeState["observed"]["connector"];
  host: ComputeNodeState["observed"]["host"];
  readability: ComputeNodeState["observed"]["readability"];
  salix: ComputeNodeState["observed"]["salix"];
}

export interface ComputeNodeRuntimeAdapter {
  drain(requestId?: string, registrationId?: string): Promise<void>;
  enable(requestId?: string, registrationId?: string): Promise<void>;
  install(requestId?: string, descriptor?: string): Promise<void>;
  observe(registrationId?: string): Promise<ComputeNodeRuntimeObservation>;
  remove(requestId?: string, registrationId?: string): Promise<void>;
  resume(operationId: string, requestId?: string): Promise<void>;
  repair(requestId?: string): Promise<void>;
}

interface PersistedIntent {
  desiredEnabled: boolean;
  installOperationId?: string;
  installAppliedOperationId?: string;
  registrationId?: string;
  workspaceId?: string;
  operation?: ComputeNodeOperation;
  remoteRevocationConfirmed?: boolean;
  revision: number;
  version: 1 | 2 | 3;
}

export interface ComputeNodeServiceOptions {
  adapter: ComputeNodeRuntimeAdapter;
  preparation?: HostPreparation;
  filePath: string;
  onStateChanged?: ((state: ComputeNodeState) => void) | undefined;
  workloadObservation?: ComputeNodeWorkloadObservationOwner | undefined;
  installAuthorization?: ComputeNodeInstallAuthorizationOwner | undefined;
  platform?: NodeJS.Platform | undefined;
  arch?: string | undefined;
  initializationWaitMs?: number;
}

const absentObservation: ComputeNodeRuntimeObservation = {
  connector: "absent",
  host: "absent",
  readability: "readable",
  salix: "unregistered",
};

/**
 * Main-owned, serialized desired/observed lifecycle for the local Agent VMM.
 * Anchors: tla/salix/VMMRemoteEnrollment.tla and agent-vmm/spec/tla/ApplianceLifecycle.tla.
 */
export class ComputeNodeService {
  private intent: PersistedIntent = { desiredEnabled: false, revision: 1, version: 3 };
  private snapshot: ComputeNodeState;
  private tail: Promise<unknown> = Promise.resolve();
  private workActivity: ComputeNodeWorkActivity = "unknown";
  private refreshPromise: Promise<ComputeNodeState> | undefined;
  private observationFresh = false;
  private observedAt?: string;

  private constructor(private readonly options: ComputeNodeServiceOptions) {
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
      this.requireEligible();
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

      // Persist the user's target before crossing the helper side-effect
      // boundary. A process exit after install but before the final
      // observation must recover toward enabled, not toward the old value.
      delete this.intent.remoteRevocationConfirmed;
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
      try {
        await this.options.preparation?.ensure((preparation) =>
          this.reportPreparation(preparation)
        );
        const operation = this.intent.operation;
        if (!operation) {
          throw new Error("Compute node authorization identity is unavailable.");
        }
        if (this.intent.installOperationId && this.snapshot.status !== "removed") {
          const operationId = this.intent.installOperationId;
          const projection = await this.options.installAuthorization.inspect({
            operationId,
            workspaceId: input.workspaceId,
          });
          if (projection.authorizationStatus === "requested") {
            const authorization = await this.options.installAuthorization.retry({
              operationId,
              workspaceId: input.workspaceId,
            });
            this.intent.registrationId = authorization.registrationId;
            await this.persistIntent();
            await this.options.adapter.install(operationId, authorization.descriptor);
            this.intent.installAppliedOperationId = operationId;
          } else if (projection.authorizationStatus === "exchange_committed") {
            await this.options.adapter.resume(operationId, operation.requestId);
            this.intent.installAppliedOperationId = operationId;
          } else if (projection.authorizationStatus === "handed_off") {
            if (this.intent.installAppliedOperationId !== operationId) {
              await this.options.adapter.resume(operationId, operation.requestId);
              this.intent.installAppliedOperationId = operationId;
            } else {
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
          const authorization = await this.options.installAuthorization.authorize({
            requestId: operation.requestId,
            workspaceId: input.workspaceId,
          });
          this.intent.installOperationId = authorization.operationId;
          this.intent.registrationId = authorization.registrationId;
          operation.operationId = authorization.operationId;
          await this.persistIntent();
          await this.options.adapter.install(
            authorization.operationId,
            authorization.descriptor
          );
          this.intent.installAppliedOperationId = authorization.operationId;
        }
        observed = await this.options.adapter.observe(this.intent.registrationId);
      } catch (error) {
        observed = await this.observeAfterFailure();
        this.finishOperation(isUnknownFailure(error) ? "unknown" : "failed");
        await this.persistIntent();
        this.publish(
          "action_required",
          observed,
          error instanceof Error ? error.message : "Compute node operation failed."
        );
        throw error;
      }
      observed = await this.observeProductStatus(observed);
      if (observed.salix === "degraded") {
        this.finishOperation("failed");
        await this.persistIntent();
        this.publish(
          "action_required",
          observed,
          "Compute node product authorization requires attention."
        );
        throw new Error("Compute node product authorization requires attention.");
      }
      try {
        await this.initializeWorkload();
        this.finishOperation("succeeded");
      } catch (error) {
        this.finishOperation("failed");
        await this.persistIntent();
        throw error;
      }
      await this.persistIntent();
      return this.reconcile();
    });
  }

  private async initializeWorkload() {
    const owner = this.options.installAuthorization!;
    const operationId = this.intent.installOperationId!;
    const workspaceId = this.intent.workspaceId!;
    // One enable action observes one node, at most 31 times over 30 seconds.
    // Only status reads repeat. The mutation runs once and requires explicit retry on failure.
    const deadline = Date.now() + (this.options.initializationWaitMs ?? 30_000);
    while (true) {
      const status = await owner.observe({ operationId, workspaceId });
      if (status === "ready") {
        await owner.initializeWorkload({ operationId, workspaceId });
        return;
      }
      if (
        status === "action_required" ||
        status === "removed" ||
        Date.now() >= deadline
      ) {
        throw new Error(
          "Compute node workload initialization could not complete. Check the node connection, then select Continue / Retry."
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 1_000));
    }
  }

  rebuild() {
    return this.run(async () => {
      this.requireEligible();
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
          error instanceof Error ? error.message : String(error)
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
        this.publish(
          "action_required",
          observed,
          error instanceof Error ? error.message : "Compute node repair failed."
        );
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
      this.beginOperation("remove");
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
          await this.options.installAuthorization.revoke({
            operationId: installOperationId,
            workspaceId,
          });
        } catch (error) {
          // A scoped 404 can hide an inaccessible registration. Only an explicit
          // removal may detach it locally; never claim remote revocation.
          if (!(error instanceof ComputeNodeAuthorizationNotFoundError)) throw error;
          unavailableRegistration = true;
        }
        await this.options.adapter.remove(
          this.intent.operation?.requestId,
          this.intent.registrationId
        );
      } catch (error) {
        const observed = await this.observeAfterFailure();
        this.finishOperation(isUnknownFailure(error) ? "unknown" : "failed");
        await this.persistIntent();
        this.publish(
          "action_required",
          observed,
          error instanceof Error ? error.message : "Compute node removal failed."
        );
        throw error;
      }
      let observed = await this.options.adapter.observe(this.intent.registrationId);
      if (!unavailableRegistration)
        observed = await this.observeProductStatus(observed);
      if (
        observed.readability !== "readable" ||
        (!unavailableRegistration && !this.removalConfirmed(observed))
      ) {
        this.finishOperation("unknown");
        await this.persistIntent();
        return this.publish(
          "action_required",
          observed,
          "Compute node removal is not confirmed."
        );
      }
      this.finishOperation("succeeded");
      this.intent.remoteRevocationConfirmed = !unavailableRegistration;
      delete this.intent.workspaceId;
      delete this.intent.installOperationId;
      delete this.intent.installAppliedOperationId;
      delete this.intent.registrationId;
      await this.persistIntent();
      return this.publish(
        "removed",
        observed,
        unavailableRegistration
          ? "Local binding removed. The previous registration was inaccessible; remote revocation is not confirmed."
          : undefined
      );
    });
  }

  private async initialize() {
    try {
      const parsed = JSON.parse(
        await readFile(this.options.filePath, "utf8")
      ) as unknown;
      if (
        typeof parsed === "object" &&
        parsed !== null &&
        "version" in parsed &&
        (parsed.version === 1 || parsed.version === 2 || parsed.version === 3) &&
        "desiredEnabled" in parsed &&
        typeof parsed.desiredEnabled === "boolean" &&
        "revision" in parsed &&
        typeof parsed.revision === "number"
      ) {
        this.intent = { ...(parsed as PersistedIntent), version: 3 };
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        this.publish(
          "action_required",
          undefined,
          "Saved compute node intent is unreadable."
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
        (observed.host === "stopped" || observed.host === "absent")
      ) {
        this.finishOperation("succeeded");
        await this.persistIntent();
        return this.reconcile();
      }
      this.finishOperation(isUnknownFailure(error) ? "unknown" : "failed");
      await this.persistIntent();
      this.publish(
        "action_required",
        observed,
        error instanceof Error ? error.message : "Compute node drain failed."
      );
      throw error;
    }
    this.finishOperation("succeeded");
    return this.reconcile();
  }

  private async reconcile(settleOperation = true) {
    this.observationFresh = true;
    let observed = await this.options.adapter.observe(this.intent.registrationId);
    observed = await this.observeProductStatus(observed);
    this.workActivity = await this.observeWorkActivity(this.intent.registrationId);
    if (settleOperation && this.confirmedOperation(observed)) {
      this.finishOperation("succeeded");
      await this.persistIntent();
    }
    if (observed.readability !== "readable") this.observationFresh = false;
    if (this.observationFresh) this.observedAt = new Date().toISOString();
    let status: ComputeNodeState["status"];
    if (observed.readability === "unreadable") status = "action_required";
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
    return this.publish(status, observed);
  }

  private publish(
    status: ComputeNodeState["status"],
    observed = this.snapshot.observed,
    problem?: string
  ) {
    // registrationId is a main-owned correlation detail used by the
    // independent Workload reader. It is not part of the renderer state
    // contract and must not leak into the strict native state schema.
    const stateObserved: ComputeNodeState["observed"] = {
      connector: observed.connector,
      host: observed.host,
      readability: observed.readability,
      salix: observed.salix,
    };
    this.snapshot = computeNodeStateSchema.parse({
      bindingWorkspaceId: this.intent.workspaceId,
      bindingInstallationId: this.intent.installOperationId,
      observedAt: this.observedAt,
      observationFresh: this.observationFresh,
      remoteRevocationConfirmed: this.intent.remoteRevocationConfirmed,
      ...this.recoveryFor(status, observed),
      desiredEnabled: this.intent.desiredEnabled,
      eligibility: this.snapshot.eligibility,
      preparation: this.snapshot.preparation,
      observed: stateObserved,
      facets: facetsFor(status, observed, this.workActivity),
      ...(this.intent.operation ? { operation: this.intent.operation } : {}),
      ...(problem ? { problem } : {}),
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
    const canContinue =
      this.intent.desiredEnabled &&
      this.intent.operation?.kind === "configure" &&
      !!this.intent.workspaceId;
    const recoveryActions: NonNullable<ComputeNodeState["recoveryActions"]> =
      canContinue ? ["continue_enable", "check_status"] : ["check_status"];
    if (this.intent.operation?.outcome === "unknown")
      return { issue: "operation_unknown", recoveryActions };
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

  private async persistIntent() {
    this.intent.revision = Math.max(
      this.intent.revision + 1,
      this.snapshot.revision + 1
    );
    await mkdir(dirname(this.options.filePath), { recursive: true });
    const temporary = `${this.options.filePath}.tmp`;
    await writeFile(temporary, JSON.stringify(this.intent), { mode: 0o600 });
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
      return observed.host === "stopped" || observed.host === "absent";
    }
    if (operation.kind === "remove") return this.removalConfirmed(observed);
    // Install/configure success requires the helper's exact operation result;
    // generic ready facts do not prove the requested release/digest.
    return false;
  }

  private removalConfirmed(observed: ComputeNodeRuntimeObservation) {
    // Product removal revokes the exact registration. The shared Host may
    // remain installed for registrations owned by other products/scopes.
    return observed.salix === "revoked";
  }

  private async observeAfterFailure() {
    try {
      return await this.options.adapter.observe(this.intent.registrationId);
    } catch {
      return this.snapshot.observed;
    }
  }

  private async observeWorkActivity(registrationId?: string) {
    const owner = this.options.workloadObservation;
    if (!owner) return "unknown" as const;
    try {
      const observation = await owner.observe(registrationId);
      return observation.readable ? observation.activity : "unknown";
    } catch {
      return "unknown" as const;
    }
  }

  private async observeProductStatus(observed: ComputeNodeRuntimeObservation) {
    const owner = this.options.installAuthorization;
    const workspaceId = this.intent.workspaceId;
    const operationId = this.intent.installOperationId;
    if (!owner || !workspaceId || !operationId) return observed;
    try {
      const status = await owner.observe({ operationId, workspaceId });
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
    } catch {
      this.observationFresh = false;
      return { ...observed, salix: "degraded" as const };
    }
  }

  private requireBinding(expected?: ComputeNodeExpectedBinding) {
    if (
      expected &&
      (expected.workspaceId !== this.intent.workspaceId ||
        expected.installationId !== (this.intent.installOperationId ?? null))
    )
      throw new ComputeNodeBindingChangedError(
        "Compute node binding changed. Review the current node before confirming again."
      );
  }

  private requireEligible() {
    if (!this.snapshot.eligibility.eligible) {
      throw new Error(
        this.snapshot.eligibility.reason ?? "Compute node is unsupported."
      );
    }
  }

  private run(operation: () => Promise<ComputeNodeState>) {
    const result = this.tail.then(operation, operation).catch((error: unknown) => {
      if (error instanceof ComputeNodeBindingChangedError) throw error;
      this.publish(
        "action_required",
        undefined,
        error instanceof Error ? error.message : "Compute node operation failed."
      );
      throw error;
    });
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
    observed.host === "ready" && observed.salix === "ready"
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

export class AgentVMMCommandAdapter implements ComputeNodeRuntimeAdapter {
  private lastKnown: ComputeNodeRuntimeObservation = absentObservation;

  constructor(
    private readonly lifecyclePath: string,
    private readonly run = runCommand
  ) {}

  async observe(registrationId?: string): Promise<ComputeNodeRuntimeObservation> {
    try {
      const output = await this.run(this.lifecyclePath, [
        "status",
        ...COMMA_AGENT_VMM_SERVICE_ARGS,
        ...(registrationId ? ["--registration-id", registrationId] : []),
      ]);
      const value = JSON.parse(output) as Record<string, unknown>;
      const hasCompleteReadinessFacts = ["hostReadable", "hostHealthy"].every(
        (key) => key in value
      );
      const hostReady =
        Boolean(value.hostLoaded) &&
        hasCompleteReadinessFacts &&
        Boolean(value.hostReadable) &&
        Boolean(value.hostHealthy);
      const observed: ComputeNodeRuntimeObservation = {
        connector: value.connectorLoaded
          ? "ready"
          : value.connectorInstalled
            ? "stopped"
            : "absent",
        host: hostReady
          ? "ready"
          : hasCompleteReadinessFacts && value.hostLoaded
            ? "degraded"
            : value.hostInstalled
              ? "stopped"
              : "absent",
        readability: "readable",
        salix: value.salixRevoked ? "revoked" : "unregistered",
      };
      this.lastKnown = observed;
      return observed;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT")
        return { ...absentObservation };
      return { ...this.lastKnown, readability: "unreadable" };
    }
  }

  async repair(requestId?: string) {
    await this.run(this.lifecyclePath, lifecycleArgs("repair", requestId));
  }

  async enable(requestId?: string, registrationId?: string) {
    if (!registrationId) {
      throw new Error("Compute node registration identity is unavailable.");
    }
    await this.run(
      this.lifecyclePath,
      registrationStateArgs("enabled", registrationId, requestId)
    );
  }

  async install(requestId?: string, descriptor?: string) {
    await this.run(
      this.lifecyclePath,
      [
        ...lifecycleArgs("install", requestId),
        ...(descriptor ? ["--operation-stdin"] : []),
      ],
      descriptor,
      180_000
    );
  }
  async resume(operationId: string, _requestId?: string) {
    await this.run(
      this.lifecyclePath,
      [...lifecycleArgs("install", operationId), "--resume-operation", operationId],
      undefined,
      180_000
    );
  }
  async drain(requestId?: string, registrationId?: string) {
    if (!registrationId) {
      throw new Error("Compute node registration identity is unavailable.");
    }
    await this.run(
      this.lifecyclePath,
      registrationStateArgs("draining", registrationId, requestId)
    );
  }

  async remove(requestId?: string, registrationId?: string) {
    await this.drain(requestId, registrationId);
  }
}

const workActivityResponseSchema = z.strictObject({
  activity: z.enum(["idle", "active"]),
  active_operation_count: z.number().int().nonnegative(),
  workload_count: z.number().int().nonnegative(),
});

/**
 * Main-owned reader for the independent Salix Workload activity projection.
 * It has no lifecycle mutation authority and never infers activity from the
 * local VMM status command.
 */
export class ComputeWorkloadActivityOwner implements ComputeNodeWorkloadObservationOwner {
  constructor(
    private readonly session: ElectronMainSessionService,
    private readonly fetcher: typeof fetch = fetch,
    private readonly timeoutMs = WORK_ACTIVITY_TIMEOUT_MS
  ) {}

  async observe(registrationId?: string): Promise<ComputeNodeWorkloadObservation> {
    if (!registrationId) return { activity: "unknown", readable: false };
    const lease = sessionProductLease(this.session.state());
    if (!lease) return { activity: "unknown", readable: false };
    const credential = this.session.acquireProductCredential({
      authorityInstanceId: lease.authorityInstanceId,
      expectedAudience: lease.audience,
      expectedSessionId: lease.sessionId,
      generation: lease.generation,
    });
    if (!credential) return { activity: "unknown", readable: false };

    try {
      const signal = AbortSignal.any([
        credential.signal,
        AbortSignal.timeout(this.timeoutMs),
      ]);
      const response = await this.fetcher(
        new URL(
          `/v1/compute-node/work-activity/${encodeURIComponent(registrationId)}`,
          lease.audience
        ),
        {
          headers: {
            accept: "application/json",
            authorization: `Bearer ${credential.token}`,
            "x-comma-session-transport": "bearer",
          },
          method: "GET",
          redirect: "manual",
          signal,
        }
      );
      if (response.status === 401) {
        await this.session.reportUnauthorized(credential);
        return { activity: "unknown", readable: false };
      }
      if (!response.ok) return { activity: "unknown", readable: false };
      const result = workActivityResponseSchema.parse(await response.json());
      if (!this.session.isCurrentProductCredential(credential)) {
        return { activity: "unknown", readable: false };
      }
      return { activity: result.activity, readable: true };
    } catch {
      return { activity: "unknown", readable: false };
    }
  }
}

function lifecycleArgs(operation: string, requestId?: string) {
  return requestId
    ? [operation, ...COMMA_AGENT_VMM_SERVICE_ARGS, "--request-id", requestId]
    : [operation, ...COMMA_AGENT_VMM_SERVICE_ARGS];
}

function registrationStateArgs(
  state: "enabled" | "draining",
  registrationId: string,
  requestId?: string
) {
  return [
    "registration-state",
    ...COMMA_AGENT_VMM_SERVICE_ARGS,
    "--registration-id",
    registrationId,
    "--state",
    state,
    ...(requestId ? ["--request-id", requestId] : []),
  ];
}

function isUnknownFailure(error: unknown) {
  return (
    error instanceof Error &&
    /timed out|timeout|connection reset|broken pipe/i.test(error.message)
  );
}

export function runCommand(
  file: string,
  args: string[],
  stdin?: string,
  timeoutMs = 15_000,
  options: { cwd?: string; env?: NodeJS.ProcessEnv } = {}
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, {
      ...options,
      detached: process.platform !== "win32",
      stdio: ["pipe", "pipe", "pipe"],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let settled = false;
    const finish = (callback: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
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
      const force = setTimeout(() => signalProcessTree("SIGKILL"), 1_000);
      force.unref();
    };
    const timeout = setTimeout(() => {
      terminate();
      finish(() =>
        reject(new Error(`Agent VMM command timed out after ${timeoutMs}ms.`))
      );
    }, timeoutMs);
    timeout.unref();
    child.stdout.on("data", (chunk: Buffer) => appendCommandOutput(stdout, chunk));
    child.stderr.on("data", (chunk: Buffer) => appendCommandOutput(stderr, chunk));
    child.once("error", (error) => finish(() => reject(error)));
    child.once("close", (code) => {
      if (code === 0) finish(() => resolve(Buffer.concat(stdout).toString("utf8")));
      else
        finish(() =>
          reject(
            new Error(
              Buffer.concat(stderr).toString("utf8").trim().slice(-4096) ||
                `Agent VMM command failed (${code ?? "signal"}).`
            )
          )
        );
    });
    child.stdin.end(stdin);
  });
}

function appendCommandOutput(chunks: Buffer[], chunk: Buffer) {
  chunks.push(chunk.subarray(-256 * 1024));
  while (
    chunks.length > 1 &&
    chunks.reduce((size, item) => size + item.length, 0) > 256 * 1024
  )
    chunks.shift();
}
