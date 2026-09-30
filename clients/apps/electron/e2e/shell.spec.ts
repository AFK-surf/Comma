import { expect } from "../../../e2e/helpers/native-expect";
import {
  _electron as electron,
  test,
  type ElectronApplication,
  type Locator,
  type Page,
} from "@playwright/test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole as findWindowByNativeRole } from "../src/test-support/electron-native-window";
import { findElectronWindowByRole } from "../src/test-support/electron-window";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const sideChatBackdropFaultFixture = resolve(
  electronAppDir,
  "test/fixtures/side-chat-backdrop-fault.cjs"
);
const sideChatBackdropMissingHealthFixture = resolve(
  electronAppDir,
  "test/fixtures/side-chat-backdrop-missing-health.cjs"
);
const sideChatSlowCloseHostFixture = resolve(
  electronAppDir,
  "test/fixtures/side-chat-slow-close-host.cjs"
);
const sideChatShortcutRejectionHostFixture = resolve(
  electronAppDir,
  "test/fixtures/side-chat-shortcut-rejection-host.cjs"
);
const sideChatShortcutReplayHostFixture = resolve(
  electronAppDir,
  "test/fixtures/side-chat-shortcut-replay-host.cjs"
);
const sideChatShortcutOverlapHostFixture = resolve(
  electronAppDir,
  "test/fixtures/side-chat-shortcut-overlap-host.cjs"
);
const SHELL_E2E_TOKEN = "comma_sess_shell_e2e";
const SHELL_E2E_EMAIL = "shell-e2e@example.com";

interface ElectronTestEnvOptions {
  apiBaseUrl?: string;
  openSideChat?: boolean;
  sideChatHostPath?: string;
  signedIn?: boolean;
}

function electronTestEnv({
  apiBaseUrl,
  openSideChat = false,
  sideChatHostPath,
  signedIn = true,
}: ElectronTestEnvOptions = {}) {
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
  return {
    ...env,
    NODE_ENV: "test",
    // Seed the session through the main-owned SecureStore (the kernel's bearer
    // authority), not renderer localStorage — the renderer never holds the raw
    // token. The hook only seeds when BOTH a base URL and token are present; the
    // Main verifies the seeded credential against this fixture before exposing
    // the signed-in projection to any renderer.
    COMMA_API_BASE_URL: apiBaseUrl ?? shellSessionStub.baseUrl,
    ...(signedIn
      ? {
          COMMA_ELECTRON_STARTUP_SESSION_TOKEN: SHELL_E2E_TOKEN,
          COMMA_ELECTRON_STARTUP_SESSION_EMAIL: SHELL_E2E_EMAIL,
        }
      : {}),
    ...(openSideChat ? { COMMA_ELECTRON_E2E_OPEN_SIDE_CHAT: "1" } : {}),
    ...(sideChatHostPath
      ? { COMMA_ELECTRON_E2E_SIDE_CHAT_HOST_PATH: sideChatHostPath }
      : {}),
  };
}

function electronTestEnvWithHealthySideChat(
  options: Omit<ElectronTestEnvOptions, "openSideChat"> = {}
) {
  return {
    ...electronTestEnv({ ...options, openSideChat: true }),
    // Shell behavior must not depend on whether the local macOS release still
    // exposes Electron's private backdrop primitives. The native addon has its
    // own lifecycle coverage; these tests use the deterministic addon fixture.
    COMMA_SIDE_CHAT_BACKDROP_FAULT: "none",
    COMMA_SIDE_CHAT_BACKDROP_PATH: sideChatBackdropFaultFixture,
  };
}

async function expectWindowDragRegions(page: Page) {
  // The window bar starts at the frame's top edge — no shell margin above it —
  // so a drag at the top of the window grabs the bar itself.
  await expect
    .poll(() =>
      page.locator(".comma-window-bar").evaluate((element) => {
        const shell = document.querySelector<HTMLElement>(".comma-app-shell")!;
        return {
          appRegion: getComputedStyle(element).getPropertyValue("-webkit-app-region"),
          shellAppRegion:
            getComputedStyle(shell).getPropertyValue("-webkit-app-region"),
          startsAtFrameTop:
            Math.abs(
              element.getBoundingClientRect().top - shell.getBoundingClientRect().top
            ) < 0.5,
        };
      })
    )
    .toEqual({ appRegion: "drag", shellAppRegion: "drag", startsAtFrameTop: true });

  // The panel below the bar is no-drag and paints no drag strip of its own.
  await expect
    .poll(() =>
      page.locator(".comma-content").evaluate((element) => ({
        appRegion: getComputedStyle(element).getPropertyValue("-webkit-app-region"),
        dragStrip: getComputedStyle(element, "::before").content,
      }))
    )
    .toEqual({ appRegion: "no-drag", dragStrip: "none" });
  // The window bar is the frame's drag surface. Probe the empty run between
  // the history buttons and the search pill: Chromium subtracts every no-drag
  // box from the drag boxes, so the element under that point must belong to
  // the bar with no no-drag ancestor between it and the bar.
  await expect
    .poll(() =>
      page.getByTestId("comma-window-bar").evaluate((bar) => {
        const history = bar.querySelector<HTMLElement>(".comma-window-history")!;
        const search = bar.querySelector<HTMLElement>(
          '[data-testid="comma-window-bar-search"]'
        )!;
        const barRect = bar.getBoundingClientRect();
        const x =
          (history.getBoundingClientRect().right +
            search.getBoundingClientRect().left) /
          2;
        const topmost = document.elementFromPoint(x, barRect.top + barRect.height / 2);
        let topmostDragSurface =
          topmost instanceof HTMLElement && bar.contains(topmost);
        for (
          let element = topmost as HTMLElement | null;
          topmostDragSurface && element && element !== bar;
          element = element.parentElement
        ) {
          if (
            getComputedStyle(element).getPropertyValue("-webkit-app-region") ===
            "no-drag"
          ) {
            topmostDragSurface = false;
          }
        }
        return {
          appRegion: getComputedStyle(bar).getPropertyValue("-webkit-app-region"),
          topmostDragSurface,
        };
      })
    )
    .toEqual({ appRegion: "drag", topmostDragSurface: true });
  // The Chat Sidebar toggle is a window-bar control: it opts out of the drag
  // surface and nothing paints over it.
  await expect
    .poll(() =>
      page
        .getByRole("button", { exact: true, name: "Toggle chat sidebar" })
        .evaluate((button) => {
          const rect = button.getBoundingClientRect();
          const topmostButton = document
            .elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)
            ?.closest("button");
          return {
            appRegion: getComputedStyle(button).getPropertyValue("-webkit-app-region"),
            inWindowBar: button.closest('[data-testid="comma-window-bar"]') !== null,
            isTopmost: topmostButton === button,
          };
        })
    )
    .toEqual({ appRegion: "no-drag", inWindowBar: true, isTopmost: true });
}

// The rail's last item raises Settings as a modal over whatever route is open;
// it is not a location, and the account menu that used to open it is gone.
async function openAppSettingsFromRail(page: Page) {
  await page.getByRole("button", { exact: true, name: "Settings" }).click();
  await expect(page.getByRole("dialog", { name: "Settings sections" })).toBeVisible();
}

// Toasts render inside this window now, pinned to its bottom-right corner, so a
// persistent recovery card (Side Chat cannot reach the stub host in these
// fixtures) sits over whatever settings row is down there. Clear the stack the
// way a user would before driving controls in that corner — `force` would hide
// a genuine overlap instead of resolving it.
async function dismissVisibleToasts(page: Page) {
  const dismiss = page.getByRole("button", { name: "Dismiss notification" });
  for (let remaining = await dismiss.count(); remaining > 0; remaining -= 1) {
    await dismiss.first().click();
  }
  await expect(dismiss).toHaveCount(0);
}

type CssRgb = { b: number; g: number; r: number };

const readLocatorCssRgb = (locator: Locator, property: "backgroundColor" | "color") =>
  locator.evaluate((element, propertyName) => {
    const color = getComputedStyle(element)[propertyName];
    const canvas = document.createElement("canvas");
    canvas.width = 1;
    canvas.height = 1;
    const context = canvas.getContext("2d");
    if (!context) {
      throw new Error("2d canvas is unavailable.");
    }
    context.fillStyle = color;
    context.fillRect(0, 0, 1, 1);
    const pixel = context.getImageData(0, 0, 1, 1).data;
    const r = pixel[0];
    const g = pixel[1];
    const b = pixel[2];
    if (r == null || g == null || b == null) {
      throw new Error("canvas pixel is unavailable.");
    }
    return { b, g, r };
  }, property);

const isNearNeutralDarkRgb = ({ b, g, r }: CssRgb) => {
  const spread = Math.max(r, g, b) - Math.min(r, g, b);
  return r >= 8 && r <= 40 && g >= 8 && g <= 40 && b >= 8 && b <= 40 && spread <= 16;
};

const isNearNeutralLightRgb = ({ b, g, r }: CssRgb) => {
  const spread = Math.max(r, g, b) - Math.min(r, g, b);
  return r >= 220 && g >= 220 && b >= 220 && spread <= 16;
};

async function readShellContentSurface(page: Page, accessibleName: string) {
  return page.getByRole("region", { name: accessibleName }).evaluate((element) => {
    const shell = element.closest<HTMLElement>(".comma-app-shell");
    if (!shell) throw new Error("App shell is unavailable.");

    const rect = element.getBoundingClientRect();
    const shellRect = shell.getBoundingClientRect();
    const style = getComputedStyle(element);
    return {
      background: style.backgroundColor,
      borderRadius: style.borderRadius,
      borderWidth: style.borderWidth,
      bounds: {
        height: Math.round(rect.height),
        width: Math.round(rect.width),
        x: Math.round(rect.x),
        y: Math.round(rect.y),
      },
      boxShadow: style.boxShadow,
      insets: {
        bottom: Math.round(shellRect.bottom - rect.bottom),
        left: Math.round(rect.left - shellRect.left),
        right: Math.round(shellRect.right - rect.right),
        top: Math.round(rect.top - shellRect.top),
      },
    };
  });
}

async function installHomeReturnFrameProbe(page: Page) {
  await page.evaluate(() => {
    type ElementFrame = {
      display: string;
      height: number;
      opacity: string;
      present: boolean;
      visibility: string;
      width: number;
    };
    type BadHomeFrame = {
      at: number;
      chat: ElementFrame;
      composerInsideChat: boolean;
      composerPresent: boolean;
      greet: ElementFrame;
      hash: string;
      layout: ElementFrame;
      orderedColumns: boolean;
      tasks: ElementFrame;
      tasksSection: ElementFrame;
    };
    type HomeReturnFrameProbe = {
      badFrames: BadHomeFrame[];
      frameSamples: number;
      homeSurfaceSeen: boolean;
      legacyAddedNodes: number;
      observer: MutationObserver;
      rafId: number;
      running: boolean;
      sample: () => void;
    };
    const scope = window as typeof window & {
      commaHomeReturnFrameProbe?: HomeReturnFrameProbe;
    };

    if (scope.commaHomeReturnFrameProbe) {
      throw new Error("Home return frame probe is already installed.");
    }

    const probe: HomeReturnFrameProbe = {
      badFrames: [],
      frameSamples: 0,
      homeSurfaceSeen: false,
      legacyAddedNodes: 0,
      observer: undefined as unknown as MutationObserver,
      rafId: 0,
      running: true,
      sample: () => {},
    };
    // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
    const elementFrame = (element: HTMLElement | null): ElementFrame => {
      if (!element) {
        return {
          display: "missing",
          height: 0,
          opacity: "0",
          present: false,
          visibility: "missing",
          width: 0,
        };
      }

      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return {
        display: style.display,
        height: rect.height,
        opacity: style.opacity,
        present: true,
        visibility: style.visibility,
        width: rect.width,
      };
    };
    // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
    const isVisibleFrame = (frame: ElementFrame) =>
      frame.present &&
      frame.display !== "none" &&
      frame.visibility !== "hidden" &&
      Number(frame.opacity) > 0.001 &&
      frame.width > 0 &&
      frame.height > 0;
    // oxlint-disable-next-line unicorn/consistent-function-scoping -- Playwright serializes this browser callback without outer functions.
    const isLegacyElement = (element: Element) =>
      element.matches(".comma-home-route") ||
      (element.matches("h1") &&
        ["What do you want to do", "你想做什么"].includes(
          element.textContent?.trim() ?? ""
        ));
    const containsLegacySurface = (node: Node) => {
      if (!(node instanceof Element)) return false;
      return (
        isLegacyElement(node) ||
        Array.from(node.querySelectorAll(".comma-home-route, h1")).some(isLegacyElement)
      );
    };

    probe.sample = () => {
      const homeHash = window.location.hash === "" || window.location.hash === "#/";
      const routeOutlet = document.querySelector<HTMLElement>(
        '[data-testid="comma-route-outlet"]'
      );
      if (!probe.homeSurfaceSeen) {
        if (!homeHash || !routeOutlet) return;
        probe.homeSurfaceSeen = true;
      }

      probe.frameSamples += 1;
      const composer = routeOutlet?.querySelector<HTMLElement>(".comma-chat-composer");
      const homeRoute = routeOutlet?.querySelector<HTMLElement>(
        '.comma-chat-route[data-variant="home"]'
      );
      const layout = homeRoute?.querySelector<HTMLElement>(
        ':scope > [data-testid="home-responsive-layout"]'
      );
      const greet = layout?.querySelector<HTMLElement>(
        ':scope > [data-testid="home-greet-rail"]'
      );
      const chat = layout?.querySelector<HTMLElement>(":scope > .comma-home-chat");
      const tasks = layout?.querySelector<HTMLElement>(
        ':scope > [data-testid="home-tasks-rail"]'
      );
      const tasksSection = tasks?.querySelector<HTMLElement>(
        '[data-testid="home-tasks-section"]'
      );
      const layoutFrame = elementFrame(layout ?? null);
      const greetFrame = elementFrame(greet ?? null);
      const chatFrame = elementFrame(chat ?? null);
      const tasksFrame = elementFrame(tasks ?? null);
      const tasksSectionFrame = elementFrame(tasksSection ?? null);
      // The rails' collapse handles are absolutely positioned overlays that
      // ride the column boundaries, not columns of their own, so they are
      // taken out of the grid before it is checked — and only while they
      // really are out of flow, so an overlay that became a column would
      // still be caught here.
      const layoutChildren = Array.from(layout?.children ?? []);
      const overlays = layoutChildren.filter(
        (child) =>
          child.classList.contains("comma-home-rail-handle") &&
          getComputedStyle(child).position === "absolute"
      );
      const columns = layoutChildren.filter((child) => !overlays.includes(child));
      const orderedColumns = Boolean(
        layout &&
        columns.length === 3 &&
        columns[0] === greet &&
        columns[1] === chat &&
        columns[2] === tasks
      );
      const composerInsideChat = Boolean(!composer || chat?.contains(composer));
      const starter = Boolean(
        routeOutlet?.querySelector('[data-placeholder="Do anything"]')
      );
      const history = homeRoute?.querySelector(
        '[data-message-id="msg-assistant-smoke"]'
      );
      const canonicalHome =
        document.querySelectorAll('.comma-chat-route[data-variant="home"]').length ===
          1 &&
        document.querySelectorAll('[data-testid="home-responsive-layout"]').length ===
          1 &&
        orderedColumns &&
        composerInsideChat &&
        Boolean(history) &&
        !starter &&
        isVisibleFrame(layoutFrame) &&
        isVisibleFrame(greetFrame) &&
        isVisibleFrame(chatFrame) &&
        isVisibleFrame(tasksFrame) &&
        isVisibleFrame(tasksSectionFrame);

      if (!canonicalHome && probe.badFrames.length < 20) {
        probe.badFrames.push({
          at: performance.now(),
          chat: chatFrame,
          composerInsideChat,
          composerPresent: Boolean(composer),
          greet: greetFrame,
          hash: window.location.hash,
          layout: layoutFrame,
          orderedColumns,
          tasks: tasksFrame,
          tasksSection: tasksSectionFrame,
        });
      }
    };

    if (
      document.querySelector(".comma-home-route") ||
      Array.from(document.querySelectorAll("h1")).some(isLegacyElement)
    ) {
      probe.legacyAddedNodes += 1;
    }
    probe.observer = new MutationObserver((records) => {
      for (const record of records) {
        if (containsLegacySurface(record.target)) probe.legacyAddedNodes += 1;
        for (const node of record.addedNodes) {
          if (containsLegacySurface(node)) probe.legacyAddedNodes += 1;
        }
      }
    });
    probe.observer.observe(document.body, {
      childList: true,
      subtree: true,
    });

    const sampleFrame = () => {
      probe.sample();
      if (probe.running) {
        probe.rafId = window.requestAnimationFrame(sampleFrame);
      }
    };
    probe.rafId = window.requestAnimationFrame(sampleFrame);
    scope.commaHomeReturnFrameProbe = probe;
  });
}

