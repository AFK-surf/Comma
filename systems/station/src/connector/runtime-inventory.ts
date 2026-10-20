// The runtime inventory: the last observation of every agent runtime target, refreshed by probes. One probe per target
// runs at a time and every caller shares it; at most two probes run at once. A probe result is committed only through
// the commit guard (the target's exact generation and auth epoch): a superseded probe is retried once for all its
// callers, and a no-retry probe hands every caller the safe cache. Probe evidence (trigger, duration, the frame
// publication) rides on the result and never enters the cache. Modeled in tla/connector/RuntimeAuth.tla.
import { Cause, Deferred, Effect, Exit, Semaphore } from "effect";
import { type RuntimeTarget, runtimeTargetKey } from "./runtime-discovery.ts";

export const RUNTIME_PROBE_CONCURRENCY = 2;
export const RUNTIME_PROBE_FRAME_EVIDENCE = "_probe_frame_evidence";
export const RUNTIME_PROBE_GENERATION_EVIDENCE = "_runtime_generation_evidence";
export const RUNTIME_PROBE_AUTH_EPOCH_EVIDENCE = "_runtime_auth_epoch_evidence";
export const RUNTIME_PROBE_NO_RETRY_EVIDENCE = "_runtime_probe_no_retry_evidence";

export type RuntimeObservation = Record<string, any>;

export class RuntimeProbeSuperseded extends Error {
  override readonly name = "RuntimeProbeSuperseded";
  constructor() {
    super("runtime probe observation was superseded");
  }
}

/** The metadata frame a probe's result is published in: the first caller claims it, the others wait for it. */
export class RuntimeProbePublication {
  claimed = false;
  readonly done = Deferred.makeUnsafe<void, Error>();
  complete(error: Error | null) {
    Deferred.doneUnsafe(this.done, error ? Exit.fail(error) : Exit.void);
  }
}

export type CommitGuard = (target: RuntimeTarget, generation: string, authEpoch: number, observed: RuntimeObservation, commit: () => void) => boolean;

type Call = {
  done: Deferred.Deferred<void>;
  publication: RuntimeProbePublication;
  runtime: RuntimeObservation | null;
  error: Error | null;
  waiters: number;
};

const observationKey = (runtime: RuntimeObservation) => `${runtime.provider ?? ""}\0${runtime.identity_material ?? ""}`;

export function cloneObservation(runtime: RuntimeObservation): RuntimeObservation {
  const cloned = { ...runtime };
  if (runtime.auth && typeof runtime.auth === "object") cloned.auth = { ...runtime.auth };
  return cloned;
}

function cachedObservation(runtime: RuntimeObservation): RuntimeObservation {
  const cached = cloneObservation(runtime);
  for (const key of ["probe_trigger", "probe_duration_ms", RUNTIME_PROBE_FRAME_EVIDENCE, RUNTIME_PROBE_GENERATION_EVIDENCE, RUNTIME_PROBE_AUTH_EPOCH_EVIDENCE, RUNTIME_PROBE_NO_RETRY_EVIDENCE]) delete cached[key];
  return cached;
}

export const normalizeProbeTrigger = (trigger: string) => (["connect", "periodic", "operator"].includes(trigger) ? trigger : "other");

export type RuntimeInventoryOptions = {
  run: (target: RuntimeTarget) => Effect.Effect<RuntimeObservation>;
  commitGuard?: CommitGuard;
  /** Every probe path applies the workspace's readiness (an unusable workspace makes runtimes unavailable). */
  workspaceReadiness?: () => Effect.Effect<void, Error>;
  /** The readiness message for a workspace error (no private paths). */
  workspaceMessage?: (error: unknown) => string;
  /** Runs a probe detached from its first caller (joined callers depend on it). */
  fork?: (effect: Effect.Effect<void>) => void;
  discover?: () => RuntimeTarget[];
  nowMs?: () => number;
};

export class RuntimeInventory {
  private runtimes = new Map<string, RuntimeObservation>();
  private inflight = new Map<string, Call>();
  private readonly slots = Semaphore.makeUnsafe(RUNTIME_PROBE_CONCURRENCY);
  private options: RuntimeInventoryOptions;

  constructor(options: RuntimeInventoryOptions) {
    this.options = { ...options };
  }

  set commitGuard(guard: CommitGuard | undefined) {
    this.options.commitGuard = guard;
  }

  setWorkspaceReadinessForTest(check: Effect.Effect<void, Error> | null) {
    this.options.workspaceReadiness = check ? () => check : undefined;
  }

  setWorkspaceReadiness(check: (() => Effect.Effect<void, Error>) | undefined) {
    this.options.workspaceReadiness = check;
  }

  snapshot(): RuntimeObservation[] {
    return [...this.runtimes.values()].map(cloneObservation).sort((a, b) => (observationKey(a) < observationKey(b) ? -1 : observationKey(a) > observationKey(b) ? 1 : 0));
  }

