import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { join } from "node:path";

import {
  chatProtocolVersion,
  sideChatClientFrameSchema,
  sideChatGeometrySettingsSchema,
  sideChatHostFrameSchema,
  sideChatPresentationSchema,
  type ChatCommandReceipt,
  type SideChatClientFrame,
  type SideChatContentSizeInput,
  type SideChatDebugSettingsValues,
  type SideChatHostFrame,
  type SideChatInteractiveCompletionInput,
  type SideChatInteractiveProgressInput,
  type SideChatPresentation,
  type SideChatShortcutRegistrationInput,
  type StatusMenuRow,
} from "@comma/chat-contract";
import {
  defaultSideChatShortcut,
  defaultSideChatDebugSettings,
  deriveSideChatDebugGeometry,
  sideChatDebugSettingsPatchSchema,
  sideChatDebugSettingsSchema,
  sideChatShortcutBindingSchema,
  unavailableSideChatPresentation,
  type SideChatDebugSettings,
  type SideChatDebugSettingsPatch,
  type SideChatOpenTestWindowInput,
  type SideChatShortcut,
  type SideChatShortcutBinding,
} from "@comma/native-bridge";
import { app } from "electron";
import log from "electron-log/main";

type SpawnSideChatHost = (
  executablePath: string,
  environment: NodeJS.ProcessEnv
) => ChildProcessWithoutNullStreams;

export interface SideChatBackdropGeometry {
  windowWidth: number;
  windowHeight: number;
  contentX: number;
  contentY: number;
  contentWidth: number;
  contentHeight: number;
  visualWidth: number;
  visualHeight: number;
}

export interface SideChatBackdropLike {
  attach(handle: Buffer): boolean;
  detach(): void;
  isAvailable(): boolean;
  rebuild(): boolean;
  setRevealOffset(offsetX: number): boolean;
  updateSettings(settings: SideChatDebugSettingsValues): boolean;
  updateGeometry(geometry: SideChatBackdropGeometry): boolean;
}

export interface SideChatWindowBounds {
  height: number;
  width: number;
  x: number;
  y: number;
}

export interface SideChatBrowserWindowLike {
  focus(): void;
  getNativeWindowHandle(): Buffer;
  hide(): void;
  isDestroyed(): boolean;
  on(event: "closed" | "ready-to-show", listener: () => void): void;
  setBounds(bounds: SideChatWindowBounds, animate?: boolean): void;
  show(): void;
  showInactive(): void;
}

interface SideChatWindowAttachment {
  backdrop: SideChatBackdropLike;
  browserWindow: SideChatBrowserWindowLike;
  toElectronBounds(
    presentation: SideChatPresentation
  ): SideChatWindowBounds | undefined;
}

interface NativeSideChatServiceOptions {
  activateOpenWindow?: boolean;
  onCloseTestWindow?: () => Promise<void> | void;
  onDebugSettingsChanged?: (settings: SideChatDebugSettings) => void;
  onEnabledChanged?: (enabled: boolean) => void;
  onOpenSettings?: () => Promise<void> | void;
  onOpenTestWindow?: (input: SideChatOpenTestWindowInput) => Promise<void> | void;
  onPresentationChanged?: (presentation: SideChatPresentation) => void;
  resolveExecutablePath?: () => string;
  spawnHost?: SpawnSideChatHost;
}

interface SideChatFailCloseBarrier {
  readonly closeAcknowledged: boolean;
  readonly closeRequestId: string;
  readonly epoch: number;
  readonly helperGeneration: number;
  readonly reason: string;
  readonly windowGeneration: number;
}

interface SideChatFailCloseRecoveryState {
  readonly barrier: SideChatFailCloseBarrier | undefined;
  readonly epoch: number;
  readonly queuedReopenEpoch: number | undefined;
}

type SideChatFailCloseRecoveryEvent =
  | {
      readonly helperGeneration: number;
      readonly closeRequestId: string;
      readonly reason: string;
      readonly type: "begin";
      readonly windowGeneration: number;
    }
  | { readonly type: "cancel-reopen" }
  | { readonly type: "queue-reopen" }
  | {
      readonly helperGeneration: number;
      readonly ok: boolean;
      readonly requestId: string;
      readonly type: "helper-command-result";
    }
  | {
      readonly helperGeneration: number;
      readonly type: "helper-closed" | "helper-lost";
    }
  | { readonly type: "reset" };

interface SideChatFailCloseRecoveryTransition {
  readonly released: boolean;
  readonly shouldReopen: boolean;
  readonly state: SideChatFailCloseRecoveryState;
}

interface SideChatSentControl {
  readonly helperGeneration: number;
  readonly requestId: string;
}

interface PendingSideChatShortcutRegistrationBase {
  readonly helperGeneration: number;
  readonly requestId: string;
  readonly shortcut: SideChatShortcutBinding;
  readonly timeout: ReturnType<typeof setTimeout>;
}

type PendingSideChatShortcutRegistration = PendingSideChatShortcutRegistrationBase &
  (
    | { readonly type: "replay" }
    | {
        readonly reject: (error: Error) => void;
        readonly resolve: (shortcut: SideChatShortcutBinding) => void;
        readonly type: "update";
      }
  );

interface QueuedSideChatShortcutUpdate {
  readonly reject: (error: Error) => void;
  readonly resolve: (shortcut: SideChatShortcutBinding) => void;
  readonly shortcut: SideChatShortcutBinding;
}

const INITIAL_FAIL_CLOSE_RECOVERY_STATE: SideChatFailCloseRecoveryState = {
  barrier: undefined,
  epoch: 0,
  queuedReopenEpoch: undefined,
};

const RESTART_DELAY_MS = 1_000;
const SHORTCUT_REGISTRATION_TIMEOUT_MS = 5_000;
// Cardinality is exactly one timer for the one persistent Side Chat window,
// and it exists only while the native-quality effect is visibly in use.
const BACKDROP_HEALTH_POLL_MS = 100;
const SIDE_CHAT_ENVIRONMENT_KEYS = ["LANG", "LC_ALL", "LC_CTYPE", "PATH"] as const;
const DEFAULT_CONTENT_SIZE: SideChatContentSizeInput = { height: 254, width: 400 };
const CARBON_CONTROL_KEY = 1 << 12;
const CARBON_OPTION_KEY = 1 << 11;
const CARBON_SHIFT_KEY = 1 << 9;
const CARBON_COMMAND_KEY = 1 << 8;
// These ANSI codes intentionally match the physical KeyboardEvent.code
// positions recorded by the renderer, independent of the active key layout.
const MAC_KEY_CODES: Record<SideChatShortcut["key"], number> = {
  space: 49,
  comma: 43,
  a: 0,
  b: 11,
  c: 8,
  d: 2,
  e: 14,
  f: 3,
  g: 5,
  h: 4,
  i: 34,
  j: 38,
  k: 40,
  l: 37,
  m: 46,
  n: 45,
  o: 31,
  p: 35,
  q: 12,
  r: 15,
  s: 1,
  t: 17,
  u: 32,
  v: 9,
  w: 13,
  x: 7,
  y: 16,
  z: 6,
  "0": 29,
  "1": 18,
  "2": 19,
  "3": 20,
  "4": 21,
  "5": 23,
  "6": 22,
  "7": 26,
  "8": 28,
  "9": 25,
};

