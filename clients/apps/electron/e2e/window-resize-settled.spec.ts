import { type ElectronApplication, type Page } from "@playwright/test";
import { electron, electronTestDirectory, expect, test } from "./electron-test";
import { setElectronWindowBounds } from "./electron-operations";
import { startElectronTestServer } from "./electron-test-server";
import { resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";
import { closeElectronTestApp } from "./close-electron-test-app";

async function startBrowserStub() {
  const server = await startElectronTestServer((_request, response) => {
    response.writeHead(200, { "content-type": "text/html" });
    response.end(`<!doctype html><title>stub</title><body style="margin:0">stub`);
  });
  return { baseUrl: server.origin, close: server.close };
}

// The product shell, not the dev workbench.
const mainWindowUrl = "assets://./";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

let userDataDir = "";

test.beforeEach(async () => {
  userDataDir = await electronTestDirectory("comma-window-resize-settled-");
});

const mainWindow = (app: ElectronApplication) =>
  app.evaluateHandle(
    ({ BrowserWindow }, url) =>
      BrowserWindow.getAllWindows().find(
        (window) => window.webContents.getURL() === url
      )!,
    mainWindowUrl
  );

/** The macOS animated resize, as a drag of the window's edge moves it. */
const resizeMainWindow = async (
  app: ElectronApplication,
  width: number,
  height: number
) =>
  setElectronWindowBounds(
    app,
    await mainWindow(app),
    { height, width },
    { animate: true }
  );

const waitForStableChatColumn = (
  appWindow: Page,
  expectedWidth: number,
  stableForMs = 250
) =>
  appWindow.evaluate(
    async ({ expectedWidth: width, stableForMs: duration }) => {
      const timeoutMs = 5_000;
      const startedAt = performance.now();
      let lastWidth = -1;
      let stableSince: number | undefined;

      await new Promise<void>((finish, reject) => {
        const sample = (now: number) => {
          const column = document.querySelector(".comma-chat-column");
          lastWidth = column ? Math.round(column.getBoundingClientRect().width) : -1;

          if (lastWidth === width) {
            stableSince ??= now;
          } else {
            stableSince = undefined;
          }

          if (stableSince !== undefined && now - stableSince >= duration) {
            finish();
            return;
          }
          if (now - startedAt >= timeoutMs) {
            reject(
              new Error(
                `Chat column did not remain at ${width}px for ${duration}ms; last width was ${lastWidth}px.`
              )
            );
            return;
          }
          requestAnimationFrame(sample);
        };

        requestAnimationFrame(sample);
      });
    },
    { expectedWidth, stableForMs }
  );

// Only Main can tell a released window edge from a pause with the button still
// down, so the shell settles layouts on this rather than on a renderer timer.
// If the platform stops reporting it, the settle silently never runs.
test(
  "main reports the end of a window resize to its renderer",
  { tag: "@shared-app" },
  async ({ sharedElectron: { app, mainWindow: appWindow } }) => {
    {
      await appWindow.evaluate(() => {
        const bridge = (
          window as Window & {
            commaNative?: {
              surfaces?: {
                onWindowResizeSettled?: (
                  listener: (payload: { height: number; width: number }) => void
                ) => () => void;
              };
            };
          }
        ).commaNative;
        const received: { height: number; width: number }[] = [];
        (window as Window & { commaResizeSettled?: unknown }).commaResizeSettled =
          received;
        bridge?.surfaces?.onWindowResizeSettled?.((payload) => received.push(payload));
      });

      // Resize, then synthesize the end-of-resize event. Whether Cocoa emits
      // `resized` for a programmatic resize varies by macOS version (an
      // animated setBounds does on a desktop, does not on CI runner images) —
      // and Cocoa is not the contract under test. Ours is: when `resized`
      // fires, Main forwards the window's content size to that window's
      // renderer.
      const nativeWindow = await mainWindow(app);
      await setElectronWindowBounds(app, nativeWindow, { height: 820, width: 1180 });
      await nativeWindow.evaluate((window) => window.emit("resized"));

      await expect
        .poll(async () =>
          appWindow.evaluate(
            () =>
              (window as Window & { commaResizeSettled?: { width: number }[] })
                .commaResizeSettled ?? []
          )
        )
        .toHaveLength(1);

      const [settled] = await appWindow.evaluate(
        () =>
          (
            window as Window & {
              commaResizeSettled?: { height: number; width: number }[];
            }
          ).commaResizeSettled ?? []
      );
      const contentSize = await app.evaluate(({ BrowserWindow }, url) => {
        const target = BrowserWindow.getAllWindows().find(
          (window) => window.webContents.getURL() === url
        );
        const [width, height] = target?.getContentSize() ?? [];
        return { height, width };
      }, mainWindowUrl);
      expect(settled).toEqual(contentSize);
      expect(contentSize.width).toBe(1180);
    }
  }
);

// The Chat Sidebar's width is a function of the window: past the point where
// the product route reaches its minimum, the sidebar yields. Its 150ms width
// transition is suppressed for its own drag handle but used to stay on through
// a window drag, so every frame restarted a transition the next frame
// interrupted — the sidebar trailed the window edge, the native browser view
// pinned to its box trailed with it, and the chat column beside it re-wrapped
// on every frame of the chase.
// @mac: it resizes the window to 900 points tall; the mac-mini-ci VMs'
// display clamped it to 680, so the rails never reached their resting widths.
test(
  "a live window resize keeps the chat column steady while the sidebar yields",
  { tag: "@mac" },
  async () => {
    const browserStub = await startBrowserStub();
    const apiStub = await startChatSmokeStub({
      assistantReply: `[Open browser](${browserStub.baseUrl}/page)`,
    });
    recordElectronOnboardingCompleted(userDataDir, [apiStub.userId]);
    const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
    const app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: {
        ...hostEnv,
        COMMA_API_BASE_URL: apiStub.baseUrl,
        COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "window-resize@comma.local",
        COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "window-resize-session-token",
        NODE_ENV: "test",
      },
    });

    try {
      const appWindow = await findElectronWindowByNativeRole(app, "main-window");
      const content = appWindow.getByRole("region", { name: "Content" });
      const composer = content.locator(".comma-chat-composer");
      await composer
        .getByRole("textbox", { name: "AI prompt" })
        .fill("Open the browser");
      await composer.getByRole("button", { name: "Send" }).click();
      await content.getByRole("link", { name: "Open browser" }).click();
      const sidebar = content.getByTestId("chat-sidebar");
      await expect(sidebar).toHaveAttribute("data-open", "true");
      const viewportSlot = sidebar.locator(".comma-chat-sidebar-browser-viewport");
      await expect
        .poll(async () => (await viewportSlot.boundingBox())?.width ?? 0)
        .toBeGreaterThan(100);

      // Measure the shell only once the sidebar has reached its content width.
      await expect
        .poll(() =>
          sidebar.evaluate(
            (element) =>
              Math.round(element.getBoundingClientRect().width) - element.scrollWidth
          )
        )
        .toBe(0);

      // Derive a resting window in Greeting's reflow interval from the current
      // layout, so changes to the rail floor do not invalidate this scenario.
      const initialWidth = await appWindow.evaluate(() => {
        const layout = document.querySelector<HTMLElement>(".comma-home-layout")!;
        const style = getComputedStyle(layout);
        const railMinimum = Number.parseFloat(
          style.getPropertyValue("--comma-home-rail-min")
        );
        const railPreferred = Number.parseFloat(
          style.getPropertyValue("--comma-home-greet-preferred")
        );
        const chatMinimum = Number.parseFloat(
          style.getPropertyValue("--comma-home-chat-min")
        );
        const gutter = Number.parseFloat(style.getPropertyValue("--spacing-xl"));
        const routeWidth =
          Number.parseFloat(style.paddingLeft) +
          Number.parseFloat(style.paddingRight) +
          chatMinimum +
          gutter +
          (railMinimum + railPreferred) / 2;
        return Math.round(
          window.innerWidth - layout.getBoundingClientRect().width + routeWidth
        );
      });
      expect(Number.isFinite(initialWidth)).toBe(true);
      await resizeMainWindow(app, initialWidth, 900);
      await expect(content.getByTestId("home-greet-rail")).toHaveAttribute(
        "data-folded",
        "false"
      );
      await expect(content.getByTestId("home-tasks-rail")).toHaveAttribute(
        "data-folded",
        "true"
      );
      await expect
        .poll(() =>
          content
            .locator(".comma-home-chat")
            .evaluate((element) => Math.round(element.getBoundingClientRect().width))
        )
        .toBe(393);
      // The inner chat column excludes 48px padding; keep the exact 250ms
      // stability barrier before collecting any live-resize samples.
      await waitForStableChatColumn(appWindow, 345);
      const reflowMinimum = await appWindow.evaluate(() => {
        const layout = document.querySelector<HTMLElement>(".comma-home-layout")!;
        const style = getComputedStyle(layout);
        return (
          Number.parseFloat(style.paddingLeft) +
          Number.parseFloat(style.paddingRight) +
          Number.parseFloat(style.getPropertyValue("--comma-home-chat-min")) +
          Number.parseFloat(style.getPropertyValue("--spacing-xl")) +
          Number.parseFloat(style.getPropertyValue("--comma-home-rail-min"))
        );
      });
      expect(Number.isFinite(reflowMinimum)).toBe(true);

      // Sampled inside the page: the chase happened between frames, which a
      // round-trip read would step straight over. The sampler runs until the
      // test has seen the window settle, not for a fixed wall-clock budget.
      type ResizeSample = {
        bar: number;
        column: number;
        slot: number;
        route: number;
        viewport: number;
      };
      type ResizeProbe = Window & {
        commaResizeSamples?: ResizeSample[];
        commaStopResizeSamples?: () => void;
      };
      await appWindow.evaluate(() => {
        const probe = window as ResizeProbe;
        const samples: ResizeSample[] = [];
        probe.commaResizeSamples = samples;
        let running = true;
        probe.commaStopResizeSamples = () => {
          running = false;
        };
        const tick = () => {
          const column = document.querySelector(".comma-chat-column");
          const slot = document.querySelector(".comma-chat-sidebar-browser-viewport");
          const bar = document.querySelector(".comma-chat-sidebar");
          samples.push({
            bar: bar ? Math.round(bar.getBoundingClientRect().width) : -1,
            column: column ? Math.round(column.getBoundingClientRect().width) : -1,
            slot: slot ? Math.round(slot.getBoundingClientRect().width) : -1,
            route:
              document.querySelector(".comma-home-layout")?.getBoundingClientRect()
                .width ?? -1,
            viewport: window.innerWidth,
          });
          if (running) requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      });
      const sampleCount = () =>
        appWindow.evaluate(
          () => (window as ResizeProbe).commaResizeSamples?.length ?? 0
        );

      // Frames at the resting width come first, so the interval above the fold
      // is sampled before the window starts to move.
      await expect.poll(sampleCount).toBeGreaterThan(10);
      // At 700px the route has reached its minimum and the sidebar must
      // yield more than 100px. Sample through the whole native animation.
      expect((await resizeMainWindow(app, 700, 900)).bounds.width).toBe(700);
      const settledViewport = await app.evaluate(
        ({ BrowserWindow }, url) =>
          BrowserWindow.getAllWindows()
            .find((window) => window.webContents.getURL() === url)!
            .getContentSize()[0]!,
        mainWindowUrl
      );
      // The renderer has painted a frame at the window's final width.
      await expect
        .poll(() =>
          appWindow.evaluate(
            (width) =>
              (window as ResizeProbe).commaResizeSamples?.some(
                (sample) => sample.viewport === width
              ) ?? false,
            settledViewport
          )
        )
        .toBe(true);

      const samples = await appWindow.evaluate(() => {
        const probe = window as ResizeProbe;
        probe.commaStopResizeSamples?.();
        return probe.commaResizeSamples ?? [];
      });
      // The sidebar really did have to yield across the whole drag.
      expect(Math.min(...samples.map((sample) => sample.bar))).toBeLessThan(
        Math.max(...samples.map((sample) => sample.bar)) - 100
      );
      // rAF observes layout before ResizeObserver necessarily publishes data-folded.
      // Select the original above-threshold interval from synchronous geometry,
      // not a fold marker that can still describe the previous window width.
      await test.info().attach("window-resize-geometry", {
        body: JSON.stringify({ reflowMinimum, samples }),
        contentType: "application/json",
      });
      const aboveFold = samples.filter((sample) => sample.route >= reflowMinimum);
      expect(aboveFold.length).toBeGreaterThan(10);
      expect([...new Set(aboveFold.map((sample) => sample.column))]).toEqual([345]);

      // The native browser view ends where its slot is, so the page inside it
      // reflows to the width the window actually left it.
      const nativeWidth = () =>
        app.evaluate(({ BrowserWindow }) => {
          const win = BrowserWindow.getAllWindows().find(
            (candidate) => candidate.webContents.getURL() === "assets://./"
          );
          const view = (win?.contentView.children ?? []).find((child) =>
            (child as { webContents?: { getURL(): string } }).webContents
              ?.getURL()
              .startsWith("http")
          ) as { getBounds(): { width: number } } | undefined;
          return view?.getBounds().width ?? -1;
        });
      const slotWidth = () =>
        viewportSlot.evaluate((element) =>
          Math.round(element.getBoundingClientRect().width)
        );
      // The fold settles after the last frame of the move, and Main places the
      // view from the slot the renderer reports after that layout: read both
      // together until they agree.
      await expect
        .poll(async () => {
          const [native, slot] = await Promise.all([nativeWidth(), slotWidth()]);
          return native === slot ? "aligned" : `native ${native}px, slot ${slot}px`;
        })
        .toBe("aligned");
    } finally {
      await closeElectronTestApp(app);
      await apiStub.close();
      await browserStub.close();
    }
  }
);

