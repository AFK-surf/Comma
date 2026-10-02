import {
  _electron as electron,
  expect,
  test,
  type ElectronApplication,
  type Page,
} from "@playwright/test";
import type { IncomingMessage, ServerResponse } from "node:http";
import { readFileSync } from "node:fs";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { startSessionProjectionStub } from "../../../e2e/helpers/session-fixture";
import { closeElectronTestApp } from "./close-electron-test-app";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const english = JSON.parse(
  readFileSync(resolve(process.cwd(), "packages/i18n/messages/en.json"), "utf8")
) as Record<string, string>;
/** A line Comma says, in whichever tone this onboarding picked. */
const asked = (key: string, keys = "") => {
  const variants = ["", "_brisk", "_playful", "_warm", "_witty", "_minimal"].map(
    (suffix) =>
      english[`${key}${suffix}`]!.replace("{keys}", keys).replace(
        /[.*+?^${}()|[\]\\]/g,
        "\\$&"
      )
  );
  return new RegExp(`^(?:${variants.join("|")})$`);
};
const ONBOARDING_E2E_EMAIL = "onboarding-window-e2e@example.com";
const ONBOARDING_E2E_TOKEN = "comma_sess_onboarding_window_e2e";
const workspace = { group_id: "grp_onboarding", id: "wsp_onboarding", name: "Home" };
const linear = {
  brand: "linear",
  category: "Integrations",
  id: "linear",
  installed: false,
  locked: false,
  mcps: [],
  name: "Linear",
  skills: [],
  summary: "Plan product work",
};
let sessionStub: Awaited<ReturnType<typeof startSessionProjectionStub>>;

