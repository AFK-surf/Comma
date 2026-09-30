import {
  browserSitePermissionsInputSchema,
  type BrowserSitePermissionsInput,
} from "@comma/native-bridge";
import {
  browserSidebarCaptureInputSchema,
  browserSidebarCloseInputSchema,
  browserInspectionComposerConsolePrefix,
  browserSidebarInspectInputSchema,
  browserSidebarInspectResultSchema,
  browserSidebarNavigateInputSchema,
  browserSidebarOpenInputSchema,
  browserSidebarOpenTabRequestSchema,
  browserSidebarUpdateInputSchema,
  maxBrowserSidebarFaviconBytes,
  maxBrowserSidebarFaviconDataUrlLength,
  maxBrowserSidebarSessionsPerOwner,
  type BrowserSidebarCaptureInput,
  type BrowserSidebarCaptureResult,
  type BrowserSidebarCloseInput,
  type BrowserSidebarInspectInput,
  type BrowserSidebarInspectResult,
  type BrowserSidebarNavigateInput,
  type BrowserSidebarOpenInput,
  type BrowserSidebarOpenTabRequest,
  type BrowserSidebarState,
  type BrowserSidebarUpdateInput,
  type SurfaceBounds,
} from "@comma/native-bridge";
import type { Session } from "electron";
import type { BrowserSitePermissions } from "./site-permissions";
import { BrowserMeetingProbe } from "./meeting-presence";
import { randomUUID } from "node:crypto";
import { getCurrentNativeCallerContext } from "../ipc";
import type { NativeSurfaceService } from "../surfaces";
import { isAllowedUrl } from "../../security";
import {
  browserSidebarElementInspectorCancelSource,
  browserSidebarElementInspectorSource,
} from "./element-inspector";

export const BROWSER_SIDEBAR_PARTITION = "persist:comma-browser-sidebar";
const BROWSER_SIDEBAR_ROLE = "browser-sidebar";
const BROWSER_SIDEBAR_CLOSE_CONFIRMATION_TIMEOUT_MS = 250;
export const CLIENT_CDP_TIMEOUT_MS = 10_000;
export const CLIENT_BROWSER_OPEN_TIMEOUT_MS = 10_000;
const CLIENT_SCREENSHOT_MAX_BYTES = 5 * 1024 * 1024;
const CLIENT_SCREENSHOT_MAX_BASE64_CHARS =
  Math.ceil(CLIENT_SCREENSHOT_MAX_BYTES / 3) * 4;
const CLIENT_BROWSER_OWNER_WINDOW_ID = "win_main";
// Blink's transient user activation lifetime. Chromium's own popup blocker
// spends that activation on the first window a gesture opens; Electron routes
// every request to `setWindowOpenHandler` without consulting it, so the sidebar
// reconstructs the rule itself in `installBrowserSidebarSecurity`.
const BROWSER_SIDEBAR_USER_ACTIVATION_TIMEOUT_MS = 5_000;
const BROWSER_SIDEBAR_FAVICON_FETCH_TIMEOUT_MS = 5_000;
export const BROWSER_SIDEBAR_WEB_PREFERENCES = {
  contextIsolation: true,
  nodeIntegration: false,
  partition: BROWSER_SIDEBAR_PARTITION,
  sandbox: true,
  webSecurity: true,
  webviewTag: false,
} as const;
export const BROWSER_INSPECTION_COMPOSER_WEB_PREFERENCES = {
  contextIsolation: true,
  nodeIntegration: false,
  partition: "",
  sandbox: true,
  webSecurity: true,
  webviewTag: false,
} as const;
const BROWSER_INSPECTION_COMPOSER_NAVIGATION_ORIGINS = new Set(["assets://."]);
const CLIENT_CDP_BLOCKED_DOMAINS = new Set([
  "Browser",
  "SystemInfo",
  "Target",
  "Tethering",
]);

function assertClientCdpMethod(method: string) {
  if (!/^[A-Z][A-Za-z0-9]*\.[A-Za-z][A-Za-z0-9]*$/.test(method)) {
    throw new Error("Invalid CDP method.");
  }
  if (CLIENT_CDP_BLOCKED_DOMAINS.has(method.split(".", 1)[0]!)) {
    throw new Error("This CDP domain is unavailable for in-app browser control.");
  }
}

interface NavigationEvent {
  isMainFrame?: boolean | undefined;
  preventDefault(): void;
  url: string;
}

type BrowserSidebarSessionLike = Pick<
  Session,
  "fetch" | "setPermissionCheckHandler" | "setPermissionRequestHandler"
>;

interface BrowserSidebarKeyboardInputLike {
  alt?: boolean | undefined;
  control?: boolean | undefined;
  key?: string | undefined;
  meta?: boolean | undefined;
  type?: string | undefined;
}

interface BrowserSidebarMouseInputLike {
  type?: string | undefined;
}

interface BrowserSidebarWebContentsLike {
  readonly id: number;
  readonly session: BrowserSidebarSessionLike;
  readonly navigationHistory: {
    canGoBack(): boolean;
    canGoForward(): boolean;
    goBack(): void;
    goForward(): void;
  };
  readonly debugger?: {
    attach(protocolVersion?: string): void;
    detach(): void;
    isAttached(): boolean;
    sendCommand(
      method: string,
      commandParams?: Record<string, unknown>
    ): Promise<unknown>;
  };
  capturePage(): Promise<{ toPNG(): Uint8Array }>;
  close(options: { waitForBeforeUnload: boolean }): void;
  executeJavaScript(source: string): Promise<unknown>;
  focus(): void;
  getOSProcessId(): number;
  getTitle(): string;
  getURL(): string;
  isLoading(): boolean;
  isDestroyed(): boolean;
  loadURL(url: string): Promise<unknown>;
  on(
    event:
      | "did-fail-load"
      | "did-navigate"
      | "did-navigate-in-page"
      | "did-start-navigation"
      | "did-start-loading"
      | "did-stop-loading"
      | "page-favicon-updated"
      | "page-title-updated",
    listener: (...args: unknown[]) => void
  ): unknown;
  on(event: "destroyed", listener: () => void): unknown;
  on(event: "console-message", listener: (...args: unknown[]) => void): unknown;
  on(
    event: "will-frame-navigate" | "will-navigate" | "will-redirect",
    listener: (event: NavigationEvent, url?: string) => void
  ): unknown;
  on(
    event: "before-input-event",
    listener: (event: unknown, input: BrowserSidebarKeyboardInputLike) => void
  ): unknown;
  on(
    event: "before-mouse-event",
    listener: (event: unknown, input: BrowserSidebarMouseInputLike) => void
  ): unknown;
  on(
    event: "did-create-window",
    listener: (window: { webContents: BrowserSidebarWebContentsLike }) => void
  ): unknown;
  reload(): void;
  setWindowOpenHandler(
    handler: (details: WindowOpenDetails) => WindowOpenResponse
  ): void;
  stop(): void;
}

interface WindowOpenDetails {
  url: string;
}

type WindowOpenResponse =
  | { action: "deny" }
  | {
      action: "allow";
      overrideBrowserWindowOptions: {
        webPreferences: typeof BROWSER_SIDEBAR_WEB_PREFERENCES;
      };
    };

export interface BrowserSidebarNativeViewLike {
  getBounds(): SurfaceBounds;
  getVisible(): boolean;
  setBounds(bounds: SurfaceBounds): void;
  setVisible(visible: boolean): void;
  setBackgroundColor?(color: string): void;
}

export interface BrowserSidebarViewLike extends BrowserSidebarNativeViewLike {
  readonly webContents: BrowserSidebarWebContentsLike;
  readonly nativeView?: BrowserSidebarNativeViewLike;
}

interface BrowserInspectionComposer {
  finish(result: BrowserInspectionComposerResult): Promise<void>;
  position(): void;
  selection: Extract<BrowserSidebarInspectResult, { status: "selected" }>;
  view: BrowserSidebarViewLike;
}

type BrowserInspectionComposerResult =
  | BrowserSidebarInspectResult
  | { status: "reselect" };

interface BrowserInspectionComposerSurface {
  height: number;
  ready: Promise<boolean>;
  rendererLoading: boolean;
  view: BrowserSidebarViewLike;
  webContents: BrowserSidebarWebContentsLike;
}

export interface BrowserSidebarOwnerWindowLike {
  readonly contentView: {
    addChildView(view: BrowserSidebarNativeViewLike): void;
    removeChildView(view: BrowserSidebarNativeViewLike): void;
  };
  isDestroyed?(): boolean;
  readonly webContents?: {
    on(
      event: "did-start-navigation" | "render-process-gone",
      listener: (...args: unknown[]) => void
    ): unknown;
    removeListener(
      event: "did-start-navigation" | "render-process-gone",
      listener: (...args: unknown[]) => void
    ): unknown;
  };
}

export interface BrowserSidebarProvider {
  showPermissions(
    input: BrowserSitePermissionsInput
  ):
    | Promise<{ status: "opened" | "unavailable"; reason?: string }>
    | { status: "opened" | "unavailable"; reason?: string };
  capture(
    input: BrowserSidebarCaptureInput
  ): Promise<BrowserSidebarCaptureResult> | BrowserSidebarCaptureResult;
  close(
    input: BrowserSidebarCloseInput
  ): Promise<BrowserSidebarState> | BrowserSidebarState;
  inspect(
    input: BrowserSidebarInspectInput
  ): Promise<BrowserSidebarInspectResult> | BrowserSidebarInspectResult;
  navigate(
    input: BrowserSidebarNavigateInput
  ): Promise<BrowserSidebarState> | BrowserSidebarState;
  open(
    input: BrowserSidebarOpenInput
  ): Promise<BrowserSidebarState> | BrowserSidebarState;
  update(
    input: BrowserSidebarUpdateInput
  ): Promise<BrowserSidebarState> | BrowserSidebarState;
}