async function finishHomeReturnFrameProbe(page: Page) {
  return page.evaluate(() => {
    type HomeReturnFrameProbe = {
      badFrames: unknown[];
      frameSamples: number;
      homeSurfaceSeen: boolean;
      legacyAddedNodes: number;
      observer: MutationObserver;
      rafId: number;
      running: boolean;
      sample: () => void;
    };
    const scope = window as typeof window & {
      commaHomeReturnFrameProbe?: HomeReturnFrameProbe;
    };
    const probe = scope.commaHomeReturnFrameProbe;
    if (!probe) throw new Error("Home return frame probe was not installed.");

    probe.running = false;
    window.cancelAnimationFrame(probe.rafId);
    probe.observer.disconnect();
    probe.sample();
    const result = {
      badFrames: probe.badFrames,
      frameSamples: probe.frameSamples,
      homeSurfaceSeen: probe.homeSurfaceSeen,
      legacyAddedNodes: probe.legacyAddedNodes,
    };
    delete scope.commaHomeReturnFrameProbe;
    return result;
  });
}

async function waitForPaintFrames(page: Page, frameCount = 2) {
  await page.evaluate(
    (count) =>
      new Promise<void>((done) => {
        let remaining = count;
        const next = () => {
          remaining -= 1;
          if (remaining <= 0) {
            done();
            return;
          }
          window.requestAnimationFrame(next);
        };
        window.requestAnimationFrame(next);
      }),
    frameCount
  );
}

// Isolate userData so the seeded SecureStore session never touches the
// developer's real profile. On hooks so the tmp dir is removed even if launch
// throws before the test body's try/finally runs.
let userDataDir: string;
let shellSessionStub: Awaited<ReturnType<typeof startSessionProjectionStub>>;

test.beforeAll(async () => {
  shellSessionStub = await startSessionProjectionStub({
    email: SHELL_E2E_EMAIL,
    profile: {
      avatarId: "avt_shell_e2e",
      avatarPngBase64:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
      name: "Shell Avatar",
    },
  });
});

test.afterAll(async () => {
  await shellSessionStub.close();
});

test.beforeEach(async () => {
  userDataDir = await mkdtemp(join(tmpdir(), "comma-shell-e2e-"));
});

test("electron keeps native window backing aligned with Comma appearance while signed out", async () => {
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnv({ signedIn: false }),
  });

  try {
    const appWindow = await findWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();

    await app.evaluate(({ nativeTheme }) => {
      nativeTheme.themeSource = "light";
    });

    await appWindow.evaluate(() =>
      window.commaNative!.appPreferences.update({
        clientSettings: { appearance: { theme: "dark" } },
      })
    );
    await expect(appWindow.locator("html")).toHaveAttribute("data-theme", "Dark mode");
    await expect(async () => {
      const background = await readLocatorCssRgb(
        appWindow.locator(".app-login-shell"),
        "backgroundColor"
      );
      expect(
        isNearNeutralDarkRgb(background),
        `login shell background ${JSON.stringify(background)}`
      ).toBe(true);
    }).toPass();

    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) => {
          const mainWindow = BrowserWindow.getAllWindows().find((candidate) => {
            const url = candidate.webContents.getURL();
            return url.length > 0 && new URL(url).hash === "";
          });
          return mainWindow?.getBackgroundColor().toLowerCase();
        })
      )
      .toBe("#0f0f10");

    await app.evaluate(({ nativeTheme }) => {
      nativeTheme.themeSource = "dark";
    });
    await appWindow.evaluate(() =>
      window.commaNative!.appPreferences.update({
        clientSettings: { appearance: { theme: "light" } },
      })
    );
    await expect(appWindow.locator("html")).toHaveAttribute("data-theme", "Light mode");
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) => {
          const windows = BrowserWindow.getAllWindows();
          const mainWindow = windows.find((candidate) => {
            const url = candidate.webContents.getURL();
            return url.length > 0 && new URL(url).hash === "";
          });
          return mainWindow?.getBackgroundColor().toLowerCase();
        })
      )
      .toBe("#f4f4f5");
  } finally {
    await app.close();
  }
});

test.afterEach(async () => {
  await rm(userDataDir, { recursive: true, force: true });
});

test("electron Appearance lists installed font families and sets the app in one", async () => {
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnv(),
  });

  try {
    const appWindow = await findWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await appWindow.evaluate(() => {
      window.location.hash = "#/settings?category=appearance";
    });
    const fontTrigger = appWindow.getByRole("button", { name: /Select font$/ });
    await expect(fontTrigger).toHaveText("Default");
    await fontTrigger.click();

    // Main grants Comma's renderer the local-fonts check, so Chromium lists the
    // installed families; under a denied check the menu holds Default alone.
    // The first read in a renderer can take seconds.
    const options = appWindow.locator('[data-slot="dropdown-option"]');
    await expect.poll(() => options.count(), { timeout: 30_000 }).toBeGreaterThan(1);
    const family = (await options.nth(1).textContent()) ?? "";
    expect(family).not.toBe("");
    await options.nth(1).click();

    await expect(appWindow.locator("html")).toHaveAttribute(
      "data-comma-font-family",
      family
    );
    await expect
      .poll(() =>
        appWindow.evaluate(async () => {
          const preferences = await window.commaNative!.appPreferences.state.get();
          return preferences.clientSettings?.appearance.fontFamily;
        })
      )
      .toBe(family);
  } finally {
    await app.close();
  }
});

test("electron shell exposes the isolated bridge and native surfaces", async () => {
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnv(),
  });

  try {
    const appWindow = await findElectronWindowByRole(app, "complementary", {
      name: "App sidebar",
    });
    await appWindow.waitForLoadState("domcontentloaded");

    const sideChatRendererWindows = await app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows()
        .map((window) => ({
          url: window.webContents.getURL(),
          visible: window.isVisible(),
        }))
        .filter((window) => window.url.toLowerCase().includes("side-chat"))
    );
    if (process.platform === "darwin") {
      expect(sideChatRendererWindows).toEqual([
        expect.objectContaining({
          url: expect.stringContaining("#/side-chat"),
          visible: false,
        }),
      ]);
    } else {
      expect(sideChatRendererWindows).toEqual([]);
    }

    await readShellContentSurface(appWindow, "Content");
    await expectWindowDragRegions(appWindow);
    if (process.platform === "darwin") {
      // window-options.ts paints the traffic lights at {x: 12, y: 15}: three
      // 12px buttons 8px apart, so a 52x12 rectangle. The window bar's
      // leading slot must hold that rectangle whole, and no control of the
      // bar may reach into it.
      await expect
        .poll(() =>
          appWindow.getByTestId("comma-window-bar").evaluate((bar) => {
            const lights = { bottom: 27, left: 12, right: 64, top: 15 };
            const slot = bar
              .querySelector('[data-testid="comma-native-window-controls"]')!
              .getBoundingClientRect();
            const overlapping = Array.from(bar.querySelectorAll("button"))
              .filter((button) => {
                const rect = button.getBoundingClientRect();
                return (
                  rect.left < lights.right &&
                  rect.right > lights.left &&
                  rect.top < lights.bottom &&
                  rect.bottom > lights.top
                );
              })
              .map((button) => button.getAttribute("aria-label"));
            return {
              overlapping,
              slotHoldsLights:
                slot.left <= lights.left &&
                slot.top <= lights.top &&
                slot.right >= lights.right &&
                slot.bottom >= lights.bottom,
            };
          })
        )
        .toEqual({ overlapping: [], slotHoldsLights: true });
    }
    await expect(
      appWindow.evaluate(() => {
        const rendererWindow = window as Window & {
          commaNative?: unknown;
          require?: unknown;
          process?: unknown;
        };
        return {
          hasCommaNative: typeof rendererWindow.commaNative === "object",
          connectorStatusType:
            typeof rendererWindow.commaNative === "object" &&
            rendererWindow.commaNative !== null &&
            "connector" in rendererWindow.commaNative
              ? typeof (
                  rendererWindow.commaNative as {
                    connector?: { status?: unknown };
                  }
                ).connector?.status
              : "missing",
          requireType: typeof rendererWindow.require,
          processType: typeof rendererWindow.process,
        };
      })
    ).resolves.toEqual({
      hasCommaNative: true,
      connectorStatusType: "function",
      requireType: "undefined",
      processType: "undefined",
    });

    await appWindow.getByRole("link", { name: "Inbox", exact: true }).click();
    const inboxHeader = appWindow
      .getByTestId("inbox-conversation-rail")
      .locator('[data-slot="content-header"]');
    await expect(inboxHeader).toBeVisible();
    await expect
      .poll(() =>
        inboxHeader.evaluate((element) => {
          const title = element.querySelector<HTMLElement>("h1")!;
          const button = element.querySelector<HTMLElement>("button")!;
          return {
            button: getComputedStyle(button).getPropertyValue("-webkit-app-region"),
            dragSurface: getComputedStyle(element, "::before").getPropertyValue(
              "-webkit-app-region"
            ),
            title: getComputedStyle(title).getPropertyValue("-webkit-app-region"),
            windowDragRegion: element.dataset.windowDragRegion,
          };
        })
      )
      .toEqual({
        button: "no-drag",
        dragSurface: "drag",
        title: "drag",
        windowDragRegion: "true",
      });

    for (const hash of ["#/", "#/inbox", "#/tasks", "#/plugins"]) {
      await appWindow.evaluate((nextHash) => {
        window.location.hash = nextHash;
      }, hash);
      await expect
        .poll(() => appWindow.evaluate(() => window.location.hash))
        .toBe(hash);

      const toggle = appWindow.getByRole("button", {
        name: "Toggle chat sidebar",
      });
      await expect(toggle).toBeVisible();
      await expect(toggle).toHaveAttribute("aria-expanded", "false");
      // The toggle is a window-bar control on every route, never a float over
      // the content panel, so no route reserves a strip for it and the panel
      // paints no drag strip of its own.
      await expect
        .poll(() =>
          toggle.evaluate((button) => {
            const rect = button.getBoundingClientRect();
            const topmostButton = document
              .elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)
              ?.closest("button");
            const content = document.querySelector(".comma-content")!;
            return {
              appRegion:
                getComputedStyle(button).getPropertyValue("-webkit-app-region"),
              contentDragStrip: getComputedStyle(content, "::before").content,
              inContent: button.closest(".comma-content") !== null,
              inWindowBar: button.closest('[data-testid="comma-window-bar"]') !== null,
              isTopmost: topmostButton === button,
            };
          })
        )
        .toEqual({
          appRegion: "no-drag",
          contentDragStrip: "none",
          inContent: false,
          inWindowBar: true,
          isTopmost: true,
        });

      await toggle.click();
      await expect(toggle).toHaveAttribute("aria-expanded", "true");
      const sidebar = appWindow.getByRole("complementary", { name: "Chat" });
      await expect(sidebar.getByRole("tab", { name: "New tab" })).toBeVisible();
      await expect(sidebar.getByRole("textbox", { name: "Address" })).toBeVisible();
      await toggle.click();
      await expect(toggle).toHaveAttribute("aria-expanded", "false");
      await expect(sidebar).toHaveCount(0);
    }

    // The rail collapses as a whole from its border toggle (⌘B does the
    // same): its slot closes to the gutter and its controls leave the page,
    // then the next press brings the full rail back.
    const railToggle = appWindow.locator(".comma-sidebar-edge-toggle");
    const railSlot = appWindow.getByTestId("comma-sidebar-slot");
    const homeLink = appWindow.getByRole("link", { exact: true, name: "Home" });
    const railSlotWidth = () =>
      railSlot.evaluate((slot) => Math.round(slot.getBoundingClientRect().width));
    await expect(railToggle).toHaveAttribute("aria-expanded", "true");
    await expect(railSlot).toHaveAttribute("data-collapsed", "false");
    await expect.poll(railSlotWidth).toBe(75);
    await railToggle.click();
    await expect(railToggle).toHaveAttribute("aria-expanded", "false");
    await expect(railSlot).toHaveAttribute("data-collapsed", "true");
    // Collapsed, the slot keeps the window's own gutter; only the rail slides
    // out from under the content panel.
    await expect.poll(railSlotWidth).toBe(8);
    await expect(homeLink).toBeHidden();
    await railToggle.click();
    await expect(railToggle).toHaveAttribute("aria-expanded", "true");
    await expect(railSlot).toHaveAttribute("data-collapsed", "false");
    await expect.poll(railSlotWidth).toBe(75);
    await expect(homeLink).toBeVisible();
    // The toggle-left-sidebar shortcut drives the same collapse.
    const railShortcut = process.platform === "darwin" ? "Meta+B" : "Control+B";
    await appWindow.keyboard.press(railShortcut);
    await expect(railToggle).toHaveAttribute("aria-expanded", "false");
    await expect(railSlot).toHaveAttribute("data-collapsed", "true");
    // Collapsed, the slot keeps the window's own gutter; only the rail slides
    // out from under the content panel.
    await expect.poll(railSlotWidth).toBe(8);
    await appWindow.keyboard.press(railShortcut);
    await expect(railToggle).toHaveAttribute("aria-expanded", "true");
    await expect(railSlot).toHaveAttribute("data-collapsed", "false");
    await expect.poll(railSlotWidth).toBe(75);
  } finally {
    await app.close();
  }
});

