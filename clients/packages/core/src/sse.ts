// Server-sent events as the core reads them: each event's `data` lines joined and parsed as JSON, with its `event`
// name when it has one. Comments, `id` and `retry` lines are not used by any stream the core reads.
import { CoreError } from "@comma/core-kernel";
import { Effect } from "effect";
import type { Pull } from "./host.ts";

/** Reads `body` to its end, calling `onEvent` with each event's data; a frame that is no JSON fails the stream. */
export function readEvents(
  body: Pull<Uint8Array>,
  onEvent: (value: unknown, event: string | undefined) => Effect.Effect<void, CoreError>
): Effect.Effect<void, CoreError> {
  return Effect.gen(function* () {
    const decoder = new TextDecoder();
    let buffer = "";
    for (;;) {
      const piece = yield* body.take.pipe(
        Effect.mapError((e) => new CoreError("network", e.message))
      );
      buffer +=
        piece === null ? decoder.decode() : decoder.decode(piece, { stream: true });
      for (;;) {
        const boundary = /\r?\n\r?\n/.exec(buffer);
        if (!boundary) break;
        const frame = buffer.slice(0, boundary.index);
        buffer = buffer.slice(boundary.index + boundary[0].length);
        const lines = frame.split(/\r?\n/);
        const data = lines
          .filter((line) => line.startsWith("data:"))
          .map((line) => line.slice(5).trimStart());
        const event = lines
          .findLast((line) => line.startsWith("event:"))
          ?.slice(6)
          .trim();
        if (data.length === 0) continue;
        const value = yield* Effect.try({
          try: (): unknown => JSON.parse(data.join("\n")),
          catch: () => new CoreError("bad_response", "an event was not JSON"),
        });
        yield* onEvent(value, event || undefined);
      }
      if (piece === null) return;
    }
  });
}
