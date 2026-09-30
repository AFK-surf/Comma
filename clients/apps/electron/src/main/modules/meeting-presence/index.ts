import type { BrowserMeeting } from "../browser-sidebar/meeting-presence";
import type {
  MeetingPresenceMeeting,
  MeetingPresenceState,
} from "@comma/native-bridge";

import {
  loadNativeAudioCapture,
  type NativeAudioApplication,
  type NativeAudioCapture,
} from "../audio-capture/native-audio";

/**
 * Mic-usage flips do not raise a process-list event, so poll the known
 * meeting apps' microphones as a backstop.
 */
const DEFAULT_POLL_INTERVAL_MS = 2_000;
/**
 * The poll still re-lists processes this often, in case a process-list event
 * never arrives (the subscription failed, or the event carried an error).
 */
const LIST_BACKSTOP_MS = 30_000;
/** A call that drops the mic for less than this is still the same call. */
const DEFAULT_INACTIVE_GRACE_MS = 20_000;

export interface MeetingAppDescriptor {
  bundleIdentifier: string;
  kind: MeetingPresenceMeeting["kind"];
  name: string;
}

/**
 * Apps whose live microphone means "the user is in a call". Browsers are
 * listed too: a browser holding the mic is almost always a web meeting, and
 * naming the page would need tab access this service deliberately avoids.
 */
export const MEETING_APPS: readonly MeetingAppDescriptor[] = [
  { bundleIdentifier: "us.zoom.xos", kind: "native", name: "Zoom" },
  { bundleIdentifier: "com.microsoft.teams2", kind: "native", name: "Microsoft Teams" },
  { bundleIdentifier: "com.microsoft.teams", kind: "native", name: "Microsoft Teams" },
  { bundleIdentifier: "com.tinyspeck.slackmacgap", kind: "native", name: "Slack" },
  { bundleIdentifier: "com.hnc.Discord", kind: "native", name: "Discord" },
  { bundleIdentifier: "com.apple.FaceTime", kind: "native", name: "FaceTime" },
  { bundleIdentifier: "Cisco-Systems.Spark", kind: "native", name: "Webex" },
  { bundleIdentifier: "com.tencent.meeting", kind: "native", name: "Tencent Meeting" },
  { bundleIdentifier: "com.electron.lark", kind: "native", name: "Feishu" },
  { bundleIdentifier: "com.google.Chrome", kind: "browser", name: "Google Chrome" },
  { bundleIdentifier: "com.apple.Safari", kind: "browser", name: "Safari" },
  { bundleIdentifier: "company.thebrowser.Browser", kind: "browser", name: "Arc" },
  {
    bundleIdentifier: "com.microsoft.edgemac",
    kind: "browser",
    name: "Microsoft Edge",
  },
  { bundleIdentifier: "com.brave.Browser", kind: "browser", name: "Brave" },
  { bundleIdentifier: "org.mozilla.firefox", kind: "browser", name: "Firefox" },
];

/**
 * Maps a helper process (`us.zoom.xos.helper`, `com.google.Chrome.helper.GPU`)
 * to the catalog entry of its parent app, if any.
 */
export function matchMeetingApp(
  bundleIdentifier: string,
  catalog: readonly MeetingAppDescriptor[] = MEETING_APPS
): MeetingAppDescriptor | undefined {
  // Audio helpers can lowercase their parent's identifier (for example Arc).
  // Keep the catalog's canonical identifier in the resulting meeting.
  const normalized = bundleIdentifier.trim().toLowerCase();
  if (!normalized) return undefined;
  return catalog.find((app) => {
    const parent = app.bundleIdentifier.toLowerCase();
    return normalized === parent || normalized.startsWith(`${parent}.`);
  });
}

export interface MeetingPresenceProvider {
  icon(input: { bundleIdentifier: string }): Promise<string | null>;
  state(input: void): Promise<MeetingPresenceState>;
}

type TrackedMeeting = {
  meeting: MeetingPresenceMeeting;
  /** Last tick at which the app still held the microphone. */
  lastLiveAt: number;
};

/**
 * Main-owned "is the user in a call?" detector.
 *
 * Watches the audio process list from the capture SDK and reports meeting
 * apps that currently hold the microphone. It only observes; Main's
 * MeetingRecorderService applies startup consent and later-meeting auto-start.
 * Each detected call gets a stable key for its lifetime, so a dismissed prompt
 * is not re-raised on every mic flap.
 */