test("electron window bar gives the traffic-light slot back in full screen", async () => {
  test.skip(process.platform !== "darwin", "Only macOS paints traffic lights.");
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnv(),
  });

  try {
    const appWindow = await findElectronWindowByRole(app, "complementary", {
      name: "App sidebar",
    });
    await appWindow.waitForLoadState("domcontentloaded");
    const bar = appWindow.getByTestId("comma-window-bar");
    const slot = appWindow.getByTestId("comma-native-window-controls");
    const readBackInset = () =>
      bar.evaluate((element) => {
        const back = element.querySelector('button[aria-label="Back"]')!;
        return Math.round(
          back.getBoundingClientRect().left - element.getBoundingClientRect().left
        );
      });
    const setFullScreen = (fullScreen: boolean) =>
      app.evaluate(({ BrowserWindow }, value) => {
        const mainWindow = BrowserWindow.getAllWindows().find((candidate) => {
          const url = candidate.webContents.getURL();
          return url.length > 0 && new URL(url).hash === "";
        })!;
        mainWindow.setFullScreen(value);
      }, fullScreen);

    await expect(slot).toHaveCount(1);
    const windowedInset = await readBackInset();
    expect(windowedInset).toBeGreaterThan(64);

    // macOS hides the lights in full screen, so history takes their place at
    // the trailing flank's inset; leaving restores the slot.
    await setFullScreen(true);
    await expect(slot).toHaveCount(0, { timeout: 10_000 });
    await expect.poll(readBackInset).toBe(12);

    await setFullScreen(false);
    await expect(slot).toHaveCount(1, { timeout: 10_000 });
    await expect.poll(readBackInset).toBe(windowedInset);
  } finally {
    await app.close();
  }
});

test("electron Settings returns to the canonical Home on its first painted frame", async () => {
  const chatStub = await startChatSmokeStub({
    sessionEmail: SHELL_E2E_EMAIL,
    workspaceChatDelayMs: 350,
  });
  let app: ElectronApplication | undefined;

  try {
    app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: electronTestEnv({ apiBaseUrl: chatStub.baseUrl }),
    });
    const appWindow = await findWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await app.evaluate(({ BrowserWindow }) => {
      const mainWindow = BrowserWindow.getAllWindows().find((candidate) => {
        const url = candidate.webContents.getURL();
        return url.length > 0 && new URL(url).hash === "";
      });
      if (!mainWindow) throw new Error("Main Electron window is unavailable.");
      mainWindow.setContentSize(1_600, 900);
    });

    await expect(
      appWindow.getByRole("region", { name: "Comma assistant" })
    ).toBeVisible();
    await expect(appWindow.getByTestId("home-responsive-layout")).toBeVisible();
    await expect
      .poll(() =>
        appWindow
          .locator('.comma-chat-route[data-variant="home"]')
          .evaluate((element) => element.getBoundingClientRect().width)
      )
      .toBeGreaterThan(1_100);
    await expect(appWindow.getByTestId("home-greet-rail")).toBeVisible();
    await expect(appWindow.getByTestId("home-tasks-rail")).toBeVisible();

    const prompt = appWindow.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("keep this through settings");
    await appWindow.getByRole("button", { name: "Send" }).click();
    const assistantMessage = appWindow.locator(
      '[data-message-id="msg-assistant-smoke"]'
    );
    await expect(assistantMessage).toBeVisible();
    await expect(appWindow.getByTestId("chat-empty")).toHaveCount(0);

    await openAppSettingsFromRail(appWindow);
    // Settings is a modal over the shell, not a location: the window stays on
    // Home, the window bar and rail stay mounted and marked beneath the card,
    // and the card holds both settings regions inside the window.
    await expect
      .poll(() => appWindow.evaluate(() => window.location.hash))
      .toMatch(/^(#\/)?$/);
    await expect(
      appWindow.getByRole("heading", { level: 1, name: "General" })
    ).toBeVisible();
    const settingsCard = appWindow.locator(".comma-settings-dialog");
    await expect(settingsCard).toBeVisible();
    await expect(appWindow.getByTestId("comma-settings-layout")).toHaveCount(0);
    await expect(appWindow.getByTestId("comma-window-bar")).toBeVisible();
    await expect(
      appWindow.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();
    await expect(
      appWindow.getByRole("button", { exact: true, name: "Settings" })
    ).toHaveAttribute("aria-current", "page");
    await expect(
      appWindow.getByRole("button", { exact: true, name: "Toggle chat sidebar" })
    ).toBeVisible();
    await expect
      .poll(() =>
        settingsCard.evaluate((card) => {
          const panel = document
            .querySelector<HTMLElement>(".comma-content")!
            .getBoundingClientRect();
          const rect = card.getBoundingClientRect();
          return {
            hasContent: card.querySelector('[data-slot="settings-content"]') !== null,
            hasSections: card.querySelector(".comma-settings-sidebar") !== null,
            insideWindow: rect.top >= 0 && rect.bottom <= window.innerHeight,
            overPanel: rect.width < panel.width,
          };
        })
      )
      .toEqual({
        hasContent: true,
        hasSections: true,
        insideWindow: true,
        overPanel: true,
      });
    await installHomeReturnFrameProbe(appWindow);

    // Home is behind the card the whole time, so dismissing it is the return.
    await appWindow.keyboard.press("Escape");
    await expect(settingsCard).toHaveCount(0);
    await expect(
      appWindow.getByRole("region", { name: "Comma assistant" })
    ).toBeVisible();
    await expect(assistantMessage).toBeVisible();
    await expect(appWindow.getByTestId("chat-empty")).toHaveCount(0);
    await waitForPaintFrames(appWindow);

    const probe = await finishHomeReturnFrameProbe(appWindow);
    expect(probe.homeSurfaceSeen).toBe(true);
    expect(probe.frameSamples).toBeGreaterThanOrEqual(2);
    expect(probe.legacyAddedNodes).toBe(0);
    expect(probe.badFrames).toEqual([]);
  } finally {
    try {
      await app?.close();
    } finally {
      await chatStub.close();
    }
  }
});

test("electron CSP permits the authenticated blob avatar to load", async () => {
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnv(),
  });

  try {
    const appWindow = await findElectronWindowByRole(app, "complementary", {
      name: "App sidebar",
    });
    await appWindow.waitForLoadState("domcontentloaded");

    // Both Profile and the rail render the authenticated avatar. Scope each
    // consumer so CSP coverage cannot silently inspect only one of them.
    await openAppSettingsFromRail(appWindow);
    await appWindow.getByRole("button", { exact: true, name: "Profile" }).click();
    const profileAvatar = appWindow
      .getByRole("button", { exact: true, name: "Choose image" })
      .locator('img[alt="Shell Avatar"]');
    const sidebarAvatar = appWindow.locator(
      '.comma-sidebar-body .comma-user-avatar img[alt="Shell Avatar"]'
    );
    for (const avatar of [profileAvatar, sidebarAvatar]) {
      await expect(avatar).toHaveAttribute("src", /^blob:/);
      await expect
        .poll(() => avatar.evaluate((image: HTMLImageElement) => image.naturalWidth))
        .toBe(1);
    }
    await expect(sidebarAvatar).toHaveCSS("width", "32px");
    await expect(sidebarAvatar).toHaveCSS("height", "32px");
  } finally {
    await app.close();
  }
});

test("electron registers Open Comma and preserves cleared global shortcuts across restart", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");
  const launch = () =>
    electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: electronTestEnv({ sideChatHostPath: sideChatShortcutRejectionHostFixture }),
    });
  let app = await launch();
  try {
    let page = await findWindowByNativeRole(app, "main-window");
    await openAppSettingsFromRail(page);
    await page.getByRole("button", { name: "Keyboard shortcuts" }).click();
    await dismissVisibleToasts(page);
    const openComma = page.getByRole("button", { name: "Open Comma: Alt + Space" });
    await expect(openComma).toBeEnabled();
    expect(
      await app.evaluate(({ globalShortcut }) =>
        globalShortcut.isRegistered("Alt+Space")
      )
    ).toBe(true);
    // Reserve another chord in the OS to exercise native rejection through the
    // actual settings owner, rather than only a mocked component error.
    expect(
      await app.evaluate(({ globalShortcut }) =>
        globalShortcut.register("Control+Alt+Shift+9", () => {})
      )
    ).toBe(true);
    await openComma.click();
    await page.keyboard.press("Control+Alt+Shift+9");
    await expect(
      page.getByText("Couldn’t register this shortcut. Choose another shortcut.")
    ).toBeVisible();
    await expect(openComma).toBeEnabled();
    expect(
      await app.evaluate(({ globalShortcut }) =>
        globalShortcut.isRegistered("Alt+Space")
      )
    ).toBe(true);
    await app.evaluate(({ globalShortcut }) =>
      globalShortcut.unregister("Control+Alt+Shift+9")
    );
    await openComma.click();
    await page.getByRole("button", { name: "Clear shortcut" }).click();
    await expect(
      page.getByRole("button", { name: "Open Comma: Not set" })
    ).toBeEnabled();
    expect(
      await app.evaluate(({ globalShortcut }) =>
        globalShortcut.isRegistered("Alt+Space")
      )
    ).toBe(false);
    await page.getByRole("button", { name: "Open Comma: Not set" }).click();
    await page.keyboard.press("Alt+Space");
    await expect(
      page.getByRole("button", { name: "Open Comma: Alt + Space" })
    ).toBeEnabled();
    expect(
      await app.evaluate(({ globalShortcut }) =>
        globalShortcut.isRegistered("Alt+Space")
      )
    ).toBe(true);
    await page.getByRole("button", { name: "Open Comma: Alt + Space" }).click();
    await page.getByRole("button", { name: "Clear shortcut" }).click();
    await expect(
      page.getByRole("button", { name: "Open Comma: Not set" })
    ).toBeEnabled();
    await page.getByRole("button", { name: "Open Side Chat: Ctrl + Z" }).click();
    await expect(page.getByRole("button", { name: "Clear shortcut" })).toBeVisible();
    await page.getByRole("button", { name: "Clear shortcut" }).click();
    await expect(
      page.getByRole("button", { name: "Open Side Chat: Not set" })
    ).toBeEnabled();
    await expect
      .poll(() =>
        page.evaluate(
          async () =>
            (await window.commaNative!.appPreferences.state.get()).clientSettings
              ?.sideChatShortcut
        )
      )
      .toBeNull();
    await app.close();
    app = await launch();
    page = await findWindowByNativeRole(app, "main-window");
    await openAppSettingsFromRail(page);
    await page.getByRole("button", { name: "Keyboard shortcuts" }).click();
    for (const title of ["Open Comma", "Open Side Chat"])
      await expect(
        page.getByRole("button", { name: `${title}: Not set` })
      ).toBeEnabled();
    expect(
      await app.evaluate(({ globalShortcut }) =>
        globalShortcut.isRegistered("Alt+Space")
      )
    ).toBe(false);
  } finally {
    await app.close();
  }
});

test("electron rolls back a rejected Side Chat shortcut across restart", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");

  const launchFixture = () =>
    electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: electronTestEnv({
        sideChatHostPath: sideChatShortcutRejectionHostFixture,
      }),
    });
  let app: ElectronApplication | undefined = await launchFixture();

  try {
    let appWindow = await findWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await openAppSettingsFromRail(appWindow);
    await appWindow.getByRole("button", { name: "Keyboard shortcuts" }).click();
    await dismissVisibleToasts(appWindow);

    const shortcut = appWindow.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await expect(shortcut).toBeEnabled();
    await shortcut.click();
    await appWindow.keyboard.press("Control+K");

    await expect(
      appWindow.getByText(
        "Couldn’t register this shortcut. The previous shortcut is still active."
      )
    ).toBeVisible();
    await expect(
      appWindow.getByRole("button", { name: "Open Side Chat: Ctrl + Z" })
    ).toBeEnabled();
    expect(
      await appWindow.evaluate(() => localStorage.getItem("comma.side-chat.shortcut"))
    ).toBeNull();

    await app.close();
    app = await launchFixture();
    appWindow = await findWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await openAppSettingsFromRail(appWindow);
    await appWindow.getByRole("button", { name: "Keyboard shortcuts" }).click();
    await dismissVisibleToasts(appWindow);

    await expect(
      appWindow.getByRole("button", { name: "Open Side Chat: Ctrl + Z" })
    ).toBeEnabled();
    expect(
      await appWindow.evaluate(() => localStorage.getItem("comma.side-chat.shortcut"))
    ).toBeNull();
  } finally {
    await app?.close();
  }
});

test("electron reconciles a rejected shortcut replay after helper restart", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");

  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnv({
      sideChatHostPath: sideChatShortcutReplayHostFixture,
    }),
  });
  const markerPath = join(
    "/tmp",
    `comma-side-chat-shortcut-replay-${app.process().pid}.json`
  );

  try {
    await rm(markerPath, { force: true });
    const appWindow = await findWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await openAppSettingsFromRail(appWindow);
    await appWindow.getByRole("button", { name: "Keyboard shortcuts" }).click();
    await dismissVisibleToasts(appWindow);

    const shortcut = appWindow.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await shortcut.click();
    await appWindow.keyboard.press("Control+K");
    await expect(
      appWindow.getByRole("button", { name: "Open Side Chat: Ctrl + K" })
    ).toBeEnabled();

    await expect
      .poll(async () => {
        try {
          return JSON.parse(await readFile(markerPath, "utf8")).state;
        } catch {
          return "missing";
        }
      })
      .toBe("reconciled");
    expect(
      await appWindow.evaluate(
        async () =>
          (await window.commaNative!.appPreferences.state.get()).clientSettings
            ?.sideChatShortcut
      )
    ).toEqual({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
  } finally {
    await app.close();
    await rm(markerPath, { force: true });
  }
});

