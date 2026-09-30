import {
  _electron as electron,
  expect,
  test,
  type ElectronApplication,
  type Page,
} from "@playwright/test";
import { createServer } from "node:http";
import { mkdtemp, rm } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

async function startBrowserStub() {
  const server = createServer((_request, response) => {
    response.writeHead(200, { "content-type": "text/html" });
    response.end(`<!doctype html><title>stub</title><body style="margin:0">stub`);
  });
  await new Promise<void>((listening) => server.listen(0, "127.0.0.1", listening));
  const { port } = server.address() as AddressInfo;
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    close: () => new Promise<void>((closed) => server.close(() => closed())),
  };
}

// The product shell, not the dev workbench or the Side Chat window — both of
// which also answer to "not side-chat" depending on creation order.
const mainWindowUrl = "assets://./";

const findMainWindow = async (app: ElectronApplication) => {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    for (const candidate of app.windows()) {
      if (candidate.url() === mainWindowUrl) return candidate;
    }
    await app.waitForEvent("window", { timeout: 1_000 }).catch(() => undefined);
  }
  throw new Error("Timed out waiting for the Electron main window.");
};

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

let userDataDir = "";

test.beforeEach(async () => {
  userDataDir = await mkdtemp(join(tmpdir(), "comma-window-resize-settled-"));
});

test.afterEach(async () => {
  if (userDataDir) await rm(userDataDir, { force: true, recursive: true });
});

const resizeMainWindow = (app: ElectronApplication, width: number, height: number) =>
  app.evaluate(
    ({ BrowserWindow }, size) => {
      const target = BrowserWindow.getAllWindows().find(
        (window) => window.webContents.getURL() === size.mainWindowUrl
      );
      const bounds = target?.getBounds();
      if (!target || !bounds) return;
      target.setBounds({ ...bounds, height: size.height, width: size.width }, true);
    },
    { height, mainWindowUrl, width }
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
test("viewport repair cannot resize the window during a paused native edge drag", async () => {
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: { ...env, NODE_ENV: "test" },
  });
  try {
    const page = await findMainWindow(app);
    await page.waitForLoadState("domcontentloaded");
    // Wait for the native window to appear before choosing a size that fits
    // the runner's work area. macOS can clamp the initial hidden 1024px height
    // during show(), independently of the viewport repair under test.
    await expect
      .poll(() =>
        app.evaluate(
          ({ BrowserWindow }, url) =>
            BrowserWindow.getAllWindows()
              .find((window) => window.webContents.getURL() === url)
              ?.isVisible(),
          mainWindowUrl
        )
      )
      .toBe(true);
    await app.evaluate(({ BrowserWindow }, url) => {
      BrowserWindow.getAllWindows()
        .find((window) => window.webContents.getURL() === url)
        ?.setContentSize(900, 700);
    }, mainWindowUrl);
    await expect
      .poll(() =>
        app.evaluate(
          ({ BrowserWindow }, url) =>
            BrowserWindow.getAllWindows()
              .find((window) => window.webContents.getURL() === url)
              ?.getContentSize(),
          mainWindowUrl
        )
      )
      .toEqual([900, 700]);
    const result = await app.evaluate(async ({ BrowserWindow }, url) => {
      const target = BrowserWindow.getAllWindows().find(
        (window) => window.webContents.getURL() === url
      );
      if (!target) throw new Error("Main window not found");
      const execute = target.webContents.executeJavaScript.bind(target.webContents);
      const setContentSize = target.setContentSize.bind(target);
      const calls: number[][] = [];
      const [width = 0, height = 0] = target.getContentSize();
      // Model Chromium's stale viewport while keeping the real BrowserWindow,
      // production event listeners and native size mutation path.
      target.webContents.executeJavaScript = ((code: string, gesture?: boolean) =>
        code === "[window.innerWidth, window.innerHeight]"
          ? Promise.resolve([width, height - 8])
          : execute(code, gesture)) as typeof target.webContents.executeJavaScript;
      target.setContentSize = (w, h, animate) => {
        calls.push([w, h]);
        setContentSize(w, h, animate);
      };
      try {
        // Programmatic sizing does not emit will-resize. Supply the native
        // drag lifecycle explicitly, as in the resize-settled transport test.
        target.emit("will-resize", {}, target.getBounds(), { edge: "bottom" });
        target.emit("resize");
        await new Promise((settled) => setTimeout(settled, 500));
        const duringDrag = calls.slice();
        target.emit("resized");
        await new Promise((settled) => setTimeout(settled, 400));
        return {
          duringDrag,
          afterRelease: calls,
          expected: [
            [width, height + 1],
            [width, height],
          ],
        };
      } finally {
        target.webContents.executeJavaScript = execute;
        target.setContentSize = setContentSize;
      }
    }, mainWindowUrl);
    expect(result.duringDrag).toEqual([]);
    expect(result.afterRelease).toEqual(result.expected);
  } finally {
    await app.close();
  }
});

