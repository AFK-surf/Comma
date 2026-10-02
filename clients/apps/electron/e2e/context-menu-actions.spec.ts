import {
  _electron as electron,
  expect,
  test,
  type ElectronApplication,
  type Locator,
} from "@playwright/test";
import { execSync } from "node:child_process";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import {
  chatSmokeWorkspace,
  chatSmokeWorkspaceChat,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const sideChatBackdropFixture = resolve(
  electronAppDir,
  "test/fixtures/side-chat-backdrop-fault.cjs"
);
const externalDocsUrl = "https://example.com/context-menu";
const assistantReplyMarkdown = [
  `[External docs](${externalDocsUrl})`,
  "",
  "Selectable assistant text",
  "",
  "```ts",
  "const copiedThroughMain = true",
  "```",
].join("\n");

function electronEnv(baseUrl: string, { openSideChat = false } = {}) {
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
  return {
    ...env,
    COMMA_API_BASE_URL: baseUrl,
    COMMA_ELECTRON_STARTUP_SESSION_EMAIL: "context-menu@comma.local",
    COMMA_ELECTRON_STARTUP_SESSION_TOKEN: "context-menu-session-token",
    ...(openSideChat
      ? {
          COMMA_ELECTRON_E2E_OPEN_SIDE_CHAT: "1",
          COMMA_SIDE_CHAT_BACKDROP_FAULT: "none",
          COMMA_SIDE_CHAT_BACKDROP_PATH: sideChatBackdropFixture,
        }
      : {}),
    NODE_ENV: "test",
  };
}

test("Electron text and link context menus use the Main-owned clipboard", async () => {
  const apiStub = await startChatSmokeStub({
    assistantReply: assistantReplyMarkdown,
    additionalInboxConversations: [chatSmokeWorkspaceChat],
  });
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-context-menu-e2e-"));
  recordElectronOnboardingCompleted(userDataDir, [apiStub.userId]);
  const app = await electron.launch({
    args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronEnv(apiStub.baseUrl),
  });

  try {
    const appWindow = await findElectronWindowByNativeRole(app, "main-window");
    await appWindow.waitForLoadState("domcontentloaded");
    await appWindow.getByRole("link", { name: "Inbox", exact: true }).click();
    const content = appWindow.getByRole("region", { name: "Content" });
    // The host list supplies the notification used to open this Chat.
    const workspaceChatItem = content.getByTestId("inbox-item");
    await expect(workspaceChatItem).toHaveCount(1);
    await workspaceChatItem.click();
    await expect(appWindow).toHaveURL(
      new RegExp(
        `#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeWorkspaceChat.id}$`
      )
    );
    const conversation = content.getByRole("region", { name: "Conversation" });
    const editor = conversation.getByRole("textbox", { name: "AI prompt" });

    await editor.fill("Preserve this draft");
    await app.evaluate(({ clipboard, nativeImage }) => {
      const image = nativeImage.createFromBitmap(Buffer.from([0, 0, 255, 255]), {
        width: 1,
        height: 1,
      });
      clipboard.writeImage(image);
    });
    await editor.click({ button: "right" });
    await appWindow.getByRole("menuitem", { name: "Paste", exact: true }).click();
    await expect(
      conversation.getByRole("button", {
        name: "Remove clipboard-image.png",
        exact: true,
      })
    ).toBeVisible();
    await expect(editor).toHaveText("Preserve this draft");
    await conversation
      .getByRole("button", { name: "Remove clipboard-image.png", exact: true })
      .click();

    await editor.fill("Copy this");
    await writeOsClipboard(app, "before-copy");
    await openRichTextMenu(editor, 0, "Copy this".length);
    await conversation.getByRole("log").click({ position: { x: 32, y: 32 } });
    await expect(appWindow.getByRole("menu")).toHaveCount(0);
    await openRichTextMenuFromCurrentSelection(editor);
    await appWindow.getByRole("menuitem", { name: "Copy", exact: true }).click();
    await expect.poll(() => readOsClipboard(app)).toBe("Copy this");

    await editor.fill("Cut this");
    await openRichTextMenu(editor, 0, "Cut this".length);
    await appWindow.getByRole("menuitem", { name: "Cut", exact: true }).click();
    await expect.poll(() => readOsClipboard(app)).toBe("Cut this");
    await expect(editor).toHaveText("");

    await editor.fill("Paste ");
    await writeOsClipboard(app, "through Main");
    await openRichTextMenu(editor, "Paste ".length, "Paste ".length);
    await appWindow.getByRole("menuitem", { name: "Paste", exact: true }).click();
    await expect(editor).toHaveText("Paste through Main");

    await openRichTextMenu(editor, 0, "Paste".length);
    await appWindow.getByRole("menuitem", { name: "Select All" }).click();
    await appWindow.evaluate(
      () =>
        new Promise<void>((finish) => {
          requestAnimationFrame(() => requestAnimationFrame(() => finish()));
        })
    );
    await writeOsClipboard(app, "before-select-all-copy");
    await openRichTextMenuFromCurrentSelection(editor);
    await appWindow.getByRole("menuitem", { name: "Copy", exact: true }).click();
    await expect.poll(() => readOsClipboard(app)).toBe("Paste through Main");

    await conversation
      .getByRole("button", { name: "Send message", exact: true })
      .click();
    const externalLink = conversation.getByRole("link", { name: "External docs" });
    await expect(externalLink).toBeVisible();
    await writeOsClipboard(app, "before-user-copy");
    await conversation
      .getByTestId("chat-user-bubble-content")
      .click({ button: "right" });
    await appWindow.getByRole("menuitem", { name: "Copy", exact: true }).click();
    await expect.poll(() => readOsClipboard(app)).toBe("Paste through Main");

    await writeOsClipboard(app, "before-copy-link");
    await externalLink.click({ button: "right" });
    await appWindow.getByRole("menuitem", { name: "Copy Link" }).click();
    await expect.poll(() => readOsClipboard(app)).toBe(externalDocsUrl);

    await writeOsClipboard(app, "before-copy-message");
    await externalLink.click({ button: "right" });
    await appWindow.getByRole("menuitem", { name: "Copy message" }).click();
    await expect.poll(() => readOsClipboard(app)).toBe(assistantReplyMarkdown);

    await writeOsClipboard(app, "before-assistant-copy");
    await conversation
      .getByText("const copiedThroughMain = true")
      .click({ button: "right" });
    await conversation.getByRole("log").click({ position: { x: 32, y: 32 } });
    await expect(appWindow.getByRole("menu")).toHaveCount(0);
    await conversation
      .getByText("const copiedThroughMain = true")
      .click({ button: "right" });
    await appWindow.getByRole("menuitem", { name: "Copy", exact: true }).click();
    await expect.poll(() => readOsClipboard(app)).toBe(assistantReplyMarkdown);

    await writeOsClipboard(app, "before-assistant-selection-copy");
    await openTextSelectionMenu(
      conversation.getByText("Selectable assistant text"),
      0,
      "Selectable".length
    );
    await expect(
      appWindow.getByRole("menuitem", { name: "Copy", exact: true })
    ).toBeVisible();
    await expect
      .poll(() =>
        appWindow.evaluate(() => CSS.highlights.has("comma-context-selection"))
      )
      .toBe(true);
    await appWindow.getByRole("menuitem", { name: "Copy", exact: true }).click();
    await expect.poll(() => readOsClipboard(app)).toBe("Selectable");

    await writeOsClipboard(app, "before-code-copy");
    await conversation.getByRole("button", { name: "Copy code" }).click();
    await expect
      .poll(() => readOsClipboard(app))
      .toBe("const copiedThroughMain = true");
  } finally {
    await app.close();
    await apiStub.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});

test("Side Chat roles can copy and explicitly open assistant links", async () => {
  test.skip(process.platform !== "darwin", "Side Chat is a macOS-only surface.");
  const apiStub = await startChatSmokeStub({
    assistantReply: `[External docs](${externalDocsUrl})`,
  });
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-side-chat-links-e2e-"));
  recordElectronOnboardingCompleted(userDataDir, [apiStub.userId]);
  const app = await electron.launch({
    args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronEnv(apiStub.baseUrl, { openSideChat: true }),
  });

  try {
    await installExternalUrlProbe(app);
    const sideChatWindow = await findElectronWindowByNativeRole(
      app,
      "side-chat-window"
    );
    await sideChatWindow.waitForLoadState("domcontentloaded");
    const editor = sideChatWindow.getByRole("textbox", { name: "AI prompt" });
    await expect(editor).toBeVisible();
    await editor.fill("Show the external docs");
    await sideChatWindow
      .getByRole("button", { name: "Send message", exact: true })
      .click();

    const externalLink = sideChatWindow.getByRole("link", {
      name: "External docs",
    });
    await expect(externalLink).toBeVisible();
    await writeOsClipboard(app, "before-side-chat-copy");
    await externalLink.click({ button: "right" });
    const copyLink = sideChatWindow.getByRole("menuitem", { name: "Copy Link" });
    await expect(copyLink).toBeVisible();
    await copyLink.click();
    await expect.poll(() => readOsClipboard(app)).toBe(externalDocsUrl);

    await externalLink.click({ button: "right" });
    await sideChatWindow
      .getByRole("menuitem", { name: "Open in External Browser" })
      .click();
    await expect.poll(() => openedExternalUrls(app)).toEqual([externalDocsUrl]);

    const sourceFrame = await sideChatWindow.evaluate(() => {
      const root = document.querySelector<HTMLElement>(".comma-side-chat-host");
      if (!root) throw new Error("Side Chat root is unavailable.");
      const bounds = root.getBoundingClientRect();
      return {
        height: 30,
        width: 30,
        x: window.screenX + bounds.left + bounds.width / 2 - 15,
        y: window.screenY + bounds.top + bounds.height - 45,
      };
    });
    await sideChatWindow.evaluate(
      async ({ frame, target }) => {
        const openTestWindow = window.commaNative?.sideChat.openTestWindow;
        if (!openTestWindow) throw new Error("openTestWindow is unavailable.");
        await openTestWindow({ sourceFrame: frame, target });
      },
      {
        frame: sourceFrame,
        target: {
          conversationId: chatSmokeWorkspaceChat.id,
          groupId: chatSmokeWorkspace.group_id,
          workspaceId: chatSmokeWorkspace.id,
        },
      }
    );

    const testWindow = await findElectronWindowByNativeRole(
      app,
      "side-chat-test-window"
    );
    const testWindowLink = testWindow.getByRole("link", { name: "External docs" });
    await expect(testWindowLink).toBeVisible();
    await testWindowLink.click({ button: "right" });
    await testWindow
      .getByRole("menuitem", { name: "Open in External Browser" })
      .click();
    await expect
      .poll(() => openedExternalUrls(app))
      .toEqual([externalDocsUrl, externalDocsUrl]);
  } finally {
    await app.close();
    await apiStub.close();
    await rm(userDataDir, { force: true, recursive: true });
  }
});

async function openRichTextMenu(editor: Locator, start: number, end: number) {
  await editor.evaluate(
    (element, selection) => {
      const textNode = Array.from(element.childNodes).find(
        (node) => node.nodeType === Node.TEXT_NODE
      );
      if (!textNode) throw new Error("The rich editor has no text node.");
      const range = document.createRange();
      range.setStart(textNode, selection.start);
      range.setEnd(textNode, selection.end);
      const windowSelection = window.getSelection();
      windowSelection?.removeAllRanges();
      windowSelection?.addRange(range);
      element.dispatchEvent(
        new MouseEvent("contextmenu", {
          bubbles: true,
          cancelable: true,
          clientX: element.getBoundingClientRect().left + 12,
          clientY: element.getBoundingClientRect().top + 12,
        })
      );
    },
    { end, start }
  );
}

async function openRichTextMenuFromCurrentSelection(editor: Locator) {
  await editor.evaluate((element) => {
    element.dispatchEvent(
      new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: element.getBoundingClientRect().left + 12,
        clientY: element.getBoundingClientRect().top + 12,
      })
    );
  });
}