/**
 * Owns only Side Chat presentation orchestration. Conversation data now stays
 * on the generated renderer chat bridge; the Swift partner is deliberately a
 * credential-free raw-trackpad/global-hotkey state machine.
 */
export class NativeSideChatService {
  readonly #activateOpenWindow: boolean;
  readonly #onCloseTestWindow: (() => Promise<void> | void) | undefined;
  readonly #onDebugSettingsChanged:
    | ((settings: SideChatDebugSettings) => void)
    | undefined;
  readonly #onEnabledChanged: ((enabled: boolean) => void) | undefined;
  readonly #onOpenSettings: (() => Promise<void> | void) | undefined;
  readonly #onOpenTestWindow:
    | ((input: SideChatOpenTestWindowInput) => Promise<void> | void)
    | undefined;
  readonly #onPresentationChanged:
    | ((presentation: SideChatPresentation) => void)
    | undefined;
  readonly #resolveExecutablePath: () => string;
  readonly #spawnHost: SpawnSideChatHost;
  #attachment: SideChatWindowAttachment | undefined;
  #attachmentWindowGeneration = 0;
  #backdropAttachAttempted = false;
  #backdropAttached = false;
  #backdropCanRebuild = false;
  #backdropHealthTimer: ReturnType<typeof setInterval> | undefined;
  #backdropUnavailable = false;
  #contentSize = DEFAULT_CONTENT_SIZE;
  #desiredOpen = false;
  #debugSettings: SideChatDebugSettings = { ...defaultSideChatDebugSettings };
  #disposed = false;
  #enabled = true;
  #geometryKey = "";
  #failCloseRecovery = INITIAL_FAIL_CLOSE_RECOVERY_STATE;
  #host: ChildProcessWithoutNullStreams | undefined;
  #hostGeneration = 0;
  #lastHostPresentationRevision = -1;
  #lastBoundsKey = "";
  #presentation: SideChatPresentation = unavailableSideChatPresentation;
  #presentationRevision = 0;
  #activeShortcutRegistration: PendingSideChatShortcutRegistration | undefined;
  #confirmedShortcutGeneration: number | undefined;
  #queuedShortcutUpdate: QueuedSideChatShortcutUpdate | undefined;
  #restartTimer: ReturnType<typeof setTimeout> | undefined;
  #shortcut: SideChatShortcutBinding = structuredClone(defaultSideChatShortcut);
  #started = false;
  #statusMenu:
    | { menu: StatusMenu; onLost: () => void; onSelect: (id: string) => void }
    | undefined;
  #windowGeneration = 0;
  #windowReady = false;

  constructor({
    activateOpenWindow = true,
    onCloseTestWindow,
    onDebugSettingsChanged,
    onEnabledChanged,
    onOpenSettings,
    onOpenTestWindow,
    onPresentationChanged,
    resolveExecutablePath = resolveNativeSideChatExecutablePath,
    spawnHost = defaultSpawnHost,
  }: NativeSideChatServiceOptions = {}) {
    this.#activateOpenWindow = activateOpenWindow;
    this.#onCloseTestWindow = onCloseTestWindow;
    this.#onDebugSettingsChanged = onDebugSettingsChanged;
    this.#onEnabledChanged = onEnabledChanged;
    this.#onOpenSettings = onOpenSettings;
    this.#onOpenTestWindow = onOpenTestWindow;
    this.#onPresentationChanged = onPresentationChanged;
    this.#resolveExecutablePath = resolveExecutablePath;
    this.#spawnHost = spawnHost;
  }

  attachWindow(attachment: SideChatWindowAttachment) {
    const windowGeneration = ++this.#windowGeneration;
    this.#stopBackdropHealthMonitor();
    this.#attachment?.backdrop.detach();
    this.#attachment = attachment;
    this.#attachmentWindowGeneration = windowGeneration;
    this.#backdropAttachAttempted = false;
    this.#backdropAttached = false;
    this.#backdropCanRebuild = false;
    this.#backdropUnavailable = false;
    this.#geometryKey = "";
    this.#lastBoundsKey = "";
    this.#windowReady = false;

    attachment.browserWindow.on("ready-to-show", () => {
      if (
        this.#attachment !== attachment ||
        this.#attachmentWindowGeneration !== windowGeneration
      ) {
        return;
      }
      this.#windowReady = true;
      this.#attachBackdropIfNeeded();
      this.#applyPresentation(undefined, this.#presentation);
    });
    attachment.browserWindow.on("closed", () => {
      if (
        this.#attachment !== attachment ||
        this.#attachmentWindowGeneration !== windowGeneration
      ) {
        return;
      }
      this.#stopBackdropHealthMonitor();
      attachment.backdrop.detach();
      this.#attachment = undefined;
      this.#attachmentWindowGeneration = 0;
      this.#backdropAttachAttempted = false;
      this.#backdropAttached = false;
      this.#backdropCanRebuild = false;
      this.#backdropUnavailable = false;
      this.#windowReady = false;
    });

    this.#attachBackdropIfNeeded();
    this.#applyPresentation(undefined, this.#presentation);
  }

  handleWindowFailure(browserWindow: SideChatBrowserWindowLike, reason: string) {
    const attachment = this.#attachment;
    if (!attachment || attachment.browserWindow !== browserWindow) return;

    this.#failClosedBackdrop(`renderer surface failed: ${reason}`);
    this.#stopBackdropHealthMonitor();
    attachment.backdrop.detach();
    this.#attachment = undefined;
    this.#attachmentWindowGeneration = 0;
    this.#backdropAttachAttempted = false;
    this.#backdropAttached = false;
    this.#backdropCanRebuild = false;
    this.#backdropUnavailable = true;
    this.#windowReady = false;
  }