export class MeetingPresenceService implements MeetingPresenceProvider {
  readonly #browserBundleIdentifier: string;
  readonly #readBrowserMeetings: () => Promise<BrowserMeeting[]>;
  readonly #catalog: readonly MeetingAppDescriptor[];
  readonly #inactiveGraceMs: number;
  readonly #loadNative: () => Promise<NativeAudioCapture | undefined>;
  readonly #now: () => number;
  readonly #onStateChanged: (state: MeetingPresenceState) => void;
  readonly #pollIntervalMs: number;
  readonly #setInterval: (fn: () => void, ms: number) => unknown;
  readonly #clearInterval: (handle: unknown) => void;
  readonly #readAppIcon: (bundleIdentifier: string) => Promise<string | undefined>;

  #native: NativeAudioCapture | undefined;
  #available = false;
  #revision = 1;
  #tracked = new Map<string, TrackedMeeting>();
  #timer: unknown;
  #unsubscribe: (() => void) | undefined;
  #started = false;
  #closed = false;
  #refreshing: Promise<void> | undefined;
  /**
   * Meeting-app processes from the last process-list read. Listing about 40
   * audio processes costs Main's thread 6-20 ms of synchronous CoreAudio and
   * LaunchServices calls, and up to about 90 ms when cold, which stalls an
   * open menu. So a process-list event, an explicit refresh or the slow
   * backstop reads the list again, and the poll re-checks just these
   * processes' microphones (about 1 ms each).
   */
  #candidates: Array<{ app: MeetingAppDescriptor; processId: number }> = [];
  #listStale = true;
  #listedAt = 0;

  constructor({
    browserBundleIdentifier = "surf.comma.desktop",
    readBrowserMeetings = async () => [],
    catalog = MEETING_APPS,
    clearInterval: clearIntervalImpl = (handle) => clearInterval(handle as never),
    inactiveGraceMs = DEFAULT_INACTIVE_GRACE_MS,
    loadNative = loadNativeAudioCapture,
    now = () => Date.now(),
    onStateChanged,
    readAppIcon = async () => undefined,
    pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
    setInterval: setIntervalImpl = (fn, ms) => setInterval(fn, ms),
  }: {
    browserBundleIdentifier?: string | undefined;
    readBrowserMeetings?: () => Promise<BrowserMeeting[]>;
    catalog?: readonly MeetingAppDescriptor[];
    clearInterval?: (handle: unknown) => void;
    inactiveGraceMs?: number;
    loadNative?: () => Promise<NativeAudioCapture | undefined>;
    now?: () => number;
    onStateChanged: (state: MeetingPresenceState) => void;
    readAppIcon?: (bundleIdentifier: string) => Promise<string | undefined>;
    pollIntervalMs?: number;
    setInterval?: (fn: () => void, ms: number) => unknown;
  }) {
    this.#browserBundleIdentifier = browserBundleIdentifier;
    this.#readBrowserMeetings = readBrowserMeetings;
    this.#catalog = catalog;
    this.#readAppIcon = readAppIcon;
    this.#clearInterval = clearIntervalImpl;
    this.#inactiveGraceMs = inactiveGraceMs;
    this.#loadNative = loadNative;
    this.#now = now;
    this.#onStateChanged = onStateChanged;
    this.#pollIntervalMs = pollIntervalMs;
    this.#setInterval = setIntervalImpl;
  }

