import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { electron, expect, test } from "./electron-test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";
import { findElectronWindowByRole } from "../src/test-support/electron-window";
import { findElectronWindowByNativeId } from "../src/test-support/electron-native-window";
import { closeElectronTestApp } from "./close-electron-test-app";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const TOKEN = "comma_sess_e2e_document_window";
const EMAIL = "document-window-e2e@example.com";
const fileName = "plan.md";
const document = "# Plan\n\nThe plugin talks to the desktop.\n";

// Open in window moves a document out of the right panel into a window of its own, on the panel's place. The panel
// keeps the document's tab and says where the document is, and shows it again once the window closes. The reader's
// edits in the window are saved on the device, so the panel has them.
// @mac: it needs a desktop that shows windows.
test(
  "Open in window shows a document in its own window on its panel's place, and the panel takes it back",
  { tag: "@mac" },
  async () => {
    const userDataDir = await mkdtemp(join(tmpdir(), "comma-document-window-e2e-"));
    recordElectronOnboardingCompleted(userDataDir, [`e2e-user:${EMAIL}`]);
    const stub = await startChatSmokeStub({
      sessionEmail: EMAIL,
      attachmentFiles: {
        "msg_document:1": {
          bytes: Buffer.from(document),
          contentType: "text/markdown",
          fileName,
        },
      },
      taskTranscript: [
        {
          actor_type: "agent",
          agent_id: "worker_document",
          message_id: "msg_document",
          kind: "message",
          content: [
            { type: "text", text: "Here is the plan." },
            {
              type: "file",
              file_name: fileName,
              mime_type: "text/markdown",
              blob_ref: { uuid: "u", hash: "h", size: Buffer.byteLength(document) },
            },
          ],
        },
      ],
    });
    const { ELECTRON_RUN_AS_NODE: _runAsNode, ...env } = process.env;
    const app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: {
        ...env,
        NODE_ENV: "test",
        COMMA_API_BASE_URL: stub.baseUrl,
        COMMA_ELECTRON_STARTUP_SESSION_TOKEN: TOKEN,
        COMMA_ELECTRON_STARTUP_SESSION_EMAIL: EMAIL,
      },
    });
    try {
      const main = await findElectronWindowByRole(app, "complementary", {
        name: "App sidebar",
      });
      await main.evaluate((hash) => {
        location.hash = hash;
      }, `#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`);
      await main.getByRole("button", { name: `Open ${fileName}` }).click();
      const panel = main.getByTestId("file-preview-panel");
      await expect(panel.getByText("The plugin talks to the desktop.")).toBeVisible();
      const place = await panel.evaluate((element) => {
        const rect = element.getBoundingClientRect();
        return {
          x: Math.round(window.screenX + rect.left),
          y: Math.round(window.screenY + rect.top),
          width: Math.round(rect.width),
          height: Math.round(rect.height),
        };
      });

      await panel.getByTestId("file-preview-open-window").click();
      const documentWindow = await findElectronWindowByNativeId(app, /^win_dynamic_/);
      // The window shows the document alone, with its text.
      await expect(
        documentWindow.getByText("The plugin talks to the desktop.")
      ).toBeVisible();
      // The panel says where the document is, in the document's place.
      await expect(main.getByTestId("document-notice-in-window")).toBeVisible();
      await expect(panel.getByText("The plugin talks to the desktop.")).toHaveCount(0);
      const bounds = await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .filter((window) => window.webContents.getURL().includes("/documents/window"))
          .map((window) => window.getBounds())
      );
      expect(bounds).toEqual([place]);

      // The reader edits the page in its window, as in the panel. The window has the focus as one a person works in
      // does: the test gives it that without taking the focus from the desktop.
      const page = documentWindow.locator(".comma-document-editor");
      const session = await documentWindow.context().newCDPSession(documentWindow);
      await session.send("Emulation.setFocusEmulationEnabled", { enabled: true });
      await page.getByText("The plugin talks to the desktop.").click();
      // The line's end, as a Mac's keys go to it (this test runs on a Mac).
      await documentWindow.keyboard.press("Meta+ArrowRight");
      await documentWindow.keyboard.type(" Edited in its window.");
      await expect(
        page.getByText("The plugin talks to the desktop. Edited in its window.")
      ).toBeVisible();
      // The menu of blocks is there, and the toolbar over a selection sets the text's form. It does not ask Comma:
      // the window has no chat for the ask to go with.
      await documentWindow.keyboard.press("Enter");
      await documentWindow.keyboard.type("/");
      await expect(documentWindow.getByTestId("document-slash-menu")).toBeVisible();
      await documentWindow.keyboard.press("Escape");
      await documentWindow.keyboard.press("Backspace");
      await documentWindow.keyboard.press("Backspace");
      await page.getByText("The plugin talks").dblclick();
      const toolbar = documentWindow.getByTestId("document-format-toolbar");
      await expect(toolbar.getByRole("button", { name: "Bold" })).toBeVisible();
      await expect(documentWindow.getByTestId("document-format-ask")).toHaveCount(0);

      // Move back closes the window: the panel shows the document again, with the edits made in the window.
      await main.getByRole("button", { name: "Move back to panel" }).click();
      await expect(main.getByTestId("document-notice-in-window")).toHaveCount(0);
      await expect(
        panel.getByText("The plugin talks to the desktop. Edited in its window.")
      ).toBeVisible();

      // The chat's next message carries the document as the reader left it in the window.
      await main
        .locator('[contenteditable="true"][aria-label="AI prompt"]')
        .filter({ visible: true })
        .first()
        .click();
      await main.keyboard.type("Make it shorter");
      await main.keyboard.press("Enter");
      await stub.waitForUploads(1);
      expect(stub.uploads[0]!.filename).toBe(fileName);
      expect(stub.uploads[0]!.bytes.toString()).toContain("Edited in its window.");
    } finally {
      await closeElectronTestApp(app);
      await stub.close();
      await rm(userDataDir, { force: true, recursive: true });
    }
  }
);