  has(target: RuntimeTarget) {
    return this.runtimes.has(runtimeTargetKey(target));
  }

  get(target: RuntimeTarget): RuntimeObservation | undefined {
    const runtime = this.runtimes.get(runtimeTargetKey(target));
    return runtime ? cloneObservation(runtime) : undefined;
  }

  /** Probes one target, or (with no provider) every discovered target, dropping targets no longer present. */
  probe(request: { provider?: string; identityMaterial?: string; trigger: string }): Effect.Effect<RuntimeObservation[], Error> {
    const self = this;
    return Effect.gen(function* () {
      const provider = (request.provider ?? "").trim();
      const identityMaterial = (request.identityMaterial ?? "").trim();
      if ((provider === "") !== (identityMaterial === "")) return yield* Effect.fail(new Error("provider and identity_material must be provided together"));
      if (provider) {
        const target = { provider, identityMaterial };
        if (!self.has(target)) return yield* Effect.fail(new Error("runtime target is not present in the current inventory"));
        return [yield* self.probeOne(target, request.trigger)];
      }
      const targets = self.options.discover?.() ?? [];
      const discovered = new Set(targets.map(runtimeTargetKey));
      const probed: RuntimeObservation[] = [];
      for (const target of targets) probed.push(yield* self.probeOne(target, request.trigger));
      for (const key of [...self.runtimes.keys()]) if (!discovered.has(key)) self.runtimes.delete(key);
      return mergeProbeEvidence(self.snapshot(), probed);
    });
  }

  /** One target: joins an in-flight probe, and retries one that the commit guard superseded. */
  probeOne(target: RuntimeTarget, trigger: string): Effect.Effect<RuntimeObservation, Error> {
    const self = this;
    return Effect.gen(function* () {
      while (true) {
        const exit = yield* Effect.exit(self.probeOneAttempt(target, trigger));
        if (Exit.isSuccess(exit)) return exit.value;
        if (!(Cause.squash(exit.cause) instanceof RuntimeProbeSuperseded)) return yield* Effect.failCause(exit.cause);
      }
    });
  }

  waitersForTest(target: RuntimeTarget): number {
    return this.inflight.get(runtimeTargetKey(target))?.waiters ?? 0;
  }

  private probeOneAttempt(target: RuntimeTarget, trigger: string): Effect.Effect<RuntimeObservation, Error> {
    const self = this;
    const key = runtimeTargetKey(target);
    return Effect.gen(function* () {
      const existing = self.inflight.get(key);
      if (existing) {
        existing.waiters++;
        return yield* Deferred.await(existing.done).pipe(
          Effect.ensuring(Effect.sync(() => existing.waiters--)),
          Effect.flatMap(() => (existing.error ? Effect.fail(existing.error) : Effect.succeed(cloneObservation(existing.runtime ?? {})))),
        );
      }
      const call: Call = { done: Deferred.makeUnsafe<void>(), publication: new RuntimeProbePublication(), runtime: null, error: null, waiters: 1 };
      self.inflight.set(key, call);
      // The probe runs to completion even if this caller goes away: joined callers depend on it.
      (self.options.fork ?? ((effect) => void Effect.runFork(effect)))(self.runProbe(target, trigger, call));
      return yield* Deferred.await(call.done).pipe(
        Effect.ensuring(Effect.sync(() => call.waiters--)),
        Effect.flatMap(() => (call.error ? Effect.fail(call.error) : Effect.succeed(cloneObservation(call.runtime ?? {})))),
      );
    });
  }

  private runProbe(target: RuntimeTarget, trigger: string, call: Call): Effect.Effect<void> {
    const self = this;
    return Effect.gen(function* () {
      const started = self.options.nowMs?.() ?? 0;
      const runtime = yield* Semaphore.withPermits(self.slots, 1)(self.options.run(target));
      if (self.options.workspaceReadiness) {
        const workspace = yield* Effect.exit(self.options.workspaceReadiness());
        if (Exit.isFailure(workspace)) applyWorkspaceUnavailable(runtime, Cause.squash(workspace.cause), self.options.workspaceMessage);
      }
      runtime.probe_trigger = normalizeProbeTrigger(trigger);
      runtime.probe_duration_ms = Math.max(0, (self.options.nowMs?.() ?? 0) - started);
      runtime[RUNTIME_PROBE_FRAME_EVIDENCE] = call.publication;
      const generation = String(runtime[RUNTIME_PROBE_GENERATION_EVIDENCE] ?? "");
      const authEpoch = Number(runtime[RUNTIME_PROBE_AUTH_EPOCH_EVIDENCE] ?? 0);
      const noRetry = runtime[RUNTIME_PROBE_NO_RETRY_EVIDENCE] === true;
      delete runtime[RUNTIME_PROBE_GENERATION_EVIDENCE];
      delete runtime[RUNTIME_PROBE_AUTH_EPOCH_EVIDENCE];
      delete runtime[RUNTIME_PROBE_NO_RETRY_EVIDENCE];
      self.finish(target, call, runtime, generation, authEpoch, noRetry);
    }).pipe(
      Effect.catchCause((cause) =>
        Effect.sync(() => {
          call.error = new Error(`runtime probe failed: ${String(cause)}`);
          self.inflight.delete(runtimeTargetKey(target));
          Deferred.doneUnsafe(call.done, Exit.void);
        }),
      ),
    );
  }

