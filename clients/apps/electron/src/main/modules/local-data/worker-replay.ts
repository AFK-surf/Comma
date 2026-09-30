import { Buffer } from "node:buffer";
import {
  LocalDataWriteFailure,
  assertProductInboxCacheApplyInput,
  isLocalDataWorkerGeneration,
  type LocalDataWriteAck,
  type LocalDataWriteRequest,
  type ProductInboxCacheApplyInput,
} from "../../../shared/local-data";
import {
  sameSessionProductLease,
  type SessionProductLease,
} from "@comma/session-contract";

export interface DirtyLocalDataWrite {
  dispatchedWorkerGeneration?: number | undefined;
  input: ProductInboxCacheApplyInput;
  operationId: string;
  serializedBytes: number;
}

export type LocalDataAckSettlement =
  | { status: "accepted" }
  | { status: "ignored" }
  | { dirty: DirtyLocalDataWrite; status: "stale" };

export interface LocalDataDirtyReplayQueueOptions {
  maxDirtyBytes?: number | undefined;
  maxDirtyOperations?: number | undefined;
}

const DEFAULT_MAX_DIRTY_BYTES = 16 * 1024 * 1024;
const DEFAULT_MAX_DIRTY_OPERATIONS = 64;

/**
 * Main-owned, in-memory dirty-write queue for one utility-process lifetime.
 * It never invents a new persistence mode or relabels a late ack as belonging
 * to a replacement worker.
 */
export class LocalDataDirtyReplayQueue {
  readonly #dirty = new Map<string, DirtyLocalDataWrite>();
  readonly #isCurrentSessionLease: (lease: SessionProductLease) => boolean;
  readonly #maxDirtyBytes: number;
  readonly #maxDirtyOperations: number;
  #dirtyBytes = 0;
  #workerGeneration = 0;