  start(shortcut: SideChatShortcutBinding = this.#shortcut) {
    if (this.#started) return;
    this.#shortcut = structuredClone(shortcut);
    this.#started = true;
    this.#disposed = false;

    try {
      this.#ensureHost();
    } catch (error) {
      log.warn(`native side-chat gesture helper unavailable: ${errorMessage(error)}`);
    }
  }

  presentation(_input?: void) {
    return this.#presentation;
  }

  debugSettings(_input?: void) {
    return { ...this.#debugSettings };
  }

  updateDebugSettings(input: SideChatDebugSettingsPatch) {
    const patch = sideChatDebugSettingsPatchSchema.parse(input);
    const candidate = sideChatDebugSettingsSchema.parse({
      ...this.#debugSettings,
      ...patch,
      revision: this.#debugSettings.revision + 1,
    });

    if (sameDebugSettingsValues(candidate, this.#debugSettings)) {
      return this.debugSettings();
    }

    this.#debugSettings = candidate;
    this.#applyDebugSettings();
    this.#onDebugSettingsChanged?.(this.debugSettings());
    return this.debugSettings();
  }

  updateShortcut(input: SideChatShortcutBinding): Promise<SideChatShortcutBinding> {
    const shortcut = sideChatShortcutBindingSchema.parse(input);
    let host = this.#host;
    if (!host || host.killed) host = this.#ensureHost();
    const hasPendingUserIntent =
      this.#activeShortcutRegistration?.type === "update" ||
      Boolean(this.#queuedShortcutUpdate);
    if (!hasPendingUserIntent && sameSideChatShortcut(shortcut, this.#shortcut)) {
      return Promise.resolve(structuredClone(this.#shortcut));
    }

    return new Promise((resolve, reject) => {
      const update: QueuedSideChatShortcutUpdate = {
        reject,
        resolve,
        shortcut,
      };
      if (
        this.#activeShortcutRegistration ||
        this.#confirmedShortcutGeneration !== this.#hostGeneration
      ) {
        this.#queueShortcutUpdate(update);
        return;
      }
      this.#startShortcutUpdate(host, update);
    });
  }

  resetDebugSettings(_input?: void) {
    this.#debugSettings = sideChatDebugSettingsSchema.parse({
      ...defaultSideChatDebugSettings,
      revision: this.#debugSettings.revision + 1,
    });
    this.#applyDebugSettings();
    this.#onDebugSettingsChanged?.(this.debugSettings());
    return this.debugSettings();
  }

  setContentSize(input: SideChatContentSizeInput): ChatCommandReceipt {
    this.#contentSize = {
      height: Math.ceil(input.height),
      visualHeight: Math.ceil(input.visualHeight ?? input.height),
      width: Math.ceil(input.width),
    };
    // Visible-only changes must reach the backdrop even when the helper keeps
    // the same reserved window frame. Reveal/lifecycle ownership is unchanged.
    this.#applyPresentation(undefined, this.#presentation);
    this.#sendLayoutIfRunning();
    return this.#receipt();
  }

  /**
   * The General setting. Off closes Side Chat, makes every open request a
   * no-op, and tells the helper to drop the edge gesture and the global
   * shortcut; the saved shortcut is kept for when it is turned on again.
   */
  setEnabled(enabled: boolean) {
    if (enabled === this.#enabled) return;
    this.#enabled = enabled;
    const host = this.#host;
    const hostRunning = Boolean(host && !host.killed);
    if (!enabled) {
      // Without a running helper nothing is shown. Closing would launch one
      // before start() supplies the saved binding, and on Windows and Linux
      // there is no helper to launch.
      if (hostRunning) this.close();
      else this.#desiredOpen = false;
    }
    if (host && hostRunning) this.#writeHostFrame(host, enabledFrame(enabled));
    this.#onEnabledChanged?.(enabled);
  }

  enabled() {
    return this.#enabled;
  }

  setInteractiveProgress({
    progress,
  }: SideChatInteractiveProgressInput): ChatCommandReceipt {
    if (!this.#enabled) return this.#receipt();
    if (this.#failCloseRecovery.barrier) {
      if (progress > 0.002) {
        this.#transitionFailCloseRecovery({ type: "queue-reopen" });
        this.#desiredOpen = true;
      }
      return this.#receipt();
    }
    if (progress > 0.002 && !this.#prepareBackdropForOpen()) return this.#receipt();
    if (!this.#sendHostFrame(surfaceInteractiveProgress(progress))) {
      this.#applyFallbackInteractiveProgress(progress);
    }
    return this.#receipt();
  }

  finishInteractiveProgress(
    input: SideChatInteractiveCompletionInput
  ): ChatCommandReceipt {
    const shouldOpen = this.#enabled && input.shouldOpen;
    if (!shouldOpen) {
      this.#transitionFailCloseRecovery({ type: "cancel-reopen" });
      this.#desiredOpen = false;
      if (this.#failCloseRecovery.barrier) return this.#receipt();
    }
    if (shouldOpen && !this.#prepareBackdropForOpen()) return this.#receipt();
    this.#desiredOpen = shouldOpen;
    if (!this.#sendHostFrame(surfaceInteractiveCompletion(shouldOpen))) {
      this.#applyFallbackVisibility(shouldOpen);
    }
    return this.#receipt();
  }

  open() {
    if (!this.#enabled || !this.#prepareBackdropForOpen()) return this.#receipt();
    this.#desiredOpen = true;
    if (!this.#sendControl("side-chat.open")) this.#applyFallbackVisibility(true);
    return this.#receipt();
  }

  close(_input?: void) {
    this.#transitionFailCloseRecovery({ type: "cancel-reopen" });
    this.#desiredOpen = false;
    if (this.#failCloseRecovery.barrier) return this.#receipt();
    if (!this.#sendControl("side-chat.close")) this.#applyFallbackVisibility(false);
    return this.#receipt();
  }

  toggle() {
    if (!this.#enabled) return this.close();
    const shouldOpen = !this.#desiredOpen;
    if (!shouldOpen) this.#transitionFailCloseRecovery({ type: "cancel-reopen" });
    if (shouldOpen && !this.#prepareBackdropForOpen()) return this.#receipt();
    if (!shouldOpen && this.#failCloseRecovery.barrier) {
      this.#desiredOpen = false;
      return this.#receipt();
    }
    this.#desiredOpen = shouldOpen;
    if (!this.#sendControl("side-chat.toggle")) {
      this.#applyFallbackVisibility(this.#desiredOpen);
    }
    return this.#receipt();
  }

  async openSettings(_input?: void) {
    await this.#onOpenSettings?.();
    return this.#receipt();
  }

  async openTestWindow(input: SideChatOpenTestWindowInput) {
    await this.#onOpenTestWindow?.(input);
    return this.#receipt();
  }

  closeTestWindow(_input?: void) {
    void this.#onCloseTestWindow?.();
    return this.#receipt();
  }

  rebuildBackdrop() {
    const attachment = this.#attachment;
    if (
      !attachment ||
      attachment.browserWindow.isDestroyed() ||
      !this.#backdropCanRebuild ||
      Boolean(this.#failCloseRecovery.barrier)
    ) {
      return false;
    }
    const available =
      attachment.backdrop.rebuild() && attachment.backdrop.isAvailable();
    if (!available) {
      this.#failClosedBackdrop("explicit rebuild failed");
      return false;
    }
    this.#backdropAttached = true;
    this.#backdropCanRebuild = true;
    this.#backdropUnavailable = false;
    this.#refreshBackdropHealthMonitor();
    return true;
  }

  /** Whether this Mac has the helper, which also draws the menu-bar item. */
  hostAvailable() {
    return existsSync(this.#resolveExecutablePath());
  }

  /**
   * Shows the macOS menu-bar item through the helper, so hovering its menu
   * never waits on Main's thread. Main keeps the latest menu and sends it to
   * every helper it starts; `onSelect` receives the id of the chosen row. When
   * the running helper is lost, the menu is dropped and `onLost` runs, so Main
   * can draw the menu itself instead of waiting on a helper that keeps failing.
   */
  showStatusMenu(menu: StatusMenu, onSelect: (id: string) => void, onLost: () => void) {
    this.#statusMenu = { menu: structuredClone(menu), onLost, onSelect };
    const host = this.#host;
    // A helper that is not running yet receives the menu when it starts.
    if (host && !host.killed) this.#writeHostFrame(host, statusMenuShowFrame(menu));
  }

  hideStatusMenu() {
    if (!this.#statusMenu) return;
    this.#statusMenu = undefined;
    const host = this.#host;
    if (host && !host.killed) {
      this.#writeHostFrame(host, {
        kind: "status-menu.hide",
        protocolVersion: chatProtocolVersion,
        requestId: randomUUID(),
      });
    }
  }

  dispose() {
    this.#disposed = true;
    this.#started = false;
    this.#desiredOpen = false;
    if (this.#restartTimer) clearTimeout(this.#restartTimer);
    this.#restartTimer = undefined;
    this.#clearActiveShortcutRegistration(
      new Error("The Side Chat service was disposed.")
    );
    this.#rejectQueuedShortcutUpdate(new Error("The Side Chat service was disposed."));
    this.#confirmedShortcutGeneration = undefined;
    this.#stopHost();
    this.#stopBackdropHealthMonitor();
    this.#attachment?.backdrop.detach();
    this.#attachment = undefined;
    this.#attachmentWindowGeneration = 0;
    this.#backdropAttachAttempted = false;
    this.#backdropAttached = false;
    this.#backdropCanRebuild = false;
    this.#backdropUnavailable = false;
    this.#transitionFailCloseRecovery({ type: "reset" });
  }

  #receipt(): ChatCommandReceipt {
    return { revision: this.#presentation.revision };
  }

  #sendControl(
    kind: "side-chat.open" | "side-chat.close" | "side-chat.toggle"
  ): SideChatSentControl | undefined {
    const requestId = randomUUID();
    const helperGeneration = this.#sendHostFrame(surfaceControl(kind, requestId));
    return helperGeneration ? { helperGeneration, requestId } : undefined;
  }

  #sendHostFrame(frame: SideChatHostFrame) {
    let host = this.#host;
    if (!host || host.killed) {
      try {
        host = this.#ensureHost();
      } catch (error) {
        log.warn(`native side-chat gesture helper unavailable: ${errorMessage(error)}`);
        return false;
      }
    }

    const helperGeneration = this.#hostGeneration;
    this.#writeHostFrame(host, frame);
    return this.#isCurrentHost(host, helperGeneration) && !host.killed
      ? helperGeneration
      : undefined;
  }

  #ensureHost() {
    if (this.#host && !this.#host.killed) return this.#host;
    if (this.#host?.killed) {
      const lostGeneration = this.#hostGeneration;
      this.#host = undefined;
      this.#confirmedShortcutGeneration = undefined;
      const registrationError = new Error(
        "The Side Chat helper was lost before registering the shortcut."
      );
      this.#clearActiveShortcutRegistration(registrationError, lostGeneration);
      this.#rejectQueuedShortcutUpdate(registrationError);
      this.#releaseFailCloseBarrierAfterHostLoss(lostGeneration);
      this.#loseStatusMenu();
    }
    if (this.#restartTimer) {
      clearTimeout(this.#restartTimer);
      this.#restartTimer = undefined;
    }

    const executablePath = this.#resolveExecutablePath();
    if (!existsSync(executablePath)) {
      throw new Error(
        `CommaSideChatHost was not found at ${executablePath}. Run pnpm --filter @comma/electron build:native.`
      );
    }

    const host = this.#spawnHost(executablePath, sideChatHostEnvironment());
    const generation = ++this.#hostGeneration;
    this.#confirmedShortcutGeneration = undefined;
    this.#lastHostPresentationRevision = -1;
    let stdoutBuffer = "";
    this.#host = host;

    host.stdout.on("data", (chunk) => {
      stdoutBuffer = this.#handleStdout(
        host,
        generation,
        stdoutBuffer,
        chunk.toString()
      );
    });
    host.stdin.on("error", (error) => this.#handleHostStreamError(host, error));
    host.stderr.on("data", (chunk) => {
      const message = chunk.toString().trim();
      if (message) log.warn(`[side-chat-helper] ${message}`);
    });
    host.on("error", (error) => this.#handleHostStreamError(host, error));
    host.on("exit", (code) => {
      if (!this.#isCurrentHost(host, generation)) return;
      this.#host = undefined;
      this.#confirmedShortcutGeneration = undefined;
      const registrationError = new Error(
        "The Side Chat helper exited before registering the shortcut."
      );
      this.#clearActiveShortcutRegistration(registrationError, generation);
      this.#rejectQueuedShortcutUpdate(registrationError);
      if (code) log.warn(`CommaSideChatHost exited with code ${code}.`);
      this.#releaseFailCloseBarrierAfterHostLoss(generation);
      this.#loseStatusMenu();
      if (this.#presentation.progress > 0.002) {
        const desiredOpen = this.#desiredOpen;
        this.#applyFallbackVisibility(false);
        this.#desiredOpen = desiredOpen;
      }
      this.#scheduleHostRestart();
    });

    this.#sendLayout(host);
    // Before the shortcut, so a helper started while Side Chat is off never
    // registers the chord.
    if (!this.#enabled) this.#writeHostFrame(host, enabledFrame(false));
    this.#replayShortcut(host);
    if (this.#statusMenu) {
      this.#writeHostFrame(host, statusMenuShowFrame(this.#statusMenu.menu));
    }
    if (this.#desiredOpen) this.#writeHostFrame(host, surfaceControl("side-chat.open"));
    return host;
  }

  #sendLayoutIfRunning() {
    const host = this.#host;
    if (host && !host.killed) this.#sendLayout(host);
  }

  #sendLayout(host: ChildProcessWithoutNullStreams) {
    this.#writeHostFrame(host, {
      debugSettings: sideChatGeometrySettingsSchema.parse(this.#debugSettings),
      height: this.#contentSize.height,
      width: this.#contentSize.width,
      kind: "side-chat.layout",
      protocolVersion: chatProtocolVersion,
      requestId: randomUUID(),
    });
  }

  #replayShortcut(host: ChildProcessWithoutNullStreams) {
    this.#registerShortcut(host, this.#shortcut, { type: "replay" });
  }

  #queueShortcutUpdate(update: QueuedSideChatShortcutUpdate) {
    this.#queuedShortcutUpdate?.reject(
      new Error("The Side Chat shortcut update was superseded.")
    );
    this.#queuedShortcutUpdate = update;
  }

  #startShortcutUpdate(
    host: ChildProcessWithoutNullStreams,
    update: QueuedSideChatShortcutUpdate
  ) {
    this.#registerShortcut(host, update.shortcut, {
      reject: update.reject,
      resolve: update.resolve,
      type: "update",
    });
  }

  #drainQueuedShortcutUpdate(
    host: ChildProcessWithoutNullStreams,
    helperGeneration: number
  ) {
    if (
      this.#activeShortcutRegistration ||
      !this.#isCurrentHost(host, helperGeneration) ||
      host.killed
    ) {
      return;
    }
    const queued = this.#queuedShortcutUpdate;
    if (!queued) return;
    this.#queuedShortcutUpdate = undefined;
    this.#startShortcutUpdate(host, queued);
  }

  #registerShortcut(
    host: ChildProcessWithoutNullStreams,
    shortcut: SideChatShortcutBinding,
    settlement:
      | { readonly type: "replay" }
      | {
          readonly reject: (error: Error) => void;
          readonly resolve: (shortcut: SideChatShortcutBinding) => void;
          readonly type: "update";
        }
  ) {
    if (this.#activeShortcutRegistration) {
      throw new Error("Side Chat shortcut registration must be serialized.");
    }
    const helperGeneration = this.#hostGeneration;
    const requestId = randomUUID();
    const timeout = setTimeout(() => {
      const pending = this.#activeShortcutRegistration;
      if (
        !pending ||
        pending.requestId !== requestId ||
        pending.helperGeneration !== helperGeneration
      ) {
        return;
      }
      this.#activeShortcutRegistration = undefined;
      const registrationError = new Error(
        pending.type === "replay"
          ? "Timed out while replaying the Side Chat shortcut."
          : "Timed out while registering the Side Chat shortcut."
      );
      if (pending.type === "update") {
        pending.reject(registrationError);
      }
      this.#confirmedShortcutGeneration = undefined;
      this.#rejectQueuedShortcutUpdate(registrationError);
      if (this.#isCurrentHost(host, helperGeneration)) {
        this.#handleHostStreamError(
          host,
          new Error(
            pending.type === "replay"
              ? "Side Chat shortcut replay timed out."
              : "Side Chat shortcut registration timed out."
          )
        );
      }
    }, SHORTCUT_REGISTRATION_TIMEOUT_MS);
    timeout.unref?.();
    this.#activeShortcutRegistration = {
      helperGeneration,
      requestId,
      shortcut,
      timeout,
      ...settlement,
    };
    this.#writeHostFrame(host, {
      ...shortcutRegistration(shortcut),
      kind: "side-chat.shortcut",
      protocolVersion: chatProtocolVersion,
      requestId,
    });
  }

  #handleStdout(
    host: ChildProcessWithoutNullStreams,
    generation: number,
    buffered: string,
    chunk: string
  ) {
    if (!this.#isCurrentHost(host, generation)) return "";
    let stdoutBuffer = buffered + chunk;
    let boundary = stdoutBuffer.indexOf("\n");

    while (boundary !== -1) {
      if (!this.#isCurrentHost(host, generation)) return "";
      const line = stdoutBuffer.slice(0, boundary).trim();
      stdoutBuffer = stdoutBuffer.slice(boundary + 1);
      boundary = stdoutBuffer.indexOf("\n");
      if (!line.startsWith("{")) continue;

      try {
        const json = JSON.parse(line) as unknown;
        const parsed = sideChatClientFrameSchema.safeParse(json);
        if (!parsed.success) {
          log.warn(
            `CommaSideChatHost emitted a non-canonical frame: ${parsed.error.message}`
          );
          continue;
        }
        this.#handleClientFrame(host, generation, parsed.data);
      } catch (error) {
        log.warn(`CommaSideChatHost emitted invalid JSON: ${errorMessage(error)}`);
      }
    }

    return stdoutBuffer;
  }

  #handleClientFrame(
    host: ChildProcessWithoutNullStreams,
    helperGeneration: number,
    frame: SideChatClientFrame
  ) {
    if (frame.kind === "side-chat.presentation") {
      if (frame.revision <= this.#lastHostPresentationRevision) {
        log.warn(
          `CommaSideChatHost emitted stale presentation revision ${frame.revision}.`
        );
        return;
      }
      this.#lastHostPresentationRevision = frame.revision;
      let shouldReopenAfterClose = false;
      const barrier = this.#failCloseRecovery.barrier;
      if (barrier) {
        if (helperGeneration !== barrier.helperGeneration || frame.phase !== "closed") {
          return;
        }
        const transition = this.#transitionFailCloseRecovery({
          helperGeneration,
          type: "helper-closed",
        });
        if (!transition.released) return;
        shouldReopenAfterClose = transition.shouldReopen;
      }
      const previous = this.#presentation;
      this.#presentation = sideChatPresentationSchema.parse({
        ...frame,
        revision: ++this.#presentationRevision,
      });
      if (frame.phase === "open") this.#desiredOpen = true;
      if (frame.phase === "closed") this.#desiredOpen = false;
      this.#applyPresentation(previous, this.#presentation);
      this.#onPresentationChanged?.(this.#presentation);
      if (shouldReopenAfterClose) this.open();
      return;
    }

    if (frame.kind === "side-chat.protocol-error") {
      log.warn(`CommaSideChatHost protocol error: ${frame.error}`);
      return;
    }

    if (frame.kind === "status-menu.select") {
      this.#statusMenu?.onSelect(frame.id);
      return;
    }

    if (frame.kind === "command.result") {
      const pendingShortcut = this.#activeShortcutRegistration;
      if (
        pendingShortcut?.requestId === frame.requestId &&
        pendingShortcut.helperGeneration === helperGeneration
      ) {
        this.#activeShortcutRegistration = undefined;
        clearTimeout(pendingShortcut.timeout);
        if (frame.ok) {
          this.#confirmedShortcutGeneration = helperGeneration;
          if (pendingShortcut.type === "update") {
            this.#shortcut = pendingShortcut.shortcut;
            pendingShortcut.resolve(structuredClone(this.#shortcut));
          }
          this.#drainQueuedShortcutUpdate(host, helperGeneration);
        } else {
          const error = new Error(
            `CommaSideChatHost rejected the shortcut: ${frame.error ?? "unknown"}`
          );
          if (pendingShortcut.type === "update") {
            pendingShortcut.reject(error);
            if (this.#confirmedShortcutGeneration === helperGeneration) {
              this.#drainQueuedShortcutUpdate(host, helperGeneration);
            } else {
              this.#rejectQueuedShortcutUpdate(error);
              this.#handleHostStreamError(host, error);
              return;
            }
          } else if (this.#queuedShortcutUpdate) {
            // The helper has conclusively rejected committed replay. A queued
            // user choice may still recover this generation, but it must run
            // only after replay settles and the helper must die if it fails.
            this.#drainQueuedShortcutUpdate(host, helperGeneration);
          } else {
            this.#handleHostStreamError(host, error);
            return;
          }
        }
      }
      const barrier = this.#failCloseRecovery.barrier;
      const rejectedActiveClose =
        !frame.ok &&
        barrier?.helperGeneration === helperGeneration &&
        barrier.closeRequestId === frame.requestId;
      this.#transitionFailCloseRecovery({
        helperGeneration,
        ok: frame.ok,
        requestId: frame.requestId,
        type: "helper-command-result",
      });
      if (!frame.ok) {
        log.warn(`CommaSideChatHost command failed: ${frame.error ?? "unknown"}`);
      }
      if (rejectedActiveClose) {
        this.#handleHostStreamError(
          host,
          new Error(
            `fail-close command ${frame.requestId} was rejected: ${frame.error ?? "unknown"}`
          )
        );
      }
      return;
    }