  private finish(target: RuntimeTarget, call: Call, runtime: RuntimeObservation, generation: string, authEpoch: number, noRetry: boolean) {
    const key = runtimeTargetKey(target);
    const commit = () => void this.runtimes.set(key, cachedObservation(runtime));
    const accepted = this.options.commitGuard ? this.options.commitGuard(target, generation, authEpoch, runtime, commit) : (commit(), true);
    if (accepted) call.runtime = cloneObservation(runtime);
    else {
      call.runtime = cloneObservation(this.runtimes.get(key) ?? {});
      if (!noRetry) call.error = new RuntimeProbeSuperseded();
    }
    this.inflight.delete(key);
    Deferred.doneUnsafe(call.done, Exit.void);
  }

  /** Publishes an auth observation into the cache; a non-ready status always disables dispatch. */
  updateAuthSnapshot(target: RuntimeTarget, snapshot: Record<string, unknown>, preserveFullReadiness: boolean): boolean {
    const runtime = this.runtimes.get(runtimeTargetKey(target));
    if (!runtime) return false;
    const status = String(snapshot.status ?? "");
    runtime.auth = { ...snapshot };
    runtime.auth_ready = status === "authenticated" || status === "not_required";
    if (status === "authenticated" || status === "not_required") {
      if (!preserveFullReadiness) {
        // Authentication is one readiness input; a replacement or previously non-ready process has not validated its models.
        Object.assign(runtime, { ready: false, status: "unavailable", readiness_issue: "runtime_probe_failed", readiness_message: "The Codex runtime has not completed a full readiness probe for this process." });
      }
    } else if (["unknown", "configured", "pending", "unauthenticated", "error"].includes(status)) {
      Object.assign(runtime, { ready: false, status: "unavailable" });
      if (status === "unauthenticated" || status === "pending") Object.assign(runtime, { readiness_issue: "authentication_required", readiness_message: "Codex reports no authenticated account." });
      else Object.assign(runtime, { readiness_issue: "runtime_probe_failed", readiness_message: "The Codex authentication state could not be confirmed." });
    }
    return true;
  }

  fullReadinessInputsReady(target: RuntimeTarget) {
    return this.runtimes.get(runtimeTargetKey(target))?.auth_ready === true;
  }

  // Test controls.

  setForTest(runtimes: RuntimeObservation[]) {
    this.runtimes = new Map(runtimes.map((r) => [observationKey(r), cachedObservation(r)]));
  }

  setProbeForTest(probe: (target: RuntimeTarget) => RuntimeObservation) {
    this.options.run = (target) => Effect.sync(() => probe(target));
  }

  setRunForTest(wrap: (original: (target: RuntimeTarget) => Effect.Effect<RuntimeObservation>) => (target: RuntimeTarget) => Effect.Effect<RuntimeObservation>) {
    this.options.run = wrap(this.options.run);
  }

  removeForTest(target: RuntimeTarget) {
    this.runtimes.delete(runtimeTargetKey(target));
  }

  patchForTest(target: RuntimeTarget, patch: Record<string, unknown>) {
    const runtime = this.runtimes.get(runtimeTargetKey(target));
    if (runtime) Object.assign(runtime, patch);
  }
}

/** The probe result's evidence copied onto the matching cache entries (for the frame that publishes them). */
export function mergeProbeEvidence(runtimes: RuntimeObservation[], probed: RuntimeObservation[]): RuntimeObservation[] {
  const evidence = new Map(probed.filter((r) => r[RUNTIME_PROBE_FRAME_EVIDENCE] instanceof RuntimeProbePublication).map((r) => [observationKey(r), r]));
  for (const runtime of runtimes) {
    const observed = evidence.get(observationKey(runtime));
    if (observed) Object.assign(runtime, { probe_trigger: observed.probe_trigger, probe_duration_ms: observed.probe_duration_ms, [RUNTIME_PROBE_FRAME_EVIDENCE]: observed[RUNTIME_PROBE_FRAME_EVIDENCE] });
  }
  return runtimes;
}

/** An unusable runtime workspace makes the runtime unavailable, with a message that names no private path. */
export function applyWorkspaceUnavailable(runtime: RuntimeObservation, error: unknown, message?: (error: unknown) => string) {
  Object.assign(runtime, {
    ready: false,
    status: "unavailable",
    readiness_issue: "workspace_unavailable",
    readiness_message: message ? message(error) : "The external runtime workspace could not be prepared.",
    last_error: error instanceof Error ? error.message : String(error),
  });
}
