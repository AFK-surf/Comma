import { Worker } from "node:worker_threads";

import type {
  NativeAudioApplication,
  NativeAudioCapture,
  NativeAudioLogger,
} from "../audio-capture/native-audio";

/**
 * The worker checks the watched processes' microphones this often. Mic-usage
 * flips do not raise a process-list event, so only a poll sees them.
 */
const MICROPHONE_POLL_INTERVAL_MS = 2_000;

/**
 * Meeting detection's CoreAudio side. Listing the audio processes and asking
 * whether a process holds a microphone are synchronous CoreAudio calls: they
 * took Main's thread 6-20 ms every 2 s, and Main's thread also routes input.
 * A worker thread makes them, so Main only exchanges messages with it.
 */
export interface MicrophoneWatch {
  /** The audio processes, listed in the worker. */
  applications(): Promise<NativeAudioApplication[]>;
  /**
   * The worker checks these process groups (one group per meeting app) from
   * now on. Settles once it has checked them, so `microphones` answers for them.
   */
  watch(groups: readonly (readonly number[])[]): Promise<void>;
  /**
   * Each watched group's first process that holds a microphone, as the
   * worker last answered. It reads no CoreAudio state itself.
   */
  microphones(): readonly number[];
  /**
   * False once the worker has stopped too often to start again; every request
   * then rejects.
   */
  available(): boolean;
  /** Fires when the set of audio processes changes; returns unsubscribe. */
  onApplicationListChanged(listener: () => void): () => void;
  /**
   * Fires when the worker's 2 s check finds a different answer than
   * `microphones` gave; returns unsubscribe.
   */
  onMicrophonesChanged(listener: () => void): () => void;
  /** Stops the worker. */
  close(): Promise<void>;
}

/**
 * Detection is available where the shared SDK load finds the capture SDK.
 * That load makes the first CoreAudio call off Main's thread too, so the
 * watch starts after it has settled.
 */
export function createMicrophoneWatchLoader({
  loadNative,
  startWatch,
}: {
  loadNative: () => Promise<NativeAudioCapture | undefined>;
  startWatch: () => MicrophoneWatch;
}): () => Promise<MicrophoneWatch | undefined> {
  return async () => ((await loadNative()) ? startWatch() : undefined);
}

// Runs in the worker. It keeps the last answer it posted, so a check posts
// only a change; a watch request always answers.
const MICROPHONE_WATCH_WORKER = `
const { parentPort, workerData } = require("node:worker_threads");
const { ShareableContent } = require(workerData.sdkPath);
let groups = [];
let live = [];
function holdsMicrophone(processId) {
  try {
    return ShareableContent.isUsingMicrophone(processId) === true;
  } catch {
    return false;
  }
}
function check() {
  return groups.flatMap((group) => {
    const processId = group.find(holdsMicrophone);
    return processId === undefined ? [] : [processId];
  });
}
let subscription;
try {
  subscription = ShareableContent.onApplicationListChanged((error) => {
    if (!error) parentPort.postMessage({ type: "applicationListChanged" });
  });
} catch {
  // The 30 s list backstop on Main covers a missing subscription.
}
const poll = setInterval(() => {
  if (groups.length === 0) return;
  const next = check();
  if (next.length === live.length && next.every((processId, index) => processId === live[index])) return;
  live = next;
  parentPort.postMessage({ type: "microphones", processIds: live });
}, workerData.pollIntervalMs);
parentPort.on("message", (message) => {
  if (message.type === "applications") {
    let applications;
    try {
      applications = ShareableContent.applications().map((application) => ({
        bundleIdentifier: application.bundleIdentifier,
        name: application.name,
        processId: application.processId,
      }));
    } catch (error) {
      parentPort.postMessage({
        type: "applications",
        id: message.id,
        error: error instanceof Error ? error.message : String(error),
      });
      return;
    }
    parentPort.postMessage({ type: "applications", id: message.id, applications });
  } else if (message.type === "watch") {
    groups = message.groups;
    live = check();
    parentPort.postMessage({ type: "watched", id: message.id, processIds: live });
  } else if (message.type === "close") {
    clearInterval(poll);
    subscription?.unsubscribe();
    process.exit(0);
  }
});
`;

type WorkerMessage =
  | { type: "applicationListChanged" }
  | { type: "microphones"; processIds: number[] }
  | { type: "applications"; id: number; applications: NativeAudioApplication[] }
  | { type: "applications"; id: number; error: string }
  | { type: "watched"; id: number; processIds: number[] };

type Pending<Value> = Map<
  number,
  { resolve: (value: Value) => void; reject: (error: Error) => void }
>;

/** The request a worker reply answers, removed from the pending ones. */
function takePending<Value>(pending: Pending<Value>, id: number) {
  const request = pending.get(id);
  pending.delete(id);
  return request;
}

/**
 * A worker that stops this many times in a row without answering a request
 * is not started again: the SDK cannot run on this machine.
 */
