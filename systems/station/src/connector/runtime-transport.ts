// The connector's requests to Salix (runtime_proxy for agent tools, runtime_execution, runtime events, subscription
// access, ...): sent on the live carrier and answered by a response/error frame with the same id. A carrier that
// closes fails its pending requests; ids only correlate replies within one connector lifetime.
import { Deferred, Duration, Effect, Exit, Semaphore } from "effect";
import type { Message } from "./message.ts";

export class RuntimeTransportUnavailable extends Error {
  override readonly name = "RuntimeTransportUnavailable";
  constructor(detail = "") {
    super(detail ? `runtime transport unavailable: ${detail}` : "runtime transport unavailable");
  }
}

/** One live carrier: a connection generation's (or a compute socket's) send path. */
export class RuntimeCarrier {
  readonly send: (message: Message) => Effect.Effect<void, unknown>;
  readonly done = Deferred.makeUnsafe<void>();
  private closedFlag = false;
  /** Admitted commits (credential renames) that a revocation waits for. */
  commitsInFlight = 0;
  private drained: Array<() => void> = [];

  constructor(send: (message: Message) => Effect.Effect<void, unknown>) {
    this.send = send;
  }

  get closed() {
    return this.closedFlag;
  }

  close() {
    if (this.closedFlag) return;
    this.closedFlag = true;
    Deferred.doneUnsafe(this.done, Exit.void);
  }

  enterCommit(): boolean {
    if (this.closedFlag) return false;
    this.commitsInFlight++;
    return true;
  }

  leaveCommit() {
    this.commitsInFlight--;
    if (this.commitsInFlight === 0) for (const wake of this.drained.splice(0)) wake();
  }

  /** Resolves when no admitted commit is running. */
  get commitsDrained(): Effect.Effect<void> {
    return Effect.callback<void>((resume) => {
      if (this.commitsInFlight === 0) return resume(Effect.void);
      this.drained.push(() => resume(Effect.void));
    });
  }
}

type Pending = { carrier: RuntimeCarrier | null; reply: Deferred.Deferred<Message> };

export const RUNTIME_PROXY_TIMEOUT = Duration.seconds(60);
export const RUNTIME_PROXY_SLOTS = 32;

