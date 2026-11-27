import { AsyncLocalStorage } from "node:async_hooks";
import { randomUUID } from "node:crypto";
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { z } from "zod";
import {
  computeNodeStateSchema,
  type ComputeNodeConfigureInput,
  type ComputeNodeExpectedBinding,
  type ComputeNodeProblem,
  type ComputeNodeState,
  type HostMaintenanceState,
} from "@comma/native-bridge";
import { realMainClock, type MainClock } from "../../clock";
import { readIntentFile } from "./intent-file";
import { ComputeNodeCommandError } from "./command";
import {
  absentObservation,
  type ComputeNodeRuntimeAdapter,
  type ComputeNodeRuntimeObservation,
  type NativeRequestReceipt,
} from "./runtime-adapter";
import type { HostPreparation } from "./host-preparation";
import { HostMaintenanceIncompatibleError } from "./host-maintenance-protocol";
import {
  ComputeNodeAuthorizationNotFoundError,
  ComputeNodeTicketNotRetryableError,
  type ComputeNodeInstallAuthorizationOwner,
  type RecoveredComputeBinding,
} from "./install-authorization";
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
export {
  ComputeNodeInstallAuthorization,
  type ComputeNodeInstallAuthorizationOwner,
} from "./install-authorization";

export class ComputeNodeSessionChangedError extends Error {
  constructor() {
    super("The compute node session changed. Review the current node.");
  }
}
class ComputeNodeBindingChangedError extends Error {}
class ComputeRequestSupersededError extends Error {}
export type ComputeNodeWorkActivity = "idle" | "active" | "unknown";
type Kind = "configure" | "drain" | "remove" | "repair" | "rebuild" | "recover";
const id = z.string().min(1).max(200);
const intentSchema = z.object({
  version: z.number().int().positive(),
  desiredEnabled: z.boolean(),
  registrationId: id.optional(),
  workspaceId: id.optional(),
  authorizationRequestId: id.optional(),
  boundDeviceId: id.optional(),
  resetPendingRebind: z.boolean().optional(),
  request: z
    .object({
      requestId: id,
      kind: z.enum(["configure", "drain", "remove", "repair", "rebuild", "recover"]),
    })
    .optional(),
  continuation: z.object({ deadlineAt: z.number().int().nonnegative() }).optional(),
  revision: z.number().int().positive(),
  accountOwner: z.object({ audience: z.string(), subject: id }).optional(),
});
type Intent = z.infer<typeof intentSchema>;
const INTENT_VERSION = 5;
const WINDOW_MS = 45 * 60_000;
const HARD_BLOCKED_PROBLEMS = new Set<ComputeNodeProblem>([
  "insufficient_disk",
  "comma_update_required",
  "service_update_required",
  "target_older_than_data",
  "local_data_migration",
  "registration_revoked",
  "host_uninstalled",
  "authorization_attention",
  "request_blocked",
  "intent_unreadable",
]);

export interface ComputeNodeServiceOptions {
  adapter: ComputeNodeRuntimeAdapter;
  preparation?: HostPreparation;
  log?: (line: string) => void;
  clock?: MainClock;
  updateHost?: () => Promise<unknown>;
  reinstallHost?: (
    explicit: boolean,
    requireCurrent: () => void
  ) => Promise<HostMaintenanceState | undefined>;
  /** Whether the Agent VMM Host is installed, read only when its lifecycle helper is missing. */
  hostInstallation?: () => Promise<HostMaintenanceState["installation"]>;
  filePath: string;
  onStateChanged?: (state: ComputeNodeState) => void;
  installAuthorization?: ComputeNodeInstallAuthorizationOwner;
  platform?: NodeJS.Platform;
  arch?: string;
  authorityGeneration?: () => string | undefined;
  accountOwner?: { audience: string; subject: string };
}

/** Main owns intent and bounded scheduling. Native receipts own every accepted local result. */
export class ComputeNodeService {
  private intent: Intent = {
    version: INTENT_VERSION,
    desiredEnabled: false,
    revision: 1,
  };
  private snapshot: ComputeNodeState;
  private readable = true;
  private readOnly = false;
  private tail: Promise<unknown> = Promise.resolve();
  private readonly authority = new AsyncLocalStorage<string | undefined>();
  private readonly clock: MainClock;
  private timer:
    | { cancel: () => void; run: () => Promise<ComputeNodeState> }
    | undefined;
  private backoff = 0;
  private receipt: NativeRequestReceipt | undefined;
  private receiptUnreadable = false;
  /** The person uninstalled the Host: its helper and app are gone, and saved intent waits for a reinstall. */
  private hostAbsent = false;
  private problem: ComputeNodeProblem | undefined;
  private detail: string | undefined;
  private remoteHostBound: boolean | undefined;
  private remoteStatus: ComputeNodeState["status"] | undefined;
  private identityMismatch = false;
  private confirmedLocalReset = false;
  private workActivity: ComputeNodeWorkActivity = "unknown";
  private preparingRequest: NonNullable<Intent["request"]> | undefined;
  private refreshPromise: Promise<ComputeNodeState> | undefined;

