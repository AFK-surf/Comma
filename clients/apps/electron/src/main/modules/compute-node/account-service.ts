import { NativeOperationError } from "../ipc/operation-error";
import { ComputeNodeCommandError } from "./command";
import type { LocalComputeOperator } from "./local-operator";
import type { LocalHostMaintenance } from "./host-maintenance";
import { createHash, randomUUID } from "node:crypto";
import {
  ComputeNodeInstallAuthorization,
  type RecoveredComputeBinding,
} from "./install-authorization";
import { join } from "node:path";
import type {
  ComputeNodeConfigureInput,
  ComputeNodeExpectedBinding,
  ComputeNodeState,
  HostMaintenanceState,
} from "@comma/native-bridge";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";
import { canonicalizeSessionAudience } from "../session/credential";
import {
  ComputeNodeService,
  ComputeNodeSessionChangedError,
  type ComputeNodeServiceOptions,
} from "./index";

/** Account intent belongs to an audience and subject. Session changes only fence commands and projections. */
export class AccountComputeNodeService {
  private readonly services = new Map<string, Promise<ComputeNodeService>>();
  private key: string | undefined;
  private sessionIdentity?: string;
  private generation = randomUUID();
  private snapshot: ComputeNodeState;
  /** The maintenance request whose success the node already took in. */
  private settledMaintenanceId: string | undefined;
  /** Captured before a destructive reset+reinstall so the node automatically rebinds and returns to ready. */
  private pendingResetRebind:
    | { key: string; workspaceId: string; wasEnabled: boolean }
    | undefined;
  /** Last (installed -> selected) release pair attempted by silent auto-update, to prevent retry loops. */
  private autoUpdateKey: string | undefined;
  private autoUpdateInFlight = false;
  private discoveryEpoch = 0;
  private cloudTargets = new Map<
    string,
    {
      target: import("./install-authorization").LocalWorkloadTarget;
      generation: string;
      workspaceId: string;
    }
  >();
  private recoveryTargets = new Map<
    string,
    {
      workspaceId: string;
      generation: string;
      registrationId: string;
      binding: RecoveredComputeBinding;
    }
  >();

  constructor(
    private readonly options: ComputeNodeServiceOptions,
    session: SessionLifecycleSnapshot,
    private readonly local?: LocalComputeOperator,
    private readonly maintenance?: LocalHostMaintenance
  ) {
    this.snapshot = this.emptyState();
    this.sessionChanged(session);
    // Main's own Host reset deleted the local registrations: mark all loaded accounts so rebind is authorized.
    this.maintenance?.onHostReset((): void => {
      const activeKey = this.key;
      for (const [serviceKey, pending] of this.services) {
        void pending
          .then(async (service) => {
            if (serviceKey === activeKey && this.key === activeKey)
              await service.hostDataReset();
            else await service.markHostDataReset();
          })
          .catch(() => undefined);
      }
    });
    // A request that succeeds on a background retry shows on the node as a first-try success does.
    this.maintenance?.onSettled((state): void => {
      this.afterMaintenance(state);
    });
    // Main's own pending Host maintenance continues, or a stuck one recovers, after a restart, signed in or not.
    void this.maintenance
      ?.continuePending(() => this.workActive())
      .catch(() => undefined);
  }

  sessionChanged(session: SessionLifecycleSnapshot) {
    const key =
      session.phase === "signed_in"
        ? JSON.stringify([
            canonicalizeSessionAudience(session.session.audience),
            session.principal.userId,
          ])
        : undefined;
    const identity = JSON.stringify([
      key,
      session.authority.authorityInstanceId,
      session.generation,
      session.phase === "signed_in" ? session.session.sessionId : null,
    ]);
    if (identity === this.sessionIdentity) return;
    this.sessionIdentity = identity;
    this.key = key;
    this.pendingResetRebind = undefined;
    this.autoUpdateKey = undefined;
    this.recoveryTargets.clear();
    this.cloudTargets.clear();
    this.discoveryEpoch++;
    this.generation = randomUUID();
    this.snapshot = this.emptyState();
    this.options.onStateChanged?.(this.state());
    if (key) void this.refresh().catch(() => undefined);
  }