    if (frame.kind === "side-chat.ready") {
      this.#writeHostFrame(host, {
        kind: "command.result",
        ok: true,
        protocolVersion: chatProtocolVersion,
        requestId: frame.requestId,
      });
      return;
    }

    // Old helpers can still announce legacy chat commands during a rolling
    // development rebuild. Refuse them explicitly: renderer chat is now the
    // only data path and the gesture helper never receives credentials/data.
    this.#writeHostFrame(host, {
      error: `Unsupported gesture-helper frame: ${frame.kind}`,
      kind: "command.result",
      ok: false,
      protocolVersion: chatProtocolVersion,
      requestId: frame.requestId,
    });
  }

  #applyPresentation(
    previous: SideChatPresentation | undefined,
    presentation: SideChatPresentation
  ) {
    const attachment = this.#attachment;
    if (!attachment || attachment.browserWindow.isDestroyed()) return;
    if (this.#failCloseRecovery.barrier) {
      attachment.browserWindow.hide();
      return;
    }

    const bounds = attachment.toElectronBounds(presentation);
    if (bounds && bounds.width > 0 && bounds.height > 0) {
      const boundsKey = `${bounds.x}:${bounds.y}:${bounds.width}:${bounds.height}`;
      if (boundsKey !== this.#lastBoundsKey) {
        this.#lastBoundsKey = boundsKey;
        attachment.browserWindow.setBounds(bounds, false);
      }
    }

    this.#attachBackdropIfNeeded();
    if (
      this.#backdropUnavailable &&
      presentation.progress > 0.002 &&
      (!this.#backdropCanRebuild || !this.rebuildBackdrop())
    ) {
      attachment.browserWindow.hide();
      this.#requestBackdropCloseIfNeeded();
      return;
    }
    if (this.#backdropUnavailable) {
      attachment.browserWindow.hide();
      this.#requestBackdropCloseIfNeeded();
      return;
    }
    if (this.#backdropAttached) {
      const geometry = geometryFromPresentation(
        presentation,
        this.#contentSize.visualHeight
      );
      const geometryKey = JSON.stringify(geometry);
      if (validBackdropGeometry(geometry) && geometryKey !== this.#geometryKey) {
        this.#geometryKey = geometryKey;
        if (!attachment.backdrop.updateGeometry(geometry)) {
          this.#failClosedBackdrop("geometry update failed");
          return;
        }
      }
      if (!attachment.backdrop.setRevealOffset(presentation.offsetX)) {
        this.#failClosedBackdrop("reveal update failed");
        return;
      }
      if (!attachment.backdrop.isAvailable()) {
        this.#failClosedBackdrop("native health query failed");
        return;
      }
    }

    this.#refreshBackdropHealthMonitor();

    if (!this.#windowReady) return;
    if (presentation.phase === "closed" || presentation.progress <= 0.002) {
      attachment.browserWindow.hide();
      return;
    }

    if (!previous || previous.phase === "closed" || previous.progress <= 0.002) {
      attachment.browserWindow.showInactive();
    }
    if (presentation.phase === "open" && previous?.phase !== "open") {
      if (this.#activateOpenWindow) {
        attachment.browserWindow.show();
        attachment.browserWindow.focus();
      } else {
        attachment.browserWindow.showInactive();
      }
    }
  }

  #attachBackdropIfNeeded() {
    if (
      this.#failCloseRecovery.barrier ||
      !this.#windowReady ||
      this.#backdropAttached ||
      this.#backdropAttachAttempted
    ) {
      return;
    }
    const attachment = this.#attachment;
    if (!attachment || attachment.browserWindow.isDestroyed()) return;
    this.#backdropAttachAttempted = true;
    try {
      const settingsAccepted = attachment.backdrop.updateSettings(
        backdropSettings(this.#debugSettings)
      );
      const attached =
        settingsAccepted &&
        attachment.backdrop.attach(attachment.browserWindow.getNativeWindowHandle()) &&
        attachment.backdrop.isAvailable();
      this.#backdropAttached = attached;
      if (!attached) {
        this.#failClosedBackdrop("attach returned unavailable");
      } else {
        this.#backdropCanRebuild = true;
        this.#backdropUnavailable = false;
      }
    } catch (error) {
      this.#failClosedBackdrop(`attach threw: ${errorMessage(error)}`);
    }
  }

  #applyDebugSettings() {
    const attachment = this.#attachment;
    if (attachment) {
      const available = attachment.backdrop.updateSettings(
        backdropSettings(this.#debugSettings)
      );
      if (this.#backdropAttachAttempted) {
        if (!available) {
          this.#failClosedBackdrop("settings update failed");
        }
      }
    }
    this.#sendLayoutIfRunning();
  }

  #failClosedBackdrop(reason: string) {
    const wasUnavailable = this.#backdropUnavailable;
    this.#backdropAttached = false;
    this.#backdropUnavailable = true;
    this.#stopBackdropHealthMonitor();
    this.#attachment?.browserWindow.hide();
    if (!wasUnavailable) {
      log.warn(
        `side-chat backdrop unavailable (${reason}); hiding Side Chat because the native-quality blur floor is unavailable`
      );
    }
    this.#requestBackdropCloseIfNeeded(reason);
  }

  #prepareBackdropForOpen() {
    if (this.#failCloseRecovery.barrier) {
      this.#transitionFailCloseRecovery({ type: "queue-reopen" });
      this.#desiredOpen = true;
      return false;
    }
    if (!this.#backdropUnavailable) return true;
    if (!this.#backdropCanRebuild) return false;
    return this.rebuildBackdrop();
  }

  #refreshBackdropHealthMonitor() {
    const attachment = this.#attachment;
    const shouldMonitor =
      Boolean(attachment) &&
      this.#windowReady &&
      this.#backdropAttached &&
      !this.#backdropUnavailable &&
      this.#presentation.progress > 0.002;
    if (!shouldMonitor) {
      this.#stopBackdropHealthMonitor();
      return;
    }
    if (this.#backdropHealthTimer) return;

    this.#backdropHealthTimer = setInterval(() => {
      const current = this.#attachment;
      if (
        !current ||
        current !== attachment ||
        current.browserWindow.isDestroyed() ||
        !this.#windowReady ||
        !this.#backdropAttached ||
        this.#backdropUnavailable ||
        this.#presentation.progress <= 0.002
      ) {
        this.#stopBackdropHealthMonitor();
        return;
      }
      if (!current.backdrop.isAvailable()) {
        this.#failClosedBackdrop("asynchronous native health check failed");
      }
    }, BACKDROP_HEALTH_POLL_MS);
    this.#backdropHealthTimer.unref?.();
  }

  #stopBackdropHealthMonitor() {
    if (!this.#backdropHealthTimer) return;
    clearInterval(this.#backdropHealthTimer);
    this.#backdropHealthTimer = undefined;
  }

  #requestBackdropCloseIfNeeded(reason = "native backdrop became unavailable") {
    const helperMayBeRevealing =
      this.#desiredOpen ||
      this.#presentation.phase !== "closed" ||
      this.#presentation.progress > 0.002;
    if (!helperMayBeRevealing) {
      return;
    }
    if (this.#failCloseRecovery.barrier) return;
    this.#desiredOpen = false;
    const closeCommand = this.#sendControl("side-chat.close");
    if (closeCommand) {
      this.#transitionFailCloseRecovery({
        closeRequestId: closeCommand.requestId,
        helperGeneration: closeCommand.helperGeneration,
        reason,
        type: "begin",
        windowGeneration: this.#attachmentWindowGeneration,
      });
    }
    // Main owns the visible window, so fail closed synchronously instead of
    // waiting for the helper's asynchronous acknowledgement/presentation.
    this.#applyFallbackVisibility(false);
  }

  #releaseFailCloseBarrierAfterHostLoss(helperGeneration: number) {
    const transition = this.#transitionFailCloseRecovery({
      helperGeneration,
      type: "helper-lost",
    });
    if (!transition.released) return;
    if (transition.shouldReopen) this.#desiredOpen = true;
    this.#applyPresentation(undefined, this.#presentation);
  }

  #transitionFailCloseRecovery(event: SideChatFailCloseRecoveryEvent) {
    const transition = reduceSideChatFailCloseRecovery(this.#failCloseRecovery, event);
    this.#failCloseRecovery = transition.state;
    return transition;
  }

  #applyFallbackVisibility(open: boolean) {
    const previous = this.#presentation;
    const progress = open ? 1 : 0;
    this.#presentation = {
      ...previous,
      offsetX: open
        ? 0
        : -(
            Math.max(
              previous.windowFrame.width,
              fallbackWindowWidth(this.#debugSettings)
            ) + this.#debugSettings.closedExtraOffset
          ),
      phase: open ? "open" : "closed",
      progress,
      revision: ++this.#presentationRevision,
    };
    this.#applyPresentation(previous, this.#presentation);
    this.#onPresentationChanged?.(this.#presentation);
  }

  #applyFallbackInteractiveProgress(progress: number) {
    const previous = this.#presentation;
    const clampedProgress = Math.min(1, Math.max(0, progress));
    const hiddenDistance =
      Math.max(previous.windowFrame.width, fallbackWindowWidth(this.#debugSettings)) +
      this.#debugSettings.closedExtraOffset;
    this.#presentation = {
      ...previous,
      offsetX: -(1 - clampedProgress) * hiddenDistance,
      phase: "interactive",
      progress: clampedProgress,
      revision: ++this.#presentationRevision,
    };
    this.#applyPresentation(previous, this.#presentation);
    this.#onPresentationChanged?.(this.#presentation);
  }

  #writeHostFrame(host: ChildProcessWithoutNullStreams, frame: SideChatHostFrame) {
    try {
      const parsed = sideChatHostFrameSchema.parse(frame);
      host.stdin.write(`${JSON.stringify(parsed)}\n`);
    } catch (error) {
      this.#handleHostStreamError(host, error);
    }
  }

  #handleHostStreamError(host: ChildProcessWithoutNullStreams, error: unknown) {
    if (this.#host !== host) return;
    const helperGeneration = this.#hostGeneration;
    this.#host = undefined;
    this.#confirmedShortcutGeneration = undefined;
    const registrationError = new Error(
      `The Side Chat helper failed before registering the shortcut: ${errorMessage(
        error
      )}`
    );
    this.#clearActiveShortcutRegistration(registrationError, helperGeneration);
    this.#rejectQueuedShortcutUpdate(registrationError);
    log.warn(`CommaSideChatHost stream failed: ${errorMessage(error)}`);
    this.#releaseFailCloseBarrierAfterHostLoss(helperGeneration);
    this.#loseStatusMenu();
    if (this.#presentation.progress > 0.002) {
      const desiredOpen = this.#desiredOpen;
      this.#applyFallbackVisibility(false);
      this.#desiredOpen = desiredOpen;
    }
    if (!host.killed) host.kill();
    this.#scheduleHostRestart();
  }

  #loseStatusMenu() {
    const statusMenu = this.#statusMenu;
    this.#statusMenu = undefined;
    statusMenu?.onLost();
  }

  #scheduleHostRestart() {
    if (!this.#started || this.#disposed || this.#restartTimer) return;
    this.#restartTimer = setTimeout(() => {
      this.#restartTimer = undefined;
      try {
        this.#ensureHost();
      } catch (error) {
        log.warn(`native side-chat restart deferred: ${errorMessage(error)}`);
        this.#scheduleHostRestart();
      }
    }, RESTART_DELAY_MS);
    this.#restartTimer.unref?.();
  }

  #stopHost() {
    const host = this.#host;
    this.#host = undefined;
    if (!host || host.killed) return;
    this.#writeHostFrame(host, surfaceControl("side-chat.stop"));
    const timer = setTimeout(() => {
      if (!host.killed) host.kill();
    }, 1_000);
    timer.unref();
  }

  #isCurrentHost(host: ChildProcessWithoutNullStreams, generation: number) {
    return this.#host === host && this.#hostGeneration === generation;
  }

  #clearActiveShortcutRegistration(error: Error, helperGeneration?: number) {
    const pending = this.#activeShortcutRegistration;
    if (
      !pending ||
      (helperGeneration !== undefined && pending.helperGeneration !== helperGeneration)
    ) {
      return;
    }
    this.#activeShortcutRegistration = undefined;
    clearTimeout(pending.timeout);
    if (pending.type === "update") pending.reject(error);
  }

  #rejectQueuedShortcutUpdate(error: Error) {
    const queued = this.#queuedShortcutUpdate;
    if (!queued) return;
    this.#queuedShortcutUpdate = undefined;
    queued.reject(error);
  }
}