test("electron serializes a shortcut update behind rejected helper replay", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");

  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnv({
      sideChatHostPath: sideChatShortcutOverlapHostFixture,
    }),
  });
  const markerPath = join(
    "/tmp",
    `comma-side-chat-shortcut-overlap-${app.process().pid}.json`
  );

  try {
    await rm(markerPath, { force: true });
    const appWindow = await findWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await openAppSettingsFromRail(appWindow);
    await appWindow.getByRole("button", { name: "Keyboard shortcuts" }).click();
    await dismissVisibleToasts(appWindow);

    const shortcutControl = appWindow.getByRole("button", { name: /^Open Side Chat:/ });
    await expect(shortcutControl).toHaveAccessibleName("Open Side Chat: Ctrl + Z");
    await shortcutControl.click();
    await appWindow.keyboard.press("Control+K");
    await expect(shortcutControl).toHaveAccessibleName("Open Side Chat: Ctrl + K");
    await expect(shortcutControl).toBeEnabled();
    await expect
      .poll(async () => {
        try {
          return JSON.parse(await readFile(markerPath, "utf8")).state;
        } catch {
          return "missing";
        }
      })
      .toBe("replay-pending");

    await shortcutControl.click();
    await appWindow.keyboard.press("Control+L");
    await expect(shortcutControl).toHaveAccessibleName("Open Side Chat: Ctrl + L");
    await expect(shortcutControl).toBeDisabled();
    await expect(shortcutControl).toHaveAttribute("aria-busy", "true");
    await expect(shortcutControl).toBeFocused();

    await expect
      .poll(async () => {
        try {
          return JSON.parse(await readFile(markerPath, "utf8"));
        } catch {
          return { overlapObserved: undefined, state: "missing" };
        }
      })
      .toMatchObject({
        overlapObserved: false,
        state: "reconciled",
      });
    await expect(
      appWindow.getByText(
        "Couldn’t register this shortcut. The previous shortcut is still active."
      )
    ).toBeVisible();
    await expect(shortcutControl).toHaveAccessibleName("Open Side Chat: Ctrl + K");
    await expect(shortcutControl).toHaveAttribute("data-state", "error");
    await expect(shortcutControl).toBeEnabled();
    await expect(shortcutControl).toBeFocused();
    expect(
      await appWindow.evaluate(
        async () =>
          (await window.commaNative!.appPreferences.state.get()).clientSettings
            ?.sideChatShortcut
      )
    ).toEqual({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });

    await appWindow.waitForTimeout(1_500);
    expect(JSON.parse(await readFile(markerPath, "utf8"))).toMatchObject({
      overlapObserved: false,
      state: "reconciled",
    });
  } finally {
    await app.close();
    await rm(markerPath, { force: true });
  }
});

test("electron closes Side Chat with Escape and preserves chat on reopen", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");
  const message = "Keep this Side Chat conversation";
  const draft = "Continue after reopening";
  const chatStub = await startChatSmokeStub({
    sessionEmail: SHELL_E2E_EMAIL,
    workspaceTranscript: [
      {
        actor_type: "agent",
        kind: "message",
        message_id: "msg-side-chat-preserved",
        created_at: 1_720_000_001,
        content: [{ type: "text", text: message }],
      },
    ],
  });
  let app: ElectronApplication | undefined;
  try {
    app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: electronTestEnvWithHealthySideChat({ apiBaseUrl: chatStub.baseUrl }),
    });
    const page = await findWindowByNativeRole(app, "side-chat-window");
    await expect(page.getByText(message)).toBeVisible();
    const composer = page.getByRole("textbox", { name: "AI prompt" });
    await composer.fill(draft);
    await composer.press("Escape");
    await expect
      .poll(() =>
        app!.evaluate(({ BrowserWindow }) => {
          const window = BrowserWindow.getAllWindows().find((candidate) => {
            const url = candidate.webContents.getURL();
            return url.includes("#/side-chat") && !url.includes("#/side-chat/");
          });
          return window?.isVisible();
        })
      )
      .toBe(false);
    await app.evaluate(({ Menu }) => {
      const openSideChat = Menu.getApplicationMenu()
        ?.items.flatMap((item) => item.submenu?.items ?? [])
        .find((item) => item.label === "Open Side Chat");
      if (!openSideChat) throw new Error("Open Side Chat menu is unavailable.");
      openSideChat.click();
    });
    await expect(page.getByText(message)).toBeVisible();
    await expect(composer).toHaveText(draft);
  } finally {
    await app?.close();
    await chatStub.close();
  }
});