  state() {
    return structuredClone(this.snapshot);
  }
  async refresh() {
    const result = await this.call((service) => service.refresh());
    void this.maybeAutoUpdate();
    return result;
  }
  reauthorize(expected: ComputeNodeExpectedBinding) {
    return this.call((service) => service.reauthorize(expected));
  }
  continue() {
    return this.call((service) => service.continue());
  }
  configure(input: ComputeNodeConfigureInput) {
    if (!input.desiredEnabled) this.pendingResetRebind = undefined;
    const generation = this.generation;
    return this.call(async (service) => {
      // The service checks local Host maintenance itself, so continuation can update an idle Host.
      try {
        return await service.configure(input);
      } catch (error) {
        if (generation !== this.generation) throw new ComputeNodeSessionChangedError();
        if (error instanceof ComputeNodeCommandError) {
          const connectionFailed =
            ["install-managed", "register"].includes(error.native?.reason ?? "") &&
            service.state().observed.host === "ready";
          throw new NativeOperationError(
            error.native?.code === "cloud_unavailable"
              ? "The workspace service could not be reached. Check its status before continuing the same setup."
              : connectionFailed
                ? "The local workspace connection could not finish. Check the connection before continuing the same setup."
                : error.reason === "outcome_unknown"
                  ? "Compute setup result is unknown. Check its status before continuing the same setup."
                  : "Compute setup could not finish. Continue the same setup after checking the connection and local components.",
            error.native?.code === "cloud_unavailable"
              ? "COMPUTE_CLOUD_UNAVAILABLE"
              : connectionFailed
                ? "COMPUTE_CONNECTION_FAILED"
                : error.reason === "outcome_unknown"
                  ? "COMPUTE_SETUP_UNKNOWN"
                  : "COMPUTE_SETUP_FAILED"
          );
        }
        throw error;
      }
    });
  }
  drain(expected?: ComputeNodeExpectedBinding) {
    this.pendingResetRebind = undefined;
    return this.call((service) => service.drain(expected));
  }
  remove(expected?: ComputeNodeExpectedBinding) {
    this.pendingResetRebind = undefined;
    return this.call((service) => service.remove(expected));
  }
  /** The server reports running work for the current account's node. */
  private workActive() {
    return this.snapshot.facets.workActivity === "active";
  }
  /** The network came back: the current account's continuation runs its next step now. */
  networkRecovered() {
    const key = this.key;
    if (!key) return;
    void this.services
      .get(key)
      ?.then((service) => {
        if (this.key === key) service.networkRecovered();
      })
      .catch(() => undefined);
  }

  async hostMaintenanceState() {
    if (!this.maintenance) throw new Error("Local Host maintenance is unavailable.");
    const state = await this.maintenance.state();
    void this.maybeAutoUpdate(state);
    return state;
  }
  async maintainHost(input: import("@comma/native-bridge").HostMaintenanceInput) {
    if (!this.maintenance) throw new Error("Local Host maintenance is unavailable.");
    if (input.action === "reinstall" && input.dataPolicy === "reset" && this.key) {
      const current =
        (await this.services
          .get(this.key)
          ?.then((service) => service.state())
          .catch(() => this.snapshot)) ?? this.snapshot;
      this.pendingResetRebind =
        current.desiredEnabled && current.bindingWorkspaceId
          ? {
              key: this.key,
              workspaceId: current.bindingWorkspaceId,
              wasEnabled: true,
            }
          : undefined;
    } else if (input.action === "uninstall") {
      this.pendingResetRebind = undefined;
    }
    try {
      const state = await this.maintenance.maintain(input);
      if (state.operation?.outcome === "failed") {
        this.pendingResetRebind = undefined;
      }
      return this.afterMaintenance(state);
    } catch (error) {
      this.pendingResetRebind = undefined;
      throw error;
    }
  }
  async resumeHostMaintenance(input: { requestId: string }) {
    if (!this.maintenance) throw new Error("Local Host maintenance is unavailable.");
    return this.afterMaintenance(
      await this.maintenance.resume(input.requestId, () => this.workActive())
    );
  }
  /**
   * Silently updates an installed Host in the background when the node is enabled, idle, and has no
   * running or failed maintenance operation. Deduplicated per (installed, selected) release pair.
   */
  private async maybeAutoUpdate(knownState?: HostMaintenanceState) {
    if (!this.key || !this.maintenance || this.autoUpdateInFlight) return;
    if (this.workActive() || !this.snapshot.desiredEnabled) return;
    const maintenanceState =
      knownState ?? (await this.maintenance.state().catch(() => undefined));
    if (
      !maintenanceState ||
      maintenanceState.installation !== "installed" ||
      !maintenanceState.updateAvailable
    )
      return;
    if (
      maintenanceState.operation &&
      maintenanceState.operation.outcome !== "succeeded"
    )
      return;
    if (!this.key || this.workActive() || !this.snapshot.desiredEnabled) return;
    const pair = `${maintenanceState.installedReleaseId ?? ""}->${maintenanceState.selectedReleaseId ?? ""}`;
    if (this.autoUpdateKey === pair) return;
    this.autoUpdateKey = pair;
    this.autoUpdateInFlight = true;
    try {
      const next = await this.maintenance.automaticUpdate();
      this.afterMaintenance(next);
    } catch {
      // Failure stays visible on the maintenance state with a clear retry entry.
    } finally {
      this.autoUpdateInFlight = false;
    }
  }
  /**
   * A reinstall or update, first try, continued or retried in the background, resumes the node's setup.
   * A reset reinstall automatically re-enables the previous workspace binding so the node returns to ready.
   * An uninstall shows on the node at once. Each request is taken in once.
   */
  private afterMaintenance(state: HostMaintenanceState) {
    if (state.operation?.outcome !== "succeeded" || !this.key) return state;
    if (this.settledMaintenanceId === state.operation.requestId) return state;
    this.settledMaintenanceId = state.operation.requestId;
    if (
      state.operation.action === "reinstall" &&
      state.operation.dataPolicy === "reset"
    ) {
      const rebind = this.pendingResetRebind;
      this.pendingResetRebind = undefined;
      if (
        rebind &&
        rebind.key === this.key &&
        rebind.wasEnabled &&
        rebind.workspaceId
      ) {
        void this.call((service) =>
          service.rebindAfterHostReset(rebind.workspaceId)
        ).catch(() => undefined);
      } else {
        void this.call((service) => service.hostReinstalled()).catch(() => undefined);
      }
    } else if (
      state.operation.action === "reinstall" ||
      state.operation.action === "update"
    )
      void this.call((service) => service.hostReinstalled()).catch(() => undefined);
    else if (state.operation.action === "uninstall")
      void this.call((service) =>
        service.hostUninstalled(state.operation?.dataPolicy === "reset")
      ).catch(() => undefined);
    return state;
  }