interface ActiveBrowserSidebar {
  closing: boolean;
  closePromise?: Promise<void> | undefined;
  destructionObserved: Promise<void>;
  /** The committed document's icon as a bounded `data:image/*` URL. */
  favicon?: string | undefined;
  /** Aborts the reads of the previous icon list when a new list arrives. */
  faviconFetch?: AbortController | undefined;
  faviconSourceUrl?: string | undefined;
  id: string;
  inspectionGeneration: number;
  inspectionPageGeneration?: number | undefined;
  inspectionComposerSurface?: BrowserInspectionComposerSurface | undefined;
  markDestructionObserved(): void;
  navigationGeneration: number;
  navigationPendingGeneration?: number | undefined;
  navigationRevision: number;
  navigationResumeUrl?: string | undefined;
  navigationUrl?: string | undefined;
  navigationUrlGeneration?: number | undefined;
  inspectionComposer?: BrowserInspectionComposer | undefined;
  owner: BrowserSidebarOwnerWindowLike;
  ownerWindowId: string;
  reason?: string | undefined;
  sessionId: string;
  tabId: string;
  url: string;
  view: BrowserSidebarViewLike;
  webContents: BrowserSidebarWebContentsLike;
}

export interface ClientBrowserTarget {
  tabId: string;
  title: string;
  url: string;
  visible: boolean;
}

interface PendingClientTabOpen {
  ownerWindowId: string;
  reject(error: Error): void;
  resolve(target: ClientBrowserTarget): void;
  timer: ReturnType<typeof setTimeout>;
}

interface BrowserSidebarSurfaces {
  registerView(
    registration: Parameters<NativeSurfaceService["registerView"]>[0]
  ): Promise<void> | void;
  state(): ReturnType<NativeSurfaceService["state"]>;
  unregisterView(viewId: string, expectedView?: object): Promise<void> | void;
  updateView(
    viewId: string,
    expectedView: object,
    patch: Parameters<NativeSurfaceService["updateView"]>[2]
  ): Promise<boolean> | boolean;
}

