import { readFile } from "node:fs/promises";
import type { AudioCaptureRecording } from "@comma/native-bridge";
import type { RecordingTranscript } from "@comma/core/contract";
import type { DriveRecordingStore, RecordingDriveTarget } from "./drive-recordings";

/** The client core's transcription (`recordings.transcribe`): the audio's transcript, or why there is none. */
export type TranscribeRecording = (audio: Uint8Array) => Promise<RecordingTranscript>;

export interface RecordingTranscriptSession {
  /** Fails once the account the recording was made under is no longer the session's. */
  assertCurrent(): void;
}

/**
 * Audio is already in Drive. Main hands its bytes to the client core, which asks the server's ASR (and bounds how many
 * at once), and writes what it answers beside the audio: the text and a JSON receipt, or a JSON error. ASR failures
 * cannot change the saved audio.
 */
export class RecordingTranscriptionService {
  constructor(
    private readonly drive: Pick<DriveRecordingStore, "writeTranscript">,
    private readonly bindSession: () => RecordingTranscriptSession,
    private readonly transcribe: TranscribeRecording
  ) {}

  async process(
    recording: AudioCaptureRecording,
    target: RecordingDriveTarget,
    sourcePath: string
  ): Promise<void> {
    const session = this.bindSession();
    try {
      const result = await this.transcribe(new Uint8Array(await readFile(sourcePath)));
      session.assertCurrent();
      await this.drive.writeTranscript(recording, target, "txt", result.transcript);
      session.assertCurrent();
      await this.drive.writeTranscript(
        recording,
        target,
        "json",
        JSON.stringify(
          { status: "ready", source: recording.driveFile, ...result },
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
              error instanceof Error && error.message
                ? error.message.slice(0, 500)
                : "Transcription failed. The audio remains in Drive.",
          },
          null,
          2
        )
      );
    }
  }
}