async function openTextSelectionMenu(target: Locator, start: number, end: number) {
  await target.evaluate(
    (element, selection) => {
      const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
      const textNodes: Text[] = [];
      let textNode = walker.nextNode();
      while (textNode) {
        textNodes.push(textNode as Text);
        textNode = walker.nextNode();
      }

      const pointAt = (offset: number) => {
        let remaining = offset;
        for (const node of textNodes) {
          if (remaining <= node.length) return { node, offset: remaining };
          remaining -= node.length;
        }
        throw new Error(`Selection offset ${offset} exceeds the target text.`);
      };
      const startPoint = pointAt(selection.start);
      const endPoint = pointAt(selection.end);
      const range = document.createRange();
      range.setStart(startPoint.node, startPoint.offset);
      range.setEnd(endPoint.node, endPoint.offset);
      const windowSelection = window.getSelection();
      windowSelection?.removeAllRanges();
      windowSelection?.addRange(range);
      element.dispatchEvent(
        new MouseEvent("contextmenu", {
          bubbles: true,
          cancelable: true,
          clientX: element.getBoundingClientRect().left + 12,
          clientY: element.getBoundingClientRect().top + 12,
        })
      );
    },
    { end, start }
  );
}

function writeOsClipboard(app: ElectronApplication, text: string) {
  return app.evaluate(({ clipboard }, value) => clipboard.writeText(value), text);
}