test("electron renders the opened Side Chat in its isolated transparent window", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...electronTestEnvWithHealthySideChat(),
      COMMA_SIDE_CHAT_BACKDROP_TRACE_GEOMETRY: "1",
    },
  });
  let backdropOutput = "";
  app.process().stderr?.on("data", (chunk) => {
    backdropOutput += chunk.toString();
  });
  const latestBackdropHeight = () => {
    const lines = backdropOutput
      .split("\n")
      .filter((line) => line.startsWith("[side-chat-geometry] "));
    const line = lines.at(-1);
    return line
      ? JSON.parse(line.slice("[side-chat-geometry] ".length)).visualHeight
      : undefined;
  };

  try {
    const sideChatWindow = await findWindowByNativeRole(app, "side-chat-window");
    await sideChatWindow.waitForLoadState("domcontentloaded");

    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          Boolean(
            BrowserWindow.getAllWindows()
              .find((window) => {
                const url = window.webContents.getURL();
                return url.includes("#/side-chat") && !url.includes("#/side-chat/");
              })
              ?.isVisible()
          )
        )
      )
      .toBe(true);
    await expect(sideChatWindow.locator(".comma-side-chat-host")).toBeVisible();
    await expect(sideChatWindow.getByText("Side Chat could not connect")).toBeVisible();

    const composerCenters = await sideChatWindow.evaluate(() => {
      const editor = document.querySelector<HTMLElement>(
        '.comma-chat-composer [role="textbox"]'
      );
      const leading = document.querySelector<HTMLElement>(
        '.comma-chat-composer [data-slot="ai-input-toolbar-leading"]'
      );
      const send = document.querySelector<HTMLElement>(
        '.comma-chat-composer [data-slot="ai-input-toolbar-trailing"] button'
      );
      if (!editor || !leading || !send) {
        throw new Error("Side Chat composer geometry is unavailable.");
      }
      const editorRect = editor.getBoundingClientRect();
      const leadingRect = leading.getBoundingClientRect();
      const sendRect = send.getBoundingClientRect();
      return {
        leading: leadingRect.top + leadingRect.height / 2,
        send: sendRect.top + sendRect.height / 2,
        textarea: editorRect.top + editorRect.height / 2,
      };
    });
    // The compact 36px Side Chat pill can land a CSS pixel off-center.
    expect(Math.abs(composerCenters.textarea - composerCenters.leading)).toBeLessThan(
      1.5
    );
    expect(Math.abs(composerCenters.textarea - composerCenters.send)).toBeLessThan(1.5);

    const composer = sideChatWindow.locator(".comma-chat-composer");
    const composerShell = sideChatWindow.locator(".comma-chat-composer-shell");
    const composerEditor = composer.getByRole("textbox", { name: "AI prompt" });
    const readComposerLayout = () =>
      sideChatWindow.evaluate(() => {
        const root = document.querySelector<HTMLElement>(".comma-chat-composer");
        const host = document.querySelector<HTMLElement>(".comma-side-chat-host");
        const shell = document.querySelector<HTMLElement>(".comma-chat-composer-shell");
        const editor = root?.querySelector<HTMLElement>('[role="textbox"]');
        const panel = document.querySelector<HTMLElement>(".comma-side-chat-panel");
        const leadingSlot = root?.querySelector<HTMLElement>(
          '[data-slot="ai-input-toolbar-leading"]'
        );
        const trailingSlot = root?.querySelector<HTMLElement>(
          '[data-slot="ai-input-toolbar-trailing"]'
        );
        const leading =
          leadingSlot?.querySelector<HTMLElement>("button") ?? leadingSlot;
        const trailing = trailingSlot?.querySelector<HTMLElement>("button");
        if (!root || !host || !shell || !panel || !leading || !trailing || !editor) {
          throw new Error("Side Chat composer transition geometry is unavailable.");
        }
        const hostRect = host.getBoundingClientRect();
        const rootRect = root.getBoundingClientRect();
        const panelRect = panel.getBoundingClientRect();
        const leadingRect = leading.getBoundingClientRect();
        const trailingRect = trailing.getBoundingClientRect();
        return {
          hostHeight: hostRect.height,
          leading: leadingRect.top + leadingRect.height / 2 - rootRect.top,
          leadingBottomGap: leading.matches("button")
            ? rootRect.bottom - leadingRect.bottom
            : null,
          textareaHeight: editor.getBoundingClientRect().height,
          composerBottomGap: panelRect.bottom - rootRect.bottom,
          composerScreenBottom: window.screenY + rootRect.bottom,
          trailing: trailingRect.top + trailingRect.height / 2 - rootRect.top,
          trailingBottomGap: rootRect.bottom - trailingRect.bottom,
          viewportHeight: window.innerHeight,
        };
      });
    await sideChatWindow.waitForTimeout(200);
    const singleLineLayout = await readComposerLayout();
    await expect
      .poll(latestBackdropHeight)
      .toBe(Math.ceil(singleLineLayout.hostHeight));
    await composerEditor.evaluate((editor) => {
      editor.textContent = "First line\nSecond line\nThird line";
      editor.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await expect(composerShell).toHaveAttribute("data-side-chat-multiline", "true");
    await expect
      .poll(async () => (await readComposerLayout()).leading)
      .toBeGreaterThan(singleLineLayout.leading + 20);
    await expect
      .poll(() =>
        composer.evaluate(
          (element) =>
            element
              .getAnimations({ subtree: true })
              .filter(
                (animation) => animation.playState === "running" || animation.pending
              ).length
        )
      )
      .toBe(0);
    const multilineLayout = await readComposerLayout();
    await expect.poll(latestBackdropHeight).toBe(Math.ceil(multilineLayout.hostHeight));
    for (const control of ["leading", "trailing"] as const) {
      expect(multilineLayout[control]).toBeGreaterThan(singleLineLayout[control] + 20);
    }
    for (const layout of [singleLineLayout, multilineLayout]) {
      expect(layout.composerBottomGap).toBeCloseTo(18, 1);
    }
    // AiInput already reserves its toolbar row inside the small layout. Side
    // Chat must not reserve a second row as empty padding below the controls.
    for (const layout of [multilineLayout, singleLineLayout]) {
      for (const gap of [layout.leadingBottomGap, layout.trailingBottomGap]) {
        if (gap === null) continue; // An empty leading slot has no button edge.
        // The composer shell adds no second padding layer in either layout.
        // Both retain the 1px border and 3px toolbar row centering.
        expect(gap).toBeCloseTo(1 + 3, 1);
      }
    }
    expect(
      Math.abs(
        singleLineLayout.composerScreenBottom - multilineLayout.composerScreenBottom
      )
    ).toBeLessThan(0.6);
    expect(multilineLayout.hostHeight).toBeGreaterThan(
      singleLineLayout.hostHeight + 15
    );
    expect(
      new Set(
        [singleLineLayout, multilineLayout].map((layout) => layout.viewportHeight)
      ).size
    ).toBe(1);
    await composerEditor.fill("");
    await expect(composerShell).not.toHaveAttribute("data-side-chat-multiline");
    await expect
      .poll(latestBackdropHeight)
      .toBe(Math.ceil(singleLineLayout.hostHeight));

    for (let cycle = 0; cycle < 3; cycle += 1) {
      // Each ordinary expansion starts after the previous collapse has painted.
      // A wall-clock delay does not establish that boundary in a background
      // Electron window. The separate rapid-reversal scenario below deliberately
      // interrupts animations and must not use this settling step.
      await expect(composerEditor).toBeEmpty();
      await expect
        .poll(() =>
          composer.evaluate(
            (element) =>
              element
                .getAnimations({ subtree: true })
                .filter(
                  (animation) => animation.playState === "running" || animation.pending
                ).length
          )
        )
        .toBe(0);
      await expect
        .poll(async () => (await readComposerLayout()).textareaHeight)
        .toBe(singleLineLayout.textareaHeight);
      await composerEditor.fill(`Cycle ${cycle}\nSecond line`);
      const expansionFrames = [];
      for (let frame = 0; frame < 12; frame += 1) {
        await sideChatWindow.waitForTimeout(16);
        expansionFrames.push(await readComposerLayout());
      }
      const expansionScreenBottoms = expansionFrames.map(
        (frame) => frame.composerScreenBottom
      );
      expect(
        Math.max(...expansionScreenBottoms) - Math.min(...expansionScreenBottoms)
      ).toBeLessThan(0.6);
      expect(new Set(expansionFrames.map((frame) => frame.hostHeight)).size).toBe(1);
      expect(expansionFrames[0]!.hostHeight).toBeGreaterThan(
        singleLineLayout.hostHeight
      );
      expect(new Set(expansionFrames.map((frame) => frame.viewportHeight)).size).toBe(
        1
      );
      expect(expansionFrames[0]!.viewportHeight).toBe(singleLineLayout.viewportHeight);
      for (const frame of expansionFrames) {
        expect(frame.composerBottomGap).toBeCloseTo(18, 1);
      }
      expectMonotonic(
        expansionFrames.map((frame) => frame.textareaHeight),
        "increasing"
      );
      expectMonotonic(
        expansionFrames.map((frame) => frame.leading),
        "increasing"
      );
      expectMonotonic(
        expansionFrames.map((frame) => frame.trailing),
        "increasing"
      );

      await composerEditor.fill("");
      const collapseFrames = [];
      for (let frame = 0; frame < 12; frame += 1) {
        await sideChatWindow.waitForTimeout(16);
        collapseFrames.push(await readComposerLayout());
      }
      const collapseScreenBottoms = collapseFrames.map(
        (frame) => frame.composerScreenBottom
      );
      expect(
        Math.max(...collapseScreenBottoms) - Math.min(...collapseScreenBottoms)
      ).toBeLessThan(0.6);
      expect(new Set(collapseFrames.map((frame) => frame.hostHeight)).size).toBe(1);
      expect(collapseFrames[0]!.hostHeight).toBeCloseTo(singleLineLayout.hostHeight, 1);
      expect(new Set(collapseFrames.map((frame) => frame.viewportHeight)).size).toBe(1);
      expect(collapseFrames[0]!.viewportHeight).toBe(singleLineLayout.viewportHeight);
      for (const frame of collapseFrames) {
        expect(frame.composerBottomGap).toBeCloseTo(18, 1);
      }
      expectMonotonic(
        collapseFrames.map((frame) => frame.textareaHeight),
        "decreasing"
      );
      expectMonotonic(
        collapseFrames.map((frame) => frame.leading),
        "decreasing"
      );
      expectMonotonic(
        collapseFrames.map((frame) => frame.trailing),
        "decreasing"
      );
    }

    await composerEditor.fill("Rapid one\nRapid two\nRapid three");
    await sideChatWindow.waitForTimeout(48);
    await composerEditor.fill("");
    await sideChatWindow.waitForTimeout(48);
    await composerEditor.fill("Reverse one\nReverse two\nReverse three");
    const reversalFrames = [];
    for (let frame = 0; frame < 15; frame += 1) {
      await sideChatWindow.waitForTimeout(16);
      reversalFrames.push(await readComposerLayout());
    }
    for (const frame of reversalFrames) {
      expect(frame.composerBottomGap).toBeCloseTo(18, 1);
      expect(frame.viewportHeight).toBe(singleLineLayout.viewportHeight);
    }
    expect(
      Math.max(...reversalFrames.map((frame) => frame.composerScreenBottom)) -
        Math.min(...reversalFrames.map((frame) => frame.composerScreenBottom))
    ).toBeLessThan(0.6);
    await composerEditor.fill("");
    await expect(composerShell).not.toHaveAttribute("data-side-chat-multiline");

    const automaticWrap = await composerEditor.evaluate(async (editor) => {
      const shell = editor.closest<HTMLElement>(".comma-chat-composer-shell");
      if (!shell) throw new Error("Side Chat composer shell is unavailable.");
      const states: string[] = [];
      const observer = new MutationObserver(() => {
        states.push(shell.dataset.sideChatMultiline ?? "single");
      });
      observer.observe(shell, {
        attributeFilter: ["data-side-chat-multiline"],
      });
      const input = async (value: string) => {
        editor.textContent = value;
        editor.dispatchEvent(new Event("input", { bubbles: true }));
        await new Promise<void>((done) => window.setTimeout(done, 24));
      };

      let value = "";
      for (let index = 0; index < 80 && !shell.dataset.sideChatMultiline; index += 1) {
        value += "M";
        await input(value);
      }
      const wrappedLength = value.length;
      for (let index = 0; index < 4; index += 1) {
        value += "M";
        await input(value);
      }
      await new Promise<void>((done) => window.setTimeout(done, 200));
      observer.disconnect();
      return {
        multiline: shell.dataset.sideChatMultiline === "true",
        states,
        wrappedLength,
      };
    });
    expect(automaticWrap.wrappedLength).toBeLessThan(80);
    expect(automaticWrap.multiline).toBe(true);
    const firstMultiline = automaticWrap.states.indexOf("true");
    expect(firstMultiline).toBeGreaterThanOrEqual(0);
    expect(automaticWrap.states.slice(firstMultiline)).not.toContain("single");
    await composerEditor.fill("");
    await expect(composerShell).not.toHaveAttribute("data-side-chat-multiline");

    await sideChatWindow.emulateMedia({ colorScheme: "dark" });
    await expect(sideChatWindow.locator(".comma-side-chat-host")).toHaveAttribute(
      "data-theme",
      "Dark mode"
    );
    await expect(async () => {
      const [composerText, retryText, statusTitle] = await Promise.all([
        readLocatorCssRgb(sideChatWindow.locator('[role="textbox"]'), "color"),
        readLocatorCssRgb(
          sideChatWindow.locator(".comma-side-chat-status .comma-chat-link-button"),
          "color"
        ),
        readLocatorCssRgb(
          sideChatWindow.locator(".comma-side-chat-status strong"),
          "color"
        ),
      ]);
      expect(
        isNearNeutralLightRgb(composerText),
        `composer text ${JSON.stringify(composerText)}`
      ).toBe(true);
      expect(
        isNearNeutralLightRgb(retryText),
        `retry text ${JSON.stringify(retryText)}`
      ).toBe(true);
      expect(
        isNearNeutralLightRgb(statusTitle),
        `status title ${JSON.stringify(statusTitle)}`
      ).toBe(true);
    }).toPass();

    await expect(
      sideChatWindow.evaluate(() => {
        const rendererWindow = window as Window & {
          commaNative?: {
            self?: { role?: string; windowId?: string };
          };
          process?: unknown;
          require?: unknown;
        };
        const root = document.querySelector<HTMLElement>(".comma-side-chat-host");
        const appRoot = document.getElementById("root");
        return {
          appRootBackground: appRoot
            ? getComputedStyle(appRoot).backgroundColor
            : "missing",
          bodyBackground: getComputedStyle(document.body).backgroundColor,
          bodyRole: document.body.dataset.commaWindowRole,
          phase: root?.dataset.phase,
          presentationReady: root?.dataset.presentationReady,
          processType: typeof rendererWindow.process,
          requireType: typeof rendererWindow.require,
          role: rendererWindow.commaNative?.self?.role,
          windowId: rendererWindow.commaNative?.self?.windowId,
        };
      })
    ).resolves.toEqual({
      appRootBackground: "rgba(0, 0, 0, 0)",
      bodyBackground: "rgba(0, 0, 0, 0)",
      bodyRole: "side-chat",
      phase: "open",
      presentationReady: "true",
      processType: "undefined",
      requireType: "undefined",
      role: "side-chat-window",
      windowId: "win_side_chat",
    });

    // Docked DevTools sit outside the native Side Chat interactive frame, so
    // the pass-through monitor makes them visible but unclickable. Any normal
    // DevTools opening must be normalized to a separate BrowserWindow.
    await app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows().find((candidate) => {
        const url = candidate.webContents.getURL();
        return url.includes("#/side-chat") && !url.includes("#/side-chat/");
      });
      if (!window) throw new Error("Side Chat BrowserWindow is unavailable.");
      window.webContents.openDevTools({ activate: false, mode: "right" });
    });
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) => {
          const window = BrowserWindow.getAllWindows().find((candidate) => {
            const url = candidate.webContents.getURL();
            return url.includes("#/side-chat") && !url.includes("#/side-chat/");
          });
          const devTools = window?.webContents.devToolsWebContents;
          return Boolean(devTools && BrowserWindow.fromWebContents(devTools));
        })
      )
      .toBe(true);
    await app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows().find((candidate) => {
        const url = candidate.webContents.getURL();
        return url.includes("#/side-chat") && !url.includes("#/side-chat/");
      });
      window?.webContents.closeDevTools();
    });

    // A real pointer sequence on a child control must remain targeted at that
    // control.
    const retryButton = sideChatWindow.getByRole("button", { name: "Retry" });
    await retryButton.evaluate((button) => {
      button.addEventListener(
        "click",
        () => {
          document.body.dataset.sideChatChildClick = "received";
        },
        { once: true }
      );
    });
    await retryButton.click();
    await expect(sideChatWindow.locator("body")).toHaveAttribute(
      "data-side-chat-child-click",
      "received"
    );
    await expect(sideChatWindow.getByText("Side Chat could not connect")).toBeVisible();

    const debugEscalationOutcome = await sideChatWindow.evaluate(async () => {
      const rendererWindow = window as Window & {
        commaNative?: {
          sideChat?: {
            updateDebugSettings?: (input: {
              showBackdrop: boolean;
            }) => Promise<unknown>;
          };
        };
      };
      try {
        await rendererWindow.commaNative?.sideChat?.updateDebugSettings?.({
          showBackdrop: false,
        });
        return "resolved";
      } catch {
        return "forbidden";
      }
    });
    expect(debugEscalationOutcome).toBe("forbidden");
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          Boolean(
            BrowserWindow.getAllWindows()
              .find((window) => {
                const url = window.webContents.getURL();
                return url.includes("#/side-chat") && !url.includes("#/side-chat/");
              })
              ?.isVisible()
          )
        )
      )
      .toBe(true);

    const mainWindow = await findWindowByNativeRole(app, "main-window");
    await mainWindow.evaluate(() =>
      window.commaNative!.appPreferences.update({
        clientSettings: { appearance: { reducedMotion: true } },
      })
    );
    await expect(sideChatWindow.locator("html")).toHaveAttribute(
      "data-comma-reduced-motion",
      "true"
    );

    // The generated settings command remains available from this signed-in
    // network-error surface.
    await sideChatWindow.evaluate(async () => {
      const rendererWindow = window as Window & {
        commaNative?: { sideChat?: { openSettings?: () => Promise<unknown> } };
      };
      await rendererWindow.commaNative?.sideChat?.openSettings?.();
    });
    await expect(
      mainWindow.getByRole("heading", { level: 1, name: "General" })
    ).toBeVisible();
    await expect(mainWindow.locator("html")).toHaveAttribute(
      "data-comma-reduced-motion",
      "true"
    );

    const reducedMotionTestSourceFrame = await sideChatWindow
      .locator(".comma-side-chat-host")
      .evaluate((host) => {
        const frame = host.getBoundingClientRect();
        return {
          height: 30,
          width: 30,
          x: window.screenX + frame.left + frame.width / 2 - 15,
          y: window.screenY + frame.top + frame.height - 45,
        };
      });
    await sideChatWindow.evaluate(async (sourceFrame) => {
      const rendererWindow = window as Window & {
        commaNative?: {
          sideChat?: {
            openTestWindow?: (input: {
              sourceFrame: typeof sourceFrame;
            }) => Promise<unknown>;
          };
        };
      };
      await rendererWindow.commaNative?.sideChat?.openTestWindow?.({ sourceFrame });
    }, reducedMotionTestSourceFrame);
    const reducedMotionTestWindow = await findWindowByNativeRole(
      app,
      "side-chat-test-window"
    );
    await expect(reducedMotionTestWindow.locator("html")).toHaveAttribute(
      "data-comma-reduced-motion",
      "true"
    );
    await reducedMotionTestWindow.keyboard.press("Escape");
    await expect.poll(() => countSideChatTestWindows(app)).toBe(0);

    await mainWindow.keyboard.press("Escape");
    await expect(mainWindow.getByTestId("home-responsive-layout")).toBeVisible();
    const sideChatRoot = sideChatWindow.locator(".comma-side-chat-host");
    for (const appearance of ["dark", "light"] as const) {
      await mainWindow.evaluate(
        (sideChatAppearance) =>
          window.commaNative!.appPreferences.update({
            clientSettings: { sideChatAppearance },
          }),
        appearance
      );
      await expect(sideChatRoot).toHaveAttribute(
        "data-theme",
        appearance === "dark" ? "Dark mode" : "Light mode"
      );
    }

    const selectableStatus = sideChatWindow.getByText("Side Chat could not connect");
    const statusBounds = await selectableStatus.boundingBox();
    expect(statusBounds).not.toBeNull();
    const selectionY = statusBounds!.y + statusBounds!.height / 2;
    await sideChatWindow.mouse.move(
      statusBounds!.x + statusBounds!.width - 2,
      selectionY
    );
    await sideChatWindow.mouse.down();
    await sideChatWindow.mouse.move(statusBounds!.x + 2, selectionY, { steps: 8 });
    await sideChatWindow.mouse.up();

    await expect
      .poll(() => sideChatWindow.evaluate(() => window.getSelection()?.toString()))
      .toContain("Side Chat");
    await expect
      .poll(() =>
        sideChatWindow.evaluate(async () => {
          const rendererWindow = window as Window & {
            commaNative?: {
              sideChat?: {
                presentation?: {
                  get?: () => Promise<{ phase: string; progress: number }>;
                };
              };
            };
          };
          const presentation =
            await rendererWindow.commaNative?.sideChat?.presentation?.get?.();
          return presentation
            ? { phase: presentation.phase, progress: presentation.progress }
            : undefined;
        })
      )
      .toEqual({ phase: "open", progress: 1 });
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          Boolean(
            BrowserWindow.getAllWindows()
              .find((window) => {
                const url = window.webContents.getURL();
                return url.includes("#/side-chat") && !url.includes("#/side-chat/");
              })
              ?.isVisible()
          )
        )
      )
      .toBe(true);

    if (process.platform === "darwin") {
      await app.evaluate(({ BrowserWindow }) => {
        BrowserWindow.getAllWindows()
          .find((window) => {
            const url = window.webContents.getURL();
            return url.includes("#/side-chat") && !url.includes("#/side-chat/");
          })
          ?.focus();
      });
      await sideChatWindow.keyboard.press("Meta+W");
      await expect
        .poll(() =>
          app.evaluate(({ BrowserWindow }) => {
            const window = BrowserWindow.getAllWindows().find((candidate) => {
              const url = candidate.webContents.getURL();
              return url.includes("#/side-chat") && !url.includes("#/side-chat/");
            });
            return { exists: Boolean(window), visible: window?.isVisible() ?? false };
          })
        )
        .toEqual({ exists: true, visible: true });
    }
  } finally {
    await app.close();
  }
});

