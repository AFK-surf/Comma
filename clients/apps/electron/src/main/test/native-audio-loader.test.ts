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
import {
  createMicrophoneWatchLoader,
  startMicrophoneWatchWorker,
} from "../modules/meeting-presence/microphone-watch";

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

/** Meeting detection on the shared load, with its CoreAudio worker faked. */
function meetingDetection(loadNative: () => Promise<NativeAudioCapture | undefined>) {
  const startWatch = vi.fn(() => ({
    applications: async () => [],
    watch: async () => undefined,
    microphones: () => [],
    available: () => true,
    onApplicationListChanged: () => () => undefined,
    onMicrophonesChanged: () => () => undefined,
    close: async () => undefined,
  }));
  const detection = new MeetingPresenceService({
    clock: { now: () => 0, setTimer: () => () => undefined },
    loadNative: createMicrophoneWatchLoader({ loadNative, startWatch }),
    onStateChanged: () => undefined,
  });
  return { detection, startWatch };
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
      clock: { now: () => nowMs, setTimer: () => () => undefined },
    });
    const { detection, startWatch } = meetingDetection(load);

    const started = detection.start();
    // From here the loader waits on the worker's call until the test settles it.
    await firstCallStarted.promise;
    expect(importSdk).not.toHaveBeenCalled();
    expect(calls).toEqual([]);
    expect(startWatch).not.toHaveBeenCalled();

    nowMs += 8_300;
    firstCall.resolve();
    await started;

    // Detection lists, polls and subscribes in its own worker, never on Main.
    expect(calls).toEqual(["getPlatformCapabilities"]);
    expect(startWatch).toHaveBeenCalledOnce();
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
      clock: { now: () => 0, setTimer: () => () => undefined },
    });

    const { detection, startWatch } = meetingDetection(load);
    await detection.start();

    expect(calls).toEqual(["getPlatformCapabilities"]);
    expect(startWatch).toHaveBeenCalledOnce();
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

describe("meeting detection's CoreAudio worker", () => {
  it("lists, checks microphones and forwards list events from its thread", async () => {
    // The SDK's ApplicationInfo exposes its fields as getters; listing the
    // processes fires a list event, so the test needs no timing.
    const { directory, path } = await fakeSdkFile(`
      const { writeFileSync } = require("node:fs");
      const { threadId } = require("node:worker_threads");
      class ApplicationInfo {
        constructor(processId, bundleIdentifier) {
          this.processId = processId;
          this._bundleIdentifier = bundleIdentifier;
        }
        get bundleIdentifier() { return this._bundleIdentifier; }
        get name() { return "app " + this.processId; }
      }
      let listChanged;
      exports.ShareableContent = {
        applications() {
          writeFileSync(__dirname + "/thread", String(threadId));
          listChanged?.(null);
          return [new ApplicationInfo(41, "us.zoom.xos"), new ApplicationInfo(42, "us.zoom.xos.helper")];
        },
        isUsingMicrophone(processId) {
          if (processId === 7) throw new Error("gone");
          return processId === 42;
        },
        onApplicationListChanged(callback) {
          listChanged = callback;
          return { unsubscribe: () => writeFileSync(__dirname + "/unsubscribed", "1") };
        },
      };
    `);
    const watch = startMicrophoneWatchWorker({ sdkPath: path });
    try {
      const listEvent = Promise.withResolvers<void>();
      watch.onApplicationListChanged(listEvent.resolve);

      await expect(watch.applications()).resolves.toEqual([
        { bundleIdentifier: "us.zoom.xos", name: "app 41", processId: 41 },
        { bundleIdentifier: "us.zoom.xos.helper", name: "app 42", processId: 42 },
      ]);
      await listEvent.promise;
      // The list ran on the worker's thread, not this one (thread 0).
      expect(Number(await readFile(join(directory, "thread"), "utf8"))).toBeGreaterThan(
        0
      );
      // Each group answers with its first process on the microphone; a process
      // that is gone counts as off.
      await watch.watch([[41, 42], [7]]);
      expect(watch.microphones()).toEqual([42]);

      await watch.close();
      expect(await readFile(join(directory, "unsubscribed"), "utf8")).toBe("1");
      await expect(watch.applications()).rejects.toThrow("exited with code 0");
    } finally {
      await rm(directory, { force: true, recursive: true });
    }
  });
  it("starts a crashed worker again and gives up after three stops in a row", async () => {
    // Each `applications` call exits the worker until the marker count runs out;
    // a fresh worker loads the module again, so the count lives in a file.
    const { directory, path } = await fakeSdkFile(`
      const { existsSync, readFileSync, writeFileSync } = require("node:fs");
      const counter = __dirname + "/crashes";
      exports.ShareableContent = {
        applications() {
          const left = existsSync(counter) ? Number(readFileSync(counter, "utf8")) : 0;
          if (left > 0) {
            writeFileSync(counter, String(left - 1));
            process.exit(3);
          }
          return [];
        },
        isUsingMicrophone: () => true,
        onApplicationListChanged: () => ({ unsubscribe() {} }),
      };
    `);
    const watch = startMicrophoneWatchWorker({ sdkPath: path });
    try {
      const listEvents = vi.fn();
      watch.onApplicationListChanged(listEvents);
      await watch.watch([[5]]);
      expect(watch.microphones()).toEqual([5]);

      // One crash: the watch drops its answer, asks for a new list, and the
      // next request runs in a new worker.
      await writeFile(join(directory, "crashes"), "1");
      await expect(watch.applications()).rejects.toThrow("exited with code 3");
      expect(watch.microphones()).toEqual([]);
      expect(listEvents).toHaveBeenCalledTimes(1);
      await expect(watch.applications()).resolves.toEqual([]);
      expect(watch.available()).toBe(true);

      // Three crashes in a row with no answer between them: no fourth worker.
      await writeFile(join(directory, "crashes"), "5");
      for (let crash = 0; crash < 3; crash += 1) {
        await expect(watch.applications()).rejects.toThrow("exited with code 3");
      }
      expect(watch.available()).toBe(false);
      await expect(watch.applications()).rejects.toThrow("stopped too often");
      expect(await readFile(join(directory, "crashes"), "utf8")).toBe("2");
    } finally {
      await watch.close();
      await rm(directory, { force: true, recursive: true });
    }
  });
});
