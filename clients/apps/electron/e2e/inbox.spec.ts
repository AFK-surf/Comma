import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { electronVideoOptions } from "../../../e2e/helpers/electron-video";
import { electron, expect, test } from "./electron-test";
import type { ChatRuntimeSnapshot } from "@comma/chat-contract";
import type { CommaNativeBridge, SessionBridge } from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";
import { chooseTaskStatus, openTaskDetails } from "../../../e2e/helpers/task-panel";
import { findElectronWindowByRole } from "../src/test-support/electron-window";
import { closeElectronTestApp } from "./close-electron-test-app";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

const E2E_TOKEN = "comma_sess_e2e_inbox";
const E2E_EMAIL = "inbox-e2e@example.com";
const E2E_USER_ID = `e2e-user:${E2E_EMAIL}`;

function electronEnv(baseUrl: string) {
  const { ELECTRON_RUN_AS_NODE: _runAsNode, ...env } = process.env;
  return {
    ...env,
    NODE_ENV: "test",
    COMMA_API_BASE_URL: baseUrl,
    COMMA_ELECTRON_STARTUP_SESSION_TOKEN: E2E_TOKEN,
    COMMA_ELECTRON_STARTUP_SESSION_EMAIL: E2E_EMAIL,
  };
}

// Isolate userData so the seeded SecureStore session never touches the
// developer's real profile. On hooks so the tmp dir is removed even if launch
// throws before the test body's try/finally runs.
let userDataDir: string;

test.beforeEach(async () => {
  userDataDir = await mkdtemp(join(tmpdir(), "comma-inbox-e2e-"));
  recordElectronOnboardingCompleted(userDataDir, [E2E_USER_ID]);
});

test.afterEach(async () => {
  await rm(userDataDir, { force: true, recursive: true });
});

// @mac: on a mac-mini-ci VM the Task status menu stayed open over the
// window and took the next click; it needs the focused desktop of the Mac
// Studio job.
test(
  "Task review crosses Main and settles through the native chat bridge",
  { tag: "@mac" },
  async ({ browserName: _browserName }, testInfo) => {
    const stub = await startChatSmokeStub({
      includeTaskInInbox: true,
      sessionEmail: E2E_EMAIL,
      taskAssistantReply: "The reviewed result is ready.",
      taskStatus: "ready_for_review",
    });
    const app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: electronEnv(stub.baseUrl),
      ...electronVideoOptions(testInfo),
    });

    try {
      const appWindow = await findElectronWindowByRole(app, "complementary", {
        name: "App sidebar",
      });
      await appWindow.waitForLoadState("domcontentloaded");
      await appWindow.getByRole("link", { name: "Tasks" }).click();

      const task = appWindow.getByTestId("tasks-route").getByRole("button", {
        name: chatSmokeTaskConversation.title,
      });
      await expect(task).toBeVisible();

      const lease = await currentProductLease(appWindow);
      // The client core's list shows the Task in its status's column.
      await expect.poll(() => taskColumn(appWindow)).toBe("Needs Review");

      await task.click();
      await expect
        .poll(() =>
          nativeTaskConversation(
            appWindow,
            lease,
            chatSmokeWorkspace.group_id,
            chatSmokeTaskConversation.id
          )
        )
        .toMatchObject({
          reviewVersion: 2,
          status: "ready_for_review",
        });

      await expect.poll(() => stub.activeTaskListEventStreams).toBeGreaterThan(0);
      await expect
        .poll(() => stub.conversationListRequestCount)
        .toBeGreaterThanOrEqual(2);
      const activeTaskListEventStreamsBeforeFailure = stub.activeTaskListEventStreams;
      const taskListEventStreamsBeforeFailure = stub.taskListEventStreamRequestCount;
      stub.failNextConversationListRead();
      await chooseTaskStatus(await openTaskDetails(appWindow), "Done");
      await expect.poll(() => stub.taskStatusRequestCount).toBe(1);
      await stub.waitForFailedConversationListRead();

      await expect
        .poll(() =>
          nativeTaskConversation(
            appWindow,
            lease,
            chatSmokeWorkspace.group_id,
            chatSmokeTaskConversation.id
          )
        )
        .toEqual(expect.objectContaining({ status: "completed" }));

      // Back on the Tasks board, the client core's list shows the Task done.
      await appWindow.getByRole("link", { name: "Tasks" }).click();
      await expect.poll(() => taskColumn(appWindow)).toBe("Done");
      await expect
        .poll(() => stub.taskListEventStreamRequestCount)
        .toBeGreaterThan(taskListEventStreamsBeforeFailure);
      await expect
        .poll(() => stub.activeTaskListEventStreams)
        .toBe(activeTaskListEventStreamsBeforeFailure);
    } finally {
      await closeElectronTestApp(app);
      await stub.close();
    }
  }
);

