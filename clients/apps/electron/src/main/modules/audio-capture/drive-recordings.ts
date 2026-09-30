import { realpath, stat } from "node:fs/promises";
import { basename, isAbsolute, join, relative } from "node:path";
import {
  audioCaptureDriveFileSchema,
  type AudioCaptureDriveFile,
  type AudioCaptureOpenSavedResult,
  type AudioCaptureRecording,
} from "@comma/native-bridge";
import type { SynchronicityProvider } from "../synchronicity";
import { resolveLocalDriveTarget } from "../synchronicity/local-path";

export interface RecordingDriveTarget {
  localRoot: string;
  space: string;
}

export interface AudioCaptureDriveStore {
  target(): Promise<RecordingDriveTarget>;
  save(
    sourcePath: string,
    target: RecordingDriveTarget,
    startedAtMs: number
  ): Promise<Pick<AudioCaptureRecording, "file" | "driveFile">>;
  open(driveFile: AudioCaptureDriveFile): Promise<AudioCaptureOpenSavedResult>;
}

/** Main-owned files never pass through a renderer blob or its 10 MB upload cap. */
export class DriveRecordingStore implements AudioCaptureDriveStore {
  constructor(
    private readonly drive: Pick<
      SynchronicityProvider,
      "state" | "importFile" | "write"
    >,
    private readonly openPath: (path: string) => Promise<string>
  ) {}

  async target(): Promise<RecordingDriveTarget> {
    return resolveLocalDriveTarget(this.drive);
  }

  async save(sourcePath: string, target: RecordingDriveTarget, startedAtMs: number) {
    const { size } = await stat(sourcePath);
    const current = await this.target();
    if (current.space !== target.space || current.localRoot !== target.localRoot) {
      throw new Error("The Drive recording folder changed during recording.");
    }
    const name = basename(sourcePath);
    const driveFile = audioCaptureDriveFileSchema.parse({
      space: target.space,
      path: `recording/${recordingDate(startedAtMs)}/${name}`,
    });
    // RecordingSave.tla: Submit -> Ack. No application-level retry after an
    // uncertain Put; the caller retains the complete WAV on every failure.
    const result = await this.drive.importFile({ ...driveFile, sourcePath });
    if (result.status !== "done")
      throw new Error("Drive did not accept the recording.");
    const mediaType = name.endsWith(".m4a") ? "audio/mp4" : "audio/wav";
    return { driveFile, file: { mediaType, name, size } } as const;
  }

  async writeTranscript(
    recording: AudioCaptureRecording,
    target: RecordingDriveTarget,
    extension: "txt" | "json",
    content: string
  ): Promise<void> {
    const current = await this.target();
    if (current.space !== target.space || current.localRoot !== target.localRoot) {
      throw new Error("The Drive recording folder changed during transcription.");
    }
    const path = recording.driveFile.path.replace(
      /\.(?:m4a|wav)$/,
      `.transcript.${extension}`
    );
    const result = await this.drive.write({
      space: target.space,
      path,
      content: Buffer.from(content).toString("base64"),
    });
    if (result.status !== "done")
      throw new Error("Drive did not accept the transcript.");
  }

  async open(input: AudioCaptureDriveFile): Promise<AudioCaptureOpenSavedResult> {
    try {
      const driveFile = audioCaptureDriveFileSchema.parse(input);
      const target = await this.target();
      if (driveFile.space !== target.space) {
        return {
          status: "unavailable",
          reason: "The recording's Drive is no longer available on this device.",
        };
      }
      // The configured source is Main's authority. A renderer path, including
      // one that follows a user-created symlink, must remain inside this root.
      const root = await realpath(target.localRoot);
      const path = await realpath(join(root, driveFile.path));
      const withinRoot = relative(root, path);
      if (
        !withinRoot ||
        withinRoot.replaceAll("\\", "/") !== driveFile.path ||
        isAbsolute(withinRoot) ||
        !(await stat(path)).isFile()
      ) {
        return {
          status: "unavailable",
          reason: "The recording is no longer in its Drive folder.",
        };
      }
      const failure = await this.openPath(path);
      return failure
        ? {
            status: "unavailable",
            reason:
              "The system could not open this recording. Check the default app for audio files.",
          }
        : { status: "opened" };
    } catch {
      return {
        status: "unavailable",
        reason:
          "The recording is not available on this device yet, or was moved or deleted. Try again after Drive finishes syncing.",
      };
    }
  }
}

/** Archive by the local calendar day when capture starts, even across midnight. */
function recordingDate(startedAtMs: number) {
  const date = new Date(startedAtMs);
  return [
    date.getFullYear(),
    String(date.getMonth() + 1).padStart(2, "0"),
    String(date.getDate()).padStart(2, "0"),
  ].join("-");
}
