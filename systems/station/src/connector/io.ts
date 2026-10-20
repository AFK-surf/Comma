// Files and closables as Effects. Callers may hand over an Effect-style object ({ write(data), close }) or a Node
// FileHandle; both become the same `Writable`.
import { Effect } from "effect";

export type Closer = { readonly close: Effect.Effect<void> };
export type Writable = Closer & { write(data: Uint8Array): Effect.Effect<unknown, Error> };

type NodeHandle = { write(data: Uint8Array | string): Promise<unknown>; close(): Promise<void> };

const isEffect = (value: unknown): value is Effect.Effect<unknown, unknown> => Effect.isEffect(value);

export function toCloser(value: unknown): Closer {
  const object = value as { close?: unknown };
  if (isEffect(object.close)) return object as Closer;
  if (typeof object.close === "function") {
    const handle = object as { close(): Promise<void> | void };
    return { close: Effect.promise(async () => void (await handle.close())).pipe(Effect.ignore) };
  }
  return { close: Effect.void };
}

export function toWritable(value: unknown): Writable {
  const object = value as { write?: unknown; close?: unknown };
  if (isEffect(object.close) && typeof object.write === "function") return object as Writable;
  const handle = value as NodeHandle;
  return {
    write: (data) => Effect.tryPromise({ try: () => handle.write(data), catch: (e) => (e instanceof Error ? e : new Error(String(e))) }),
    close: toCloser(handle).close,
  };
}