test.describe("onboarding window", () => {
  let testDirectory: string;

  test.beforeAll(async () => {
    sessionStub = await startSessionProjectionStub({
      email: ONBOARDING_E2E_EMAIL,
      handleRequest: answerOnboardingRequest,
    });
  });

  test.afterAll(async () => {
    await sessionStub.close();
  });

  test.beforeEach(async () => {
    testDirectory = await mkdtemp(join(tmpdir(), "comma-onboarding-window-e2e-"));
  });

  test.afterEach(async () => {
    await rm(testDirectory, { force: true, recursive: true });
  });

  test("opens on first launch before the main window, holds the product under it, and closes as completed", async () => {
    // A fresh profile: this account has not finished the onboarding here.
    const userDataPath = join(testDirectory, "user-data");
    const app = await electron.launch({
      args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataPath}`],
      cwd: electronAppDir,
      env: electronEnv(),
    });

    try {
      const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
      await mainWindow.waitForLoadState("domcontentloaded");

      // The main window presents the onboarding in its own window, by itself,
      // instead of covering its product with the overlay.
      const onboarding = await findElectronWindowByNativeRole(
        app,
        "onboarding-window",
        30_000
      );
      await expect(
        onboarding.getByRole("dialog", { name: "Welcome to Comma" })
      ).toBeVisible();
      // On first launch the onboarding comes before the product: the main
      // window loads hidden and shows only once the onboarding has closed.
      await expect.poll(() => mainWindowVisible(app)).toBe(false);
      // Its intro sound starts as it opens, without waiting for a press: the
      // window's autoplay policy lets it play. Whether it is heard depends on
      // the machine having an output device, which CI runners lack.
      await expect
        .poll(() =>
          onboarding.evaluate(() => {
            const audio = document.querySelector<HTMLAudioElement>(
              ".comma-onboarding audio"
            );
            return Boolean(audio && !audio.paused);
          })
        )
        .toBe(true);
      await expect(mainWindow.getByTestId("comma-window-bar-search")).toBeVisible();
      await expect(
        mainWindow.getByRole("dialog", { name: "Welcome to Comma" })
      ).toHaveCount(0);
      // Presenting again brings the open window forward instead of a second one.
      const lease = await signedInLease(mainWindow);
      await expect(presentOnboardingWindow(mainWindow, lease)).resolves.toEqual({
        presented: true,
      });
      await expect.poll(() => onboardingWindowCount(app)).toBe(1);

      // The product under it stands down: its Search shortcut stays shut, and
      // Home holds its hero back so nothing shows through the onboarding.
      const hero = mainWindow.getByTestId("chat-empty");
      await expect(hero).toHaveCSS("opacity", "0");
      await pressSearchShortcut(mainWindow);
      await mainWindow.waitForTimeout(300);
      await expect(
        mainWindow.getByRole("dialog", { name: "Search Comma" })
      ).toHaveCount(0);

      // A transparent sheet over the display that holds the main window, from
      // below its menu bar to its bottom edge, so it covers the Dock. It sits
      // above the Dock only while Comma is the active app; otherwise it is at
      // the normal level, so the browser and System Settings come in front.
      const placement = await app.evaluate(({ BrowserWindow, screen }) => {
        const windows = BrowserWindow.getAllWindows();
        const sheet = windows.find((window) =>
          window.webContents.getURL().includes("#/onboarding")
        );
        const main = windows.find(
          (window) => !window.webContents.getURL().includes("#/")
        );
        if (!sheet || !main)
          throw new Error("The onboarding or main window is missing.");
        const display = screen.getDisplayMatching(main.getBounds());
        return {
          active: BrowserWindow.getFocusedWindow() !== null,
          alwaysOnTop: sheet.isAlwaysOnTop(),
          bounds: sheet.getBounds(),
          display: { bounds: display.bounds, workArea: display.workArea },
          movable: sheet.isMovable(),
          resizable: sheet.isResizable(),
        };
      });
      const { bounds: display, workArea } = placement.display;
      expect(placement.bounds).toEqual({
        height: display.y + display.height - workArea.y,
        width: display.width,
        x: display.x,
        y: workArea.y,
      });
      expect(placement).toMatchObject({
        alwaysOnTop: placement.active,
        movable: false,
        resizable: false,
      });
      // The page paints nothing of its own: the desktop shows through.
      await expect
        .poll(() =>
          onboarding.evaluate(() =>
            [document.documentElement, document.body].map(
              (element) => getComputedStyle(element).backgroundColor
            )
          )
        )
        .toEqual(["rgba(0, 0, 0, 0)", "rgba(0, 0, 0, 0)"]);

      // A failed plugin authorization reports through a toast, which stays
      // in the sheet: the sheet covers the Dock, so all of it is usable. Start
      // ends the intro once the screen has dimmed, and the greeting hands over
      // to the apps card on its own.
      await onboarding
        .getByRole("button", { name: "Start", exact: true })
        .click({ timeout: 20_000 });
      await onboarding
        .getByRole("button", { name: "Connect Linear" })
        .click({ timeout: 20_000 });
      const toast = onboarding
        .locator("[data-sonner-toast]")
        .filter({ hasText: "Couldn’t connect the app." });
      await expect(toast).toBeVisible();
      // How far the toast reaches past the sheet, once it has slid in.
      await expect
        .poll(() =>
          toast.evaluate((element) => {
            const box = element.getBoundingClientRect();
            return Math.max(box.bottom - innerHeight, box.right - innerWidth);
          })
        )
        .toBeLessThanOrEqual(0);

      // Closing the window by hand (⌘W) closes the onboarding: Main records
      // it as completed for this account, and the product takes its
      // shortcuts back. The hero returns; the composer is not forced focus.
      await app.evaluate(({ BrowserWindow }) => {
        BrowserWindow.getAllWindows()
          .find((window) => window.webContents.getURL().includes("#/onboarding"))
          ?.close();
      });
      await expect.poll(() => onboardingWindowCount(app)).toBe(0);
      await expect.poll(() => mainWindowVisible(app)).toBe(true);
      await expect
        .poll(() => readCompletedUserIds(userDataPath))
        .toContain(sessionStub.userId);
      await expect(hero).toHaveCSS("opacity", "1");
      await expect(homeComposer(mainWindow)).not.toBeFocused();
      await pressSearchShortcut(mainWindow);
      await expect(
        mainWindow.getByRole("dialog", { name: "Search Comma" })
      ).toBeVisible();
      await mainWindow.keyboard.press("Escape");

      // General's Replay onboarding forgets that completion: Settings closes,
      // and the main window presents the onboarding again and steps aside for
      // it, as after a sign-in. Its renderer closes the window after the exit
      // of a Start chatting, and the main window comes back on Home's composer.
      await mainWindow.getByRole("button", { exact: true, name: "Settings" }).click();
      const settings = mainWindow.getByRole("dialog", { name: "Settings sections" });
      await expect(settings).toBeVisible();
      await mainWindow
        .locator('[data-setting-id="app.onboarding.replay"]')
        .getByRole("button", { exact: true, name: "Replay" })
        .click();
      await expect(settings).toBeHidden();
      const replay = await findElectronWindowByNativeRole(
        app,
        "onboarding-window",
        30_000
      );
      await expect(hero).toHaveCSS("opacity", "0");
      await expect.poll(() => mainWindowVisible(app)).toBe(false);
      await replay.evaluate(() => {
        // Main destroys the window as soon as it answers.
        void (
          globalThis as typeof globalThis & {
            commaNative: {
              onboarding: {
                closeWindow(input: Record<string, never>): Promise<void>;
              };
            };
          }
        ).commaNative.onboarding.closeWindow({});
      });
      await expect.poll(() => onboardingWindowCount(app)).toBe(0);
      await expect.poll(() => mainWindowVisible(app)).toBe(true);
      // Main records the completion for the user it presented the window to.
      await expect
        .poll(() => readCompletedUserIds(userDataPath))
        .toContain(sessionStub.userId);
      await expect(homeComposer(mainWindow)).toBeFocused();
      await expect(hero).toHaveCSS("opacity", "1");
    } finally {
      await closeElectronTestApp(app);
    }
  });

  test("tells of the Side Chat, then ends with the Open Comma shortcut: its keys turn the step into the success, and the welcome page follows", async () => {
    test.skip(
      process.platform !== "darwin",
      "The onboarding's shortcuts are macOS-only."
    );
    const userDataPath = join(testDirectory, "user-data");
    const app = await electron.launch({
      args: [electronMain, "--lang=en-US", `--user-data-dir=${userDataPath}`],
      cwd: electronAppDir,
      env: electronEnv(),
    });

    try {
      const onboarding = await findElectronWindowByNativeRole(
        app,
        "onboarding-window",
        30_000
      );
      await onboarding
        .getByRole("button", { name: "Start", exact: true })
        .click({ timeout: 20_000 });
      // Each item skipped, Comma hurried along by the full-window control
      // while it talks: the apps, the name, then this Mac's grants.
      for (const item of ["apps", "name", "permissions"]) {
        const card = onboarding.getByRole("group", {
          name: asked(`onboarding_question_${item}`),
        });
        await expect
          .poll(
            async () => {
              if (await card.isVisible()) return true;
              await onboarding
                .getByRole("button", { name: "Continue", exact: true })
                .click({ timeout: 500 })
                .catch(() => undefined);
              return false;
            },
            { timeout: 30_000 }
          )
          .toBe(true);
        await card.getByRole("button", { name: /^(Skip for now|Continue)$/ }).click();
      }

      // After the grants Comma tells of the Side Chat and its shortcut.
      await expect(
        onboarding.locator(".comma-chat-user-bubble-content", {
          hasText: asked("onboarding_side_chat", "⌃ + Z"),
        })
      ).toBeAttached({ timeout: 30_000 });
      // Comma's recap lands, then the conversation steps back for the
      // Open Comma shortcut, which takes the focus.
      const step = onboarding.getByRole("group", { name: "Try Option + Comma" });
      await expect(step).toBeFocused({ timeout: 30_000 });
      await expect(onboarding.getByText("Last step", { exact: true })).toBeVisible();

      // Another key says which two to press.
      await onboarding.keyboard.press("KeyY");
      await expect(step.getByRole("status")).toHaveText(
        "That’s not it. Press Option and Comma together."
      );

      // Both keys down: the keys turn green, the step's title and words
      // become the success in place, and a beat later the welcome page
      // follows, its Start chatting focused for the keyboard.
      await onboarding.keyboard.press("Alt+Comma");
      const done = onboarding.getByRole("group", { name: "Beautiful" });
      await expect(done.getByRole("status")).toHaveText(
        "You’ve got it. Press it anytime to bring up Comma."
      );
      await expect(
        onboarding.getByRole("heading", { name: "Comma is ready." })
      ).toBeVisible();
      await expect(
        onboarding.getByRole("button", { name: "Start chatting" })
      ).toBeFocused();
      await expect(done).toHaveCount(0);
    } finally {
      await closeElectronTestApp(app);
    }
  });
});

function answerOnboardingRequest(
  request: IncomingMessage,
  response: ServerResponse,
  path: string
) {
  const answer = (body: unknown, status = 200) => {
    response.writeHead(status, { "content-type": "application/json" });
    response.end(JSON.stringify(body));
    return true;
  };
  if (request.method === "POST" && path === "/v1/comma/me/bootstrap") {
    return answer({ status: "ready", workspace });
  }
  if (
    request.method === "GET" &&
    path === `/v1/comma/workspaces/${workspace.id}/plugins`
  ) {
    return answer({ data: [linear], next_cursor: null });
  }
  if (
    request.method === "POST" &&
    path === `/v1/comma/workspaces/${workspace.id}/plugins/linear/install`
  ) {
    return answer({ error: "install_failed" }, 500);
  }
  return false;
}

function electronEnv() {
  const {
    COMMA_ELECTRON_STARTUP_SESSION_TOKEN: _sessionToken,
    ELECTRON_RUN_AS_NODE: _electronRunAsNode,
    ...env
  } = process.env;
  return {
    ...env,
    COMMA_API_BASE_URL: sessionStub.baseUrl,
    COMMA_ELECTRON_STARTUP_SESSION_EMAIL: ONBOARDING_E2E_EMAIL,
    COMMA_ELECTRON_STARTUP_SESSION_TOKEN: ONBOARDING_E2E_TOKEN,
    NODE_ENV: "test",
  };
}

type RendererNative = typeof globalThis & {
  commaNative: {
    appPreferences: {
      update(input: {
        clientSettings: { onboardingCompletedUserIds: string[] };
      }): Promise<unknown>;
    };
    onboarding: {
      presentWindow(input: { session: unknown }): Promise<{ presented: boolean }>;
    };
    session: {
      state: {
        get(): Promise<{
          authority: { authorityInstanceId: string };
          generation: number;
          phase: string;
          session: { audience: string; sessionId: string } | null;
        }>;
      };
    };
  };
};

async function signedInLease(page: Page) {
  let lease: unknown;
  await expect
    .poll(async () => {
      lease = await page.evaluate(async () => {
        const snapshot = await (
          globalThis as RendererNative
        ).commaNative.session.state.get();
        return snapshot.phase === "signed_in" && snapshot.session
          ? {
              audience: snapshot.session.audience,
              authorityInstanceId: snapshot.authority.authorityInstanceId,
              generation: snapshot.generation,
              sessionId: snapshot.session.sessionId,
            }
          : undefined;
      });
      return lease !== undefined;
    })
    .toBe(true);
  return lease;
}

// The call the main window's onboarding host makes for an account that has
// not finished the onboarding on this device.
function presentOnboardingWindow(page: Page, session: unknown) {
  return page.evaluate(
    (lease) =>
      (globalThis as RendererNative).commaNative.onboarding.presentWindow({
        session: lease,
      }),
    session
  );
}

function homeComposer(page: Page) {
  return page
    .getByRole("region", { name: "Content" })
    .getByRole("textbox", { name: "AI prompt" });
}

function pressSearchShortcut(page: Page) {
  return page.keyboard.press(
    process.platform === "darwin" ? "Meta+KeyK" : "Control+KeyK"
  );
}

/** Whether the main window (the one with no hash route) is on screen. */
function mainWindowVisible(app: ElectronApplication) {
  return app.evaluate(({ BrowserWindow }) =>
    BrowserWindow.getAllWindows().some(
      (window) => !window.webContents.getURL().includes("#/") && window.isVisible()
    )
  );
}

function onboardingWindowCount(app: ElectronApplication) {
  return app.evaluate(
    ({ BrowserWindow }) =>
      BrowserWindow.getAllWindows().filter((window) =>
        window.webContents.getURL().includes("#/onboarding")
      ).length
  );
}

async function readCompletedUserIds(userDataPath: string): Promise<string[]> {
  return readFile(join(userDataPath, "app-preferences.json"), "utf8")
    .then(
      (text) =>
        (
          JSON.parse(text) as {
            clientSettings?: { onboardingCompletedUserIds?: string[] };
          }
        ).clientSettings?.onboardingCompletedUserIds ?? []
    )
    .catch(() => []);
}