const MAX_FAILED_STARTS = 3;

const unavailable = () =>
  new Error("Meeting detection's CoreAudio worker stopped too often.");

/**
 * Starts meeting detection's CoreAudio worker. A worker that stops on its own
 * (a crash in the SDK) answers no microphone and raises a list change; the
 * next request starts a new one, which watches nothing until the caller
 * watches again. After `MAX_FAILED_STARTS` stops in a row with no answer,
 * `available` turns false and every request rejects.
 */
export function startMicrophoneWatchWorker({
  sdkPath = require.resolve("@recappi/sdk"),
  logger,
}: {
  sdkPath?: string;
  logger?: NativeAudioLogger | undefined;
} = {}): MicrophoneWatch {
  const listListeners = new Set<() => void>();
  const microphoneListeners = new Set<() => void>();
  const listing: Pending<NativeAudioApplication[]> = new Map();
  const watching: Pending<void> = new Map();
  // Kept as the messages arrive, in the worker's order. A caller that awaits
  // `watch` may resume after a newer change has arrived, so it reads this.
  let microphones: number[] = [];
  let nextId = 0;
  let closing = false;
  /** Stops in a row since the last answer from a worker. */
  let failedStarts = 0;
  let current: { worker: Worker; exited: Promise<void> } | undefined;

  const rejectPending = (error: Error) => {
    for (const pending of [listing, watching]) {
      for (const { reject } of pending.values()) reject(error);
      pending.clear();
    }
  };
  const answered = () => {
    failedStarts = 0;
  };
  const start = () => {
    const worker = new Worker(MICROPHONE_WATCH_WORKER, {
      eval: true,
      workerData: { pollIntervalMs: MICROPHONE_POLL_INTERVAL_MS, sdkPath },
    });
    let failure: Error | undefined;
    worker.on("message", (message: WorkerMessage) => {
      switch (message.type) {
        case "applicationListChanged":
          for (const listener of listListeners) listener();
          return;
        case "microphones":
          microphones = message.processIds;
          for (const listener of microphoneListeners) listener();
          return;
        case "applications":
          answered();
          if ("error" in message) {
            takePending(listing, message.id)?.reject(new Error(message.error));
          } else {
            takePending(listing, message.id)?.resolve(message.applications);
          }
          return;
        case "watched":
          answered();
          microphones = message.processIds;
          takePending(watching, message.id)?.resolve();
          return;
      }
    });
    worker.on("error", (error) => {
      failure = error instanceof Error ? error : new Error(String(error));
      logger?.warn("meeting detection's CoreAudio worker failed", {
        error: failure.message,
        source: "meeting-presence",
      });
    });
    const exited = new Promise<void>((resolve) => {
      worker.once("exit", (code) => {
        if (current?.worker === worker) current = undefined;
        if (!closing) {
          failedStarts += 1;
          logger?.warn("meeting detection's CoreAudio worker exited", {
            code,
            source: "meeting-presence",
          });
        }
        // A new worker watches nothing until the caller watches again.
        microphones = [];
        rejectPending(
          failure ?? new Error(`The CoreAudio worker exited with code ${code}.`)
        );
        resolve();
        // The caller lists again, which starts the next worker and hands it
        // the groups.
        if (!closing) for (const listener of listListeners) listener();
      });
    });
    current = { worker, exited };
    return current;
  };

  const request = <Value>(
    pending: Pending<Value>,
    message: { type: "applications" } | { type: "watch"; groups: number[][] }
  ) => {
    if (closing) {
      return Promise.reject(new Error("The CoreAudio worker exited with code 0."));
    }
    if (failedStarts >= MAX_FAILED_STARTS) return Promise.reject(unavailable());
    const { worker } = current ?? start();
    const id = (nextId += 1);
    const reply = new Promise<Value>((resolve, reject) => {
      pending.set(id, { resolve, reject });
    });
    // oxlint-disable-next-line unicorn/require-post-message-target-origin -- a worker thread has no target origin
    worker.postMessage({ ...message, id });
    return reply;
  };

  start();
  return {
    applications: () => request(listing, { type: "applications" }),
    watch: (groups) =>
      request(watching, { type: "watch", groups: groups.map((group) => [...group]) }),
    microphones: () => microphones,
    available: () => failedStarts < MAX_FAILED_STARTS,
    onApplicationListChanged(listener) {
      listListeners.add(listener);
      return () => {
        listListeners.delete(listener);
      };
    },
    onMicrophonesChanged(listener) {
      microphoneListeners.add(listener);
      return () => {
        microphoneListeners.delete(listener);
      };
    },
    async close() {
      closing = true;
      const running = current;
      if (!running) return;
      // oxlint-disable-next-line unicorn/require-post-message-target-origin -- a worker thread has no target origin
      running.worker.postMessage({ type: "close" });
      await running.exited;
    },
  };
}