test("electron keeps a recovered Side Chat fail-closed until its slow helper close settles", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnvWithHealthySideChat({
      sideChatHostPath: sideChatSlowCloseHostFixture,
    }),
  });
  const electronProcess = app.process();
  let electronOutput = "";
  const captureOutput = (chunk: Buffer | string) => {
    electronOutput += chunk.toString();
  };
  electronProcess.stdout?.on("data", captureOutput);
  electronProcess.stderr?.on("data", captureOutput);

  try {
    const sideChatWindow = await findWindowByNativeRole(app, "side-chat-window");
    await sideChatWindow.waitForLoadState("domcontentloaded");
    await expect(sideChatWindow.locator(".comma-side-chat-host")).toBeVisible();
    await expect
      .poll(() => persistentSideChatWindowState(app))
      .toEqual({
        count: 1,
        visible: true,
      });
    await installSideChatVisibilityProbe(app);

    const originalWindowState = await app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows().find((candidate) => {
        const url = candidate.webContents.getURL();
        return url.includes("#/side-chat") && !url.includes("#/side-chat/");
      });
      if (!window) throw new Error("Side Chat BrowserWindow is unavailable.");
      return { bounds: window.getBounds(), id: window.id };
    });

    await app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows().find((candidate) => {
        const url = candidate.webContents.getURL();
        return url.includes("#/side-chat") && !url.includes("#/side-chat/");
      });
      if (!window) throw new Error("Side Chat BrowserWindow is unavailable.");
      window.webContents.forcefullyCrashRenderer();
    });

    await expect.poll(() => electronOutput).toContain("close-received epoch=1");
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows()
            .filter((candidate) => {
              const url = candidate.webContents.getURL();
              return url.includes("#/side-chat") && !url.includes("#/side-chat/");
            })
            .map((window) => ({
              id: window.id,
              visible: window.isVisible(),
            }))
        )
      )
      .toEqual([
        {
          id: expect.any(Number),
          visible: false,
        },
      ]);
    const [recoveredWindow] = await app.evaluate(({ BrowserWindow }) =>
      BrowserWindow.getAllWindows()
        .filter((candidate) => {
          const url = candidate.webContents.getURL();
          return url.includes("#/side-chat") && !url.includes("#/side-chat/");
        })
        .map((window) => ({ bounds: window.getBounds(), id: window.id }))
    );
    if (!recoveredWindow) throw new Error("Recovered Side Chat window is missing.");
    const recoveredWindowId = recoveredWindow.id;
    expect(recoveredWindowId).not.toBe(originalWindowState.id);

    const recoveredSideChatWindow = await findWindowByNativeRole(
      app,
      "side-chat-window"
    );
    await recoveredSideChatWindow.waitForLoadState("domcontentloaded");

    // The fixture treats the first post-close layout as proof that the
    // replacement renderer has mounted. It first sends an old terminal closed
    // followed by opening/open frames before acknowledging the fail-close
    // request, then sends a long closing sequence after the exact ACK while
    // injecting interactive/open interference before the terminal closed.
    await expect
      .poll(() => electronOutput)
      .toContain("replacement-layout-received epoch=1");
    await expect.poll(() => electronOutput).toContain("stale-open-before-ack epoch=1");

    // Queue an explicit reopen while the helper-generation close barrier is
    // still active. The request must stay in Main until the matching closed
    // frame; sending it to the helper early makes the fixture emit an open
    // presentation immediately and fails the visibility assertions below.
    const reopenRequestedAt = await recoveredSideChatWindow.evaluate(async () => {
      const rendererWindow = window as Window & {
        commaNative?: {
          sideChat?: {
            finishInteractiveProgress?: (input: {
              shouldOpen: boolean;
            }) => Promise<unknown>;
            setContentSize?: (input: {
              height: number;
              width: number;
            }) => Promise<unknown>;
          };
        };
      };
      const sideChat = rendererWindow.commaNative?.sideChat;
      if (!sideChat?.finishInteractiveProgress || !sideChat.setContentSize) {
        throw new Error("Side Chat recovery commands are unavailable.");
      }
      const requestedAt = Date.now();
      await sideChat.finishInteractiveProgress({
        shouldOpen: true,
      });

      // The fixture deliberately withholds the exact close ACK until this
      // sentinel layout arrives. Awaiting the queued reopen first proves Main
      // accepted it while the barrier was still active; this second command
      // then releases the deterministic ACK/closing sequence.
      await sideChat.setContentSize({ height: 555, width: 777 });
      return requestedAt;
    });

    await expect.poll(() => electronOutput).toContain("close-ack-emitted epoch=1");
    await expect
      .poll(() => electronOutput)
      .toContain("closing-positive-after-ack epoch=1");
    await expect
      .poll(() => electronOutput)
      .toContain("post-ack-interactive-interference epoch=1");
    await expect
      .poll(() => electronOutput)
      .toContain("post-ack-open-interference epoch=1");
    await expect.poll(() => electronOutput).toContain("closed-emitted epoch=1");
    await expect
      .poll(() => electronOutput)
      .toContain("reopen-received-after-final epoch=1");
    expect(electronOutput).not.toContain("premature-open-received epoch=1");
    const helperTiming = readSlowCloseFixtureTiming(electronOutput);
    expect(helperTiming).toBeDefined();
    if (!helperTiming)
      throw new Error("Slow-close fixture timing markers are missing.");
    expect(helperTiming.staleClosedAt).toBeLessThan(helperTiming.closeAcknowledgedAt);
    expect(helperTiming.staleOpeningAt).toBeLessThan(helperTiming.closeAcknowledgedAt);
    expect(helperTiming.staleOpenAt).toBeLessThan(helperTiming.closeAcknowledgedAt);
    expect(reopenRequestedAt).toBeLessThanOrEqual(helperTiming.causalReleaseAt);
    expect(helperTiming.causalReleaseAt).toBeLessThanOrEqual(
      helperTiming.closeAcknowledgedAt
    );
    const firstClosingAt = helperTiming.closingFrameAts[0];
    const lastClosingAt = helperTiming.closingFrameAts.at(-1);
    if (firstClosingAt === undefined || lastClosingAt === undefined) {
      throw new Error("Slow-close fixture positive closing frames are missing.");
    }
    expect(firstClosingAt).toBeGreaterThanOrEqual(helperTiming.closeAcknowledgedAt);
    expect(helperTiming.postAckInteractiveAt).toBeGreaterThan(firstClosingAt);
    expect(helperTiming.postAckOpenAt).toBeGreaterThan(
      helperTiming.postAckInteractiveAt
    );
    expect(helperTiming.postAckOpenAt).toBeLessThan(helperTiming.closedAt);
    expect(
      helperTiming.closingFrameAts.every(
        (at) => at >= helperTiming.closeAcknowledgedAt && at < helperTiming.closedAt
      )
    ).toBe(true);
    expect(lastClosingAt - firstClosingAt).toBeGreaterThanOrEqual(500);
    expect(lastClosingAt).toBeLessThan(helperTiming.closedAt);
    expect(helperTiming.closedAt - firstClosingAt).toBeGreaterThanOrEqual(500);
    expect(reopenRequestedAt).toBeLessThan(helperTiming.closedAt);
    expect(helperTiming.reopenReceivedAt).toBeGreaterThanOrEqual(helperTiming.closedAt);

    const causalMarkerOrder = [
      "replacement-layout-received epoch=1",
      "stale-closed-before-ack epoch=1",
      "stale-opening-before-ack epoch=1",
      "stale-open-before-ack epoch=1",
      "causal-release-layout-received epoch=1",
      "close-ack-emitted epoch=1",
      "closing-positive-after-ack epoch=1",
      "post-ack-interactive-interference epoch=1",
      "post-ack-open-interference epoch=1",
      "closed-emitted epoch=1",
      "reopen-received-after-final epoch=1",
    ].map((marker) => electronOutput.indexOf(marker));
    expect(causalMarkerOrder.every((index) => index >= 0)).toBe(true);
    for (let index = 1; index < causalMarkerOrder.length; index += 1) {
      const previous = causalMarkerOrder[index - 1];
      const current = causalMarkerOrder[index];
      if (previous === undefined || current === undefined) {
        throw new Error("Slow-close fixture causal marker order is incomplete.");
      }
      expect(previous).toBeLessThan(current);
    }

    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows()
            .filter((candidate) => {
              const url = candidate.webContents.getURL();
              return url.includes("#/side-chat") && !url.includes("#/side-chat/");
            })
            .map((window) => ({
              bounds: window.getBounds(),
              id: window.id,
              visible: window.isVisible(),
            }))
        )
      )
      .toEqual([
        {
          bounds: originalWindowState.bounds,
          id: recoveredWindowId,
          visible: true,
        },
      ]);
    await expect(
      recoveredSideChatWindow.locator(".comma-side-chat-host")
    ).toBeVisible();

    await expect
      .poll(
        async () =>
          (await readSideChatVisibilityCalls(app)).filter(
            (call) => call.windowId === recoveredWindowId
          ).length
      )
      .toBeGreaterThan(0);
    const recoveredVisibilityCalls = (await readSideChatVisibilityCalls(app)).filter(
      (call) => call.windowId === recoveredWindowId
    );
    expect(recoveredVisibilityCalls.some((call) => call.kind === "showInactive")).toBe(
      true
    );
    expect(
      recoveredVisibilityCalls.every((call) => call.at >= helperTiming.closedAt)
    ).toBe(true);
  } finally {
    electronProcess.stdout?.off("data", captureOutput);
    electronProcess.stderr?.off("data", captureOutput);
    await destroySideChatTestWindowsAndClose(app);
  }
});

test("electron keeps Side Chat hidden when backdrop geometry fails after attach", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...electronTestEnv({ openSideChat: true }),
      COMMA_SIDE_CHAT_BACKDROP_FAULT: "geometry",
      COMMA_SIDE_CHAT_BACKDROP_PATH: sideChatBackdropFaultFixture,
    },
  });
  const electronProcess = app.process();
  let electronOutput = "";
  const captureOutput = (chunk: Buffer | string) => {
    electronOutput += chunk.toString();
  };
  electronProcess.stdout?.on("data", captureOutput);
  electronProcess.stderr?.on("data", captureOutput);

  try {
    const sideChatWindow = await findWindowByNativeRole(app, "side-chat-window");
    await sideChatWindow.waitForLoadState("domcontentloaded");

    // The fixture throws from updateGeometry only after attach has succeeded,
    // so observing this fault proves the native-quality backdrop was attached.
    await expect.poll(() => electronOutput).toContain("injected geometry failure");
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) => {
          const window = BrowserWindow.getAllWindows().find((candidate) => {
            const url = candidate.webContents.getURL();
            return (
              url.includes("#/side-chat") && !url.includes("#/side-chat/test-window")
            );
          });
          return { exists: Boolean(window), visible: window?.isVisible() ?? false };
        })
      )
      .toEqual({ exists: true, visible: false });
  } finally {
    electronProcess.stdout?.off("data", captureOutput);
    electronProcess.stderr?.off("data", captureOutput);
    await destroySideChatTestWindowsAndClose(app);
  }
});

test("electron detects delayed backdrop health loss and rebuilds on explicit reopen", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...electronTestEnv({ openSideChat: true }),
      COMMA_SIDE_CHAT_BACKDROP_FAULT: "async-health",
      COMMA_SIDE_CHAT_BACKDROP_PATH: sideChatBackdropFaultFixture,
    },
  });
  const electronProcess = app.process();
  let electronOutput = "";
  const captureOutput = (chunk: Buffer | string) => {
    electronOutput += chunk.toString();
  };
  electronProcess.stdout?.on("data", captureOutput);
  electronProcess.stderr?.on("data", captureOutput);

  try {
    const sideChatWindow = await findWindowByNativeRole(app, "side-chat-window");
    await sideChatWindow.waitForLoadState("domcontentloaded");

    await expect.poll(() => electronOutput).toContain("injected async health failure");
    await expect
      .poll(async () => ({
        presentation: await readSideChatPresentation(sideChatWindow),
        window: await persistentSideChatWindowState(app),
      }))
      .toEqual({
        presentation: { phase: "closed", progress: 0 },
        window: { count: 1, visible: false },
      });
    expect(electronOutput).not.toContain("explicit rebuild recovered");

    await sideChatWindow.evaluate(async () => {
      const rendererWindow = window as Window & {
        commaNative?: {
          sideChat?: {
            finishInteractiveProgress?: (input: {
              shouldOpen: boolean;
            }) => Promise<unknown>;
          };
        };
      };
      await rendererWindow.commaNative?.sideChat?.finishInteractiveProgress?.({
        shouldOpen: true,
      });
    });

    await expect
      .poll(() => electronOutput)
      .toContain("explicit rebuild recovered count=1");
    await expect
      .poll(async () => ({
        presentation: await readSideChatPresentation(sideChatWindow),
        window: await persistentSideChatWindowState(app),
      }))
      .toEqual({
        presentation: { phase: "open", progress: 1 },
        window: { count: 1, visible: true },
      });
  } finally {
    electronProcess.stdout?.off("data", captureOutput);
    electronProcess.stderr?.off("data", captureOutput);
    await destroySideChatTestWindowsAndClose(app);
  }
});

test("electron rejects a backdrop addon without a native health contract", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...electronTestEnv({ openSideChat: true }),
      COMMA_SIDE_CHAT_BACKDROP_PATH: sideChatBackdropMissingHealthFixture,
    },
  });
  const electronProcess = app.process();
  let electronOutput = "";
  const captureOutput = (chunk: Buffer | string) => {
    electronOutput += chunk.toString();
  };
  electronProcess.stdout?.on("data", captureOutput);
  electronProcess.stderr?.on("data", captureOutput);

  try {
    const sideChatWindow = await findWindowByNativeRole(app, "side-chat-window");
    await sideChatWindow.waitForLoadState("domcontentloaded");

    await expect.poll(() => electronOutput).toContain("has an invalid API");
    await expect
      .poll(async () => ({
        presentation: await readSideChatPresentation(sideChatWindow),
        window: await persistentSideChatWindowState(app),
      }))
      .toEqual({
        presentation: { phase: "closed", progress: 0 },
        window: { count: 1, visible: false },
      });
  } finally {
    electronProcess.stdout?.off("data", captureOutput);
    electronProcess.stderr?.off("data", captureOutput);
    await destroySideChatTestWindowsAndClose(app);
  }
});

test("non-macOS rejects opening a Side Chat Test window", async () => {
  test.skip(process.platform === "darwin", "This is the non-macOS boundary.");
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnv(),
  });

  try {
    const mainWindow = await findWindowByNativeRole(app, "main-window");
    await mainWindow.waitForLoadState("domcontentloaded");
    const outcome = await mainWindow.evaluate(async () => {
      const rendererWindow = window as Window & {
        commaNative?: {
          sideChat?: {
            openTestWindow?: (input: {
              sourceFrame: { height: number; width: number; x: number; y: number };
            }) => Promise<unknown>;
          };
        };
      };
      const openTestWindow = rendererWindow.commaNative?.sideChat?.openTestWindow;
      if (!openTestWindow) throw new Error("openTestWindow is unavailable.");
      try {
        await openTestWindow({
          sourceFrame: { height: 30, width: 30, x: 0, y: 0 },
        });
        return "resolved";
      } catch {
        return "rejected";
      }
    });

    expect(outcome).toBe("rejected");
    await expect.poll(() => countSideChatTestWindows(app)).toBe(0);
  } finally {
    await destroySideChatTestWindowsAndClose(app);
  }
});

