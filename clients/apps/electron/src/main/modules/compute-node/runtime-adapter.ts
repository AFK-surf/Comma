import { assertMaintenanceCapable } from "./host-maintenance-protocol";
import type { ComputeNodeState } from "@comma/native-bridge";
import { runCommand } from "./command";

const COMMA_AGENT_VMM_SERVICE_ARGS = ["--service-type", "agent"] as const;

export interface ComputeNodeRuntimeObservation {
  connector: ComputeNodeState["observed"]["connector"];
  host: ComputeNodeState["observed"]["host"];
  readability: ComputeNodeState["observed"]["readability"];
  salix: ComputeNodeState["observed"]["salix"];
  registration?: "present" | "absent" | "unreadable";
  registrationState?: "enabled" | "draining" | "revoked";
  reason?:
    | "operator_unavailable"
    | "registration_unreadable"
    | "registration_not_found"
    | "capability_missing";
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
  private lastKnown: ComputeNodeRuntimeObservation = absentObservation;

  constructor(
    private readonly lifecyclePath: string,
    private readonly run = runCommand,
    private readonly requireMaintenanceContract = false
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
      const observed: ComputeNodeRuntimeObservation = {
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
          ...this.lastKnown,
          readability: "unreadable",
          registration: "unreadable",
          reason: "operator_unavailable",
        };
      return { ...this.lastKnown, readability: "unreadable" };
    }
  }

  async repair(requestId?: string) {
    await this.mutate(lifecycleArgs("repair", requestId));
  }

  async enable(requestId?: string, registrationId?: string) {
    if (!registrationId) {
      throw new Error("Compute node registration identity is unavailable.");
    }
    await this.mutate(registrationStateArgs("enabled", registrationId, requestId));
  }

  async install(requestId?: string, descriptor?: string) {
    await this.mutate(
      [
        ...lifecycleArgs("install", requestId),
        ...(descriptor ? ["--operation-stdin"] : []),
      ],
      descriptor,
      180_000
    );
  }
  async resume(operationId: string, _requestId?: string) {
    await this.mutate(
      [...lifecycleArgs("install", operationId), "--resume-operation", operationId],
      undefined,
      180_000
    );
  }
  async drain(requestId?: string, registrationId?: string) {
    if (!registrationId) {
      throw new Error("Compute node registration identity is unavailable.");
    }
    await this.mutate(registrationStateArgs("draining", registrationId, requestId));
  }

  async remove(requestId?: string, registrationId?: string) {
    if (!registrationId)
      throw new Error("Compute node registration identity is unavailable.");
    await this.mutate(
      [
        "registration-revoke",
        ...COMMA_AGENT_VMM_SERVICE_ARGS,
        "--registration-id",
        registrationId,
        ...(requestId ? ["--request-id", requestId] : []),
      ],
      undefined,
      150_000
    );
  }
  private async mutate(args: string[], stdin?: string, timeoutMs?: number) {
    if (this.requireMaintenanceContract)
      await assertMaintenanceCapable(
        this.lifecyclePath,
        this.run,
        COMMA_AGENT_VMM_SERVICE_ARGS
      );
    return stdin === undefined && timeoutMs === undefined
      ? this.run(this.lifecyclePath, args)
      : this.run(this.lifecyclePath, args, stdin, timeoutMs);
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
