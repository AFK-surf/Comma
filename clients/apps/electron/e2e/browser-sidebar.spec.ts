import { expect } from "../../../e2e/helpers/native-expect";
import { _electron as electron, test } from "@playwright/test";
import { createServer, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { createRequire } from "node:module";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import {
  maxBrowserSidebarSessionsPerOwner,
  type BrowserSidebarState,
} from "@comma/native-bridge";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  chatSmokeWorkspaceChat,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const onePixelPngBase64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

test("Command-K keeps the browser visible until its stand-in is decoded", async () => {
  // Reuse the real browser/session fixtures: DOM-only tests cannot observe
  // whether Main hides WebContentsView before the replacement PNG is ready.
  const browserStub = await startBrowserStub();
  const apiStub = await startChatSmokeStub({
    assistantReply: `[Open browser](${browserStub.baseUrl}/a1)`,
  });
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-browser-overlay-e2e-"));
  recordElectronOnboardingCompleted(userDataDir, [apiStub.userId]);
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...hostEnv,
      COMMA_API_BASE_URL: apiStub.baseUrl,
      COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "browser-overlay@comma.local",
      COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "browser-overlay-session-token",
      NODE_ENV: "test",
    },
  });
  try {
    const appWindow = await findElectronWindowByNativeRole(app, "main-window");
    await appWindow.evaluate(() => {
      const testWindow = window as typeof window & {
        e2eBrowserVisibility?: boolean | undefined;
      };
      window.commaNative!.browserSidebar.onChanged((state) => {
        testWindow.e2eBrowserVisibility = state.visible;
      });
    });
    const content = appWindow.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("Open browser");
    await composer.getByRole("button", { name: "Send" }).click();
    await content.getByRole("link", { name: "Open browser" }).click();
    const viewport = content.locator(".comma-chat-sidebar-browser-viewport");
    const browserSnapshot = viewport.locator(".comma-chat-sidebar-browser-snapshot");
    const lastNativeVisibility = () =>
      appWindow.evaluate(
        () =>
          (window as typeof window & { e2eBrowserVisibility?: boolean })
            .e2eBrowserVisibility
      );
    await expect.poll(lastNativeVisibility).toBe(true);
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, url) =>
            webContents
              .getAllWebContents()
              .some((contents) => contents.getURL() === url && !contents.isLoading()),
          `${browserStub.baseUrl}/a1`
        )
      )
      .toBe(true);
    // Cmd+K uses the same native suppression path. Hold PNG decoding past
    // the old 48 ms paint fallback: the live page must remain visible until
    // the actual DOM stand-in is decoded, including when the palette closes
    // before decoding finishes.
    for (const closeBeforeDecode of [false, true]) {
      await appWindow.evaluate(() => {
        const originalDecode = HTMLImageElement.prototype.decode;
        const testWindow = window as typeof window & {
          e2eReleaseSnapshotDecode?: () => void;
        };
        HTMLImageElement.prototype.decode = async function () {
          if (!this.classList.contains("comma-chat-sidebar-browser-snapshot")) {
            return originalDecode.call(this);
          }
          HTMLImageElement.prototype.decode = originalDecode;
          await originalDecode.call(this);
          await new Promise<void>((resolveDecode) => {
            testWindow.e2eReleaseSnapshotDecode = resolveDecode;
          });
        };
      });
      await appWindow.keyboard.press("ControlOrMeta+k");
      const palette = appWindow.getByRole("dialog", { name: "Search Comma" });
      await expect(palette).toBeVisible();
      await expect(browserSnapshot).toBeVisible();
      await appWindow.waitForTimeout(100);
      expect(await lastNativeVisibility()).toBe(true);
      await expect
        .poll(() =>
          appWindow.evaluate(
            () =>
              typeof (
                window as typeof window & {
                  e2eReleaseSnapshotDecode?: () => void;
                }
              ).e2eReleaseSnapshotDecode === "function"
          )
        )
        .toBe(true);
      if (closeBeforeDecode) {
        await appWindow.keyboard.press("Escape");
        await expect(palette).toHaveCount(0);
        await expect(browserSnapshot).toHaveCount(0);
      }
      await appWindow.evaluate(() => {
        const testWindow = window as typeof window & {
          e2eReleaseSnapshotDecode?: () => void;
        };
        testWindow.e2eReleaseSnapshotDecode?.();
        delete testWindow.e2eReleaseSnapshotDecode;
      });
      if (closeBeforeDecode) {
        await appWindow.waitForTimeout(100);
        expect(await lastNativeVisibility()).toBe(true);
        await expect(browserSnapshot).toHaveCount(0);
      } else {
        await expect.poll(lastNativeVisibility).toBe(false);
        expect(
          await browserSnapshot.evaluate(
            (image: HTMLImageElement) => image.complete && image.naturalWidth > 0
          )
        ).toBe(true);
        await appWindow.keyboard.press("Escape");
        await expect(palette).toHaveCount(0);
        await expect.poll(lastNativeVisibility).toBe(true);
        await expect(browserSnapshot).toHaveCount(0);
      }
    }
  } finally {
    await app.close();
    await apiStub.close();
    await browserStub.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});

