import {
  MessageChannelMain,
  utilityProcess,
  type MessagePortMain,
  type UtilityProcess,
} from "electron";
import { join } from "node:path";
import {
  nativeCorePortChannel,
  type NativePeerConnectResult,
} from "@comma/native-bridge";
import { sessionPresenceExpectationHeader } from "@comma/session-contract";
import {
  CORE_START,
  type AppRelease,
  type AppUpdateStatus,
  type ChatPickAnswer,
  type ChatPickRequest,
  type CoreToMain,
  type MainToCore,
  type UtilityDesktopStart,
  type UtilityPresence,
  type MeetingAnswer,
  type MeetingCall,
  type MeetingEvent,
  type UtilitySessionStart,
} from "@comma/core/utility-protocol";
import { CoreClient, type Opener } from "@comma/core-kernel/client";
import { proxyCommaApiRequest } from "../../protocol";
import type { MainSessionHost } from "../session/session-host";
import { getCurrentNativeCallerContext, type WebContentsRegistry } from "../ipc";
import type { CoreProvider } from "../native";
import type { FilesSaveDownloadResult } from "@comma/native-bridge";

/** What the core reads of Main's Drive node (the synchronicity service). */
export type { LocalDriveSource } from "./local-drive";

import { localDriveState, runLocalDrive, type LocalDriveSource } from "./local-drive";

export const CORE_UTILITY_BUNDLE_FILENAME = "core.js";

export function resolveCoreUtilityModulePath(mainBundleDirectory: string = __dirname) {
  return join(mainBundleDirectory, CORE_UTILITY_BUNDLE_FILENAME);
}

/** Main's meeting recorder parts as the core reaches them (modules/meeting-recorder). */
export interface CoreMeetingPort {
  command(call: MeetingCall): Promise<MeetingAnswer>;
  /** What the core is told when it (re)starts. */
  events(): MeetingEvent[];
}

/** Restarts after the core's process exits, growing to this pause. */
const restartPausesMs = [0, 1_000, 5_000, 30_000];

/** The app's own updates, as the core uses them (it decides when): Velopack's, or an e2e's scripted feed. */
export interface CoreAppUpdates {
  status(): Promise<AppUpdateStatus>;
  check(): Promise<AppRelease | null>;
  download(release: AppRelease): Promise<boolean>;
  apply(release: AppRelease): Promise<boolean>;
}

/**
 * What Main offers the core's desktop ports: the person's presence, the system browser, the app's return, the chat
 * file picker and the app's updates.
 */
export interface CoreDesktopHost {
  start: UtilityDesktopStart;
  presence(): UtilityPresence;
  openExternal(url: string): Promise<void>;
  returnToApp(): void;
  /** The file dialog on a window, for an intake the core opened (modules/chat/pick.ts); `signal`: the core gave up. */
  pickAttachments(
    request: ChatPickRequest,
    signal: AbortSignal
  ): Promise<ChatPickAnswer>;
  /** Saves bytes the core read into the Downloads folder (a Drive download): its handle, or why it could not. */
  saveDownload(input: {
    fileName: string;
    content: Uint8Array;
  }): Promise<FilesSaveDownloadResult>;
  /** Absent: the app does not update itself. */
  updates?: CoreAppUpdates | undefined;
  /**
   * Resets the app (its windows and services, this core host's process with them) once the core cleared what it keeps
   * (`app.reset`). Absent: the core's reset is not taken.
   */
  reset?: (() => void) | undefined;
}

interface Logger {
  warn(message: string, meta?: Record<string, unknown>): void;
}

/**
 * The Comma client core in its utility process. Main gives it a data directory and its session ports, hands it one
 * end of each window's channel, and carries its requests. The core runs the session lifecycle; Main keeps the
 * credential (`MainSessionHost`): the core's auth requests, its changes of Main's credential store (by reference) and
 * its Google sign-in go to the session host, and each snapshot it publishes moves Main's gate before anything acts on
 * it. Its product requests go through the same `/v1` proxy the renderer's do (Main adds the bearer it alone holds
 * and refuses a request made for a lease its gate does not hold), and the answer streams back. The core never sees a
 * credential. While the core is away (it restarts after a crash), Main's gate keeps the lease the core last confirmed.
 */