  /** Resolve the native SDK and begin watching. Safe to call once. */
  async start(): Promise<MeetingPresenceState> {
    if (this.#started || this.#closed) return this.#snapshot();
    this.#started = true;
    this.#native = await this.#loadNative();
    this.#available = Boolean(this.#native);
    if (!this.#native) return this.#publish();

    this.#unsubscribe = this.#native.onApplicationListChanged(() => {
      void this.refresh();
    });
    this.#timer = this.#setInterval(() => {
      void this.#tickOnce();
    }, this.#pollIntervalMs);
    await this.refresh();
    return this.#snapshot();
  }

  async state(): Promise<MeetingPresenceState> {
    if (!this.#started) await this.start();
    return this.#snapshot();
  }

  async icon({
    bundleIdentifier,
  }: {
    bundleIdentifier: string;
  }): Promise<string | null> {
    const app = this.#catalog.find(
      (entry) => entry.bundleIdentifier === bundleIdentifier && entry.kind === "native"
    );
    return app ? ((await this.#readAppIcon(app.bundleIdentifier)) ?? null) : null;
  }

  /** Re-derive presence from the live process list. Coalesces overlapping calls. */
  refresh(): Promise<void> {
    this.#listStale = true;
    return this.#tickOnce();
  }

  #tickOnce(): Promise<void> {
    if (this.#refreshing) return this.#refreshing;
    this.#refreshing = Promise.resolve()
      .then(() => this.#tick())
      .finally(() => {
        this.#refreshing = undefined;
      });
    return this.#refreshing;
  }

  async close() {
    this.#closed = true;
    this.#unsubscribe?.();
    this.#unsubscribe = undefined;
    if (this.#timer !== undefined) this.#clearInterval(this.#timer);
    this.#timer = undefined;
  }

  async #tick() {
    const native = this.#native;
    if (!native || this.#closed) return;

    if (this.#listStale || this.#now() - this.#listedAt >= LIST_BACKSTOP_MS) {
      let applications: NativeAudioApplication[];
      try {
        applications = native.applications();
      } catch {
        return;
      }
      this.#listStale = false;
      this.#listedAt = this.#now();
      this.#candidates = applications.flatMap((application) => {
        const app = matchMeetingApp(application.bundleIdentifier, this.#catalog);
        return app ? [{ app, processId: application.processId }] : [];
      });
    }

    const now = this.#now();
    const live = new Map<
      string,
      { app: MeetingAppDescriptor; processId: number; browserTabId?: string }
    >();
    for (const { app, processId } of this.#candidates) {
      if (live.has(app.bundleIdentifier)) continue;
      if (native.isUsingMicrophone(processId)) {
        live.set(app.bundleIdentifier, { app, processId });
      }
    }

    const browserMeetings = await this.#readBrowserMeetings();
    if (this.#closed) return;
    for (const meeting of browserMeetings) {
      live.set(`browser:${meeting.id}`, {
        app: {
          bundleIdentifier: this.#browserBundleIdentifier,
          name: meeting.name,
          kind: "browser",
        },
        processId: meeting.processId,
        browserTabId: meeting.tabId,
      });
    }

    let changed = false;

    for (const [bundleIdentifier, { app, processId, browserTabId }] of live) {
      const tracked = this.#tracked.get(bundleIdentifier);
      if (tracked) {
        tracked.lastLiveAt = now;
        if (
          tracked.meeting.status !== "active" ||
          tracked.meeting.processId !== processId
        ) {
          tracked.meeting = { ...tracked.meeting, processId, status: "active" };
          changed = true;
        }
        continue;
      }
      this.#tracked.set(bundleIdentifier, {
        lastLiveAt: now,
        meeting: {
          ...(browserTabId ? { browserTabId } : {}),
          bundleIdentifier: app.bundleIdentifier,
          key: `${bundleIdentifier}:${now}`,
          kind: app.kind,
          name: app.name,
          processId,
          since: now,
          status: "active",
        },
      });
      changed = true;
    }

    for (const [bundleIdentifier, tracked] of this.#tracked) {
      if (live.has(bundleIdentifier)) continue;
      if (
        tracked.meeting.browserTabId ||
        now - tracked.lastLiveAt >= this.#inactiveGraceMs
      ) {
        this.#tracked.delete(bundleIdentifier);
        changed = true;
      } else if (tracked.meeting.status !== "ending") {
        tracked.meeting = { ...tracked.meeting, status: "ending" };
        changed = true;
      }
    }

    if (changed) this.#publish();
  }

  #publish(): MeetingPresenceState {
    this.#revision += 1;
    const snapshot = this.#snapshot();
    this.#onStateChanged(snapshot);
    return snapshot;
  }

  #snapshot(): MeetingPresenceState {
    return {
      available: this.#available,
      meetings: [...this.#tracked.values()]
        .map((tracked) => tracked.meeting)
        .toSorted((left, right) => left.since - right.since),
      revision: this.#revision,
    };
  }
}