// Modeled in tla/browser-sidebar/BrowserSidebar.tla.
export class NativeBrowserSidebarService implements BrowserSidebarProvider {
  readonly #activeByTabId = new Map<string, ActiveBrowserSidebar>();
  readonly #activeByOwnerWindowId = new Map<
    string,
    Map<string, ActiveBrowserSidebar>
  >();
  readonly #createView: (ownerWindowId: string) => BrowserSidebarViewLike;
  readonly #createComposerView: (() => BrowserSidebarViewLike) | undefined;
  readonly #composerUrl: string | undefined;
  readonly #getCallerWindowId: () => string;
  readonly #operationTailByOwnerWindowId = new Map<string, Promise<void>>();
  readonly #releaseOwnerLifecycleByWindowId = new Map<string, () => void>();
  readonly #onStateChanged:
    | ((ownerWindowId: string, state: BrowserSidebarState) => Promise<void> | void)
    | undefined;
  readonly #onClientOpenTabRequested:
    | ((ownerWindowId: string, request: BrowserSidebarOpenTabRequest) => boolean)
    | undefined;
  readonly #pendingClientTabOpens = new Map<string, PendingClientTabOpen>();
  readonly #releaseOwnerWindowListener: (() => void) | undefined;
  readonly #resolveOwnerWindow: (
    windowId: string
  ) => BrowserSidebarOwnerWindowLike | undefined;
  readonly #surfaces: BrowserSidebarSurfaces;
  readonly #sitePermissions: BrowserSitePermissions | undefined;
  #disposed = false;
  readonly #meetingProbe = new BrowserMeetingProbe();

  async showPermissions(input: BrowserSitePermissionsInput) {
    const parsed = browserSitePermissionsInputSchema.parse(input);
    const active = this.#active(this.#getCallerWindowId(), parsed.sessionId);
    if (!active || active.closing || !this.#sitePermissions)
      return {
        status: "unavailable" as const,
        reason: "Website permissions are unavailable for this tab.",
      };
    return this.#sitePermissions.showSettings(active.webContents, parsed.anchor);
  }

  constructor({
    createView,
    sitePermissions,
    createComposerView,
    composerUrl,
    getCallerWindowId = () => getCurrentNativeCallerContext().windowId,
    onClientOpenTabRequested,
    onStateChanged,
    onOwnerWindowUnregistered,
    resolveOwnerWindow,
    surfaces,
  }: {
    sitePermissions?: BrowserSitePermissions | undefined;
    createView: (ownerWindowId: string) => BrowserSidebarViewLike;
    createComposerView?: (() => BrowserSidebarViewLike) | undefined;
    composerUrl?: string | undefined;
    getCallerWindowId?: (() => string) | undefined;
    onClientOpenTabRequested?:
      | ((ownerWindowId: string, request: BrowserSidebarOpenTabRequest) => boolean)
      | undefined;
    onStateChanged?:
      | ((ownerWindowId: string, state: BrowserSidebarState) => Promise<void> | void)
      | undefined;
    onOwnerWindowUnregistered?:
      | ((listener: (windowId: string) => void) => () => void)
      | undefined;
    resolveOwnerWindow: (windowId: string) => BrowserSidebarOwnerWindowLike | undefined;
    surfaces: BrowserSidebarSurfaces;
  }) {
    this.#createView = createView;
    this.#sitePermissions = sitePermissions;
    this.#createComposerView = createComposerView;
    this.#composerUrl = composerUrl;
    this.#getCallerWindowId = getCallerWindowId;
    this.#onClientOpenTabRequested = onClientOpenTabRequested;
    this.#onStateChanged = onStateChanged;
    this.#resolveOwnerWindow = resolveOwnerWindow;
    this.#surfaces = surfaces;
    this.#releaseOwnerWindowListener = onOwnerWindowUnregistered?.((windowId) => {
      void this.disposeOwner(windowId).catch(() => undefined);
    });
  }

  /** Main composition only; this is not exposed as a renderer capability. */
  async readMeetings() {
    const tabs = this.#activeByOwnerWindowId.get(CLIENT_BROWSER_OWNER_WINDOW_ID);
    const pages = [...(tabs?.values() ?? [])]
      .filter((tab) => !tab.closing)
      .map((tab) => ({
        id: String(tab.webContents.id),
        tabId: tab.sessionId,
        visible: tab.view.getVisible(),
        contents: tab.webContents,
      }));
    return this.#meetingProbe.read(pages);
  }

  /**
   * Requests one real renderer tab and settles only when that same tab has
   * created its Main-owned WebContentsView and completed its first navigation.
   * The wait is event-driven and bounded; no target polling or "most recent
   * tab" inference is involved.
   */
  async openClientTab(input: { url: string }): Promise<ClientBrowserTarget> {
    this.#requireAvailable();
    const tabId = randomUUID();
    const request = browserSidebarOpenTabRequestSchema.parse({
      tabId,
      url: input.url,
    });
    const ownerWindowId = CLIENT_BROWSER_OWNER_WINDOW_ID;
    const owner = this.#resolveOwnerWindow(ownerWindowId);
    if (!owner || owner.isDestroyed?.()) {
      throw new Error("Comma's main window is unavailable for a browser tab.");
    }
    if (!this.#onClientOpenTabRequested) {
      throw new Error("Opening an in-app browser tab is unavailable.");
    }

    return new Promise<ClientBrowserTarget>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (!this.#pendingClientTabOpens.delete(tabId)) return;
        reject(
          new Error(
            `Timed out waiting for in-app browser tab ${tabId} to become ready.`
          )
        );
      }, CLIENT_BROWSER_OPEN_TIMEOUT_MS);
      this.#pendingClientTabOpens.set(tabId, {
        ownerWindowId,
        reject,
        resolve,
        timer,
      });

      try {
        if (this.#onClientOpenTabRequested?.(ownerWindowId, request) !== true) {
          this.#rejectPendingClientTabOpen(
            tabId,
            new Error("Comma's main renderer is not ready to open a browser tab.")
          );
        }
      } catch (error: unknown) {
        this.#rejectPendingClientTabOpen(tabId, asError(error));
      }
    });
  }

  async open(input: BrowserSidebarOpenInput): Promise<BrowserSidebarState> {
    this.#requireAvailable();
    const parsed = browserSidebarOpenInputSchema.parse(input);
    const ownerWindowId = this.#getCallerWindowId();
    try {
      return await this.#enqueueOwnerOperation(ownerWindowId, async () => {
        this.#requireAvailable();
        return this.#openForOwner(ownerWindowId, parsed);
      });
    } catch (error: unknown) {
      if (parsed.tabId) {
        this.#rejectPendingClientTabOpen(parsed.tabId, asError(error));
      }
      throw error;
    }
  }

  async inspect(
    input: BrowserSidebarInspectInput
  ): Promise<BrowserSidebarInspectResult> {
    this.#requireAvailable();
    const parsed = browserSidebarInspectInputSchema.parse(input);
    const ownerWindowId = this.#getCallerWindowId();
    const active = this.#active(ownerWindowId, parsed.sessionId);
    if (!active || active.closing || active.webContents.isDestroyed()) {
      return {
        reason: "This browser page is no longer available.",
        status: "unavailable",
      };
    }

    if (parsed.action === "cancel") {
      await this.#cancelInspection(active);
      return { status: "cancelled" };
    }

    const inspectionGeneration = ++active.inspectionGeneration;
    await active.inspectionComposer?.finish({ status: "cancelled" });
    try {
      while (inspectionGeneration === active.inspectionGeneration) {
        active.webContents.focus();
        active.inspectionPageGeneration = inspectionGeneration;
        let result: unknown;
        try {
          result = await active.webContents.executeJavaScript(
            browserSidebarElementInspectorSource
          );
        } finally {
          if (active.inspectionPageGeneration === inspectionGeneration) {
            active.inspectionPageGeneration = undefined;
          }
        }
        if (inspectionGeneration !== active.inspectionGeneration) {
          return { status: "cancelled" };
        }
        const raw = result as { status?: unknown; userMessage?: unknown };
        if (raw?.status !== "selected" || typeof raw.userMessage === "string") {
          return browserSidebarInspectResultSchema.parse(result);
        }
        const selection = browserSidebarInspectResultSchema.parse({
          ...(result as object),
          userMessage: "pending",
        });
        if (selection.status !== "selected") return selection;
        // Electron 42 can re-enter the V8 inspector callback if a second
        // WebContentsView is attached while executeJavaScript is settling. Move
        // the native view-tree mutation to the next Main turn, then revalidate
        // ownership before showing the isolated Composer surface.
        await nextMainTurn();
        if (
          inspectionGeneration !== active.inspectionGeneration ||
          active.closing ||
          active.webContents.isDestroyed()
        ) {
          return { status: "cancelled" };
        }
        const composed = await this.#showInspectionComposer(active, selection);
        if (composed.status === "reselect") continue;
        if (inspectionGeneration === active.inspectionGeneration) {
          await this.#cancelInspection(active);
        }
        return composed;
      }
      return { status: "cancelled" };
    } catch {
      return {
        reason: "The page changed before element selection finished.",
        status: "unavailable",
      };
    }
  }

  async #openForOwner(
    ownerWindowId: string,
    parsed: BrowserSidebarOpenInput
  ): Promise<BrowserSidebarState> {
    const tabId = parsed.tabId ?? parsed.sessionId;
    const owner = this.#resolveOwnerWindow(ownerWindowId);
    if (!owner || owner.isDestroyed?.()) {
      throw new Error(
        `Browser sidebar owner window ${ownerWindowId} is not registered.`
      );
    }
    this.#installOwnerLifecycle(ownerWindowId, owner);

    const tabOwner = this.#activeByTabId.get(tabId);
    if (
      tabOwner &&
      (tabOwner.ownerWindowId !== ownerWindowId ||
        tabOwner.sessionId !== parsed.sessionId)
    ) {
      throw new Error(`Browser tab ${tabId} is already owned by another session.`);
    }

    const previous = this.#active(ownerWindowId, parsed.sessionId);
    if (previous && !previous.closing) {
      if (previous.tabId !== tabId) {
        throw new Error(
          `Browser session ${parsed.sessionId} cannot change its tab identity.`
        );
      }
      this.#hideOtherSessions(ownerWindowId, parsed.sessionId);
      this.#touchActive(previous);
      previous.view.setBounds(parsed.bounds);
      previous.inspectionComposer?.position();
      previous.view.setVisible(true);
      const requestedNavigationRevision = parsed.navigationRevision ?? 0;
      if (requestedNavigationRevision > previous.navigationRevision) {
        previous.navigationRevision = requestedNavigationRevision;
        this.#startNavigation(previous, normalizeBrowserSidebarUrl(parsed.url));
      } else if (previous.navigationResumeUrl) {
        this.#startNavigation(previous, previous.navigationResumeUrl);
      }
      await this.#surfaces.updateView(previous.id, previous.view, {
        bounds: parsed.bounds,
      });
      const state = await this.#state(ownerWindowId, parsed.sessionId);
      await this.#onStateChanged?.(ownerWindowId, state);
      this.#resolvePendingClientTabOpenIfReady(previous);
      return state;
    }
    if (previous) {
      await this.#closeActive(previous);
    }

    const hasRendererCapacityFence = parsed.closeBeforeOpenSessionIds !== undefined;
    const closeBeforeOpenSessionIds = parsed.closeBeforeOpenSessionIds ?? [];
    const exactVictimsDrained = await this.#closeBeforeOpening(
      ownerWindowId,
      closeBeforeOpenSessionIds
    );
    if (hasRendererCapacityFence) {
      // Product renderers include the field even when no victim was selected.
      // Never turn a stale or missing fence into an unrelated retained-page eviction.
      const sessionCount = this.#activeByOwnerWindowId.get(ownerWindowId)?.size ?? 0;
      if (!exactVictimsDrained || sessionCount >= maxBrowserSidebarSessionsPerOwner) {
        const state = capacityBlockedState(parsed.sessionId);
        try {
          await this.#onStateChanged?.(ownerWindowId, state);
        } catch {
          // The command result carries the same retryable state. Do not turn a
          // transient event-delivery failure into a permanent renderer error.
        }
        this.#rejectPendingClientTabOpen(
          tabId,
          new Error("Comma has reached its retained in-app browser tab capacity.")
        );
        return state;
      }
    } else {
      await this.#evictBeforeOpening(ownerWindowId);
    }
    this.#hideOtherSessions(ownerWindowId, parsed.sessionId);
    const view = this.#createView(ownerWindowId);
    const webContents = view.webContents;
    const destructionSignal = createDestructionSignal();
    const active: ActiveBrowserSidebar = {
      closing: false,
      destructionObserved: destructionSignal.promise,
      id: browserSidebarViewId(ownerWindowId, parsed.sessionId),
      inspectionGeneration: 0,
      markDestructionObserved: destructionSignal.resolve,
      navigationGeneration: 0,
      navigationRevision: parsed.navigationRevision ?? 0,
      navigationUrl: normalizeBrowserSidebarUrl(parsed.url),
      owner,
      ownerWindowId,
      sessionId: parsed.sessionId,
      tabId,
      url: normalizeBrowserSidebarUrl(parsed.url),
      view,
      webContents,
    };
    try {
      webContents.on("destroyed", () => {
        active.markDestructionObserved();
        if (
          !active.closing ||
          (!active.closePromise &&
            this.#active(active.ownerWindowId, active.sessionId) === active)
        ) {
          const closePromise = this.#handleExternallyDestroyed(active);
          active.closePromise = closePromise;
          void closePromise.catch(() => undefined);
        }
      });
      installBrowserSidebarSecurity(webContents, {
        sitePermissions: this.#sitePermissions,
      });
      this.#sitePermissions?.register(
        webContents,
        owner,
        () =>
          !active.closing && this.#active(ownerWindowId, active.sessionId) === active
      );
      this.#installNavigationStatePublishing(active);
      view.setBounds(parsed.bounds);
      view.setVisible(true);
      owner.contentView.addChildView(view.nativeView ?? view);
    } catch (error: unknown) {
      try {
        owner.contentView.removeChildView(view.nativeView ?? view);
      } catch {
        // Continue to the explicit WebContents close below.
      }
      closeWebContents(webContents);
      throw error;
    }
    this.#ownerSessions(ownerWindowId).set(parsed.sessionId, active);
    this.#activeByTabId.set(tabId, active);

    try {
      await this.#surfaces.registerView({
        bounds: parsed.bounds,
        id: active.id,
        lifecycle: "creating",
        ownerWindowId,
        partition: BROWSER_SIDEBAR_PARTITION,
        role: BROWSER_SIDEBAR_ROLE,
        view,
      });
      this.#startNavigation(active, active.url);
      void nextMainTurn()
        .then(() => {
          if (
            !active.closing &&
            this.#active(active.ownerWindowId, active.sessionId) === active
          ) {
            return this.#ensureInspectionComposerSurface(active);
          }
          return undefined;
        })
        .catch(() => undefined);
      await this.#surfaces.updateView(active.id, view, {
        bounds: view.getBounds(),
        lifecycle: "ready",
      });
    } catch (error: unknown) {
      if (this.#active(ownerWindowId, parsed.sessionId) === active) {
        await this.#closeActive(active);
      }
      throw error;
    }

    const state = await this.#state(ownerWindowId, parsed.sessionId);
    await this.#onStateChanged?.(ownerWindowId, state);
    // A native view is not yet a usable browser page. The loadURL settlement
    // below resolves the client request after the exact tab has finished its
    // first navigation. That prevents a following open from hiding/stopping
    // this tab while its document is still empty.
    this.#resolvePendingClientTabOpenIfReady(active);
    return state;
  }

  async update(input: BrowserSidebarUpdateInput): Promise<BrowserSidebarState> {
    this.#requireAvailable();
    const parsed = browserSidebarUpdateInputSchema.parse(input);
    const ownerWindowId = this.#getCallerWindowId();
    return this.#enqueueOwnerOperation(ownerWindowId, async () => {
      this.#requireAvailable();
      return this.#updateForOwner(ownerWindowId, parsed);
    });
  }

  /**
   * One PNG frame of the live view, for a renderer that is about to hide it
   * behind a full-window DOM overlay and needs a stand-in that matches what
   * was on screen. Only a visible view can be captured: anything else has no
   * on-screen frame to stand in for.
   */
  async capture(
    input: BrowserSidebarCaptureInput
  ): Promise<BrowserSidebarCaptureResult> {
    this.#requireAvailable();
    const parsed = browserSidebarCaptureInputSchema.parse(input);
    const ownerWindowId = this.#getCallerWindowId();
    return this.#enqueueOwnerOperation(ownerWindowId, async () => {
      this.#requireAvailable();
      const active = this.#active(ownerWindowId, parsed.sessionId);
      if (
        !active ||
        active.closing ||
        active.webContents.isDestroyed() ||
        !active.view.getVisible()
      ) {
        return { status: "unavailable" };
      }
      try {
        return {
          pngImage: (await active.webContents.capturePage()).toPNG(),
          status: "ready",
        };
      } catch {
        // The caller falls back to hiding without a stand-in.
        return { status: "unavailable" };
      }
    });
  }

  listClientTargets() {
    const targets: ClientBrowserTarget[] = [];
    for (const sessions of this.#activeByOwnerWindowId.values()) {
      for (const active of sessions.values()) {
        if (active.closing || active.webContents.isDestroyed()) continue;
        targets.push(this.#clientTarget(active));
      }
    }
    return targets;
  }

  async sendClientCdpCommand(input: {
    method: string;
    params: Record<string, unknown>;
    tabId: string;
  }) {
    assertClientCdpMethod(input.method);
    const target = this.#requireClientTarget(input.tabId);
    return this.#enqueueOwnerOperation(target.ownerWindowId, async () => {
      const active = this.#requireClientTarget(input.tabId);
      return this.#withClientDebugger(active, (debuggerApi) =>
        debuggerApi.sendCommand(input.method, input.params)
      );
    });
  }

  async captureClientScreenshot(input: { tabId: string }) {
    const target = this.#requireClientTarget(input.tabId);
    return this.#enqueueOwnerOperation(target.ownerWindowId, async () => {
      const active = this.#requireClientTarget(input.tabId);
      // capturePage() has no painted frame for a hidden WebContentsView on
      // macOS. CDP remains bound to this exact tab's WebContents, and captures
      // its compositor surface without selecting or flashing the tab in UI.
      const result = await this.#withClientDebugger(
        active,
        (debuggerApi) =>
          debuggerApi.sendCommand("Page.captureScreenshot", {
            captureBeyondViewport: false,
            format: "png",
            fromSurface: true,
          }),
        CLIENT_SCREENSHOT_MAX_BASE64_CHARS + 256
      );
      const data = (result as { data?: unknown } | null)?.data;
      if (
        typeof data !== "string" ||
        data.length > CLIENT_SCREENSHOT_MAX_BASE64_CHARS
      ) {
        throw new Error("Browser screenshot exceeds its decoded limit.");
      }
      const screenshot = Buffer.from(data, "base64");
      if (screenshot.byteLength > CLIENT_SCREENSHOT_MAX_BYTES) {
        throw new Error("Browser screenshot exceeds its decoded limit.");
      }
      return {
        pngImage: screenshot,
        target: this.#clientTarget(active),
      };
    });
  }

  #requireClientTarget(tabId: string) {
    this.#requireAvailable();
    const active = this.#activeByTabId.get(tabId);
    if (!active || active.closing || active.webContents.isDestroyed()) {
      throw new Error(`The requested in-app browser tab ${tabId} is unavailable.`);
    }
    return active;
  }

  #clientTarget(active: ActiveBrowserSidebar): ClientBrowserTarget {
    return {
      tabId: active.tabId,
      title: active.webContents.getTitle(),
      url: currentSafeUrl(active.webContents, active.url),
      visible: active.view.getVisible(),
    };
  }

  #resolvePendingClientTabOpen(active: ActiveBrowserSidebar) {
    const pending = this.#pendingClientTabOpens.get(active.tabId);
    if (!pending || pending.ownerWindowId !== active.ownerWindowId) return;
    this.#pendingClientTabOpens.delete(active.tabId);
    clearTimeout(pending.timer);
    pending.resolve(this.#clientTarget(active));
  }

  #resolvePendingClientTabOpenIfReady(active: ActiveBrowserSidebar) {
    if (
      active.navigationPendingGeneration !== undefined ||
      active.webContents.isLoading()
    ) {
      return;
    }
    this.#resolvePendingClientTabOpen(active);
  }

  #rejectPendingClientTabOpen(tabId: string, error: Error) {
    const pending = this.#pendingClientTabOpens.get(tabId);
    if (!pending) return;
    this.#pendingClientTabOpens.delete(tabId);
    clearTimeout(pending.timer);
    pending.reject(error);
  }

  #rejectPendingClientTabOpensForOwner(ownerWindowId: string, error: Error) {
    for (const [tabId, pending] of this.#pendingClientTabOpens) {
      if (pending.ownerWindowId === ownerWindowId) {
        this.#rejectPendingClientTabOpen(tabId, error);
      }
    }
  }

  async #withClientDebugger<T>(
    active: ActiveBrowserSidebar,
    operation: (
      debuggerApi: NonNullable<BrowserSidebarWebContentsLike["debugger"]>
    ) => Promise<T>,
    maxResultChars = 512 * 1024
  ) {
    const debuggerApi = active.webContents.debugger;
    if (!debuggerApi) throw new Error("CDP is unavailable for this browser target.");
    if (debuggerApi.isAttached()) {
      throw new Error("The browser target is already attached to a debugger.");
    }
    debuggerApi.attach("1.3");
    try {
      const result = await withWallTimeout(
        operation(debuggerApi),
        CLIENT_CDP_TIMEOUT_MS,
        "CDP command timed out."
      );
      const encoded = JSON.stringify(result);
      if (encoded !== undefined && encoded.length > maxResultChars) {
        throw new Error("CDP result exceeds its response limit.");
      }
      return result;
    } finally {
      try {
        if (debuggerApi.isAttached()) debuggerApi.detach();
      } catch {
        // Detach is cleanup. Never hide the command's timeout or protocol error.
      }
    }
  }

  async #updateForOwner(
    ownerWindowId: string,
    parsed: BrowserSidebarUpdateInput
  ): Promise<BrowserSidebarState> {
    const active = this.#active(ownerWindowId, parsed.sessionId);
    if (!active) {
      return availableInactiveState(parsed.sessionId);
    }
    if (active.closing) return this.#state(ownerWindowId, parsed.sessionId);
    this.#touchActive(active);

    if (parsed.bounds) {
      active.view.setBounds(parsed.bounds);
      active.inspectionComposer?.position();
      await this.#surfaces.updateView(active.id, active.view, {
        bounds: parsed.bounds,
      });
    }
    if (parsed.visible !== undefined) {
      if (parsed.visible) {
        this.#hideOtherSessions(ownerWindowId, parsed.sessionId);
      } else if (!active.webContents.isDestroyed()) {
        void this.#cancelInspection(active);
        this.#pauseNavigation(active);
      }
      active.view.setVisible(parsed.visible);
    }
    if (parsed.url) {
      const nextUrl = normalizeBrowserSidebarUrl(parsed.url);
      this.#startNavigation(active, nextUrl);
    } else if (parsed.visible && active.navigationResumeUrl) {
      this.#startNavigation(active, active.navigationResumeUrl);
    }

    const state = await this.#state(ownerWindowId, parsed.sessionId);
    await this.#onStateChanged?.(ownerWindowId, state);
    return state;
  }

  async navigate(input: BrowserSidebarNavigateInput): Promise<BrowserSidebarState> {
    this.#requireAvailable();
    const parsed = browserSidebarNavigateInputSchema.parse(input);
    const ownerWindowId = this.#getCallerWindowId();
    return this.#enqueueOwnerOperation(ownerWindowId, async () => {
      this.#requireAvailable();
      const active = this.#active(ownerWindowId, parsed.sessionId);
      if (!active || active.closing) {
        return availableInactiveState(parsed.sessionId);
      }
      this.#touchActive(active);

      const { navigationHistory } = active.webContents;
      if (parsed.action === "back" && navigationHistory.canGoBack()) {
        this.#invalidateNavigation(active);
        active.reason = undefined;
        navigationHistory.goBack();
      } else if (parsed.action === "forward" && navigationHistory.canGoForward()) {
        this.#invalidateNavigation(active);
        active.reason = undefined;
        navigationHistory.goForward();
      } else if (parsed.action === "reload") {
        this.#invalidateNavigation(active);
        active.reason = undefined;
        active.webContents.reload();
      } else if (parsed.action === "stop") {
        this.#invalidateNavigation(active);
        active.webContents.stop();
      }

      const state = await this.#state(ownerWindowId, parsed.sessionId);
      await this.#onStateChanged?.(ownerWindowId, state);
      return state;
    });
  }

  async close(input: BrowserSidebarCloseInput): Promise<BrowserSidebarState> {
    this.#requireAvailable();
    const parsed = browserSidebarCloseInputSchema.parse(input);
    const ownerWindowId = this.#getCallerWindowId();
    this.#preemptSession(ownerWindowId, parsed.sessionId);
    return this.#enqueueOwnerOperation(ownerWindowId, () =>
      this.#closeSession(ownerWindowId, parsed.sessionId)
    );
  }

  async disposeOwner(ownerWindowId: string) {
    this.#rejectPendingClientTabOpensForOwner(
      ownerWindowId,
      new Error("The browser tab owner window closed before the tab became ready.")
    );
    this.#releaseOwnerLifecycle(ownerWindowId);
    this.#preemptOwner(ownerWindowId);
    return this.#enqueueOwnerOperation(ownerWindowId, () =>
      this.#closeForOwner(ownerWindowId)
    );
  }

  async reset() {
    for (const tabId of this.#pendingClientTabOpens.keys()) {
      this.#rejectPendingClientTabOpen(
        tabId,
        new Error("Browser sidebar reset before the tab became ready.")
      );
    }
    const ownerWindowIds = Array.from(this.#activeByOwnerWindowId.keys());
    for (const ownerWindowId of ownerWindowIds) {
      this.#preemptOwner(ownerWindowId);
    }
    await Promise.all(
      ownerWindowIds.map((ownerWindowId) =>
        this.#enqueueOwnerOperation(ownerWindowId, () =>
          this.#closeForOwner(ownerWindowId)
        )
      )
    );
  }

  async #closeForOwner(ownerWindowId: string) {
    const sessions = this.#activeByOwnerWindowId.get(ownerWindowId);
    await Promise.all(
      Array.from(sessions?.values() ?? [], (active) => this.#closeActive(active))
    );
    return availableInactiveState();
  }

  async #closeSession(ownerWindowId: string, sessionId: string) {
    const active = this.#active(ownerWindowId, sessionId);
    let firstError: unknown;
    if (active) {
      try {
        await this.#closeActive(active);
      } catch (error: unknown) {
        firstError = error;
      }
      if (this.#active(ownerWindowId, sessionId) === active) {
        throw (
          firstError ??
          new Error(`Browser sidebar session ${sessionId} remained active after close.`)
        );
      }
    }
    const state = availableInactiveState(sessionId);
    try {
      await this.#onStateChanged?.(ownerWindowId, state);
    } catch (error: unknown) {
      firstError ??= error;
    }
    if (firstError) throw firstError;
    return state;
  }

  async dispose() {
    if (this.#disposed) {
      return;
    }
    this.#disposed = true;
    for (const tabId of this.#pendingClientTabOpens.keys()) {
      this.#rejectPendingClientTabOpen(
        tabId,
        new Error("Browser sidebar service was disposed before the tab became ready.")
      );
    }
    this.#releaseOwnerWindowListener?.();
    for (const release of this.#releaseOwnerLifecycleByWindowId.values()) {
      release();
    }
    this.#releaseOwnerLifecycleByWindowId.clear();
    for (const ownerWindowId of this.#activeByOwnerWindowId.keys()) {
      this.#preemptOwner(ownerWindowId);
    }
    await Promise.all(
      Array.from(this.#activeByOwnerWindowId.values(), (sessions) =>
        Promise.all(
          Array.from(sessions.values(), (active) => this.#closeActive(active))
        )
      )
    );
    await Promise.all(
      Array.from(this.#operationTailByOwnerWindowId.values(), (operation) =>
        operation.catch(() => undefined)
      )
    );
  }

  #closeActive(active: ActiveBrowserSidebar) {
    if (active.closePromise) {
      return active.closePromise;
    }
    const closePromise = this.#performClose(active).catch((error: unknown) => {
      if (this.#active(active.ownerWindowId, active.sessionId) === active) {
        active.closePromise = undefined;
      }
      throw error;
    });
    active.closePromise = closePromise;
    return closePromise;
  }

  async #performClose(active: ActiveBrowserSidebar) {
    active.closing = true;
    this.#invalidateNavigation(active);
    await this.#cancelInspection(active);
    this.#disposeInspectionComposerSurface(active);

    let firstError: unknown;
    try {
      await this.#surfaces.updateView(active.id, active.view, {
        lifecycle: "destroying",
      });
    } catch (error: unknown) {
      firstError = error;
    }

    try {
      active.owner.contentView.removeChildView(active.view.nativeView ?? active.view);
    } catch (error: unknown) {
      firstError ??= error;
    }
    try {
      active.view.setVisible(false);
    } catch (error: unknown) {
      firstError ??= error;
    }
    try {
      if (!active.webContents.isDestroyed()) {
        active.webContents.close({ waitForBeforeUnload: false });
      }
    } catch (error: unknown) {
      firstError ??= error;
    }

    let webContentsDestroyed = this.#isWebContentsDestroyed(active);
    if (!webContentsDestroyed) {
      await waitForDestructionConfirmation(active);
      webContentsDestroyed = this.#isWebContentsDestroyed(active);
    }
    if (!webContentsDestroyed) {
      throw (
        firstError ??
        new Error(
          `Browser sidebar session ${active.sessionId} did not destroy its WebContents.`
        )
      );
    }

    this.#deleteActive(active);

    try {
      await this.#surfaces.updateView(active.id, active.view, {
        lifecycle: "destroyed",
      });
    } catch (error: unknown) {
      firstError ??= error;
    }
    try {
      await this.#surfaces.unregisterView(active.id, active.view);
    } catch (error: unknown) {
      firstError ??= error;
    }

    if (firstError) {
      throw firstError;
    }
  }

  #isWebContentsDestroyed(active: ActiveBrowserSidebar) {
    try {
      return active.webContents.isDestroyed();
    } catch {
      return false;
    }
  }

  async #handleExternallyDestroyed(active: ActiveBrowserSidebar) {
    active.closing = true;
    this.#deleteActive(active);
    try {
      active.owner.contentView.removeChildView(active.view.nativeView ?? active.view);
    } catch {
      // The owner may already be closing; the WebContents is still explicitly gone.
    }
    let firstError: unknown;
    try {
      await this.#surfaces.updateView(active.id, active.view, {
        lifecycle: "destroyed",
      });
    } catch (error: unknown) {
      firstError = error;
    }
    try {
      await this.#surfaces.unregisterView(active.id, active.view);
    } catch (error: unknown) {
      firstError ??= error;
    }
    try {
      await this.#onStateChanged?.(
        active.ownerWindowId,
        availableInactiveState(active.sessionId)
      );
    } catch (error: unknown) {
      firstError ??= error;
    }
    if (firstError) throw firstError;
  }

  async #state(ownerWindowId: string, sessionId: string): Promise<BrowserSidebarState> {
    const active = this.#active(ownerWindowId, sessionId);
    if (!active) {
      return availableInactiveState(sessionId);
    }
    const snapshot = await this.#surfaces.state();
    const surface = snapshot.views.find(
      (view) =>
        view.id === active.id &&
        view.windowId === active.ownerWindowId &&
        view.lifecycle !== "destroyed"
    );
    active.url = currentSafeUrl(active.webContents, active.url);
    return {
      active: true,
      available: true,
      sessionId,
      canGoBack: active.webContents.navigationHistory.canGoBack(),
      canGoForward: active.webContents.navigationHistory.canGoForward(),
      loading: active.webContents.isLoading(),
      ...(active.reason ? { reason: active.reason } : {}),
      ...(surface ? { surface } : {}),
      url: active.url,
      title: active.webContents.getTitle(),
      ...(active.favicon ? { favicon: active.favicon } : {}),
      visible: active.view.getVisible(),
    };
  }

  #installNavigationStatePublishing(active: ActiveBrowserSidebar) {
    const publish = () => {
      void this.#publishState(active).catch(() => undefined);
    };
    const trackNavigationUrl = (
      value: unknown,
      { advanceGeneration = true }: { advanceGeneration?: boolean } = {}
    ) => {
      if (typeof value !== "string" || !isSafeBrowserSidebarUrl(value)) return;
      const url = normalizeBrowserSidebarUrl(value);
      if (advanceGeneration && url !== active.navigationUrl) {
        active.navigationGeneration += 1;
      }
      active.navigationUrl = url;
      active.navigationUrlGeneration = active.navigationGeneration;
      active.reason = undefined;
    };
    active.webContents.on("did-start-navigation", (...args) => {
      const isMainFrame = typeof args[3] !== "boolean" || args[3];
      if (isMainFrame) trackNavigationUrl(args[1]);
    });
    active.webContents.on("will-navigate", (event) => {
      trackNavigationUrl(event.url);
    });
    active.webContents.on("will-redirect", (event) => {
      if (event.isMainFrame !== false) {
        trackNavigationUrl(event.url, { advanceGeneration: false });
      }
    });
    active.webContents.on("did-fail-load", (...args) => {
      const errorCode = typeof args[1] === "number" ? args[1] : undefined;
      const errorDescription =
        typeof args[2] === "string" ? args[2] : "This page could not be loaded.";
      const validatedUrl = typeof args[3] === "string" ? args[3] : undefined;
      const isMainFrame = typeof args[4] !== "boolean" || args[4];
      if (
        isMainFrame &&
        errorCode !== -3 &&
        this.#isCurrentNavigationFailure(active, validatedUrl)
      ) {
        active.reason = errorDescription;
      }
      publish();
    });
    active.webContents.on("did-navigate", publish);
    active.webContents.on("did-navigate-in-page", publish);
    active.webContents.on("page-favicon-updated", (...args) => {
      void this.#loadFavicon(active, args[1])
        .then((changed) => {
          if (changed) publish();
        })
        .catch(() => undefined);
    });
    active.webContents.on("did-start-loading", () => {
      active.reason = undefined;
      publish();
    });
    active.webContents.on("did-stop-loading", publish);
    active.webContents.on("page-title-updated", publish);
  }

  /**
   * Chromium reports the document's icon candidates, including the implicit
   * `/favicon.ico`. The app renderer may load only `data:` images, so Main
   * reads the first candidate that is an image through the tab's own session:
   * the page's partition, cookies and HTTP cache, usually a cache hit. An
   * inline `data:image/*` icon is used as is; `data:,` means "no icon".
   *
   * Each list replaces the icon, including with none. A navigation alone does
   * not: Chromium skips the event when the next document declares the same
   * list, so clearing on `did-navigate` would lose a reloaded page's icon. A
   * list that still names the current icon's source keeps it without a read,
   * even if an earlier candidate would now load; at 16 px any of them will do.
   */
  async #loadFavicon(active: ActiveBrowserSidebar, candidates: unknown) {
    const urls = (Array.isArray(candidates) ? candidates : []).filter(
      (url): url is string =>
        typeof url === "string" && /^(?:https?:|data:image\/)/.test(url)
    );
    active.faviconFetch?.abort();
    const fetch = new AbortController();
    active.faviconFetch = fetch;
    if (active.faviconSourceUrl && urls.includes(active.faviconSourceUrl)) {
      return false;
    }
    for (const url of urls) {
      const favicon = url.startsWith("data:")
        ? url
        : await fetchFavicon(active.webContents.session, url, fetch.signal).catch(
            () => undefined
          );
      if (fetch.signal.aborted || active.closing) return false;
      // A long `Content-Type` can push a fetched icon past the published limit.
      if (favicon && favicon.length <= maxBrowserSidebarFaviconDataUrlLength) {
        active.favicon = favicon;
        active.faviconSourceUrl = url;
        return true;
      }
    }
    const changed = active.favicon !== undefined;
    active.favicon = undefined;
    active.faviconSourceUrl = undefined;
    return changed;
  }

  async #publishState(active: ActiveBrowserSidebar) {
    if (
      active.closing ||
      this.#active(active.ownerWindowId, active.sessionId) !== active
    ) {
      return;
    }
    await this.#onStateChanged?.(
      active.ownerWindowId,
      await this.#state(active.ownerWindowId, active.sessionId)
    );
  }

  #startNavigation(active: ActiveBrowserSidebar, url: string) {
    void this.#cancelInspection(active);
    const navigationGeneration = ++active.navigationGeneration;
    active.reason = undefined;
    active.navigationPendingGeneration = navigationGeneration;
    active.navigationResumeUrl = undefined;
    active.navigationUrl = url;
    active.navigationUrlGeneration = navigationGeneration;
    active.url = url;
    let navigation: Promise<unknown>;
    try {
      navigation = active.webContents.loadURL(url);
    } catch (error: unknown) {
      if (!this.#isCurrentNavigation(active, navigationGeneration)) return;
      active.navigationPendingGeneration = undefined;
      if (isExpectedNavigationCancellation(error)) {
        void this.#publishState(active).catch(() => undefined);
        return;
      }
      active.reason =
        error instanceof Error ? error.message : "This page could not be loaded.";
      this.#rejectPendingClientTabOpen(active.tabId, asError(error));
      void this.#publishState(active).catch(() => undefined);
      return;
    }
    void navigation.then(
      () => {
        if (!this.#isCurrentNavigation(active, navigationGeneration)) return;
        active.navigationPendingGeneration = undefined;
        active.url = currentSafeUrl(active.webContents, url);
        // Electron's loadURL Promise is the navigation-complete signal. Its
        // callback can run before isLoading() flips for the next Main turn, so
        // do not add a second sampled-state gate here.
        this.#resolvePendingClientTabOpen(active);
        void this.#publishState(active).catch(() => undefined);
      },
      (error: unknown) => {
        if (!this.#isCurrentNavigation(active, navigationGeneration)) return;
        active.navigationPendingGeneration = undefined;
        if (isExpectedNavigationCancellation(error)) {
          void this.#publishState(active).catch(() => undefined);
          return;
        }
        active.reason =
          error instanceof Error ? error.message : "This page could not be loaded.";
        this.#rejectPendingClientTabOpen(active.tabId, asError(error));
        void this.#publishState(active).catch(() => undefined);
      }
    );
  }

  #active(ownerWindowId: string, sessionId: string) {
    return this.#activeByOwnerWindowId.get(ownerWindowId)?.get(sessionId);
  }

  #ownerSessions(ownerWindowId: string) {
    let sessions = this.#activeByOwnerWindowId.get(ownerWindowId);
    if (!sessions) {
      sessions = new Map();
      this.#activeByOwnerWindowId.set(ownerWindowId, sessions);
    }
    return sessions;
  }

  async #evictBeforeOpening(ownerWindowId: string) {
    const sessions = this.#activeByOwnerWindowId.get(ownerWindowId);
    const overflow = Math.max(
      0,
      (sessions?.size ?? 0) - maxBrowserSidebarSessionsPerOwner + 1
    );
    const evictions = Array.from(sessions?.values() ?? []).slice(0, overflow);
    for (const oldest of evictions) {
      this.#preemptSession(ownerWindowId, oldest.sessionId);
      await this.#closeActive(oldest);
    }
  }

  async #closeBeforeOpening(ownerWindowId: string, sessionIds: readonly string[]) {
    for (const sessionId of sessionIds) {
      const victim = this.#active(ownerWindowId, sessionId);
      if (!victim) continue;
      try {
        this.#preemptSession(ownerWindowId, sessionId);
      } catch {
        // Physical teardown below is still authoritative for the fence.
      }
      try {
        await this.#closeActive(victim);
      } catch {
        // The tracked-handle check below distinguishes a real teardown failure
        // from a reporting failure after physical release.
      }
      // performClose is best-effort and deletes the native session only after
      // trying every teardown step. A reporting failure after that point must
      // not strand later exact victims or their fenced replacement.
      if (this.#active(ownerWindowId, sessionId) === victim) {
        // The ordered head is still physically live. Leave the suffix untouched
        // so the caller can retry the same exact fence after capacity is released.
        return false;
      }
    }
    return true;
  }

  #touchActive(active: ActiveBrowserSidebar) {
    const sessions = this.#activeByOwnerWindowId.get(active.ownerWindowId);
    if (sessions?.get(active.sessionId) !== active) return;
    sessions.delete(active.sessionId);
    sessions.set(active.sessionId, active);
  }

  #invalidateNavigation(
    active: ActiveBrowserSidebar,
    { preserveResume = false }: { preserveResume?: boolean } = {}
  ) {
    active.navigationGeneration += 1;
    active.navigationPendingGeneration = undefined;
    if (!preserveResume) active.navigationResumeUrl = undefined;
    active.navigationUrl = undefined;
    active.navigationUrlGeneration = undefined;
  }

  #pauseNavigation(active: ActiveBrowserSidebar) {
    const resumableUrl =
      active.navigationPendingGeneration === active.navigationGeneration
        ? active.navigationUrl
        : undefined;
    if (resumableUrl) active.navigationResumeUrl = resumableUrl;
    this.#invalidateNavigation(active, { preserveResume: true });
    active.webContents.stop();
  }

  async #cancelInspection(active: ActiveBrowserSidebar) {
    const hadActivePageInspection = active.inspectionPageGeneration !== undefined;
    active.inspectionGeneration += 1;
    active.inspectionPageGeneration = undefined;
    const composer = active.inspectionComposer;
    if (composer) {
      await composer.finish({ status: "cancelled" });
    }
    if (!hadActivePageInspection || active.webContents.isDestroyed()) return;
    try {
      await active.webContents.executeJavaScript(
        browserSidebarElementInspectorCancelSource
      );
    } catch {
      // Navigation or teardown may destroy the page before cancellation runs.
    }
  }

  // Modeled in tla/browser-sidebar/BrowserInspectionComposer.tla.
  async #showInspectionComposer(
    active: ActiveBrowserSidebar,
    selection: Extract<BrowserSidebarInspectResult, { status: "selected" }>
  ): Promise<BrowserInspectionComposerResult> {
    const surface = await this.#ensureInspectionComposerSurface(active);
    if (!surface) {
      return {
        reason: "The element composer is unavailable.",
        status: "unavailable",
      };
    }

    return await new Promise<BrowserInspectionComposerResult>((resolve) => {
      let finished = false;
      const position = () => {
        const browserBounds = active.view.getBounds();
        const width = Math.min(440, Math.max(240, browserBounds.width - 24));
        const maxHeight = Math.max(56, browserBounds.height - 24);
        const resolvedHeight = Math.min(surface.height, maxHeight);
        const x = Math.max(
          browserBounds.x + 12,
          Math.min(
            browserBounds.x + selection.element.rect.x,
            browserBounds.x + browserBounds.width - width - 12
          )
        );
        const below =
          browserBounds.y +
          selection.element.rect.y +
          selection.element.rect.height +
          12;
        const above = browserBounds.y + selection.element.rect.y - resolvedHeight - 12;
        const y =
          below + resolvedHeight <= browserBounds.y + browserBounds.height - 12
            ? below
            : Math.max(browserBounds.y + 12, above);
        surface.view.setBounds({ height: resolvedHeight, width, x, y });
      };
      const finish = async (result: BrowserInspectionComposerResult) => {
        if (finished) return;
        finished = true;
        if (active.inspectionComposer?.view === surface.view) {
          active.inspectionComposer = undefined;
        }
        try {
          surface.view.setVisible(false);
        } catch {
          // Owner teardown may already have destroyed the reusable surface.
        }
        resolve(result);
      };
      active.inspectionComposer = { finish, position, selection, view: surface.view };
      position();
      surface.view.setVisible(true);
      surface.webContents.focus();
      void surface.webContents
        .executeJavaScript(browserInspectionComposerActivateSource)
        .catch(() =>
          finish({
            reason: "The element composer could not be activated.",
            status: "unavailable",
          })
        );
    });
  }

  async #ensureInspectionComposerSurface(
    active: ActiveBrowserSidebar
  ): Promise<BrowserInspectionComposerSurface | undefined> {
    const current = active.inspectionComposerSurface;
    if (current && !current.webContents.isDestroyed()) {
      return (await current.ready) ? current : undefined;
    }
    const createView = this.#createComposerView;
    const composerUrl = this.#composerUrl;
    if (!createView || !composerUrl || active.closing) return undefined;

    const view = createView();
    const webContents = view.webContents;
    let readySettled = false;
    let resolveReady!: (ready: boolean) => void;
    const ready = new Promise<boolean>((resolve) => {
      resolveReady = (value) => {
        if (readySettled) return;
        readySettled = true;
        resolve(value);
      };
    });
    const surface: BrowserInspectionComposerSurface = {
      height: 76,
      ready,
      rendererLoading: true,
      view,
      webContents,
    };
    active.inspectionComposerSurface = surface;

    webContents.setWindowOpenHandler(() => ({ action: "deny" }));
    webContents.on("will-navigate", (event, url) => {
      const targetUrl = typeof url === "string" ? url : event.url;
      if (!isAllowedUrl(targetUrl, BROWSER_INSPECTION_COMPOSER_NAVIGATION_ORIGINS)) {
        event.preventDefault();
      }
    });
    webContents.on("destroyed", () => {
      resolveReady(false);
      try {
        active.owner.contentView.removeChildView(view.nativeView ?? view);
      } catch {
        // Owner teardown may remove the child first.
      }
      try {
        view.setVisible(false);
      } catch {
        // The native view may already be gone with its WebContents.
      }
      if (active.inspectionComposerSurface === surface) {
        active.inspectionComposerSurface = undefined;
      }
      if (active.inspectionComposer?.view === view) {
        void active.inspectionComposer.finish({
          reason: "The element composer closed before the prompt was sent.",
          status: "unavailable",
        });
      }
    });
    webContents.on("did-start-loading", () => {
      surface.rendererLoading = true;
    });
    webContents.on("console-message", (...args) => {
      const message = consoleMessageFromArgs(args);
      if (!message?.startsWith(browserInspectionComposerConsolePrefix)) return;
      const payload = parseInspectionComposerMessage(
        message.slice(browserInspectionComposerConsolePrefix.length)
      );
      if (!payload) return;
      if (payload.type === "layout") {
        const restoreComposer =
          surface.rendererLoading && active.inspectionComposer?.view === view;
        surface.rendererLoading = false;
        surface.height = payload.height;
        resolveReady(true);
        const composer = active.inspectionComposer;
        composer?.position();
        if (restoreComposer && composer?.view === view) {
          view.setVisible(true);
          webContents.focus();
          void webContents
            .executeJavaScript(browserInspectionComposerRestoreSource)
            .catch(() => undefined);
        }
        return;
      }
      const composer = active.inspectionComposer;
      if (!composer || composer.view !== view) return;
      if (payload.type === "cancel") {
        void composer.finish({ status: "reselect" });
        return;
      }
      void composer.finish({
        ...composer.selection,
        userMessage: payload.message,
      });
    });
    view.setBackgroundColor?.("#00000000");
    view.setVisible(false);
    active.owner.contentView.addChildView(view.nativeView ?? view);
    void webContents.loadURL(composerUrl).catch(() => {
      resolveReady(false);
      if (active.inspectionComposerSurface === surface) {
        active.inspectionComposerSurface = undefined;
      }
      try {
        active.owner.contentView.removeChildView(view.nativeView ?? view);
      } catch {
        // Owner teardown may remove the child first.
      }
      if (!webContents.isDestroyed()) {
        webContents.close({ waitForBeforeUnload: false });
      }
    });
    return (await ready) ? surface : undefined;
  }

  #disposeInspectionComposerSurface(active: ActiveBrowserSidebar) {
    const surface = active.inspectionComposerSurface;
    active.inspectionComposerSurface = undefined;
    if (!surface) return;
    try {
      active.owner.contentView.removeChildView(surface.view.nativeView ?? surface.view);
    } catch {
      // Owner teardown may remove the child first.
    }
    try {
      surface.view.setVisible(false);
    } catch {
      // Continue to explicit WebContents teardown.
    }
    if (!surface.webContents.isDestroyed()) {
      surface.webContents.close({ waitForBeforeUnload: false });
    }
  }

  #isCurrentNavigation(active: ActiveBrowserSidebar, navigationGeneration: number) {
    return (
      !active.closing &&
      active.navigationGeneration === navigationGeneration &&
      this.#active(active.ownerWindowId, active.sessionId) === active
    );
  }

  #isCurrentNavigationFailure(
    active: ActiveBrowserSidebar,
    validatedUrl: string | undefined
  ) {
    if (
      !active.navigationUrl ||
      active.navigationUrlGeneration !== active.navigationGeneration ||
      !validatedUrl ||
      !isSafeBrowserSidebarUrl(validatedUrl)
    ) {
      return false;
    }
    const failedUrl = normalizeBrowserSidebarUrl(validatedUrl);
    return failedUrl === active.navigationUrl;
  }

  #deleteActive(active: ActiveBrowserSidebar) {
    if (this.#activeByTabId.get(active.tabId) === active) {
      this.#activeByTabId.delete(active.tabId);
    }
    const sessions = this.#activeByOwnerWindowId.get(active.ownerWindowId);
    if (sessions?.get(active.sessionId) === active) {
      sessions.delete(active.sessionId);
      if (sessions.size === 0) {
        this.#activeByOwnerWindowId.delete(active.ownerWindowId);
      }
    }
  }

  #hideOtherSessions(ownerWindowId: string, sessionId: string) {
    const sessions = this.#activeByOwnerWindowId.get(ownerWindowId);
    for (const active of sessions?.values() ?? []) {
      if (active.sessionId === sessionId || active.closing) continue;
      if (!active.webContents.isDestroyed()) {
        this.#pauseNavigation(active);
      }
      active.view.setVisible(false);
    }
  }

  #preemptSession(ownerWindowId: string, sessionId: string) {
    const active = this.#active(ownerWindowId, sessionId);
    if (!active) return;
    active.closing = true;
    void this.#cancelInspection(active);
    this.#invalidateNavigation(active);
    if (!active.webContents.isDestroyed()) {
      active.webContents.stop();
    }
    active.view.setVisible(false);
  }

  #preemptOwner(ownerWindowId: string) {
    for (const active of this.#activeByOwnerWindowId.get(ownerWindowId)?.values() ??
      []) {
      this.#preemptSession(ownerWindowId, active.sessionId);
    }
  }

  #installOwnerLifecycle(ownerWindowId: string, owner: BrowserSidebarOwnerWindowLike) {
    if (this.#releaseOwnerLifecycleByWindowId.has(ownerWindowId)) return;
    const webContents = owner.webContents;
    if (
      !webContents ||
      typeof webContents.on !== "function" ||
      typeof webContents.removeListener !== "function"
    ) {
      return;
    }

    const resetOwner = () => {
      void this.disposeOwner(ownerWindowId).catch(() => undefined);
    };
    const onDidStartNavigation = (...args: unknown[]) => {
      const isInPlace = args[2];
      const isMainFrame = args[3];
      if (isInPlace === true || isMainFrame === false) return;
      resetOwner();
    };
    const onRenderProcessGone = () => resetOwner();
    webContents.on("did-start-navigation", onDidStartNavigation);
    webContents.on("render-process-gone", onRenderProcessGone);
    this.#releaseOwnerLifecycleByWindowId.set(ownerWindowId, () => {
      webContents.removeListener("did-start-navigation", onDidStartNavigation);
      webContents.removeListener("render-process-gone", onRenderProcessGone);
    });
  }

  #releaseOwnerLifecycle(ownerWindowId: string) {
    const release = this.#releaseOwnerLifecycleByWindowId.get(ownerWindowId);
    if (!release) return;
    this.#releaseOwnerLifecycleByWindowId.delete(ownerWindowId);
    release();
  }

  #requireAvailable() {
    if (this.#disposed) {
      throw new Error("Browser sidebar service is disposed.");
    }
  }

  #enqueueOwnerOperation<T>(
    ownerWindowId: string,
    operation: () => Promise<T>
  ): Promise<T> {
    const previous =
      this.#operationTailByOwnerWindowId.get(ownerWindowId) ?? Promise.resolve();
    const result = previous.catch(() => undefined).then(operation);
    const tail = result.then(
      () => undefined,
      () => undefined
    );
    this.#operationTailByOwnerWindowId.set(ownerWindowId, tail);
    void tail.finally(() => {
      if (this.#operationTailByOwnerWindowId.get(ownerWindowId) === tail) {
        this.#operationTailByOwnerWindowId.delete(ownerWindowId);
      }
    });
    return result;
  }
}

