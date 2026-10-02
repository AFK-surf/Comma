import {
  defaultAppPreferences,
  defaultCommaClientSettings,
  type AppPreferences,
  type AppPreferencesPatch,
  type OnboardingWindowState,
} from "@comma/native-bridge";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";
import { describe, expect, it, vi } from "vitest";
import {
  MainWindowOnboardingHold,
  OnboardingWindowPresenter,
  onboardingHoldsMainWindow,
  onboardingWindowFor,
  type OnboardingBrowserWindowLike,
  type WindowBounds,
} from "../onboarding-window";

// The laptop has its Dock along the bottom; the monitor has it on the left.
const laptop = {
  bounds: { height: 1117, width: 1728, x: 0, y: 0 },
  workArea: { height: 1010, width: 1728, x: 0, y: 33 },
};
const monitor = {
  bounds: { height: 1440, width: 2560, x: 1728, y: -200 },
  workArea: { height: 1415, width: 2480, x: 1808, y: -175 },
};
// Each display below its menu bar, the Dock included.
const laptopSheet = { height: 1084, width: 1728, x: 0, y: 33 };
const monitorSheet = { height: 1415, width: 2560, x: 1728, y: -175 };

describe("onboardingWindowFor", () => {
  it("presents the window only on macOS, whose app activation lets it step down for the browser", () => {
    const harness = createHarness();

    expect(onboardingWindowFor("macos", harness.presenter)).toBe(harness.presenter);
    for (const os of ["linux", "windows"]) {
      // The main window then covers its product with the overlay.
      expect(
        onboardingWindowFor(os, harness.presenter).presentWindow({} as never)
      ).toEqual({ presented: false });
    }
    expect(harness.createWindow).not.toHaveBeenCalled();
  });
});

function createHold(onboardingOpen = false) {
  const state = { onboardingOpen };
  const bringOnboardingForward = vi.fn();
  const hideMainWindow = vi.fn();
  const showMainWindow = vi.fn();
  const hold = new MainWindowOnboardingHold({
    bringOnboardingForward,
    hideMainWindow,
    logger: { warn: vi.fn() },
    onboardingOpen: () => state.onboardingOpen,
    showMainWindow,
    graceMs: 5_000,
    timeoutMs: 20_000,
  });
  return { bringOnboardingForward, hideMainWindow, hold, showMainWindow, state };
}