  async recoveryCandidates(input: { workspaceId: string; cursor?: string }) {
    const generation = this.generation,
      owner = this.options.installAuthorization;
    if (!this.key || !this.local || !(owner instanceof ComputeNodeInstallAuthorization))
      throw new Error("Recovery is unavailable.");
    const page = await this.local.registrationPage(input.cursor);
    const candidates = await owner.recoveryCandidates(
      input.workspaceId,
      page.registrations.map((row) => row.id)
    );
    if (generation !== this.generation) throw new ComputeNodeSessionChangedError();
    this.recoveryTargets.clear();
    for (const binding of candidates) {
      if (!page.registrations.some((row) => row.id === binding.id)) continue;
      this.recoveryTargets.set(randomUUID(), {
        workspaceId: input.workspaceId,
        generation,
        registrationId: binding.id,
        binding,
      });
    }
    return {
      confirmationId: generation,
      candidates: [...this.recoveryTargets].map(([key, row]) => ({
        key,
        label: row.registrationId.slice(-8),
        workspaceId: row.workspaceId,
      })),
      ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
    };
  }
  async recover(input: { key: string; confirmationId: string }) {
    const target = this.recoveryTargets.get(input.key),
      generation = this.generation;
    const owner = this.options.installAuthorization;
    if (
      !target ||
      target.generation !== generation ||
      input.confirmationId !== generation ||
      !(owner instanceof ComputeNodeInstallAuthorization)
    )
      throw new ComputeNodeSessionChangedError();
    return this.call((service) => service.recoverBinding(target.binding));
  }

  async localOverview(input: { cursor?: string; workspaceId?: string }) {
    const generation = this.generation,
      key = this.key,
      local = this.local,
      owner = this.options.installAuthorization;
    const overview = (await local?.overview(input)) ?? {
      availability: "unavailable" as const,
      environments: [],
    };
    this.cloudTargets.clear();
    if (
      !input.workspaceId ||
      !key ||
      !local ||
      !(owner instanceof ComputeNodeInstallAuthorization) ||
      overview.availability !== "available"
    )
      return overview;
    const targets = overview.environments.flatMap((row) => {
      const target = local.workloadTarget(row.key);
      return target ? [{ key: row.key, target }] : [];
    });
    if (targets.length === 0) return overview;
    try {
      if (this.generation !== generation || this.key !== key)
        return {
          ...overview,
          environments: overview.environments.map((row) => ({
            ...row,
            canReadWorkloads: false,
            canOperate: false,
          })),
        };
      const mappings = await owner.localMappings(
        input.workspaceId,
        targets.map((row) => row.target)
      );
      if (this.generation !== generation || this.key !== key)
        throw new ComputeNodeSessionChangedError();
      for (const row of targets) {
        if (
          local.workloadTarget(row.key) === row.target &&
          mappings.some(
            (mapping) =>
              mapping.can_read &&
              mapping.registration_id === row.target.registration_id &&
              mapping.allocation_id === row.target.allocation_id &&
              mapping.generation === row.target.generation
          )
        ) {
          this.cloudTargets.set(row.key, {
            target: row.target,
            generation,
            workspaceId: input.workspaceId,
          });
        }
      }
      return {
        ...overview,
        environments: overview.environments.map((row) => ({
          ...row,
          canReadWorkloads: this.cloudTargets.has(row.key),
          canOperate: false,
        })),
      };
    } catch {
      return overview;
    }
  }

