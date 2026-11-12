import type { BrowserMeeting } from "../browser-sidebar/meeting-presence";
import type {
  MeetingPresenceMeeting,
  MeetingPresenceState,
} from "@comma/native-bridge";

import { clockInterval, realMainClock, type MainClock } from "../../clock";
import type { MicrophoneWatch } from "./microphone-watch";

/**
 * Main's tick: it probes the in-app browser for meetings and ends calls whose
 * grace period ran out. The worker checks microphones on its own 2 s poll.
 */
const DEFAULT_POLL_INTERVAL_MS = 2_000;
/**
 * The tick still re-lists processes this often, in case a process-list event
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

type MeetingCandidate = { app: MeetingAppDescriptor; processId: number };

/**
 * The candidates' processes, one group per meeting app in list order. Helper
 * processes stay in their app's group: browsers and Slack hold the
 * microphone in a helper.
 */
function groupByApp(candidates: readonly MeetingCandidate[]): number[][] {
  const groups = new Map<string, number[]>();
  for (const { app, processId } of candidates) {
    const group = groups.get(app.bundleIdentifier);
    if (group) group.push(processId);
    else groups.set(app.bundleIdentifier, [processId]);
  }
  return [...groups.values()];
}

/**
 * Main-owned "is the user in a call?" detector.
 *
 * Watches the audio process list from the capture SDK and reports meeting
 * apps that currently hold the microphone. A worker makes the CoreAudio calls
 * (`MicrophoneWatch`); this service keeps the state machine on Main. It only
 * observes; Main's MeetingRecorderService applies startup consent and
 * later-meeting auto-start. Each detected call gets a stable key for its
 * lifetime, so a dismissed prompt is not re-raised on every mic flap.
 */
export class MeetingPresenceService implements MeetingPresenceProvider {
  readonly #browserBundleIdentifier: string;
  readonly #readBrowserMeetings: () => Promise<BrowserMeeting[]>;
  readonly #catalog: readonly MeetingAppDescriptor[];
  readonly #clock: MainClock;
  readonly #inactiveGraceMs: number;
  readonly #loadNative: () => Promise<MicrophoneWatch | undefined>;
  readonly #onStateChanged: (state: MeetingPresenceState) => void;
  readonly #pollIntervalMs: number;
  readonly #readAppIcon: (bundleIdentifier: string) => Promise<string | undefined>;

  #native: MicrophoneWatch | undefined;
  #available = false;
  #revision = 1;
  #tracked = new Map<string, TrackedMeeting>();
  #stopPolling: (() => void) | undefined;
  #unsubscribe: Array<() => void> = [];
  #started = false;
  #closed = false;
  #refreshing: Promise<void> | undefined;
  /** A tick was asked for while one ran: it runs once more afterwards. */
  #tickAgain = false;
  /**
   * Meeting-app processes from the last process-list read, and the groups the
   * worker watches (one per app). A process-list event, an explicit refresh
   * or the slow backstop reads the list again; in between the worker
   * re-checks just these processes' microphones.
   */
  #candidates: MeetingCandidate[] = [];
  #listStale = true;
  #listedAt = 0;

  constructor({
    browserBundleIdentifier = "surf.comma.desktop",
    readBrowserMeetings = async () => [],
    catalog = MEETING_APPS,
    clock = realMainClock,
    inactiveGraceMs = DEFAULT_INACTIVE_GRACE_MS,
    loadNative,
    onStateChanged,
    readAppIcon = async () => undefined,
    pollIntervalMs = DEFAULT_POLL_INTERVAL_MS,
  }: {
    browserBundleIdentifier?: string | undefined;
    readBrowserMeetings?: () => Promise<BrowserMeeting[]>;
    catalog?: readonly MeetingAppDescriptor[];
    /** Main's clock: the tick, the list backstop and the inactive grace. */
    clock?: MainClock;
    inactiveGraceMs?: number;
    /** Starts the CoreAudio worker; undefined where the capture SDK is unavailable. */
    loadNative: () => Promise<MicrophoneWatch | undefined>;
    onStateChanged: (state: MeetingPresenceState) => void;
    readAppIcon?: (bundleIdentifier: string) => Promise<string | undefined>;
    pollIntervalMs?: number;
  }) {
    this.#browserBundleIdentifier = browserBundleIdentifier;
    this.#readBrowserMeetings = readBrowserMeetings;
    this.#catalog = catalog;
    this.#readAppIcon = readAppIcon;
    this.#clock = clock;
    this.#inactiveGraceMs = inactiveGraceMs;
    this.#loadNative = loadNative;
    this.#onStateChanged = onStateChanged;
    this.#pollIntervalMs = pollIntervalMs;
  }

