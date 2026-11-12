import { helperContractFailure } from "./host-maintenance-protocol";
import type { ComputeNodeState } from "@comma/native-bridge";
import { runCommand } from "./command";

const COMMA_AGENT_VMM_SERVICE_ARGS = ["--service-type", "agent"] as const;

export interface ComputeNodeRuntimeObservation {
  connector: ComputeNodeState["observed"]["connector"];
  host: ComputeNodeState["observed"]["host"];
  readability: ComputeNodeState["observed"]["readability"];
  salix: ComputeNodeState["observed"]["salix"];
  helperContractFailure?: "too_old" | "too_new";
  remoteProtocol?: {
    hostProtocol: string;
    minProtocol: number;
    maxProtocol: number;
    hostSide: "too_old" | "too_new";
  };
  registration?: "present" | "absent" | "unreadable";
  registrationState?: "enabled" | "draining" | "revoked";
  /** The installed Host stopped because it cannot open this Mac's local data. */
  hostStartFailure?: {
    code: "STATE_SCHEMA_INCOMPATIBLE" | "STATE_MIGRATION_FAILED";
    dataSchema?: number;
  };
  reason?:
    | "operator_unavailable"
    | "registration_unreadable"
    | "registration_not_found"
    | "capability_missing";
}

export interface ComputeNodeRuntimeAdapter {
  drain(requestId?: string, registrationId?: string): Promise<void>;
  enable(
    requestId?: string,
    registrationId?: string
  ): Promise<NativeRequestReceipt | void>;
  install(
    requestId?: string,
    descriptor?: string
  ): Promise<NativeRequestReceipt | void>;
  observe(
    registrationId?: string,
    installOperationId?: string
  ): Promise<ComputeNodeRuntimeObservation>;
  remove(requestId?: string, registrationId?: string): Promise<void>;
  resume(operationId: string, requestId?: string): Promise<NativeRequestReceipt | void>;
  repair(requestId?: string): Promise<void>;
  recover?(requestId: string, descriptor: string): Promise<NativeRequestReceipt | void>;

  receipt?(
    requestId: string,
    registrationId?: string
  ): Promise<NativeRequestReceipt | undefined>;
}

export interface NativeRequestReceipt {
  requestId: string;
  targetRegistrationId?: string;
  correlationRequestId?: string;
  kind: string;
  outcome: "pending" | "failed" | "succeeded" | "superseded";
  retryable?: boolean;
  stage?: string;
  failureCode?: string;
}

export const absentObservation: ComputeNodeRuntimeObservation = {
  connector: "absent",
  host: "absent",
  readability: "readable",
  salix: "unregistered",
};

/**
 * Main-owned, serialized desired/observed lifecycle for the local Agent VMM.
 */
export class AgentVMMCommandAdapter implements ComputeNodeRuntimeAdapter {
  private readonly executions = new Map<
    string,
    { registrationId: string; abort: AbortController; done: Promise<unknown> }
  >();
  private lastKnown: ComputeNodeRuntimeObservation = absentObservation;

  constructor(
    private readonly lifecyclePath: string,
    private readonly run = runCommand
  ) {}

  async recover(requestId: string, descriptor: string) {
    return this.tracked(
      requestId,
      JSON.parse(descriptor).registration_id as string,
      [
        "registration-recover",
        ...COMMA_AGENT_VMM_SERVICE_ARGS,
        "--request-id",
        requestId,
        "--descriptor-stdin",
      ],
      descriptor,
      180_000
    );
  }

  async receipt(
    requestId: string,
    registrationId?: string
  ): Promise<NativeRequestReceipt | undefined> {
    const value = JSON.parse(
      await this.run(
        this.lifecyclePath,
        [
          "operation",
          ...COMMA_AGENT_VMM_SERVICE_ARGS,
          "--request-id",
          requestId,
          ...(registrationId ? ["--registration-id", registrationId] : []),
        ],
        undefined,
        5_000
      )
    );
    const receipt = parseRequestReceipt(value);
    if (
      receipt &&
      receipt.requestId !== requestId &&
      (receipt.correlationRequestId !== requestId ||
        receipt.targetRegistrationId !== registrationId ||
        receipt.kind !== "registration-recover")
    )
      throw new Error("The native receipt does not acknowledge this request.");
    return receipt;
  }