async function withWallTimeout<T>(
  operation: Promise<T>,
  timeoutMs: number,
  message: string
): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      operation,
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error(message)), timeoutMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function asError(error: unknown) {
  return error instanceof Error ? error : new Error(String(error));
}

type InspectionComposerMessage =
  | { height: number; type: "layout" }
  | { type: "cancel" }
  | { message: string; type: "submit" };

function consoleMessageFromArgs(args: unknown[]) {
  for (const argument of args) {
    if (typeof argument === "string") return argument;
    if (
      argument &&
      typeof argument === "object" &&
      "message" in argument &&
      typeof argument.message === "string"
    ) {
      return argument.message;
    }
  }
  return undefined;
}

function nextMainTurn() {
  return new Promise<void>((resolve) => setImmediate(resolve));
}

const browserInspectionComposerActivateSource =
  "globalThis.dispatchEvent(new CustomEvent('comma-browser-inspection-composer-activate', { detail: { resetDraft: true } }));";

const browserInspectionComposerRestoreSource =
  "globalThis.dispatchEvent(new CustomEvent('comma-browser-inspection-composer-activate', { detail: { resetDraft: false } }));";

function parseInspectionComposerMessage(
  value: string
): InspectionComposerMessage | undefined {
  let payload: unknown;
  try {
    payload = JSON.parse(value);
  } catch {
    return undefined;
  }
  if (!payload || typeof payload !== "object" || !("type" in payload)) {
    return undefined;
  }
  if (payload.type === "cancel") return { type: "cancel" };
  if (
    payload.type === "layout" &&
    "height" in payload &&
    typeof payload.height === "number" &&
    Number.isFinite(payload.height)
  ) {
    return {
      height: Math.min(240, Math.max(56, Math.ceil(payload.height))),
      type: "layout",
    };
  }
  if (
    payload.type === "submit" &&
    "message" in payload &&
    typeof payload.message === "string"
  ) {
    const message = payload.message.trim();
    if (message.length > 0 && message.length <= 4_000) {
      return { message, type: "submit" };
    }
  }
  return undefined;
}

