import { describe, expect, it, vi } from "vitest";
import type { MeetingPresenceState } from "@comma/native-bridge";
import { testEpoch } from "@comma/test-utils/test-clock";

import {
  MEETING_APPS,
  MeetingPresenceService,
  matchMeetingApp,
} from "../modules/meeting-presence";
import type { NativeAudioApplication } from "../modules/audio-capture/native-audio";
import type { MicrophoneWatch } from "../modules/meeting-presence/microphone-watch";

/**
 * The worker side of the microphone watch, answered in this thread. Every
 * request is answered by a promise, as a worker's reply is. `pollNow` is the
 * worker's own 2 s check: it calls back only when the answer changes.
 */
class FakeWatch implements MicrophoneWatch {
  apps: NativeAudioApplication[] = [];
  mic = new Set<number>();
  listReads = 0;
  closed = 0;
  unsubscribed = 0;
  /** The worker stopped too often to start again. */
  gaveUp = false;
  /** The requests Main sent, in order. */
  requests: Array<"applications" | "watch"> = [];
  /** The watch lists Main sent. */
  watched: number[][][] = [];
  #held: Promise<void> | undefined;
  #asked: (() => void) | undefined;
  #groups: number[][] = [];
  #live: number[] = [];
  #listListeners: Array<() => void> = [];
  #microphoneListeners: Array<() => void> = [];