  constructor(
    isCurrentSessionLease: (lease: SessionProductLease) => boolean,
    {
      maxDirtyBytes = DEFAULT_MAX_DIRTY_BYTES,
      maxDirtyOperations = DEFAULT_MAX_DIRTY_OPERATIONS,
    }: LocalDataDirtyReplayQueueOptions = {}
  ) {
    this.#isCurrentSessionLease = isCurrentSessionLease;
    this.#maxDirtyBytes = positiveSafeInteger(maxDirtyBytes, "maxDirtyBytes");
    this.#maxDirtyOperations = positiveSafeInteger(
      maxDirtyOperations,
      "maxDirtyOperations"
    );
  }

  get size() {
    return this.#dirty.size;
  }

  get serializedBytes() {
    return this.#dirtyBytes;
  }

  get workerGeneration() {
    return this.#workerGeneration;
  }

  enqueue(operationId: string, input: ProductInboxCacheApplyInput): void {
    if (typeof operationId !== "string" || !operationId.trim()) {
      throw new Error("Local data operationId must not be empty.");
    }
    if (this.#dirty.has(operationId)) {
      throw new Error(`Local data operation ${operationId} already exists.`);
    }
    assertProductInboxCacheApplyInput(input);
    this.#assertCurrent(input.session);
    if (this.#dirty.size >= this.#maxDirtyOperations) {
      throw new Error(
        `Local data dirty replay queue reached its operation limit (${this.#maxDirtyOperations}).`
      );
    }

    const serializedInput = JSON.stringify(input);
    const serializedBytes =
      Buffer.byteLength(operationId, "utf8") +
      Buffer.byteLength(serializedInput, "utf8");
    if (this.#dirtyBytes + serializedBytes > this.#maxDirtyBytes) {
      throw new Error(
        `Local data dirty replay queue reached its serialized-byte limit (${this.#maxDirtyBytes}).`
      );
    }

    this.#dirty.set(operationId, {
      input: structuredClone(input),
      operationId,
      serializedBytes,
    });
    this.#dirtyBytes += serializedBytes;
  }

  startWorker(workerGeneration: number): DirtyLocalDataWrite[] {
    if (!isLocalDataWorkerGeneration(workerGeneration)) {
      throw new Error("Local data workerGeneration must be a positive safe integer.");
    }
    if (workerGeneration <= this.#workerGeneration) {
      throw new Error("Local data workerGeneration must advance on restart.");
    }

    const stale = this.#discardStale();
    this.#workerGeneration = workerGeneration;
    for (const dirty of this.#dirty.values()) {
      dirty.dispatchedWorkerGeneration = undefined;
    }
    return stale;
  }

  takePending(maxRequests = Number.MAX_SAFE_INTEGER): {
    requests: LocalDataWriteRequest[];
    stale: DirtyLocalDataWrite[];
  } {
    if (!isLocalDataWorkerGeneration(this.#workerGeneration)) {
      throw new Error("Local data worker has not started.");
    }
    positiveSafeInteger(maxRequests, "maxRequests");

    const stale = this.#discardStale();
    const requests: LocalDataWriteRequest[] = [];
    for (const dirty of this.#dirty.values()) {
      if (requests.length >= maxRequests) break;
      if (dirty.dispatchedWorkerGeneration !== undefined) continue;
      dirty.dispatchedWorkerGeneration = this.#workerGeneration;
      requests.push({
        input: structuredClone(dirty.input),
        operationId: dirty.operationId,
        workerGeneration: this.#workerGeneration,
      });
    }
    return { requests, stale };
  }

  markDispatchFailed(
    operationId: string,
    workerGeneration: number
  ): LocalDataAckSettlement {
    const dirty = this.#dirty.get(operationId);
    if (!dirty || dirty.dispatchedWorkerGeneration !== workerGeneration) {
      return { status: "ignored" };
    }
    if (!this.#isCurrentSessionLease(dirty.input.session)) {
      this.#remove(operationId);
      return { dirty: structuredClone(dirty), status: "stale" };
    }
    dirty.dispatchedWorkerGeneration = undefined;
    return { status: "accepted" };
  }

  acceptAck(ack: LocalDataWriteAck): LocalDataAckSettlement {
    if (ack.workerGeneration !== this.#workerGeneration) {
      return { status: "ignored" };
    }
    const dirty = this.#dirty.get(ack.operationId);
    if (!dirty || dirty.dispatchedWorkerGeneration !== ack.workerGeneration) {
      return { status: "ignored" };
    }
    if (!this.#isCurrentSessionLease(dirty.input.session)) {
      this.#remove(ack.operationId);
      return { dirty: structuredClone(dirty), status: "stale" };
    }
    if (!sameSessionProductLease(ack.session, dirty.input.session)) {
      throw new Error("Local data write acknowledgement changed its session lease.");
    }

    this.#remove(ack.operationId);
    return { status: "accepted" };
  }

  discard(operationId: string): boolean {
    return this.#remove(operationId) !== undefined;
  }

  #assertCurrent(session: SessionProductLease): void {
    if (this.#isCurrentSessionLease(session)) return;
    throw new LocalDataWriteFailure({
      code: "stale_session_lease",
      session,
    });
  }

  #discardStale(): DirtyLocalDataWrite[] {
    const stale: DirtyLocalDataWrite[] = [];
    for (const [operationId, dirty] of this.#dirty) {
      if (this.#isCurrentSessionLease(dirty.input.session)) continue;
      this.#remove(operationId);
      stale.push(structuredClone(dirty));
    }
    return stale;
  }

  #remove(operationId: string): DirtyLocalDataWrite | undefined {
    const dirty = this.#dirty.get(operationId);
    if (!dirty) return undefined;
    this.#dirty.delete(operationId);
    this.#dirtyBytes -= dirty.serializedBytes;
    return dirty;
  }
}

function positiveSafeInteger(value: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new Error(`${name} must be a positive safe integer.`);
  }
  return value;
}