  private constructor(private readonly options: ComputeNodeServiceOptions) {
    this.clock = options.clock ?? realMainClock;
    const eligible =
      (options.platform ?? process.platform) === "darwin" &&
      (options.arch ?? process.arch) === "arm64";
    this.snapshot = computeNodeStateSchema.parse({
      desiredEnabled: false,
      revision: 1,
      status: eligible ? "not_set" : "action_required",
      eligibility: {
        eligible,
        ...(!eligible ? { reason: "Compute node requires Apple silicon macOS." } : {}),
      },
      observed: absentObservation,
      facets: facetsFor("not_set", absentObservation),
    });
  }
  static async open(options: ComputeNodeServiceOptions) {
    const service = new ComputeNodeService(options);
    try {
      const raw = JSON.parse(await readIntentFile(options.filePath));
      service.intent = intentSchema.parse(raw);
      service.readOnly = service.intent.version > INTENT_VERSION;
      // One bounded migration retains native request and Registration identity, discarding Main's old verdicts.
      if (!service.intent.request && raw.operation?.requestId)
        service.intent.request = {
          requestId:
            raw.operation.kind === "configure"
              ? (raw.installOperationId ?? raw.operation.requestId)
              : raw.operation.requestId,
          kind: raw.operation.kind,
        };
      if (
        options.accountOwner &&
        raw.accountOwner &&
        JSON.stringify(raw.accountOwner) !== JSON.stringify(options.accountOwner)
      )
        throw new Error("Compute intent belongs to another account.");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") service.readable = false;
    }
    if (options.accountOwner) service.intent.accountOwner = options.accountOwner;
    const hadPendingConfigure =
      service.intent.desiredEnabled && service.intent.request?.kind === "configure";
    void service
      .run(async () => {
        const state = await service.observe(service.receipt?.outcome === "succeeded");
        if (hadPendingConfigure && service.canAutoContinue(state)) {
          return service.continueLocked(false);
        }
        return state;
      })
      .catch(() => undefined);
    return service;
  }
  state() {
    return structuredClone(this.snapshot);
  }
  refresh() {
    if (this.refreshPromise) return this.refreshPromise;
    const next = this.run(() => this.observe(this.receipt?.outcome === "succeeded"));
    this.refreshPromise = next;
    void next
      .finally(() => {
        this.refreshPromise = undefined;
      })
      .catch(() => undefined);
    return next;
  }
  configure(input: ComputeNodeConfigureInput) {
    if (!input.desiredEnabled) return this.drain();
    return this.run(async () => {
      this.requireMutable();
      if (!input.workspaceId)
        throw new Error("Select a workspace before enabling this compute node.");
      if (this.snapshot.status === "removed") {
        delete this.intent.registrationId;
        delete this.intent.workspaceId;
        delete this.intent.authorizationRequestId;
        delete this.intent.boundDeviceId;
        delete this.intent.resetPendingRebind;
      }
      if (this.intent.workspaceId && this.intent.workspaceId !== input.workspaceId)
        throw new Error("Remove the existing connection before changing workspace.");
      if (!this.snapshot.eligibility.eligible)
        throw new Error(this.snapshot.eligibility.reason);
      this.intent.workspaceId = input.workspaceId;
      this.intent.desiredEnabled = true;
      const previous = this.intent.request;
      await this.start("configure");
      return this.execute(true, previous !== this.intent.request);
    });
  }
  reauthorize(expected: ComputeNodeExpectedBinding) {
    return this.run(async () => {
      this.requireMutable();
      this.requireBinding(expected);
      await this.start("recover");
      return this.execute(true);
    });
  }
  /** Continue exactly the saved action; a failed remove can never become an enable. */
  continue() {
    return this.run(
      () => this.continueLocked(true),
      this.intent.request?.kind === "remove" || this.intent.request?.kind === "drain"
    );
  }
  private canAutoContinue(state: ComputeNodeState) {
    if (!this.readable || this.readOnly) return false;
    if (!this.intent.desiredEnabled) return false;
    if (this.intent.request?.kind !== "configure") return false;
    if (this.confirmedLocalReset) return false;
    if (state.status !== "action_required") return false;
    if (state.problem !== "continuation_paused") return false;
    if (state.problem && HARD_BLOCKED_PROBLEMS.has(state.problem)) return false;
    if (this.receipt?.outcome === "failed" && !this.receipt.retryable) return false;
    return true;
  }
  private async continueLocked(explicit: boolean): Promise<ComputeNodeState> {
    this.requireMutable();
    if (!this.intent.request || this.problem === "request_blocked")
      return this.observe(true);
    this.intent.continuation = { deadlineAt: this.clock.now() + WINDOW_MS };
    this.backoff = 0;
    await this.save();
    return this.receipt?.outcome === "succeeded" &&
      ["configure", "recover"].includes(this.intent.request.kind)
      ? this.observe(true)
      : this.execute(explicit);
  }
  drain(expected?: ComputeNodeExpectedBinding) {
    return this.run(async () => {
      this.requireMutable();
      this.requireBinding(expected);
      this.intent.desiredEnabled = false;
      await this.start("drain");
      return this.execute(true);
    }, true);
  }
  remove(expected?: ComputeNodeExpectedBinding) {
    return this.run(async () => {
      this.requireMutable();
      this.requireBinding(expected);
      this.intent.desiredEnabled = false;
      await this.start("remove");
      return this.execute(true);
    }, true);
  }
  hostDataReset() {
    return this.run(async () => {
      if (this.readable && !this.readOnly && this.intent.registrationId) {
        this.intent.resetPendingRebind = true;
        if (
          this.intent.desiredEnabled &&
          this.intent.request?.kind !== "remove" &&
          this.intent.request?.kind !== "drain"
        ) {
          this.cancelTimer();
          this.intent.request = { requestId: randomUUID(), kind: "configure" };
          delete this.intent.continuation;
          this.receipt = undefined;
          this.receiptUnreadable = false;
          this.problem = undefined;
          this.detail = undefined;
        }
        await this.save();
      }
      return this.observe(this.receipt?.outcome === "succeeded");
    });
  }
  /** Marks a loaded non-active account's saved binding for rebind after a shared Host data reset. */
  markHostDataReset() {
    const next = this.tail.then(
      async () => {
        if (this.readable && !this.readOnly && this.intent.registrationId) {
          let changed = false;
          if (!this.intent.resetPendingRebind) {
            this.intent.resetPendingRebind = true;
            changed = true;
          }
          if (
            this.intent.desiredEnabled &&
            this.intent.request?.kind !== "remove" &&
            this.intent.request?.kind !== "drain"
          ) {
            this.cancelTimer();
            this.intent.request = { requestId: randomUUID(), kind: "configure" };
            delete this.intent.continuation;
            this.receipt = undefined;
            this.receiptUnreadable = false;
            this.problem = undefined;
            this.detail = undefined;
            changed = true;
          }
          if (changed) await this.save(false);
        }
      },
      async () => undefined
    );
    this.tail = next.catch(() => undefined);
    return next;
  }
  hostReinstalled() {
    return this.run(async () => {
      const state = await this.observe(this.receipt?.outcome === "succeeded");
      if (
        this.readable &&
        !this.readOnly &&
        this.intent.desiredEnabled &&
        this.intent.workspaceId &&
        (this.intent.resetPendingRebind ||
          (!this.intent.registrationId && this.intent.request?.kind === "configure"))
      ) {
        const previous = this.intent.request;
        await this.start("configure");
        return this.execute(true, previous !== this.intent.request, true);
      }
      if (this.canAutoContinue(state)) {
        return this.continueLocked(false);
      }
      return state;
    });
  }
  /** Atomically marks the previous binding reset and re-enables the workspace after a Host reset+reinstall. */
  rebindAfterHostReset(workspaceId: string) {
    return this.run(async () => {
      this.requireMutable();
      if (this.intent.registrationId) this.intent.resetPendingRebind = true;
      if (this.snapshot.status === "removed") {
        delete this.intent.registrationId;
        delete this.intent.workspaceId;
        delete this.intent.authorizationRequestId;
        delete this.intent.boundDeviceId;
        delete this.intent.resetPendingRebind;
      }
      if (this.intent.workspaceId && this.intent.workspaceId !== workspaceId)
        throw new Error("Remove the existing connection before changing workspace.");
      if (!this.snapshot.eligibility.eligible)
        throw new Error(this.snapshot.eligibility.reason);
      this.intent.workspaceId = workspaceId;
      this.intent.desiredEnabled = true;
      const previous = this.intent.request;
      await this.start("configure");
      return this.execute(true, previous !== this.intent.request, true);
    });
  }
  hostUninstalled(reset = false) {
    if (!reset) return this.refresh();
    return this.run(async () => {
      if (
        this.readable &&
        !this.readOnly &&
        this.intent.registrationId &&
        this.intent.workspaceId &&
        this.options.installAuthorization
      ) {
        let revoked = false;
        try {
          const status = await this.options.installAuthorization.revoke({
            workspaceId: this.intent.workspaceId,
            registrationId: this.intent.registrationId,
          });
          revoked = status === "removed";
        } catch (error) {
          revoked = error instanceof ComputeNodeAuthorizationNotFoundError;
        }
        this.requireAuthority();
        if (revoked) {
          delete this.intent.registrationId;
          delete this.intent.resetPendingRebind;
          delete this.intent.boundDeviceId;
          delete this.intent.continuation;
          if (this.intent.desiredEnabled && this.intent.workspaceId) {
            const nextId = randomUUID();
            this.intent.authorizationRequestId = nextId;
            this.intent.request = { requestId: nextId, kind: "configure" };
          } else {
            delete this.intent.workspaceId;
            delete this.intent.authorizationRequestId;
            delete this.intent.request;
          }
          this.receipt = undefined;
          this.receiptUnreadable = false;
          this.problem = undefined;
          this.detail = undefined;
          await this.save();
        } else {
          this.intent.resetPendingRebind = true;
          if (
            this.intent.desiredEnabled &&
            this.intent.request?.kind !== "remove" &&
            this.intent.request?.kind !== "drain"
          ) {
            this.cancelTimer();
            this.intent.request = { requestId: randomUUID(), kind: "configure" };
            delete this.intent.continuation;
            this.receipt = undefined;
            this.receiptUnreadable = false;
            this.problem = undefined;
            this.detail = undefined;
          }
          await this.save();
        }
      }
      return this.observe(this.receipt?.outcome === "succeeded");
    });
  }
  networkRecovered() {
    if (this.timer) this.schedule(0, this.timer.run);
  }