  /** Start the CoreAudio worker and begin watching. Safe to call once. */
  async start(): Promise<MeetingPresenceState> {
    if (this.#started || this.#closed) return this.#snapshot();
    this.#started = true;
    const native = await this.#loadNative();
    if (this.#closed) {
      await native?.close();
      return this.#snapshot();
    }
    this.#native = native;
    this.#available = Boolean(native);
    if (!native) return this.#publish();

    this.#unsubscribe = [
      native.onApplicationListChanged(() => {
        void this.refresh();
      }),
      native.onMicrophonesChanged(() => {
        void this.#tickOnce();
      }),
    ];
    this.#stopPolling = clockInterval(this.#clock, this.#pollIntervalMs, () => {
      void this.#tickOnce();
    });
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

  /**
   * Re-derive presence from a fresh process list and microphone check.
   * Coalesces overlapping calls: a call during a tick runs one more after it.
   */
  refresh(): Promise<void> {
    this.#listStale = true;
    return this.#tickOnce();
  }

  #tickOnce(): Promise<void> {
    if (this.#refreshing) {
      this.#tickAgain = true;
      return this.#refreshing;
    }
    this.#refreshing = (async () => {
      try {
        do {
          this.#tickAgain = false;
          await this.#tick();
        } while (this.#tickAgain && !this.#closed);
      } finally {
        this.#refreshing = undefined;
      }
    })();
    return this.#refreshing;
  }

  async close() {
    this.#closed = true;
    for (const unsubscribe of this.#unsubscribe.splice(0)) unsubscribe();
    this.#stopPolling?.();
    this.#stopPolling = undefined;
    await this.#native?.close();
  }

  async #tick() {
    const native = this.#native;
    if (!native || this.#closed) return;

    if (this.#listStale || this.#clock.now() - this.#listedAt >= LIST_BACKSTOP_MS) {
      // Cleared first, so a list event during the read asks for another.
      this.#listStale = false;
      let candidates: MeetingCandidate[];
      try {
        candidates = (await native.applications()).flatMap((application) => {
          const app = matchMeetingApp(application.bundleIdentifier, this.#catalog);
          return app ? [{ app, processId: application.processId }] : [];
        });
        // Each re-list hands the worker its groups, and it checks their
        // microphones before it answers.
        await native.watch(groupByApp(candidates));
      } catch {
        this.#listStale = true;
        // The worker stopped too often to start again: no app's meeting can
        // be seen, so detection reports itself unavailable.
        if (!native.available()) this.#becomeUnavailable();
        return;
      }
      if (this.#closed) return;
      this.#listedAt = this.#clock.now();
      this.#candidates = candidates;
    }

    const browserMeetings = await this.#readBrowserMeetings();
    if (this.#closed) return;

    const now = this.#clock.now();
    const live = new Map<
      string,
      { app: MeetingAppDescriptor; processId: number; browserTabId?: string }
    >();
    // The worker answers with each app's first process on the microphone.
    for (const processId of native.microphones()) {
      const candidate = this.#candidates.find((entry) => entry.processId === processId);
      if (!candidate || live.has(candidate.app.bundleIdentifier)) continue;
      live.set(candidate.app.bundleIdentifier, { app: candidate.app, processId });
    }
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

  #becomeUnavailable() {
    if (!this.#available) return;
    this.#available = false;
    this.#stopPolling?.();
    this.#stopPolling = undefined;
    this.#tracked.clear();
    this.#candidates = [];
    this.#publish();
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
