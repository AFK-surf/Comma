import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import type { AudioCaptureRecording } from "@comma/native-bridge";
import type { DriveRecordingStore } from "../modules/audio-capture/drive-recordings";
import {
  RecordingTranscriptionService,
  type TranscribeRecording,
} from "../modules/audio-capture/transcription";

const directories: string[] = [];
afterEach(async () => {
  await Promise.all(
    directories.splice(0).map((path) => rm(path, { recursive: true, force: true }))
  );
});
const recording: AudioCaptureRecording = {
  channels: 1,
  durationMs: 840000,
  sampleRate: 16000,
  file: { name: "meeting.m4a", size: 5_000_000, mediaType: "audio/mp4" },
  driveFile: { space: "drive", path: "recording/2026-09-09/meeting.m4a" },
};
const target = { space: "drive", localRoot: "/drive" };
const result = {
  transcript: "[00:01] Speaker: 会议开始。",
  duration_seconds: 840,
  chunks: [{ index: 0, offset_seconds: 0, transcript: "[00:01] Speaker: 会议开始。" }],
};

async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), "comma-asr-test-"));
  directories.push(directory);
  const path = join(directory, "meeting.m4a");
  await writeFile(path, "fixture audio");
  const writeTranscript = vi.fn<DriveRecordingStore["writeTranscript"]>(async () => {});
  const assertCurrent = vi.fn(() => {});
  const transcribe = vi.fn<TranscribeRecording>(async (audio) => {
    expect(new TextDecoder().decode(audio)).toBe("fixture audio");
    return result;
  });
  const service = new RecordingTranscriptionService(
    { writeTranscript },
    () => ({ assertCurrent }),
    transcribe
  );
  return { path, service, writeTranscript, transcribe, assertCurrent };
}

it("hands the saved audio to the core and writes complete text and JSON beside it", async () => {
  const { service, path, transcribe, writeTranscript } = await fixture();
  await service.process(recording, target, path);
  expect(transcribe).toHaveBeenCalledOnce();
  expect(writeTranscript).toHaveBeenNthCalledWith(
    1,
    recording,
    target,
    "txt",
    result.transcript
  );
  expect(JSON.parse(writeTranscript.mock.calls[1]![3]!)).toEqual({
    status: "ready",
    source: recording.driveFile,
    ...result,
  });
});

it("records why the core gave no transcript without changing the audio", async () => {
  const { service, path, transcribe, writeTranscript } = await fixture();
  transcribe.mockRejectedValueOnce(new Error("ASR is not configured"));
  await service.process(recording, target, path);
  expect(writeTranscript).toHaveBeenCalledOnce();
  expect(writeTranscript.mock.calls[0]![2]).toBe("json");
  expect(JSON.parse(writeTranscript.mock.calls[0]![3]!)).toEqual({
    status: "error",
    source: recording.driveFile,
    reason: "ASR is not configured",
  });
});

it("does not write a late transcript after the account session changes", async () => {
  const { service, path, assertCurrent, writeTranscript } = await fixture();
  assertCurrent.mockImplementation(() => {
    throw new Error("Session ended");
  });
  await expect(service.process(recording, target, path)).rejects.toThrow(
    "Session ended"
  );
  expect(writeTranscript).not.toHaveBeenCalled();
});