export class CoreHostService {
  readonly #modulePath: string;
  readonly #dataDir: string;
  readonly #legacyTasksPath: string | undefined;
  readonly #legacyMeetingTasksPath: string | undefined;
  #meeting: CoreMeetingPort | null = null;
  readonly #session: MainSessionHost;
  readonly #clientPlatform: UtilitySessionStart["clientPlatform"];
  readonly #logger: Logger | undefined;
  readonly #renderImagePreview:
    | ((input: { bytes: Uint8Array; mediaType: string }) => Promise<Uint8Array>)
    | undefined;
  readonly #desktop: CoreDesktopHost | undefined;
  readonly #testClock: boolean;
  readonly #stationPeers: Record<string, string[]> | undefined;
  readonly #meshAddon: string | undefined;
  /** Moves of the core's test clock under way, by id (`advanceClock`). */
  readonly #clockMoves = new Map<
    number,
    { resolve(): void; reject(error: Error): void }
  >();
  #nextClockMove = 0;
  #child: UtilityProcess | null = null;
  readonly #requests = new Map<number, AbortController>();
  /** Session ports under way for the core, by id: `abort` gives them up. */
  readonly #sessionCalls = new Map<number, AbortController>();
  readonly #restartListeners = new Set<() => void>();
  #failures = 0;
  #closed = false;
  #client: CoreClient | null = null;

  readonly #localDrive: (() => LocalDriveSource | undefined) | undefined;