test("electron opens the legacy Test surface as an isolated fullscreen window", async ({
  browserName: _browserName,
}, testInfo) => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnvWithHealthySideChat(),
  });

  try {
    const sideChatWindow = await findWindowByNativeRole(app, "side-chat-window");
    await sideChatWindow.waitForLoadState("domcontentloaded");
    await expect(sideChatWindow.locator(".comma-side-chat-host")).toBeVisible();
    const sideChatThreadFocusStyle = await sideChatWindow.evaluate(() => {
      const host = document.querySelector<HTMLElement>(".comma-side-chat-host");
      if (!host) throw new Error("Side Chat root is unavailable.");
      const viewport = document.createElement("div");
      viewport.className = "comma-scroll-area__viewport";
      viewport.tabIndex = 0;
      host.append(viewport);
      try {
        viewport.focus();
        const style = window.getComputedStyle(viewport);
        return {
          outlineStyle: style.outlineStyle,
        };
      } finally {
        viewport.remove();
      }
    });
    expect(sideChatThreadFocusStyle).toEqual({
      outlineStyle: "none",
    });

    const sourceFrame = await sideChatWindow.evaluate(() => {
      const root = document.querySelector<HTMLElement>(".comma-side-chat-host");
      if (!root) throw new Error("Side Chat root is unavailable.");
      const frame = root.getBoundingClientRect();
      return {
        height: 30,
        width: 30,
        x: window.screenX + frame.left + frame.width / 2 - 15,
        y: window.screenY + frame.top + frame.height - 45,
      };
    });

    await sideChatWindow.evaluate(async (input) => {
      const rendererWindow = window as Window & {
        commaNative?: {
          sideChat?: {
            openTestWindow?: (value: { sourceFrame: typeof input }) => Promise<unknown>;
          };
        };
      };
      await rendererWindow.commaNative?.sideChat?.openTestWindow?.({
        sourceFrame: input,
      });
    }, sourceFrame);

    const testWindow = await findWindowByNativeRole(app, "side-chat-test-window");
    await testWindow.waitForLoadState("domcontentloaded");
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows()
            .find((candidate) =>
              candidate.webContents.getURL().includes("#/side-chat/test-window")
            )
            ?.isVisible()
        )
      )
      .toBe(true);
    const runtime = await app.evaluate(({ BrowserWindow, screen }, source) => {
      const window = BrowserWindow.getAllWindows().find((candidate) =>
        candidate.webContents.getURL().includes("#/side-chat/test-window")
      );
      if (!window) return undefined;
      return {
        bounds: window.getBounds(),
        expectedDisplayBounds: screen.getDisplayMatching(source).bounds,
        url: window.webContents.getURL(),
        visible: window.isVisible(),
      };
    }, sourceFrame);
    expect(runtime).toBeDefined();
    expect(runtime).toMatchObject({
      bounds: runtime?.expectedDisplayBounds,
      visible: true,
    });
    expect(runtime?.url).toContain("#/side-chat/test-window?");

    const root = testWindow.locator(".comma-side-chat-test-window");
    await expect(root).toHaveAttribute("data-expanded", "true");
    await expect(root).toHaveAttribute("data-content-visible", "true");
    await expect(testWindow.locator("body")).toHaveAttribute(
      "data-comma-window-role",
      "side-chat-test"
    );
    await expect(
      testWindow.getByRole("heading", { level: 1, name: "测试窗口" })
    ).toBeVisible();
    await expect(testWindow.getByText("Window", { exact: true })).toBeVisible();
    await expect(testWindow.getByText("DPR", { exact: true })).toBeVisible();
    await expect(testWindow.getByText("Presentation", { exact: true })).toBeVisible();
    await expect(testWindow.getByText("Messages", { exact: true })).toHaveCount(0);
    await expect(testWindow.getByText("Draft", { exact: true })).toHaveCount(0);

    const dialog = testWindow.getByRole("dialog", {
      name: "Side Chat diagnostics",
    });
    const expectedDialogWidth = Math.min(
      Math.max(340, runtime!.bounds.width * 0.28),
      420
    );
    await testWindow.waitForTimeout(450);
    await expect
      .poll(async () => (await dialog.boundingBox())?.width)
      .toBeCloseTo(expectedDialogWidth, 0);
    const dialogBounds = await dialog.boundingBox();
    expect(dialogBounds).not.toBeNull();
    expect(dialogBounds!.width).toBeCloseTo(expectedDialogWidth, 0);
    expect(dialogBounds!.height).toBeCloseTo(276, 0);
    expect(dialogBounds!.x + dialogBounds!.width / 2).toBeCloseTo(
      runtime!.bounds.width / 2,
      0
    );
    expect(dialogBounds!.y + dialogBounds!.height / 2).toBeCloseTo(
      runtime!.bounds.height / 2,
      0
    );

    await testWindow.getByRole("button", { name: "Refresh content" }).click();
    const artifactPath = testInfo.outputPath("side-chat-test-window-expanded.png");
    await testWindow.screenshot({ animations: "disabled", path: artifactPath });
    await testInfo.attach("side-chat-test-window-expanded", {
      contentType: "image/png",
      path: artifactPath,
    });

    await testWindow.mouse.click(8, 8);
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows().some((candidate) =>
            candidate.webContents.getURL().includes("#/side-chat/test-window")
          )
        )
      )
      .toBe(false);
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          Boolean(
            BrowserWindow.getAllWindows()
              .find((candidate) => {
                const url = candidate.webContents.getURL();
                return url.includes("#/side-chat") && !url.includes("#/side-chat/");
              })
              ?.isVisible()
          )
        )
      )
      .toBe(true);

    const taskSourceFrame = {
      height: 120,
      width: 300,
      x: sourceFrame.x - 135,
      y: sourceFrame.y - 105,
    };
    await sideChatWindow.evaluate(
      async (input) => {
        const rendererWindow = window as Window & {
          commaNative?: {
            sideChat?: {
              openTestWindow?: (value: typeof input) => Promise<unknown>;
            };
          };
        };
        await rendererWindow.commaNative?.sideChat?.openTestWindow?.(input);
      },
      {
        sourceFrame: taskSourceFrame,
        target: {
          conversationId: "cnv_e2e_task",
          groupId: "grp_test",
          workspaceId: "wsp_e2e",
        },
      }
    );
    const taskWindow = await findWindowByNativeRole(app, "side-chat-test-window");
    await taskWindow.waitForLoadState("domcontentloaded");
    const taskRoot = taskWindow.locator(".comma-side-chat-test-window");
    await expect(taskRoot).toHaveAttribute("data-window-content", "task-chat");
    await expect(taskRoot).toHaveAttribute("data-expanded", "true");
    await expect(taskRoot).toHaveAttribute("data-transition-phase", "open");
    await expect(taskRoot).toHaveAttribute("data-content-visible", "true");
    await expect(taskWindow.getByRole("dialog", { name: "Task chat" })).toBeVisible();
    await expect(
      taskWindow.getByRole("region", { name: "Conversation" })
    ).toBeVisible();
    const taskRuntime = await app.evaluate(({ BrowserWindow }) => {
      const window = BrowserWindow.getAllWindows().find((candidate) =>
        candidate.webContents.getURL().includes("conversationId=cnv_e2e_task")
      );
      return window
        ? { bounds: window.getBounds(), url: window.webContents.getURL() }
        : undefined;
    });
    expect(taskRuntime?.url).toContain("workspaceId=wsp_e2e");
    const taskDialog = taskWindow.getByRole("dialog", { name: "Task chat" });
    // Entrance runs on the lightweight shell before hydration. The settled
    // dialog has no movement transition; dedicated entrance tests sample motion.
    expect(
      await taskWindow
        .locator(".comma-side-chat-test-window")
        .evaluate((element) => getComputedStyle(element, "::before").transform)
    ).toBe("none");
    const expectedTaskDialogWidth = Math.min(560, taskRuntime!.bounds.width - 80);
    const expectedTaskDialogHeight = Math.min(680, taskRuntime!.bounds.height - 80);
    await expect
      .poll(async () => (await taskDialog.boundingBox())?.width)
      .toBeCloseTo(expectedTaskDialogWidth, 0);
    await expect
      .poll(async () => (await taskDialog.boundingBox())?.height)
      .toBeCloseTo(expectedTaskDialogHeight, 0);
    const taskDialogBounds = await taskDialog.boundingBox();
    expect(taskDialogBounds).not.toBeNull();
    expect(taskDialogBounds!.width).toBeCloseTo(expectedTaskDialogWidth, 0);
    expect(taskDialogBounds!.height).toBeCloseTo(expectedTaskDialogHeight, 0);
    expect(taskDialogBounds!.x + taskDialogBounds!.width / 2).toBeCloseTo(
      taskRuntime!.bounds.width / 2,
      0
    );
    expect(taskDialogBounds!.y + taskDialogBounds!.height / 2).toBeCloseTo(
      taskRuntime!.bounds.height / 2,
      0
    );
    const taskComposer = taskWindow.locator(".comma-chat-composer");
    const taskComposerBounds = await taskComposer.boundingBox();
    expect(taskComposerBounds).not.toBeNull();
    expect(taskComposerBounds!.x - taskDialogBounds!.x).toBeCloseTo(19, 0);
    expect(
      taskDialogBounds!.x +
        taskDialogBounds!.width -
        taskComposerBounds!.x -
        taskComposerBounds!.width
    ).toBeCloseTo(19, 0);
    const taskComposerSurface = await taskComposer.evaluate((element) => {
      const style = window.getComputedStyle(element);
      const route = element.closest<HTMLElement>(".comma-chat-route");
      const routeStyle = route ? window.getComputedStyle(route) : undefined;
      return {
        background: style.backgroundColor,
        borderWidth: style.borderTopWidth,
        routeBackground: routeStyle?.backgroundColor ?? "",
        routePaddingLeft: routeStyle?.paddingLeft ?? "",
        routePaddingRight: routeStyle?.paddingRight ?? "",
      };
    });
    expect(taskComposerSurface.borderWidth).toBe("1px");
    expect(taskComposerSurface.background).not.toBe("rgba(0, 0, 0, 0)");
    expect(taskComposerSurface.background).not.toBe(
      taskComposerSurface.routeBackground
    );
    expect(taskComposerSurface.routePaddingLeft).toBe("18px");
    expect(taskComposerSurface.routePaddingRight).toBe("18px");
    const taskChatArtifactPath = testInfo.outputPath("side-chat-task-window.png");
    await taskWindow.screenshot({ animations: "disabled", path: taskChatArtifactPath });
    await testInfo.attach("side-chat-task-window", {
      contentType: "image/png",
      path: taskChatArtifactPath,
    });
    await taskWindow.getByRole("button", { name: "Close task chat" }).click();
    await expect(taskRoot).toHaveAttribute("data-expanded", "false");
    await expect(taskRoot).toHaveAttribute("data-transition-phase", "closing");
    await taskWindow.waitForTimeout(160);
    const collapsingTaskStyle = await taskDialog.evaluate((element) => {
      const style = window.getComputedStyle(element);
      return {
        opacity: Number.parseFloat(style.opacity),
        radius: Number.parseFloat(style.borderTopLeftRadius),
      };
    });
    expect(collapsingTaskStyle.opacity).toBeGreaterThan(0);
    expect(collapsingTaskStyle.opacity).toBeLessThan(1);
    // The shell transform scales the fixed-radius dialog during exit.
    expect(collapsingTaskStyle.radius).toBe(20);
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows().some((candidate) =>
            candidate.webContents.getURL().includes("conversationId=cnv_e2e_task")
          )
        )
      )
      .toBe(true);
    await expect
      .poll(async () => {
        if (taskWindow.isClosed()) return 0;
        return taskDialog
          .evaluate((element) =>
            Number.parseFloat(window.getComputedStyle(element).opacity)
          )
          .catch(() => 0);
      })
      .toBeLessThanOrEqual(0.01);
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows().some((candidate) =>
            candidate.webContents.getURL().includes("conversationId=cnv_e2e_task")
          )
        )
      )
      .toBe(false);

    await sideChatWindow.evaluate(async (input) => {
      const rendererWindow = window as Window & {
        commaNative?: {
          sideChat?: {
            openTestWindow?: (value: { sourceFrame: typeof input }) => Promise<unknown>;
          };
        };
      };
      await rendererWindow.commaNative?.sideChat?.openTestWindow?.({
        sourceFrame: input,
      });
    }, sourceFrame);
    const reopenedTestWindow = await findWindowByNativeRole(
      app,
      "side-chat-test-window"
    );
    await expect(
      reopenedTestWindow.getByRole("dialog", { name: "Side Chat diagnostics" })
    ).toBeVisible();
    await reopenedTestWindow.keyboard.press("Escape");
    await expect
      .poll(() =>
        app.evaluate(({ BrowserWindow }) =>
          BrowserWindow.getAllWindows().some((candidate) =>
            candidate.webContents.getURL().includes("#/side-chat/test-window")
          )
        )
      )
      .toBe(false);
    await expect
      .poll(() =>
        sideChatWindow.evaluate(async () => {
          const rendererWindow = window as Window & {
            commaNative?: {
              sideChat?: {
                presentation?: {
                  get?: () => Promise<{ phase: string; progress: number }>;
                };
              };
            };
          };
          const presentation =
            await rendererWindow.commaNative?.sideChat?.presentation?.get?.();
          return presentation
            ? { phase: presentation.phase, progress: presentation.progress }
            : undefined;
        })
      )
      .toEqual({ phase: "open", progress: 1 });

    await sideChatWindow.evaluate(async (input) => {
      const rendererWindow = window as Window & {
        commaNative?: {
          sideChat?: {
            openTestWindow?: (value: { sourceFrame: typeof input }) => Promise<unknown>;
          };
        };
      };
      const openTestWindow = rendererWindow.commaNative?.sideChat?.openTestWindow;
      if (!openTestWindow) throw new Error("openTestWindow is unavailable.");
      await Promise.all([
        openTestWindow({ sourceFrame: input }),
        openTestWindow({ sourceFrame: input }),
      ]);
    }, sourceFrame);
    await expect.poll(() => countSideChatTestWindows(app)).toBe(1);

    await app.evaluate(({ BrowserWindow }) => {
      const testWindows = BrowserWindow.getAllWindows().filter((candidate) =>
        candidate.webContents.getURL().includes("#/side-chat/test-window")
      );
      if (testWindows.length !== 1) {
        throw new Error(
          `Expected exactly one Side Chat Test window, found ${testWindows.length}.`
        );
      }
      testWindows[0]?.webContents.forcefullyCrashRenderer();
    });
    await expect.poll(() => countSideChatTestWindows(app)).toBe(0);
  } finally {
    await destroySideChatTestWindowsAndClose(app);
  }
});

interface SideChatVisibilityCall {
  at: number;
  kind: "show" | "showInactive";
  windowId: number;
}

