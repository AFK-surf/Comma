import { randomUUID } from "node:crypto";
import {
  LocalDataWriteFailure,
  assertNormalizedLocalDataAudience,
  assertLocalDataWriteAck,
  type LocalDataOpenResult,
  type LocalDataRepository,
  type LocalDataRepositoryHealth,
  type LocalDataWorkerApi,
  type LocalDataWriteAck,
  type LocalProductInboxItem,
  type ProductInboxCacheApplyInput,
  type LocalDataProductWorkspaceInput,
} from "../../../shared/local-data";
import type { SessionProductLease } from "@comma/session-contract";
import { LocalDataDirtyReplayQueue } from "./worker-replay";

type AsyncWorkerApi = {
  [Method in keyof LocalDataWorkerApi]: LocalDataWorkerApi[Method] extends (
    ...args: infer Args
  ) => infer Result
    ? (...args: Args) => Promise<Awaited<Result>>
    : never;
};

export interface LocalDataWorkerConnection {
  readonly remote: AsyncWorkerApi;
  dispose(): void;
  isTerminated(): boolean;
  onTerminated(listener: (error: Error) => void): () => void;
}

export interface LocalDataWorkerHost {
  connect(): LocalDataWorkerConnection;
}

export interface LocalDataUtilityRepositoryOptions {
  createOperationId?: (() => string) | undefined;
  databasePath: string;
  host: LocalDataWorkerHost;
  isCurrentSessionLease: (lease: SessionProductLease) => boolean;
  now?: (() => number) | undefined;
  openTimeoutMs?: number | undefined;
  requestTimeoutMs?: number | undefined;
  restartDelaysMs?: readonly number[] | undefined;
  scheduleDeadline?: ((expire: () => void, delayMs: number) => () => void) | undefined;
  scheduleRestart?: ((restart: () => void, delayMs: number) => () => void) | undefined;
}

interface ActiveConnection {
  cancelPendingCalls: Set<(error: Error) => void>;
  connection: LocalDataWorkerConnection;
  generation: number;
  inFlightWrites: number;
  removeTerminatedListener: () => void;
}

interface WriteWaiter {
  cancelDeadline(): void;
  reject(error: Error): void;
  resolve(ack: LocalDataWriteAck): void;
}

class LocalDataUtilityTimeoutError extends Error {
  constructor(operation: string, timeoutMs: number) {
    super(`Local data utility ${operation} timed out after ${timeoutMs} ms.`);
    this.name = "LocalDataUtilityTimeoutError";
  }
}

const DEFAULT_OPEN_TIMEOUT_MS = 5_000;
const DEFAULT_REQUEST_TIMEOUT_MS = 5_000;
const DEFAULT_RESTART_DELAYS_MS = [250, 1_000, 5_000, 15_000, 30_000] as const;
const MAX_CONCURRENT_WRITES = 2;
const RESTART_STABILITY_WINDOW_MS = 5_000;

/**
 * Main-side repository for the local-data utility process.
 *
 * Writes become dirty before dispatch and remain dirty until an acknowledgement
 * from the current workerGeneration is accepted. A replacement worker therefore
 * replays the exact merge/replace operation after an unconfirmed process loss.
 */
export class LocalDataUtilityRepository implements LocalDataRepository {
  readonly #createOperationId: () => string;
  readonly #databasePath: string;
  readonly #host: LocalDataWorkerHost;
  readonly #now: () => number;
  readonly #openTimeoutMs: number;
  readonly #recoveredListeners = new Set<(workerGeneration: number) => void>();
  readonly #replay: LocalDataDirtyReplayQueue;
  readonly #requestTimeoutMs: number;
  readonly #restartDelaysMs: readonly number[];
  readonly #scheduleDeadlineImpl: (expire: () => void, delayMs: number) => () => void;
  readonly #scheduleRestartImpl: (restart: () => void, delayMs: number) => () => void;
  readonly #writeWaiters = new Map<string, WriteWaiter>();