test("main reports the end of a window resize to its renderer", async () => {
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: { ...env, NODE_ENV: "test" },
  });

  try {
    const appWindow = await findMainWindow(app);
    await appWindow.waitForLoadState("domcontentloaded");

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
    await app.evaluate(({ BrowserWindow }, url) => {
      const target = BrowserWindow.getAllWindows().find(
        (window) => window.webContents.getURL() === url
      );
      const bounds = target?.getBounds();
      if (!target || !bounds) return;
      target.setBounds({ ...bounds, height: 820, width: 1180 });
      target.emit("resized");
    }, mainWindowUrl);

    await expect
      .poll(
        async () =>
          appWindow.evaluate(
            () =>
              (window as Window & { commaResizeSettled?: { width: number }[] })
                .commaResizeSettled ?? []
          ),
        { timeout: 15_000 }
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
  } finally {
    await app.close();
  }
});

// The Chat Sidebar's width is a function of the window: past the point where
// the product route reaches its minimum, the sidebar yields. Its 150ms width
// transition is suppressed for its own drag handle but used to stay on through
// a window drag, so every frame restarted a transition the next frame
// interrupted — the sidebar trailed the window edge, the native browser view
// pinned to its box trailed with it, and the chat column beside it re-wrapped
// on every frame of the chase.
test("a live window resize keeps the chat column steady while the sidebar yields", async () => {
  test.setTimeout(180_000);
  const browserStub = await startBrowserStub();
  const apiStub = await startChatSmokeStub({
    assistantReply: `[Open browser](${browserStub.baseUrl}/page)`,
  });
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
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("Open the browser");
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
    // round-trip read would step straight over.
    await appWindow.evaluate(() => {
      const probe = window as Window & { commaResizeSamples?: unknown[] };
      const samples: {
        bar: number;
        column: number;
        slot: number;
        route: number;
      }[] = [];
      probe.commaResizeSamples = samples;
      const until = performance.now() + 5_000;
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
        });
        if (performance.now() < until) requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });

    await new Promise((settled) => setTimeout(settled, 900));
    // At 700px the route has reached its minimum and the sidebar must
    // yield more than 100px. Sample through the whole native animation.
    await resizeMainWindow(app, 700, 900);
    await new Promise((settled) => setTimeout(settled, 2_000));

    const samples = await appWindow.evaluate(
      () =>
        (
          window as Window & {
            commaResizeSamples?: {
              bar: number;
              column: number;
              slot: number;
              route: number;
            }[];
          }
        ).commaResizeSamples ?? []
    );
    expect(samples.length).toBeGreaterThan(30);
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
    const nativeWidth = await app.evaluate(({ BrowserWindow }) => {
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
    const slotWidth = await viewportSlot.evaluate((element) =>
      Math.round(element.getBoundingClientRect().width)
    );
    expect(nativeWidth).toBe(slotWidth);
  } finally {
    await app.close();
    await apiStub.close();
    await browserStub.close();
  }
});

// A narrow window squeezes the sidebar's rendered width — CSS clamps it to
// what the window leaves after the route's 425px minimum — but never its
// stored width, so widening the window must hand the user's chosen width
// straight back, not a ratcheted-down one.
test("the Chat Sidebar returns to its own width once the window no longer needs it", async () => {
  test.setTimeout(180_000);
  const browserStub = await startBrowserStub();
  const apiStub = await startChatSmokeStub({
    assistantReply: `[Open browser](${browserStub.baseUrl}/page)`,
  });
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...hostEnv,
      COMMA_API_BASE_URL: apiStub.baseUrl,
      COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "sidebar-restore@comma.local",
      COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "sidebar-restore-session-token",
      NODE_ENV: "test",
    },
  });

  try {
    const appWindow = await findElectronWindowByNativeRole(app, "main-window");
    const content = appWindow.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("Open the browser");
    await composer.getByRole("button", { name: "Send" }).click();
    await content.getByRole("link", { name: "Open browser" }).click();
    const sidebar = content.getByTestId("chat-sidebar");
    await expect(sidebar).toHaveAttribute("data-open", "true");

    const sidebarWidth = async () =>
      Math.round((await sidebar.boundingBox())?.width ?? 0);

    await resizeMainWindow(app, 1_900, 900);
    await expect.poll(sidebarWidth, { timeout: 15_000 }).toBe(440);

    // Narrow enough that the route hits its 425px floor. The app sidebar is a
    // fixed 75px rail that never yields, so the rendered width is clamped to
    // what the window leaves past the shell's trailing inset and the rail:
    // 900 - 8 - 75 - 425 = 392 (a 1100px window would still fit the stored
    // 440px beside the rail and clamp nothing).
    await resizeMainWindow(app, 900, 900);
    await expect.poll(sidebarWidth, { timeout: 15_000 }).toBe(392);

    await resizeMainWindow(app, 1_900, 900);
    await expect.poll(sidebarWidth, { timeout: 15_000 }).toBe(440);
  } finally {
    await app.close();
    await apiStub.close();
    await browserStub.close();
  }
});
