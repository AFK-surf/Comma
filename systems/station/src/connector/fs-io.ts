// File reads and writes as Effects. A read or write on a pipe or device can block in the kernel for as long as its
// peer wants, as it could in the Go connector; Node runs it on its libuv pool, which the station sizes for that
// (UV_THREADPOOL_SIZE, set in src/main.ts and the test script) so blocked I/O cannot starve other file work.
import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { Effect } from "effect";
import type { Writable } from "./io.ts";

const toError = (e: unknown) => (e instanceof Error ? e : new Error(String(e)));

/** Reads up to `limit` bytes of `path` (a regular file, or a pipe until its writer closes or the limit is reached). */
export function readLimited(path: string, limit: number): Effect.Effect<Buffer, Error> {
  return Effect.tryPromise({
    try: async () => {
      const handle = await open(path, constants.O_RDONLY);
      try {
        const chunks: Buffer[] = [];
        let total = 0;
        const buffer = Buffer.alloc(Math.min(Math.max(limit, 1), 1 << 20));
        while (total < limit) {
          const { bytesRead } = await handle.read(buffer, 0, Math.min(buffer.length, limit - total), null);
          if (bytesRead === 0) break;
          chunks.push(Buffer.from(buffer.subarray(0, bytesRead)));
          total += bytesRead;
        }
        return Buffer.concat(chunks);
      } finally {
        await handle.close();
      }
    },
    catch: toError,
  });
}

/** Opens `path` for writing, truncating or appending, as one Writable. */
export function openWritable(path: string, append: boolean, mode = 0o644): Effect.Effect<Writable, Error> {
  return Effect.tryPromise({
    try: async (): Promise<Writable> => {
      const handle = await open(path, constants.O_CREAT | constants.O_WRONLY | (append ? constants.O_APPEND : constants.O_TRUNC), mode);
      return {
        write: (data) => Effect.tryPromise({ try: () => handle.write(data), catch: toError }),
        close: Effect.promise(() => handle.close().catch(() => {})),
      };
    },
    catch: toError,
  });
}