function readOsClipboard(app: ElectronApplication) {
  return app.evaluate(({ clipboard }) => clipboard.readText());
}

function installExternalUrlProbe(app: ElectronApplication) {
  return app.evaluate(({ shell }) => {
    const scope = globalThis as typeof globalThis & {
      commaContextMenuOpenedUrls?: string[];
    };
    scope.commaContextMenuOpenedUrls = [];
    shell.openExternal = async (url) => {
      scope.commaContextMenuOpenedUrls?.push(url);
    };
  });
}

function openedExternalUrls(app: ElectronApplication) {
  return app.evaluate(
    () =>
      (
        globalThis as typeof globalThis & {
          commaContextMenuOpenedUrls?: string[];
        }
      ).commaContextMenuOpenedUrls ?? []
  );
}

test("application menu navigates Comma and reflects shortcut and sidebar state", async () => {
  const apiStub = await startChatSmokeStub();
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-application-menu-e2e-"));
  recordElectronOnboardingCompleted(userDataDir, [apiStub.userId]);
  const app = await electron.launch({
    args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataDir}`],
    cwd: electronAppDir,
    env: electronEnv(apiStub.baseUrl),
  });
  try {
    const page = await findElectronWindowByNativeRole(app, "main-window");
    await page.waitForLoadState("domcontentloaded");
    await page.bringToFront();
    const nativeWindow = await app.browserWindow(page);
    await nativeWindow.evaluate((window) => {
      window.show();
      window.focus();
    });
    await app.evaluate(({ app: electronApp }) => electronApp.focus({ steal: true }));
    await expect
      .poll(() => nativeWindow.evaluate((window) => window.isFocused()))
      .toBe(true)
      .catch(async (error: unknown) => {
        await describeFocus(app, userDataDir);
        throw error;
      });
    const item = (id: string) =>
      app.evaluate(({ Menu }, commandId) => {
        const entry = Menu.getApplicationMenu()?.getMenuItemById(commandId);
        return entry
          ? {
              enabled: entry.enabled,
              checked: entry.checked,
              accelerator: entry.accelerator,
              label: entry.label,
              icon: Boolean(entry.icon),
            }
          : null;
      }, id);
    const click = (id: string) =>
      app.evaluate(({ Menu, BrowserWindow }, commandId) => {
        const entry = Menu.getApplicationMenu()?.getMenuItemById(commandId);
        if (!entry?.enabled) throw new Error(`Menu action unavailable: ${commandId}`);
        const focusedWindow = BrowserWindow.getFocusedWindow()!;
        // Electron's runtime click wrapper passes focused WebContents to native roles.
        entry.click(
          undefined!,
          focusedWindow,
          focusedWindow.webContents as unknown as KeyboardEvent
        );
      }, id);
    const applicationIdentity = await app.evaluate(({ app: electronApp, Menu }) => ({
      name: electronApp.getName(),
      labels: Menu.getApplicationMenu()!
        .items[0]!.submenu!.items.filter((entry) =>
          ["about", "hide", "quit"].includes(entry.role ?? "")
        )
        .map((entry) => entry.label),
      userData: electronApp.getPath("userData"),
    }));
    expect(applicationIdentity.name).toMatch(/^Comma(?: Staging| Dev)?$/);
    expect(await realpath(applicationIdentity.userData)).toBe(
      await realpath(userDataDir)
    );
    expect(applicationIdentity.labels).toHaveLength(3);
    for (const label of applicationIdentity.labels) {
      expect(label).toContain(applicationIdentity.name);
    }
    const devToolsOpen = () =>
      nativeWindow.evaluate((window) => window.webContents.isDevToolsOpened());
    expect(await devToolsOpen()).toBe(false);
    await click("toggle-devtools");
    await expect.poll(devToolsOpen).toBe(true);
    await nativeWindow.evaluate((window) => window.focus());
    await click("toggle-devtools");
    await expect.poll(devToolsOpen).toBe(false);
    await expect.poll(async () => (await item("go-inbox"))?.enabled).toBe(true);
    expect((await item("go-inbox"))?.icon).toBe(true);
    expect((await item("go-inbox"))?.label).toContain("G → I");
    expect((await item("go-search"))?.accelerator).toMatch(/(Super|Command|Meta)\+K/i);
    expect((await item("drive-upload"))?.enabled).toBe(false);
    const installedMenu = await app.evaluateHandle(({ Menu }) =>
      Menu.getApplicationMenu()
    );
    await click("go-inbox");
    await expect(page).toHaveURL(/#\/inbox/);
    await click("go-comma-assistant");
    await expect(page).toHaveURL(/#\/$/);
    expect(
      await app.evaluate(
        ({ Menu }, installed) => Menu.getApplicationMenu() === installed,
        installedMenu
      )
    ).toBe(true);
    await installedMenu.dispose();
    await click("go-inbox");
    await expect(page).toHaveURL(/#\/inbox/);
    const before = (await item("toggle-left-sidebar"))?.checked;
    await click("toggle-left-sidebar");
    await expect
      .poll(async () => (await item("toggle-left-sidebar"))?.checked)
      .toBe(!before);
    await page.keyboard.press(process.platform === "darwin" ? "Meta+b" : "Control+b");
    await expect
      .poll(async () => (await item("toggle-left-sidebar"))?.checked)
      .toBe(before);
    await page.evaluate(() =>
      window.commaNative!.appPreferences.update({
        clientSettings: {
          appShortcutOverrides: {
            "go-search": {
              kind: "chord",
              stroke: {
                code: "KeyJ",
                modifiers: { meta: true, control: false, alt: false, shift: true },
              },
            },
          },
        },
      })
    );
    await expect
      .poll(async () => (await item("go-search"))?.accelerator)
      .toBe("Super+Shift+J");
    await click("browser-new-tab");
    await expect
      .poll(async () => (await item("browser-close-tab"))?.enabled)
      .toBe(true);
    await click("browser-close-tab");
    await click("go-shortcuts");
    await expect(page).toHaveURL(/category=keyboard-shortcuts/);
    await app.evaluate(({ BrowserWindow }) => BrowserWindow.getFocusedWindow()?.hide());
    await expect.poll(async () => (await item("record-start"))?.enabled).toBe(false);
  } finally {
    await app.close();
    await apiStub.close();
    await rm(userDataDir, { recursive: true, force: true });
  }
});

// TEMPORARY CI diagnosis for a focus failure seen only on CI runners: what
// holds focus when the main window does not get it. Remove once understood.
function run(command: string, timeout = 5_000) {
  try {
    return execSync(command, { encoding: "utf8", timeout });
  } catch (error) {
    return String(error);
  }
}

async function describeFocus(app: ElectronApplication, userDataDir: string) {
  const state = await app.evaluate(({ app: electronApp, BrowserWindow }) => ({
    focusedWindow: BrowserWindow.getFocusedWindow()?.webContents.getURL() ?? null,
    hidden: electronApp.isHidden(),
    windows: BrowserWindow.getAllWindows().map((window) => ({
      alwaysOnTop: window.isAlwaysOnTop(),
      focused: window.isFocused(),
      url: window.webContents.getURL(),
      visible: window.isVisible(),
    })),
  }));
  console.log(
    `[focus-diagnosis] front app: ${run("lsappinfo info -only name `lsappinfo front`")}`
  );
  // Runners cannot capture the screen; the unified log says which alert the
  // front app shows and who asked for it.
  console.log(
    `[focus-diagnosis] alerts:\n${run(
      'log show --last 30m --style compact --predicate \'process == "UserNotificationCenter" OR eventMessage CONTAINS[c] "CFUserNotification"\' | tail -40',
      60_000
    )}`
  );
  console.log(
    `[focus-diagnosis] alert text: ${run(
      'osascript -e \'tell application "System Events" to get value of every static text of every window of process "UserNotificationCenter"\'',
      15_000
    )}`
  );
  console.log(
    `[focus-diagnosis] Electron processes:\n${run(
      "ps -axo pid,etime,command | grep -i '[E]lectron' | cut -c1-220"
    )}`
  );
  const log = await readFile(join(userDataDir, "logs", "main.log"), "utf8").catch(
    (error: unknown) => String(error)
  );
  console.log(
    `[focus-diagnosis] ${JSON.stringify(state)}\n[focus-diagnosis] main.log tail:\n${log
      .split("\n")
      .filter((line) => !/^\s+at /.test(line))
      .slice(-40)
      .join("\n")}`
  );
}