  async applications() {
    if (this.gaveUp) throw new Error("stopped too often");
    this.requests.push("applications");
    this.#asked?.();
    await this.#held;
    this.listReads += 1;
    return this.apps.map((application) => ({ ...application }));
  }
  async watch(groups: readonly (readonly number[])[]) {
    this.requests.push("watch");
    this.#groups = groups.map((group) => [...group]);
    this.watched.push(this.#groups);
    this.#live = this.#check();
  }
  microphones() {
    return this.#live;
  }
  available() {
    return !this.gaveUp;
  }
  onApplicationListChanged(listener: () => void) {
    this.#listListeners.push(listener);
    return () => {
      this.unsubscribed += 1;
    };
  }
  onMicrophonesChanged(listener: () => void) {
    this.#microphoneListeners.push(listener);
    return () => {
      this.unsubscribed += 1;
    };
  }
  async close() {
    this.closed += 1;
  }
  emitListChanged() {
    for (const listener of this.#listListeners) listener();
  }
  /** The worker's 2 s check of the watched processes. */
  pollNow() {
    const next = this.#check();
    if (next.join() === this.#live.join()) return;
    this.#live = next;
    for (const listener of this.#microphoneListeners) listener();
  }
  /** Holds the process list back until `release`, as a busy worker does. */
  holdApplications() {
    const asked = Promise.withResolvers<void>();
    const release = Promise.withResolvers<void>();
    this.#asked = asked.resolve;
    this.#held = release.promise;
    return { asked: asked.promise, release: () => release.resolve() };
  }
  #check() {
    return this.#groups.flatMap((group) => {
      const processId = group.find((id) => this.mic.has(id));
      return processId === undefined ? [] : [processId];
    });
  }
}

function harness(
  overrides: {
    readBrowserMeetings?: () => Promise<
      import("../modules/browser-sidebar/meeting-presence").BrowserMeeting[]
    >;
    nativeAvailable?: boolean;
    readAppIcon?: (bundleIdentifier: string) => Promise<string | undefined>;
    /** Leaves the poll on the global timers and clock, which the test fakes. */
    globalTimers?: boolean;
  } = {}
) {
  const native = new FakeWatch();
  const published: MeetingPresenceState[] = [];
  const publishWaiters: Array<(state: MeetingPresenceState) => void> = [];
  let nowMs = 1_700_000_000_000;
  const timers: Array<() => void> = [];
  let cancelled = 0;
  const service = new MeetingPresenceService({
    inactiveGraceMs: 20_000,
    ...(overrides.readBrowserMeetings
      ? { readBrowserMeetings: overrides.readBrowserMeetings }
      : {}),
    ...(overrides.readAppIcon ? { readAppIcon: overrides.readAppIcon } : {}),
    ...(overrides.globalTimers
      ? {}
      : {
          clock: {
            now: () => nowMs,
            setTimer: (_ms: number, run: () => void) => {
              timers.push(run);
              return () => {
                cancelled += 1;
              };
            },
          },
        }),
    loadNative: async () => (overrides.nativeAvailable === false ? undefined : native),
    onStateChanged: (state) => {
      published.push(state);
      for (const resolve of publishWaiters.splice(0)) resolve(state);
    },
    pollIntervalMs: 2_000,
  });
  return {
    advance: (ms: number) => {
      nowMs += ms;
    },
    cancelledCount: () => cancelled,
    timers,
    native,
    /** Resolves with the next state the service publishes. */
    nextPublished: () => {
      const next = Promise.withResolvers<MeetingPresenceState>();
      publishWaiters.push(next.resolve);
      return next.promise;
    },
    published,
    service,
  };
}

const zoom = { bundleIdentifier: "us.zoom.xos", name: "zoom.us", processId: 4242 };
const zoomHelper = {
  bundleIdentifier: "us.zoom.xos.helper.renderer",
  name: "zoom helper",
  processId: 4243,
};
const chrome = {
  bundleIdentifier: "com.google.Chrome",
  name: "Google Chrome",
  processId: 900,
};
const spotify = {
  bundleIdentifier: "com.spotify.client",
  name: "Spotify",
  processId: 77,
};

describe("matchMeetingApp", () => {
  it("collapses helper processes onto their parent catalog entry", () => {
    expect(matchMeetingApp("us.zoom.xos.helper.renderer")?.name).toBe("Zoom");
    expect(matchMeetingApp("com.google.Chrome.helper.GPU")?.kind).toBe("browser");
    expect(matchMeetingApp("com.spotify.client")).toBeUndefined();
    expect(matchMeetingApp("")).toBeUndefined();
    expect(MEETING_APPS.some((app) => app.bundleIdentifier === "us.zoom.xos")).toBe(
      true
    );
  });
});

describe("MeetingPresenceService", () => {
  it("reports detection unavailable and ends its calls once the worker stops for good", async () => {
    const h = harness();
    h.native.apps = [zoom];
    h.native.mic.add(zoom.processId);
    expect((await h.service.start()).meetings).toMatchObject([
      { bundleIdentifier: "us.zoom.xos", status: "active" },
    ]);

    // The worker crashed three times in a row; it answers no more.
    h.native.gaveUp = true;
    await h.service.refresh();

    expect(h.published.at(-1)).toMatchObject({ available: false, meetings: [] });
    expect(h.cancelledCount()).toBe(1);
  });

  // CoreAudio calls took Main's thread 6-20 ms every 2 s, and Main's thread
  // also routes input. A worker makes them now, so each answer is a message
  // the service waits for.
  it("takes every CoreAudio answer from the worker asynchronously", async () => {
    const h = harness();
    h.native.apps = [zoom, zoomHelper, spotify];
    h.native.mic.add(zoomHelper.processId);
    const list = h.native.holdApplications();

    const started = h.service.start();
    await list.asked;
    // The process list is still in the worker: nothing is derived from it yet.
    expect(h.published).toEqual([]);
    list.release();

    expect((await started).meetings).toMatchObject([
      { bundleIdentifier: "us.zoom.xos", processId: 4243, status: "active" },
    ]);
    // One group per meeting app, helpers included: the helper holds Zoom's mic.
    expect(h.native.requests).toEqual(["applications", "watch"]);
    expect(h.native.watched).toEqual([[[4242, 4243]]]);
    await h.service.close();
  });

  it("detects in-app joined calls without mic activity and ends them despite Comma microphone use", async () => {
    let joined = false;
    const h = harness({
      readBrowserMeetings: async () =>
        joined
          ? [
              {
                id: "tab:room",
                tabId: "tab",
                name: "Google Meet (Comma)",
                processId: 42,
              },
            ]
          : [],
    });
    h.native.apps = [{ bundleIdentifier: "surf.comma", name: "Comma", processId: 42 }];
    h.native.mic.add(42);
    expect((await h.service.start()).meetings).toEqual([]);
    joined = true;
    await h.service.refresh();
    expect((await h.service.state()).meetings).toMatchObject([
      { name: "Google Meet (Comma)", processId: 42, status: "active" },
    ]);
    joined = false;
    await h.service.refresh();
    expect((await h.service.state()).meetings).toEqual([]);
    h.advance(20_000);
    await h.service.refresh();
    expect((await h.service.state()).meetings).toEqual([]);
    expect(h.timers).toHaveLength(1);
    await h.service.close();
  });

  it("detects an existing Arc call through its lowercase audio helper", async () => {
    const h = harness();
    h.native.apps = [
      { bundleIdentifier: "company.thebrowser.Browser", name: "Arc", processId: 901 },
      {
        bundleIdentifier: "company.thebrowser.browser.helper",
        name: "",
        processId: 902,
      },
    ];
    h.native.mic.add(902);
    const state = await h.service.start();
    expect(state.meetings).toMatchObject([
      {
        bundleIdentifier: "company.thebrowser.Browser",
        kind: "browser",
        name: "Arc",
        processId: 902,
        status: "active",
      },
    ]);
    await h.service.close();
  });

  it("reads the OS product icon on demand without adding image payloads to presence", async () => {
    const readAppIcon = vi.fn(async () => "data:image/png;base64,cG5n");
    const h = harness({ readAppIcon });
    h.native.apps = [zoom, chrome];
    h.native.mic.add(zoom.processId);
    h.native.mic.add(chrome.processId);
    await h.service.start();
    expect(readAppIcon).not.toHaveBeenCalled();
    await expect(
      h.service.icon({ bundleIdentifier: zoom.bundleIdentifier })
    ).resolves.toBe("data:image/png;base64,cG5n");
    await expect(
      h.service.icon({ bundleIdentifier: chrome.bundleIdentifier })
    ).resolves.toBeNull();
    await expect(
      h.service.icon({ bundleIdentifier: spotify.bundleIdentifier })
    ).resolves.toBeNull();
    expect(readAppIcon).toHaveBeenCalledTimes(1);
    await h.service.close();
  });
  it("reports unavailable without the native sdk and never polls", async () => {
    const h = harness({ nativeAvailable: false });
    const state = await h.service.start();
    expect(state).toMatchObject({ available: false, meetings: [] });
    expect(h.timers).toHaveLength(0);
    await h.service.close();
  });

  it("ignores meeting apps that are open but not on the microphone", async () => {
    const h = harness();
    h.native.apps = [zoom, spotify];
    await h.service.start();
    expect((await h.service.state()).meetings).toEqual([]);
  });

  it("detects a call when a meeting app takes the microphone and keys it for its lifetime", async () => {
    const h = harness();
    h.native.apps = [zoom, zoomHelper, spotify];
    await h.service.start();

    h.native.mic.add(4243); // only the helper holds the mic
    h.advance(1_000);
    await h.service.refresh();
    const [meeting] = (await h.service.state()).meetings;
    expect(meeting).toMatchObject({
      bundleIdentifier: "us.zoom.xos",
      kind: "native",
      name: "Zoom",
      processId: 4243,
      status: "active",
    });
    expect(meeting?.key).toBe(`us.zoom.xos:${meeting?.since}`);

    // A mic flap inside the grace period keeps the same call and key.
    h.native.mic.delete(4243);
    h.advance(5_000);
    await h.service.refresh();
    expect((await h.service.state()).meetings[0]).toMatchObject({
      key: meeting?.key,
      status: "ending",
    });
    h.native.mic.add(4243);
    h.advance(1_000);
    await h.service.refresh();
    expect((await h.service.state()).meetings[0]).toMatchObject({
      key: meeting?.key,
      status: "active",
    });
  });

  it("ends the call once the grace period elapses without the microphone", async () => {
    const h = harness();
    h.native.apps = [zoom];
    h.native.mic.add(4242);
    await h.service.start();
    expect((await h.service.state()).meetings).toHaveLength(1);

    h.native.mic.delete(4242);
    h.advance(19_000);
    await h.service.refresh();
    expect((await h.service.state()).meetings[0]?.status).toBe("ending");

    h.advance(1_500);
    await h.service.refresh();
    expect((await h.service.state()).meetings).toEqual([]);

    // Coming back later is a new call with a new key.
    h.native.mic.add(4242);
    h.advance(60_000);
    await h.service.refresh();
    const next = (await h.service.state()).meetings[0];
    expect(next?.status).toBe("active");
    expect(next?.key).not.toBe(`us.zoom.xos:1700000000000`);
  });

  it("labels a browser holding the microphone as a browser call", async () => {
    const h = harness();
    h.native.apps = [chrome];
    h.native.mic.add(900);
    await h.service.start();
    expect((await h.service.state()).meetings[0]).toMatchObject({
      kind: "browser",
      name: "Google Chrome",
    });
  });

  it("publishes only on change and refreshes on process-list events", async () => {
    const h = harness();
    h.native.apps = [zoom];
    await h.service.start();
    const before = h.published.length;

    await h.service.refresh();
    await h.service.refresh();
    expect(h.published.length).toBe(before);

    h.native.mic.add(4242);
    h.native.emitListChanged();
    await h.service.refresh();
    expect(h.published.length).toBe(before + 1);
    expect(h.published.at(-1)?.meetings).toHaveLength(1);
  });

  // The fakes answer at once, so a poll's tick has settled by the time
  // advancing the fake clock past it returns.
  it("follows the worker's microphone changes and re-lists processes only on list events", async () => {
    vi.useFakeTimers({ now: testEpoch });
    const h = harness({ globalTimers: true });
    h.native.apps = [zoom, spotify];
    await h.service.start();
    const reads = h.native.listReads;
    const requests = h.native.requests.length;

    // Main's 2 s tick asks the worker nothing, and an unchanged check posts nothing.
    await vi.advanceTimersByTimeAsync(2_000);
    h.native.pollNow();
    expect(h.native.requests).toHaveLength(requests);

    // The worker's 2 s check sees a mic flip without listing every audio process.
    h.native.mic.add(4242);
    const flipped = h.nextPublished();
    h.native.pollNow();
    expect((await flipped).meetings).toMatchObject([
      { name: "Zoom", status: "active" },
    ]);
    expect(h.native.listReads).toBe(reads);
    expect(h.native.requests).toHaveLength(requests);

    // A meeting app that starts audio later arrives with a process-list event.
    h.native.apps = [zoom, spotify, chrome];
    h.native.mic.add(900);
    h.native.pollNow();
    await vi.advanceTimersByTimeAsync(2_000);
    expect((await h.service.state()).meetings.map(({ name }) => name)).toEqual([
      "Zoom",
    ]);
    const listed = h.nextPublished();
    h.native.emitListChanged();
    expect((await listed).meetings.map(({ name }) => name)).toEqual([
      "Zoom",
      "Google Chrome",
    ]);
    expect(h.native.listReads).toBe(reads + 1);
    await h.service.close();
  });

  it("re-lists processes on a slow backstop when no list event arrives", async () => {
    vi.useFakeTimers({ now: testEpoch });
    const h = harness({ globalTimers: true });
    h.native.apps = [spotify];
    await h.service.start();
    const reads = h.native.listReads;

    // Zoom starts its call, but the process-list event never fires.
    h.native.apps = [zoom, spotify];
    h.native.mic.add(4242);
    await vi.advanceTimersByTimeAsync(2_000);
    expect((await h.service.state()).meetings).toEqual([]);
    expect(h.native.listReads).toBe(reads);

    await vi.advanceTimersByTimeAsync(28_000);
    expect((await h.service.state()).meetings).toMatchObject([
      { name: "Zoom", status: "active" },
    ]);
    expect(h.native.listReads).toBe(reads + 1);
    await h.service.close();
  });

  it("stops polling, listening and the worker on close", async () => {
    const h = harness();
    await h.service.start();
    expect(h.timers).toHaveLength(1);
    await h.service.close();
    expect(h.cancelledCount()).toBe(1);
    expect(h.native.unsubscribed).toBe(2);
    expect(h.native.closed).toBe(1);
  });
});
