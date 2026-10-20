import jsQR from "jsqr";
import { expect } from "../../../e2e/helpers/native-expect";
import { electron, electronReportTime, test } from "./electron-test";
import {
  createCipheriv,
  createHash,
  createPublicKey,
  pbkdf2Sync,
  verify,
} from "node:crypto";
import type { ServerResponse } from "node:http";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { startCablePhone, type CablePhone } from "../src/test-support/cable-phone";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  chatSmokeWorkspaceChat,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";
import { closeElectronTestApp } from "./close-electron-test-app";
import { expectElectronContents } from "./electron-operations";
import { startElectronTestServer } from "./electron-test-server";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const onePixelPngBase64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

test(
  "Command-K keeps the browser visible until its stand-in is decoded",
  { tag: "@shared-app" },
  async ({ sharedElectron: { app, mainWindow: appWindow, signIn, useApi } }) => {
    // Reuse the real browser/session fixtures: DOM-only tests cannot observe
    // whether Main hides WebContentsView before the replacement PNG is ready.
    const browserStub = await startBrowserStub();
    const apiStub = await startChatSmokeStub({
      assistantReply: `[Open browser](${browserStub.baseUrl}/a1)`,
    });
    try {
      useApi(apiStub.server);
      await signIn({ email: "browser-overlay@comma.local", userId: apiStub.userId });
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
      await apiStub.close();
      await browserStub.close();
    }
  }
);

