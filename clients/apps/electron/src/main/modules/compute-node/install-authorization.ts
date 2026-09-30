import type { ComputeNodeState } from "@comma/native-bridge";
import { sessionProductLease } from "@comma/session-contract";
import { z } from "zod";
import type { ElectronMainSessionService } from "../session";

const INSTALL_AUTHORIZATION_TIMEOUT_MS = 10_000;

const installDescriptorSchema = z.strictObject({
  exchange_url: z.string().url(),
  expires_at: z.string().min(1),
  one_time_secret: z.string().min(1).max(128),
  operation_id: z.string().min(1).max(128),
  version: z.literal(1),
});

const installAuthorizationResponseSchema = z.strictObject({
  descriptor: installDescriptorSchema,
  operation: z
    .object({
      id: z.string().min(1).max(160),
      registration_id: z.string().min(1).max(160),
    })
    .passthrough(),
});

const operationResponseSchema = z.strictObject({
  operation: z
    .object({
      authorization_status: z.enum([
        "requested",
        "exchange_committed",
        "handed_off",
        "action_required",
        "revoked",
      ]),
      status: z.enum(["processing", "ready", "stopped", "action_required", "removed"]),
    })
    .passthrough(),
});

export class ComputeNodeAuthorizationNotFoundError extends Error {
  constructor() {
    super("This compute node registration is unavailable in the current session.");
  }
}

export type ComputeNodeInstallAuthorizationPhase = z.infer<
  typeof operationResponseSchema
>["operation"]["authorization_status"];

