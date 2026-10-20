import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

import {
  createNativeAudioCaptureLoader,
  makeFirstCoreAudioCallInWorker,
  type NativeAudioCapture,
  type RecappiModule,
} from "../modules/audio-capture/native-audio";
import { MeetingPresenceService } from "../modules/meeting-presence";

/** A fake SDK that records every call Main makes into it. */
function recordingSdk() {
  const calls: string[] = [];
  const sdk: RecappiModule = {
    getPlatformCapabilities: () => {
      calls.push("getPlatformCapabilities");
      return { tapAudio: true, tapGlobalAudio: true };
    },
    ShareableContent: {
      applications: () => {
        calls.push("applications");
        return [];
      },
      applicationWithProcessId: () => null,
      isUsingMicrophone: () => {
        calls.push("isUsingMicrophone");
        return false;
      },
      onApplicationListChanged: () => {
        calls.push("onApplicationListChanged");
        return { unsubscribe: () => undefined };
      },
      tapAudio: () => {
        throw new Error("not used");
      },
      tapGlobalAudio: () => {
        throw new Error("not used");
      },
    },
  };
  return { calls, sdk };
}

function meetingDetection(loadNative: () => Promise<NativeAudioCapture | undefined>) {
  return new MeetingPresenceService({
    clearInterval: () => undefined,
    loadNative,
    onStateChanged: () => undefined,
    setInterval: () => 1,
  });
}

async function fakeSdkFile(body: string) {
  const directory = await mkdtemp(join(tmpdir(), "comma-native-audio-worker-"));
  const path = join(directory, "sdk.cjs");
  await writeFile(path, body);
  return { directory, path };
}

describe("native audio loader", () => {
  it("makes no SDK call on Main until the worker's first CoreAudio call has settled", async () => {
    const { calls, sdk } = recordingSdk();
    const importSdk = vi.fn(async () => sdk);
    const firstCallStarted = Promise.withResolvers<void>();
    const firstCall = Promise.withResolvers<void>();
    const logger = { info: vi.fn(), warn: vi.fn() };
    let nowMs = 1_000;
    const load = createNativeAudioCaptureLoader({
      firstCoreAudioCall: () => {
        firstCallStarted.resolve();
        return firstCall.promise;
      },
      importSdk,
      logger,
      now: () => nowMs,
    });
    const detection = meetingDetection(load);

    const started = detection.start();
    // From here the loader waits on the worker's call until the test settles it.
    await firstCallStarted.promise;
    expect(importSdk).not.toHaveBeenCalled();
    expect(calls).toEqual([]);

    nowMs += 8_300;
    firstCall.resolve();
    await started;

    expect(calls[0]).toBe("getPlatformCapabilities");
    expect(calls).toContain("onApplicationListChanged");
    expect(logger.info).toHaveBeenCalledExactlyOnceWith(
      "first CoreAudio call finished off Main's thread",
      { durationMs: 8_300, source: "native-audio" }
    );
    expect(logger.warn).not.toHaveBeenCalled();
    // Audio capture shares the load: the first call is made once per process.
    await load();
    expect(importSdk).toHaveBeenCalledTimes(1);
  });

  it("falls back to Main's own first call and logs it when the worker fails", async () => {
    const { calls, sdk } = recordingSdk();
    const logger = { info: vi.fn(), warn: vi.fn() };
    const load = createNativeAudioCaptureLoader({
      firstCoreAudioCall: async () => {
        throw new Error("worker could not load the SDK");
      },
      importSdk: async () => sdk,
      logger,
      now: () => 0,
    });

    await meetingDetection(load).start();

    expect(calls).toContain("onApplicationListChanged");
    expect(logger.warn).toHaveBeenCalledExactlyOnceWith(
      "first CoreAudio call failed off Main's thread; Main makes it",
      { durationMs: 0, error: "worker could not load the SDK", source: "native-audio" }
    );
    expect(logger.info).not.toHaveBeenCalled();
  });
});

describe("first CoreAudio call in a worker", () => {
  it("lists the audio processes in the worker and settles when it returns", async () => {
    const { directory, path } = await fakeSdkFile(`
      const { writeFileSync } = require("node:fs");
      const { threadId } = require("node:worker_threads");
      exports.ShareableContent = {
        applications() {
          writeFileSync(__dirname + "/called", String(threadId));
          return [];
        },
      };
    `);
    try {
      await makeFirstCoreAudioCallInWorker(path);
      // The call ran on a worker thread, not this one (thread 0).
      expect(Number(await readFile(join(directory, "called"), "utf8"))).toBeGreaterThan(
        0
      );
    } finally {
      await rm(directory, { force: true, recursive: true });
    }
  });

  it("rejects when the SDK call throws in the worker", async () => {
    const { directory, path } = await fakeSdkFile(`
      exports.ShareableContent = {
        applications() {
          throw new Error("CoreAudio is unavailable");
        },
      };
    `);
    try {
      await expect(makeFirstCoreAudioCallInWorker(path)).rejects.toThrow(
        "CoreAudio is unavailable"
      );
    } finally {
      await rm(directory, { force: true, recursive: true });
    }
  });
});
