import { readIntentFile } from "./intent-file";
import type { LocalComputeOperator } from "./local-operator";
import type { LocalHostMaintenance } from "./host-maintenance";
import { createHash, randomUUID } from "node:crypto";
import { rename } from "node:fs/promises";
import {
  ComputeNodeInstallAuthorization,
  type ComputeRecoveryChallenge,
  type RecoveredComputeBinding,
} from "./install-authorization";
import { join } from "node:path";
import type {
  ComputeNodeConfigureInput,
  ComputeNodeExpectedBinding,
  ComputeNodeState,
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
      candidate: ComputeRecoveryChallenge;
      proof: Awaited<ReturnType<LocalComputeOperator["recoveryProof"]>>;
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
  refresh() {
    return this.call((service) => service.refresh());
  }
  configure(input: ComputeNodeConfigureInput) {
    const generation = this.generation;
    return this.call(async (service) => {
      if (input.desiredEnabled) await this.maintenance?.assertInstallationAllowed();
      if (generation !== this.generation) throw new ComputeNodeSessionChangedError();
      return service.configure(input);
    });
  }
  drain(expected?: ComputeNodeExpectedBinding) {
    return this.call((service) => service.drain(expected));
  }
  abandon(expected: ComputeNodeExpectedBinding) {
    return this.call((service) => service.abandon(expected));
  }
  remove(expected?: ComputeNodeExpectedBinding) {
    return this.call((service) => service.remove(expected));
  }
  repair() {
    const generation = this.generation;
    return this.call(async (service) => {
      await this.maintenance?.assertInstallationAllowed();
      if (generation !== this.generation) throw new ComputeNodeSessionChangedError();
      return service.repair();
    });
  }
  rebuild() {
    const generation = this.generation;
    return this.call(async (service) => {
      await this.maintenance?.assertInstallationAllowed();
      if (generation !== this.generation) throw new ComputeNodeSessionChangedError();
      return service.rebuild();
    });
  }

  hostMaintenanceState() {
    if (!this.maintenance) throw new Error("Local Host maintenance is unavailable.");
    return this.maintenance.state();
  }
  maintainHost(input: import("@comma/native-bridge").HostMaintenanceInput) {
    if (!this.maintenance) throw new Error("Local Host maintenance is unavailable.");
    return this.maintenance.maintain(input);
  }
  resumeHostMaintenance(input: { requestId: string }) {
    if (!this.maintenance) throw new Error("Local Host maintenance is unavailable.");
    return this.maintenance.resume(input.requestId);
  }

  async recoveryCandidates(input: { workspaceId: string; cursor?: string }) {
    const generation = this.generation,
      key = this.key;
    const owner = this.options.installAuthorization;
    const local = this.local;
    if (!key || !local || !(owner instanceof ComputeNodeInstallAuthorization))
      throw new Error("Recovery management is unavailable.");
    const discovery = ++this.discoveryEpoch;
    const current = () => {
      if (
        key !== this.key ||
        generation !== this.generation ||
        discovery !== this.discoveryEpoch
      )
        throw new ComputeNodeSessionChangedError();
    };
    const page = await local.registrationPage(input.cursor);
    current();
    const candidates = await owner.recoveryCandidates(
      input.workspaceId,
      page.registrations.map((row) => row.id)
    );
    current();
    const verified: typeof this.recoveryTargets = new Map();
    const verify = async (candidate: ComputeRecoveryChallenge) => {
      current();
      const [audience, subject] = JSON.parse(key) as [string, string];
      if (
        candidate.challenge.audience !== audience ||
        candidate.challenge.subject !== subject ||
        candidate.challenge.scope_key !== input.workspaceId ||
        candidate.challenge.operation_id !== candidate.operation_id ||
        candidate.challenge.registration_id !== candidate.registration_id ||
        !page.registrations.some((row) => row.id === candidate.registration_id)
      )
        return;
      try {
        const proof = await local.recoveryProof(candidate.challenge);
        current();
        const binding = await owner.recoverBinding(
          input.workspaceId,
          candidate.operation_id,
          proof,
          false
        );
        current();
        if (
          binding.registration_id !== candidate.registration_id ||
          binding.environment_id !== candidate.challenge.environment_id
        )
          return;
        verified.set(randomUUID(), {
          workspaceId: input.workspaceId,
          generation,
          candidate,
          proof,
          binding,
        });
      } catch {
        current(); /* Unverified cloud identities never reach the renderer. */
      }
    };
    // Four bounded proof workers for at most 32 IDs from this user-requested page.
    let index = 0;
    await Promise.all(
      Array.from({ length: Math.min(4, candidates.length) }, async () => {
        while (index < candidates.length) {
          const candidate = candidates[index++];
          if (candidate) await verify(candidate);
        }
      })
    );
    current();
    this.recoveryTargets = verified;
    return {
      confirmationId: generation,
      candidates: [...verified].map(([candidateKey, value]) => ({
        key: candidateKey,
        label: value.binding.id.slice(-8),
      })),
      ...(page.nextCursor ? { nextCursor: page.nextCursor } : {}),
    };
  }

  async recover(input: { key: string; confirmationId: string }) {
    const target = this.recoveryTargets.get(input.key),
      generation = this.generation,
      key = this.key;
    const owner = this.options.installAuthorization;
    if (
      !target ||
      !key ||
      target.generation !== generation ||
      input.confirmationId !== generation ||
      !(owner instanceof ComputeNodeInstallAuthorization)
    )
      throw new ComputeNodeSessionChangedError();
    // Open the original account owner before the cloud effect. A late accepted result is saved only there.
    await this.call(async (service) => service.state());
    const service = await this.services.get(key)!;
    if (this.generation !== generation || this.key !== key)
      throw new ComputeNodeSessionChangedError();
    const result = await service.recoverBinding(target.binding, () =>
      owner.recoverBinding(
        target.workspaceId,
        target.candidate.operation_id,
        target.proof,
        true
      )
    );
    const binding = target.binding;
    // Migrate only the exact unscoped record whose original subject/scope and Host have now been proved.
    try {
      const legacy = JSON.parse(await readIntentFile(this.options.filePath)) as {
        installOperationId?: string;
        workspaceId?: string;
        registrationId?: string;
      };
      if (
        legacy.installOperationId === binding.id &&
        legacy.workspaceId === binding.scope_key &&
        (!legacy.registrationId || legacy.registrationId === binding.registration_id)
      ) {
        await rename(this.options.filePath, `${this.options.filePath}.migrated`);
      }
    } catch {
      /* An unreadable or unrelated legacy record remains unowned and unchanged. */
    }
    if (this.generation !== generation || this.key !== key)
      throw new ComputeNodeSessionChangedError();
    this.recoveryTargets.clear();
    return result;
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
      })),
      ...(result.next_cursor ? { nextCursor: result.next_cursor } : {}),
    };
  }
  disposeLocal(input: { key: string }) {
    if (!this.local) throw new Error("Local Host management is unavailable.");
    return this.local.dispose(input);
  }
  resumeLocalDisposal(input: { requestId: string }) {
    if (!this.local) throw new Error("Local Host management is unavailable.");
    return this.local.resume(input.requestId);
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
