import { describe, expect, it, vi } from "vitest";
import type { MeetingPresenceState } from "@comma/native-bridge";
import { testEpoch } from "@comma/test-utils/test-clock";

import {
  MEETING_APPS,
  MeetingPresenceService,
  matchMeetingApp,
} from "../modules/meeting-presence";
import type {
  NativeAudioApplication,
  NativeAudioCapture,
} from "../modules/audio-capture/native-audio";

class FakeNative implements NativeAudioCapture {
  apps: NativeAudioApplication[] = [];
  mic = new Set<number>();
  listeners: Array<() => void> = [];
  listReads = 0;
  unsubscribed = 0;

  applications() {
    this.listReads += 1;
    return this.apps;
  }
  isUsingMicrophone(processId: number) {
    return this.mic.has(processId);
  }
  onApplicationListChanged(listener: () => void) {
    this.listeners.push(listener);
    return () => {
      this.unsubscribed += 1;
    };
  }
  tapApplication(): never {
    throw new Error("not used");
  }
  tapSystem(): never {
    throw new Error("not used");
  }
  emitListChanged() {
    for (const listener of this.listeners) listener();
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
  const native = new FakeNative();
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
  it("polls known meeting apps' microphones and re-lists processes only on list events", async () => {
    vi.useFakeTimers({ now: testEpoch });
    const h = harness({ globalTimers: true });
    h.native.apps = [zoom, spotify];
    await h.service.start();
    const reads = h.native.listReads;

    // The 2 s backstop sees a mic flip without listing every audio process.
    h.native.mic.add(4242);
    await vi.advanceTimersByTimeAsync(2_000);
    expect((await h.service.state()).meetings).toMatchObject([
      { name: "Zoom", status: "active" },
    ]);
    expect(h.native.listReads).toBe(reads);

    // A meeting app that starts audio later arrives with a process-list event.
    h.native.apps = [zoom, spotify, chrome];
    h.native.mic.add(900);
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

  it("stops polling and listening on close", async () => {
    const h = harness();
    await h.service.start();
    expect(h.timers).toHaveLength(1);
    await h.service.close();
    expect(h.cancelledCount()).toBe(1);
    expect(h.native.unsubscribed).toBe(1);
  });
});