export function installBrowserSidebarSecurity(
  webContents: BrowserSidebarWebContentsLike,
  {
    now = Date.now,
    sitePermissions,
  }: {
    now?: (() => number) | undefined;
    sitePermissions?: BrowserSitePermissions | undefined;
  } = {}
) {
  const preventUnsafeNavigation = (event: NavigationEvent) => {
    if (!isSafeBrowserSidebarUrl(event.url)) {
      event.preventDefault();
    }
  };

  // A sign-in flow hands the account provider a popup and waits on the
  // `WindowProxy` it gets back: only a real child window carries `opener`,
  // `postMessage`, and `close` between the two pages. Denying the request
  // hands the page `null` instead, which every provider reports as a blocked
  // popup, and `target="_blank"` becomes a click that does nothing at all.
  //
  // What denial was really buying was the popup blocker Electron does not
  // ship: without one, a page opens windows on load, unprompted. Spend a
  // user gesture per window instead, the way Chromium does.
  let userActivatedAt: number | undefined;
  webContents.on("before-input-event", (_event, input) => {
    if (isBrowserSidebarKeyboardActivation(input)) {
      userActivatedAt = now();
    }
  });
  webContents.on("before-mouse-event", (_event, input) => {
    if (input.type === "mouseDown") {
      userActivatedAt = now();
    }
  });
  webContents.setWindowOpenHandler(({ url }) => {
    if (
      !isSafeBrowserSidebarUrl(url) ||
      userActivatedAt === undefined ||
      now() - userActivatedAt > BROWSER_SIDEBAR_USER_ACTIVATION_TIMEOUT_MS
    ) {
      return { action: "deny" };
    }
    userActivatedAt = undefined;
    return {
      action: "allow",
      overrideBrowserWindowOptions: {
        webPreferences: BROWSER_SIDEBAR_WEB_PREFERENCES,
      },
    };
  });
  // The popup carries the sign-in through to a redirect the opener reads, so
  // it holds the same page privileges and needs the same guards. Electron ties
  // its lifetime to this WebContents, so closing the tab closes the popup.
  webContents.on("did-create-window", (window) => {
    installBrowserSidebarSecurity(window.webContents, { now, sitePermissions });
  });
  webContents.on("will-frame-navigate", preventUnsafeNavigation);
  webContents.on("will-navigate", preventUnsafeNavigation);
  webContents.on("will-redirect", preventUnsafeNavigation);
  if (sitePermissions) {
    sitePermissions.install(webContents.session);
    return;
  }
  webContents.session.setPermissionCheckHandler(() => false);
  webContents.session.setPermissionRequestHandler(
    (_webContents, _permission, callback) => {
      callback(false);
    }
  );
}