function reduceSideChatFailCloseRecovery(
  state: SideChatFailCloseRecoveryState,
  event: SideChatFailCloseRecoveryEvent
): SideChatFailCloseRecoveryTransition {
  if (event.type === "reset") {
    return {
      released: Boolean(state.barrier),
      shouldReopen: false,
      state: {
        barrier: undefined,
        epoch: state.epoch,
        queuedReopenEpoch: undefined,
      },
    };
  }

  if (event.type === "begin") {
    if (state.barrier) {
      return { released: false, shouldReopen: false, state };
    }
    const epoch = state.epoch + 1;
    return {
      released: false,
      shouldReopen: false,
      state: {
        barrier: {
          closeAcknowledged: false,
          closeRequestId: event.closeRequestId,
          epoch,
          helperGeneration: event.helperGeneration,
          reason: event.reason,
          windowGeneration: event.windowGeneration,
        },
        epoch,
        queuedReopenEpoch: undefined,
      },
    };
  }

  if (event.type === "queue-reopen") {
    const barrier = state.barrier;
    if (!barrier || state.queuedReopenEpoch === barrier.epoch) {
      return { released: false, shouldReopen: false, state };
    }
    return {
      released: false,
      shouldReopen: false,
      state: { ...state, queuedReopenEpoch: barrier.epoch },
    };
  }

  if (event.type === "helper-command-result") {
    const barrier = state.barrier;
    if (
      !barrier ||
      barrier.closeAcknowledged ||
      barrier.helperGeneration !== event.helperGeneration ||
      barrier.closeRequestId !== event.requestId ||
      !event.ok
    ) {
      return { released: false, shouldReopen: false, state };
    }
    return {
      released: false,
      shouldReopen: false,
      state: {
        ...state,
        barrier: { ...barrier, closeAcknowledged: true },
      },
    };
  }

  if (event.type === "cancel-reopen") {
    if (state.queuedReopenEpoch === undefined) {
      return { released: false, shouldReopen: false, state };
    }
    return {
      released: false,
      shouldReopen: false,
      state: { ...state, queuedReopenEpoch: undefined },
    };
  }

  const barrier = state.barrier;
  if (
    !barrier ||
    barrier.helperGeneration !== event.helperGeneration ||
    (event.type === "helper-closed" && !barrier.closeAcknowledged)
  ) {
    return { released: false, shouldReopen: false, state };
  }
  return {
    released: true,
    shouldReopen: state.queuedReopenEpoch === barrier.epoch,
    state: {
      barrier: undefined,
      epoch: state.epoch,
      queuedReopenEpoch: undefined,
    },
  };
}