  recoverBinding(expected: RecoveredComputeBinding) {
    return this.run(async () => {
      this.requireMutable();
      if (this.intent.registrationId && this.intent.registrationId !== expected.id)
        throw new Error(
          "Remove the current connection before selecting another Registration."
        );
      this.intent.registrationId = expected.id;
      this.intent.workspaceId = expected.owner_id;
      this.intent.desiredEnabled = expected.status !== "stopped";
      await this.start("recover");
      return this.execute(true);
    });
  }
  private async start(kind: Kind) {
    this.cancelTimer();
    // Explicit continuation keeps the original request. A different action creates a new native request.
    if (
      this.intent.request?.kind !== kind ||
      this.receipt?.outcome === "succeeded" ||
      this.receipt?.outcome === "superseded" ||
      (kind === "configure" &&
        this.receipt?.outcome === "failed" &&
        !this.receipt.retryable)
    ) {
      this.intent.request = { requestId: randomUUID(), kind };
      this.receipt = undefined;
      this.receiptUnreadable = false;
    }
    if (kind === "configure" && !this.intent.registrationId)
      this.intent.authorizationRequestId = this.intent.request.requestId;
    this.intent.continuation = { deadlineAt: this.clock.now() + WINDOW_MS };
    this.backoff = 0;
    this.problem = undefined;
    this.detail = undefined;
    this.hostAbsent = false;
    await this.save();
    this.publish("processing", this.snapshot.observed);
  }
  private async execute(
    explicit = false,
    fresh = false,
    localResetConfirmed = false
  ): Promise<ComputeNodeState> {
    const request = this.intent.request;
    if (!request) return this.observe();
    const owner = this.options.installAuthorization;
    const cancelingUnsubmittedPreparation =
      this.preparingRequest?.requestId === this.intent.authorizationRequestId &&
      this.preparingRequest !== undefined;
    const target = () => {
      if (!owner || !this.intent.workspaceId || !this.intent.registrationId)
        throw new Error("Compute registration identity is unavailable.");
      return {
        workspaceId: this.intent.workspaceId,
        registrationId: this.intent.registrationId,
      };
    };
    try {
      this.requireRequest(request.requestId);
      if (request.kind === "configure") {
        if (!owner || !this.intent.workspaceId)
          throw new Error("Compute authorization is unavailable.");
        // Readable accepted requests need no software preparation. A missing helper may be restored,
        // but dispatch below always re-reads the exact receipt instead of treating that read failure as absence.
        const accepted = fresh
          ? undefined
          : await this.readRequestReceipt(request).catch((error) => {
              if (requestBlocked(error, request.requestId)) throw error;
              return undefined;
            });
        this.requireRequest(request.requestId);
        if (!accepted) {
          if (fresh && this.options.preparation) this.preparingRequest = request;
          const ensure = () =>
            this.options.preparation?.ensure(
              () => this.publish("processing", this.snapshot.observed),
              this.intent.continuation
                ? { deadline: this.intent.continuation.deadlineAt }
                : {}
            );
          try {
            await ensure();
          } catch (error) {
            if (
              !(error instanceof ComputeNodeCommandError) ||
              error.reason !== "command_failed" ||
              error.native?.code !== "host_uninstalled" ||
              error.native.reason !== "owner_uninstalled" ||
              !this.options.reinstallHost
            )
              throw error;
            const maintenance = await this.options.reinstallHost(explicit, () =>
              this.requireRequest(request.requestId)
            );
            this.requireRequest(request.requestId);
            const operation = maintenance?.operation;
            if (
              operation?.action !== "reinstall" ||
              operation.dataPolicy !== "preserve"
            )
              throw error;
            if (operation.outcome !== "succeeded") {
              this.problem = undefined;
              this.detail = undefined;
              return this.observe();
            }
            await ensure();
          }
          if (this.preparingRequest === request) this.preparingRequest = undefined;
        }
        this.requireRequest(request.requestId);
        this.problem = undefined;
        this.detail = undefined;
        await this.configureRequest(request, explicit, localResetConfirmed);
      } else if (request.kind === "drain" || request.kind === "remove") {
        // Cloud revocation and native replay fencing are separate facts. A refused/unknown cloud call cannot
        // make native work look complete; native still fences the exact target even after a failed claim.
        let cloudError: unknown;
        if (this.intent.registrationId) {
          try {
            if (request.kind === "remove") await owner?.revoke(target());
            else await owner?.configure({ ...target(), enabled: false });
          } catch (error) {
            cloudError = error;
          }
          this.requireRequest(request.requestId);
          if (request.kind === "remove")
            await this.options.adapter.remove(
              request.requestId,
              this.intent.registrationId
            );
          else
            await this.options.adapter.drain(
              request.requestId,
              this.intent.registrationId
            );
        } else if (
          this.intent.workspaceId &&
          this.intent.authorizationRequestId &&
          owner?.cancelRequest
        ) {
          const canceled = await owner.cancelRequest({
            workspaceId: this.intent.workspaceId,
            requestId: this.intent.authorizationRequestId,
          });
          this.requireRequest(request.requestId);
          this.intent.registrationId = canceled.registrationId;
          await this.save();
          if (!canceled.hostBound && cancelingUnsubmittedPreparation) {
            // This process still awaited the new request's first preparation. No native mutation was submitted.
            // The cloud's request tombstone fences a late authorization; closing this intent deletes no local data.
            delete this.intent.request;
            delete this.intent.registrationId;
            delete this.intent.workspaceId;
            delete this.intent.authorizationRequestId;
            delete this.intent.continuation;
            this.receipt = undefined;
            this.problem = undefined;
            this.detail = undefined;
            this.cancelTimer();
            await this.save();
            return this.publish("not_set", this.snapshot.observed);
          }
          const local = await this.options.adapter.observe(
            canceled.registrationId,
            this.intent.authorizationRequestId
          );
          this.requireRequest(request.requestId);
          const original = this.options.adapter.receipt
            ? await this.options.adapter.receipt(
                this.intent.authorizationRequestId,
                canceled.registrationId
              )
            : null;
          if (
            canceled.hostBound ||
            local.readability !== "readable" ||
            local.registration !== "absent" ||
            original !== undefined
          )
            await this.options.adapter.remove(
              request.requestId,
              canceled.registrationId
            );
        } else {
          throw new Error(
            "The original authorization result must be resolved before this connection can be removed or stopped."
          );
        }
        if (cloudError) throw cloudError;
      } else if (request.kind === "recover") {
        if (!owner?.recoveryDescriptor || !this.options.adapter.recover)
          throw new Error("Registration recovery is unavailable.");
        await this.acceptNativeReceipt(
          request,
          await this.options.adapter.recover(
            request.requestId,
            owner.recoveryDescriptor(target())
          )
        );
      } else if (request.kind === "repair") {
        await this.options.updateHost?.();
        this.requireRequest(request.requestId);
      } else {
        await this.options.preparation?.rebuild(() =>
          this.publish("processing", this.snapshot.observed)
        );
      }
      this.requireRequest(request.requestId);
      if (request.kind !== "configure") {
        this.problem = undefined;
        this.detail = undefined;
      }
    } catch (error) {
      if (
        error instanceof ComputeRequestSupersededError ||
        this.intent.request?.requestId !== request.requestId
      )
        return this.state();
      this.requireAuthority();
      this.problem = requestBlocked(error, request.requestId)
        ? "request_blocked"
        : error instanceof HostMaintenanceIncompatibleError ||
            (error instanceof ComputeNodeCommandError &&
              (/unknown command|unrecognized command|unknown action/i.test(
                error.message
              ) ||
                error.native?.code === "upgrade_required"))
          ? "host_uninstalled"
          : request.kind === "remove"
            ? "removal_failed"
            : request.kind === "drain"
              ? "stop_failed"
              : error instanceof ComputeNodeCommandError &&
                  error.reason === "outcome_unknown"
                ? "operation_unknown"
                : "setup_failed";
      this.detail =
        error instanceof Error
          ? error.message.slice(0, 4096)
          : "Compute action failed.";
      this.options.log?.(`compute request ${request.kind} failed`);
      this.requireRequest(request.requestId);
      if (this.unsubmittedPreparationFailed()) {
        delete this.intent.continuation;
        this.cancelTimer();
        await this.save();
      }
    }
    this.requireRequest(request.requestId);
    return this.observe(this.receipt?.outcome === "succeeded");
  }
  private async configureRequest(
    request: NonNullable<Intent["request"]>,
    explicit: boolean,
    localResetConfirmed = false
  ) {
    const owner = this.options.installAuthorization!;
    const receipt = await this.readRequestReceipt(request);
    this.requireRequest(request.requestId);
    if (receipt) {
      if (explicit && rejectedClaimTicket(receipt)) {
        let refreshed;
        try {
          refreshed = await owner.retry({
            workspaceId: this.intent.workspaceId!,
            registrationId: this.intent.registrationId!,
          });
        } catch (error) {
          this.requireRequest(request.requestId);
          if (!(error instanceof ComputeNodeTicketNotRetryableError)) throw error;
          await this.acceptNativeReceipt(
            request,
            await this.options.adapter.resume(
              request.requestId,
              this.intent.registrationId
            )
          );
          return;
        }
        this.requireRequest(request.requestId);
        await this.acceptNativeReceipt(
          request,
          await this.options.adapter.install(request.requestId, refreshed.descriptor)
        );
        return;
      }
      if (receipt.kind === "install-managed" && !settled(receipt)) {
        this.problem = "authorization_attention";
        return;
      }
      if (settled(receipt)) return;
      if (receipt.kind === "registration-claim") {
        await this.acceptNativeReceipt(
          request,
          await this.options.adapter.resume(
            request.requestId,
            this.intent.registrationId
          )
        );
      } else if (receipt.kind === "registration-recover") {
        if (!owner.recoveryDescriptor || !this.options.adapter.recover)
          throw new Error("Registration recovery is unavailable.");
        await this.acceptNativeReceipt(
          request,
          await this.options.adapter.recover(
            request.requestId,
            owner.recoveryDescriptor({
              workspaceId: this.intent.workspaceId!,
              registrationId: this.intent.registrationId!,
            })
          )
        );
      } else {
        await this.acceptNativeReceipt(
          request,
          await this.options.adapter.enable(
            request.requestId,
            this.intent.registrationId
          )
        );
      }
      return;
    }
    // A successful exact native read is the only evidence that this request has not been accepted.
    if (!this.intent.registrationId) {
      const accepted = await owner.authorize({
        requestId: this.intent.authorizationRequestId ?? request.requestId,
        workspaceId: this.intent.workspaceId!,
      });
      this.intent.registrationId = accepted.registrationId;
      await this.save(false);
      this.requireRequest(request.requestId);
      if (accepted.descriptor) {
        await this.acceptNativeReceipt(
          request,
          await this.options.adapter.install(request.requestId, accepted.descriptor)
        );
        return;
      }
      if (!explicit)
        throw new Error("Continue this registration to renew its first claim ticket.");
      const retried = await owner.retry({
        workspaceId: this.intent.workspaceId!,
        registrationId: this.intent.registrationId,
      });
      this.requireRequest(request.requestId);
      await this.acceptNativeReceipt(
        request,
        await this.options.adapter.install(request.requestId, retried.descriptor)
      );
      return;
    }
    const local = await this.options.adapter.observe(
      this.intent.registrationId,
      request.requestId
    );
    this.requireRequest(request.requestId);
    if (
      local.readability !== "readable" ||
      (local.registration !== "present" && local.registration !== "absent")
    )
      throw new Error("The current Registration cannot be read.");
    if (local.registration === "present") {
      if (
        local.deviceId &&
        (this.intent.boundDeviceId !== local.deviceId || this.intent.resetPendingRebind)
      ) {
        this.intent.boundDeviceId = local.deviceId;
        delete this.intent.resetPendingRebind;
        await this.save(false);
      }
      await owner.configure({
        workspaceId: this.intent.workspaceId!,
        registrationId: this.intent.registrationId,
        enabled: true,
      });
      this.requireRequest(request.requestId);
      await this.acceptNativeReceipt(
        request,
        await this.options.adapter.enable(request.requestId, this.intent.registrationId)
      );
      return;
    }
    // local.registration === "absent": inspect cloud facts before deciding retry, recover, or rebind.
    const remote = await owner.inspect({
      workspaceId: this.intent.workspaceId!,
      registrationId: this.intent.registrationId,
    });
    this.requireRequest(request.requestId);
    if (remote.hostBound === false && remote.status !== "removed") {
      if (!explicit)
        throw new Error("Continue this registration to renew its first claim ticket.");
      const accepted = await owner.retry({
        workspaceId: this.intent.workspaceId!,
        registrationId: this.intent.registrationId,
      });
      this.requireRequest(request.requestId);
      await this.acceptNativeReceipt(
        request,
        await this.options.adapter.install(request.requestId, accepted.descriptor)
      );
      return;
    }
    if (
      remote.hostBound === true &&
      local.deviceIdentityState === "ready" &&
      remote.deviceId &&
      local.deviceId === remote.deviceId &&
      owner.recoveryDescriptor &&
      this.options.adapter.recover
    ) {
      await this.acceptNativeReceipt(
        request,
        await this.options.adapter.recover(
          request.requestId,
          owner.recoveryDescriptor({
            workspaceId: this.intent.workspaceId!,
            registrationId: this.intent.registrationId,
          })
        )
      );
      return;
    }
    const confirmedLocalReset =
      (remote.connected === false ||
        (localResetConfirmed &&
          this.intent.resetPendingRebind === true &&
          (!remote.deviceId ||
            !this.intent.boundDeviceId ||
            remote.deviceId === this.intent.boundDeviceId))) &&
      Boolean(local.deviceId) &&
      local.deviceId !== remote.deviceId &&
      (this.intent.resetPendingRebind === true ||
        (Boolean(this.intent.boundDeviceId) &&
          remote.deviceId === this.intent.boundDeviceId));
    if (confirmedLocalReset) {
      if (!explicit) {
        this.problem = "authorization_attention";
        return;
      }
      if (remote.status !== "removed") {
        try {
          const revokedStatus = await owner.revoke({
            workspaceId: this.intent.workspaceId!,
            registrationId: this.intent.registrationId,
          });
          if (revokedStatus !== "removed")
            throw new Error(
              `Compute node revocation did not complete (${revokedStatus}).`
            );
        } catch (error) {
          if (!(error instanceof ComputeNodeAuthorizationNotFoundError)) throw error;
        }
      }
      this.requireRequest(request.requestId);
      this.intent.authorizationRequestId = randomUUID();
      delete this.intent.registrationId;
      delete this.intent.resetPendingRebind;
      delete this.intent.boundDeviceId;
      await this.save(false);
      this.requireRequest(request.requestId);
      const accepted = await owner.authorize({
        requestId: this.intent.authorizationRequestId,
        workspaceId: this.intent.workspaceId!,
      });
      this.intent.registrationId = accepted.registrationId;
      await this.save(false);
      this.requireRequest(request.requestId);
      if (accepted.descriptor) {
        await this.acceptNativeReceipt(
          request,
          await this.options.adapter.install(request.requestId, accepted.descriptor)
        );
      }
      return;
    }
    this.problem = "authorization_attention";
  }
  private async acceptNativeReceipt(
    request: NonNullable<Intent["request"]>,
    receipt: NativeRequestReceipt | void
  ) {
    if (!receipt) return;
    if (this.intent.request !== request) throw new ComputeRequestSupersededError();
    if (
      !this.intent.registrationId ||
      receipt.targetRegistrationId !== this.intent.registrationId
    )
      throw new Error("The native receipt belongs to another Registration.");
    const expected =
      request.kind === "recover"
        ? ["registration-recover"]
        : request.kind === "configure"
          ? [
              "registration-claim",
              "registration-enable",
              "registration-recover",
              "install-managed",
            ]
          : request.kind === "drain"
            ? ["registration-drain"]
            : request.kind === "remove"
              ? ["registration-remove"]
              : [];
    if (!expected.includes(receipt.kind))
      throw new Error("The native receipt belongs to another action.");
    if (request.requestId !== receipt.requestId) {
      if (
        (request.kind !== "recover" && request.kind !== "configure") ||
        receipt.kind !== "registration-recover" ||
        receipt.correlationRequestId !== request.requestId
      )
        throw new Error("The native receipt does not acknowledge this request.");
      request.requestId = receipt.requestId;
      await this.save(false);
    }
    this.requireRequest(request.requestId);
    this.receipt = receipt;
  }
  private async readRequestReceipt(request: NonNullable<Intent["request"]>) {
    if (!this.options.adapter.receipt)
      throw new Error("The native request receipt cannot be read.");
    const receipt = await this.options.adapter.receipt(
      request.requestId,
      this.intent.registrationId
    );
    this.requireRequest(request.requestId);
    if (receipt) await this.acceptNativeReceipt(request, receipt);
    else this.receipt = undefined;
    return receipt;
  }
  private async observe(observeOnly = false) {
    this.requireAuthority();
    if (this.problem === "continuation_paused") this.problem = undefined;
    let observed: ComputeNodeRuntimeObservation;
    try {
      observed = await this.options.adapter.observe(
        this.intent.registrationId,
        this.intent.request?.requestId
      );
    } catch {
      observed = { ...this.snapshot.observed, readability: "unreadable" };
    }
    this.requireAuthority();
    this.receiptUnreadable = false;
    // No helper and no Host: nothing local can be read until a reinstall. Saved intent and identity stay as they are.
    this.hostAbsent =
      observed.reason === "helper_missing" &&
      Boolean(this.intent.registrationId || this.intent.request) &&
      (await this.options.hostInstallation?.().catch(() => undefined)) ===
        "not_installed";
    this.requireAuthority();
    if (this.hostAbsent)
      observed = {
        ...observed,
        connector: "absent",
        host: "absent",
        readability: "readable",
      };
    const request = this.intent.request;
    if (request && !this.hostAbsent && !this.unsubmittedPreparationFailed()) {
      try {
        this.receipt = await this.readRequestReceipt(request);
        if (this.receipt?.outcome === "failed")
          this.options.log?.(
            `compute request failure ${JSON.stringify({
              action: request.kind,
              requestId: request.requestId,
              failureCode: this.receipt.failureCode?.slice(0, 128) ?? "unknown",
            })}`
          );
      } catch (error) {
        this.requireRequest(request.requestId);
        this.receipt = undefined;
        if (requestBlocked(error, request.requestId)) {
          this.problem = "request_blocked";
        } else this.receiptUnreadable = true;
      }
    }
    this.remoteStatus = undefined;
    if (
      this.intent.request?.kind === "configure" &&
      this.receipt?.kind === "install-managed" &&
      !settled(this.receipt)
    )
      this.problem = "authorization_attention";
    if (
      observed.readability === "readable" &&
      observed.registration === "present" &&
      observed.deviceId &&
      this.readable &&
      !this.readOnly &&
      (this.intent.boundDeviceId !== observed.deviceId ||
        this.intent.resetPendingRebind)
    ) {
      this.intent.boundDeviceId = observed.deviceId;
      delete this.intent.resetPendingRebind;
      await this.save();
    }
    this.remoteHostBound = undefined;
    this.identityMismatch = false;
    let remoteDeviceId: string | undefined;
    let remoteConnected: boolean | undefined;
    if (
      this.intent.registrationId &&
      this.intent.workspaceId &&
      this.options.installAuthorization
    ) {
      try {
        const remote = await this.options.installAuthorization.inspect({
          registrationId: this.intent.registrationId,
          workspaceId: this.intent.workspaceId,
        });
        this.requireAuthority();
        this.remoteStatus = remote.status;
        this.remoteHostBound = remote.hostBound;
        remoteDeviceId = remote.deviceId;
        remoteConnected = remote.connected;
        this.workActivity = remote.workActivity;
        if (
          remote.errorCode === "authorization_expired" ||
          remote.errorCode === "credential_missing"
        )
          if (this.problem !== "request_blocked")
            this.problem = "authorization_attention";
        observed.salix =
          remote.status === "ready"
            ? "ready"
            : remote.status === "removed"
              ? "revoked"
              : remote.status === "action_required"
                ? "degraded"
                : "enrolling";
      } catch (error) {
        this.requireAuthority();
        observed.salix = "degraded";
        if (
          error instanceof ComputeNodeAuthorizationNotFoundError &&
          this.problem !== "request_blocked"
        )
          this.problem = "authorization_attention";
      }
    }
    this.identityMismatch = Boolean(
      observed.deviceId && remoteDeviceId && observed.deviceId !== remoteDeviceId
    );
    const confirmedLocalReset =
      this.problem !== "request_blocked" &&
      this.intent.desiredEnabled &&
      Boolean(this.intent.registrationId) &&
      observed.readability === "readable" &&
      observed.registration === "absent" &&
      remoteConnected === false &&
      Boolean(observed.deviceId) &&
      observed.deviceId !== remoteDeviceId &&
      (this.intent.resetPendingRebind === true ||
        (Boolean(this.intent.boundDeviceId) &&
          remoteDeviceId === this.intent.boundDeviceId));
    this.confirmedLocalReset = confirmedLocalReset;
    if (
      confirmedLocalReset &&
      !this.intent.request &&
      this.readable &&
      !this.readOnly
    ) {
      this.intent.request = { requestId: randomUUID(), kind: "configure" };
      await this.save();
    }
    if (
      this.problem !== "request_blocked" &&
      this.intent.desiredEnabled &&
      this.intent.registrationId &&
      observed.readability === "readable" &&
      observed.registration === "absent" &&
      (this.remoteHostBound === true ||
        this.remoteStatus === "ready" ||
        this.receipt?.outcome === "succeeded")
    ) {
      const canAutoRecover =
        this.remoteHostBound === true &&
        observed.deviceIdentityState === "ready" &&
        Boolean(remoteDeviceId) &&
        observed.deviceId === remoteDeviceId &&
        Boolean(this.options.installAuthorization?.recoveryDescriptor) &&
        Boolean(this.options.adapter.recover) &&
        !observeOnly &&
        this.intent.request?.kind === "configure" &&
        !this.receipt &&
        Boolean(this.intent.continuation) &&
        this.clock.now() < this.intent.continuation!.deadlineAt;
      if (!canAutoRecover && !confirmedLocalReset)
        this.problem = "authorization_attention";
    }
    let canceledBeforeLocalAcceptance = false;
    if (
      this.remoteStatus === "removed" &&
      this.remoteHostBound === false &&
      ["remove", "drain"].includes(this.intent.request?.kind ?? "") &&
      observed.readability === "readable" &&
      observed.registration === "absent" &&
      this.intent.authorizationRequestId &&
      this.options.adapter.receipt
    ) {
      try {
        canceledBeforeLocalAcceptance =
          (await this.options.adapter.receipt(
            this.intent.authorizationRequestId,
            this.intent.registrationId
          )) === undefined;
      } catch {
        /* An unreadable original request is not an absent request. */
      }
    }
    let status: ComputeNodeState["status"];
    if (
      !this.readable ||
      this.receiptUnreadable ||
      observed.readability === "unreadable"
    )
      status = "action_required";
    else if (this.problem === "request_blocked") status = "action_required";
    else if (
      observed.registrationState === "revoked" &&
      this.intent.request?.kind !== "remove"
    ) {
      status = "action_required";
      this.problem = "registration_revoked";
    } else if (
      this.intent.request?.kind === "configure" &&
      this.remoteStatus === "stopped" &&
      this.receipt &&
      settled(this.receipt)
    )
      status = "stopped";
    else if (canceledBeforeLocalAcceptance) status = "removed";
    else if (
      this.intent.request?.kind === "remove" &&
      this.remoteStatus === "removed" &&
      this.receipt?.outcome === "succeeded"
    )
      status = "removed";
    else if (
      this.intent.request?.kind === "drain" &&
      this.remoteStatus === "stopped" &&
      this.receipt?.outcome === "succeeded"
    )
      status = "stopped";
    else if (
      this.remoteStatus === "removed" &&
      this.intent.request?.kind !== "remove"
    ) {
      status = "action_required";
      this.problem = "registration_revoked";
    } else if (
      this.receipt?.outcome === "failed" ||
      (this.intent.request?.kind === "configure" &&
        this.receipt?.outcome === "superseded") ||
      this.problem
    )
      status = "action_required";
    else if (!this.intent.desiredEnabled)
      status = this.intent.registrationId ? "stopped" : "not_set";
    else if (
      this.remoteStatus === "ready" &&
      observed.host === "ready" &&
      observed.connector === "ready"
    )
      status = "ready";
    else status = "processing";
    if (this.hostAbsent) status = "action_required";
    if (
      status === "processing" &&
      this.intent.request &&
      (confirmedLocalReset ||
        !this.intent.continuation ||
        this.clock.now() >= this.intent.continuation.deadlineAt)
    ) {
      status = "action_required";
      this.problem = "continuation_paused";
    }
    if (
      this.problem === "request_blocked" &&
      this.intent.continuation &&
      this.readable &&
      !this.readOnly
    ) {
      delete this.intent.continuation;
      await this.save();
    }
    const converged =
      status === "ready" || status === "removed" || status === "stopped";
    if (converged) {
      this.cancelTimer();
      if (this.intent.continuation && this.readable && !this.readOnly) {
        delete this.intent.continuation;
        await this.save();
      }
    } else if (
      !this.hostAbsent &&
      !confirmedLocalReset &&
      this.problem !== "request_blocked" &&
      this.intent.request &&
      this.intent.continuation &&
      this.clock.now() < this.intent.continuation.deadlineAt &&
      this.receipt?.kind !== "install-managed" &&
      ((status === "processing" &&
        (observeOnly || this.receipt?.outcome === "succeeded")) ||
        (!observeOnly &&
          (!this.receipt ||
            this.receipt.outcome === "pending" ||
            (this.receipt.outcome === "failed" && this.receipt.retryable))))
    ) {
      this.schedule(
        Math.min(30_000, 1_000 * 2 ** Math.min(this.backoff++, 5)),
        observeOnly || this.receipt?.outcome === "succeeded"
          ? () => this.observe(true)
          : () => this.execute()
      );
    } else this.cancelTimer();
    return this.publish(status, observed);
  }
  private unsubmittedPreparationFailed() {
    return (
      this.preparingRequest !== undefined &&
      this.preparingRequest === this.intent.request &&
      this.options.preparation?.state().phase === "failed"
    );
  }
  private publish(
    status: ComputeNodeState["status"],
    observed: ComputeNodeRuntimeObservation
  ) {
    const request = this.intent.request;
    const blocked = !this.readable || this.readOnly || this.receiptUnreadable;
    let action: ComputeNodeState["primaryAction"] =
      status === "action_required" && this.receiptUnreadable
        ? this.readable && !this.readOnly && request?.kind === "configure"
          ? "continue"
          : "check_status"
        : undefined;
    if (
      this.readable &&
      !this.readOnly &&
      status === "action_required" &&
      (observed.helperContractFailure === "too_old" || this.hostAbsent)
    )
      action = "update_host";
    else if (!blocked && status === "action_required")
      action =
        this.problem === "request_blocked"
          ? this.intent.registrationId
            ? "remove"
            : "check_status"
          : this.problem === "registration_revoked"
            ? "remove"
            : this.problem === "host_uninstalled"
              ? "update_host"
              : this.problem === "authorization_attention"
                ? this.identityMismatch
                  ? "remove"
                  : "recover"
                : (this.problem === "continuation_paused" && request) ||
                    (request?.kind === "configure" && rejectedClaimTicket(this.receipt))
                  ? "continue"
                  : (this.receipt?.outcome === "failed" && !this.receipt.retryable) ||
                      (request?.kind === "configure" &&
                        this.receipt &&
                        settled(this.receipt))
                    ? "check_status"
                    : "continue";
    const problem = !this.readable
      ? "intent_unreadable"
      : this.hostAbsent
        ? "host_uninstalled"
        : this.receiptUnreadable
          ? "operation_unknown"
          : (this.problem ??
            (this.receipt?.outcome === "failed"
              ? request?.kind === "remove"
                ? "removal_failed"
                : request?.kind === "drain"
                  ? "stop_failed"
                  : "setup_failed"
              : undefined));
    this.snapshot = computeNodeStateSchema.parse({
      desiredEnabled:
        request?.kind === "configure" &&
        this.remoteStatus === "stopped" &&
        this.receipt &&
        settled(this.receipt)
          ? false
          : this.intent.desiredEnabled,
      eligibility: this.snapshot.eligibility,
      observed: {
        connector: observed.connector,
        host: observed.host,
        readability: observed.readability,
        salix: observed.salix,
      },
      facets: facetsFor(status, observed, this.workActivity),
      status,
      revision: ++this.snapshot.revision,
      bindingWorkspaceId: this.intent.workspaceId,
      bindingRegistrationId: this.intent.registrationId,
      bindingRevision: this.intent.revision,
      confirmationId: this.options.authorityGeneration?.(),
      observationFresh: observed.readability === "readable",
      observedAt: new Date(this.clock.now()).toISOString(),
      ...(request
        ? {
            currentRequest: request,
            operation: {
              requestId: request.requestId,
              kind: request.kind,
              outcome:
                this.receipt?.outcome === "superseded"
                  ? "failed"
                  : (this.receipt?.outcome ?? "unknown"),
              ...(this.receipt?.stage ? { stage: this.receipt.stage } : {}),
            },
          }
        : {}),
      ...(action ? { primaryAction: action } : {}),
      ...(problem ? { problem } : {}),
      ...(this.detail ? { problemDetail: this.detail } : {}),
      ...(this.intent.continuation && status === "processing"
        ? { deadlineAt: new Date(this.intent.continuation.deadlineAt).toISOString() }
        : {}),
      ...(this.options.preparation
        ? { preparation: this.options.preparation.state() }
        : {}),
    });
    this.options.onStateChanged?.(this.state());
    return this.state();
  }
  private cancelTimer() {
    this.timer?.cancel();
    this.timer = undefined;
  }
  private schedule(ms: number, run: () => Promise<ComputeNodeState>) {
    this.cancelTimer();
    const request = this.intent.request;
    const timer = {
      run: () => {
        if (this.intent.request !== request) return Promise.resolve(this.state());
        return this.receipt?.outcome === "succeeded" ? this.observe(true) : run();
      },
      cancel: () => {},
    };
    timer.cancel = this.clock.setTimer(ms, () => {
      if (this.timer !== timer) return;
      this.timer = undefined;
      void this.run(timer.run).catch(() => undefined);
    });
    this.timer = timer;
  }
  private requireBinding(expected?: ComputeNodeExpectedBinding) {
    if (
      expected &&
      (expected.workspaceId !== this.intent.workspaceId ||
        expected.registrationId !== (this.intent.registrationId ?? null) ||
        expected.bindingRevision !== this.intent.revision ||
        expected.confirmationId !== this.options.authorityGeneration?.())
    )
      throw new ComputeNodeBindingChangedError(
        "The connection changed. Review its current scope."
      );
  }
  private requireMutable() {
    this.requireAuthority();
    if (!this.readable || this.readOnly)
      throw new Error(
        "The saved compute intent is unreadable or belongs to a newer Comma."
      );
  }
  private requireRequest(requestId: string) {
    this.requireAuthority();
    if (this.intent.request?.requestId !== requestId)
      throw new ComputeRequestSupersededError();
  }
  private requireAuthority() {
    if (
      this.options.authorityGeneration &&
      (!this.options.authorityGeneration() ||
        this.authority.getStore() !== this.options.authorityGeneration())
    )
      throw new ComputeNodeSessionChangedError();
  }
  private async save(current = true) {
    if (current) this.requireAuthority();
    this.intent.version = INTENT_VERSION;
    this.intent.revision++;
    const revision = this.intent.revision;
    const body = JSON.stringify(this.intent);
    const temporary = `${this.options.filePath}.${randomUUID()}.tmp`;
    await mkdir(dirname(this.options.filePath), { recursive: true });
    await writeFile(temporary, body, { mode: 0o600 });
    if (current) this.requireAuthority();
    if (revision !== this.intent.revision) {
      await rm(temporary, { force: true });
      return;
    }
    await rename(temporary, this.options.filePath);
  }
  private run(operation: () => Promise<ComputeNodeState>, interrupt = false) {
    const generation = this.options.authorityGeneration?.();
    const execute = () =>
      this.authority.run(generation, async () => {
        this.requireAuthority();
        return operation();
      });
    if (interrupt) return execute();
    const next = this.tail.then(execute, execute);
    this.tail = next.catch(() => undefined);
    return next;
  }
}
function settled(receipt: NativeRequestReceipt) {
  return (
    receipt.outcome === "succeeded" ||
    receipt.outcome === "superseded" ||
    (receipt.outcome === "failed" && !receipt.retryable)
  );
}

