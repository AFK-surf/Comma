import { execFile } from "node:child_process";
import { rename, rm } from "node:fs/promises";
import { promisify } from "node:util";

const runFile = promisify(execFile);

export interface RecordingEncoder {
  /** Returns a complete M4A. The source WAV remains until Drive confirms the save. */
  encode(sourcePath: string): Promise<string>;
}

/** Apple AVFoundation in the existing native helper. Paths stay in Main. */
export class HelperRecordingEncoder implements RecordingEncoder {
  constructor(
    private readonly executablePath: string | undefined,
    private readonly timeoutMs = 120_000
  ) {}

  async encode(sourcePath: string): Promise<string> {
    if (!this.executablePath) throw new Error("Recording compression is unavailable.");
    const outputPath = sourcePath.replace(/\.wav$/, ".m4a");
    const partialPath = `${outputPath}.partial.m4a`;
    try {
      // One bounded child per stopped recording. execFile waits for child closure,
      // including after SIGKILL, before we remove an incomplete output.
      await runFile(
        this.executablePath,
        ["--encode-recording", sourcePath, partialPath],
        {
          timeout: this.timeoutMs,
          killSignal: "SIGKILL",
          maxBuffer: 64 * 1024,
        }
      );
      await rename(partialPath, outputPath);
      return outputPath;
    } catch (error) {
      await rm(partialPath, { force: true }).catch(() => undefined);
      throw error;
    }
  }
}