// Model: tla/side_chat_geometry/SideChatGeometry.tla (Resize, Deliver, Paint).
function geometryFromPresentation(
  presentation: SideChatPresentation,
  visualHeight?: number
): SideChatBackdropGeometry {
  const { contentFrame, windowFrame } = presentation;
  return {
    contentHeight: contentFrame.height,
    contentWidth: contentFrame.width,
    contentX: contentFrame.x - windowFrame.x,
    contentY: contentFrame.y - windowFrame.y,
    visualHeight: Math.min(visualHeight ?? contentFrame.height, contentFrame.height),
    visualWidth: contentFrame.width,
    windowHeight: windowFrame.height,
    windowWidth: windowFrame.width,
  };
}

function validBackdropGeometry(geometry: SideChatBackdropGeometry) {
  return (
    geometry.windowWidth > 0 &&
    geometry.windowHeight > 0 &&
    geometry.contentWidth > 0 &&
    geometry.contentHeight > 0 &&
    geometry.visualWidth > 0 &&
    geometry.visualHeight > 0
  );
}

/** The menu-bar menu the helper draws: rows, icon, tooltip and width in points. */
export interface StatusMenu {
  iconPath: string;
  rows: StatusMenuRow[];
  toolTip: string;
  width: number;
}

function statusMenuShowFrame(menu: StatusMenu): SideChatHostFrame {
  return {
    ...menu,
    kind: "status-menu.show",
    protocolVersion: chatProtocolVersion,
    requestId: randomUUID(),
  };
}

