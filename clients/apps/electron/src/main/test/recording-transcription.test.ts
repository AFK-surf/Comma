import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it, vi } from "vitest";
import type { AudioCaptureRecording } from "@comma/native-bridge";
import type { DriveRecordingStore } from "../modules/audio-capture/drive-recordings";
import { RecordingTranscriptionService } from "../modules/audio-capture/transcription";

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

async function fixture(frame = { status: "ready", result }) {
  const directory = await mkdtemp(join(tmpdir(), "comma-asr-test-"));
  directories.push(directory);
  const path = join(directory, "meeting.m4a");
  await writeFile(path, "fixture audio");
  const writeTranscript = vi.fn<DriveRecordingStore["writeTranscript"]>(async () => {});
  const assertCurrent = vi.fn(() => {});
  const fetcher = vi.fn<typeof fetch>(async (_url, init) => {
    expect(await (init!.body as Blob).text()).toBe("fixture audio");
    const bytes = new TextEncoder().encode(
      `: working\n\nevent: transcription\ndata: ${JSON.stringify(frame)}\n\n`
    );
    // Split every byte, including Chinese UTF-8 sequences and SSE delimiters.
    return new Response(
      new ReadableStream({
        start(controller) {
          for (const byte of bytes) controller.enqueue(Uint8Array.of(byte));
          controller.close();
        },
      }),
      { headers: { "content-type": "text/event-stream" } }
    );
  });
  const service = new RecordingTranscriptionService({ writeTranscript }, () => ({
    fetch: fetcher,
    url: new URL("https://comma.example/v1/comma/me/recordings/transcribe"),
    assertCurrent,
  }));
  return { path, service, writeTranscript, fetcher, assertCurrent };
}

it("uploads the saved audio and writes complete text and JSON beside it", async () => {
  const { service, path, fetcher, writeTranscript } = await fixture();
  await service.process(recording, target, path);
  expect(fetcher).toHaveBeenCalledOnce();
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

it("keeps a terminal transcript when response cancellation fails", async () => {
  const { service, path, fetcher, writeTranscript } = await fixture();
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(
        new TextEncoder().encode(
          `event: transcription\ndata: ${JSON.stringify({ status: "ready", result })}\n\n`
        )
      );
    },
    cancel() {
      throw new Error("response cancellation failed");
    },
  });
  fetcher.mockResolvedValueOnce(new Response(body));

  await service.process(recording, target, path);

  expect(writeTranscript).toHaveBeenCalledTimes(2);
  expect(writeTranscript.mock.calls[0]![2]).toBe("txt");
  expect(JSON.parse(writeTranscript.mock.calls[1]![3]!).status).toBe("ready");
  expect(body.locked).toBe(false);
});

it.each(["provider", "disconnect", "oversized"])(
  "records an ASR %s failure without changing the audio",
  async (failure) => {
    const { service, path, fetcher, writeTranscript } = await fixture();
    if (failure === "provider")
      fetcher.mockResolvedValueOnce(
        new Response(
          'event: transcription\ndata: {"status":"error","reason":"ASR is not configured"}\n\n'
        )
      );
    if (failure === "disconnect")
      fetcher.mockResolvedValueOnce(new Response(": heartbeat\n\n"));
    await service.process(
      failure === "oversized"
        ? { ...recording, file: { ...recording.file, size: 30 * 1024 * 1024 + 1 } }
        : recording,
      target,
      path
    );
    expect(writeTranscript).toHaveBeenCalledOnce();
    expect(writeTranscript.mock.calls[0]![2]).toBe("json");
    expect(JSON.parse(writeTranscript.mock.calls[0]![3]!).status).toBe("error");
    if (failure === "oversized") expect(fetcher).not.toHaveBeenCalled();
  }
);

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

it("bounds concurrent ASR requests and admits a new recording after completion", async () => {
  const { service, path, fetcher, writeTranscript } = await fixture();
  const gate = Promise.withResolvers<Response>();
  fetcher.mockImplementation(() => gate.promise);
  const first = service.process(recording, target, path);
  const second = service.process(recording, target, path);
  await service.process(recording, target, path);
  expect(JSON.parse(writeTranscript.mock.calls[0]![3]!).reason).toContain("busy");
  gate.resolve(
    new Response(
      'event: transcription\ndata: {"status":"error","reason":"test failure"}\n\n'
    )
  );
  await Promise.all([first, second]);
  expect(fetcher).toHaveBeenCalledTimes(2);
  fetcher.mockResolvedValue(new Response(": ended\n\n"));
  await service.process(recording, target, path);
  expect(fetcher).toHaveBeenCalledTimes(3);
});
