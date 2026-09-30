import { openAsBlob } from "node:fs";
import { createParser } from "eventsource-parser";
import { z } from "zod";
import type { AudioCaptureRecording } from "@comma/native-bridge";
import type { DriveRecordingStore, RecordingDriveTarget } from "./drive-recordings";

const transcriptResult = z.discriminatedUnion("status", [
  z.object({
    status: z.literal("ready"),
    result: z.object({
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
    }),
  }),
  z.object({ status: z.literal("error"), reason: z.string().max(500) }),
]);

export interface RecordingASRSession {
  fetch: typeof fetch;
  url: URL;
  assertCurrent(): void;
}

/** Audio is already in Drive. ASR failures cannot change its saved receipt. */
export class RecordingTranscriptionService {
  #active = 0;
  constructor(
    private readonly drive: Pick<DriveRecordingStore, "writeTranscript">,
    private readonly bindSession: () => RecordingASRSession
  ) {}

  async process(
    recording: AudioCaptureRecording,
    target: RecordingDriveTarget,
    sourcePath: string
  ): Promise<void> {
    const session = this.bindSession();
    let admitted = false;
    try {
      // At most two ASR requests per client, with no queue or automatic replay.
      if (this.#active >= 2)
        throw new Error("Transcription is busy. The audio remains in Drive.");
      admitted = true;
      this.#active++;
      if (recording.file.size > 30 * 1024 * 1024)
        throw new Error(
          "ASR accepts recordings up to 30 MiB. The audio remains in Drive."
        );
      const result = await transcribeRecording(session, sourcePath);
      session.assertCurrent();
      await this.drive.writeTranscript(recording, target, "txt", result.transcript);
      session.assertCurrent();
      await this.drive.writeTranscript(
        recording,
        target,
        "json",
        JSON.stringify(
          {
            status: "ready",
            source: recording.driveFile,
            ...result,
          },
          null,
          2
        )
      );
    } catch (error) {
      session.assertCurrent();
      await this.drive.writeTranscript(
        recording,
        target,
        "json",
        JSON.stringify(
          {
            status: "error",
            source: recording.driveFile,
            reason:
              error instanceof Error
                ? error.message.slice(0, 500)
                : "Transcription failed. The audio remains in Drive.",
          },
          null,
          2
        )
      );
    } finally {
      if (admitted) this.#active--;
    }
  }
}

async function transcribeRecording(session: RecordingASRSession, sourcePath: string) {
  const response = await session.fetch(session.url, {
    method: "POST",
    headers: { "content-type": "audio/mp4", accept: "text/event-stream" },
    body: await openAsBlob(sourcePath, { type: "audio/mp4" }),
    signal: AbortSignal.timeout(620_000),
  });
  if (!response.ok || !response.body)
    throw new Error("Transcription is unavailable. The audio remains in Drive.");
  let result: z.infer<typeof transcriptResult> | undefined;
  const parser = createParser({
    maxBufferSize: 16 * 1024 * 1024,
    onEvent(event) {
      if (event.event === "transcription")
        result = transcriptResult.parse(JSON.parse(event.data));
    },
    onError(error) {
      throw error;
    },
  });
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      parser.feed(decoder.decode(value, { stream: true }));
      if (result) break;
    }
    parser.feed(decoder.decode());
  } finally {
    await reader.cancel().catch(() => undefined);
    reader.releaseLock();
  }
  if (!result)
    throw new Error("Transcription was interrupted. The audio remains in Drive.");
  if (result.status === "error") throw new Error(result.reason);
  return result.result;
}