function surfaceControl(
  kind: "side-chat.open" | "side-chat.close" | "side-chat.toggle" | "side-chat.stop",
  requestId = randomUUID()
): SideChatHostFrame {
  return {
    kind,
    protocolVersion: chatProtocolVersion,
    requestId,
  };
}

function enabledFrame(enabled: boolean): SideChatHostFrame {
  return {
    enabled,
    kind: "side-chat.enabled",
    protocolVersion: chatProtocolVersion,
    requestId: randomUUID(),
  };
}

function surfaceInteractiveProgress(progress: number): SideChatHostFrame {
  return {
    kind: "side-chat.interactive-progress",
    progress,
    protocolVersion: chatProtocolVersion,
    requestId: randomUUID(),
  };
}

function surfaceInteractiveCompletion(shouldOpen: boolean): SideChatHostFrame {
  return {
    kind: "side-chat.interactive-complete",
    protocolVersion: chatProtocolVersion,
    requestId: randomUUID(),
    shouldOpen,
  };
}

function shortcutRegistration(
  shortcut: SideChatShortcutBinding
): SideChatShortcutRegistrationInput {
  if (shortcut === null) return { modifiers: 0 };
  const { alt, control, meta, shift } = shortcut.modifiers;
  return {
    keyCode: MAC_KEY_CODES[shortcut.key],
    modifiers:
      (alt ? CARBON_OPTION_KEY : 0) |
      (control ? CARBON_CONTROL_KEY : 0) |
      (meta ? CARBON_COMMAND_KEY : 0) |
      (shift ? CARBON_SHIFT_KEY : 0),
  };
}

