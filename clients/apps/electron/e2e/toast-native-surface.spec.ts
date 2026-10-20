import { expect, test } from "./electron-test";
import { setElectronWindowContentSize } from "./electron-operations";
import { startElectronTestServer } from "./electron-test-server";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// The sidebar browser is a `WebContentsView`, which the compositor paints above
// the renderer's entire DOM — a toast at the window's bottom-right corner is
// covered by it outright, at any z-index. Only a real Electron window can prove
// the stack steps clear of it, so this case measures both boxes in the live app.
test(
  "a toast raised behind the sidebar browser lands clear of the native view",
  { tag: "@shared-app" },
  async ({ sharedElectron: { app, mainWindow: appWindow, signIn, useApi } }) => {
    const browserStub = await startBrowserStub();
    const apiStub = await startChatSmokeStub({
      assistantReply: `[Open browser](${browserStub.baseUrl}/page)`,
    });

    try {
      useApi(apiStub.server);
      await signIn({
        email: "toast-native-surface@comma.local",
        userId: apiStub.userId,
      });
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
        await setElectronWindowContentSize(app, appWindow, { width, height: 800 });
        expect(await appWindow.evaluate(() => window.innerWidth)).toBe(width);
        await expectClearOfNativeView(`${width}px`);
      }
    } finally {
      await apiStub.close();
      await browserStub.close();
    }
  }
);

async function startBrowserStub() {
  const server = await startElectronTestServer((request, response) => {
    const path = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
    response.writeHead(200, { "content-type": "text/html" });
    response.end(`<!doctype html><title>${path}</title><p>${path}</p>`);
  });
  return { baseUrl: server.origin, close: server.close };
}
