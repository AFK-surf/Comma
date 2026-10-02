import type {
  AppPreferences,
  AppPreferencesPatch,
  OnboardingCloseWindowInput,
  OnboardingHandoff,
  OnboardingOutputVolume,
  OnboardingPresentWindowInput,
  OnboardingPresentWindowResult,
  OnboardingWindowState,
} from "@comma/native-bridge";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";

/** The route the onboarding renderer loads; its window role picks the app. */
export const onboardingWindowRoute = "/onboarding";

/** What the generated `onboarding.*` handlers call. */
export interface OnboardingWindowProvider {
  presentWindow(
    input: OnboardingPresentWindowInput
  ): Promise<OnboardingPresentWindowResult> | OnboardingPresentWindowResult;
  closeWindow(input: OnboardingCloseWindowInput): void;
  outputVolume(input: void): Promise<OnboardingOutputVolume>;
  window(input: void): OnboardingWindowState;
}

/** A runtime without the full-screen window keeps the in-window overlay. */
export const unavailableOnboardingWindow: OnboardingWindowProvider = {
  presentWindow: () => ({ presented: false }),
  closeWindow: () => undefined,
  outputVolume: async () => ({ volume: null }),
  window: () => ({ open: false }),
};

/**
 * The window follows macOS's app activation to step down for the browser and
 * System Settings; Electron reports activation only there. Elsewhere the
 * in-window overlay presents the onboarding.
 */
export function onboardingWindowFor(
  operatingSystem: string,
  presenter: OnboardingWindowProvider
): OnboardingWindowProvider {
  return operatingSystem === "macos" ? presenter : unavailableOnboardingWindow;
}

export interface WindowBounds {
  height: number;
  width: number;
  x: number;
  y: number;
}

/** A display's full bounds and its work area, which leaves out the menu bar and Dock. */
export interface OnboardingDisplay {
  bounds: WindowBounds;
  workArea: WindowBounds;
}

/**
 * The window level of the sheet while Comma is the active app: the menu bar's
 * own level (NSMainMenuWindowLevel, 24), the lowest level Electron names above
 * the Dock (kCGDockWindowLevel, 20). The sheet never overlaps the menu bar, and
 * the higher system surfaces (menu bar extras at 25, menus at 101, Spotlight,
 * notifications, alerts) still draw above it.
 */
export const onboardingSheetLevel = "main-menu";

/**
 * Whether the first-launch onboarding comes before the product: on macOS,
 * where it has a window of its own, for a signed-in account that has not
 * finished it on this Mac. The main window then stays hidden until the
 * onboarding window closes.
 */
export function onboardingHoldsMainWindow({
  completedUserIds,
  operatingSystem,
  session,
}: {
  completedUserIds: readonly string[];
  operatingSystem: string;
  session: Pick<SessionLifecycleSnapshot, "phase" | "principal">;
}) {
  return (
    operatingSystem === "macos" &&
    session.phase === "signed_in" &&
    session.principal !== null &&
    !completedUserIds.includes(session.principal.userId)
  );
}

export interface MainWindowOnboardingHoldOptions {
  /** Brings the open onboarding window back in front. */
  bringOnboardingForward(): void;
  /** Takes the main window off screen, if it is on screen. */
  hideMainWindow(): void;
  logger: { warn(message: string): void };
  onboardingOpen(): boolean;
  showMainWindow(): void;
  timeoutMs: number;
  /**
   * How long a request for Comma waits for the onboarding window to open
   * before it shows the main window instead. macOS itself asks for the app as
   * it launches with no window on screen, which lands in this span.
   */
  graceMs: number;
}

/**
 * Keeps the main window hidden while the onboarding comes before the
 * product, and shows it once the wait is over. It begins at launch for an
 * account already signed in, before the main window shows; or when the
 * onboarding window opens over a main window already on screen (the account
 * signed in just now, or the Debug replay), which then steps aside. Bound:
 * released by the onboarding window closing (closed by hand or after Start
 * chatting), the session leaving its account, the user asking for Comma
 * while no onboarding window has opened `graceMs` after the hold began, or,
 * if none opened at all, `timeoutMs` after it began.
 */
export class MainWindowOnboardingHold {
  readonly #options: MainWindowOnboardingHoldOptions;
  #timer: ReturnType<typeof setTimeout> | undefined;
  #startedAt = 0;

  constructor(options: MainWindowOnboardingHoldOptions) {
    this.#options = options;
  }

  get held() {
    return this.#timer !== undefined;
  }