async function installSideChatVisibilityProbe(app: ElectronApplication) {
  await app.evaluate(({ app: electronApp, BrowserWindow }) => {
    type ProbeGlobal = typeof globalThis & {
      commaSideChatVisibilityCallsForE2e?: SideChatVisibilityCall[];
    };
    const mainGlobal = globalThis as ProbeGlobal;
    const calls: SideChatVisibilityCall[] = [];
    const instrumented = new WeakSet<object>();
    mainGlobal.commaSideChatVisibilityCallsForE2e = calls;

    const record = (
      browserWindow: InstanceType<typeof BrowserWindow>,
      kind: SideChatVisibilityCall["kind"]
    ) => {
      const url = browserWindow.webContents.getURL();
      if (!url.includes("#/side-chat") || url.includes("#/side-chat/")) return;
      calls.push({ at: Date.now(), kind, windowId: browserWindow.id });
    };
    const instrument = (browserWindow: InstanceType<typeof BrowserWindow>) => {
      if (instrumented.has(browserWindow)) return;
      instrumented.add(browserWindow);
      const show = browserWindow.show.bind(browserWindow);
      const showInactive = browserWindow.showInactive.bind(browserWindow);
      browserWindow.show = () => {
        record(browserWindow, "show");
        show();
      };
      browserWindow.showInactive = () => {
        record(browserWindow, "showInactive");
        showInactive();
      };
    };

    for (const browserWindow of BrowserWindow.getAllWindows()) {
      instrument(browserWindow);
    }
    electronApp.on("browser-window-created", (_event, browserWindow) => {
      instrument(browserWindow);
    });
  });
}

async function readSideChatVisibilityCalls(app: ElectronApplication) {
  return app.evaluate(() => {
    const mainGlobal = globalThis as typeof globalThis & {
      commaSideChatVisibilityCallsForE2e?: SideChatVisibilityCall[];
    };
    return mainGlobal.commaSideChatVisibilityCallsForE2e ?? [];
  });
}

function readSlowCloseFixtureTiming(output: string) {
  const closeStartedAt = output.match(/close-received epoch=1 at=(\d+)/)?.[1];
  const staleClosedAt = output.match(/stale-closed-before-ack epoch=1 at=(\d+)/)?.[1];
  const staleOpeningAt = output.match(/stale-opening-before-ack epoch=1 at=(\d+)/)?.[1];
  const staleOpenAt = output.match(/stale-open-before-ack epoch=1 at=(\d+)/)?.[1];
  const causalReleaseAt = output.match(
    /causal-release-layout-received epoch=1 at=(\d+)/
  )?.[1];
  const closeAcknowledgedAt = output.match(/close-ack-emitted epoch=1 at=(\d+)/)?.[1];
  const closingFrameAts = [
    ...output.matchAll(/closing-positive-after-ack epoch=1 at=(\d+)/g),
  ].flatMap((match) => (match[1] ? [Number(match[1])] : []));
  const postAckInteractiveAt = output.match(
    /post-ack-interactive-interference epoch=1 at=(\d+)/
  )?.[1];
  const postAckOpenAt = output.match(
    /post-ack-open-interference epoch=1 at=(\d+)/
  )?.[1];
  const closedAt = output.match(/closed-emitted epoch=1 at=(\d+)/)?.[1];
  const reopenReceivedAt = output.match(
    /reopen-received-after-final epoch=1 at=(\d+)/
  )?.[1];
  if (
    !closeStartedAt ||
    !staleClosedAt ||
    !staleOpeningAt ||
    !staleOpenAt ||
    !causalReleaseAt ||
    !closeAcknowledgedAt ||
    closingFrameAts.length < 3 ||
    !postAckInteractiveAt ||
    !postAckOpenAt ||
    !closedAt ||
    !reopenReceivedAt
  ) {
    return undefined;
  }
  return {
    causalReleaseAt: Number(causalReleaseAt),
    closedAt: Number(closedAt),
    closeAcknowledgedAt: Number(closeAcknowledgedAt),
    closeStartedAt: Number(closeStartedAt),
    closingFrameAts,
    postAckInteractiveAt: Number(postAckInteractiveAt),
    postAckOpenAt: Number(postAckOpenAt),
    reopenReceivedAt: Number(reopenReceivedAt),
    staleClosedAt: Number(staleClosedAt),
    staleOpenAt: Number(staleOpenAt),
    staleOpeningAt: Number(staleOpeningAt),
  };
}

async function countSideChatTestWindows(app: ElectronApplication) {
  return app.evaluate(
    ({ BrowserWindow }) =>
      BrowserWindow.getAllWindows().filter((candidate) =>
        candidate.webContents.getURL().includes("#/side-chat/test-window")
      ).length
  );
}

async function persistentSideChatWindowState(app: ElectronApplication) {
  return app.evaluate(({ BrowserWindow }) => {
    const windows = BrowserWindow.getAllWindows().filter((candidate) => {
      const url = candidate.webContents.getURL();
      return url.includes("#/side-chat") && !url.includes("#/side-chat/");
    });
    return {
      count: windows.length,
      visible: windows.some((window) => window.isVisible()),
    };
  });
}

async function readSideChatPresentation(sideChatWindow: Page) {
  return sideChatWindow.evaluate(async () => {
    const rendererWindow = window as Window & {
      commaNative?: {
        sideChat?: {
          presentation?: {
            get?: () => Promise<{ phase: string; progress: number }>;
          };
        };
      };
    };
    const presentation =
      await rendererWindow.commaNative?.sideChat?.presentation?.get?.();
    return presentation
      ? { phase: presentation.phase, progress: presentation.progress }
      : undefined;
  });
}

function expectMonotonic(values: number[], direction: "increasing" | "decreasing") {
  for (let index = 1; index < values.length; index += 1) {
    const previous = values[index - 1]!;
    const current = values[index]!;
    if (direction === "increasing") {
      expect(
        current,
        `Expected ${direction} frames: ${values.join(", ")}`
      ).toBeGreaterThanOrEqual(previous - 0.1);
    } else {
      expect(
        current,
        `Expected ${direction} frames: ${values.join(", ")}`
      ).toBeLessThanOrEqual(previous + 0.1);
    }
  }
}

async function destroySideChatTestWindowsAndClose(app: ElectronApplication) {
  await app
    .evaluate(({ BrowserWindow }) => {
      for (const window of BrowserWindow.getAllWindows()) {
        if (window.webContents.getURL().includes("#/side-chat/test-window")) {
          window.destroy();
        }
      }
    })
    .catch(() => undefined);

  const electronProcess = app.process();
  const forceKill = () => {
    if (electronProcess.exitCode !== null) return;
    try {
      electronProcess.kill("SIGKILL");
    } catch {
      // The process may exit between the exitCode check and the signal.
    }
  };
  let forceKillTimer: ReturnType<typeof setTimeout> | undefined;
  const closeAttempt = app.close().catch(forceKill);
  await Promise.race([
    closeAttempt,
    new Promise<void>((finishTimeout) => {
      forceKillTimer = setTimeout(() => {
        forceKill();
        finishTimeout();
      }, 5_000);
    }),
  ]);
  if (forceKillTimer) clearTimeout(forceKillTimer);
}

const updateBridgeVersion = "0.0.2-staging.e2e";

type AutomaticUpdateCalls = {
  apply: number;
  check: number;
  download: number;
  status: number;
};

type UpdateBridgeRendererWindow = Window & {
  commaAutomaticUpdateCalls?: AutomaticUpdateCalls;
  commaNative: {
    updates: {
      apply(update: unknown): Promise<boolean>;
      check(): Promise<unknown>;
      download(update: unknown): Promise<boolean>;
      status(): Promise<unknown>;
    };
  };
};

// Counts every updater bridge call the renderer makes, so a test can assert on
// the check that never ran as precisely as on the one that did.
async function installUpdateBridgeMock(app: ElectronApplication) {
  await app.context().addInitScript(
    ({ version }) => {
      const rendererWindow = window as UpdateBridgeRendererWindow;
      const targetRelease = {
        PackageId: "comma-staging",
        Version: version,
        Type: "Full",
        FileName: `comma-staging-${version}-full.nupkg`,
        SHA1: "e2e-sha1",
        SHA256: "e2e-sha256",
        Size: 1024,
        NotesMarkdown: "",
        NotesHtml: "",
      };
      const update = {
        TargetFullRelease: targetRelease,
        DeltasToTarget: [],
        IsDowngrade: false,
      };
      const calls: AutomaticUpdateCalls = {
        apply: 0,
        check: 0,
        download: 0,
        status: 0,
      };

      rendererWindow.commaAutomaticUpdateCalls = calls;
      rendererWindow.commaNative.updates = {
        async status() {
          calls.status += 1;
          return {
            configured: true,
            currentVersion: "0.0.1-staging.e2e",
            productName: "Comma Staging",
          };
        },
        async check() {
          calls.check += 1;
          return update;
        },
        async download() {
          calls.download += 1;
          return true;
        },
        async apply() {
          calls.apply += 1;
          return true;
        },
      };
    },
    { version: updateBridgeVersion }
  );
}

function readAutomaticUpdateCalls(page: Page) {
  return page.evaluate(
    () => (window as UpdateBridgeRendererWindow).commaAutomaticUpdateCalls
  );
}

test("main renderer downloads an available update once and offers restart", async () => {
  // A healthy chat keeps the stack to a single card. These assertions are about
  // where the update toast sits, not about how a stack of toasts collapses.
  const chatStub = await startChatSmokeStub({ sessionEmail: SHELL_E2E_EMAIL });
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnv({ apiBaseUrl: chatStub.baseUrl }),
  });

  try {
    const appWindow = await findWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await expect(
      appWindow.getByRole("complementary", { name: "App sidebar" })
    ).toBeVisible();

    await installUpdateBridgeMock(app);

    // Reload after installing the init script so the mock is present before the
    // React root mounts and starts its once-per-launch update check.
    await appWindow.reload();
    await appWindow.waitForLoadState("domcontentloaded");

    await expect(appWindow.getByText("Update ready")).toBeVisible();
    await expect(
      appWindow.getByText(
        `Comma Staging ${updateBridgeVersion} has been downloaded. Restart to finish installing.`
      )
    ).toBeVisible();

    // The stack lives in this window and hugs its own bottom-right corner.
    const toaster = appWindow.locator("[data-sonner-toaster]");
    await expect(toaster).toHaveAttribute("data-y-position", "bottom");
    await expect(toaster).toHaveAttribute("data-x-position", "right");
    // Playwright injects renderer mouse events below, bypassing macOS's native
    // draggable-region hit test. Preserve the native clickability contract
    // explicitly so a visible action cannot become window-drag chrome again.
    await expect
      .poll(() =>
        toaster.evaluate((list) =>
          getComputedStyle(list).getPropertyValue("-webkit-app-region")
        )
      )
      .toBe("no-drag");
    // Nothing may clip the card or its shadow: the stack is a viewport-fixed
    // sibling of the shell, inset from the window edges on both axes.
    expect(
      await toaster.evaluate((list) => {
        const { bottom, right } = list.getBoundingClientRect();
        return {
          bottomGap: Math.round(window.innerHeight - bottom),
          rightGap: Math.round(window.innerWidth - right),
        };
      })
    ).toEqual({ bottomGap: 24, rightGap: 24 });

    // Comma supports a 500px main window, inside sonner's <=600px mobile
    // breakpoint. The visible card must keep the same bottom-right contract
    // there rather than inheriting sonner's full-width, left-aligned mobile row.
    await app.evaluate(({ BrowserWindow }) => {
      const mainWindow = BrowserWindow.getAllWindows().find((candidate) => {
        const url = candidate.webContents.getURL();
        return url.length > 0 && new URL(url).hash === "";
      });
      if (!mainWindow) throw new Error("Main Electron window is unavailable.");
      mainWindow.setContentSize(500, 640);
    });
    await expect.poll(() => appWindow.evaluate(() => window.innerWidth)).toBe(500);
    const updateToast = appWindow.locator("output").filter({ hasText: "Update ready" });
    await expect(updateToast).toHaveCount(1);
    await expect
      .poll(() =>
        updateToast.evaluate((card) => {
          const { bottom, right } = card.getBoundingClientRect();
          return {
            bottomGap: Math.round(window.innerHeight - bottom),
            rightGap: Math.round(window.innerWidth - right),
          };
        })
      )
      .toEqual({ bottomGap: 24, rightGap: 24 });

    await app.evaluate(({ BrowserWindow }) => {
      const mainWindow = BrowserWindow.getAllWindows().find((candidate) => {
        const url = candidate.webContents.getURL();
        return url.length > 0 && new URL(url).hash === "";
      });
      if (!mainWindow) throw new Error("Main Electron window is unavailable.");
      mainWindow.setContentSize(1_440, 1_024);
    });
    await expect.poll(() => appWindow.evaluate(() => window.innerWidth)).toBe(1_440);
    await expect
      .poll(() => readAutomaticUpdateCalls(appWindow))
      .toEqual({
        apply: 0,
        check: 1,
        download: 1,
        status: 1,
      });

    const [secondaryWindow] = await Promise.all([
      app.waitForEvent("window"),
      appWindow.evaluate(() =>
        (
          window as Window & {
            commaNative: {
              windows: { create(input: { route: string }): Promise<unknown> };
            };
          }
        ).commaNative.windows.create({ route: "/" })
      ),
    ]);
    await secondaryWindow.waitForLoadState("domcontentloaded");
    await expect
      .poll(() => readAutomaticUpdateCalls(secondaryWindow))
      .toEqual({
        apply: 0,
        check: 0,
        download: 0,
        status: 0,
      });
    await expect(secondaryWindow.getByText("Update ready")).toHaveCount(0);
    await secondaryWindow.close();

    await appWindow.getByRole("button", { name: "Restart now" }).click();

    await expect
      .poll(async () => (await readAutomaticUpdateCalls(appWindow))?.apply)
      .toBe(1);
  } finally {
    await destroySideChatTestWindowsAndClose(app);
    await chatStub.close();
  }
});

test("login screen downloads the update without offering a restart", async () => {
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronTestEnv({ signedIn: false }),
  });

  try {
    const appWindow = await findWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();

    await installUpdateBridgeMock(app);
    await appWindow.reload();
    await appWindow.waitForLoadState("domcontentloaded");
    await expect(
      appWindow.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeVisible();

    // Downloading while the user types their password is the point: the release
    // is on disk by the time they are in. Only the restart offer waits for the
    // session, so it can never interrupt a sign-in.
    await expect
      .poll(() => readAutomaticUpdateCalls(appWindow))
      .toEqual({
        apply: 0,
        check: 1,
        download: 1,
        status: 1,
      });
    await expect(appWindow.getByText("Update ready")).toHaveCount(0);
  } finally {
    await destroySideChatTestWindowsAndClose(app);
  }
});
