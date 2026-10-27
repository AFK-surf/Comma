import type { ComputeNodeState } from "@comma/native-bridge";
import { sessionProductLease } from "@comma/session-contract";
import type { CoreClient } from "@comma/core-kernel/client";
import type {
  ComputeLocalMapping,
  ComputeLocalWorkloadTarget,
  ComputeLocalWorkloads,
  ComputeRecoveredBinding,
  ComputeRecoveryChallenge,
} from "@comma/core/api-schemas";
import type {
  ComputeNodeAuthorizationValue,
  ComputeNodeOperationValue,
} from "@comma/core/contract";
import { ComputeNodeCommandError } from "./command";
import type { MainSessionHost } from "../session";

export class ComputeNodeAuthorizationNotFoundError extends Error {
  constructor() {
    super("This compute node registration is unavailable in the current session.");
  }
}

/**
 * The refusals of the install-operation routes that fail the same way again (`SalixStore.AgentVMMInstallations`
 * reasons, sent by `compute_error`/`comma_error` in `comma_web/router.ex`): a gone or terminal registration, an
 * operation that cannot move on, and request or environment validation. Main stops continuing these.
 */
const terminalRefusalReasons = [
  "registration_not_found",
  "terminal_registration",
  "installation_not_handed_off",
  "handoff_expired",
  "handoff_complete",
  "operation_not_retryable",
  "invalid_request",
  "invalid_install_request",
  "invalid_install_environment",
  "invalid_install_material",
  "install_material_too_large",
  "invalid_delivery_target",
  "delivery_target_mismatch",
  "environment_scope_required",
  "scope_host_bound",
  "not_found",
] as const;
/**
 * Refusals that clear by themselves: a concurrent update, deletion or rollout, a lost race, a changed Session or
 * permission. Main keeps continuing them within its budget, as for an unknown reason, 408, 429 and 5xx.
 */
const transientRefusalReasons = [
  "update_in_progress",
  "deletion_in_progress",
  "idempotency_conflict",
  "revision_conflict",
  "environment_scope_rollout_pending",
  "compute_node_not_ready",
  "authorization_changed",
  "rate_limited",
  "expired",
  "forbidden",
] as const;
/** The server's refusal reasons that Main tells apart. Any other code is `other`; Main never logs a raw code. */
export type ComputeNodeCloudRefusalReason =
  | (typeof terminalRefusalReasons)[number]
  | (typeof transientRefusalReasons)[number]
  | "other";

/**
 * The server answered and refused the request (HTTP 4xx or 5xx). `reason` is the server's error code mapped to
 * {@link ComputeNodeCloudRefusalReason}. Only a known terminal reason outside 401, 403, 408, 429 and 5xx is
 * `terminal`: the same request fails again. Every other refusal keeps its earlier retryable handling.
 */
export class ComputeNodeCloudRefusalError extends Error {
  readonly terminal: boolean;
  constructor(
    operation: string,
    readonly status: number,
    readonly reason: ComputeNodeCloudRefusalReason,
    options?: ErrorOptions
  ) {
    super(`Compute node ${operation} failed (${status} ${reason}).`, options);
    this.terminal =
      status >= 400 &&
      status < 500 &&
      ![401, 403, 408, 429].includes(status) &&
      (terminalRefusalReasons as readonly string[]).includes(reason);
  }
}

function cloudRefusalReason(code: unknown): ComputeNodeCloudRefusalReason {
  return (terminalRefusalReasons as readonly unknown[]).includes(code) ||
    (transientRefusalReasons as readonly unknown[]).includes(code)
    ? (code as ComputeNodeCloudRefusalReason)
    : "other";
}

export type ComputeNodeInstallAuthorizationPhase =
  ComputeNodeOperationValue["authorizationStatus"];
export type LocalWorkloadTarget = ComputeLocalWorkloadTarget;
export type RecoveredComputeBinding = ComputeRecoveredBinding;
export type { ComputeRecoveryChallenge };