function isBrowserSidebarKeyboardActivation(input: BrowserSidebarKeyboardInputLike) {
  if (
    input.type !== "keyDown" ||
    typeof input.key !== "string" ||
    input.key === "Escape"
  ) {
    return false;
  }

  // Modifier combinations can be consumed by browser and app shortcuts. Treat
  // them conservatively instead of granting third-party page code a popup
  // budget from an input it may never receive.
  return !input.alt && !input.control && !input.meta;
}

/**
 * The user agent every page in this app presents to a remote origin.
 *
 * Identity providers read `Electron/<version>` as an app-embedded webview and
 * answer with their restricted sign-in flow — Google downgrades OAuth to
 * `flowName=GeneralOAuthLite`. The engine rendering the browser sidebar is the
 * Chrome the rest of the string already names, so drop the token that is not.
 *
 * Applied through `app.userAgentFallback`, before any WebContents exists,
 * because Chromium builds the sign-in popup itself: it stamps the agent at
 * creation, ahead of any hook that could correct it, and the popup's first
 * request is the one the provider judges.
 */
export function browserFacingUserAgent(userAgent: string) {
  return userAgent.replace(/ Electron\/\S+/u, "");
}

function normalizeBrowserSidebarUrl(value: string) {
  const url = new URL(value);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("Browser sidebar URLs must use http or https.");
  }
  return url.toString();
}