export function makeRuntimeTransport(options: { onActivate?: () => void; onDeactivate?: (carrier: RuntimeCarrier) => void; proxySlots?: number }) {
  let active: RuntimeCarrier | null = null;
  let sequence = 0;
  const pending = new Map<string, Pending>();
  const proxySlots = Semaphore.makeUnsafe(options.proxySlots ?? RUNTIME_PROXY_SLOTS);
  let proxyInflight = 0;

  const failPending = (carrier: RuntimeCarrier) => {
    for (const [id, entry] of pending) {
      if (entry.carrier === carrier) pending.delete(id);
    }
  };

  /** Deactivates (once): pending requests on it fail; waits for admitted commits first. */
  const revoke = (carrier: RuntimeCarrier): Effect.Effect<void> =>
    Effect.gen(function* () {
      if (active === carrier) active = null;
      carrier.close();
      yield* carrier.commitsDrained;
      failPending(carrier);
      options.onDeactivate?.(carrier);
    });

  const transport = {
    activate(send: (message: Message) => Effect.Effect<void, unknown>): RuntimeCarrier {
      const carrier = new RuntimeCarrier(send);
      active = carrier;
      options.onActivate?.();
      return carrier;
    },
    revoke,
    active: () => active,
    nextRequestId: (prefix: string) => `${prefix}${(++sequence).toString(36)}`,
    /** Sends `request` on `carrier` and waits for its reply, the carrier's end, or the timeout. */
    request(carrier: RuntimeCarrier, request: Message, timeout?: Duration.Duration): Effect.Effect<Message, Error> {
      return Effect.gen(function* () {
        const reply = Deferred.makeUnsafe<Message>();
        const id = request.id!;
        pending.set(id, { carrier, reply });
        const forget = Effect.sync(() => {
          if (pending.get(id)?.reply === reply) pending.delete(id);
        });
        return yield* Effect.gen(function* () {
          if (carrier.closed) return yield* Effect.fail(new RuntimeTransportUnavailable());
          const sent = yield* Effect.exit(carrier.send(request));
          if (Exit.isFailure(sent)) return yield* Effect.fail(new RuntimeTransportUnavailable(String(Exit.isFailure(sent) ? "send failed" : "")));
          const raced = Effect.raceFirst(
            Deferred.await(reply).pipe(Effect.map((m) => ({ ok: true as const, m }))),
            Deferred.await(carrier.done).pipe(Effect.as({ ok: false as const })),
          );
          const outcome = timeout ? yield* raced.pipe(Effect.timeoutOption(timeout)) : { _tag: "Some" as const, value: yield* raced };
          if (outcome._tag === "None") return yield* Effect.fail(new Error("context deadline exceeded"));
          if (!outcome.value.ok) return yield* Effect.fail(new RuntimeTransportUnavailable());
          return outcome.value.m;
        }).pipe(Effect.ensuring(forget));
      });
    },
    /** A reply frame from Salix. */
    complete(msg: Message) {
      if (!msg.id) return;
      const entry = pending.get(msg.id);
      if (!entry) return;
      pending.delete(msg.id);
      Deferred.doneUnsafe(entry.reply, Exit.succeed(msg));
    },
    /** A pending request no carrier owns (tests that feed replies directly). */
    registerPending(id: string): Effect.Effect<Message> {
      const reply = Deferred.makeUnsafe<Message>();
      pending.set(id, { carrier: null, reply });
      return Deferred.await(reply);
    },
    pendingCount: () => pending.size,
    /** runtime_proxy: an agent tool call relayed to Salix, bounded in concurrency and time. */
    proxy(params: Record<string, unknown>): Effect.Effect<Record<string, unknown>, Error> {
      const self = this;
      return Semaphore.withPermits(
        proxySlots,
        1,
      )(
        Effect.gen(function* () {
          proxyInflight++;
          const carrier = active;
          if (!carrier) return yield* Effect.fail(new RuntimeTransportUnavailable());
          const reply = yield* self.request(carrier, { id: self.nextRequestId("runtime_"), type: "request", method: "runtime_proxy", params }, RUNTIME_PROXY_TIMEOUT).pipe(
            Effect.mapError((e) => (e instanceof RuntimeTransportUnavailable ? new RuntimeTransportUnavailable(`delivery result unconfirmed: ${e.message}`) : e)),
          );
          if (reply.type === "error" || reply.error) return yield* Effect.fail(new Error(reply.error || "runtime proxy error"));
          return reply.result && typeof reply.result === "object" && !Array.isArray(reply.result) ? (reply.result as Record<string, unknown>) : { value: reply.result };
        }).pipe(Effect.ensuring(Effect.sync(() => proxyInflight--))),
      ).pipe(Effect.timeoutOption(RUNTIME_PROXY_TIMEOUT), Effect.flatMap((o) => (o._tag === "Some" ? Effect.succeed(o.value) : Effect.fail(new Error("context deadline exceeded")))));
    },
    /** Runs `effect` holding a proxy slot when one is free (None at once when all are taken): meeting callbacks. */
    withProxySlotIfAvailable: <A, E, R>(effect: Effect.Effect<A, E, R>) => Semaphore.withPermitsIfAvailable(proxySlots, 1)(effect),
    proxyInflight: () => proxyInflight,
    proxyCapacity: () => options.proxySlots ?? RUNTIME_PROXY_SLOTS,
    saturateProxySlotsForTest: () => {
      const permits = options.proxySlots ?? RUNTIME_PROXY_SLOTS;
      Effect.runSync(Semaphore.take(proxySlots, permits));
      return () => void Effect.runSync(Semaphore.release(proxySlots, permits));
    },
  };
  return transport;
}

export type RuntimeTransport = ReturnType<typeof makeRuntimeTransport>;
