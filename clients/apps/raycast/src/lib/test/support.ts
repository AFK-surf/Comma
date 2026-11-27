import type { Fetch } from "../api";
import type { KeyValueStore } from "../store";

export function memoryStore(): KeyValueStore & { values: Map<string, string> } {
  const values = new Map<string, string>();
  return {
    values,
    get: (key) => Promise.resolve(values.get(key)),
    set: (key, value) => Promise.resolve(void values.set(key, value)),
    remove: (key) => Promise.resolve(void values.delete(key)),
  };
}

export interface Seen {
  method: string;
  path: string;
  headers: Record<string, string>;
  body: unknown;
  signal: AbortSignal | undefined;
}

/** A Comma API answered from `answers`, by `METHOD path` (the path without its query). */
export function fakeServer(
  origin: string,
  answers: Record<string, (seen: Seen) => { status: number; body?: unknown }>
) {
  const seen: Seen[] = [];
  const fetch: Fetch = (url, init) => {
    if (!url.startsWith(origin)) throw new Error(`request left the origin: ${url}`);
    const path = url.slice(origin.length);
    const request = {
      method: init.method,
      path,
      headers: init.headers,
      body: init.body === undefined ? undefined : JSON.parse(init.body),
      signal: init.signal,
    };
    seen.push(request);
    const answer = answers[`${init.method} ${path.split("?")[0]}`]?.(request) ?? {
      status: 404,
    };
    return Promise.resolve({
      status: answer.status,
      json: () => Promise.resolve(answer.body ?? {}),
    });
  };
  return { fetch, seen };
}
