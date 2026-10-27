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
const TOKEN = "comma_sess_e2e_app_window";
const EMAIL = "app-window-e2e@example.com";

/** An uncompressed ustar archive of one file: the bundle format. */
function tar(name: string, text: string): Buffer {
  const data = Buffer.from(text);
  const header = Buffer.alloc(512);
  header.write(name, 0);
  header.write("0000644\0", 100);
  header.write("0000000\0", 108);
  header.write("0000000\0", 116);
  header.write(data.length.toString(8).padStart(11, "0") + "\0", 124);
  header.write("00000000000\0", 136);
  header.write("        ", 148);
  header.write("0", 156);
  header.write("ustar\0", 257);
  header.write("00", 263);
  let sum = 0;
  for (const b of header) sum += b;
  header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148);
  return Buffer.concat([
    header,
    data,
    Buffer.alloc((512 - (data.length % 512)) % 512),
    Buffer.alloc(1024),
  ]);
}

// Open in window moves an app out of the right panel: the window opens on the panel's place, and the panel lets the app
// go only once the window shows, so the app never leaves the screen. The panel keeps the app's tab while the window is
// open, and runs the app again once it closes.
// @mac: it needs a desktop that shows windows.
test(
  "Open in window opens the app on its panel's place, and the panel takes it back when the window closes",
  { tag: "@mac" },
  async () => {
    const userDataDir = await mkdtemp(join(tmpdir(), "comma-app-window-e2e-"));
    recordElectronOnboardingCompleted(userDataDir, [`e2e-user:${EMAIL}`]);
    const bundle = tar(
      "index.html",
      "<!doctype html><html><body><p>Habits</p></body></html>"
    );
    const miniApp = {
      id: "app_habits",
      slug: "x7k2q9",
      workspace_id: chatSmokeWorkspace.id,
      name: "Team habits",
      description: "",
      icon_url: null,
      repo: null,
      visibility: "workspace",
      status: "active",
      live_version: 3,
      latest_version: 3,
      author: { name: "Ada" },
      capabilities: [],
      egress: [],
      secrets: [],
      grants: [],
      installed: false,
      install: null,
      storage: [],
      has_backend: false,
    };
    const stub = await startChatSmokeStub({
      sessionEmail: EMAIL,
      taskTranscript: [
        {
          actor_type: "agent",
          agent_id: "worker_app",
          message_id: "msg_app",
          kind: "message",
          text: "Team habits — preview version 3",
          content: [
            {
              type: "mini_app",
              version: 1,
              app_id: miniApp.id,
              app_version: 3,
              name: miniApp.name,
              summary: "Team habits — preview version 3",
            },
          ],
        },
      ],
      extraRoutes: (request, url, res) => {
        if (url.pathname === `/v1/comma/apps/${miniApp.id}/open`) {
          request.resume();
          res.writeHead(200, { "content-type": "application/json" });
          res.end(
            JSON.stringify({
              app: miniApp,
              version: 3,
              digest: "digest-3",
              viewer: { id: "usr", name: "Ada" },
              guest: false,
            })
          );
          return true;
        }
        if (url.pathname.endsWith(`/apps/${miniApp.id}/versions/3/bundle`)) {
          res.writeHead(200, { "content-type": "application/x-tar" });
          res.end(bundle);
          return true;
        }
        return false;
      },
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
      const card = main.getByTestId("mini-app-message-card");
      await expect(card.getByTestId("mini-app-frame")).toBeVisible();
      await card.getByTestId("mini-app-card-open").click();
      const panel = main.getByTestId("mini-app-chrome").last();
      await expect(main.getByTestId("mini-app-frame")).toHaveCount(2);
      const place = await panel.evaluate((chrome) => {
        const rect = chrome.parentElement!.getBoundingClientRect();
        return {
          x: Math.round(window.screenX + rect.left),
          y: Math.round(window.screenY + rect.top),
          width: Math.round(rect.width),
          height: Math.round(rect.height),
        };
      });

      // Main holds the new window's show until the test lets it go: until then the panel keeps the app.
      await app.evaluate(({ app: electronApp }) => {
        electronApp.once("browser-window-created", (_event, created) => {
          const held = globalThis as { releaseAppWindow?: () => void };
          const show = created.show.bind(created);
          const showInactive = created.showInactive.bind(created);
          let shown: (() => void) | undefined;
          created.show = () => {
            shown = show;
          };
          created.showInactive = () => {
            shown = showInactive;
          };
          held.releaseAppWindow = () => {
            created.show = show;
            created.showInactive = showInactive;
            (shown ?? show)();
          };
        });
      });
      await panel.getByRole("button", { name: "App actions" }).click();
      await main.getByRole("menuitem", { name: "Open in window" }).click();
      const appWindow = await findElectronWindowByNativeId(app, /^win_dynamic_/);
      await expect(appWindow.getByTestId("mini-app-chrome")).toBeAttached();
      await expect(main.getByTestId("mini-app-frame")).toHaveCount(2);

      // The window shows: the panel lets the app go and says where it runs.
      await app.evaluate(() =>
        (globalThis as { releaseAppWindow?: () => void }).releaseAppWindow?.()
      );
      await expect(main.getByTestId("mini-app-frame")).toHaveCount(1);
      await expect(main.getByTestId("mini-app-notice-in-window")).toBeVisible();
      const bounds = await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows()
          .filter((window) => window.webContents.getURL().includes("/window"))
          .map((window) => window.getBounds())
      );
      expect(bounds).toEqual([place]);

      // Move back closes the window: the app runs in the panel again.
      await main.getByRole("button", { name: "Move back to panel" }).click();
      await expect(main.getByTestId("mini-app-notice-in-window")).toHaveCount(0);
      await expect(main.getByTestId("mini-app-frame")).toHaveCount(2);
    } finally {
      await closeElectronTestApp(app);
      await stub.close();
      await rm(userDataDir, { force: true, recursive: true });
    }
  }
);