// @mac: it checks that the composer takes focus when the window activates.
test(
  "browser sidebar keeps page sessions isolated and remains recoverable during navigation failures",
  { tag: "@mac" },
  async () => {
    const browserStub = await startBrowserStub();
    const apiStub = await startChatSmokeStub({
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
        const originalInspect = bridge.browserSidebar.inspect.bind(
          bridge.browserSidebar
        );
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
      await expect
        .poll(async () => (await sidebar.boundingBox())?.width ?? 0)
        .toBe(440);

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
              ...(state.reasonCode === undefined
                ? {}
                : { reasonCode: state.reasonCode }),
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
      // Observe focus after every activation listener has run. The test can
      // install its observer before the prewarmed React composer has mounted.
      const focusedOnActivation = await app.evaluate(
        async ({ webContents }, { pageUrl, composerId }) => {
          const page = webContents
            .getAllWebContents()
            .find((contents) => contents.getURL() === pageUrl);
          const composerContents = webContents.fromId(composerId);
          if (!page || !composerContents)
            throw new Error("Inspection surfaces are missing");
          await composerContents.executeJavaScript(`
          document.activeElement?.blur();
          window.e2eInspectionActivation = new Promise((resolve) => {
            const dispatch = window.dispatchEvent;
            window.dispatchEvent = function(event) {
              const result = dispatch.call(this, event);
              if (event.type === 'comma-browser-inspection-composer-activate') {
                window.dispatchEvent = dispatch;
                resolve(document.activeElement?.getAttribute('role') === 'textbox');
              }
              return result;
            };
          });
          void 0;
        `);
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
          return composerContents.executeJavaScript("window.e2eInspectionActivation");
        },
        { pageUrl: `${browserStub.baseUrl}/a1`, composerId: prewarmedComposerId }
      );
      expect(focusedOnActivation).toBe(true);
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
        async ({ webContents }, { pageUrl, composerId }) => {
          const page = webContents
            .getAllWebContents()
            .find((contents) => contents.getURL() === pageUrl);
          if (!page) throw new Error(`Browser WebContents not found for ${pageUrl}`);
          // The hidden composer keeps its textbox focused from the last
          // selection; only the new activation, which follows the element's
          // screenshot, should focus it again.
          await webContents
            .fromId(composerId)
            ?.executeJavaScript("document.activeElement?.blur()");
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
        { pageUrl: `${browserStub.baseUrl}/a1`, composerId: prewarmedComposerId }
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
          ?.getAttribute('data-compact-multiline')
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
      // The chat shows the element's screenshot; the agent reads that file
      // beside the DOM context in the message text.
      await expect(
        inspectedUserMessage.getByRole("img", { name: "inspected-element.png" })
      ).toBeVisible();
      const screenshotUpload = apiStub.uploads.find(
        (upload) => upload.filename === "inspected-element.png"
      );
      expect(screenshotUpload?.bytes.subarray(1, 4).toString()).toBe("PNG");
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
      await appWindow
        .getByRole("button", { exact: true, name: "Recent tasks" })
        .click();
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
      const sidebarToggle = appWindow
        .getByTestId("comma-window-bar")
        .getByRole("button", { name: "New tab" });
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
                .elementFromPoint(
                  rect.left + rect.width / 2,
                  rect.top + rect.height / 2
                )
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
          hitTarget: "New tab",
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
        const originalGetBoundingClientRect =
          element.getBoundingClientRect.bind(element);
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
      const secondPageId = secondPageSessionId.slice(
        `${productHostSessionId}::`.length
      );
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

      // Main must finish shutdown with a hanging page. Chromium's later
      // flush of the disposable profile is not part of that contract.
      await closeElectronTestApp(app);
      appClosed = true;
    } finally {
      if (!appClosed) await closeElectronTestApp(app);
      await apiStub.close();
      await browserStub.close();
      await rm(userDataDir, { force: true, recursive: true });
    }
  }
);

test(
  "a sign-in popup opens on a click, stays in the page's session, and never opens unprompted",
  { tag: "@shared-app" },
  async ({ sharedElectron: { app, mainWindow, signIn, useApi } }) => {
    const browserStub = await startBrowserStub();
    const apiStub = await startChatSmokeStub();

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
      useApi(apiStub.server);
      await signIn({ email: "browser-popup@comma.local", userId: apiStub.userId });
      const appWindow = mainWindow;
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
      await apiStub.close();
      await browserStub.close();
    }
  }
);

test(
  "a passkey prompt in a browser tab ends at once so the site can offer other sign-in methods",
  { tag: "@shared-app" },
  async ({ sharedElectron: { app, mainWindow, signIn, useApi } }) => {
    const browserStub = await startBrowserStub();
    const apiStub = await startChatSmokeStub();
    // A WebAuthn relying party must be a domain, not an IP address. The iframe
    // keeps 127.0.0.1, so it is a cross-site frame.
    const passkeyUrl = `${browserStub.baseUrl.replace("127.0.0.1", "localhost")}/passkey`;
    const readPasskeyProbe = () =>
      app.evaluate(async ({ webContents }, url) => {
        const page = webContents
          .getAllWebContents()
          .find((contents) => contents.getURL() === url);
        return page
          ? ((await page.executeJavaScript("window.passkeyProbe")) as {
              autofill?: boolean;
              frameAutofill?: boolean;
              phone?: boolean;
              signIn?: string;
              signInMs?: number;
            })
          : undefined;
      }, passkeyUrl);

    try {
      useApi(apiStub.server);
      await signIn({ email: "browser-passkey@comma.local", userId: apiStub.userId });
      const appWindow = mainWindow;
      await appWindow.waitForLoadState("domcontentloaded");
      await appWindow.evaluate(async (url) => {
        const bridge = window.commaNative;
        if (!bridge) throw new Error("Native bridge is unavailable");
        await bridge.browserSidebar.open({
          bounds: { height: 500, width: 400, x: 800, y: 40 },
          sessionId: "passkey-host",
          url,
        });
      }, passkeyUrl);

      await expect
        .poll(() => readPasskeyProbe().then((probe) => probe?.signIn))
        .toBeDefined();
      const probe = await readPasskeyProbe();
      // Electron reported passkey autofill and phone sign-in that no tab can
      // show, so sites chose a passkey flow that could not finish.
      expect(probe?.autofill).toBe(false);
      expect(probe?.phone).toBe(false);
      // The autofill request that the page starts on load used to hold the
      // only request slot, and the account's passkey prompt then failed with
      // "A request is already pending". Without autofill, it waited forever.
      expect(probe?.signIn).toBe("NotAllowedError");
      expect(probe?.signInMs).toBeLessThan(5_000);
      await expect
        .poll(() => readPasskeyProbe().then((latest) => latest?.frameAutofill))
        .toBe(false);
    } finally {
      await apiStub.close();
      await browserStub.close();
    }
  }
);

/** Where the browsers on this Mac keep their profiles, as the shared app's next start reads it. */
const importTest = test.extend<{ applicationSupport: string }>({
  // Playwright requires fixture dependencies to use object destructuring.
  // eslint-disable-next-line no-empty-pattern
  applicationSupport: async ({}, use) => {
    const directory = await mkdtemp(join(tmpdir(), "comma-browser-import-data-"));
    try {
      await use(directory);
    } finally {
      await rm(directory, { force: true, recursive: true });
    }
  },
  sharedElectronEnv: async ({ applicationSupport }, use) => {
    await use({
      COMMA_ELECTRON_E2E_BROWSER_IMPORT_DIRECTORY: applicationSupport,
      COMMA_ELECTRON_E2E_BROWSER_IMPORT_KEYCHAIN_PASSWORD:
        browserImportKeychainPassword,
    });
  },
});
const browserImportKeychainPassword = "e2e-chrome-safe-storage";

importTest(
  "the browser sidebar imports the sign-ins of the browsers on this Mac in one step",
  { tag: "@shared-app" },
  async ({ applicationSupport, sharedElectron }) => {
    const browserStub = await startBrowserStub();
    const cookieEchoUrl = `${browserStub.baseUrl}/cookie-echo`;
    const apiStub = await startChatSmokeStub({
      assistantReply: `[Open browser](${cookieEchoUrl})`,
    });
    const keychainPassword = browserImportKeychainPassword;
    // Profiles as Chrome and Arc write them. Both signed in to the stub site;
    // Chrome used it last. Arc also signed in to another site.
    await writeBrowserProfileFixture(
      applicationSupport,
      keychainPassword,
      "Google/Chrome",
      [{ host: "127.0.0.1", name: "imported_session", value: "signed-in-in-chrome" }]
    );
    await writeBrowserProfileFixture(
      applicationSupport,
      keychainPassword,
      "Arc/User Data",
      [
        {
          host: "127.0.0.1",
          lastAccessMs: Date.now() - 3_600_000,
          name: "arc_session",
          value: "older-sign-in-in-arc",
        },
        { host: "localhost", name: "arc_only", value: "signed-in-in-arc" },
      ]
    );
    const { app } = sharedElectron;
    // For the report of a wait that never ends: when each step of the test ended, on the clock of the stub's requests
    // and of Main's navigation events.
    const steps: string[] = [];
    const step = (name: string) => steps.push(`${electronReportTime()} ${name}`);
    // The echo page is a browser view, reached through Main. It changes by a reload the app starts: the wait reads
    // it again at each load, and a wait that never ends reports every WebContents and what the page echoed.
    const cookieEcho = (expected: string) =>
      expectElectronContents(
        app,
        cookieEchoUrl,
        "document.body.textContent",
        expected,
        async () => ({
          steps,
          // A request after the import says the page was loaded again, and its cookies say whether the import was
          // in the jar by then. The page shows a response only once its navigation commits: see `navigation`.
          echoPageRequests: browserStub.requests("/cookie-echo"),
          // What the sidebar's partition holds for the stub's host now.
          sidebarCookies: await app.evaluate(async ({ session }) =>
            (
              await session
                .fromPartition("persist:comma-browser-sidebar")
                .cookies.get({ domain: "127.0.0.1" })
            ).map(({ name, value }) => `${name}=${value}`)
          ),
        })
      );

    try {
      sharedElectron.useApi(apiStub.server);
      await sharedElectron.signIn({
        email: "browser-import@comma.local",
        userId: apiStub.userId,
      });
      const appWindow = sharedElectron.mainWindow;
      const content = appWindow.getByRole("region", { name: "Content" });
      const composer = content.locator(".comma-chat-composer");
      await composer.getByRole("textbox", { name: "AI prompt" }).fill("Open browser");
      await composer.getByRole("button", { name: "Send" }).click();
      await content.getByRole("link", { name: "Open browser" }).click();
      await cookieEcho("");

      // This Mac has a browser to import from, so the sidebar offers it once.
      const offer = content.getByRole("note");
      await expect(offer).toContainText("Import your browser sign-ins");
      await offer.getByRole("button", { name: "Import…" }).click();
      step("clicked the offer's Import… (the dialog opens over the page)");
      const dialog = appWindow.getByRole("dialog", { name: "Import sign-ins" });
      // Every profile starts selected; one click imports them all.
      await expect(
        dialog.getByRole("checkbox", { name: /Google Chrome/ })
      ).toBeChecked();
      await expect(dialog.getByRole("checkbox", { name: /Arc/ })).toBeChecked();
      await dialog.getByRole("button", { name: "Import", exact: true }).click();
      step("clicked the dialog's Import");
      await expect(dialog.getByText("Imported sign-ins for 2 sites.")).toBeVisible();
      step("saw the success message");
      await dialog.getByRole("button", { name: "Done" }).click();
      step("clicked Done (the dialog closes)");

      // The page reloads signed in as in Chrome, which used the site last, with
      // none of Arc's cookies for it. Arc's other site is signed in too.
      await cookieEcho("imported_session=signed-in-in-chrome");
      await expect(offer).toHaveCount(0);
      expect(
        await app.evaluate(async ({ session }) =>
          (
            await session
              .fromPartition("persist:comma-browser-sidebar")
              .cookies.get({ domain: "localhost" })
          ).map(({ name, value }) => `${name}=${value}`)
        )
      ).toEqual(["arc_only=signed-in-in-arc"]);
    } finally {
      await apiStub.close();
      await browserStub.close();
    }
  }
);

// Microseconds since 1601-01-01 UTC, as Chromium stores times.
function chromiumTime(unixMs: number) {
  return (BigInt(unixMs) + 11_644_473_600_000n) * 1000n;
}

async function writeBrowserProfileFixture(
  applicationSupport: string,
  keychainPassword: string,
  browserDirectory: string,
  cookies: Array<{ host: string; lastAccessMs?: number; name: string; value: string }>
) {
  const browser = join(applicationSupport, browserDirectory);
  await mkdir(join(browser, "Default"), { recursive: true });
  await writeFile(
    join(browser, "Local State"),
    JSON.stringify({
      profile: {
        info_cache: { Default: { name: "Person 1", user_name: "ada@example.com" } },
      },
    })
  );
  const key = pbkdf2Sync(keychainPassword, "saltysalt", 1003, 16, "sha1");
  const database = new DatabaseSync(join(browser, "Default/Cookies"));
  database.exec(`
    CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
    INSERT INTO meta VALUES ('version', '24');
    CREATE TABLE cookies(host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
      name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL,
      path TEXT NOT NULL, expires_utc INTEGER NOT NULL, last_access_utc INTEGER NOT NULL,
      is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
      has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
      samesite INTEGER NOT NULL);
  `);
  const insert = database.prepare(
    "INSERT INTO cookies VALUES (?, '', ?, '', ?, '/', ?, ?, 0, 1, 1, 1, 1)"
  );
  for (const cookie of cookies) {
    const cipher = createCipheriv("aes-128-cbc", key, Buffer.alloc(16, 0x20));
    const encrypted = Buffer.concat([
      Buffer.from("v10"),
      cipher.update(
        Buffer.concat([
          createHash("sha256").update(cookie.host).digest(),
          Buffer.from(cookie.value),
        ])
      ),
      cipher.final(),
    ]);
    insert.run(
      cookie.host,
      cookie.name,
      encrypted,
      chromiumTime(Date.now() + 365 * 24 * 3600 * 1000),
      chromiumTime(cookie.lastAccessMs ?? Date.now())
    );
  }
  database.close();
}

/** `PublicKeyCredential.toJSON()` as the stub page records it. */
interface PasskeyJson {
  id: string;
  response: {
    authenticatorData: string;
    clientDataJSON: string;
    publicKey?: string;
    signature?: string;
  };
}

const fromBase64Url = (value: string) => Buffer.from(value, "base64url");

/** The phone listens before the shared app starts again: Main reaches it at the origin the reset gives. */
const phoneTest = test.extend<{ phone: CablePhone }>({
  // Playwright requires fixture dependencies to use object destructuring.
  // eslint-disable-next-line no-empty-pattern
  phone: async ({}, use) => {
    const phone = await startCablePhone();
    try {
      await use(phone);
    } finally {
      await phone.close();
    }
  },
  sharedElectronEnv: async ({ phone }, use) => {
    await use({ COMMA_ELECTRON_E2E_CABLE_PHONE_ORIGIN: phone.tunnelOrigin });
  },
});

phoneTest(
  "a browser tab creates a passkey on a phone and signs in with it through the QR code",
  { tag: "@shared-app" },
  async ({ phone, sharedElectron }) => {
    const browserStub = await startBrowserStub();
    // A WebAuthn relying party must be a domain, not an IP address.
    const pageUrl = `${browserStub.baseUrl.replace("127.0.0.1", "localhost")}/passkey-phone`;
    const pageOrigin = new URL(pageUrl).origin;
    const apiStub = await startChatSmokeStub({
      assistantReply: `[Open browser](${pageUrl})`,
    });
    const { app } = sharedElectron;
    const inPage = (script: string) =>
      app.evaluate(
        async ({ webContents }, { source, url }) => {
          const page = webContents
            .getAllWebContents()
            .find((contents) => contents.getURL() === url && !contents.isLoading());
          return page ? page.executeJavaScript(source, true) : undefined;
        },
        { source: script, url: pageUrl }
      );
    const probe = () =>
      inPage("window.phoneProbe") as Promise<
        | {
            capabilities?: { hybridTransport?: boolean };
            created?: { instance: boolean; json: PasskeyJson };
            signedIn?: { instance: boolean; json: PasskeyJson };
            error?: string;
          }
        | undefined
      >;

    try {
      sharedElectron.useApi(apiStub.server);
      await sharedElectron.signIn({
        email: "browser-phone-passkey@comma.local",
        userId: apiStub.userId,
      });
      const appWindow = sharedElectron.mainWindow;
      const content = appWindow.getByRole("region", { name: "Content" });
      const composer = content.locator(".comma-chat-composer");
      await composer.getByRole("textbox", { name: "AI prompt" }).fill("Open browser");
      await composer.getByRole("button", { name: "Send" }).click();
      await content.getByRole("link", { name: "Open browser" }).click();
      // Main serves the page's passkey requests once the document committed.
      await expect
        .poll(async () => {
          await inPage("window.readCapabilities()");
          return (await probe())?.capabilities?.hybridTransport;
        })
        .toBe(true);

      // The phone's camera reads the QR code that the dialog shows.
      const scanQrCode = async (dialogName: string) => {
        const dialog = appWindow.getByRole("dialog", { name: dialogName });
        const canvas = dialog
          .getByRole("figure", { name: "QR code for your phone" })
          .locator("canvas");
        await expect(canvas).toBeVisible();
        const pixels = await canvas.evaluate((element: HTMLCanvasElement) => ({
          width: element.width,
          height: element.height,
          data: Array.from(
            element.getContext("2d")!.getImageData(0, 0, element.width, element.height)
              .data
          ),
        }));
        const qr = jsQR(
          new Uint8ClampedArray(pixels.data),
          pixels.width,
          pixels.height
        )?.data;
        expect(qr).toMatch(/^FIDO:\/\d+$/u);
        phone.scan(qr!);
        await expect(dialog).toHaveCount(0);
      };

      await inPage("window.createPasskey(); true");
      await scanQrCode("Save a passkey on your phone");
      await expect.poll(async () => (await probe())?.created).toBeDefined();
      const created = (await probe())!.created!;
      expect(created.instance).toBe(true);
      expect(phone.passkeys).toHaveLength(1);

      await inPage("window.signIn(); true");
      await scanQrCode("Sign in with a passkey from your phone");
      await expect.poll(async () => (await probe())?.signedIn).toBeDefined();
      const signedIn = (await probe())!.signedIn!;
      expect(signedIn.instance).toBe(true);

      // What the site's server checks: the origin and challenge it issued, and
      // the signature under the public key it stored when the passkey was made.
      const clientData = JSON.parse(
        fromBase64Url(signedIn.json.response.clientDataJSON).toString()
      );
      expect(clientData).toEqual({
        type: "webauthn.get",
        challenge: Buffer.from("sign-in-challenge-0123456789").toString("base64url"),
        origin: pageOrigin,
        crossOrigin: false,
      });
      expect(signedIn.json.id).toBe(created.json.id);
      expect(
        verify(
          "sha256",
          Buffer.concat([
            fromBase64Url(signedIn.json.response.authenticatorData),
            createHash("sha256")
              .update(fromBase64Url(signedIn.json.response.clientDataJSON))
              .digest(),
          ]),
          createPublicKey({
            key: fromBase64Url(created.json.response.publicKey!),
            format: "der",
            type: "spki",
          }),
          fromBase64Url(signedIn.json.response.signature!)
        )
      ).toBe(true);
      expect((await probe())?.error).toBeUndefined();

      // Closing the dialog ends the request the way a browser does.
      await inPage("window.signIn(); true");
      const dialog = appWindow.getByRole("dialog", {
        name: "Sign in with a passkey from your phone",
      });
      await dialog.getByRole("button", { name: "Cancel" }).click();
      await expect(dialog).toHaveCount(0);
      await expect
        .poll(async () => (await probe())?.error)
        .toMatch(/^NotAllowedError: /u);
    } finally {
      await apiStub.close();
      await browserStub.close();
    }
  }
);

async function startBrowserStub() {
  const hangingResponses = new Set<ServerResponse>();
  // Each request, for a failed test's report: when it arrived and the cookies it carried.
  const requests: Array<{ path: string; at: string; cookie: string | null }> = [];
  const server = await startElectronTestServer((request, response) => {
    const path = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
    requests.push({
      path,
      at: electronReportTime(),
      cookie: request.headers.cookie ?? null,
    });
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
    if (path === "/cookie-echo") {
      response.writeHead(200, { "content-type": "text/plain" });
      response.end(request.headers.cookie ?? "");
      return;
    }
    if (path === "/passkey") {
      const { port } = server;
      response.writeHead(200, { "content-type": "text/html" });
      response.end(`<!doctype html>
        <title>/passkey</title>
        <input autocomplete="username webauthn" />
        <iframe
          allow="publickey-credentials-get"
          src="http://127.0.0.1:${port}/passkey-frame"
        ></iframe>
        <script>
          window.passkeyProbe = {};
          window.addEventListener("message", (event) => {
            window.passkeyProbe.frameAutofill = event.data.autofill;
          });
          const challenge = new Uint8Array(32);
          (async () => {
            window.passkeyProbe.autofill =
              await PublicKeyCredential.isConditionalMediationAvailable();
            window.passkeyProbe.phone = (
              await PublicKeyCredential.getClientCapabilities()
            ).hybridTransport;
            // Passkey autofill on load, then the account's passkey prompt.
            navigator.credentials
              .get({ mediation: "conditional", publicKey: { challenge } })
              .catch(() => undefined);
            const started = performance.now();
            try {
              await navigator.credentials.get({
                publicKey: {
                  allowCredentials: [
                    {
                      id: challenge,
                      transports: ["internal", "hybrid"],
                      type: "public-key",
                    },
                  ],
                  challenge,
                  timeout: 60000,
                },
              });
              window.passkeyProbe.signIn = "resolved";
            } catch (error) {
              window.passkeyProbe.signIn = error.name;
            }
            window.passkeyProbe.signInMs = performance.now() - started;
          })();
        </script>`);
      return;
    }
    if (path === "/passkey-phone") {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(`<!doctype html>
        <title>/passkey-phone</title>
        <script>
          window.phoneProbe = {};
          const bytes = (text) => new TextEncoder().encode(text);
          const record = (key) => (credential) => {
            window.phoneProbe[key] = {
              instance: credential instanceof PublicKeyCredential,
              json: credential.toJSON(),
            };
          };
          const fail = (error) => {
            window.phoneProbe.error = error.name + ": " + error.message;
          };
          window.readCapabilities = async () => {
            window.phoneProbe.capabilities =
              await PublicKeyCredential.getClientCapabilities();
          };
          window.createPasskey = () =>
            navigator.credentials
              .create({
                publicKey: {
                  challenge: bytes("create-challenge-0123456789"),
                  rp: { name: "Passkey stub" },
                  user: {
                    id: bytes("user-1"),
                    name: "ada@example.com",
                    displayName: "Ada",
                  },
                  pubKeyCredParams: [{ alg: -7, type: "public-key" }],
                  authenticatorSelection: { residentKey: "required" },
                },
              })
              .then(record("created"), fail);
          window.signIn = () =>
            navigator.credentials
              .get({ publicKey: { challenge: bytes("sign-in-challenge-0123456789") } })
              .then(record("signedIn"), fail);
        </script>`);
      return;
    }
    if (path === "/passkey-frame") {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(`<!doctype html>
        <script>
          PublicKeyCredential.isConditionalMediationAvailable().then((autofill) =>
            parent.postMessage({ autofill }, "*")
          );
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

  return {
    baseUrl: server.origin,
    pageLoads: (path: string) =>
      requests.filter((request) => request.path === path).length,
    requests: (path: string) =>
      requests
        .filter((request) => request.path === path)
        .map(({ at, cookie }) => ({ at, cookie })),
    close: () => {
      for (const response of hangingResponses) response.destroy();
      return server.close();
    },
  };
}