  async observe(
    registrationId?: string,
    installOperationId?: string
  ): Promise<ComputeNodeRuntimeObservation> {
    void installOperationId;
    const lastKnown = this.lastKnown;
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
      const registration = registrationId
        ? value.registrationRead === "present" ||
          value.registrationRead === "absent" ||
          value.registrationRead === "unreadable"
          ? value.registrationRead
          : "unreadable"
        : undefined;
      const registrationState =
        value.registrationState === "enabled" ||
        value.registrationState === "draining" ||
        value.registrationState === "revoked"
          ? value.registrationState
          : undefined;
      const contractFailure = helperContractFailure(value);
      const observed: ComputeNodeRuntimeObservation = {
        ...(contractFailure ? { helperContractFailure: contractFailure } : {}),
        ...(registrationId ? readRemoteProtocol(value.remoteProtocol) : {}),
        ...readHostStartFailure(value.hostStartFailure),
        ...(registration ? { registration } : {}),
        ...(registrationId && registrationState ? { registrationState } : {}),
        ...(registrationId && !value.registrationRead
          ? { reason: "capability_missing" as const }
          : {}),
        connector:
          registration === "absent"
            ? "absent"
            : registration === "unreadable"
              ? "degraded"
              : value.connectorLoaded
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
        readability: registration === "unreadable" ? "unreadable" : "readable",
        salix: "unregistered",
      };
      this.lastKnown = observed;
      return observed;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT" && !registrationId)
        return { ...absentObservation };
      if (registrationId)
        return {
          ...lastKnown,
          readability: "unreadable",
          registration: "unreadable",
          reason: "operator_unavailable",
        };
      return { ...lastKnown, readability: "unreadable" };
    }
  }

  async repair(requestId?: string) {
    await this.mutate(lifecycleArgs("repair", requestId), undefined, undefined, true);
  }

  async enable(requestId?: string, registrationId?: string) {
    if (!registrationId || !requestId) {
      throw new Error("Compute node registration identity is unavailable.");
    }
    return this.tracked(
      requestId,
      registrationId,
      registrationStateArgs("enabled", registrationId, requestId)
    );
  }

  async install(requestId?: string, descriptor?: string) {
    if (!requestId || !descriptor)
      throw new Error("The native registration request and ticket are required.");
    const registrationId = JSON.parse(descriptor).registration_id as string;
    return this.tracked(
      requestId,
      registrationId,
      [...lifecycleArgs("registration-claim", requestId), "--descriptor-stdin"],
      descriptor,
      180_000
    );
  }
  async resume(requestId: string, registrationId?: string) {
    if (!registrationId)
      throw new Error("The registration identity is required to continue its claim.");
    return this.tracked(
      requestId,
      registrationId,
      lifecycleArgs("registration-claim", requestId),
      undefined,
      180_000
    );
  }
  private async tracked(
    requestId: string,
    registrationId: string,
    args: string[],
    stdin?: string,
    timeoutMs?: number
  ) {
    const abort = new AbortController();
    const done = this.run(this.lifecyclePath, args, stdin, timeoutMs, {
      signal: abort.signal,
    });
    const execution = { registrationId, abort, done };
    this.executions.set(requestId, execution);
    try {
      const receipt = parseRequestReceipt(JSON.parse(await done));
      if (!receipt || receipt.targetRegistrationId !== registrationId)
        throw new Error("The native receipt belongs to another Registration.");
      if (receipt.kind !== args[0])
        throw new Error("The native receipt belongs to another action.");
      if (
        receipt.requestId !== requestId &&
        (args[0] !== "registration-recover" ||
          receipt.kind !== "registration-recover" ||
          receipt.correlationRequestId !== requestId)
      )
        throw new Error("The native receipt does not acknowledge this request.");
      return receipt;
    } finally {
      if (this.executions.get(requestId) === execution)
        this.executions.delete(requestId);
    }
  }
  private async stopExecutors(registrationId: string) {
    for (const execution of this.executions.values()) {
      if (execution.registrationId !== registrationId) continue;
      execution.abort.abort();
      // runCommand resolves only after the exact spawned helper exits; it sends TERM then KILL to that helper tree.
      await execution.done.catch(() => undefined);
    }
  }
  async drain(requestId?: string, registrationId?: string) {
    if (!registrationId) {
      throw new Error("Compute node registration identity is unavailable.");
    }
    await this.stopExecutors(registrationId);
    await this.mutate(registrationStateArgs("draining", registrationId, requestId));
  }

  async remove(requestId?: string, registrationId?: string) {
    if (!registrationId)
      throw new Error("Compute node registration identity is unavailable.");
    await this.stopExecutors(registrationId);
    await this.mutate(
      [
        "registration-remove",
        ...COMMA_AGENT_VMM_SERVICE_ARGS,
        "--registration-id",
        registrationId,
        ...(requestId ? ["--request-id", requestId] : []),
      ],
      undefined,
      150_000
    );
  }
  /** `gated`: the operation can conflict with Host maintenance, so it needs the maintenance protocol. */
  private async mutate(
    args: string[],
    stdin?: string,
    timeoutMs?: number,
    gated = false
  ) {
    void gated;
    return stdin === undefined && timeoutMs === undefined
      ? this.run(this.lifecyclePath, args)
      : this.run(this.lifecyclePath, args, stdin, timeoutMs);
  }
}

