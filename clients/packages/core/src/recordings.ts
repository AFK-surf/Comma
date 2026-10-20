// A meeting recording's transcript (`recordings.transcribe`): Main hands over the saved audio (already in Drive), the
// server's ASR answers an event stream, and its `transcription` event is the transcript or why there is none. Main
// writes the result beside the audio; a failure never changes the audio. There is no queue and no automatic replay.
// Quick Chat's words use the same call with a `purpose`: `"dictation"` for the audio before a pause, `"quick_chat_send"`
// for the audio of a send. Their transcript is plain text, and a Task waits for it, so it is given up much sooner.
//
// Bounds: at most two recordings in flight per device (a third fails at once), and apart from them three dictations,
// which are small and short: a Quick Chat asks about at most two pauses at once (a third fails at once), and a send
// waits for its turn, so the sends waiting number at most the Returns under way. Audio up to 30 MiB; one request each,
// given up after a little over ten minutes (dictation: 10 s, the wait included).
import { CoreError } from "@comma/core-kernel";
import { Effect, Option, Semaphore } from "effect";
import { z } from "zod";
import type { Ctx } from "./ctx.ts";
import { readEvents } from "./sse.ts";

const PATH = "/v1/comma/me/recordings/transcribe";
export const MAX_TRANSCRIBED_BYTES = 30 * 1024 * 1024;
const MAX_IN_FLIGHT = 2;
const MAX_DICTATIONS_IN_FLIGHT = 3;
const TRANSCRIBE_TIMEOUT_MS = 620_000;
const DICTATION_TIMEOUT_MS = 10_000;

const transcriptSchema = z.object({
  transcript: z.string().max(8_000_000),
  duration_seconds: z.number().int().nonnegative(),
  chunks: z
    .array(
      z.object({
        index: z.number().int().nonnegative(),
        offset_seconds: z.number().nonnegative(),
        transcript: z.string().max(8_000_000),
      })
    )
    .max(48),
});
const transcriptionSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("ready"), result: transcriptSchema }),
  z.object({ status: z.literal("error"), reason: z.string().max(500) }),
]);

export type Transcript = z.infer<typeof transcriptSchema>;

/** Why there is no transcript, as Main writes it beside the audio. */
const unavailable = (message: string) => new CoreError("transcription_failed", message);

export class Recordings {
  /** Transcriptions in flight: one permit each, never waited for (a third fails at once). */
  readonly #inFlight = Semaphore.makeUnsafe(MAX_IN_FLIGHT);
  /** Dictations in flight: a pause's fails at once without a permit, a send's waits for one. */
  readonly #dictating = Semaphore.makeUnsafe(MAX_DICTATIONS_IN_FLIGHT);

  constructor(ctx: Ctx) {
    ctx.kernel.calls({
      "recordings.transcribe": {
        run: (p) => {
          const { audio, purpose } = (p ?? {}) as {
            audio?: unknown;
            purpose?: unknown;
          };
          if (!(audio instanceof Uint8Array) || audio.length === 0)
            throw CoreError.invalid("audio is required");
          if (
            purpose !== undefined &&
            purpose !== "dictation" &&
            purpose !== "quick_chat_send"
          )
            throw CoreError.invalid("purpose is not known");
          if (audio.length > MAX_TRANSCRIBED_BYTES)
            return Effect.fail(
              unavailable(
                "ASR accepts recordings up to 30 MiB. The audio remains in Drive."
              )
            );
          const dictation = purpose !== undefined;
          const transcript = transcribe(ctx, audio, dictation);
          const admitted =
            purpose === "quick_chat_send"
              ? transcript.pipe(this.#dictating.withPermits(1))
              : transcript.pipe(
                  (dictation ? this.#dictating : this.#inFlight).withPermitsIfAvailable(
                    1
                  ),
                  Effect.flatMap(
                    Option.match({
                      onNone: () =>
                        Effect.fail(
                          unavailable(
                            "Transcription is busy. The audio remains in Drive."
                          )
                        ),
                      onSome: Effect.succeed,
                    })
                  )
                );
          return admitted.pipe(
            Effect.timeoutOrElse({
              duration: dictation ? DICTATION_TIMEOUT_MS : TRANSCRIBE_TIMEOUT_MS,
              orElse: () =>
                Effect.fail(
                  unavailable(
                    "Transcription took too long. The audio remains in Drive."
                  )
                ),
            })
          );
        },
      },
    });
  }
}

function transcribe(
  ctx: Ctx,
  audio: Uint8Array,
  dictation: boolean
): Effect.Effect<Transcript, CoreError> {
  return Effect.scoped(
    Effect.gen(function* () {
      const account = yield* ctx.session.account();
      const body = yield* ctx.api
        .stream(account, dictation ? `${PATH}?purpose=dictation` : PATH, {
          method: "POST",
          contentType: "audio/mp4",
          body: audio,
        })
        .pipe(
          Effect.mapError(() =>
            unavailable("Transcription is unavailable. The audio remains in Drive.")
          )
        );
      // The first transcription event is the answer: the stream is let go then (`taken`, carrying it). A stream that
      // ends or breaks before one has none.
      const result = yield* readEvents(body, (value, event) => {
        if (event !== "transcription") return Effect.void;
        const parsed = transcriptionSchema.safeParse(value);
        return Effect.fail(
          parsed.success
            ? new CoreError("taken", "", undefined, parsed.data)
            : unavailable(
                "Transcription answered unexpectedly. The audio remains in Drive."
              )
        );
      }).pipe(
        Effect.as(null),
        Effect.catch((e) =>
          e.code === "taken"
            ? Effect.succeed(e.detail as z.infer<typeof transcriptionSchema>)
            : e.code === "transcription_failed"
              ? Effect.fail(e)
              : Effect.succeed(null)
        )
      );
      if (!result)
        return yield* Effect.fail(
          unavailable("Transcription was interrupted. The audio remains in Drive.")
        );
      if (result.status === "error")
        return yield* Effect.fail(unavailable(result.reason));
      return result.result;
    })
  );
}