test("browser sidebar keeps page sessions isolated and remains recoverable during navigation failures", async () => {
  test.setTimeout(180_000);
  const browserStub = await startBrowserStub();
  const lruTaskRefs = Array.from(
    { length: maxBrowserSidebarSessionsPerOwner },
    (_, index) => ({
      browserLink: {
        label: `Open LRU browser ${index}`,
        url: `${browserStub.baseUrl}/lru-task-${index}`,
      },
      id: `cnv_public_browser_lru_${index}`,
      title: `Browser LRU task ${index}`,
    })
  );
  const apiStub = await startChatSmokeStub({
    additionalTaskRefs: lruTaskRefs,
    assistantReply: `[Open browser](${browserStub.baseUrl}/a1)`,
    taskAssistantReply: [
      `[Old page](${browserStub.baseUrl}/old)`,
      `[New page](${browserStub.baseUrl}/new)`,
    ].join("\n\n"),
  });
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-browser-sidebar-e2e-"));
  recordElectronOnboardingCompleted(userDataDir, [apiStub.userId]);
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...hostEnv,
      COMMA_API_BASE_URL: apiStub.baseUrl,
      COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "browser-sidebar@comma.local",
      COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "browser-sidebar-session-token",
      NODE_ENV: "test",
    },
  });
  let appClosed = false;

  try {
    const appWindow = await findElectronWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await appWindow.evaluate(() => {
      const bridge = window.commaNative;
      if (!bridge) throw new Error("Native bridge is unavailable");
      const testWindow = window as typeof window & {
        e2eBrowserSidebarOpenCalls?: Array<{
          closeBeforeOpenSessionIds?: string[] | undefined;
          navigationRevision?: number | undefined;
          sessionId: string;
          url: string;
        }>;
        e2eBrowserSidebarDelayNextOpenSessionId?: string | undefined;
        e2eBrowserSidebarDelayedOpenReady?: boolean | undefined;
        e2eBrowserSidebarInspectResults?: unknown[] | undefined;
        e2eBrowserSidebarReleaseDelayedOpen?: (() => void) | undefined;
        e2eBrowserSidebarStates?: Array<{
          sessionId?: string | undefined;
          visible?: boolean | undefined;
        }>;
        e2eBrowserSidebarUpdateCalls?: Array<{
          sessionId: string;
          visible?: boolean | undefined;
        }>;
      };
      const originalInspect = bridge.browserSidebar.inspect.bind(bridge.browserSidebar);
      const originalOpen = bridge.browserSidebar.open.bind(bridge.browserSidebar);
      const originalUpdate = bridge.browserSidebar.update.bind(bridge.browserSidebar);
      testWindow.e2eBrowserSidebarInspectResults = [];
      testWindow.e2eBrowserSidebarOpenCalls = [];
      testWindow.e2eBrowserSidebarStates = [];
      testWindow.e2eBrowserSidebarUpdateCalls = [];
      bridge.browserSidebar.onChanged((state) => {
        testWindow.e2eBrowserSidebarStates?.push(state);
      });
      window.commaNative = {
        ...bridge,
        browserSidebar: {
          ...bridge.browserSidebar,
          inspect: async (input) => {
            const result = await originalInspect(input);
            testWindow.e2eBrowserSidebarInspectResults?.push(result);
            return result;
          },
          open: async (input) => {
            testWindow.e2eBrowserSidebarOpenCalls?.push({
              closeBeforeOpenSessionIds: input.closeBeforeOpenSessionIds,
              navigationRevision: input.navigationRevision,
              sessionId: input.sessionId,
              url: input.url,
            });
            const delayResult =
              testWindow.e2eBrowserSidebarDelayNextOpenSessionId === input.sessionId;
            if (delayResult) {
              testWindow.e2eBrowserSidebarDelayNextOpenSessionId = undefined;
            }
            const result = await originalOpen(input);
            if (delayResult) {
              testWindow.e2eBrowserSidebarDelayedOpenReady = true;
              await new Promise<void>((resolveDelayedOpen) => {
                testWindow.e2eBrowserSidebarReleaseDelayedOpen = resolveDelayedOpen;
              });
            }
            return result;
          },
          update: (input) => {
            testWindow.e2eBrowserSidebarUpdateCalls?.push({
              sessionId: input.sessionId,
              visible: input.visible,
            });
            return originalUpdate(input);
          },
        },
      };
    });
    const content = appWindow.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer
      .getByRole("textbox", { name: "AI prompt" })
      .fill("Open the browser sidebar");
    await composer.getByRole("button", { name: "Send" }).click();
    await content.getByRole("link", { name: "Open browser" }).click();

    const sidebar = content.getByTestId("chat-sidebar");
    const viewport = sidebar.locator(".comma-chat-sidebar-browser-viewport");
    await expect(sidebar).toHaveAttribute("data-open", "true");
    await expect(sidebar.getByRole("textbox", { name: "Address" })).toHaveValue(
      `${browserStub.baseUrl}/a1`
    );
    await expect.poll(async () => (await sidebar.boundingBox())?.width ?? 0).toBe(440);

    const viewportBounds = await viewport.evaluate((element) => {
      const rect = element.getBoundingClientRect();
      return {
        height: Math.round(rect.height),
        width: Math.round(rect.width),
        x: Math.round(rect.x),
        y: Math.round(rect.y),
      };
    });
    const activePageSessionId = async (hostSessionId: string) => {
      const activeTab = sidebar.locator('[role="tab"][aria-selected="true"]');
      await expect(activeTab).toHaveCount(1);
      const pageId = await activeTab.getAttribute("data-tab");
      if (!pageId || pageId === "chat") {
        throw new Error(`No active browser page tab for ${hostSessionId}`);
      }
      return `${hostSessionId}::${pageId}`;
    };
    const rendererOpenCallCount = (sessionId: string) =>
      appWindow.evaluate((activeSessionId) => {
        const testWindow = window as typeof window & {
          e2eBrowserSidebarOpenCalls?: Array<{ sessionId: string }>;
        };
        return (
          testWindow.e2eBrowserSidebarOpenCalls?.filter(
            (call) => call.sessionId === activeSessionId
          ).length ?? 0
        );
      }, sessionId);
    const rendererOpenCalls = (sessionId: string) =>
      appWindow.evaluate((activeSessionId) => {
        const testWindow = window as typeof window & {
          e2eBrowserSidebarOpenCalls?: Array<{
            navigationRevision?: number | undefined;
            sessionId: string;
            url: string;
          }>;
        };
        return (
          testWindow.e2eBrowserSidebarOpenCalls?.filter(
            (call) => call.sessionId === activeSessionId
          ) ?? []
        );
      }, sessionId);
    const readNativeBrowserState = (sessionId: string) =>
      appWindow.evaluate(
        async ({ activeSessionId, bounds: nextBounds }) => {
          const bridge = window.commaNative;
          if (!bridge) throw new Error("Native bridge is unavailable");
          const state = await bridge.browserSidebar.update({
            bounds: nextBounds,
            sessionId: activeSessionId,
          });
          return {
            active: state.active,
            canGoBack: state.canGoBack,
            canGoForward: state.canGoForward,
            loading: state.loading,
            ...(state.reason === undefined ? {} : { reason: state.reason }),
            ...(state.reasonCode === undefined ? {} : { reasonCode: state.reasonCode }),
            ...(state.title === undefined ? {} : { title: state.title }),
            url: state.url,
            visible: state.visible,
          };
        },
        { activeSessionId: sessionId, bounds: viewportBounds }
      );
    const productHostSessionId = JSON.stringify([
      chatSmokeWorkspace.group_id,
      chatSmokeWorkspaceChat.id,
    ]);
    const productSessionId = await activePageSessionId(productHostSessionId);
    expect(productSessionId).toContain(`${productHostSessionId}::`);
    await expect
      .poll(() =>
        appWindow.evaluate(
          async ({ sessionId }) => {
            const bridge = window.commaNative;
            if (!bridge) throw new Error("Native bridge is unavailable");
            return (
              await bridge.browserSidebar.update({
                sessionId,
                visible: true,
              })
            ).surface?.bounds;
          },
          { sessionId: productSessionId }
        )
      )
      .toEqual(viewportBounds);

    await expect
      .poll(() =>
        app.evaluate(({ webContents }) =>
          webContents
            .getAllWebContents()
            .some((contents) =>
              contents.getURL().includes("#/browser-inspection-composer")
            )
        )
      )
      .toBe(true);
    const prewarmedComposerId = await app.evaluate(({ webContents }) => {
      const inspectionComposer = webContents
        .getAllWebContents()
        .find((contents) =>
          contents.getURL().includes("#/browser-inspection-composer")
        );
      if (!inspectionComposer) {
        throw new Error("Prewarmed inspection composer WebContents not found");
      }
      return inspectionComposer.id;
    });
    const selectElement = sidebar.getByRole("button", { name: "Select element" });
    await expect(selectElement).toBeEnabled();
    await selectElement.click();
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, { pageUrl }) => {
            const page = webContents
              .getAllWebContents()
              .find((contents) => contents.getURL() === pageUrl);
            if (!page) return false;
            return page.executeJavaScript(
              `Boolean(document.querySelector('#comma-browser-sidebar-element-inspector'))`
            );
          },
          { pageUrl: `${browserStub.baseUrl}/a1` }
        )
      )
      .toBe(true);
    // Measure the native selection path inside Main. Driver round trips and
    // expect.poll's scheduling interval are not part of the focus latency.
    const selection = await app.evaluate(
      async ({ webContents }, { pageUrl, composerId }) => {
        const page = webContents
          .getAllWebContents()
          .find((contents) => contents.getURL() === pageUrl);
        const composerContents = webContents.fromId(composerId);
        if (!page || !composerContents)
          throw new Error("Inspection surfaces are missing");
        await composerContents.executeJavaScript(`
          document.activeElement?.blur();
          window.addEventListener('comma-browser-inspection-composer-activate', () => {
            window.e2eInspectionFocusedOnActivation =
              document.activeElement?.getAttribute('role') === 'textbox';
          }, { once: true });
        `);
        const startedAt = Date.now();
        await page.executeJavaScript(`
          (() => {
            const target = document.querySelector('#inspection-sensitive-target');
            if (!target) throw new Error('Sensitive inspection fixture is missing');
            target.dispatchEvent(new MouseEvent('click', {
              bubbles: true,
              cancelable: true,
              composed: true
            }));
          })();
        `);
        await composerContents.executeJavaScript(`
          new Promise((resolve, reject) => {
            const deadline = setTimeout(() => {
              document.removeEventListener('focusin', inspect);
              reject(new Error('Inspection composer did not receive focus'));
            }, 5000);
            const inspect = () => {
              if (document.activeElement?.getAttribute('role') === 'textbox') {
                clearTimeout(deadline);
                document.removeEventListener('focusin', inspect);
                resolve();
              }
            };
            document.addEventListener('focusin', inspect);
            inspect();
          });
        `);
        const duration = Date.now() - startedAt;
        const focusedOnActivation = await composerContents.executeJavaScript(
          "window.e2eInspectionFocusedOnActivation"
        );
        return { duration, focusedOnActivation };
      },
      { pageUrl: `${browserStub.baseUrl}/a1`, composerId: prewarmedComposerId }
    );
    expect(selection.focusedOnActivation).toBe(true);
    expect(selection.duration).toBeLessThan(250);
    await app.evaluate(
      async ({ webContents }, { composerId }) => {
        const inspectionComposer = webContents
          .getAllWebContents()
          .find((contents) =>
            contents.getURL().includes("#/browser-inspection-composer")
          );
        if (!inspectionComposer) {
          throw new Error("Inspection composer WebContents not found");
        }
        if (inspectionComposer.id !== composerId) {
          throw new Error(
            "Inspection composer did not reuse its prewarmed WebContents"
          );
        }
        const leadingControls = await inspectionComposer.executeJavaScript(`
        ({
          hasAttachment: Boolean(document.querySelector('[aria-label="Add attachment"]')),
          hasClose: Boolean(document.querySelector('[aria-label="Close"]'))
        })
      `);
        if (leadingControls.hasAttachment) {
          throw new Error("Inspection composer unexpectedly exposed attachments");
        }
        if (!leadingControls.hasClose) {
          throw new Error("Inspection composer did not expose its close control");
        }
        await inspectionComposer.executeJavaScript(`
        (() => {
          const close = document.querySelector('[aria-label="Close"]');
          if (!(close instanceof HTMLElement)) {
            throw new Error('Inspection composer close button not found');
          }
          close.click();
        })()
      `);
      },
      { composerId: prewarmedComposerId }
    );
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, { pageUrl }) => {
            const page = webContents
              .getAllWebContents()
              .find((contents) => contents.getURL() === pageUrl);
            if (!page) return false;
            return page.executeJavaScript(
              `document.querySelector('#comma-browser-sidebar-element-inspector')?.style.display === 'block'`
            );
          },
          { pageUrl: `${browserStub.baseUrl}/a1` }
        )
      )
      .toBe(true);
    await expect(
      sidebar.getByRole("button", { name: "Cancel element selection" })
    ).toHaveAttribute("aria-pressed", "true");
    await app.evaluate(
      ({ webContents }, { pageUrl }) => {
        const page = webContents
          .getAllWebContents()
          .find((contents) => contents.getURL() === pageUrl);
        if (!page) throw new Error(`Browser WebContents not found for ${pageUrl}`);
        page.sendInputEvent({ keyCode: "Escape", type: "keyDown" });
        page.sendInputEvent({ keyCode: "Escape", type: "keyUp" });
      },
      { pageUrl: `${browserStub.baseUrl}/a1` }
    );
    const restartedSelection = sidebar.getByRole("button", {
      name: "Select element",
    });
    await expect(restartedSelection).toHaveAttribute("aria-pressed", "false");
    await appWindow.evaluate(() => {
      const testWindow = window as typeof window & {
        e2eBrowserSidebarInspectResults?: unknown[] | undefined;
      };
      testWindow.e2eBrowserSidebarInspectResults = [];
    });
    await restartedSelection.click();
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, { pageUrl }) => {
            const page = webContents
              .getAllWebContents()
              .find((contents) => contents.getURL() === pageUrl);
            if (!page) return false;
            return page.executeJavaScript(
              `document.querySelector('#comma-browser-sidebar-element-inspector')?.style.display === 'block'`
            );
          },
          { pageUrl: `${browserStub.baseUrl}/a1` }
        )
      )
      .toBe(true);
    await app.evaluate(
      async ({ webContents }, { pageUrl }) => {
        const page = webContents
          .getAllWebContents()
          .find((contents) => contents.getURL() === pageUrl);
        if (!page) throw new Error(`Browser WebContents not found for ${pageUrl}`);
        await page.executeJavaScript(`
          (() => {
            const target = document.querySelector('#inspection-sensitive-target');
            if (!target) throw new Error('Sensitive inspection fixture is missing');
            target.dispatchEvent(new MouseEvent('click', {
              bubbles: true,
              cancelable: true,
              composed: true
            }));
          })();
        `);
      },
      { pageUrl: `${browserStub.baseUrl}/a1` }
    );
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, { composerId }) => {
            const composerContents = webContents.fromId(composerId);
            if (!composerContents) return false;
            return composerContents.executeJavaScript(
              `document.activeElement?.getAttribute('role') === 'textbox'`
            );
          },
          { composerId: prewarmedComposerId }
        )
      )
      .toBe(true);
    await app.evaluate(
      async ({ webContents }, { composerId }) => {
        const inspectionComposer = webContents.fromId(composerId);
        if (!inspectionComposer) {
          throw new Error("Inspection composer WebContents not found after restart");
        }
        await inspectionComposer.executeJavaScript(`
        (() => {
          const editor = document.querySelector('[role="textbox"]');
          if (!(editor instanceof HTMLElement)) {
            throw new Error('Inspection composer textbox not found');
          }
          editor.focus();
        })()
      `);
        inspectionComposer.insertText("Explain this selected\nelement");
        const multiline = await inspectionComposer.executeJavaScript(`
        document.querySelector('.comma-chat-composer-shell')
          ?.getAttribute('data-side-chat-multiline')
      `);
        if (multiline !== "true") {
          throw new Error(`Inspection composer did not expand: ${multiline}`);
        }
        inspectionComposer.reload();
      },
      { composerId: prewarmedComposerId }
    );
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, { composerId }) => {
            const inspectionComposer = webContents.fromId(composerId);
            if (!inspectionComposer) return undefined;
            return inspectionComposer.executeJavaScript(`
              document.querySelector('[role="textbox"]')?.textContent
            `);
          },
          { composerId: prewarmedComposerId }
        )
      )
      .toBe("Explain this selected\nelement");
    await app.evaluate(
      async ({ webContents }, { composerId }) => {
        const inspectionComposer = webContents.fromId(composerId);
        if (!inspectionComposer) {
          throw new Error("Inspection composer WebContents missing after reload");
        }
        await inspectionComposer.executeJavaScript(`
          (() => {
            const send = document.querySelector('button[aria-label="Send message"]');
            if (!(send instanceof HTMLButtonElement)) {
              throw new Error('Inspection composer send button not found');
            }
            if (send.disabled) {
              throw new Error('Inspection composer send button is disabled');
            }
            send.click();
          })()
        `);
      },
      { composerId: prewarmedComposerId }
    );
    await expect
      .poll(() =>
        appWindow.evaluate(() => {
          const testWindow = window as typeof window & {
            e2eBrowserSidebarInspectResults?: Array<{ status?: string }> | undefined;
          };
          return (
            testWindow.e2eBrowserSidebarInspectResults?.filter(
              (result) => result.status === "selected"
            ).length ?? 0
          );
        })
      )
      .toBe(1);
    const inspectedElement = await appWindow.evaluate(() => {
      const testWindow = window as typeof window & {
        e2eBrowserSidebarInspectResults?: Array<{
          element?: {
            attributes?: Record<string, string> | undefined;
            outerHTML?: string | undefined;
          };
          status?: string | undefined;
        }>;
      };
      const result = testWindow.e2eBrowserSidebarInspectResults?.findLast(
        (candidate) => candidate.status === "selected"
      );
      if (!result?.element?.outerHTML) {
        throw new Error("Selected browser inspection result was not captured");
      }
      return result.element;
    });
    expect(inspectedElement.attributes).toEqual({
      "aria-label": "Account card",
      class: "account-card",
      id: "inspection-sensitive-target",
    });
    expect(inspectedElement.outerHTML).toContain("Visible account details");
    expect(inspectedElement.outerHTML).toContain('title="Visible label"');
    for (const privateValue of [
      "root-token-secret",
      "child-token-secret",
      "password-secret",
      "hidden-input-secret",
      "hidden-descendant-secret",
      "styled-hidden-secret",
      "text-input-secret",
      "textarea-secret",
      "recordInspectionClick",
    ]) {
      expect(inspectedElement.outerHTML).not.toContain(privateValue);
    }
    expect(inspectedElement.outerHTML).not.toContain('type="password"');
    expect(inspectedElement.outerHTML).not.toContain('type="hidden"');
    expect(inspectedElement.outerHTML).not.toContain("data-token");
    expect(inspectedElement.outerHTML).not.toContain("onclick");
    const inspectedUserMessage = content
      .locator('[data-slot="chat-user-output"]')
      .filter({ hasText: "Explain this selected element" });
    await expect(inspectedUserMessage).toHaveCount(1);
    await expect(
      inspectedUserMessage.getByTestId("chat-browser-inspection-context")
    ).toContainText("/a1");
    // The window bar's Recent tasks menu drops over the sidebar, where the
    // native view composites above every DOM layer. While the menu is open
    // the sidebar hides the live view behind a frame-accurate snapshot, and
    // hands the view back the moment the menu closes.
    const recentTasksMenu = appWindow.getByRole("menu", { name: "Recent tasks" });
    const browserSnapshot = viewport.locator(".comma-chat-sidebar-browser-snapshot");
    const lastNativeVisibility = () =>
      appWindow.evaluate(
        ({ sessionId }) => {
          const testWindow = window as typeof window & {
            e2eBrowserSidebarStates?: Array<{
              sessionId?: string | undefined;
              visible?: boolean | undefined;
            }>;
          };
          return testWindow.e2eBrowserSidebarStates
            ?.filter((state) => state.sessionId === sessionId)
            .at(-1)?.visible;
        },
        { sessionId: productSessionId }
      );
    await appWindow.getByRole("button", { exact: true, name: "Recent tasks" }).click();
    await expect(recentTasksMenu).toBeVisible();
    await expect(browserSnapshot).toBeVisible();
    await expect.poll(lastNativeVisibility).toBe(false);
    await appWindow.keyboard.press("Escape");
    await expect(recentTasksMenu).toHaveCount(0);
    await expect.poll(lastNativeVisibility).toBe(true);
    await expect(browserSnapshot).toHaveCount(0);
    // The toggle is a window-bar control, not a float over the content panel:
    // it stays clickable beside the open sidebar and the panel's top drag
    // region no longer keeps a strip clear for it.
    const sidebarToggle = appWindow.getByRole("button", {
      name: "Toggle chat sidebar",
    });
    await expect
      .poll(() =>
        sidebarToggle.evaluate((button) => {
          const rect = button.getBoundingClientRect();
          const contentElement = document.querySelector(".comma-content");
          const sidebarHeader = document.querySelector(".comma-chat-sidebar-header");
          return {
            buttonRegion:
              getComputedStyle(button).getPropertyValue("-webkit-app-region"),
            contentDragStrip: contentElement
              ? getComputedStyle(contentElement, "::before").content
              : undefined,
            hitTarget: document
              .elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)
              ?.closest("button")
              ?.getAttribute("aria-label"),
            inContent: button.closest(".comma-content") !== null,
            inWindowBar: button.closest('[data-testid="comma-window-bar"]') !== null,
            sidebarHeaderRegion: sidebarHeader
              ? getComputedStyle(sidebarHeader).getPropertyValue("-webkit-app-region")
              : undefined,
          };
        })
      )
      .toEqual({
        buttonRegion: "no-drag",
        contentDragStrip: "none",
        hitTarget: "Toggle chat sidebar",
        inContent: false,
        inWindowBar: true,
        sidebarHeaderRegion: "no-drag",
      });
    await sidebarToggle.click();
    await expect(sidebar).toHaveAttribute("data-open", "false");
    await expect
      .poll(() =>
        appWindow.evaluate(
          ({ sessionId }) => {
            const testWindow = window as typeof window & {
              e2eBrowserSidebarStates?: Array<{
                sessionId?: string | undefined;
                visible?: boolean | undefined;
              }>;
            };
            return testWindow.e2eBrowserSidebarStates
              ?.filter((state) => state.sessionId === sessionId)
              .at(-1)?.visible;
          },
          { sessionId: productSessionId }
        )
      )
      .toBe(false);
    await sidebarToggle.click();
    await expect(sidebar).toHaveAttribute("data-open", "true");
    await expect
      .poll(() =>
        appWindow.evaluate(
          ({ sessionId }) => {
            const testWindow = window as typeof window & {
              e2eBrowserSidebarStates?: Array<{
                sessionId?: string | undefined;
                visible?: boolean | undefined;
              }>;
            };
            return testWindow.e2eBrowserSidebarStates
              ?.filter((state) => state.sessionId === sessionId)
              .at(-1)?.visible;
          },
          { sessionId: productSessionId }
        )
      )
      .toBe(true);

    const openCountBeforeNativeRecreation =
      await rendererOpenCallCount(productSessionId);
    await appWindow.evaluate(
      () =>
        new Promise<void>((resolveFrame) => {
          window.requestAnimationFrame(() => {
            window.requestAnimationFrame(() => resolveFrame());
          });
        })
    );
    await viewport.evaluate((element) => {
      const originalGetBoundingClientRect = element.getBoundingClientRect.bind(element);
      const testWindow = window as typeof window & {
        e2eBrowserSidebarGeometryReady?: boolean;
        e2eBrowserSidebarZeroBoundsReads?: number;
      };
      testWindow.e2eBrowserSidebarGeometryReady = false;
      testWindow.e2eBrowserSidebarZeroBoundsReads = 0;
      Object.defineProperty(element, "getBoundingClientRect", {
        configurable: true,
        value: () => {
          if (!testWindow.e2eBrowserSidebarGeometryReady) {
            testWindow.e2eBrowserSidebarZeroBoundsReads =
              (testWindow.e2eBrowserSidebarZeroBoundsReads ?? 0) + 1;
            return new DOMRect(0, 0, 0, 0);
          }
          return originalGetBoundingClientRect();
        },
      });
    });
    await appWindow.evaluate(async (sessionId) => {
      const bridge = window.commaNative;
      if (!bridge) throw new Error("Native bridge is unavailable");
      await bridge.browserSidebar.close({ sessionId });
    }, productSessionId);
    await expect
      .poll(() =>
        appWindow.evaluate(() => {
          const testWindow = window as typeof window & {
            e2eBrowserSidebarZeroBoundsReads?: number;
          };
          return testWindow.e2eBrowserSidebarZeroBoundsReads ?? 0;
        })
      )
      .toBeGreaterThan(0);
    expect(await rendererOpenCallCount(productSessionId)).toBe(
      openCountBeforeNativeRecreation
    );
    await appWindow.evaluate(() => {
      const testWindow = window as typeof window & {
        e2eBrowserSidebarGeometryReady?: boolean;
      };
      testWindow.e2eBrowserSidebarGeometryReady = true;
      window.dispatchEvent(new Event("resize"));
    });
    await expect
      .poll(() => rendererOpenCallCount(productSessionId))
      .toBe(openCountBeforeNativeRecreation + 1);
    await expect
      .poll(() => readNativeBrowserState(productSessionId))
      .toMatchObject({
        active: true,
        loading: false,
        url: `${browserStub.baseUrl}/a1`,
        visible: true,
      });

    const address = sidebar.getByRole("textbox", { name: "Address" });
    await address.fill(`${browserStub.baseUrl}/fail`);
    await address.press("Enter");
    await expect(appWindow.getByTestId("browser-error")).toBeVisible();
    await address.fill(`${browserStub.baseUrl}/recovered`);
    await address.press("Enter");
    await expect(address).toHaveValue(`${browserStub.baseUrl}/recovered`);
    await expect(appWindow.getByTestId("browser-error")).toHaveCount(0);

    const recoveredTab = sidebar.getByRole("tab", {
      exact: true,
      name: "/recovered",
    });
    await expect(recoveredTab).toHaveAttribute("aria-selected", "true");
    await sidebar.getByRole("button", { exact: true, name: "New tab" }).click();
    await expect(
      sidebar.getByRole("tab", { exact: true, name: "New tab" })
    ).toHaveAttribute("aria-selected", "true");
    const secondPageSessionId = await activePageSessionId(productHostSessionId);
    const secondAddress = sidebar.getByRole("textbox", { name: "Address" });
    await expect(secondAddress).toHaveValue("");
    await secondAddress.fill(`${browserStub.baseUrl}/b1`);
    await secondAddress.press("Enter");
    expect(secondPageSessionId).not.toBe(productSessionId);
    await expect
      .poll(() => readNativeBrowserState(secondPageSessionId))
      .toMatchObject({
        active: true,
        loading: false,
        title: "/b1",
        url: `${browserStub.baseUrl}/b1`,
        visible: true,
      });
    const secondPageId = secondPageSessionId.slice(`${productHostSessionId}::`.length);
    const secondTab = sidebar.locator(`[role="tab"][data-tab="${secondPageId}"]`);
    await expect(secondTab).toHaveAttribute("aria-selected", "true");
    await expect(secondTab).toHaveAccessibleName("/b1");
    await expect
      .poll(() =>
        app.evaluate(async ({ webContents }, pageUrl) => {
          const page = webContents
            .getAllWebContents()
            .find((contents) => contents.getURL() === pageUrl);
          if (!page) return "";
          return page.executeJavaScript("document.body.textContent ?? ''");
        }, `${browserStub.baseUrl}/b1`)
      )
      .toContain("/b1");
    const secondInitialOpenCalls = await rendererOpenCalls(secondPageSessionId);
    expect(secondInitialOpenCalls.length).toBeGreaterThan(0);
    expect(secondInitialOpenCalls.length).toBeLessThanOrEqual(2);
    expect(
      new Set(
        secondInitialOpenCalls.map((call) =>
          JSON.stringify({
            navigationRevision: call.navigationRevision,
            url: call.url,
          })
        )
      )
    ).toEqual(
      new Set([
        JSON.stringify({
          navigationRevision: secondInitialOpenCalls[0]?.navigationRevision,
          url: `${browserStub.baseUrl}/b1`,
        }),
      ])
    );
    const secondInitialOpenCount = secondInitialOpenCalls.length;

    await recoveredTab.click();
    await expect(recoveredTab).toHaveAttribute("aria-selected", "true");
    await expect(sidebar.getByRole("textbox", { name: "Address" })).toHaveValue(
      `${browserStub.baseUrl}/recovered`
    );
    await expect
      .poll(() => readNativeBrowserState(productSessionId))
      .toMatchObject({
        active: true,
        url: `${browserStub.baseUrl}/recovered`,
        visible: true,
      });
    await expect
      .poll(() => readNativeBrowserState(secondPageSessionId))
      .toMatchObject({
        active: true,
        url: `${browserStub.baseUrl}/b1`,
        visible: false,
      });

    await secondTab.click();
    await expect(secondTab).toHaveAttribute("aria-selected", "true");
    await expect(sidebar.getByRole("textbox", { name: "Address" })).toHaveValue(
      `${browserStub.baseUrl}/b1`
    );
    await expect
      .poll(() => readNativeBrowserState(secondPageSessionId))
      .toMatchObject({
        active: true,
        url: `${browserStub.baseUrl}/b1`,
        visible: true,
      });
    expect(await rendererOpenCallCount(secondPageSessionId)).toBe(
      secondInitialOpenCount
    );
    await secondAddress.fill(`${browserStub.baseUrl}/b2`);
    await secondAddress.press("Enter");
    await expect
      .poll(() => readNativeBrowserState(secondPageSessionId))
      .toMatchObject({
        canGoBack: true,
        loading: false,
        title: "/b2",
        url: `${browserStub.baseUrl}/b2`,
      });
    await expect(secondTab).toHaveAttribute("aria-selected", "true");
    await expect(secondTab).toHaveAccessibleName("/b2");
    const openCountBeforeHistory = await rendererOpenCallCount(secondPageSessionId);

    await sidebar.getByRole("button", { name: "Back" }).click();
    await expect
      .poll(() => readNativeBrowserState(secondPageSessionId))
      .toMatchObject({
        canGoForward: true,
        loading: false,
        title: "/b1",
        url: `${browserStub.baseUrl}/b1`,
      });
    await expect(secondTab).toHaveAttribute("aria-selected", "true");
    await expect(secondTab).toHaveAccessibleName("/b1");
    expect(await rendererOpenCallCount(secondPageSessionId)).toBe(
      openCountBeforeHistory
    );

    await sidebar.getByRole("button", { name: "Forward" }).click();
    await expect
      .poll(() => readNativeBrowserState(secondPageSessionId))
      .toMatchObject({
        canGoBack: true,
        loading: false,
        title: "/b2",
        url: `${browserStub.baseUrl}/b2`,
      });
    await expect(secondTab).toHaveAttribute("aria-selected", "true");
    await expect(secondTab).toHaveAccessibleName("/b2");
    expect(await rendererOpenCallCount(secondPageSessionId)).toBe(
      openCountBeforeHistory
    );

    await sidebar.getByRole("button", { name: "Close /b2" }).press("Enter");
    await expect(secondTab).toHaveCount(0);
    await expect(recoveredTab).toHaveAttribute("aria-selected", "true");
    await expect(sidebar.getByRole("textbox", { name: "Address" })).toHaveValue(
      `${browserStub.baseUrl}/recovered`
    );
    await expect
      .poll(() => readNativeBrowserState(secondPageSessionId))
      .toMatchObject({ active: false });

    const openCountBeforeCapacityRecovery =
      await rendererOpenCallCount(productSessionId);
    await sidebarToggle.click();
    await expect(sidebar).toHaveAttribute("data-open", "false");
    await appWindow.evaluate(
      async ({ baseUrl, bounds: nextBounds, sessionId, sessionLimit }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        await bridge.browserSidebar.close({ sessionId });
        for (let index = 0; index < sessionLimit; index += 1) {
          await bridge.browserSidebar.open({
            bounds: nextBounds,
            sessionId: `capacity-blocker-${index}`,
            url: `${baseUrl}/capacity-${index}`,
          });
        }
      },
      {
        baseUrl: browserStub.baseUrl,
        bounds: viewportBounds,
        sessionId: productSessionId,
        sessionLimit: maxBrowserSidebarSessionsPerOwner,
      }
    );
    await sidebarToggle.click();
    await expect(sidebar).toHaveAttribute("data-open", "true");
    await expect
      .poll(() => rendererOpenCallCount(productSessionId))
      .toBe(openCountBeforeCapacityRecovery + 1);
    await expect
      .poll(() =>
        appWindow.evaluate(
          ({ sessionId }) => {
            const testWindow = window as typeof window & {
              e2eBrowserSidebarStates?: BrowserSidebarState[];
            };
            return testWindow.e2eBrowserSidebarStates
              ?.filter((state) => state.sessionId === sessionId)
              .at(-1)?.reasonCode;
          },
          { sessionId: productSessionId }
        )
      )
      .toBe("capacity");
    const capacityCleanupSessionIndex = maxBrowserSidebarSessionsPerOwner - 1;
    const capacityCleanupSessionId = `capacity-blocker-${capacityCleanupSessionIndex}`;
    const capacityCleanupUrl = `${browserStub.baseUrl}/capacity-${capacityCleanupSessionIndex}`;
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, blockerUrl) =>
            webContents
              .getAllWebContents()
              .some((contents) => contents.getURL() === blockerUrl),
          capacityCleanupUrl
        )
      )
      .toBe(true);
    await app.evaluate(({ webContents }, blockerUrl) => {
      const blocker = webContents
        .getAllWebContents()
        .find((contents) => contents.getURL() === blockerUrl);
      if (!blocker) {
        throw new Error(`Capacity blocker not found for ${blockerUrl}`);
      }
      const originalClose = blocker.close.bind(blocker);
      Object.defineProperty(blocker, "close", {
        configurable: true,
        value: () => {
          originalClose();
          throw new Error("injected capacity cleanup reporting failure");
        },
      });
    }, capacityCleanupUrl);
    const capacityCleanupRejected = await appWindow.evaluate(async (sessionId) => {
      const bridge = window.commaNative;
      if (!bridge) throw new Error("Native bridge is unavailable");
      try {
        await bridge.browserSidebar.close({ sessionId });
        return false;
      } catch {
        return true;
      }
    }, capacityCleanupSessionId);
    expect(capacityCleanupRejected).toBe(true);
    await expect
      .poll(() => rendererOpenCallCount(productSessionId))
      .toBe(openCountBeforeCapacityRecovery + 2);
    await expect
      .poll(() => readNativeBrowserState(productSessionId))
      .toMatchObject({
        active: true,
        loading: false,
        url: `${browserStub.baseUrl}/recovered`,
        visible: true,
      });
    await appWindow.evaluate(async (sessionLimit) => {
      const bridge = window.commaNative;
      if (!bridge) throw new Error("Native bridge is unavailable");
      await Promise.all(
        Array.from({ length: sessionLimit - 1 }, (_, offset) =>
          bridge.browserSidebar.close({
            sessionId: `capacity-blocker-${offset}`,
          })
        )
      );
    }, maxBrowserSidebarSessionsPerOwner);

    const tablist = sidebar.getByRole("tablist", {
      name: "Chat sidebar content",
    });
    for (let index = 0; index < 6; index += 1) {
      await sidebar.getByRole("button", { exact: true, name: "New tab" }).click();
    }
    await expect
      .poll(() =>
        tablist.evaluate((element) => {
          const selected = element.querySelector<HTMLElement>(
            '[role="tab"][aria-selected="true"]'
          );
          if (!selected) {
            return { overflow: false, scrolled: false, selectedVisible: false };
          }
          const listRect = element.getBoundingClientRect();
          const selectedRect = selected.getBoundingClientRect();
          return {
            overflow: element.scrollWidth > element.clientWidth,
            scrolled: element.scrollLeft > 0,
            selectedVisible:
              selectedRect.left >= listRect.left - 1 &&
              selectedRect.right <= listRect.right + 1,
          };
        })
      )
      .toEqual({ overflow: true, scrolled: true, selectedVisible: true });

    await content
      .getByRole("button", {
        name: `Task: ${chatSmokeTaskConversation.title}`,
        exact: true,
      })
      .click();
    await sidebar.getByRole("button", { name: "Open task", exact: true }).click();
    await content
      .getByTestId("comma-route-outlet")
      .getByRole("link", { name: "Old page" })
      .click();
    await expect(appWindow).toHaveURL(
      new RegExp(
        `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    const taskHostSessionId = JSON.stringify([
      chatSmokeWorkspace.group_id,
      chatSmokeTaskConversation.id,
    ]);
    const taskOldPageSessionId = await activePageSessionId(taskHostSessionId);
    await expect
      .poll(() => readNativeBrowserState(taskOldPageSessionId))
      .toMatchObject({
        loading: false,
        url: `${browserStub.baseUrl}/old`,
      });
    await expect(sidebar.getByRole("textbox", { name: "Address" })).toHaveValue(
      `${browserStub.baseUrl}/old`
    );

    await appWindow.goBack();
    await expect(appWindow).not.toHaveURL(
      new RegExp(
        `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    await expect
      .poll(() => readNativeBrowserState(taskOldPageSessionId))
      .toMatchObject({
        loading: false,
        url: `${browserStub.baseUrl}/old`,
      });
    await app.evaluate(
      async ({ webContents }, { currentUrl, nextPath }) => {
        const retained = webContents
          .getAllWebContents()
          .find((contents) => contents.getURL() === currentUrl);
        if (!retained) {
          throw new Error(`Retained browser contents not found for ${currentUrl}`);
        }
        await retained.executeJavaScript(
          `history.pushState({}, "", ${JSON.stringify(
            nextPath
          )}); document.title = "Hidden latest";`
        );
      },
      { currentUrl: `${browserStub.baseUrl}/old`, nextPath: "/latest" }
    );
    await expect
      .poll(() => readNativeBrowserState(taskOldPageSessionId))
      .toMatchObject({
        loading: false,
        url: `${browserStub.baseUrl}/latest`,
      });
    const taskOpenCountBeforeHiddenRecovery =
      await rendererOpenCallCount(taskOldPageSessionId);
    await appWindow.evaluate(async (sessionId) => {
      const bridge = window.commaNative;
      if (!bridge) throw new Error("Native bridge is unavailable");
      await bridge.browserSidebar.close({ sessionId });
    }, taskOldPageSessionId);
    await content
      .getByRole("button", {
        name: `Task: ${chatSmokeTaskConversation.title}`,
        exact: true,
      })
      .click();
    await sidebar.getByRole("button", { name: "Open task" }).click();
    await expect(appWindow).toHaveURL(
      new RegExp(
        `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    await expect(sidebar.getByRole("textbox", { name: "Address" })).toHaveValue(
      `${browserStub.baseUrl}/latest`
    );
    await expect
      .poll(() => rendererOpenCallCount(taskOldPageSessionId))
      .toBeGreaterThanOrEqual(taskOpenCountBeforeHiddenRecovery + 1);
    expect(await rendererOpenCallCount(taskOldPageSessionId)).toBeLessThanOrEqual(
      taskOpenCountBeforeHiddenRecovery + 2
    );
    await expect
      .poll(() => readNativeBrowserState(taskOldPageSessionId))
      .toMatchObject({
        active: true,
        loading: false,
        url: `${browserStub.baseUrl}/latest`,
      });
    await appWindow.goBack();
    await expect(appWindow).not.toHaveURL(
      new RegExp(
        `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    await sidebar.getByRole("button", { name: "Open task", exact: true }).click();
    await content
      .getByTestId("comma-route-outlet")
      .getByRole("link", { name: "New page" })
      .click();
    await expect(appWindow).toHaveURL(
      new RegExp(
        `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    const taskNewPageSessionId = await activePageSessionId(taskHostSessionId);
    expect(taskNewPageSessionId).not.toBe(taskOldPageSessionId);
    await expect
      .poll(() => readNativeBrowserState(taskNewPageSessionId))
      .toMatchObject({
        loading: false,
        url: `${browserStub.baseUrl}/new`,
      });
    await expect
      .poll(() => readNativeBrowserState(taskOldPageSessionId))
      .toMatchObject({
        loading: false,
        url: `${browserStub.baseUrl}/latest`,
      });
    await expect(sidebar.getByRole("textbox", { name: "Address" })).toHaveValue(
      `${browserStub.baseUrl}/new`
    );

    const delayedRemountUrl = `${browserStub.baseUrl}/two`;
    const currentRemountUrl = `${browserStub.baseUrl}/three`;
    const delayedAddress = sidebar.getByRole("textbox", { name: "Address" });
    await delayedAddress.fill(delayedRemountUrl);
    await delayedAddress.press("Enter");
    await delayedAddress.press("Tab");
    await expect(delayedAddress).toHaveValue(delayedRemountUrl);
    await expect
      .poll(() => readNativeBrowserState(taskNewPageSessionId))
      .toMatchObject({
        active: true,
        url: delayedRemountUrl,
        visible: true,
      });
    const taskOpenCountBeforeDelayedRemount =
      await rendererOpenCallCount(taskNewPageSessionId);
    await appWindow.evaluate(async (sessionId) => {
      const bridge = window.commaNative;
      if (!bridge) throw new Error("Native bridge is unavailable");
      const testWindow = window as typeof window & {
        e2eBrowserSidebarDelayNextOpenSessionId?: string | undefined;
        e2eBrowserSidebarDelayedOpenReady?: boolean | undefined;
        e2eBrowserSidebarReleaseDelayedOpen?: (() => void) | undefined;
      };
      testWindow.e2eBrowserSidebarDelayNextOpenSessionId = sessionId;
      testWindow.e2eBrowserSidebarDelayedOpenReady = false;
      testWindow.e2eBrowserSidebarReleaseDelayedOpen = undefined;
      await bridge.browserSidebar.close({ sessionId });
    }, taskNewPageSessionId);
    await expect
      .poll(() => rendererOpenCallCount(taskNewPageSessionId))
      .toBe(taskOpenCountBeforeDelayedRemount + 1);
    await expect
      .poll(() =>
        appWindow.evaluate(() => {
          const testWindow = window as typeof window & {
            e2eBrowserSidebarDelayedOpenReady?: boolean | undefined;
          };
          return testWindow.e2eBrowserSidebarDelayedOpenReady ?? false;
        })
      )
      .toBe(true);
    await expect
      .poll(() => readNativeBrowserState(taskNewPageSessionId))
      .toMatchObject({
        active: true,
        url: delayedRemountUrl,
        visible: true,
      });

    await appWindow.goBack();
    await expect(appWindow).not.toHaveURL(
      new RegExp(
        `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    await content
      .getByRole("button", {
        name: `Task: ${chatSmokeTaskConversation.title}`,
        exact: true,
      })
      .click();
    await sidebar.getByRole("button", { name: "Open task" }).click();
    await expect(appWindow).toHaveURL(
      new RegExp(
        `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    await expect
      .poll(() => rendererOpenCallCount(taskNewPageSessionId))
      .toBeGreaterThanOrEqual(taskOpenCountBeforeDelayedRemount + 2);
    const taskOpenCountAfterDelayedRemount =
      await rendererOpenCallCount(taskNewPageSessionId);
    expect(taskOpenCountAfterDelayedRemount).toBeLessThanOrEqual(
      taskOpenCountBeforeDelayedRemount + 3
    );
    await expect
      .poll(() => readNativeBrowserState(taskNewPageSessionId))
      .toMatchObject({
        active: true,
        url: delayedRemountUrl,
        visible: true,
      });
    const currentAddress = sidebar.getByRole("textbox", { name: "Address" });
    await currentAddress.fill(currentRemountUrl);
    await currentAddress.press("Enter");
    await currentAddress.press("Tab");
    await expect
      .poll(() => rendererOpenCallCount(taskNewPageSessionId))
      .toBe(taskOpenCountAfterDelayedRemount);
    await expect(currentAddress).toHaveValue(currentRemountUrl);
    await expect
      .poll(() => readNativeBrowserState(taskNewPageSessionId))
      .toMatchObject({
        active: true,
        url: currentRemountUrl,
        visible: true,
      });

    const staleHideCountBeforeOldReply = await appWindow.evaluate((sessionId) => {
      const testWindow = window as typeof window & {
        e2eBrowserSidebarUpdateCalls?: Array<{
          sessionId: string;
          visible?: boolean | undefined;
        }>;
      };
      return (
        testWindow.e2eBrowserSidebarUpdateCalls?.filter(
          (call) => call.sessionId === sessionId && call.visible === false
        ).length ?? 0
      );
    }, taskNewPageSessionId);
    expect(staleHideCountBeforeOldReply).toBeGreaterThan(0);
    await appWindow.evaluate(async () => {
      const testWindow = window as typeof window & {
        e2eBrowserSidebarReleaseDelayedOpen?: (() => void) | undefined;
      };
      const release = testWindow.e2eBrowserSidebarReleaseDelayedOpen;
      if (!release) throw new Error("Delayed browser open is not ready to release");
      testWindow.e2eBrowserSidebarReleaseDelayedOpen = undefined;
      release();
      await new Promise<void>((resolveFrame) => {
        requestAnimationFrame(() => requestAnimationFrame(() => resolveFrame()));
      });
    });
    expect(
      await appWindow.evaluate((sessionId) => {
        const testWindow = window as typeof window & {
          e2eBrowserSidebarUpdateCalls?: Array<{
            sessionId: string;
            visible?: boolean | undefined;
          }>;
        };
        return (
          testWindow.e2eBrowserSidebarUpdateCalls?.filter(
            (call) => call.sessionId === sessionId && call.visible === false
          ).length ?? 0
        );
      }, taskNewPageSessionId)
    ).toBe(staleHideCountBeforeOldReply);
    await expect
      .poll(() => readNativeBrowserState(taskNewPageSessionId))
      .toMatchObject({
        active: true,
        url: currentRemountUrl,
        visible: true,
      });
    await expect(sidebar.getByRole("textbox", { name: "Address" })).toHaveValue(
      currentRemountUrl
    );

    const bounds = { height: 500, width: 400, x: 800, y: 40 };
    const isolated = await appWindow.evaluate(
      async ({ baseUrl, bounds: nextBounds }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        const waitForReady = async (
          sessionId: string,
          url: string,
          requireBack: boolean
        ) => {
          for (let attempt = 0; attempt < 200; attempt += 1) {
            const state = await bridge.browserSidebar.update({
              bounds: nextBounds,
              sessionId,
            });
            if (
              state.url === url &&
              state.loading === false &&
              (!requireBack || state.canGoBack)
            ) {
              return;
            }
            await new Promise((resolveWait) => setTimeout(resolveWait, 10));
          }
          throw new Error(`Browser session ${sessionId} did not finish ${url}`);
        };
        await bridge.browserSidebar.open({
          bounds: nextBounds,
          sessionId: "host-a",
          url: `${baseUrl}/a1`,
        });
        await waitForReady("host-a", `${baseUrl}/a1`, false);
        await bridge.browserSidebar.update({
          sessionId: "host-a",
          url: `${baseUrl}/a2`,
        });
        await waitForReady("host-a", `${baseUrl}/a2`, true);
        await bridge.browserSidebar.open({
          bounds: nextBounds,
          sessionId: "host-b",
          url: `${baseUrl}/b1`,
        });
        await waitForReady("host-b", `${baseUrl}/b1`, false);
        await bridge.browserSidebar.update({
          sessionId: "host-b",
          url: `${baseUrl}/b2`,
        });
        await waitForReady("host-b", `${baseUrl}/b2`, true);
        const hostA = await bridge.browserSidebar.open({
          bounds: nextBounds,
          sessionId: "host-a",
          url: `${baseUrl}/a1`,
        });
        await bridge.browserSidebar.navigate({
          action: "back",
          sessionId: "host-a",
        });
        await waitForReady("host-a", `${baseUrl}/a1`, false);
        const hostABack = await bridge.browserSidebar.update({
          bounds: nextBounds,
          sessionId: "host-a",
        });
        const hostB = await bridge.browserSidebar.open({
          bounds: nextBounds,
          sessionId: "host-b",
          url: `${baseUrl}/b1`,
        });
        await bridge.browserSidebar.navigate({
          action: "back",
          sessionId: "host-b",
        });
        await waitForReady("host-b", `${baseUrl}/b1`, false);
        const hostBBack = await bridge.browserSidebar.update({
          bounds: nextBounds,
          sessionId: "host-b",
        });
        return { hostA, hostABack, hostB, hostBBack };
      },
      { baseUrl: browserStub.baseUrl, bounds }
    );
    expect(isolated.hostA).toMatchObject({
      canGoBack: true,
      url: `${browserStub.baseUrl}/a2`,
    });
    expect(isolated.hostABack.url).toBe(`${browserStub.baseUrl}/a1`);
    expect(isolated.hostB).toMatchObject({
      canGoBack: true,
      url: `${browserStub.baseUrl}/b2`,
    });
    expect(isolated.hostBBack.url).toBe(`${browserStub.baseUrl}/b1`);

    const boundedSessions = await appWindow.evaluate(
      async ({ baseUrl, bounds: nextBounds, sessionLimit }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        const waitForState = async (
          sessionId: string,
          predicate: (state: BrowserSidebarState) => boolean
        ) => {
          // Chromium can need several seconds to load with 32 live sessions.
          // Keep the 200-probe bound, but do not treat a 2s load as failure.
          let lastState: BrowserSidebarState | undefined;
          for (let attempt = 0; attempt < 200; attempt += 1) {
            const state = await bridge.browserSidebar.update({
              bounds: nextBounds,
              sessionId,
            });
            lastState = state;
            if (predicate(state)) return state;
            await new Promise((resolveWait) => setTimeout(resolveWait, 50));
          }
          throw new Error(
            `Browser session ${sessionId} did not reach expected state: ${JSON.stringify(lastState)}`
          );
        };
        for (let index = 0; index <= sessionLimit; index += 1) {
          await bridge.browserSidebar.open({
            bounds: nextBounds,
            sessionId: `lru-host-${index}`,
            url: `${baseUrl}/lru-${index}`,
          });
        }
        const beforeRevisit = (await bridge.surfaces.list()).views.filter(
          (view) => view.role === "browser-sidebar"
        );
        const revisited = await bridge.browserSidebar.open({
          bounds: nextBounds,
          sessionId: "lru-host-0",
          url: `${baseUrl}/revisited`,
        });
        const afterRevisit = (await bridge.surfaces.list()).views.filter(
          (view) => view.role === "browser-sidebar"
        );

        const protectedSessionId = "fenced-protected-host";
        const victimSessionId = "fenced-renderer-victim";
        const replacementSessionId = "fenced-replacement";
        await bridge.browserSidebar.open({
          bounds: nextBounds,
          sessionId: protectedSessionId,
          url: `${baseUrl}/protected-one`,
        });
        await waitForState(
          protectedSessionId,
          (state) => state.loading === false && state.url === `${baseUrl}/protected-one`
        );
        await bridge.browserSidebar.update({
          sessionId: protectedSessionId,
          url: `${baseUrl}/protected-two`,
        });
        await waitForState(
          protectedSessionId,
          (state) =>
            state.canGoBack === true &&
            state.loading === false &&
            state.url === `${baseUrl}/protected-two`
        );
        await bridge.browserSidebar.navigate({
          action: "back",
          sessionId: protectedSessionId,
        });
        const protectedBack = await waitForState(
          protectedSessionId,
          (state) =>
            state.canGoForward === true &&
            state.loading === false &&
            state.url === `${baseUrl}/protected-one`
        );

        await bridge.browserSidebar.open({
          bounds: nextBounds,
          sessionId: victimSessionId,
          url: `${baseUrl}/victim`,
        });
        await waitForState(
          victimSessionId,
          (state) => state.loading === false && state.url === `${baseUrl}/victim`
        );
        // Make the unrelated history-bearing session the native LRU victim. The
        // renderer-selected victim must be closed instead when replacement opens.
        for (let index = 4; index <= sessionLimit; index += 1) {
          await bridge.browserSidebar.update({
            bounds: nextBounds,
            sessionId: `lru-host-${index}`,
          });
        }
        await bridge.browserSidebar.update({
          bounds: nextBounds,
          sessionId: "lru-host-0",
        });
        const beforeFencedAdmission = (await bridge.surfaces.list()).views.filter(
          (view) => view.role === "browser-sidebar"
        );
        const replacement = await bridge.browserSidebar.open({
          bounds: nextBounds,
          closeBeforeOpenSessionIds: [victimSessionId],
          sessionId: replacementSessionId,
          url: `${baseUrl}/replacement`,
        });
        await waitForState(
          replacementSessionId,
          (state) => state.loading === false && state.url === `${baseUrl}/replacement`
        );
        const afterFencedAdmission = (await bridge.surfaces.list()).views.filter(
          (view) => view.role === "browser-sidebar"
        );
        await bridge.browserSidebar.navigate({
          action: "forward",
          sessionId: protectedSessionId,
        });
        const protectedForward = await waitForState(
          protectedSessionId,
          (state) =>
            state.canGoBack === true &&
            state.loading === false &&
            state.url === `${baseUrl}/protected-two`
        );

        return {
          afterFencedAdmission,
          afterRevisit,
          beforeFencedAdmission,
          beforeRevisit,
          protectedBack,
          protectedForward,
          protectedSessionId,
          replacement,
          replacementSessionId,
          revisited,
          victimSessionId,
        };
      },
      {
        baseUrl: browserStub.baseUrl,
        bounds,
        sessionLimit: maxBrowserSidebarSessionsPerOwner,
      }
    );
    expect(boundedSessions.beforeRevisit).toHaveLength(
      maxBrowserSidebarSessionsPerOwner
    );
    expect(
      boundedSessions.beforeRevisit.some((view) => view.id.includes("lru-host-0"))
    ).toBe(false);
    expect(boundedSessions.afterRevisit).toHaveLength(
      maxBrowserSidebarSessionsPerOwner
    );
    expect(boundedSessions.revisited).toMatchObject({
      active: true,
      url: `${browserStub.baseUrl}/revisited`,
    });
    expect(boundedSessions.beforeFencedAdmission).toHaveLength(
      maxBrowserSidebarSessionsPerOwner
    );
    expect(
      boundedSessions.beforeFencedAdmission.some((view) =>
        view.id.includes(boundedSessions.protectedSessionId)
      )
    ).toBe(true);
    expect(
      boundedSessions.beforeFencedAdmission.some((view) =>
        view.id.includes(boundedSessions.victimSessionId)
      )
    ).toBe(true);
    expect(boundedSessions.protectedBack).toMatchObject({
      canGoForward: true,
      url: `${browserStub.baseUrl}/protected-one`,
    });
    expect(boundedSessions.afterFencedAdmission).toHaveLength(
      maxBrowserSidebarSessionsPerOwner
    );
    expect(
      boundedSessions.afterFencedAdmission.some((view) =>
        view.id.includes(boundedSessions.protectedSessionId)
      )
    ).toBe(true);
    expect(
      boundedSessions.afterFencedAdmission.some((view) =>
        view.id.includes(boundedSessions.victimSessionId)
      )
    ).toBe(false);
    expect(
      boundedSessions.afterFencedAdmission.some((view) =>
        view.id.includes(boundedSessions.replacementSessionId)
      )
    ).toBe(true);
    expect(boundedSessions.replacement).toMatchObject({
      active: true,
      sessionId: boundedSessions.replacementSessionId,
      url: `${browserStub.baseUrl}/replacement`,
    });
    expect(boundedSessions.protectedForward).toMatchObject({
      canGoBack: true,
      url: `${browserStub.baseUrl}/protected-two`,
    });

    const reportingFailureVictims = await appWindow.evaluate(
      async ({ baseUrl, bounds: nextBounds }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        const victims = ["reporting-victim-one", "reporting-victim-two"];
        for (const [index, sessionId] of victims.entries()) {
          const url = `${baseUrl}/reporting-victim-${index + 1}`;
          await bridge.browserSidebar.open({
            bounds: nextBounds,
            sessionId,
            url,
          });
          for (let attempt = 0; attempt < 200; attempt += 1) {
            const state = await bridge.browserSidebar.update({
              bounds: nextBounds,
              sessionId,
            });
            if (state.loading === false && state.url === url) break;
            await new Promise((resolveWait) => setTimeout(resolveWait, 10));
          }
        }
        return {
          firstUrl: `${baseUrl}/reporting-victim-1`,
          victims,
        };
      },
      { baseUrl: browserStub.baseUrl, bounds }
    );
    await expect
      .poll(() =>
        app.evaluate(({ webContents }, victimUrl) => {
          return webContents
            .getAllWebContents()
            .some((contents) => contents.getURL() === victimUrl);
        }, reportingFailureVictims.firstUrl)
      )
      .toBe(true);
    await app.evaluate(({ webContents }, victimUrl) => {
      const victim = webContents
        .getAllWebContents()
        .find((contents) => contents.getURL() === victimUrl);
      if (!victim) throw new Error(`Native victim not found for ${victimUrl}`);
      const originalClose = victim.close.bind(victim);
      Object.defineProperty(victim, "close", {
        configurable: true,
        value: () => {
          originalClose();
          throw new Error("injected reporting failure after WebContents destruction");
        },
      });
    }, reportingFailureVictims.firstUrl);
    const reportingFailureAdmission = await appWindow.evaluate(
      async ({ baseUrl, bounds: nextBounds, victims }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        const replacementSessionId = "reporting-failure-replacement";
        const replacement = await bridge.browserSidebar.open({
          bounds: nextBounds,
          closeBeforeOpenSessionIds: victims,
          sessionId: replacementSessionId,
          url: `${baseUrl}/reporting-failure-replacement`,
        });
        return {
          replacement,
          replacementSessionId,
          surfaces: (await bridge.surfaces.list()).views.filter(
            (view) => view.role === "browser-sidebar"
          ),
          victimStates: await Promise.all(
            victims.map((sessionId) =>
              bridge.browserSidebar.update({
                bounds: nextBounds,
                sessionId,
              })
            )
          ),
        };
      },
      {
        baseUrl: browserStub.baseUrl,
        bounds,
        victims: reportingFailureVictims.victims,
      }
    );
    expect(reportingFailureAdmission.victimStates).toEqual([
      expect.objectContaining({ active: false }),
      expect.objectContaining({ active: false }),
    ]);
    expect(reportingFailureAdmission.replacement).toMatchObject({
      active: true,
      sessionId: reportingFailureAdmission.replacementSessionId,
    });
    for (const victim of reportingFailureVictims.victims) {
      expect(
        reportingFailureAdmission.surfaces.some((view) => view.id.includes(victim))
      ).toBe(false);
    }
    expect(
      reportingFailureAdmission.surfaces.some((view) =>
        view.id.includes(reportingFailureAdmission.replacementSessionId)
      )
    ).toBe(true);

    const partialFailureVictims = await appWindow.evaluate(
      async ({ baseUrl, bounds: nextBounds }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        const victims = ["partial-victim-one", "partial-victim-two"];
        for (const [index, sessionId] of victims.entries()) {
          const url = `${baseUrl}/partial-victim-${index + 1}`;
          await bridge.browserSidebar.open({
            bounds: nextBounds,
            sessionId,
            url,
          });
          for (let attempt = 0; attempt < 200; attempt += 1) {
            const state = await bridge.browserSidebar.update({
              bounds: nextBounds,
              sessionId,
            });
            if (state.loading === false && state.url === url) break;
            await new Promise((resolveWait) => setTimeout(resolveWait, 10));
          }
        }
        return {
          firstUrl: `${baseUrl}/partial-victim-1`,
          victims,
        };
      },
      { baseUrl: browserStub.baseUrl, bounds }
    );
    await app.evaluate(({ webContents }, victimUrl) => {
      const victim = webContents
        .getAllWebContents()
        .find((contents) => contents.getURL() === victimUrl);
      if (!victim) throw new Error(`Native victim not found for ${victimUrl}`);
      const originalClose = victim.close.bind(victim);
      let rejectFirstClose = true;
      Object.defineProperty(victim, "close", {
        configurable: true,
        value: () => {
          if (rejectFirstClose) {
            rejectFirstClose = false;
            throw new Error("injected close failure before WebContents destruction");
          }
          originalClose();
        },
      });
    }, partialFailureVictims.firstUrl);
    const partialFailureReplacementSessionId = "partial-failure-replacement";
    const firstPartialFailureAdmission = await appWindow.evaluate(
      async ({ baseUrl, bounds: nextBounds, replacementSessionId, victims }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        const replacement = await bridge.browserSidebar.open({
          bounds: nextBounds,
          closeBeforeOpenSessionIds: victims,
          sessionId: replacementSessionId,
          url: `${baseUrl}/partial-replacement`,
        });
        return {
          replacement,
          replacementSessionId,
          surfaces: (await bridge.surfaces.list()).views.filter(
            (view) => view.role === "browser-sidebar"
          ),
          victimStates: await Promise.all(
            victims.map((sessionId) =>
              bridge.browserSidebar.update({
                bounds: nextBounds,
                sessionId,
              })
            )
          ),
        };
      },
      {
        baseUrl: browserStub.baseUrl,
        bounds,
        replacementSessionId: partialFailureReplacementSessionId,
        victims: partialFailureVictims.victims,
      }
    );
    expect(firstPartialFailureAdmission.replacement).toMatchObject({
      active: false,
      reasonCode: "capacity",
      sessionId: partialFailureReplacementSessionId,
    });
    expect(firstPartialFailureAdmission.victimStates).toEqual([
      expect.objectContaining({ active: true }),
      expect.objectContaining({ active: true }),
    ]);
    expect(
      firstPartialFailureAdmission.surfaces.some((view) =>
        view.id.includes(partialFailureVictims.victims[0] ?? "missing-victim")
      )
    ).toBe(true);
    expect(
      firstPartialFailureAdmission.surfaces.some((view) =>
        view.id.includes(partialFailureVictims.victims[1] ?? "missing-victim")
      )
    ).toBe(true);
    expect(
      firstPartialFailureAdmission.surfaces.some((view) =>
        view.id.includes(partialFailureReplacementSessionId)
      )
    ).toBe(false);

    const retriedPartialFailureAdmission = await appWindow.evaluate(
      async ({ baseUrl, bounds: nextBounds, replacementSessionId, victims }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        const replacement = await bridge.browserSidebar.open({
          bounds: nextBounds,
          closeBeforeOpenSessionIds: victims,
          sessionId: replacementSessionId,
          url: `${baseUrl}/partial-replacement`,
        });
        return {
          replacement,
          surfaces: (await bridge.surfaces.list()).views.filter(
            (view) => view.role === "browser-sidebar"
          ),
          victimStates: await Promise.all(
            victims.map((sessionId) =>
              bridge.browserSidebar.update({
                bounds: nextBounds,
                sessionId,
              })
            )
          ),
        };
      },
      {
        baseUrl: browserStub.baseUrl,
        bounds,
        replacementSessionId: partialFailureReplacementSessionId,
        victims: partialFailureVictims.victims,
      }
    );
    expect(retriedPartialFailureAdmission.victimStates).toEqual([
      expect.objectContaining({ active: false }),
      expect.objectContaining({ active: false }),
    ]);
    expect(retriedPartialFailureAdmission.replacement).toMatchObject({
      active: true,
      sessionId: partialFailureReplacementSessionId,
    });
    for (const victim of partialFailureVictims.victims) {
      expect(
        retriedPartialFailureAdmission.surfaces.some((view) => view.id.includes(victim))
      ).toBe(false);
    }

    const staleFailureSessionId = "stale-failure-host";
    const staleFailureCurrentUrl = `${browserStub.baseUrl}/generation-current`;
    await appWindow.evaluate(
      async ({ bounds: nextBounds, sessionId, url }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        await bridge.browserSidebar.open({
          bounds: nextBounds,
          sessionId,
          url,
        });
        for (let attempt = 0; attempt < 200; attempt += 1) {
          const state = await bridge.browserSidebar.update({
            bounds: nextBounds,
            sessionId,
          });
          if (state.loading === false && state.url === url) return;
          await new Promise((resolveWait) => setTimeout(resolveWait, 10));
        }
        throw new Error(`Browser session ${sessionId} did not finish ${url}`);
      },
      {
        bounds,
        sessionId: staleFailureSessionId,
        url: staleFailureCurrentUrl,
      }
    );
    await app.evaluate(
      ({ webContents }, { currentUrl, failedUrl }) => {
        const current = webContents
          .getAllWebContents()
          .find((contents) => contents.getURL() === currentUrl);
        if (!current) {
          throw new Error(`Native browser contents not found for ${currentUrl}`);
        }
        current.emit(
          "did-fail-load",
          {} as Electron.Event,
          -105,
          "ERR_NAME_NOT_RESOLVED",
          failedUrl,
          true,
          0,
          0
        );
      },
      {
        currentUrl: staleFailureCurrentUrl,
        failedUrl: `${browserStub.baseUrl}/generation-old`,
      }
    );
    await expect
      .poll(() => readNativeBrowserState(staleFailureSessionId))
      .toMatchObject({
        active: true,
        loading: false,
        url: staleFailureCurrentUrl,
      });
    expect(await readNativeBrowserState(staleFailureSessionId)).not.toHaveProperty(
      "reason"
    );

    const cancellation = await appWindow.evaluate(
      async ({ baseUrl, bounds: nextBounds }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        const recoveredStates = [];
        const stoppedStates = [];
        for (let index = 0; index < 3; index += 1) {
          const supersededSessionId = `superseded-host-${index}`;
          await bridge.browserSidebar.open({
            bounds: nextBounds,
            sessionId: supersededSessionId,
            url: `${baseUrl}/hang`,
          });
          await bridge.browserSidebar.update({
            sessionId: supersededSessionId,
            url: `${baseUrl}/recovered`,
          });
          let recovered;
          for (let attempt = 0; attempt < 200; attempt += 1) {
            recovered = await bridge.browserSidebar.update({
              bounds: nextBounds,
              sessionId: supersededSessionId,
            });
            if (
              recovered.url === `${baseUrl}/recovered` &&
              recovered.loading === false
            ) {
              break;
            }
            await new Promise((resolveWait) => setTimeout(resolveWait, 10));
          }
          recoveredStates.push(recovered);

          const stoppedSessionId = `stopped-host-${index}`;
          await bridge.browserSidebar.open({
            bounds: nextBounds,
            sessionId: stoppedSessionId,
            url: `${baseUrl}/hang`,
          });
          await bridge.browserSidebar.navigate({
            action: "stop",
            sessionId: stoppedSessionId,
          });
          await bridge.browserSidebar.update({
            sessionId: stoppedSessionId,
            visible: false,
          });
          stoppedStates.push(
            await bridge.browserSidebar.update({
              sessionId: stoppedSessionId,
              visible: true,
            })
          );
        }
        return { recoveredStates, stoppedStates };
      },
      { baseUrl: browserStub.baseUrl, bounds }
    );
    for (const recovered of cancellation.recoveredStates) {
      expect(recovered).toMatchObject({
        loading: false,
        url: `${browserStub.baseUrl}/recovered`,
      });
      expect(recovered).not.toHaveProperty("reason");
    }
    for (const stopped of cancellation.stoppedStates) {
      expect(stopped).not.toHaveProperty("reason");
    }

    await appWindow.evaluate(
      async ({ baseUrl, bounds: nextBounds }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        await bridge.browserSidebar.open({
          bounds: nextBounds,
          sessionId: "reload-host",
          url: `${baseUrl}/recovered`,
        });
      },
      { baseUrl: browserStub.baseUrl, bounds }
    );
    // Reload from the workspace chat so the fresh renderer owns only that
    // conversation channel before the 31-host LRU fixture is populated.
    await appWindow.goBack();
    await expect(
      content.getByRole("button", {
        exact: true,
        name: `Task: ${lruTaskRefs[0]!.title}`,
      })
    ).toBeVisible();
    await appWindow.reload({ waitUntil: "domcontentloaded" });
    await expect
      .poll(() =>
        appWindow.evaluate(async () => {
          const bridge = window.commaNative;
          if (!bridge) throw new Error("Native bridge is unavailable");
          return (await bridge.surfaces.list()).views.filter(
            (view) => view.role === "browser-sidebar"
          );
        })
      )
      .toEqual([]);

    await appWindow.evaluate(() => {
      const bridge = window.commaNative;
      if (!bridge) throw new Error("Native bridge is unavailable");
      const testWindow = window as typeof window & {
        e2eBrowserSidebarOpenCalls?: Array<{
          closeBeforeOpenSessionIds?: string[] | undefined;
          navigationRevision?: number | undefined;
          sessionId: string;
          url: string;
        }>;
        e2eChatRetainCalls?: Array<Parameters<typeof bridge.chat.retain>[0]>;
      };
      const originalOpen = bridge.browserSidebar.open.bind(bridge.browserSidebar);
      const originalChatRetain = bridge.chat.retain.bind(bridge.chat);
      testWindow.e2eBrowserSidebarOpenCalls = [];
      testWindow.e2eChatRetainCalls = [];
      window.commaNative = {
        ...bridge,
        browserSidebar: {
          ...bridge.browserSidebar,
          open: (input) => {
            testWindow.e2eBrowserSidebarOpenCalls?.push({
              closeBeforeOpenSessionIds: input.closeBeforeOpenSessionIds,
              navigationRevision: input.navigationRevision,
              sessionId: input.sessionId,
              url: input.url,
            });
            return originalOpen(input);
          },
        },
        chat: {
          ...bridge.chat,
          retain: (input) => {
            testWindow.e2eChatRetainCalls?.push(input);
            return originalChatRetain(input);
          },
        },
      };
    });

    const lruTaskButton = (task: (typeof lruTaskRefs)[number]) =>
      content.getByRole("button", {
        exact: true,
        name: `Task: ${task.title}`,
      });
    const waitForLruHome = async () => {
      await expect(lruTaskButton(lruTaskRefs[0]!)).toBeVisible();
    };
    const openLruTaskBrowser = async (task: (typeof lruTaskRefs)[number]) => {
      await lruTaskButton(task).click();
      await sidebar.getByRole("button", { exact: true, name: "Open task" }).click();
      const browserLink = content.getByTestId("comma-route-outlet").getByRole("link", {
        exact: true,
        name: task.browserLink.label,
      });
      await expect(browserLink).toBeVisible();
      await browserLink.click();
      await expect(appWindow).toHaveURL(
        new RegExp(
          `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${task.id}$`
        )
      );
      await expect(sidebar.getByRole("textbox", { name: "Address" })).toHaveValue(
        task.browserLink.url
      );
      const hostSessionId = JSON.stringify([chatSmokeWorkspace.group_id, task.id]);
      const sessionId = await activePageSessionId(hostSessionId);
      await expect
        .poll(() => readNativeBrowserState(sessionId))
        .toMatchObject({
          active: true,
          loading: false,
          url: task.browserLink.url,
          visible: true,
        });
      return sessionId;
    };
    const releaseLruTaskChat = (task: (typeof lruTaskRefs)[number]) =>
      appWindow.evaluate(async (conversationId) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        const testWindow = window as typeof window & {
          e2eChatRetainCalls?: Array<Parameters<typeof bridge.chat.retain>[0]>;
        };
        const lease = testWindow.e2eChatRetainCalls
          ?.filter((call) => call.conversationId === conversationId)
          .at(-1);
        if (!lease) throw new Error(`Chat lease not found for ${conversationId}`);
        await bridge.chat.release(lease);
      }, task.id);
    const hasRetainedLruTaskChat = (task: (typeof lruTaskRefs)[number]) =>
      appWindow.evaluate(async (conversationId) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        const testWindow = window as typeof window & {
          e2eChatRetainCalls?: Array<Parameters<typeof bridge.chat.retain>[0]>;
        };
        const lease = testWindow.e2eChatRetainCalls
          ?.filter((call) => call.conversationId === conversationId)
          .at(-1);
        if (!lease) throw new Error(`Chat lease not found for ${conversationId}`);
        return (
          await bridge.chat.state.get({ session: lease.session })
        ).snapshot.sessions.some(
          (session) => session.conversationId === conversationId
        );
      }, task.id);

    // Advance the real Main-owned lease expiry instead of spending 30 seconds
    // idle. Install before these leases are released; other processes keep
    // their real clocks, and production retention policy stays unchanged.
    const mainClock = await app.evaluateHandle(
      (_electron, modulePath) => {
        const require = process.getBuiltinModule("module").createRequire(modulePath);
        const timers: typeof import("@sinonjs/fake-timers") = require(modulePath);
        return timers.install({
          toFake: ["setTimeout", "clearTimeout"],
          shouldAdvanceTime: true,
          shouldClearNativeTimers: true,
        });
      },
      createRequire(resolve(process.cwd(), "package.json")).resolve(
        "@sinonjs/fake-timers"
      )
    );
    await waitForLruHome();
    const initialLruSessionIds: string[] = [];
    for (let index = 0; index < maxBrowserSidebarSessionsPerOwner - 1; index += 1) {
      const task = lruTaskRefs[index];
      if (!task) throw new Error(`Missing LRU task ${index}`);
      if (index === maxBrowserSidebarSessionsPerOwner - 2) {
        await mainClock.evaluate((clock) => clock.tickAsync(30_000));
        await expect.poll(() => hasRetainedLruTaskChat(lruTaskRefs[1]!)).toBe(false);
      }
      initialLruSessionIds.push(await openLruTaskBrowser(task));
      await appWindow.goBack();
      await waitForLruHome();
      if (index > 0) await releaseLruTaskChat(task);
    }

    const touchedTask = lruTaskRefs[0]!;
    const touchedSessionId = initialLruSessionIds[0]!;
    const nextOldestSessionId = initialLruSessionIds[1]!;
    await lruTaskButton(touchedTask).click();
    await expect(
      sidebar.getByRole("link", {
        exact: true,
        name: touchedTask.browserLink.label,
      })
    ).toBeVisible();
    await sidebar.getByRole("button", { name: "Open task" }).click();
    await expect(appWindow).toHaveURL(
      new RegExp(
        `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${touchedTask.id}$`
      )
    );
    const touchedAddress = sidebar.getByRole("textbox", { name: "Address" });
    await expect(touchedAddress).toHaveValue(touchedTask.browserLink.url);
    const touchedUrl = `${browserStub.baseUrl}/lru-task-0-two`;
    await touchedAddress.fill(touchedUrl);
    await touchedAddress.press("Enter");
    await expect
      .poll(() => readNativeBrowserState(touchedSessionId))
      .toMatchObject({
        active: true,
        canGoBack: true,
        loading: false,
        url: touchedUrl,
      });
    await sidebar.getByRole("button", { name: "Back" }).click();
    await expect
      .poll(() => readNativeBrowserState(touchedSessionId))
      .toMatchObject({
        active: true,
        canGoForward: true,
        loading: false,
        url: touchedTask.browserLink.url,
      });

    await appWindow.goBack();
    await waitForLruHome();
    const admittedTask = lruTaskRefs.at(-1)!;
    const admittedSessionId = await openLruTaskBrowser(admittedTask);
    await expect
      .poll(() =>
        appWindow.evaluate(
          ({ sessionId, url }) => {
            const testWindow = window as typeof window & {
              e2eBrowserSidebarOpenCalls?: Array<{
                closeBeforeOpenSessionIds?: string[] | undefined;
                sessionId: string;
                url: string;
              }>;
            };
            return testWindow.e2eBrowserSidebarOpenCalls
              ?.filter((call) => call.sessionId === sessionId && call.url === url)
              .at(-1)?.closeBeforeOpenSessionIds;
          },
          { sessionId: admittedSessionId, url: admittedTask.browserLink.url }
        )
      )
      .toEqual([nextOldestSessionId]);
    await expect
      .poll(() => readNativeBrowserState(nextOldestSessionId))
      .toMatchObject({ active: false });
    await expect
      .poll(() => readNativeBrowserState(touchedSessionId))
      .toMatchObject({
        active: true,
        canGoForward: true,
        url: touchedTask.browserLink.url,
        visible: false,
      });
    await expect
      .poll(() => readNativeBrowserState(admittedSessionId))
      .toMatchObject({
        active: true,
        loading: false,
        url: admittedTask.browserLink.url,
        visible: true,
      });

    await appWindow.goBack();
    await waitForLruHome();
    await lruTaskButton(touchedTask).click();
    await expect(
      sidebar.getByRole("link", {
        exact: true,
        name: touchedTask.browserLink.label,
      })
    ).toBeVisible();
    await sidebar.getByRole("button", { name: "Open task" }).click();
    await expect(appWindow).toHaveURL(
      new RegExp(
        `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${touchedTask.id}$`
      )
    );
    await expect(sidebar.getByRole("button", { name: "Forward" })).toBeEnabled();
    await sidebar.getByRole("button", { name: "Forward" }).click();
    await expect
      .poll(() => readNativeBrowserState(touchedSessionId))
      .toMatchObject({
        active: true,
        loading: false,
        url: touchedUrl,
        visible: true,
      });

    await appWindow.goBack();
    await waitForLruHome();
    await appWindow.evaluate(
      async (sessionIds) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        await Promise.all(
          sessionIds.map((sessionId) => bridge.browserSidebar.close({ sessionId }))
        );
      },
      [...initialLruSessionIds, admittedSessionId]
    );

    await appWindow.evaluate(
      async ({
        baseUrl,
        bounds: nextBounds,
        productSessionId: activeProductSession,
      }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        await Promise.all([
          bridge.browserSidebar.close({ sessionId: activeProductSession }),
          bridge.browserSidebar.close({ sessionId: "host-a" }),
          bridge.browserSidebar.close({ sessionId: "host-b" }),
        ]);
        await bridge.browserSidebar.open({
          bounds: nextBounds,
          sessionId: "hanging-host",
          url: `${baseUrl}/hang`,
        });
        await bridge.browserSidebar.navigate({
          action: "stop",
          sessionId: "hanging-host",
        });
        await bridge.browserSidebar.update({
          sessionId: "hanging-host",
          visible: false,
        });
        await bridge.browserSidebar.close({ sessionId: "hanging-host" });
        await bridge.browserSidebar.open({
          bounds: nextBounds,
          sessionId: "quit-host",
          url: `${baseUrl}/hang`,
        });
      },
      { baseUrl: browserStub.baseUrl, bounds, productSessionId }
    );

    await expect(
      Promise.race([
        app.close().then(() => "closed"),
        new Promise<string>((resolveTimeout) =>
          setTimeout(() => resolveTimeout("timeout"), 3_000)
        ),
      ])
    ).resolves.toBe("closed");
    appClosed = true;
  } finally {
    if (!appClosed) await app.close();
    await apiStub.close();
    await browserStub.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});

test("a browser tab shows the page icon and keeps it across a reload", async () => {
  const browserStub = await startBrowserStub();
  const apiStub = await startChatSmokeStub({
    assistantReply: `[Open icon page](${browserStub.baseUrl}/icon-page)`,
  });
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-browser-favicon-e2e-"));
  recordElectronOnboardingCompleted(userDataDir, [apiStub.userId]);
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...hostEnv,
      COMMA_API_BASE_URL: apiStub.baseUrl,
      COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "browser-favicon@comma.local",
      COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "browser-favicon-session-token",
      NODE_ENV: "test",
    },
  });
  try {
    const appWindow = await findElectronWindowByNativeRole(app, "main-window");
    const content = appWindow.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("Open icon page");
    await composer.getByRole("button", { name: "Send" }).click();
    await content.getByRole("link", { name: "Open icon page" }).click();

    const tab = content.locator(".comma-right-sidebar-tab").first();
    const tabIcon = tab.locator("img");
    const iconDecoded = () =>
      tabIcon.evaluate(
        (image: HTMLImageElement) =>
          image.complete &&
          image.naturalWidth > 0 &&
          image.src.startsWith("data:image/png")
      );
    await expect(tab).toContainText("Icon page");
    await expect.poll(iconDecoded).toBe(true);

    // A reloaded document declares the same icons, so Chromium sends no new
    // icon list. The tab must keep its icon instead of falling back.
    await content.getByRole("button", { name: "Reload" }).click();
    await expect.poll(() => browserStub.pageLoads("/icon-page")).toBe(2);
    await expect(content.getByRole("button", { name: "Reload" })).toBeVisible();
    await appWindow.waitForTimeout(300);
    await expect(tabIcon).toHaveCount(1);
    expect(await iconDecoded()).toBe(true);

    // A page that declares no icon shows the generic icon.
    const address = content.getByRole("textbox", { name: "Address" });
    await address.fill(`${browserStub.baseUrl}/no-icon`);
    await address.press("Enter");
    await expect(tab).toContainText("No icon");
    await expect(tabIcon).toHaveCount(0);

    const sidebar = content.getByTestId("chat-sidebar");
    await tab.hover();
    await sidebar.getByRole("button", { name: "Close No icon" }).click();
    await expect(sidebar).toHaveAttribute("data-open", "false");
    await expect(appWindow.getByTestId("chat-sidebar-toggle")).toHaveAttribute(
      "aria-expanded",
      "false"
    );
    await expect.poll(async () => (await sidebar.boundingBox())?.width ?? 0).toBe(0);
    await expect
      .poll(() =>
        app.evaluate(
          ({ webContents }, url) =>
            webContents
              .getAllWebContents()
              .some((contents) => contents.getURL() === url),
          `${browserStub.baseUrl}/no-icon`
        )
      )
      .toBe(false);
  } finally {
    await app.close();
    await apiStub.close();
    await browserStub.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});

test("sign-out closes every native browser sidebar session", async () => {
  const browserStub = await startBrowserStub();
  const apiStub = await startChatSmokeStub();
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-browser-sign-out-e2e-"));
  recordElectronOnboardingCompleted(userDataDir, [apiStub.userId]);
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...hostEnv,
      COMMA_API_BASE_URL: apiStub.baseUrl,
      COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "browser-sign-out@comma.local",
      COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "browser-sign-out-session-token",
      NODE_ENV: "test",
    },
  });

  try {
    const appWindow = await findElectronWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await appWindow.evaluate(
      async ({ baseUrl }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        await bridge.browserSidebar.open({
          bounds: { height: 500, width: 400, x: 800, y: 40 },
          sessionId: "sign-out-host",
          url: `${baseUrl}/hang`,
        });
        const lifecycle = await bridge.session.state.get();
        if (lifecycle.phase !== "signed_in") {
          throw new Error("Browser sign-out E2E requires a signed-in session.");
        }
        const result = await bridge.session.signOut({
          expected: {
            authorityInstanceId: lifecycle.authority.authorityInstanceId,
            expectedAudience: lifecycle.session.audience,
            expectedSessionId: lifecycle.session.sessionId,
            generation: lifecycle.generation,
          },
        });
        if (!result.ok) {
          throw new Error(`Native sign-out failed: ${result.error.code}`);
        }
      },
      { baseUrl: browserStub.baseUrl }
    );

    await expect
      .poll(() =>
        appWindow.evaluate(async () => {
          const bridge = window.commaNative;
          if (!bridge) throw new Error("Native bridge is unavailable");
          return (await bridge.surfaces.list()).views.filter(
            (view) => view.role === "browser-sidebar"
          );
        })
      )
      .toEqual([]);
  } finally {
    await app.close();
    await apiStub.close();
    await browserStub.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});

test("a sign-in popup opens on a click, stays in the page's session, and never opens unprompted", async () => {
  const browserStub = await startBrowserStub();
  const apiStub = await startChatSmokeStub();
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-browser-popup-e2e-"));
  recordElectronOnboardingCompleted(userDataDir, [apiStub.userId]);
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  const app = await electron.launch({
    args: [electronMain, `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: {
      ...hostEnv,
      COMMA_API_BASE_URL: apiStub.baseUrl,
      COMMA_ELECTRON_E2E_SESSION_EMAIL: "browser-popup@comma.local",
      COMMA_ELECTRON_E2E_SESSION_TOKEN: "browser-popup-session-token",
      NODE_ENV: "test",
    },
  });

  const readSignInProbe = () =>
    app.evaluate(async ({ webContents }, signInUrl) => {
      const page = webContents
        .getAllWebContents()
        .find((contents) => contents.getURL() === signInUrl);
      if (!page) return undefined;
      return (await page.executeJavaScript(
        `({ ...window.signInProbe, popupClosed: window.signInPopup ? window.signInPopup.closed : undefined })`
      )) as {
        clicked?: string;
        escape?: string;
        handshake?: string;
        popupClosed?: boolean;
        releaseDown?: string;
        releaseUp?: string;
        unprompted?: string;
      };
    }, `${browserStub.baseUrl}/signin`);

  try {
    const appWindow = await findElectronWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await appWindow.evaluate(
      async ({ baseUrl }) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        await bridge.browserSidebar.open({
          bounds: { height: 500, width: 400, x: 800, y: 40 },
          sessionId: "popup-host",
          url: `${baseUrl}/signin`,
        });
      },
      { baseUrl: browserStub.baseUrl }
    );

    // Load-time window.open, with no gesture behind it, is the popup spam the
    // blanket deny used to be the only defence against.
    await expect
      .poll(() => readSignInProbe().then((probe) => probe?.unprompted))
      .toBe("blocked");
    expect(
      await app.evaluate(
        ({ webContents }, oauthUrl) =>
          webContents
            .getAllWebContents()
            .filter((contents) => contents.getURL() === oauthUrl).length,
        `${browserStub.baseUrl}/oauth`
      )
    ).toBe(0);

    // Escape is an explicit exception to HTML's user-activation model. It must
    // not turn a keyboard dismissal into permission for a native popup.
    await app.evaluate(({ webContents }, signInUrl) => {
      const page = webContents
        .getAllWebContents()
        .find((contents) => contents.getURL() === signInUrl);
      if (!page) throw new Error("Browser sidebar sign-in page is not loaded");
      page.sendInputEvent({ keyCode: "Escape", type: "keyDown" });
      page.sendInputEvent({ keyCode: "Escape", type: "keyUp" });
    }, `${browserStub.baseUrl}/signin`);
    await expect
      .poll(() => readSignInProbe().then((probe) => probe?.escape))
      .toBe("blocked");

    // The down event may spend one activation. Releasing that same physical
    // click must not mint a second budget for another window.
    await app.evaluate(async ({ webContents }, signInUrl) => {
      const page = webContents
        .getAllWebContents()
        .find((contents) => contents.getURL() === signInUrl);
      if (!page) throw new Error("Browser sidebar sign-in page is not loaded");
      const sendMouseInput = (type: "mouseDown" | "mouseUp") =>
        new Promise<void>((resolveInput) => {
          const inputListener = (
            _event: Electron.Event,
            input: Electron.InputEvent
          ) => {
            if (input.type !== type) return;
            page.removeListener("before-mouse-event", inputListener);
            resolveInput();
          };
          page.on("before-mouse-event", inputListener);
          page.sendInputEvent({
            button: "left",
            clickCount: 1,
            type,
            x: 160,
            y: 80,
          });
        });

      await sendMouseInput("mouseDown");
      await page.executeJavaScript(`
        (() => {
          const popup = window.open(
            "/popup-probe",
            "release-down-probe",
            "width=300,height=300"
          );
          window.signInProbe.releaseDown =
            popup === null ? "blocked" : "opened";
          popup?.close();
        })()
      `);
      await sendMouseInput("mouseUp");
      await page.executeJavaScript(`
        (() => {
          const popup = window.open(
            "/popup-probe",
            "release-up-probe",
            "width=300,height=300"
          );
          window.signInProbe.releaseUp =
            popup === null ? "blocked" : "opened";
          popup?.close();
        })()
      `);
    }, `${browserStub.baseUrl}/signin`);
    await expect
      .poll(() => readSignInProbe().then((probe) => probe?.releaseDown))
      .toBe("opened");
    await expect
      .poll(() => readSignInProbe().then((probe) => probe?.releaseUp))
      .toBe("blocked");

    // A real click on the provider button: this is the gesture Chromium would
    // spend on one popup, so the page must get a live WindowProxy back.
    await app.evaluate(({ webContents }, signInUrl) => {
      const page = webContents
        .getAllWebContents()
        .find((contents) => contents.getURL() === signInUrl);
      if (!page) throw new Error("Browser sidebar sign-in page is not loaded");
      page.sendInputEvent({
        button: "left",
        clickCount: 1,
        type: "mouseDown",
        x: 160,
        y: 80,
      });
      page.sendInputEvent({
        button: "left",
        clickCount: 1,
        type: "mouseUp",
        x: 160,
        y: 80,
      });
    }, `${browserStub.baseUrl}/signin`);

    await expect
      .poll(() => readSignInProbe().then((probe) => probe?.clicked))
      .toBe("opened");

    const handshake = await expect
      .poll(() => readSignInProbe().then((probe) => probe?.handshake))
      .toBeDefined()
      .then(() => readSignInProbe().then((probe) => JSON.parse(probe!.handshake!)));

    // The redirect the provider lands on must reach the opener, and must carry
    // the cookies the opener already holds — that is the whole sign-in.
    expect(handshake.hasOpener).toBe(true);
    expect(handshake.cookie).toContain("comma_e2e_sso=granted");
    // Providers answer `Electron/<version>` with a restricted sign-in flow.
    expect(handshake.userAgent).not.toContain("Electron/");
    expect(handshake.userAgent).toContain("Chrome/");

    // The popup closes itself once the provider is done; the opener sees it.
    await expect
      .poll(() => readSignInProbe().then((probe) => probe?.popupClosed))
      .toBe(true);
  } finally {
    await app.close();
    await apiStub.close();
    await browserStub.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});

async function startBrowserStub() {
  const hangingResponses = new Set<ServerResponse>();
  const requestCounts = new Map<string, number>();
  const server = createServer((request, response) => {
    const path = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
    requestCounts.set(path, (requestCounts.get(path) ?? 0) + 1);
    if (path === "/icon-page") {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(
        '<!doctype html><title>Icon page</title><link rel="icon" href="/icon.png"><p>icon'
      );
      return;
    }
    if (path === "/icon.png") {
      response.writeHead(200, {
        "cache-control": "max-age=3600",
        "content-type": "image/png",
      });
      response.end(Buffer.from(onePixelPngBase64, "base64"));
      return;
    }
    if (path === "/no-icon") {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(
        '<!doctype html><title>No icon</title><link rel="icon" href="data:,"><p>none'
      );
      return;
    }
    if (path === "/fail") {
      request.socket.destroy();
      return;
    }
    if (path === "/hang") {
      hangingResponses.add(response);
      response.on("close", () => hangingResponses.delete(response));
      response.writeHead(200, { "content-type": "text/html" });
      response.write("<!doctype html><title>Pending</title><p>pending");
      return;
    }
    if (path === "/a1") {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(`<!doctype html>
        <title>/a1</title>
        <section
          id="inspection-sensitive-target"
          class="account-card"
          aria-label="Account card"
          data-token="root-token-secret"
          onclick="recordInspectionClick('root-token-secret')"
        >
          <span title="Visible label" data-token="child-token-secret">
            Visible account details
          </span>
          <input type="password" name="password" value="password-secret" />
          <input type="hidden" name="csrf" value="hidden-input-secret" />
          <input type="text" name="account" value="text-input-secret" />
          <textarea name="notes">textarea-secret</textarea>
          <span hidden data-token="hidden-descendant-secret">
            hidden-descendant-secret
          </span>
          <span style="display: none" data-token="styled-hidden-secret">
            styled-hidden-secret
          </span>
        </section>`);
      return;
    }
    if (path === "/signin") {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(`<!doctype html>
        <title>/signin</title>
        <button
          id="continue-with-google"
          style="position:fixed;left:0;top:0;width:320px;height:160px"
        >Continue with Google</button>
        <script>
          document.cookie = "comma_e2e_sso=granted; path=/";
          window.signInProbe = {};
          // A page that opens a window before anyone touches it is popup spam.
          window.signInProbe.unprompted =
            window.open("/oauth", "spam", "width=300,height=300") === null
              ? "blocked"
              : "opened";
          window.addEventListener("message", (event) => {
            window.signInProbe.handshake = String(event.data);
          });
          window.addEventListener("keydown", (event) => {
            if (event.key !== "Escape") return;
            const popup = window.open(
              "/popup-probe",
              "escape-probe",
              "width=300,height=300"
            );
            window.signInProbe.escape = popup === null ? "blocked" : "opened";
            popup?.close();
          });
          document.getElementById("continue-with-google").onclick = () => {
            const popup = window.open("/oauth", "oauth", "width=480,height=620");
            window.signInProbe.clicked = popup === null ? "blocked" : "opened";
            window.signInPopup = popup;
          };
        </script>`);
      return;
    }
    if (path === "/oauth") {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(`<!doctype html>
        <title>/oauth</title>
        <script>
          window.opener.postMessage(
            JSON.stringify({
              cookie: document.cookie,
              hasOpener: Boolean(window.opener),
              userAgent: navigator.userAgent,
            }),
            "*"
          );
          setTimeout(() => window.close(), 50);
        </script>`);
      return;
    }
    if (path === "/victim") {
      // Session isolation must also hold when one navigation takes over 2s.
      globalThis.setTimeout(() => {
        if (response.destroyed) return;
        response.writeHead(200, { "content-type": "text/html" });
        response.end("<!doctype html><title>/victim</title><p>/victim</p>");
      }, 4_000);
      return;
    }
    if (path === "/b1") {
      globalThis.setTimeout(() => {
        if (response.destroyed) return;
        response.writeHead(200, { "content-type": "text/html" });
        response.end("<!doctype html><title>/b1</title><p>/b1</p>");
      }, 800);
      return;
    }
    response.writeHead(200, { "content-type": "text/html" });
    response.end(`<!doctype html><title>${path}</title><p>${path}</p>`);
  });

  await new Promise<void>((resolveListen) => {
    server.listen(0, "127.0.0.1", resolveListen);
  });
  const { port } = server.address() as AddressInfo;
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    pageLoads: (path: string) => requestCounts.get(path) ?? 0,
    close: () =>
      new Promise<void>((resolveClose) => {
        for (const response of hangingResponses) response.destroy();
        server.close(() => resolveClose());
        server.closeAllConnections();
      }),
  };
}