function parseRequestReceipt(
  value: unknown,
  requestId?: string
): NativeRequestReceipt | undefined {
  if (value === null) return undefined;
  if (!value || typeof value !== "object")
    throw new Error("The native request receipt is unreadable.");
  const receipt = value as Record<string, unknown>;
  const canonical = receipt.requestId ?? receipt.operationId;
  if (
    typeof canonical !== "string" ||
    !canonical ||
    (requestId && canonical !== requestId) ||
    typeof receipt.kind !== "string" ||
    !["pending", "failed", "succeeded", "superseded"].includes(String(receipt.outcome))
  )
    throw new Error("The native request receipt is unreadable.");
  return {
    requestId: canonical,
    kind: receipt.kind,
    outcome: receipt.outcome as NativeRequestReceipt["outcome"],
    ...(typeof receipt.correlationRequestId === "string"
      ? { correlationRequestId: receipt.correlationRequestId }
      : {}),
    ...(typeof receipt.targetRegistrationId === "string"
      ? { targetRegistrationId: receipt.targetRegistrationId }
      : {}),
    retryable: receipt.retryable === true,
    ...(typeof receipt.stage === "string" ? { stage: receipt.stage } : {}),
    ...(typeof receipt.failureCode === "string"
      ? { failureCode: receipt.failureCode }
      : {}),
  };
}

function readHostStartFailure(
  value: unknown
): Pick<ComputeNodeRuntimeObservation, "hostStartFailure"> {
  if (!value || typeof value !== "object") return {};
  const failure = value as Record<string, unknown>;
  if (
    failure.code !== "STATE_SCHEMA_INCOMPATIBLE" &&
    failure.code !== "STATE_MIGRATION_FAILED"
  )
    return {};
  return {
    hostStartFailure: {
      code: failure.code,
      ...(Number.isSafeInteger(failure.dataSchema)
        ? { dataSchema: failure.dataSchema as number }
        : {}),
    },
  };
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
    state === "enabled" ? "registration-enable" : "registration-drain",
    ...COMMA_AGENT_VMM_SERVICE_ARGS,
    "--registration-id",
    registrationId,
    ...(requestId ? ["--request-id", requestId] : []),
  ];
}

/** A refusal belongs to the explicitly queried registration. A successful connection omits it. */
function readRemoteProtocol(
  value: unknown
): Pick<ComputeNodeRuntimeObservation, "remoteProtocol"> {
  if (!value || typeof value !== "object") return {};
  const refusal = value as Record<string, unknown>;
  if (
    typeof refusal.hostProtocol !== "string" ||
    refusal.hostProtocol.length > 128 ||
    !Number.isSafeInteger(refusal.minProtocol) ||
    Number(refusal.minProtocol) < 1 ||
    !Number.isSafeInteger(refusal.maxProtocol) ||
    Number(refusal.maxProtocol) < Number(refusal.minProtocol) ||
    (refusal.hostSide !== "too_old" && refusal.hostSide !== "too_new")
  )
    return {};
  return {
    remoteProtocol: {
      hostProtocol: refusal.hostProtocol,
      minProtocol: Number(refusal.minProtocol),
      maxProtocol: Number(refusal.maxProtocol),
      hostSide: refusal.hostSide,
    },
  };
}
