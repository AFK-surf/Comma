// The readers: worker threads, each with its own read-only connection; a read goes to the one with the least to do, so
// a heavy one (a long chat list) holds up no other request and no writes. A reader is a V8 of its own (tens of MB), so
// they are started when reads come and let go once none has come for a while: an idle station keeps none. One that
// dies (its heap is bounded) fails what it held and is replaced by the next read.
import { availableParallelism } from "node:os";
import { Worker } from "node:worker_threads";
import { log } from "../ops/log.ts";
import type { Answer, Ask } from "./worker.ts";
import { HttpError } from "./views.ts";
import { wall } from "../ops/fibers.ts";

/// How long a reader with nothing to do is kept.
const IDLE_MS = 60_000;

/// `held`: the reads it is answering, by id, with their ops (said when it fails).
type Slot = { worker: Worker; busy: number; held: Map<number, string>; idle?: () => void };

export class Readers {
  private slots: Slot[] = [];
  private waiting = new Map<number, { resolve: (text: string) => void; reject: (error: Error) => void }>();
  private next = 0;
  private closed = false;
  private readonly data: string;
  private readonly size: number;
  /// People's names as their credentials say them (the admin API's `deps.names`), given to every read.
  readonly names = new Map<string, string>();
  /// What only the hub knows, given to every read: sessions' process states and client keys (the hub sets these).
  processes: () => Map<string, string> = () => new Map();
  clientKeys: () => Map<string, string> = () => new Map();

  /// At most two by default (STILLFAIL_READERS says otherwise).
  constructor(data: string, size = Number(process.env.STILLFAIL_READERS) || Math.min(2, Math.max(1, availableParallelism() - 1))) {
    this.data = data;
    this.size = size;
  }

  private start(): Slot {
    // From source: worker.ts beside this; bundled (this inside dist/main.js): dist/read/worker.js.
    const file = new URL(import.meta.url.endsWith(".ts") ? "./worker.ts" : "./read/worker.js", import.meta.url);
    // A reader's heap stays small: what it builds is answered and dropped.
    const worker = new Worker(file, { workerData: { data: this.data }, resourceLimits: { maxOldGenerationSizeMb: 128, maxYoungGenerationSizeMb: 8 } });
    const slot: Slot = { worker, busy: 0, held: new Map() };
    worker.on("message", (answer: Answer) => {
      slot.busy--;
      slot.held.delete(answer.id);
      if (slot.busy === 0) this.letGoLater(slot);
      const waiter = this.waiting.get(answer.id);
      this.waiting.delete(answer.id);
      if (!waiter) return;
      if (answer.text !== undefined) waiter.resolve(answer.text);
      else waiter.reject(new HttpError(answer.status ?? 500, answer.error ?? "read failed"));
    });
    worker.on("error", (error) => log.error("readers", "a reader failed", { error: error.message, reading: [...slot.held.values()] }));
    worker.on("exit", (code) => {
      slot.idle?.();
      this.slots = this.slots.filter((s) => s !== slot);
      for (const id of slot.held.keys()) {
        this.waiting.get(id)?.reject(new HttpError(500, `the reader stopped (exit ${code})`));
        this.waiting.delete(id);
      }
    });
    this.slots.push(slot);
    return slot;
  }

  private letGoLater(slot: Slot) {
    slot.idle?.();
    // A thread's resources: the machine's time.
    slot.idle = wall.after(IDLE_MS, () => {
      if (slot.busy === 0) void slot.worker.terminate();
    });
  }

  /// The answer, as JSON text.
  read(op: string, args: unknown, lang: Ask["lang"]): Promise<string> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    const free = this.slots.find((s) => s.busy === 0);
    const slot = free ?? (this.slots.length < this.size ? this.start() : this.slots.reduce((a, b) => (b.busy < a.busy ? b : a)));
    slot.idle?.();
    const id = this.next++;
    slot.busy++;
    slot.held.set(id, op);
    return new Promise((resolve, reject) => {
      this.waiting.set(id, { resolve, reject });
      slot.worker.postMessage({ id, op, args, lang, names: [...this.names], processes: [...this.processes()], clientKeys: [...this.clientKeys()] } satisfies Ask);
    });
  }

  close() {
    this.closed = true;
    for (const { worker } of this.slots) void worker.terminate();
  }
}