function sameSideChatShortcut(
  left: SideChatShortcutBinding,
  right: SideChatShortcutBinding
): boolean {
  if (left === null || right === null) return left === right;
  return (
    left.key === right.key &&
    left.modifiers.alt === right.modifiers.alt &&
    left.modifiers.control === right.modifiers.control &&
    left.modifiers.meta === right.modifiers.meta &&
    left.modifiers.shift === right.modifiers.shift
  );
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function sideChatHostEnvironment(source = process.env): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = {};
  for (const key of SIDE_CHAT_ENVIRONMENT_KEYS) {
    const value = source[key];
    if (value !== undefined) environment[key] = value;
  }
  return environment;
}

function backdropSettings(
  settings: SideChatDebugSettings
): SideChatDebugSettingsValues {
  const { revision: _revision, ...values } = settings;
  return values;
}

function sameDebugSettingsValues(
  left: SideChatDebugSettings,
  right: SideChatDebugSettings
) {
  return (
    JSON.stringify(backdropSettings(left)) === JSON.stringify(backdropSettings(right))
  );
}

function fallbackWindowWidth(settings: SideChatDebugSettings) {
  return (
    settings.contentWidth +
    deriveSideChatDebugGeometry(settings).horizontalBackdropPadding
  );
}

const SIDE_CHAT_HOST_RELATIVE_EXECUTABLE_PATH =
  "native/macos/CommaSideChatHost.app/Contents/MacOS/CommaSideChatHost";

export function nativeSideChatExecutableCandidatePaths({
  appPath = app.getAppPath(),
  cwd = process.cwd(),
  isPackaged = app.isPackaged,
  resourcesPath = process.resourcesPath,
}: {
  appPath?: string;
  cwd?: string;
  isPackaged?: boolean;
  resourcesPath?: string;
} = {}) {
  if (isPackaged) {
    return [join(resourcesPath, SIDE_CHAT_HOST_RELATIVE_EXECUTABLE_PATH)];
  }

  return [
    ...new Set([
      join(appPath, "dist", SIDE_CHAT_HOST_RELATIVE_EXECUTABLE_PATH),
      // Forge's unpackaged Main entry reports `.vite/build` as appPath.
      join(appPath, "../..", "dist", SIDE_CHAT_HOST_RELATIVE_EXECUTABLE_PATH),
      join(cwd, "dist", SIDE_CHAT_HOST_RELATIVE_EXECUTABLE_PATH),
      join(cwd, "apps/electron/dist", SIDE_CHAT_HOST_RELATIVE_EXECUTABLE_PATH),
      join(cwd, "clients/apps/electron/dist", SIDE_CHAT_HOST_RELATIVE_EXECUTABLE_PATH),
    ]),
  ];
}

export function resolveNativeSideChatExecutablePath() {
  const candidates = nativeSideChatExecutableCandidatePaths();
  return candidates.find((candidate) => existsSync(candidate)) ?? candidates[0]!;
}

function defaultSpawnHost(executablePath: string, environment: NodeJS.ProcessEnv) {
  return spawn(executablePath, [], {
    env: environment,
    stdio: ["pipe", "pipe", "pipe"],
  });
}
