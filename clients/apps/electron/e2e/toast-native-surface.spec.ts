import { _electron as electron, expect, test } from "@playwright/test";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

// The sidebar browser is a `WebContentsView`, which the compositor paints above
// the renderer's entire DOM — a toast at the window's bottom-right corner is
// covered by it outright, at any z-index. Only a real Electron window can prove
// the stack steps clear of it, so this case measures both boxes in the live app.
test("a toast raised behind the sidebar browser lands clear of the native view", async () => {
  test.setTimeout(120_000);
  const browserStub = await startBrowserStub();
  const apiStub = await startChatSmokeStub({
    assistantReply: `[Open browser](${browserStub.baseUrl}/page)`,
  });
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-toast-native-surface-e2e-"));
  recordElectronOnboardingCompleted(userDataDir, [apiStub.userId]);
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...hostEnv,
      COMMA_API_BASE_URL: apiStub.baseUrl,
      COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "toast-native-surface@comma.local",
      COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "toast-native-surface-session-token",
      NODE_ENV: "test",
    },
  });
  let appClosed = false;

  try {
    const appWindow = await findElectronWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    const content = appWindow.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer
      .getByRole("textbox", { name: "AI prompt" })
      .fill("Open the browser sidebar");
    await composer.getByRole("button", { name: "Send" }).click();
    await content.getByRole("link", { name: "Open browser" }).click();

    const sidebar = content.getByTestId("chat-sidebar");
    await expect(sidebar).toHaveAttribute("data-open", "true");
    // The toolbar only leaves its disabled state once Main reports the view
    // active, which is also when it starts covering the window's right edge.
    await expect(sidebar.getByRole("button", { name: "Reload" })).toBeEnabled();

    // A rejected address raises the browser's own persistent error toast — the
    // toast this bug hid behind the very view that produced it.
    const address = sidebar.getByRole("textbox", { name: "Address" });
    await address.fill("ftp://example.com");
    await address.press("Enter");
    const errorToast = appWindow.getByTestId("browser-error");
    await expect(errorToast).toBeVisible();

    const geometry = () =>
      appWindow.evaluate(() => {
        const card = document.querySelector<HTMLElement>(
          '[data-testid="browser-error"]'
        );
        const view = document.querySelector<HTMLElement>(
          ".comma-chat-sidebar-browser-viewport"
        );
        // At the 500px supported shell width, the app rail/sidebar clamps can
        // re-render between Electron committing window.innerWidth and React
        // remounting the active browser panel. Report presence as part of the
        // polled contract instead of throwing before the layout can settle.
        const toast = card?.getBoundingClientRect();
        const native = view?.getBoundingClientRect();
        return {
          // Published on the toast host, not the document root (see
          // `toastObstruction`), so the stack alone re-resolves per frame.
          claim:
            document
              .querySelector<HTMLElement>('[data-slot="toast-host"]')
              ?.style.getPropertyValue("--comma-toast-obstruction-right") ?? "",
          hasNativeViewport: Boolean(view),
          hasToast: Boolean(card),
          innerWidth: window.innerWidth,
          nativeLeft: native ? Math.round(native.x) : null,
          nativeWidth: native ? Math.round(native.width) : 0,
          toastLeft: toast ? Math.round(toast.x) : null,
          toastRight: toast ? Math.round(toast.right) : null,
          toastWidth: toast ? Math.round(toast.width) : 0,
        };
      });
    const expectClearOfNativeView = async (label: string) => {
      try {
        await expect
          .poll(async () => {
            const box = await geometry();
            return {
              clearsNativeView:
                box.toastRight !== null &&
                box.nativeLeft !== null &&
                box.toastRight <= box.nativeLeft,
              hasNativeViewport: box.hasNativeViewport,
              hasToast: box.hasToast,
              insideWindow: box.toastLeft !== null && box.toastLeft >= 0,
              // Guards the two above from passing on a collapsed box.
              nativeViewShowing: box.nativeWidth >= 1,
              toastShowing: box.toastWidth >= 1,
            };
          })
          .toEqual({
            clearsNativeView: true,
            hasNativeViewport: true,
            hasToast: true,
            insideWindow: true,
            nativeViewShowing: true,
            toastShowing: true,
          });
      } catch (failure) {
        // Booleans alone are near-impossible to diagnose from a remote run:
        // whether the claim was never published or published and not applied
        // are different bugs, and only the numbers tell them apart.
        console.log(`toast placement at ${label}:`, JSON.stringify(await geometry()));
        throw failure;
      }
    };
    await expectClearOfNativeView("the default window");

    // Sonner swaps to a full-width row below 601px and stops honouring the
    // stack's right offset there, so the desktop measurement above proves
    // nothing about narrow windows. Checked at the breakpoint itself and again
    // at the 500px main window Comma supports. The stack settles at the same 24px
    // it keeps from the window's own edges; the assertion stays on "not
    // covered", which is the contract and cannot flake mid-resize.
    for (const width of [600, 500]) {
      await setContentSize(app, width, 800);
      await expect.poll(() => appWindow.evaluate(() => window.innerWidth)).toBe(width);
      await expectClearOfNativeView(`${width}px`);
    }

    await app.close();
    appClosed = true;
  } finally {
    if (!appClosed) await app.close();
    await apiStub.close();
    await browserStub.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});

async function setContentSize(
  app: Awaited<ReturnType<typeof electron.launch>>,
  width: number,
  height: number
) {
  await app.evaluate(
    ({ BrowserWindow }, size) => {
      const mainWindow = BrowserWindow.getAllWindows().find((candidate) => {
        const url = candidate.webContents.getURL();
        return url.length > 0 && new URL(url).hash === "";
      });
      if (!mainWindow) throw new Error("Main Electron window is unavailable.");
      mainWindow.setContentSize(size.width, size.height);
    },
    { height, width }
  );
}

async function startBrowserStub() {
  const server = createServer((request, response) => {
    const path = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
    response.writeHead(200, { "content-type": "text/html" });
    response.end(`<!doctype html><title>${path}</title><p>${path}</p>`);
  });

  await new Promise<void>((resolveListen) => {
    server.listen(0, "127.0.0.1", resolveListen);
  });
  const { port } = server.address() as AddressInfo;
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    close: () =>
      new Promise<void>((resolveClose) => {
        server.close(() => resolveClose());
        server.closeAllConnections();
      }),
  };
}