function facetsFor(
  status: ComputeNodeState["status"],
  observed: ComputeNodeRuntimeObservation,
  workActivity: ComputeNodeWorkActivity = "unknown"
): ComputeNodeState["facets"] {
  return {
    admission:
      status === "ready" ? "accepting" : status === "stopped" ? "draining" : "closed",
    connection:
      observed.connector === "ready"
        ? "connected"
        : observed.connector === "degraded"
          ? "degraded"
          : status === "processing"
            ? "connecting"
            : "disconnected",
    installationHealth:
      observed.host === "absent"
        ? "absent"
        : observed.host === "ready"
          ? "healthy"
          : "degraded",
    runtimeReadiness:
      status === "ready"
        ? "ready"
        : status === "processing"
          ? "starting"
          : "unavailable",
    workActivity,
  };
}

function requestBlocked(error: unknown, requestId: string) {
  return (
    error instanceof ComputeNodeCommandError &&
    error.reason === "command_failed" &&
    error.native?.code === "request_blocked" &&
    error.native.reason === "local_owner_fence" &&
    error.native.requestId === requestId
  );
}

function rejectedClaimTicket(receipt: NativeRequestReceipt | undefined) {
  return (
    receipt?.kind === "registration-claim" &&
    receipt.outcome === "failed" &&
    (receipt.failureCode === "invalid_ticket" ||
      receipt.failureCode === "ticket_expired")
  );
}
