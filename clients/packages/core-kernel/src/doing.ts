// What a person set going on this device and the core has not finished (the `doing` topic): every call that changes
// something, from the moment it is asked until its answer. One that failed stays a few seconds more, with why, so the
// control it was asked from can say so where it is.
import type { ErrorBody } from "./error.ts";

type Entry = {
  id: number;
  call: string;
  params: Map<string, string>;
  since: number;
  failed: ErrorBody | null;
};

/// How long a failure stays where it was asked.
export const FAILED_SHOWN_MS = 6_000;

export type DoingItem = {
  call: string;
  /// The call's scalar params, as text (what a control matches itself by).
  params: Record<string, string>;
  since: number;
  stage: "running" | "failed";
  error?: ErrorBody;
};

export class Doing {
  #next = 0;
  #list: Entry[] = [];

  /// One begun; `end` it, or `fail` it, with what this gives.
  start(call: string, params: unknown, now: number): number {
    const id = ++this.#next;
    const plain = new Map<string, string>();
    if (params !== null && typeof params === "object" && !Array.isArray(params)) {
      for (const [k, v] of Object.entries(params)) {
        if (
          typeof v === "string" ||
          typeof v === "boolean" ||
          (typeof v === "number" && Number.isFinite(v))
        )
          plain.set(k, String(v));
      }
    }
    this.#list.push({ id, call, params: plain, since: now, failed: null });
    return id;
  }

  end(id: number): void {
    this.#list = this.#list.filter((e) => e.id !== id);
  }

  fail(id: number, why: ErrorBody): void {
    const e = this.#list.find((item) => item.id === id);
    if (e) e.failed = why;
  }

  /// The topic's value: what is under way, oldest first.
  value(): { doing: DoingItem[] } {
    return {
      doing: this.#list.map((e) => {
        const item: DoingItem = {
          call: e.call,
          params: Object.fromEntries(e.params),
          since: Math.trunc(e.since),
          stage: e.failed ? "failed" : "running",
        };
        if (e.failed) item.error = e.failed;
        return item;
      }),
    };
  }
}
