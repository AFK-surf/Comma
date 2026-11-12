import type { ComputeNodeState } from "@comma/native-bridge";
import { sessionProductLease } from "@comma/session-contract";
import type { CoreClient } from "@comma/core-kernel/client";
import type {
  ComputeLocalMapping,
  ComputeLocalWorkloadTarget,
  ComputeLocalWorkloads,
  ComputeRecoveredBinding,
} from "@comma/core/api-schemas";
import type {
  ComputeNodeAuthorizationValue,
  ComputeNodeRegistrationValue,
} from "@comma/core/contract";
import { ComputeNodeCommandError } from "./command";
import type { MainSessionHost } from "../session";

export class ComputeNodeAuthorizationNotFoundError extends Error {
  constructor() {
    super("This compute node registration is unavailable in the current session.");
  }
}

export class ComputeNodeTicketNotRetryableError extends Error {
  constructor(cause: unknown) {
    super("The server did not issue a new claim ticket.", { cause });
  }
}

export type LocalWorkloadTarget = ComputeLocalWorkloadTarget;
export type RecoveredComputeBinding = ComputeRecoveredBinding;

export interface ComputeNodeInstallAuthorizationOwner {
  cancelRequest?(input: {
    workspaceId: string;
    requestId: string;
  }): Promise<{ registrationId: string; hostBound: boolean }>;
  recoveryDescriptor?(input: { registrationId: string; workspaceId: string }): string;
  inspectRequest?(input: {
    workspaceId: string;
    requestId: string;
  }): Promise<{ registrationId: string }>;
  authorize(input: {
    requestId: string;
    workspaceId: string;
  }): Promise<ComputeNodeAuthorizationValue>;
  observe(input: {
    registrationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeState["status"]>;
  inspect(input: {
    registrationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeRegistrationValue>;
  retry(input: {
    registrationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeAuthorizationValue>;
  configure(input: {
    enabled: boolean;
    registrationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeState["status"]>;
  revoke(input: {
    registrationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeState["status"]>;
}

type RegistrationTarget = { registrationId: string; workspaceId: string };

/**
 * A compute node's Registration in the Workspace, through the client core (`computeNode.*`): Main names the
 * session lease it acts for, and the core makes the request only for that session. The one-time descriptor comes back
 * on Main's own channel to the core; it never enters renderer IPC or native replay state.
 */
export class ComputeNodeInstallAuthorization implements ComputeNodeInstallAuthorizationOwner {
  constructor(
    private readonly session: MainSessionHost,
    private readonly client: () => CoreClient | undefined
  ) {}

  inspectRequest(input: { workspaceId: string; requestId: string }) {
    return this.call<{ registrationId: string }>(
      "computeNode.requestRegistration",
      input,
      "recovering this compute node",
      "recovery"
    );
  }

  cancelRequest(input: { workspaceId: string; requestId: string }) {
    return this.call<{ registrationId: string; hostBound: boolean }>(
      "computeNode.cancelRequest",
      input,
      "canceling this compute request",
      "cancel"
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

  async observe(input: RegistrationTarget): Promise<ComputeNodeState["status"]> {
    return (await this.inspect(input)).status;
  }

  inspect(input: RegistrationTarget) {
    return this.call<ComputeNodeRegistrationValue>(
      "computeNode.inspect",
      input,
      "reading compute node status",
      "status",
      true
    );
  }

  retry(input: RegistrationTarget) {
    return this.call<ComputeNodeAuthorizationValue>(
      "computeNode.retry",
      input,
      "retrying compute node installation",
      "retry"
    );
  }

  async configure(input: RegistrationTarget & { enabled: boolean }) {
    return (
      await this.call<ComputeNodeRegistrationValue>(
        "computeNode.configure",
        input,
        "reading compute node status",
        input.enabled ? "enable" : "disable",
        true
      )
    ).status;
  }

  async revoke(input: RegistrationTarget) {
    return (
      await this.call<ComputeNodeRegistrationValue>(
        "computeNode.revoke",
        input,
        "reading compute node status",
        "revoke",
        true
      )
    ).status;
  }

  recoveryDescriptor(input: { registrationId: string; workspaceId: string }) {
    const expected = sessionProductLease(this.session.state());
    if (!expected) throw new Error("Sign in before reauthorizing this registration.");
    const lease = this.session.acquireProductCredential({
      authorityInstanceId: expected.authorityInstanceId,
      generation: expected.generation,
      expectedAudience: expected.audience,
      expectedSessionId: expected.sessionId,
    });
    if (!lease) throw new Error("Compute recovery session changed.");
    return JSON.stringify({
      version: 1,
      registration_id: input.registrationId,
      recovery_url: new URL(
        `/v1/comma/workspaces/${encodeURIComponent(input.workspaceId)}/compute-nodes/agent-vmm/registrations/${encodeURIComponent(input.registrationId)}/recovery`,
        lease.audience
      ).href,
      authorization: lease.token,
    });
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
    return this.call<RecoveredComputeBinding[]>(
      "computeNode.recoveryCandidates",
      { workspaceId, registrationIds },
      "recovering this compute node",
      "recovery"
    );
  }

  /**
   * `name` for the session Main holds now. `operation` names what failed; `scoped`: a missing registration (404) is one
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
      if (operation === "retry" && code === "registration_not_retryable")
        throw new ComputeNodeTicketNotRetryableError(error);
      if (code === "session_changed" || code === "signed_out")
        throw new Error(`Compute node ${operation} session changed.`, { cause: error });
      if (typeof status === "number" && status >= 400 && status < 600)
        throw new Error(`Compute node ${operation} failed (${status}).`, {
          cause: error,
        });
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
