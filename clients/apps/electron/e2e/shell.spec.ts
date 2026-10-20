import { closeElectronTestApp } from "./close-electron-test-app";
import { expect } from "../../../e2e/helpers/native-expect";
import { type Locator, type Page } from "@playwright/test";
import { electron, test } from "./electron-test";
import {
  setElectronNativeTheme,
  setElectronWindowContentSize,
  setElectronWindowFullScreen,
} from "./electron-operations";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole as findWindowByNativeRole } from "../src/test-support/electron-native-window";
import { findElectronWindowByRole } from "../src/test-support/electron-window";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const SHELL_E2E_TOKEN = "comma_sess_shell_e2e";
const SHELL_E2E_EMAIL = "shell-e2e@example.com";

interface ElectronTestEnvOptions {
  apiBaseUrl?: string;
  signedIn?: boolean;
}

function electronTestEnv({ apiBaseUrl, signedIn = true }: ElectronTestEnvOptions = {}) {
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
        .getByTestId("comma-window-bar")
        .getByRole("button", { exact: true, name: "New tab" })
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
      const starter = Boolean(routeOutlet?.querySelector('[data-testid="chat-empty"]'));
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
  // Every stub here signs the shell account in.
  recordElectronOnboardingCompleted(userDataDir, [shellSessionStub.userId]);
});

test(
  "electron keeps native window backing aligned with Comma appearance while signed out",
  { tag: "@shared-app" },
  async ({ sharedElectron: { app, mainWindow: appWindow } }) => {
    try {
      await expect(
        appWindow.getByRole("heading", { name: "Welcome to Comma" })
      ).toBeVisible();

      await setElectronNativeTheme(app, "light");

      await appWindow.evaluate(() =>
        window.commaNative!.appPreferences.update({
          clientSettings: { appearance: { theme: "dark" } },
        })
      );
      await expect(appWindow.locator("html")).toHaveAttribute(
        "data-theme",
        "Dark mode"
      );
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

      await setElectronNativeTheme(app, "dark");
      await appWindow.evaluate(() =>
        window.commaNative!.appPreferences.update({
          clientSettings: { appearance: { theme: "light" } },
        })
      );
      await expect(appWindow.locator("html")).toHaveAttribute(
        "data-theme",
        "Light mode"
      );
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
      // The theme the test set stands in for the operating system's: the app does not own it.
      await setElectronNativeTheme(app, "system");
    }
  }
);

test.afterEach(async () => {
  await rm(userDataDir, { recursive: true, force: true });
});

test("electron Appearance lists installed font families", { tag: "@mac" }, async () => {
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
    await expect.poll(() => options.count()).toBeGreaterThan(1);
    expect((await options.nth(1).textContent()) ?? "").not.toBe("");
  } finally {
    await closeElectronTestApp(app);
  }
});

test(
  "electron shell exposes the isolated bridge and native surfaces",
  { tag: "@shared-app" },
  async ({ sharedElectron: { mainWindow: appWindow, signIn, useApi } }) => {
    useApi(shellSessionStub.server);
    await signIn({ email: SHELL_E2E_EMAIL, userId: shellSessionStub.userId });
    {
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

        const toggle = appWindow
          .getByTestId("comma-window-bar")
          .getByRole("button", { name: "New tab" });
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
                .elementFromPoint(
                  rect.left + rect.width / 2,
                  rect.top + rect.height / 2
                )
                ?.closest("button");
              const content = document.querySelector(".comma-content")!;
              return {
                appRegion:
                  getComputedStyle(button).getPropertyValue("-webkit-app-region"),
                contentDragStrip: getComputedStyle(content, "::before").content,
                inContent: button.closest(".comma-content") !== null,
                inWindowBar:
                  button.closest('[data-testid="comma-window-bar"]') !== null,
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
    }
  }
);

test(
  "electron window bar gives the traffic-light slot back in full screen",
  { tag: "@mac" },
  async () => {
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
        setElectronWindowFullScreen(app, appWindow, fullScreen);

      await expect(slot).toHaveCount(1);
      const windowedInset = await readBackInset();
      expect(windowedInset).toBeGreaterThan(64);

      // macOS hides the lights in full screen, so history takes their place at
      // the trailing flank's inset; leaving restores the slot.
      await setFullScreen(true);
      await expect(slot).toHaveCount(0);
      await expect.poll(readBackInset).toBe(12);

      await setFullScreen(false);
      await expect(slot).toHaveCount(1);
      await expect.poll(readBackInset).toBe(windowedInset);
    } finally {
      await closeElectronTestApp(app);
    }
  }
);

test(
  "electron Settings returns to the canonical Home on its first painted frame",
  { tag: "@shared-app" },
  async ({ sharedElectron: { app, mainWindow: appWindow, signIn, useApi } }) => {
    const chatStub = await startChatSmokeStub({
      sessionEmail: SHELL_E2E_EMAIL,
      workspaceChatDelayMs: 350,
    });

    try {
      useApi(chatStub.server);
      await signIn({ email: SHELL_E2E_EMAIL, userId: chatStub.userId });
      await setElectronWindowContentSize(app, appWindow, { width: 1_600, height: 900 });

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
        appWindow
          .getByTestId("comma-window-bar")
          .getByRole("button", { exact: true, name: "New tab" })
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
      await chatStub.close();
    }
  }
);

test(
  "electron CSP permits the authenticated blob avatar to load",
  { tag: "@shared-app" },
  async ({ sharedElectron: { mainWindow: appWindow, signIn, useApi } }) => {
    useApi(shellSessionStub.server);
    await signIn({ email: SHELL_E2E_EMAIL, userId: shellSessionStub.userId });
    {
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
    }
  }
);