function isSafeBrowserSidebarUrl(value: string) {
  try {
    const protocol = new URL(value).protocol;
    return protocol === "http:" || protocol === "https:";
  } catch {
    return false;
  }
}

function currentSafeUrl(webContents: BrowserSidebarWebContentsLike, fallback: string) {
  const current = webContents.getURL();
  return isSafeBrowserSidebarUrl(current) ? current : fallback;
}

async function fetchFavicon(
  session: BrowserSidebarSessionLike,
  url: string,
  signal: AbortSignal
) {
  const response = await session.fetch(url, {
    signal: AbortSignal.any([
      signal,
      AbortSignal.timeout(BROWSER_SIDEBAR_FAVICON_FETCH_TIMEOUT_MS),
    ]),
  });
  const type = response.headers
    .get("content-type")
    ?.split(";")[0]
    ?.trim()
    .toLowerCase();
  if (
    !response.ok ||
    !response.body ||
    !type?.startsWith("image/") ||
    Number(response.headers.get("content-length")) > maxBrowserSidebarFaviconBytes
  ) {
    await response.body?.cancel();
    return undefined;
  }
  const chunks: Uint8Array[] = [];
  let size = 0;
  for await (const chunk of response.body) {
    size += chunk.byteLength;
    if (size > maxBrowserSidebarFaviconBytes) return undefined;
    chunks.push(chunk);
  }
  if (size === 0) return undefined;
  return `data:${type};base64,${Buffer.concat(chunks).toString("base64")}`;
}