// A narrow window squeezes the sidebar's rendered width — CSS clamps it to
// what the window leaves after the route's 425px minimum — but never its
// stored width, so widening the window must hand the user's chosen width
// straight back, not a ratcheted-down one.
test(
  "the Chat Sidebar returns to its own width once the window no longer needs it",
  { tag: "@shared-app" },
  async ({ sharedElectron: { app, mainWindow: appWindow, signIn, useApi } }) => {
    const browserStub = await startBrowserStub();
    const apiStub = await startChatSmokeStub({
      assistantReply: `[Open browser](${browserStub.baseUrl}/page)`,
    });

    try {
      useApi(apiStub.server);
      await signIn({ email: "sidebar-restore@comma.local", userId: apiStub.userId });
      const content = appWindow.getByRole("region", { name: "Content" });
      const composer = content.locator(".comma-chat-composer");
      await composer
        .getByRole("textbox", { name: "AI prompt" })
        .fill("Open the browser");
      await composer.getByRole("button", { name: "Send" }).click();
      await content.getByRole("link", { name: "Open browser" }).click();
      const sidebar = content.getByTestId("chat-sidebar");
      await expect(sidebar).toHaveAttribute("data-open", "true");

      const sidebarWidth = async () =>
        Math.round((await sidebar.boundingBox())?.width ?? 0);

      await resizeMainWindow(app, 1_900, 900);
      await expect.poll(sidebarWidth).toBe(440);

      // Narrow enough that the route hits its 425px floor. The app sidebar is a
      // fixed 68px rail that never yields, so the rendered width is clamped to
      // what the window leaves past the shell's trailing inset and the rail:
      // 900 - 8 - 68 - 425 = 399 (a 1100px window would still fit the stored
      // 440px beside the rail and clamp nothing).
      await resizeMainWindow(app, 900, 900);
      await expect.poll(sidebarWidth).toBe(399);

      await resizeMainWindow(app, 1_900, 900);
      await expect.poll(sidebarWidth).toBe(440);
    } finally {
      await apiStub.close();
      await browserStub.close();
    }
  }
);