  constructor(options: {
    modulePath?: string | undefined;
    dataDir: string;
    legacyTasksPath?: string | undefined;
    /** Main's meeting journal from before the core (`meeting-tasks.json`), brought over once. */
    legacyMeetingTasksPath?: string | undefined;
    session: MainSessionHost;
    logger?: Logger | undefined;
    /** The desktop ports Main answers (absent: the core has none). */
    desktop?: CoreDesktopHost | undefined;
    /**
     * An Electron e2e's (`COMMA_ELECTRON_E2E_CORE_TEST_CLOCK`, never a release's): the core's clock stands still and
     * moves only by `advanceClock`.
     */
    testClock?: boolean | undefined;
    /** An Electron e2e's (never a release's): where its stations listen, by endpoint id. */
    stationPeers?: Record<string, string[]> | undefined;
    /** The mesh addon of the station the app carries (`mesh.node`): the core reaches stations on it. */
    meshAddon?: string | undefined;
    /** Draws a workspace image the core read again with the platform's decoder (nativeImage). */
    renderImagePreview?: (input: {
      bytes: Uint8Array;
      mediaType: string;
    }) => Promise<Uint8Array>;
    /**
     * This installation's Drive node, once Main runs it: the core reads its state and listings to index Drive search
     * (core drive-catalog.ts); `driveChanged` says when its files changed.
     */
    localDrive?: (() => LocalDriveSource | undefined) | undefined;
  }) {
    this.#modulePath = options.modulePath ?? resolveCoreUtilityModulePath();
    this.#dataDir = options.dataDir;
    this.#legacyTasksPath = options.legacyTasksPath;
    this.#legacyMeetingTasksPath = options.legacyMeetingTasksPath;
    this.#session = options.session;
    this.#clientPlatform =
      process.platform === "darwin"
        ? "macos"
        : process.platform === "win32"
          ? "windows"
          : process.platform === "linux"
            ? "linux"
            : "unknown";
    // A 401 Main saw shut its gate: the core hears it as a refusal of that lease.
    this.#session.onRejected((lease) =>
      this.#post({ type: "rejected", lease, status: 401 })
    );
    this.#logger = options.logger;
    this.#renderImagePreview = options.renderImagePreview;
    this.#desktop = options.desktop;
    this.#testClock = options.testClock === true;
    this.#stationPeers = options.stationPeers;
    this.#meshAddon = options.meshAddon;
    this.#localDrive = options.localDrive;
  }

  /** The Drive node's files changed: the core indexes them again while Drive search is shown. */
  driveChanged() {
    this.#post({ type: "drive-changed" });
  }

  start() {
    if (this.#closed || this.#child) return;
    const child = utilityProcess.fork(this.#modulePath, [], {
      serviceName: "Comma Core",
      stdio: "inherit",
    });
    this.#child = child;
    child.on("message", (message: CoreToMain) => this.#receive(child, message));
    child.on("exit", (code) => {
      if (this.#child !== child) return;
      this.#child = null;
      for (const request of this.#requests.values()) request.abort();
      this.#requests.clear();
      for (const call of this.#sessionCalls.values()) call.abort();
      this.#sessionCalls.clear();
      for (const move of this.#clockMoves.values())
        move.reject(new Error("The Comma core's process went."));
      this.#clockMoves.clear();
      // The gate keeps what the core confirmed; what the core had not settled is queued for revocation.
      void this.#session.coreExited().catch((error: unknown) =>
        this.#logger?.warn("Comma core: an issued credential is still unsettled.", {
          error: error instanceof Error ? error.message : String(error),
        })
      );
      for (const listener of this.#restartListeners) listener();
      if (this.#closed) return;
      this.#logger?.warn(`Comma core exited with code ${code}; starting it again.`);
      const pause =
        restartPausesMs[Math.min(this.#failures, restartPausesMs.length - 1)] ?? 0;
      this.#failures += 1;
      setTimeout(() => this.start(), pause);
    });
    this.#post({
      type: CORE_START,
      dataDir: this.#dataDir,
      ...(this.#legacyTasksPath ? { legacyTasksPath: this.#legacyTasksPath } : {}),
      ...(this.#localDrive ? { localDrive: true as const } : {}),
      ...(this.#legacyMeetingTasksPath
        ? { legacyMeetingTasksPath: this.#legacyMeetingTasksPath }
        : {}),
      session: {
        apiOrigin: this.#session.apiOrigin,
        clientPlatform: this.#clientPlatform,
        resumed: this.#session.resume(),
      },
      ...(this.#desktop
        ? {
            desktop: {
              ...this.#desktop.start,
              ...(this.#desktop.updates ? { updates: true as const } : {}),
            },
          }
        : {}),
      ...(this.#testClock ? { testClock: true as const } : {}),
      ...(this.#stationPeers ? { stationPeers: this.#stationPeers } : {}),
      ...(this.#meshAddon ? { meshAddon: this.#meshAddon } : {}),
    });
    for (const event of this.#meeting?.events() ?? []) this.meetingEvent(event);
  }

  /**
   * Moves the core's test clock `ms` forward (`testClock`): done once each timer due on the way ran and what it asked
   * of Main was answered, so a test sees what became due as settled. Moves run one after another.
   */
  advanceClock(ms: number): Promise<void> {
    if (!this.#testClock)
      return Promise.reject(new Error("The core has no test clock."));
    const child = this.#child;
    if (!child) return Promise.reject(new Error("The Comma core is not running."));
    const id = ++this.#nextClockMove;
    return new Promise<void>((resolve, reject) => {
      this.#clockMoves.set(id, { resolve, reject });
      this.#post({ type: "clock", id, ms }, child);
    });
  }

  /** Main's meeting recorder parts: the core's commands go to them; what they know now is told to the core. */
  setMeeting(meeting: CoreMeetingPort): void {
    this.#meeting = meeting;
    for (const event of meeting.events()) this.meetingEvent(event);
  }

  /** Tells the core what Main's meeting parts saw (nothing while it is not running: it hears it all on start). */
  meetingEvent(event: MeetingEvent): void {
    this.#post({ type: "meeting-event", event });
  }

  /**
   * Hands the core a channel's end: a window's (`surface`, its id: the core lets it act only as that window) or
   * Main's own (no surface, `host`: it may make the calls that answer credentials). False when the core is not running.
   */
  attach(
    port: MessagePortMain,
    surface?: string,
    session = true,
    host = false
  ): boolean {
    const child = this.#child;
    if (!child) return false;
    child.postMessage(
      {
        type: "client",
        ...(surface ? { surface } : {}),
        ...(session ? {} : { session: false as const }),
        ...(host ? { host: true as const } : {}),
      } satisfies MainToCore,
      [port]
    );
    return true;
  }

  /**
   * Main's own client of the core, for what Main shows (the menu-bar Tasks): a
   * channel like a window's, opened again after the core's process restarts.
   */
  client(): CoreClient {
    this.#client ??= new CoreClient(this.#mainOpener(), {
      onFault: (error) => this.#logger?.warn(`Comma core: ${error.message}`),
    });
    return this.#client;
  }

  #mainOpener(): Opener {
    return (onMessage, onFail) => {
      const { port1, port2 } = new MessageChannelMain();
      if (!this.attach(port2, undefined, true, true)) {
        port1.close();
        port2.close();
        throw new Error("The Comma core is not running.");
      }
      port1.on("message", (event) => onMessage(event.data));
      port1.start();
      const stop = this.onExit(() => onFail("The Comma core's process went."));
      return {
        // oxlint-disable-next-line unicorn/require-post-message-target-origin -- a port has no target origin
        post: (message) => port1.postMessage(message),
        close: () => {
          stop();
          port1.close();
        },
      };
    };
  }

  /** Told when the core's process went (every window's channel to it went with it). */
  onExit(listener: () => void) {
    this.#restartListeners.add(listener);
    return () => this.#restartListeners.delete(listener);
  }

  close() {
    this.#closed = true;
    this.#client?.close();
    for (const request of this.#requests.values()) request.abort();
    this.#requests.clear();
    this.#child?.kill();
    this.#child = null;
  }

  #post(message: MainToCore, child: UtilityProcess | null = this.#child) {
    // oxlint-disable-next-line unicorn/require-post-message-target-origin -- a utility process has no target origin
    child?.postMessage(message);
  }

  #receive(child: UtilityProcess, message: CoreToMain) {
    if (this.#child !== child) return;
    if (message.type === "abort") {
      this.#requests.get(message.id)?.abort();
      this.#requests.delete(message.id);
      this.#sessionCalls.get(message.id)?.abort();
      this.#sessionCalls.delete(message.id);
      return;
    }
    if (message.type === "clock-done") {
      const move = this.#clockMoves.get(message.id);
      this.#clockMoves.delete(message.id);
      if (message.error === undefined) move?.resolve();
      else move?.reject(new Error(message.error));
      return;
    }
    if (message.type === "gate") {
      this.#session.gate(message.snapshot, message.lease);
      return;
    }
    if (message.type === "reset") {
      this.#desktop?.reset?.();
      return;
    }
    if (message.type === "session-dropped") {
      void this.#session.dropped(message.id);
      return;
    }
    if (message.type === "session") {
      void this.#sessionCall(child, message);
      return;
    }
    if (message.type === "meeting") {
      void this.#meetingCall(child, message);
      return;
    }
    if (message.type === "fetch") void this.#fetch(child, message);
    if (message.type === "preview") void this.#preview(child, message);
    if (message.type === "drive") void this.#driveRead(child, message);
  }

  /** A request of the core to the Drive node: its state, one listing page, or one of its operations. */
  async #driveRead(
    child: UtilityProcess,
    message: Extract<CoreToMain, { type: "drive" }>
  ) {
    let out: MainToCore;
    try {
      const drive = this.#localDrive?.();
      if (!drive) throw new Error("Drive is unavailable.");
      let value: unknown;
      if (message.op === "state") value = localDriveState(await drive.state());
      else if (message.op === "list") {
        const page = await drive.list(message.input);
        value = { entries: page.entries, nextCursor: page.nextCursor };
      } else value = await runLocalDrive(drive, message.name, message.input);
      out = { type: "drive-done", id: message.id, value };
    } catch (error) {
      out = {
        type: "drive-done",
        id: message.id,
        error: error instanceof Error ? error.message : String(error),
      };
    }
    if (this.#child === child) this.#post(out, child);
  }

  /** A session port the core asked for: answered to that process only, unless it gave the call up. */
  async #sessionCall(
    child: UtilityProcess,
    message: Extract<CoreToMain, { type: "session" }>
  ) {
    const controller = new AbortController();
    this.#sessionCalls.set(message.id, controller);
    let out: MainToCore;
    try {
      const value = await this.#runSession(message, controller.signal);
      out = { type: "session-done", id: message.id, value };
    } catch (error) {
      out = {
        type: "session-done",
        id: message.id,
        error: error instanceof Error ? error.message : String(error),
      };
    }
    const given = this.#sessionCalls.get(message.id) === controller;
    this.#sessionCalls.delete(message.id);
    if (given && this.#child === child) this.#post(out, child);
    else if (message.op === "auth") void this.#session.dropped(message.id);
  }

  #runSession(
    message: Extract<CoreToMain, { type: "session" }>,
    signal: AbortSignal
  ): Promise<unknown> {
    switch (message.op) {
      case "auth":
        return this.#session.authFetch(message.input, {
          requestId: message.id,
          signal,
        });
      case "vault":
        return this.#session.vault();
      case "change":
        return this.#session.change(message.input);
      case "google":
        return this.#session.google(message.input, signal);
      case "googleDone":
        this.#session.googleDone(message.input.grant, message.input.ok);
        return Promise.resolve(null);
      case "presence":
        return Promise.resolve(
          this.#desktop?.presence() ?? { idleSeconds: 0, homeRepliesShown: false }
        );
      case "openExternal":
        if (!this.#desktop) return Promise.reject(new Error("No system browser."));
        // Only a web page: never a file or another app's scheme.
        if (
          !URL.canParse(message.input.url) ||
          new URL(message.input.url).protocol !== "https:"
        )
          return Promise.reject(new Error("Only https pages open in the browser."));
        return this.#desktop.openExternal(message.input.url).then(() => null);
      case "returnToApp":
        this.#desktop?.returnToApp();
        return Promise.resolve(null);
      case "chatPick":
        if (!this.#desktop) return Promise.reject(new Error("No file dialog."));
        return this.#desktop.pickAttachments(message.input, signal);
      case "saveDownload":
        if (!this.#desktop) return Promise.reject(new Error("No Downloads folder."));
        return this.#desktop
          .saveDownload(message.input)
          .then((saved) =>
            saved.status === "saved"
              ? { downloadRef: saved.downloadRef, fileName: saved.fileName }
              : null
          );
      case "updateStatus":
        return this.#updates(message.op, (updates) => updates.status());
      case "updateCheck":
        return this.#updates(message.op, (updates) => updates.check());
      case "updateDownload":
        return this.#updates(message.op, (updates) => updates.download(message.input));
      case "updateApply":
        return this.#updates(message.op, (updates) => updates.apply(message.input));
    }
  }

  /** An update port for the core; a failure is logged here too (the core only retries). */
  async #updates<A>(op: string, run: (updates: CoreAppUpdates) => Promise<A>) {
    const updates = this.#desktop?.updates;
    if (!updates) throw new Error("This app does not update itself.");
    try {
      return await run(updates);
    } catch (error) {
      this.#logger?.warn(`Comma core: ${op} failed.`, {
        error: error instanceof Error ? error.message : String(error),
      });
      throw error;
    }
  }

  /** A meeting command: answered to the process that gave it. */
  async #meetingCall(
    child: UtilityProcess,
    message: Extract<CoreToMain, { type: "meeting" }>
  ) {
    const { type: _type, id, ...call } = message;
    let out: MainToCore;
    try {
      if (!this.#meeting) throw new Error("Meeting recording is not ready.");
      out = {
        type: "meeting-done",
        id,
        answer: await this.#meeting.command(call as MeetingCall),
      };
    } catch (error) {
      out = {
        type: "meeting-done",
        id,
        error: error instanceof Error ? error.message : String(error),
      };
    }
    if (this.#child === child) this.#post(out, child);
  }

  async #preview(
    child: UtilityProcess,
    message: Extract<CoreToMain, { type: "preview" }>
  ) {
    let out: MainToCore;
    try {
      if (!this.#renderImagePreview) throw new Error("Image previews are unavailable.");
      const bytes = await this.#renderImagePreview({
        bytes: new Uint8Array(message.bytes),
        mediaType: message.mediaType,
      });
      out = { type: "preview-done", id: message.id, bytes };
    } catch (error) {
      out = {
        type: "preview-done",
        id: message.id,
        error: error instanceof Error ? error.message : String(error),
      };
    }
    if (this.#child === child) this.#post(out, child);
  }

  async #fetch(child: UtilityProcess, message: Extract<CoreToMain, { type: "fetch" }>) {
    const { id } = message;
    const controller = new AbortController();
    this.#requests.set(id, controller);
    const answer = (out: MainToCore) => {
      if (this.#child === child && this.#requests.get(id) === controller)
        this.#post(out, child);
    };
    try {
      const authority = this.#session;
      const headers = new Headers(message.headers);
      headers.set(
        sessionPresenceExpectationHeader,
        JSON.stringify({
          authorityInstanceId: message.lease.authorityInstanceId,
          expectedAudience: message.lease.audience,
          expectedSessionId: message.lease.sessionId,
          generation: message.lease.generation,
        })
      );
      // The renderer's own proxy path: the same header allowlist, credential
      // injection, lease checks and replay of an unanswered read.
      const url = new URL(message.path, "assets://.");
      const request = new Request(new URL(message.path, "https://core.invalid"), {
        body: message.body ? new Uint8Array(message.body) : null,
        headers,
        method: message.method,
        signal: controller.signal,
      });
      const response = await proxyCommaApiRequest(request, url, authority);
      answer({
        type: "head",
        id,
        status: response.status,
        headers: [...response.headers],
      });
      const reader = response.body?.getReader();
      if (reader) {
        // The core may have let the request go while its head was still on the way: the stream ends here, not open
        // and unread upstream.
        if (controller.signal.aborted) {
          await reader.cancel();
          return;
        }
        controller.signal.addEventListener("abort", () => void reader.cancel());
        for (;;) {
          const next = await reader.read();
          if (next.done) break;
          answer({ type: "chunk", id, bytes: next.value });
        }
      }
      answer({ type: "end", id });
      this.#failures = 0;
    } catch (error) {
      answer({
        type: "fail",
        id,
        message: error instanceof Error ? error.message : String(error),
      });
    } finally {
      if (this.#requests.get(id) === controller) this.#requests.delete(id);
    }
  }
}

/**
 * `core.open`: a channel from the calling window to the core. The window's end
 * arrives on `nativeCorePortChannel`; when the window closes its end closes, and
 * when the core's process goes the window hears the channel closed.
 */
export class CoreChannelService implements CoreProvider {
  readonly #host: CoreHostService;
  readonly #registry: WebContentsRegistry;
  readonly #channels = new Map<string, { windowId: string; port: MessagePortMain }>();
  #next = 1;

  constructor({
    host,
    registry,
  }: {
    host: CoreHostService;
    registry: WebContentsRegistry;
  }) {
    this.#host = host;
    this.#registry = registry;
    registry.onWindowUnregistered((registration) => {
      for (const [channelId, channel] of this.#channels) {
        if (channel.windowId !== registration.id) continue;
        this.#channels.delete(channelId);
        channel.port.close();
      }
    });
    host.onExit(() => {
      for (const [channelId, channel] of this.#channels) {
        this.#channels.delete(channelId);
        channel.port.close();
        this.#registry
          .getWindowRegistration(channel.windowId)
          ?.window.webContents.postMessage?.(nativeCorePortChannel, {
            channelId,
            kind: "closed",
          });
      }
    });
  }

  open(_input?: void): NativePeerConnectResult {
    const caller = getCurrentNativeCallerContext();
    const registration = this.#registry.getWindowRegistrationByWebContentsId(
      caller.webContentsId
    );
    if (!registration?.window.webContents.postMessage)
      throw new Error("The window is not registered.");
    const { port1, port2 } = new MessageChannelMain();
    // Only the main window signs in and out; the others show the session and run under it.
    if (
      !this.#host.attach(port2, registration.id, registration.role === "main-window")
    ) {
      port1.close();
      port2.close();
      throw new Error("The Comma core is not running.");
    }
    const channelId = `core_${this.#next++}`;
    this.#channels.set(channelId, { port: port1, windowId: registration.id });
    registration.window.webContents.postMessage(
      nativeCorePortChannel,
      { channelId, kind: "connected" },
      [port1]
    );
    return { channelId };
  }
}