function closeWebContents(webContents: BrowserSidebarWebContentsLike) {
  if (!webContents.isDestroyed()) {
    webContents.close({ waitForBeforeUnload: false });
  }
}

function createDestructionSignal() {
  let resolve!: () => void;
  const promise = new Promise<void>((promiseResolve) => {
    resolve = promiseResolve;
  });
  return { promise, resolve };
}

async function waitForDestructionConfirmation(active: ActiveBrowserSidebar) {
  let confirmationTimeout: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      active.destructionObserved,
      new Promise<void>((resolve) => {
        confirmationTimeout = setTimeout(
          resolve,
          BROWSER_SIDEBAR_CLOSE_CONFIRMATION_TIMEOUT_MS
        );
      }),
    ]);
  } finally {
    if (confirmationTimeout !== undefined) {
      clearTimeout(confirmationTimeout);
    }
  }
}

function browserSidebarViewId(ownerWindowId: string, sessionId: string) {
  return `view_browser_sidebar_${ownerWindowId}_${encodeURIComponent(sessionId)}`;
}

function isExpectedNavigationCancellation(error: unknown) {
  if (typeof error === "object" && error !== null) {
    const cancellation = error as { code?: unknown; errno?: unknown };
    if (cancellation.code === "ERR_ABORTED" || cancellation.errno === -3) {
      return true;
    }
  }
  return error instanceof Error && /ERR_ABORTED|\(-3\)/u.test(error.message);
}

function availableInactiveState(sessionId?: string): BrowserSidebarState {
  return {
    active: false,
    available: true,
    ...(sessionId ? { sessionId } : {}),
  };
}

function capacityBlockedState(sessionId: string): BrowserSidebarState {
  return {
    active: false,
    available: true,
    reason: "Waiting for an older browser sidebar session to finish closing.",
    reasonCode: "capacity",
    sessionId,
  };
}