  async localWorkloads(input: { key: string; cursor?: string }) {
    const mapping = this.cloudTargets.get(input.key),
      owner = this.options.installAuthorization;
    if (
      !mapping ||
      mapping.generation !== this.generation ||
      this.local?.workloadTarget(input.key) !== mapping.target ||
      !(owner instanceof ComputeNodeInstallAuthorization)
    )
      throw new ComputeNodeSessionChangedError();
    const result = await owner.localWorkloads(
      mapping.workspaceId,
      mapping.target,
      input.cursor
    );
    if (
      this.cloudTargets.get(input.key) !== mapping ||
      mapping.generation !== this.generation ||
      this.local?.workloadTarget(input.key) !== mapping.target
    )
      throw new ComputeNodeSessionChangedError();
    return {
      workloads: result.workloads.map((row) => ({
        label: `${row.kind} ${row.id.slice(-8)}`,
        state: row.phase ?? "unknown",
        ...(row.location?.device_id ? { deviceId: row.location.device_id } : {}),
        ...(row.problem ? { problem: row.problem } : {}),
      })),
      ...(result.next_cursor ? { nextCursor: result.next_cursor } : {}),
    };
  }
  async disposeLocal(input: { key: string }) {
    if (!this.local) throw new Error("Local Host management is unavailable.");
    try {
      return await this.local.dispose(input);
    } finally {
      await this.refresh().catch(() => undefined);
    }
  }
  async resumeLocalDisposal(input: { requestId: string }) {
    if (!this.local) throw new Error("Local Host management is unavailable.");
    try {
      return await this.local.resume(input.requestId);
    } finally {
      await this.refresh().catch(() => undefined);
    }
  }

  private emptyState(): ComputeNodeState {
    const eligible =
      (this.options.platform ?? process.platform) === "darwin" &&
      (this.options.arch ?? process.arch) === "arm64";
    return {
      desiredEnabled: false,
      eligibility: { eligible },
      revision: 1,
      confirmationId: this.generation,
      observationFresh: false,
      status: eligible ? "not_set" : "action_required",
      observed: {
        host: "absent",
        connector: "absent",
        readability: "unreadable",
        salix: "unregistered",
      },
      facets: {
        admission: "closed",
        connection: "disconnected",
        installationHealth: "absent",
        runtimeReadiness: "unavailable",
        workActivity: "unknown",
      },
    };
  }

  private async call(
    action: (service: ComputeNodeService) => Promise<ComputeNodeState>
  ) {
    const key = this.key;
    if (!key) throw new Error("Sign in before managing a workspace compute node.");
    const generation = this.generation;
    let pending = this.services.get(key);
    if (!pending) {
      // The old unscoped file remains unowned until the original subject can be proved.
      // The digest bounds filename length. It addresses storage; the owner body must also match.
      // It does not verify identity, authorization, or file integrity.
      pending = ComputeNodeService.open({
        ...this.options,
        ...(this.maintenance
          ? {
              updateHost: () => this.maintenance!.automaticUpdate(),
              reinstallHost: (explicit: boolean, requireCurrent: () => void) =>
                this.maintenance!.prepareForSetup(explicit, requireCurrent),
              hostInstallation: async () =>
                (await this.maintenance!.state()).installation,
            }
          : {}),
        filePath: join(
          `${this.options.filePath}.accounts`,
          `${createHash("sha256").update(key).digest("hex")}.json`
        ),
        accountOwner: {
          audience: JSON.parse(key)[0] as string,
          subject: JSON.parse(key)[1] as string,
        },
        authorityGeneration: () => (this.key === key ? this.generation : undefined),
        onStateChanged: (state) => {
          if (this.key !== key) return;
          this.snapshot = state;
          this.options.onStateChanged?.(this.state());
          if (state.desiredEnabled) void this.maybeAutoUpdate();
        },
      });
      this.services.set(key, pending);
      void pending.catch(() => {
        if (this.services.get(key) === pending) this.services.delete(key);
      });
    }
    const service = await pending;
    if (this.key !== key || this.generation !== generation)
      throw new ComputeNodeSessionChangedError();
    const result = await action(service);
    if (this.key !== key || this.generation !== generation)
      throw new ComputeNodeSessionChangedError();
    return result;
  }
}
