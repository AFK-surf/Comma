// A request id names one operation across connection replacements. A running operation replies on whichever
// connection holds it last; a completed one replays its reply (except ceremony replies, which only keep a tombstone so
// a retry executes again behind the auth coordinator's own fence). Completed replies are bounded by age, count and
// size. The same id with other method or params is refused.
import { createHash } from "node:crypto";
import type { Message } from "./message.ts";

export const REQUEST_REPLAY_TTL_MS = 2 * 60_000;
export const REQUEST_REPLAY_MAX_ENTRIES = 256;
export const REQUEST_REPLAY_MAX_BYTES = 32 * 1024 * 1024;

export type RequestBinding = "rejected" | "execute" | "rebound" | "reply";

export type RequestOperation<S> = {
  fingerprint: string;
  sink: S | null;
  reply: Message | null;
  replyBytes: number;
  completedAt: number;
  done: boolean;
  replayCompleted: boolean;
};

/** Requests whose reply belongs to one connection (streams, tunnels) are never rebound or replayed. */
export function recoverableRequest(msg: Message): boolean {
  return (
    !!msg.id &&
    msg.method !== "read_stream" &&
    msg.method !== "read_ref" &&
    msg.method !== "write_stream" &&
    msg.method !== "meeting_artifact_read" &&
    msg.method !== "lan_tcp_dial"
  );
}

/** Method and params, hashed; params are encoded as Go's json.Marshal did (sorted object keys). */
export function requestFingerprint(msg: Message): string {
  return createHash("sha256")
    .update(`${msg.method ?? ""}\0${canonicalJson(msg.params ?? null)}`)
    .digest("hex");
}

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    const keys = Object.keys(value as object).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson((value as Record<string, unknown>)[k])}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

/** Device-code start replies carry a one-time code: never replayed once the attempt may be terminal. */
export const replayCompletedRequest = (method: string) => method !== "runtime_auth_login_start";

/** A cheap upper bound of a reply's retained size: strings and bytes dominate; containers count their members. */
export function estimateReplyBytes(reply: Message): number {
  const base = (reply.id?.length ?? 0) + (reply.type?.length ?? 0) + (reply.error?.length ?? 0);
  return base + estimateValueBytes(reply.result, REQUEST_REPLAY_MAX_BYTES - base, 0);
}

function estimateValueBytes(value: unknown, remaining: number, depth: number): number {
  if (value === undefined || value === null || remaining <= 0) return 0;
  if (depth > 64) return remaining + 1;
  if (typeof value === "string") return value.length;
  if (value instanceof Uint8Array) return value.length;
  if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") return 8;
  if (Array.isArray(value)) {
    let total = 0;
    for (let i = 0; i < value.length && total <= remaining; i++) total += estimateValueBytes(value[i], remaining - total, depth + 1);
    return total;
  }
  if (typeof value === "object") {
    let total = 0;
    for (const [key, member] of Object.entries(value as object)) {
      if (total > remaining) break;
      total += key.length + estimateValueBytes(member, remaining - total - key.length, depth + 1);
    }
    return total;
  }
  return 16;
}

export function boundedReplayReply(id: string, method: string, reply: Message): { reply: Message; bytes: number } {
  const bytes = estimateReplyBytes(reply);
  if (bytes <= REQUEST_REPLAY_MAX_BYTES) return { reply, bytes: Math.max(bytes, 1) };
  const refused: Message = { id, type: "error", error: `${method}: response exceeds connector replay limit` };
  return { reply: refused, bytes: estimateReplyBytes(refused) };
}

/** The operations table. `takeSlot` admits an execution or a reply; the caller holds the connection checks. */
export function makeRequestOperations<S>(nowMs: () => number) {
  const operations = new Map<string, RequestOperation<S>>();
  let replayBytes = 0;

  const remove = (id: string, operation: RequestOperation<S>) => {
    operations.delete(id);
    replayBytes = Math.max(0, replayBytes - operation.replyBytes);
  };

  const prune = (now: number, keepId: string) => {
    for (const [id, operation] of operations) if (operation.done && now - operation.completedAt >= REQUEST_REPLAY_TTL_MS) remove(id, operation);
    const completed = () => [...operations.values()].filter((o) => o.done).length;
    while (replayBytes > REQUEST_REPLAY_MAX_BYTES || completed() > REQUEST_REPLAY_MAX_ENTRIES) {
      let oldest: [string, RequestOperation<S>] | undefined;
      for (const entry of operations) {
        if (entry[0] === keepId || !entry[1].done) continue;
        if (!oldest || entry[1].completedAt < oldest[1].completedAt) oldest = entry;
      }
      if (!oldest) break;
      remove(oldest[0], oldest[1]);
    }
  };

  const fresh = (fingerprint: string, sink: S): RequestOperation<S> => ({ fingerprint, sink, reply: null, replyBytes: 0, completedAt: 0, done: false, replayCompleted: false });

  return {
    /** Decides what a request with this id does on `sink`. */
    bind(sink: S, msg: Message, fingerprint: string, takeSlot: () => boolean): { binding: RequestBinding; reply?: Message } {
      prune(nowMs(), "");
      const id = msg.id!;
      const operation = operations.get(id);
      if (operation) {
        if (operation.fingerprint !== fingerprint) {
          if (!takeSlot()) return { binding: "rejected" };
          return { binding: "reply", reply: { id, type: "error", error: "request id reused with different method or params" } };
        }
        if (operation.done) {
          if (!takeSlot()) return { binding: "rejected" };
          if (operation.replayCompleted && operation.reply) return { binding: "reply", reply: operation.reply };
          operations.set(id, fresh(fingerprint, sink));
          return { binding: "execute" };
        }
        operation.sink = sink;
        return { binding: "rebound" };
      }
      if (!takeSlot()) return { binding: "rejected" };
      operations.set(id, fresh(fingerprint, sink));
      return { binding: "execute" };
    },
    /** Records the reply and returns the sink to deliver it to (null when the operation is unknown or already done). */
    complete(id: string, method: string, reply: Message): { sink: S | null; reply: Message } | null {
      const replay = replayCompletedRequest(method);
      let stored = reply;
      let bytes = 0;
      if (replay) ({ reply: stored, bytes } = boundedReplayReply(id, method, reply));
      const operation = operations.get(id);
      if (!operation || operation.done) return null;
      operation.done = true;
      operation.replayCompleted = replay;
      if (replay) {
        operation.reply = stored;
        operation.replyBytes = bytes;
      }
      operation.completedAt = nowMs();
      replayBytes += bytes;
      const sink = operation.sink;
      prune(operation.completedAt, id);
      return { sink, reply: stored };
    },
    get: (id: string) => operations.get(id) ?? null,
  };
}