export interface ComputeNodeInstallAuthorizationOwner {
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
  initializeWorkload(input: {
    operationId: string;
    workspaceId: string;
  }): Promise<void>;
  revoke(input: {
    operationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeState["status"]>;
}

/**
 * Main-owned product authorization. Bearer credentials and one-time
 * descriptors never enter renderer IPC or native replay state.
 */
export class ComputeNodeInstallAuthorization implements ComputeNodeInstallAuthorizationOwner {
  constructor(
    private readonly session: ElectronMainSessionService,
    private readonly fetcher: typeof fetch = fetch,
    private readonly timeoutMs = INSTALL_AUTHORIZATION_TIMEOUT_MS
  ) {}

  async authorize(input: {
    requestId: string;
    workspaceId: string;
  }): Promise<{ descriptor: string; operationId: string; registrationId: string }> {
    const { credential, lease } = this.credential("enabling this compute node");
    const response = await this.fetcher(
      new URL(
        `/v1/comma/workspaces/${encodeURIComponent(input.workspaceId)}/compute-nodes/agent-vmm/install-operations`,
        lease.audience
      ),
      {
        body: JSON.stringify({}),
        headers: {
          accept: "application/json",
          authorization: `Bearer ${credential.token}`,
          "content-type": "application/json",
          "idempotency-key": input.requestId,
          "x-comma-session-transport": "bearer",
        },
        method: "POST",
        redirect: "manual",
        signal: AbortSignal.any([
          credential.signal,
          AbortSignal.timeout(this.timeoutMs),
        ]),
      }
    );
    if (response.status === 401) {
      await this.session.reportUnauthorized(credential);
      throw new Error("Compute node authorization expired.");
    }
    if (!response.ok) {
      throw new Error(`Compute node authorization failed (${response.status}).`);
    }
    const result = installAuthorizationResponseSchema.parse(await response.json());
    this.requireCurrent(credential, "authorization");
    if (result.operation.id !== result.descriptor.operation_id) {
      throw new Error("Compute node authorization identity mismatch.");
    }
    return {
      descriptor: JSON.stringify(result.descriptor),
      operationId: result.operation.id,
      registrationId: result.operation.registration_id,
    };
  }

  async observe(input: {
    operationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeState["status"]> {
    return (await this.inspect(input)).status;
  }

  async inspect(input: { operationId: string; workspaceId: string }) {
    const operation = await this.request(input, "GET");
    return {
      authorizationStatus: operation.authorization_status,
      status: operation.status,
    };
  }

  async retry(input: { operationId: string; workspaceId: string }) {
    const result = await this.authorizationRequest(input, "retry");
    if (result.operation.id !== input.operationId) {
      throw new Error("Compute node retry identity mismatch.");
    }
    return {
      descriptor: JSON.stringify(result.descriptor),
      operationId: result.operation.id,
      registrationId: result.operation.registration_id,
    };
  }

  async configure(input: {
    enabled: boolean;
    operationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeState["status"]> {
    return (await this.request(input, "POST", input.enabled ? "enable" : "disable"))
      .status;
  }

  async initializeWorkload(input: {
    operationId: string;
    workspaceId: string;
  }): Promise<void> {
    await this.request(input, "POST", "initialize-workload");
  }

  async revoke(input: {
    operationId: string;
    workspaceId: string;
  }): Promise<ComputeNodeState["status"]> {
    return (await this.request(input, "POST", "revoke")).status;
  }

  private async request(
    input: { operationId: string; workspaceId: string },
    method: "GET" | "POST",
    action?: "enable" | "disable" | "revoke" | "initialize-workload"
  ) {
    const { credential, lease } = this.credential("reading compute node status");
    const suffix = action ? `/${action}` : "";
    const response = await this.fetcher(
      new URL(
        `/v1/comma/workspaces/${encodeURIComponent(input.workspaceId)}/compute-nodes/agent-vmm/install-operations/${encodeURIComponent(input.operationId)}${suffix}`,
        lease.audience
      ),
      {
        headers: {
          accept: "application/json",
          authorization: `Bearer ${credential.token}`,
          "x-comma-session-transport": "bearer",
        },
        method,
        redirect: "manual",
        signal: AbortSignal.any([
          credential.signal,
          AbortSignal.timeout(this.timeoutMs),
        ]),
      }
    );
    if (response.status === 401) await this.session.reportUnauthorized(credential);
    this.requireCurrent(credential, "status");
    if (response.status === 404) throw new ComputeNodeAuthorizationNotFoundError();
    if (!response.ok) {
      const operation = action ?? "status";
      throw new Error(`Compute node ${operation} failed (${response.status}).`);
    }
    const result = operationResponseSchema.parse(await response.json());
    this.requireCurrent(credential, "status");
    return result.operation;
  }

  private async authorizationRequest(
    input: { operationId: string; workspaceId: string },
    action: "retry"
  ) {
    const { credential, lease } = this.credential("retrying compute node installation");
    const response = await this.fetcher(
      new URL(
        `/v1/comma/workspaces/${encodeURIComponent(input.workspaceId)}/compute-nodes/agent-vmm/install-operations/${encodeURIComponent(input.operationId)}/${action}`,
        lease.audience
      ),
      {
        headers: {
          accept: "application/json",
          authorization: `Bearer ${credential.token}`,
          "x-comma-session-transport": "bearer",
        },
        method: "POST",
        redirect: "manual",
        signal: AbortSignal.any([
          credential.signal,
          AbortSignal.timeout(this.timeoutMs),
        ]),
      }
    );
    if (response.status === 401) await this.session.reportUnauthorized(credential);
    if (!response.ok)
      throw new Error(`Compute node ${action} failed (${response.status}).`);
    const result = installAuthorizationResponseSchema.parse(await response.json());
    this.requireCurrent(credential, action);
    if (result.operation.id !== result.descriptor.operation_id) {
      throw new Error("Compute node authorization identity mismatch.");
    }
    return result;
  }

  private credential(purpose: string) {
    const lease = sessionProductLease(this.session.state());
    if (!lease) throw new Error(`Sign in before ${purpose}.`);
    const credential = this.session.acquireProductCredential({
      authorityInstanceId: lease.authorityInstanceId,
      expectedAudience: lease.audience,
      expectedSessionId: lease.sessionId,
      generation: lease.generation,
    });
    if (!credential) throw new Error("Compute node session is unavailable.");
    return { credential, lease };
  }

  private requireCurrent(
    credential: ReturnType<ElectronMainSessionService["acquireProductCredential"]> & {},
    purpose: string
  ) {
    if (!this.session.isCurrentProductCredential(credential)) {
      throw new Error(`Compute node ${purpose} session changed.`);
    }
  }
}