  begin() {
    if (this.#timer) return;
    this.#startedAt = Date.now();
    this.#timer = setTimeout(() => {
      if (this.#options.onboardingOpen()) return;
      this.#options.logger.warn(
        "no onboarding window opened on first launch; showing the main window"
      );
      this.release();
    }, this.#options.timeoutMs);
  }

  /**
   * The onboarding window opened. Over a main window on screen (no hold
   * began at launch), the hold begins now and the main window steps aside.
   */
  onboardingOpened() {
    if (this.held) return;
    this.begin();
    this.#options.hideMainWindow();
  }

  release() {
    const timer = this.#timer;
    if (!timer) return;
    this.#timer = undefined;
    clearTimeout(timer);
    this.#options.showMainWindow();
  }

  /**
   * The user asked for Comma (the Dock, the shortcut, the status item). An
   * open onboarding comes forward. With none open yet, a request in the first
   * `graceMs` waits for it (macOS asks for the app itself as it launches with
   * no window on screen); a later one ends the wait and the main window
   * shows, so the request never goes unanswered. Returns whether the hold
   * took the request.
   */
  openRequested() {
    if (!this.held) return false;
    if (this.#options.onboardingOpen()) this.#options.bringOnboardingForward();
    else if (Date.now() - this.#startedAt >= this.#options.graceMs) this.release();
    return true;
  }
}

/**
 * The part of `display` the sheet covers: everything below the menu bar,
 * including the Dock wherever it sits (bottom, left, or right).
 */
export function onboardingSheetBounds({ bounds, workArea }: OnboardingDisplay) {
  return {
    height: bounds.y + bounds.height - workArea.y,
    width: bounds.width,
    x: bounds.x,
    y: workArea.y,
  };
}

export interface OnboardingBrowserWindowLike {
  destroy(): void;
  focus(): void;
  getBounds(): WindowBounds;
  isDestroyed(): boolean;
  isFocused(): boolean;
  isVisible(): boolean;
  moveTop(): void;
  on(event: "close" | "closed" | "unresponsive", listener: () => void): unknown;
  setAlwaysOnTop(flag: boolean, level: typeof onboardingSheetLevel): void;
  setBounds(bounds: WindowBounds): void;
  webContents: {
    on(event: "render-process-gone", listener: () => void): unknown;
    on(
      event: "did-fail-load",
      listener: (
        event: unknown,
        errorCode: number,
        errorDescription: string,
        validatedURL: string,
        isMainFrame: boolean
      ) => void
    ): unknown;
  };
}

export interface OnboardingWindowPresenterOptions {
  /** Whether presenting may take focus; an automated background launch may not. */
  activate: boolean;
  /** Whether Comma is the active app now. */
  appActive(): boolean;
  /** The user of the session the calling renderer was admitted with. */
  admittedUserId(): string;
  /**
   * Creates the hidden window at `bounds`. `load` registers it and loads its
   * renderer, which shows the window once it has painted.
   */
  createWindow(bounds: WindowBounds): {
    load(): Promise<void>;
    window: OnboardingBrowserWindowLike;
  };
  /** The display that most overlaps `bounds`. */
  displayMatching(bounds: WindowBounds): OnboardingDisplay;
  focusMainWindow(): void;
  logger: { warn(message: string): void };
  /**
   * Tells the main window that the onboarding ended with "Start chatting",
   * once its window has closed and the main window has the focus back.
   */
  onHandoff(handoff: OnboardingHandoff): void;
  /** The app's main window while it exists. */
  mainWindow(): { getBounds(): WindowBounds } | undefined;
  /**
   * Calls `listener` each time Comma becomes or stops being the active app;
   * returns the unsubscribe.
   */
  onAppActiveChanged(listener: (active: boolean) => void): () => void;
  /** Calls `listener` when a display is added, removed, or changes; returns the unsubscribe. */
  onDisplaysChanged(listener: () => void): () => void;
  /** Publishes `window()` to the main window each time the window opens or closes. */
  onWindowChanged(state: OnboardingWindowState): void;
  /** The output volume, from 0 to 1; null when it cannot be read. */
  outputVolume(): Promise<number | null>;
  preferences: {
    state(): AppPreferences | Promise<AppPreferences>;
    update(patch: AppPreferencesPatch): AppPreferences | Promise<AppPreferences>;
  };
}

/**
 * Why a presentation ended. Main itself only ever destroys the window, so a
 * `close` event on a presentation that has not ended is the user closing it.
 */
type Ending = "disposed" | "failed" | "finished" | "session" | "user";

interface Presentation {
  ending: Ending | undefined;
  /** Whether it held focus as it ended: the main window then takes it over. */
  focused: boolean;
  /** Its renderer finished with "Start chatting": Home takes the user on. */
  handoff: OnboardingHandoff | undefined;
  /** It is above the Dock, at `onboardingSheetLevel`, rather than at the normal level. */
  raised: boolean;
  stopWatching(): void;
  userId: string;
  window: OnboardingBrowserWindowLike;
}

/**
 * Owns the one full-screen onboarding window: a transparent sheet over the
 * display that holds the main window, from below the menu bar down to the
 * display's bottom edge, so it covers the Dock. While Comma is the active app
 * the sheet sits above the Dock (`onboardingSheetLevel`). When Comma resigns
 * active it drops back to the normal window level, so the browser (plugin
 * authorization), System Settings, and the Computer Use helper (permission
 * grants) come in front of it. Activating Comma raises it again; activation
 * lands on the main window, and the open onboarding then moves back above it
 * and takes focus.
 *
 * It lives only while its user stays signed in. Its renderer asks to close
 * after "Start chatting" and the exit reveal; a user who closes the window by
 * hand has closed the onboarding too. Either way Main records the completion
 * for the user it bound the window to, and the main window takes the focus
 * back; after "Start chatting" the main window then hears of the hand-off, so
 * Home focuses its composer and a plugin authorization still open is verified
 * there.
 *
 * The window is open from its creation until its presentation ends; the main
 * window's product stands down for that long (`window()`).
 */
export class OnboardingWindowPresenter implements OnboardingWindowProvider {
  readonly #options: OnboardingWindowPresenterOptions;
  #disposed = false;
  #presentation: Presentation | undefined;
  // Read as the window is created, so its sound need not wait for it.
  #outputVolume: Promise<number | null> | undefined;

  constructor(options: OnboardingWindowPresenterOptions) {
    this.#options = options;
  }

  window(): OnboardingWindowState {
    return { open: this.#presentation !== undefined };
  }

  async outputVolume(): Promise<OnboardingOutputVolume> {
    return { volume: await (this.#outputVolume ??= this.#options.outputVolume()) };
  }

  async presentWindow(): Promise<OnboardingPresentWindowResult> {
    // Read inside the calling renderer's admission, before any await.
    const userId = this.#options.admittedUserId();
    if (this.#disposed) {
      throw new Error("The onboarding window is unavailable while Comma quits.");
    }
    const open = this.#presentation;
    if (open) {
      this.#bringToFront(open);
      return { presented: true };
    }
    const main = this.#options.mainWindow();
    if (!main) throw new Error("The onboarding window needs the main window.");

    this.#outputVolume = this.#options.outputVolume();
    const { load, window } = this.#options.createWindow(
      onboardingSheetBounds(this.#options.displayMatching(main.getBounds()))
    );
    const presentation: Presentation = {
      ending: undefined,
      focused: false,
      handoff: undefined,
      raised: false,
      stopWatching: () => undefined,
      userId,
      window,
    };
    this.#setPresentation(presentation);
    this.#watch(presentation);
    this.#raise(presentation, this.#options.appActive());
    try {
      await load();
    } catch (error) {
      this.#end(presentation, "failed", errorMessage(error));
      throw error;
    }
    return { presented: true };
  }

  closeWindow({ pluginAuthorization }: OnboardingCloseWindowInput) {
    const presentation = this.#presentation;
    if (!presentation) return;
    presentation.handoff = pluginAuthorization ? { pluginAuthorization } : {};
    this.#end(presentation, "finished");
    this.#completed(presentation, "finished");
  }

  /** Main's session changed: the window stays only for its signed-in user. */
  sessionChanged(snapshot: SessionLifecycleSnapshot) {
    const presentation = this.#presentation;
    if (
      !presentation ||
      (snapshot.phase === "signed_in" &&
        snapshot.principal.userId === presentation.userId)
    ) {
      return;
    }
    this.#end(presentation, "session");
  }

  /** Comma was activated onto its main window: the onboarding goes back above it. */
  mainWindowFocused() {
    const presentation = this.#presentation;
    if (presentation) this.#bringToFront(presentation);
  }

  /** Comma is quitting: close without recording completion or moving focus. */
  dispose() {
    this.#disposed = true;
    const presentation = this.#presentation;
    if (presentation) this.#end(presentation, "disposed");
  }

  #watch(presentation: Presentation) {
    const { window } = presentation;
    window.on("close", () => this.#closedByUser(presentation));
    window.on("closed", () => this.#closed(presentation));
    // A dead or hung renderer must not leave a sheet over the whole display.
    window.on("unresponsive", () =>
      this.#end(presentation, "failed", "the renderer became unresponsive")
    );
    window.webContents.on("render-process-gone", () =>
      this.#end(presentation, "failed", "the renderer exited")
    );
    window.webContents.on(
      "did-fail-load",
      (_event, code, description, _url, isMainFrame) => {
        if (isMainFrame) {
          this.#end(
            presentation,
            "failed",
            `the renderer failed to load (${code}: ${description})`
          );
        }
      }
    );
    const stopFollowingDisplays = this.#options.onDisplaysChanged(() =>
      this.#fit(presentation)
    );
    // App activation, not the window's own focus: focus moves between Comma's
    // windows (activation lands on the main window first), and only another
    // app coming to the front must see the sheet stand down.
    const stopFollowingActivation = this.#options.onAppActiveChanged((active) =>
      this.#raise(presentation, active)
    );
    presentation.stopWatching = () => {
      stopFollowingDisplays();
      stopFollowingActivation();
    };
  }

  /** Above the Dock while Comma is active; the normal level while another app is. */
  #raise(presentation: Presentation, active: boolean) {
    const { ending, window } = presentation;
    if (ending || window.isDestroyed() || presentation.raised === active) return;
    presentation.raised = active;
    window.setAlwaysOnTop(active, onboardingSheetLevel);
  }

  #bringToFront({ window }: Presentation) {
    // A window still loading shows itself, in front, once its renderer paints.
    if (!window.isVisible()) return;
    window.moveTop();
    if (this.#options.activate) window.focus();
  }

  /**
   * Follows the display that holds the main window, or its own once that is
   * gone, and that display's menu bar and Dock as they change.
   */
  #fit({ ending, window }: Presentation) {
    if (ending) return;
    const current = window.getBounds();
    const target = onboardingSheetBounds(
      this.#options.displayMatching(this.#options.mainWindow()?.getBounds() ?? current)
    );
    if (
      target.x !== current.x ||
      target.y !== current.y ||
      target.width !== current.width ||
      target.height !== current.height
    ) {
      window.setBounds(target);
    }
  }

  #closedByUser(presentation: Presentation) {
    if (!this.#settle(presentation, "user")) return;
    this.#completed(presentation, "closed");
  }

  /** Records completion for the user Main bound the window to. */
  #completed(presentation: Presentation, how: "closed" | "finished") {
    void this.#recordCompletion(presentation.userId).catch((error: unknown) => {
      this.#options.logger.warn(
        `Onboarding completion was not recorded after it ${how}: ${errorMessage(error)}`
      );
    });
  }

  #closed(presentation: Presentation) {
    presentation.stopWatching();
    if (this.#presentation === presentation) this.#setPresentation(undefined);
    // A presentation started meanwhile (a replay) takes the focus instead.
    if (presentation.ending === "disposed" || this.#presentation) return;
    if (presentation.focused) this.#options.focusMainWindow();
    if (presentation.handoff) this.#options.onHandoff(presentation.handoff);
  }

  #end(presentation: Presentation, ending: Ending, reason?: string) {
    if (!this.#settle(presentation, ending)) return;
    if (reason) this.#options.logger.warn(`Onboarding window closed: ${reason}`);
    const { window } = presentation;
    if (ending === "finished") {
      // Asked by this window's own renderer: let the reply reach it first.
      setTimeout(() => {
        if (!window.isDestroyed()) window.destroy();
      }, 0);
      return;
    }
    if (!window.isDestroyed()) window.destroy();
  }

  /** Ends the presentation once; later ends and user closes see it ended. */
  #settle(presentation: Presentation, ending: Ending) {
    if (presentation.ending) return false;
    presentation.ending = ending;
    presentation.focused =
      !presentation.window.isDestroyed() && presentation.window.isFocused();
    if (this.#presentation === presentation) this.#setPresentation(undefined);
    return true;
  }

  /**
   * Publishes each open or close to the main window. Quitting Comma publishes
   * nothing: the main window closes with it.
   */
  #setPresentation(next: Presentation | undefined) {
    const wasOpen = this.#presentation !== undefined;
    this.#presentation = next;
    if (wasOpen !== (next !== undefined) && !this.#disposed) {
      this.#options.onWindowChanged(this.window());
    }
  }

  async #recordCompletion(userId: string) {
    const { clientSettings } = await this.#options.preferences.state();
    // Client settings no renderer has written yet are the defaults: none completed.
    const completedUserIds = clientSettings?.onboardingCompletedUserIds ?? [];
    if (completedUserIds.includes(userId)) return;
    await this.#options.preferences.update({
      clientSettings: { onboardingCompletedUserIds: [...completedUserIds, userId] },
    });
  }
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