export interface ComputeNodeInstallAuthorizationOwner {
  inspectUnexchangedRequest?(input: {
    workspaceId: string;
    requestId: string;
  }): Promise<{ operationId: string; registrationId: string }>;
  abandon?(input: { workspaceId: string; operationId: string }): Promise<void>;
  inspectRecoveredBinding?(input: {
    workspaceId: string;
    operationId: string;
  }): Promise<RecoveredComputeBinding>;
  authorize(input: {
    requestId: string;
    workspaceId: string;
  }): Promise<{ descriptor: string; operationId: string; registrationId: string }>;
  observe(input: {
    operationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeState["status"]>;
  inspect(input: { operationId: string; workspaceId: string }): Promise<{
    authorizationStatus: ComputeNodeInstallAuthorizationPhase;
    status: ComputeNodeState["status"];
    workActivity: "idle" | "active" | "unknown";
    /** The server's failure code for an action-required operation. */
    errorCode?: string;
    /** Why the server revoked the registration. Only `authorization_expired` is replaced automatically. */
    registrationRevocationReason?: "authorization_expired" | "revoked";
    shellPhase?:
      | "not_initialized"
      | "preparing"
      | "ready"
      | "failed"
      | "deleting"
      | "deleted";
  }>;
  retry(input: {
    operationId: string;
    workspaceId: string;
  }): Promise<{ descriptor: string; operationId: string; registrationId: string }>;
  configure(input: {
    enabled: boolean;
    operationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeState["status"]>;
  revoke(input: {
    operationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeState["status"]>;
}

type Operation = { operationId: string; workspaceId: string };

/**
 * A compute node's install operation in the workspace, through the client core (`computeNode.*`): Main names the
 * session lease it acts for, and the core makes the request only for that session. The one-time descriptor comes back
 * on Main's own channel to the core; it never enters renderer IPC or native replay state.
 */
export class ComputeNodeInstallAuthorization implements ComputeNodeInstallAuthorizationOwner {
  constructor(
    private readonly session: MainSessionHost,
    private readonly client: () => CoreClient | undefined
  ) {}

  inspectUnexchangedRequest(input: { workspaceId: string; requestId: string }) {
    return this.call<{ operationId: string; registrationId: string }>(
      "computeNode.unexchangedRequest",
      input,
      "recovering this compute node",
      "recovery"
    );
  }

  authorize(input: { requestId: string; workspaceId: string }) {
    return this.call<ComputeNodeAuthorizationValue>(
      "computeNode.authorize",
      input,
      "enabling this compute node",
      "authorization"
    );
  }

  async observe(input: Operation): Promise<ComputeNodeState["status"]> {
    return (await this.inspect(input)).status;
  }

  inspect(input: Operation) {
    return this.call<ComputeNodeOperationValue>(
      "computeNode.inspect",
      input,
      "reading compute node status",
      "status",
      true
    );
  }

  retry(input: Operation) {
    return this.call<ComputeNodeAuthorizationValue>(
      "computeNode.retry",
      input,
      "retrying compute node installation",
      "retry"
    );
  }

  async configure(input: Operation & { enabled: boolean }) {
    return (
      await this.call<ComputeNodeOperationValue>(
        "computeNode.configure",
        input,
        "reading compute node status",
        input.enabled ? "enable" : "disable",
        true
      )
    ).status;
  }

  async revoke(input: Operation) {
    return (
      await this.call<ComputeNodeOperationValue>(
        "computeNode.revoke",
        input,
        "reading compute node status",
        "revoke",
        true
      )
    ).status;
  }

  inspectRecoveredBinding(input: Operation) {
    return this.call<RecoveredComputeBinding>(
      "computeNode.recoveredBinding",
      input,
      "reading compute node status",
      "status",
      true
    );
  }

  async abandon(input: Operation) {
    await this.call<null>(
      "computeNode.abandon",
      input,
      "recovering this compute node",
      "recovery"
    );
  }

  localMappings(workspaceId: string, targets: LocalWorkloadTarget[]) {
    return this.call<ComputeLocalMapping[]>(
      "computeNode.localMappings",
      { workspaceId, targets },
      "recovering this compute node",
      "recovery"
    );
  }

  localWorkloads(workspaceId: string, target: LocalWorkloadTarget, afterId?: string) {
    return this.call<ComputeLocalWorkloads>(
      "computeNode.localWorkloads",
      { workspaceId, target, ...(afterId !== undefined ? { afterId } : {}) },
      "recovering this compute node",
      "recovery"
    );
  }

  recoveryCandidates(workspaceId: string, registrationIds: string[]) {
    return this.call<ComputeRecoveryChallenge[]>(
      "computeNode.recoveryCandidates",
      { workspaceId, registrationIds },
      "recovering this compute node",
      "recovery"
    );
  }

  recoverBinding(
    workspaceId: string,
    operationId: string,
    proof: unknown,
    consume: boolean
  ) {
    return this.call<RecoveredComputeBinding>(
      "computeNode.recoverBinding",
      { workspaceId, operationId, proof, consume },
      "recovering this compute node",
      "recovery"
    );
  }

  /**
   * `name` for the session Main holds now. `operation` names what failed; `scoped`: a missing operation (404) is one
   * this session cannot see (ComputeNodeAuthorizationNotFoundError).
   */
  private async call<T>(
    name: string,
    params: Record<string, unknown>,
    purpose: string,
    operation: string,
    scoped = false
  ): Promise<T> {
    const lease = sessionProductLease(this.session.state());
    if (!lease) throw new Error(`Sign in before ${purpose}.`);
    const client = this.client();
    if (!client) throw unreachable();
    try {
      return (await client.call(name, {
        ...params,
        lease: {
          audience: lease.audience,
          authorityInstanceId: lease.authorityInstanceId,
          generation: lease.generation,
          sessionId: lease.sessionId,
        },
      })) as T;
    } catch (error) {
      const { code, status } = (error ?? {}) as { code?: string; status?: number };
      if (code !== undefined && unreachableCodes.has(code)) throw unreachable();
      if (scoped && status === 404) throw new ComputeNodeAuthorizationNotFoundError();
      if (code === "session_changed" || code === "signed_out")
        throw new Error(`Compute node ${operation} session changed.`, { cause: error });
      if (typeof status === "number" && status >= 400 && status < 600)
        throw new ComputeNodeCloudRefusalError(
          operation,
          status,
          cloudRefusalReason(code),
          { cause: error }
        );
      throw new Error(
        `Compute node ${operation} failed (${status ?? code ?? "unknown"}).`,
        { cause: error }
      );
    }
  }
}

/**
 * The core's codes for a request that got no answer, or none it could read: its outcome is unknown. Main's `/v1`
 * proxy answers `upstream_unavailable` when the service did not answer it.
 */
const unreachableCodes = new Set([
  "upstream_unavailable",
  "network",
  "timeout",
  "bad_response",
  "disconnected",
  "closed",
  "no_core",
]);

function unreachable() {
  return new ComputeNodeCommandError(
    "The workspace service could not be reached. Check its status before continuing the same setup.",
    "outcome_unknown",
    { code: "cloud_unavailable", reason: "cloud_unavailable" }
  );
}
