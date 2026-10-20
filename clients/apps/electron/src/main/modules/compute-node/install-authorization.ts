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
  /** Waits for the node to read ready (at most `waitMs`), then initializes its workload once. */
  initializeWorkload(input: {
    operationId: string;
    workspaceId: string;
    waitMs?: number;
  }): Promise<void>;
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

  async initializeWorkload(input: Operation & { waitMs?: number }): Promise<void> {
    const client = this.client();
    if (!client) throw unreachable();
    try {
      await client.call("computeNode.initializeWorkload", input);
    } catch (error) {
      const { code, message } = (error ?? {}) as { code?: string; message?: string };
      if (code !== undefined && unreachableCodes.has(code)) throw unreachable();
      throw new Error(message ?? "Compute node workload initialization failed.", {
        cause: error,
      });
    }
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