describe("MainWindowOnboardingHold", () => {
  it("lets the launch request wait for the onboarding, then answers a later one with the main window", () => {
    vi.useFakeTimers();
    try {
      const { bringOnboardingForward, hold, showMainWindow } = createHold();
      hold.begin();

      // macOS asks for the app itself as it launches with no window on
      // screen: that request waits for the onboarding window.
      expect(hold.openRequested()).toBe(true);
      expect(showMainWindow).not.toHaveBeenCalled();
      expect(hold.held).toBe(true);

      // The renderer never presented the onboarding (e.g. it is still
      // recovering its connection): a later Dock click must not be swallowed.
      vi.advanceTimersByTime(5_000);
      expect(hold.openRequested()).toBe(true);
      expect(showMainWindow).toHaveBeenCalledTimes(1);
      expect(bringOnboardingForward).not.toHaveBeenCalled();
      expect(hold.held).toBe(false);
      expect(hold.openRequested()).toBe(false);
      vi.advanceTimersByTime(20_000);
      expect(showMainWindow).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("brings an open onboarding forward and keeps the main window hidden until it closes", () => {
    vi.useFakeTimers();
    try {
      const { bringOnboardingForward, hold, showMainWindow, state } = createHold();
      hold.begin();
      state.onboardingOpen = true;

      expect(hold.openRequested()).toBe(true);
      expect(bringOnboardingForward).toHaveBeenCalledTimes(1);
      vi.advanceTimersByTime(20_000);
      expect(showMainWindow).not.toHaveBeenCalled();

      hold.release();
      hold.release();
      expect(showMainWindow).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("steps the main window aside when the onboarding opens over it, until it closes", () => {
    vi.useFakeTimers();
    try {
      // Signed in just now: the main window is on screen, no hold began.
      const { bringOnboardingForward, hideMainWindow, hold, showMainWindow, state } =
        createHold();
      state.onboardingOpen = true;
      hold.onboardingOpened();
      expect(hideMainWindow).toHaveBeenCalledTimes(1);
      expect(hold.held).toBe(true);

      // Asking for Comma brings the onboarding forward, however late.
      vi.advanceTimersByTime(20_000);
      expect(hold.openRequested()).toBe(true);
      expect(bringOnboardingForward).toHaveBeenCalledTimes(1);
      expect(showMainWindow).not.toHaveBeenCalled();

      // Closed by hand or after Start chatting: the main window comes back.
      state.onboardingOpen = false;
      hold.release();
      expect(showMainWindow).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("leaves a main window held since launch as it is when the onboarding opens", () => {
    const { hideMainWindow, hold } = createHold();
    hold.begin();
    hold.onboardingOpened();
    expect(hideMainWindow).not.toHaveBeenCalled();
    expect(hold.held).toBe(true);
    hold.release();
  });

  it("shows the main window when no onboarding window opened before the timeout", () => {
    vi.useFakeTimers();
    try {
      const { hold, showMainWindow } = createHold();
      hold.begin();
      vi.advanceTimersByTime(19_999);
      expect(showMainWindow).not.toHaveBeenCalled();
      vi.advanceTimersByTime(1);
      expect(showMainWindow).toHaveBeenCalledTimes(1);
      expect(hold.held).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("onboardingHoldsMainWindow", () => {
  it("puts the onboarding before the product for a signed-in account that has not finished it on macOS", () => {
    const signedInAsA = { phase: "signed_in", principal: { userId: "usr_a" } } as const;
    const holds = (
      overrides: Partial<Parameters<typeof onboardingHoldsMainWindow>[0]>
    ) =>
      onboardingHoldsMainWindow({
        completedUserIds: [],
        operatingSystem: "macos",
        session: signedInAsA as never,
        ...overrides,
      });
    expect(holds({})).toBe(true);
    // Finished on this Mac: the product comes up at once.
    expect(holds({ completedUserIds: ["usr_a"] })).toBe(false);
    // Another account finished it: this one still meets it.
    expect(holds({ completedUserIds: ["usr_b"] })).toBe(true);
    // Signed out: sign-in needs the main window.
    expect(holds({ session: { phase: "signed_out", principal: null } as never })).toBe(
      false
    );
    // No onboarding window outside macOS: the overlay runs over the product.
    expect(holds({ operatingSystem: "windows" })).toBe(false);
  });
});

describe("OnboardingWindowPresenter", () => {
  it("covers the display that holds the main window below its menu bar and keeps one window", async () => {
    const harness = createHarness({
      mainBounds: { height: 900, width: 1400, x: 2000, y: 0 },
    });

    await expect(harness.presenter.presentWindow()).resolves.toEqual({
      presented: true,
    });
    const window = harness.window();
    expect(window.getBounds()).toEqual(monitorSheet);

    window.paint();
    window.focused = false;
    await expect(harness.presenter.presentWindow()).resolves.toEqual({
      presented: true,
    });

    expect(harness.createWindow).toHaveBeenCalledOnce();
    expect(window.moveTop).toHaveBeenCalledOnce();
    expect(window.focused).toBe(true);
  });

  it("moves back above the main window when Comma is activated onto it", async () => {
    const harness = createHarness();
    await harness.presenter.presentWindow();
    const window = harness.window();

    // Still loading: it comes to the front on its own once painted.
    harness.presenter.mainWindowFocused();
    expect(window.moveTop).not.toHaveBeenCalled();

    window.paint();
    window.focused = false;
    harness.presenter.mainWindowFocused();

    expect(window.moveTop).toHaveBeenCalledOnce();
    expect(window.focused).toBe(true);
  });

  it("records a hand-closed onboarding as completed and gives the main window focus", async () => {
    const harness = createHarness({ completedUserIds: ["usr_other"] });
    await harness.presenter.presentWindow();
    harness.window().paint();

    harness.window().closeByUser();

    await vi.waitFor(() =>
      expect(harness.completedUserIds()).toEqual(["usr_other", "usr_1"])
    );
    expect(harness.focusMainWindow).toHaveBeenCalledOnce();
    // Closing it by hand is no hand-off to Home's composer.
    expect(harness.onHandoff).not.toHaveBeenCalled();
    await harness.presenter.presentWindow();
    expect(harness.createWindow).toHaveBeenCalledTimes(2);
  });

  it("records completion for the user it was presented to when its renderer closes it", async () => {
    const harness = createHarness({ completedUserIds: ["usr_other"] });
    await harness.presenter.presentWindow();
    const window = harness.window();
    window.paint();

    harness.presenter.closeWindow({});
    // The request came from the window's own renderer; its reply goes first.
    expect(window.isDestroyed()).toBe(false);
    await vi.waitFor(() => expect(window.isDestroyed()).toBe(true));

    await vi.waitFor(() =>
      expect(harness.completedUserIds()).toEqual(["usr_other", "usr_1"])
    );
    expect(harness.updatePreferences).toHaveBeenCalledOnce();
    expect(harness.focusMainWindow).toHaveBeenCalledOnce();
  });

  it("hands Start chatting to the main window once it has closed and given the focus back", async () => {
    const harness = createHarness();
    await harness.presenter.presentWindow();
    const window = harness.window();
    window.paint();
    // An app the user is still authorizing in the browser.
    const pluginAuthorization = {
      authorizationState: "state_1",
      expiresAt: Date.now() + 60_000,
      pluginId: "linear",
      workspaceId: "wsp_1",
    };

    harness.presenter.closeWindow({ pluginAuthorization });
    expect(harness.onHandoff).not.toHaveBeenCalled();
    await vi.waitFor(() =>
      expect(harness.onHandoff).toHaveBeenCalledExactlyOnceWith({ pluginAuthorization })
    );

    expect(window.isDestroyed()).toBe(true);
    expect(harness.published.at(-1)).toEqual({ open: false });
    expect(harness.focusMainWindow.mock.invocationCallOrder[0]).toBeLessThan(
      harness.onHandoff.mock.invocationCallOrder[0] ?? 0
    );
  });

  it("stays only while its user is signed in", async () => {
    const harness = createHarness();
    await harness.presenter.presentWindow();
    const window = harness.window();
    window.paint();

    harness.presenter.sessionChanged(signedIn("usr_1", 2));
    expect(window.isDestroyed()).toBe(false);

    harness.presenter.sessionChanged(signedIn("usr_2", 3));
    expect(window.isDestroyed()).toBe(true);
    expect(harness.updatePreferences).not.toHaveBeenCalled();
  });

  it("leaves the focus where it is when it closes behind another app", async () => {
    const harness = createHarness();
    await harness.presenter.presentWindow();
    const window = harness.window();
    window.paint();
    // The user is approving a plugin in the browser.
    window.focused = false;

    harness.presenter.sessionChanged(signedIn("usr_2", 3));

    expect(window.isDestroyed()).toBe(true);
    expect(harness.focusMainWindow).not.toHaveBeenCalled();
  });

  it("follows the main window's display when the displays change", async () => {
    const harness = createHarness();
    await harness.presenter.presentWindow();
    const window = harness.window();
    expect(window.getBounds()).toEqual(laptopSheet);

    harness.mainBounds = { height: 900, width: 1400, x: 2400, y: 100 };
    harness.displaysChanged();
    expect(window.getBounds()).toEqual(monitorSheet);

    // The user moves the monitor's Dock to the bottom: the sheet still covers it.
    harness.displays.monitor = {
      ...monitor,
      workArea: { height: 1340, width: 2560, x: 1728, y: -175 },
    };
    harness.displaysChanged();
    expect(window.getBounds()).toEqual(monitorSheet);
  });

  it("sits above the Dock only while Comma is the active app", async () => {
    const harness = createHarness();
    await harness.presenter.presentWindow();
    const window = harness.window();
    window.paint();
    expect(window.level).toBe("main-menu");

    // The user goes to the browser to authorize a plugin: it comes in front.
    harness.setAppActive(false);
    expect(window.level).toBe("normal");

    harness.setAppActive(true);
    expect(window.level).toBe("main-menu");
    expect(window.setAlwaysOnTop).toHaveBeenCalledTimes(3);

    harness.presenter.closeWindow({});
    await vi.waitFor(() => expect(window.isDestroyed()).toBe(true));
    harness.setAppActive(false);
    expect(window.setAlwaysOnTop).toHaveBeenCalledTimes(3);
  });

  it("presented while another app is active, rises above the Dock once Comma is", async () => {
    const harness = createHarness({ appActive: false });
    await harness.presenter.presentWindow();
    const window = harness.window();
    expect(window.level).toBe("normal");
    expect(window.setAlwaysOnTop).not.toHaveBeenCalled();

    harness.setAppActive(true);

    expect(window.level).toBe("main-menu");
  });

  it("never leaves the sheet over the display once its renderer is gone", async () => {
    const harness = createHarness();
    await harness.presenter.presentWindow();
    const window = harness.window();
    window.paint();

    window.renderProcessGone();

    expect(window.isDestroyed()).toBe(true);
    expect(harness.updatePreferences).not.toHaveBeenCalled();
    expect(harness.warn).toHaveBeenCalledWith(
      expect.stringContaining("renderer exited")
    );
  });

  it("tells the main window it is open from its creation until its presentation ends", async () => {
    const harness = createHarness();
    expect(harness.presenter.window()).toEqual({ open: false });

    await harness.presenter.presentWindow();
    harness.window().paint();
    await harness.presenter.presentWindow();
    expect(harness.presenter.window()).toEqual({ open: true });
    expect(harness.published).toEqual([{ open: true }]);

    harness.window().closeByUser();
    expect(harness.presenter.window()).toEqual({ open: false });
    expect(harness.published).toEqual([{ open: true }, { open: false }]);

    // A window whose renderer never loads is closed again at once.
    harness.failNextLoad();
    await expect(harness.presenter.presentWindow()).rejects.toThrow("load");
    expect(harness.published.slice(2)).toEqual([{ open: true }, { open: false }]);

    // Quitting closes the main window with it: nothing more is published.
    await harness.presenter.presentWindow();
    harness.presenter.dispose();
    expect(harness.published.slice(4)).toEqual([{ open: true }]);
  });

  it("closes without recording or moving focus when Comma quits", async () => {
    const harness = createHarness();
    await harness.presenter.presentWindow();
    const window = harness.window();
    window.paint();

    harness.presenter.dispose();

    expect(window.isDestroyed()).toBe(true);
    expect(harness.updatePreferences).not.toHaveBeenCalled();
    expect(harness.focusMainWindow).not.toHaveBeenCalled();
    await expect(harness.presenter.presentWindow()).rejects.toThrow("quits");
  });
});

function createHarness({
  appActive = true,
  completedUserIds = [],
  mainBounds = { height: 900, width: 1400, x: 100, y: 100 },
}: {
  appActive?: boolean;
  completedUserIds?: string[];
  mainBounds?: WindowBounds;
} = {}) {
  let active = appActive;
  let activationChanged: ((active: boolean) => void) | undefined;
  const windows: FakeWindow[] = [];
  let completed = completedUserIds;
  const readPreferences = (): AppPreferences => ({
    ...defaultAppPreferences,
    clientSettings: {
      ...defaultCommaClientSettings,
      onboardingCompletedUserIds: completed,
    },
  });
  let displaysChanged: (() => void) | undefined;
  let failNextLoad = false;
  const createWindow = vi.fn((bounds: WindowBounds) => {
    const window = new FakeWindow(bounds);
    windows.push(window);
    const fails = failNextLoad;
    failNextLoad = false;
    return {
      load: async () => {
        if (fails) throw new Error("The renderer did not load.");
      },
      window,
    };
  });
  const published: OnboardingWindowState[] = [];
  const focusMainWindow = vi.fn();
  const onHandoff = vi.fn();
  const updatePreferences = vi.fn(async (patch: AppPreferencesPatch) => {
    completed = patch.clientSettings?.onboardingCompletedUserIds ?? completed;
    return readPreferences();
  });
  const warn = vi.fn();
  const harness = {
    completedUserIds: () => completed,
    createWindow,
    displays: { laptop, monitor },
    displaysChanged: () => displaysChanged?.(),
    failNextLoad: () => {
      failNextLoad = true;
    },
    focusMainWindow,
    mainBounds,
    onHandoff,
    presenter: undefined as unknown as OnboardingWindowPresenter,
    published,
    setAppActive: (next: boolean) => {
      active = next;
      activationChanged?.(next);
    },
    updatePreferences,
    warn,
    window: () => {
      const window = windows.at(-1);
      if (!window) throw new Error("No onboarding window was created.");
      return window;
    },
  };
  harness.presenter = new OnboardingWindowPresenter({
    activate: true,
    appActive: () => active,
    admittedUserId: () => "usr_1",
    createWindow,
    displayMatching: (bounds) =>
      bounds.x + bounds.width / 2 >= monitor.bounds.x
        ? harness.displays.monitor
        : harness.displays.laptop,
    focusMainWindow,
    logger: { warn },
    mainWindow: () => ({ getBounds: () => harness.mainBounds }),
    onAppActiveChanged: (listener) => {
      activationChanged = listener;
      return () => {
        activationChanged = undefined;
      };
    },
    onDisplaysChanged: (listener) => {
      displaysChanged = listener;
      return () => {
        displaysChanged = undefined;
      };
    },
    onHandoff,
    onWindowChanged: (state) => published.push(state),
    outputVolume: async () => 0.8,
    preferences: { state: readPreferences, update: updatePreferences },
  });
  return harness;
}

type Listener = (...args: never[]) => void;

/** The parts of a BrowserWindow the presenter drives, with Electron's close order. */
class FakeWindow implements OnboardingBrowserWindowLike {
  focused = false;
  level = "normal";
  readonly moveTop = vi.fn();
  readonly setAlwaysOnTop = vi.fn((flag: boolean, level: string) => {
    this.level = flag ? level : "normal";
  });
  readonly webContents = {
    on: (event: string, listener: Listener) => this.#listen(`web:${event}`, listener),
  };
  #bounds: WindowBounds;
  #destroyed = false;
  readonly #listeners = new Map<string, Listener[]>();
  #visible = false;

  constructor(bounds: WindowBounds) {
    this.#bounds = bounds;
  }

  destroy() {
    if (this.#destroyed) throw new Error("Object has been destroyed");
    this.#destroyed = true;
    this.#emit("closed");
  }

  focus() {
    this.focused = true;
  }

  getBounds() {
    return this.#bounds;
  }

  isDestroyed() {
    return this.#destroyed;
  }

  isFocused() {
    return this.focused;
  }

  isVisible() {
    return this.#visible;
  }

  on(event: string, listener: Listener) {
    this.#listen(event, listener);
  }

  setBounds(bounds: WindowBounds) {
    this.#bounds = bounds;
  }

  /** ready-to-show: the renderer painted and the window is shown, focused. */
  paint() {
    this.#visible = true;
    this.focused = true;
  }

  /** ⌘W: `close`, then `closed`. */
  closeByUser() {
    this.#emit("close");
    this.#destroyed = true;
    this.#emit("closed");
  }

  renderProcessGone() {
    this.#emit("web:render-process-gone");
  }

  #listen(event: string, listener: Listener) {
    this.#listeners.set(event, [...(this.#listeners.get(event) ?? []), listener]);
  }

  #emit(event: string) {
    for (const listener of this.#listeners.get(event) ?? []) listener();
  }
}

function signedIn(userId: string, generation: number) {
  return {
    authority: { authorityInstanceId: "electron-main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    contractVersion: 1,
    generation,
    phase: "signed_in",
    principal: { email: `${userId}@example.com`, userId },
    revision: generation,
    session: {
      audience: "https://api.comma.test",
      expiresAtEpochSeconds: 2_000_000_000,
      sessionId: "11111111-1111-4111-8111-111111111111",
    },
  } satisfies SessionLifecycleSnapshot;
}