  #active: ActiveConnection | undefined;
  #closed = false;
  #consecutiveStartFailures = 0;
  #health: LocalDataRepositoryHealth = {
    status: "degraded",
    workerGeneration: 0,
  };
  #ready = createReadySignal();
  #lastReadyAt: number | undefined;
  #recoveryPending = false;
  #restartCancellation: (() => void) | undefined;
  #starting: Promise<void> | undefined;

  private constructor({
    createOperationId = randomUUID,
    databasePath,
    host,
    isCurrentSessionLease,
    now = Date.now,
    openTimeoutMs = DEFAULT_OPEN_TIMEOUT_MS,
    requestTimeoutMs = DEFAULT_REQUEST_TIMEOUT_MS,
    restartDelaysMs = DEFAULT_RESTART_DELAYS_MS,
    scheduleDeadline = defaultDeadlineScheduler,
    scheduleRestart = defaultRestartScheduler,
  }: LocalDataUtilityRepositoryOptions) {
    this.#createOperationId = createOperationId;
    this.#databasePath = databasePath;
    this.#host = host;
    this.#now = now;
    this.#openTimeoutMs = normalizeTimeout(openTimeoutMs, "openTimeoutMs");
    this.#replay = new LocalDataDirtyReplayQueue(isCurrentSessionLease);
    this.#requestTimeoutMs = normalizeTimeout(requestTimeoutMs, "requestTimeoutMs");
    this.#restartDelaysMs = normalizeRestartDelays(restartDelaysMs);
    this.#scheduleDeadlineImpl = scheduleDeadline;
    this.#scheduleRestartImpl = scheduleRestart;
  }

  static async open(options: LocalDataUtilityRepositoryOptions) {
    const repository = new LocalDataUtilityRepository(options);
    await repository.#startWorker();
    return repository;
  }

  applyProductInboxSync(
    input: ProductInboxCacheApplyInput
  ): Promise<LocalDataWriteAck> {
    this.#throwIfClosed();
    const operationId = this.#createOperationId();
    try {
      this.#replay.enqueue(operationId, input);
    } catch (error) {
      return Promise.reject(toError(error));
    }

    const result = new Promise<LocalDataWriteAck>((resolve, reject) => {
      const waiter: WriteWaiter = {
        cancelDeadline: noop,
        reject: (error) => reject(error),
        resolve,
      };
      this.#writeWaiters.set(operationId, waiter);
      waiter.cancelDeadline = this.#scheduleDeadlineImpl(() => {
        if (this.#writeWaiters.get(operationId) !== waiter) return;
        this.#settleWriteWaiter(operationId, {
          error: new LocalDataUtilityTimeoutError(
            "applyProductInboxSync",
            this.#requestTimeoutMs
          ),
        });
      }, this.#requestTimeoutMs);
    });
    this.#dispatchDirtyWrites();
    return result;
  }

  async close(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    this.#restartCancellation?.();
    this.#restartCancellation = undefined;
    this.#ready.resolve();

    const closedError = new Error("Local data repository is closed.");
    for (const operationId of this.#writeWaiters.keys()) {
      this.#settleWriteWaiter(operationId, { error: closedError });
    }
    this.#recoveredListeners.clear();

    const active = this.#active;
    this.#active = undefined;
    this.#health = {
      status: "closed",
      workerGeneration: this.#health.workerGeneration,
    };
    if (!active) return;

    this.#cancelConnectionCalls(active, closedError);
    active.removeTerminatedListener();
    try {
      await this.#runWithDeadline({
        operation: "close",
        run: () => active.connection.remote.close(),
        timeoutMs: this.#requestTimeoutMs,
      });
    } catch {
      // The process may already be gone; disposal below still tears down the port.
    } finally {
      active.connection.dispose();
    }
  }

  health(): LocalDataRepositoryHealth {
    return { ...this.#health };
  }

  async listProductInboxItems(input: {
    audience: string;
    limit?: number | undefined;
    principalId: string;
    workspaceId?: string | undefined;
  }): Promise<LocalProductInboxItem[]> {
    assertNormalizedLocalDataAudience(input.audience);
    const active = await this.#readyConnection();
    return this.#runConnectionCall(active, "listProductInboxItems", () =>
      active.connection.remote.listProductInboxItems(input)
    );
  }

  async listProductWorkspaces(input: {
    audience: string;
    principalId: string;
  }): Promise<LocalDataProductWorkspaceInput[]> {
    assertNormalizedLocalDataAudience(input.audience);
    const active = await this.#readyConnection();
    return this.#runConnectionCall(active, "listProductWorkspaces", () =>
      active.connection.remote.listProductWorkspaces(input)
    );
  }

  onRecovered(listener: (workerGeneration: number) => void): () => void {
    this.#throwIfClosed();
    this.#recoveredListeners.add(listener);
    return () => {
      this.#recoveredListeners.delete(listener);
    };
  }

  async referencedBlobIds(): Promise<string[]> {
    const active = await this.#readyConnection();
    return this.#runConnectionCall(active, "referencedBlobIds", () =>
      active.connection.remote.referencedBlobIds()
    );
  }

  async schemaVersion(): Promise<number> {
    const active = await this.#readyConnection();
    return this.#runConnectionCall(active, "schemaVersion", () =>
      active.connection.remote.schemaVersion()
    );
  }

  async #startWorker(): Promise<void> {
    if (this.#closed || this.#starting) return this.#starting;

    const start = this.#startWorkerAttempt().finally(() => {
      if (this.#starting === start) this.#starting = undefined;
    });
    this.#starting = start;
    return start;
  }

  async #startWorkerAttempt(): Promise<void> {
    this.#restartCancellation?.();
    this.#restartCancellation = undefined;

    const generation = this.#health.workerGeneration + 1;
    this.#rejectStaleWrites(this.#replay.startWorker(generation));
    this.#health = {
      status: "degraded",
      workerGeneration: generation,
    };

    let connection: LocalDataWorkerConnection;
    try {
      connection = this.#host.connect();
    } catch (error) {
      this.#recordStartFailure(error);
      return;
    }

    const active: ActiveConnection = {
      cancelPendingCalls: new Set(),
      connection,
      generation,
      inFlightWrites: 0,
      removeTerminatedListener: () => {},
    };
    active.removeTerminatedListener = connection.onTerminated((error) => {
      this.#handleConnectionLoss(active, error);
    });
    this.#active = active;

    try {
      const opened = await this.#runConnectionCall(
        active,
        "open",
        () =>
          connection.remote.open({
            databasePath: this.#databasePath,
            workerGeneration: generation,
          }),
        this.#openTimeoutMs
      );
      this.#assertOpenResult(opened, generation);
    } catch (error) {
      this.#handleConnectionLoss(active, toError(error));
      return;
    }

    if (this.#closed || this.#active !== active || connection.isTerminated()) {
      return;
    }

    const recovered = this.#recoveryPending;
    this.#recoveryPending = false;
    this.#health = {
      status: "ready",
      workerGeneration: generation,
    };
    this.#lastReadyAt = this.#now();
    this.#ready.resolve();

    if (recovered) {
      for (const listener of this.#recoveredListeners) {
        try {
          listener(generation);
        } catch {
          // Recovery is repository state; one observer cannot roll it back.
        }
      }
    }
    this.#dispatchDirtyWrites();
  }

  #assertOpenResult(opened: LocalDataOpenResult, generation: number): void {
    if (opened.workerGeneration !== generation) {
      throw new Error(
        `Local data worker opened generation ${opened.workerGeneration}; expected ${generation}.`
      );
    }
  }

  #dispatchDirtyWrites(): void {
    const active = this.#active;
    if (
      !active ||
      this.#health.status !== "ready" ||
      active.connection.isTerminated()
    ) {
      return;
    }

    const availableWrites = MAX_CONCURRENT_WRITES - active.inFlightWrites;
    if (availableWrites <= 0) return;

    const pending = this.#replay.takePending(availableWrites);
    this.#rejectStaleWrites(pending.stale);
    for (const request of pending.requests) {
      active.inFlightWrites += 1;
      this.#armWriteDeadline(request.operationId, active);
      void this.#runConnectionCall(active, "applyProductInboxSync", () =>
        active.connection.remote.applyProductInboxSync(request)
      )
        .then((ackValue) => {
          if (
            this.#active !== active ||
            active.connection.isTerminated() ||
            this.#health.status !== "ready"
          ) {
            const settlement = this.#replay.markDispatchFailed(
              request.operationId,
              request.workerGeneration
            );
            if (settlement.status === "stale") {
              this.#rejectStaleWrites([settlement.dirty]);
            }
            return;
          }

          let ack: LocalDataWriteAck;
          try {
            ack = assertLocalDataWriteAck(ackValue);
          } catch {
            this.#handleConnectionLoss(
              active,
              new Error("Local data worker returned an invalid write acknowledgement.")
            );
            return;
          }

          if (
            ack.operationId !== request.operationId ||
            ack.workerGeneration !== active.generation
          ) {
            const settlement = this.#replay.markDispatchFailed(
              request.operationId,
              request.workerGeneration
            );
            if (settlement.status === "stale") {
              this.#rejectStaleWrites([settlement.dirty]);
              return;
            }
            this.#handleConnectionLoss(
              active,
              new Error("Local data worker returned an invalid write acknowledgement.")
            );
            return;
          }

          let settlement: ReturnType<LocalDataDirtyReplayQueue["acceptAck"]>;
          try {
            settlement = this.#replay.acceptAck(ack);
          } catch {
            this.#handleConnectionLoss(
              active,
              new Error("Local data worker returned an invalid write acknowledgement.")
            );
            return;
          }
          if (settlement.status === "stale") {
            this.#rejectStaleWrites([settlement.dirty]);
            return;
          }
          if (settlement.status !== "accepted") return;
          this.#settleWriteWaiter(ack.operationId, { ack });
        })
        .catch((error: unknown) => {
          if (
            this.#active !== active ||
            active.connection.isTerminated() ||
            this.#health.status !== "ready"
          ) {
            const settlement = this.#replay.markDispatchFailed(
              request.operationId,
              request.workerGeneration
            );
            if (settlement.status === "stale") {
              this.#rejectStaleWrites([settlement.dirty]);
            }
            return;
          }

          const settlement = this.#replay.markDispatchFailed(
            request.operationId,
            request.workerGeneration
          );
          if (settlement.status === "stale") {
            this.#rejectStaleWrites([settlement.dirty]);
            return;
          }
          if (settlement.status === "ignored") return;
          this.#replay.discard(request.operationId);
          this.#settleWriteWaiter(request.operationId, { error: toError(error) });
        })
        .finally(() => {
          active.inFlightWrites = Math.max(0, active.inFlightWrites - 1);
          if (
            this.#active === active &&
            this.#health.status === "ready" &&
            !active.connection.isTerminated()
          ) {
            this.#dispatchDirtyWrites();
          }
        });
    }
  }

  #handleConnectionLoss(active: ActiveConnection, error: Error): void {
    if (this.#closed || this.#active !== active) return;

    const wasReady = this.#health.status === "ready";
    if (wasReady) {
      const readyForMs =
        this.#lastReadyAt === undefined ? 0 : this.#now() - this.#lastReadyAt;
      this.#consecutiveStartFailures =
        readyForMs >= RESTART_STABILITY_WINDOW_MS
          ? 0
          : this.#consecutiveStartFailures + 1;
    } else {
      this.#consecutiveStartFailures += 1;
    }
    this.#active = undefined;
    this.#cancelConnectionCalls(active, error);
    active.removeTerminatedListener();
    active.connection.dispose();
    this.#health = {
      error: error.message,
      status: "degraded",
      workerGeneration: active.generation,
    };
    this.#recoveryPending = true;
    if (wasReady) this.#ready = createReadySignal();
    this.#scheduleRestart();
  }

  #rejectStaleWrites(
    dirtyWrites: ReadonlyArray<{
      input: ProductInboxCacheApplyInput;
      operationId: string;
    }>
  ): void {
    for (const dirty of dirtyWrites) {
      const waiter = this.#writeWaiters.get(dirty.operationId);
      if (!waiter) continue;
      this.#settleWriteWaiter(dirty.operationId, {
        error: new LocalDataWriteFailure({
          code: "stale_session_lease",
          session: dirty.input.session,
        }),
      });
    }
  }

  #recordStartFailure(error: unknown): void {
    this.#consecutiveStartFailures += 1;
    this.#health = {
      error: toError(error).message,
      status: "degraded",
      workerGeneration: this.#health.workerGeneration,
    };
    this.#recoveryPending = true;
    this.#scheduleRestart();
  }

  #scheduleRestart(): void {
    if (this.#closed || this.#restartCancellation) return;
    const delayIndex = Math.min(
      Math.max(this.#consecutiveStartFailures - 1, 0),
      this.#restartDelaysMs.length - 1
    );
    const delayMs = this.#restartDelaysMs[delayIndex]!;
    this.#restartCancellation = this.#scheduleRestartImpl(() => {
      this.#restartCancellation = undefined;
      void this.#startWorker();
    }, delayMs);
  }

  async #readyConnection(): Promise<ActiveConnection> {
    await this.#waitUntilReady();
    const active = this.#active;
    if (!active || this.#health.status !== "ready") {
      throw new Error("Local data repository is not ready.");
    }
    return active;
  }

  async #waitUntilReady(): Promise<void> {
    this.#throwIfClosed();
    await this.#runWithDeadline({
      operation: "readiness",
      run: async () => {
        while (this.#health.status !== "ready") {
          const ready = this.#ready;
          await ready.promise;
          this.#throwIfClosed();
        }
      },
      timeoutMs: this.#requestTimeoutMs,
    });
  }

  #runConnectionCall<T>(
    active: ActiveConnection,
    operation: string,
    run: () => Promise<T>,
    timeoutMs = this.#requestTimeoutMs
  ): Promise<T> {
    let cancelPendingCall: (error: Error) => void = noop;
    const result = this.#runWithDeadline({
      onTimeout: (error) => {
        this.#handleConnectionLoss(active, error);
      },
      operation,
      run,
      timeoutMs,
      trackCancellation: (cancel) => {
        cancelPendingCall = cancel;
        active.cancelPendingCalls.add(cancel);
      },
    });
    return result.finally(() => {
      active.cancelPendingCalls.delete(cancelPendingCall);
    });
  }

  #runWithDeadline<T>({
    onTimeout,
    operation,
    run,
    timeoutMs,
    trackCancellation,
  }: {
    onTimeout?: ((error: LocalDataUtilityTimeoutError) => void) | undefined;
    operation: string;
    run: () => Promise<T>;
    timeoutMs: number;
    trackCancellation?: ((cancel: (error: Error) => void) => void) | undefined;
  }): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let settled = false;
      let cancelDeadline = noop;
      const rejectPending = (error: Error) => {
        if (settled) return;
        settled = true;
        cancelDeadline();
        reject(error);
      };
      trackCancellation?.(rejectPending);
      cancelDeadline = this.#scheduleDeadlineImpl(() => {
        if (settled) return;
        settled = true;
        const error = new LocalDataUtilityTimeoutError(operation, timeoutMs);
        onTimeout?.(error);
        reject(error);
      }, timeoutMs);

      let pending: Promise<T>;
      try {
        pending = run();
      } catch (error) {
        settled = true;
        cancelDeadline();
        reject(toError(error));
        return;
      }

      void pending.then(
        (value) => {
          if (settled) return;
          settled = true;
          cancelDeadline();
          resolve(value);
        },
        (error: unknown) => {
          if (settled) return;
          settled = true;
          cancelDeadline();
          reject(toError(error));
        }
      );
    });
  }

  #cancelConnectionCalls(active: ActiveConnection, error: Error): void {
    for (const cancel of active.cancelPendingCalls) cancel(error);
    active.cancelPendingCalls.clear();
  }

  #armWriteDeadline(operationId: string, active: ActiveConnection): void {
    const waiter = this.#writeWaiters.get(operationId);
    if (!waiter) return;

    waiter.cancelDeadline();
    waiter.cancelDeadline = this.#scheduleDeadlineImpl(() => {
      if (this.#writeWaiters.get(operationId) !== waiter) return;

      const error = new LocalDataUtilityTimeoutError(
        "applyProductInboxSync",
        this.#requestTimeoutMs
      );
      this.#settleWriteWaiter(operationId, { error });
      if (this.#active === active && this.#health.status === "ready") {
        this.#handleConnectionLoss(active, error);
      }
    }, this.#requestTimeoutMs);
  }

  #settleWriteWaiter(
    operationId: string,
    settlement: { ack: LocalDataWriteAck } | { error: Error }
  ): void {
    const waiter = this.#writeWaiters.get(operationId);
    if (!waiter) return;

    this.#writeWaiters.delete(operationId);
    waiter.cancelDeadline();
    if ("ack" in settlement) {
      waiter.resolve(settlement.ack);
    } else {
      waiter.reject(settlement.error);
    }
  }

  #throwIfClosed(): void {
    if (this.#closed) {
      throw new Error("Local data repository is closed.");
    }
  }
}

function createReadySignal() {
  let settled = false;
  let resolvePromise = noop;
  const promise = new Promise<void>((resolve) => {
    resolvePromise = resolve;
  });
  return {
    promise,
    resolve() {
      if (settled) return;
      settled = true;
      resolvePromise();
    },
  };
}

function noop() {}

function defaultDeadlineScheduler(expire: () => void, delayMs: number): () => void {
  const timer = setTimeout(expire, delayMs);
  return () => clearTimeout(timer);
}

function defaultRestartScheduler(restart: () => void, delayMs: number): () => void {
  const timer = setTimeout(restart, delayMs);
  return () => clearTimeout(timer);
}

function normalizeRestartDelays(values: readonly number[]): readonly number[] {
  if (values.length === 0) {
    throw new Error("restartDelaysMs must contain at least one delay.");
  }
  return values.map((value, index) =>
    normalizeTimeout(value, `restartDelaysMs[${index}]`)
  );
}

function normalizeTimeout(value: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < 1 || value > 300_000) {
    throw new Error(`${name} must be an integer from 1 to 300000.`);
  }
  return value;
}

function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}