// The macOS status-item menu is out of Playwright's reach, so Main records
// each menu it installs and clicks the requested Task row once, through the
// row's own click handler. The Tasks come from the client core's task list,
// and the shortcut comes from a preference change made in the renderer.
test(
  "the menu-bar menu lists In progress Tasks, opens one, and follows customized shortcuts",
  { tag: "@mac" },
  async ({ browserName: _browserName }, testInfo) => {
    const reviewTask = {
      id: "cnv_review_smoke",
      status: "ready_for_review",
      title: "Waiting for review",
    };
    const stub = await startChatSmokeStub({
      extraInlineTasks: [reviewTask],
      includeTaskInInbox: true,
      sessionEmail: E2E_EMAIL,
      taskStatus: "active",
    });
    const menuFilePath = join(userDataDir, "status-tray-menu.json");
    const taskRowId = `task:${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`;
    const app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: {
        ...electronEnv(stub.baseUrl),
        COMMA_ELECTRON_E2E_ACTIVATE_STATUS_TRAY_MENU_ITEM: taskRowId,
        COMMA_ELECTRON_E2E_STATUS_TRAY_MENU_FILE_PATH: menuFilePath,
      },
      ...electronVideoOptions(testInfo),
    });
    const menu = async (): Promise<{
      host?: string;
      rows: { accelerator?: string; id?: string; label?: string; type?: string }[];
    }> => {
      try {
        return JSON.parse(await readFile(menuFilePath, "utf8"));
      } catch {
        return { rows: [] };
      }
    };
    const menuRows = async () => (await menu()).rows;

    try {
      const appWindow = await findElectronWindowByRole(app, "complementary", {
        name: "App sidebar",
      });
      await expect(appWindow).toHaveURL(
        new RegExp(
          `#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
        )
      );
      // On macOS the menu-bar helper draws it, so hovering it never waits on
      // Main; Electron's Tray draws it elsewhere.
      expect((await menu()).host).toBe(
        process.platform === "darwin" ? "menu-bar-helper" : "electron"
      );
      const rows = await menuRows();
      expect(rows).toContainEqual(
        expect.objectContaining({
          id: taskRowId,
          label: chatSmokeTaskConversation.title,
        })
      );
      // The Task that waits for review is in the same Inbox, but not In progress.
      expect(rows.map((row) => row.id)).not.toContain(
        `task:${chatSmokeWorkspace.group_id}/${reviewTask.id}`
      );
      // Open Comma is the only command above the Tasks, which start with
      // their section title.
      expect(rows.findIndex((row) => row.type === "separator")).toBe(1);
      expect(rows[2]).toMatchObject({ type: "header" });
      // The Settings row shows the chord the renderer publishes for the app menu.
      const settingsAccelerator = async () =>
        (await menuRows()).find((row) => row.id === "settings")?.accelerator;
      await expect.poll(settingsAccelerator).toBe("Super+,");

      await appWindow.evaluate(() =>
        window.commaNative!.appPreferences.update({
          clientSettings: {
            openCommaShortcut: {
              key: "7",
              modifiers: { alt: true, control: true, meta: false, shift: true },
            },
          },
        })
      );
      await expect
        .poll(async () => (await menuRows())[0]?.accelerator)
        .toBe("Control+Alt+Shift+7");

      await appWindow.evaluate(() =>
        window.commaNative!.appPreferences.update({
          clientSettings: {
            appShortcutOverrides: {
              "go-settings": {
                kind: "chord",
                stroke: {
                  code: "KeyJ",
                  modifiers: { alt: true, control: false, meta: true, shift: false },
                },
              },
            },
          },
        })
      );
      await expect
        .poll(async () =>
          (await menuRows()).some((row) => row.accelerator === "Super+Alt+J")
        )
        .toBe(true);
    } finally {
      await closeElectronTestApp(app);
      await stub.close();
    }
  }
);

function currentProductLease(appWindow: import("@playwright/test").Page) {
  return appWindow.evaluate(async (): Promise<SessionProductLease> => {
    const lifecycle = await (
      window as unknown as { commaNative: { session: SessionBridge } }
    ).commaNative.session.state.get();
    if (lifecycle.phase !== "signed_in") {
      throw new Error("A Task review requires a signed-in Session.");
    }
    return {
      audience: lifecycle.session.audience,
      authorityInstanceId: lifecycle.authority.authorityInstanceId,
      generation: lifecycle.generation,
      sessionId: lifecycle.session.sessionId,
    };
  });
}

function nativeTaskConversation(
  appWindow: import("@playwright/test").Page,
  session: SessionProductLease,
  groupId: string,
  conversationId: string
) {
  return appWindow.evaluate(
    async ({ expectedSession, targetConversationId, targetGroupId }) => {
      const scope = window as unknown as {
        commaCore: {
          subscribe(
            topic: object,
            onValue: (value: unknown) => void,
            onError: (error: unknown) => void
          ): () => void;
        };
        commaNative: CommaNativeBridge;
      };
      // The core's chat as this window sees it, once.
      const { session: shown, snapshot } = await new Promise<{
        session: { sessionId: string } | null;
        snapshot: ChatRuntimeSnapshot;
      }>((settle, fail) => {
        const stop = scope.commaCore.subscribe(
          { topic: "chat", surface: scope.commaNative.self.windowId },
          (value) => {
            settle(value as never);
            queueMicrotask(() => stop());
          },
          fail
        );
      });
      if (shown?.sessionId !== expectedSession.sessionId) return undefined;
      return snapshot.sessions.find(
        (candidate) =>
          candidate.groupId === targetGroupId &&
          candidate.conversationId === targetConversationId
      )?.state.conversation;
    },
    {
      expectedSession: session,
      targetConversationId: conversationId,
      targetGroupId: groupId,
    }
  );
}

/** The board column the smoke Task shows in, as the Tasks route draws the client core's list. */
async function taskColumn(appWindow: import("@playwright/test").Page) {
  const column = appWindow
    .getByTestId("tasks-route")
    .locator('[data-slot="task-board-column"]')
    .filter({
      has: appWindow.getByRole("button", { name: chatSmokeTaskConversation.title }),
    });
  if ((await column.count()) !== 1) return undefined;
  return column.locator('[data-slot="task-board-column-label"]').textContent();
}
