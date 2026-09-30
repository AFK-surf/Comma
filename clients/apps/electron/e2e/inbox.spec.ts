import { electronVideoOptions } from "../../../e2e/helpers/electron-video";
import { _electron as electron, expect, test } from "@playwright/test";
import type { ChatRuntimeSnapshot } from "@comma/chat-contract";
import type {
  CommaNativeBridge,
  ProductInboxBridge,
  SessionBridge,
} from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import { createServer, type Server, type ServerResponse } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import type { AddressInfo } from "node:net";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";
import { openTaskDetails, taskDoneButton } from "../../../e2e/helpers/task-panel";
import { findElectronWindowByRole } from "../src/test-support/electron-window";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

const E2E_TOKEN = "comma_sess_e2e_inbox";
const E2E_EMAIL = "inbox-e2e@example.com";
const E2E_SESSION_ID = `e2e-session:${E2E_EMAIL}`;
const E2E_USER_ID = `e2e-user:${E2E_EMAIL}`;
const WORKSPACE = {
  group_id: "grp-e2e",
  id: "ws-e2e",
  name: "E2E Workspace",
};
const WORKSPACE_B = {
  group_id: "grp-e2e-b",
  id: "ws-e2e-b",
  name: "E2E Workspace B",
};
const CONVERSATION = {
  group_id: WORKSPACE.group_id,
  id: "conv-e2e-1",
  kind: "user_chat",
  status: "open",
  title: "E2E tracer conversation",
  updated_at: 1_720_000_000,
  created_at: 1_710_000_000,
  freshness: { state: "fresh" as const },
};
const NEXT_CONVERSATION = {
  ...CONVERSATION,
  id: "conv-e2e-2",
  title: "E2E paginated conversation",
  updated_at: 1_730_000_000,
};
const NEXT_CURSOR = "page-2";
const CONVERSATION_B = {
  ...CONVERSATION,
  group_id: WORKSPACE_B.group_id,
  id: "conv-e2e-b",
  title: "E2E workspace B conversation",
};

/**
 * Local `/v1` stub matching what `ProductInboxService` fetches. `fail` flips it
 * to 500s so a second read exercises the `cache` path. `authHeaders` records
 * the Bearer the Main proxy injected (proves the seeded session flows through).
 */
function startSalixStub({ paginate = true }: { paginate?: boolean } = {}) {
  const authHeaders: (string | undefined)[] = [];
  const conversationRequests: string[] = [];
  const eventStreamRequests: string[] = [];
  let delayedWorkspaceResponse: ServerResponse | undefined;
  let holdNextWorkspace = false;
  let notifyDelayedWorkspace: (() => void) | undefined;
  let delayedWorkspace = Promise.resolve();
  let fail = false;
  let failNextWorkspaceBConversation = false;
  let notifyFailedWorkspaceBConversation: (() => void) | undefined;
  let failedWorkspaceBConversation = Promise.resolve();

  const server = createServer((req, res) => {
    authHeaders.push(req.headers.authorization);
    if (fail) {
      res.writeHead(500).end("stub down");
      return;
    }

    const url = new URL(req.url ?? "", "http://127.0.0.1");
    res.setHeader("content-type", "application/json");
    if (req.method === "GET" && url.pathname === "/v1/comma/auth/session") {
      res.end(
        JSON.stringify({
          expires_at: 4_102_444_800,
          session_id: E2E_SESSION_ID,
          user: { email: E2E_EMAIL, id: E2E_USER_ID },
        })
      );
      return;
    }
    if (url.pathname === "/v1/comma/workspaces") {
      if (holdNextWorkspace) {
        holdNextWorkspace = false;
        delayedWorkspaceResponse = res;
        notifyDelayedWorkspace?.();
        return;
      }
      res.end(JSON.stringify({ data: [WORKSPACE, WORKSPACE_B] }));
      return;
    }
    if (url.pathname === `/v1/comma/groups/${WORKSPACE.group_id}/conversations`) {
      conversationRequests.push(url.toString());
      const cursor = url.searchParams.get("cursor");
      res.end(
        JSON.stringify(
          cursor === NEXT_CURSOR
            ? {
                data: [NEXT_CONVERSATION],
                has_more: false,
                next_cursor: null,
              }
            : {
                data: [CONVERSATION],
                has_more: paginate,
                next_cursor: paginate ? NEXT_CURSOR : null,
              }
        )
      );
      return;
    }
    if (url.pathname === `/v1/comma/groups/${WORKSPACE_B.group_id}/conversations`) {
      conversationRequests.push(url.toString());
      if (failNextWorkspaceBConversation) {
        failNextWorkspaceBConversation = false;
        notifyFailedWorkspaceBConversation?.();
        notifyFailedWorkspaceBConversation = undefined;
        res.writeHead(503).end(JSON.stringify({ error: "stub unavailable" }));
        return;
      }
      res.end(
        JSON.stringify({
          data: [CONVERSATION_B],
          has_more: false,
          next_cursor: null,
        })
      );
      return;
    }
    if (
      url.pathname === `/v1/comma/groups/${WORKSPACE.group_id}/conversations/events` ||
      url.pathname === `/v1/comma/groups/${WORKSPACE_B.group_id}/conversations/events`
    ) {
      eventStreamRequests.push(url.toString());
      res.writeHead(503).end(JSON.stringify({ error: "stream unavailable" }));
      return;
    }
    if (
      req.method === "POST" &&
      url.pathname === `/v1/comma/groups/${WORKSPACE.group_id}/assistant-chat`
    ) {
      res.end(JSON.stringify(CONVERSATION));
      return;
    }
    res.writeHead(404).end(JSON.stringify({ data: [] }));
  });

  return new Promise<{
    baseUrl: string;
    authHeaders: (string | undefined)[];
    conversationRequests: string[];
    eventStreamRequests: string[];
    failNextWorkspaceBConversationRead: () => void;
    holdNextWorkspace: () => void;
    releaseDelayedWorkspace: () => void;
    setFail: (value: boolean) => void;
    waitForFailedWorkspaceBConversationRead: () => Promise<void>;
    waitForDelayedWorkspace: () => Promise<void>;
    close: () => Promise<void>;
  }>((resolvePromise) => {
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as AddressInfo;
      resolvePromise({
        authHeaders,
        baseUrl: `http://127.0.0.1:${port}`,
        conversationRequests,
        eventStreamRequests,
        failNextWorkspaceBConversationRead: () => {
          failNextWorkspaceBConversation = true;
          failedWorkspaceBConversation = new Promise<void>((resolveFailed) => {
            notifyFailedWorkspaceBConversation = resolveFailed;
          });
        },
        holdNextWorkspace: () => {
          if (delayedWorkspaceResponse) {
            throw new Error("A delayed Workspace response is already pending.");
          }
          holdNextWorkspace = true;
          delayedWorkspace = new Promise<void>((resolveDelayed) => {
            notifyDelayedWorkspace = resolveDelayed;
          });
        },
        releaseDelayedWorkspace: () => {
          const response = delayedWorkspaceResponse;
          if (!response) throw new Error("No delayed Workspace response is pending.");
          delayedWorkspaceResponse = undefined;
          notifyDelayedWorkspace = undefined;
          response.end(JSON.stringify({ data: [WORKSPACE, WORKSPACE_B] }));
        },
        setFail: (value) => {
          fail = value;
        },
        waitForFailedWorkspaceBConversationRead: () => failedWorkspaceBConversation,
        waitForDelayedWorkspace: () => delayedWorkspace,
        close: () =>
          new Promise<void>((done) => (server as Server).close(() => done())),
      });
    });
  });
}

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
});

test.afterEach(async () => {
  await rm(userDataDir, { force: true, recursive: true });
});

test("native Inbox preserves lease ordering, pagination, and cached fallback", async ({
  browserName: _browserName,
}, testInfo) => {
  const stub = await startSalixStub();
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
    await appWindow.getByRole("link", { name: "Inbox" }).click();
    await expect(appWindow.getByText(CONVERSATION.title)).toBeVisible();
    await expect(appWindow.getByTestId("inbox-source")).toHaveAttribute(
      "data-source",
      "live-sync"
    );

    const lease = await appWindow.evaluate(async () => {
      const scope = window as unknown as {
        commaNative: {
          session: SessionBridge;
        };
      };
      const lifecycle = await scope.commaNative.session.state.get();
      if (lifecycle.phase !== "signed_in") {
        throw new Error("ProductInbox race requires a signed-in Session.");
      }
      return {
        audience: lifecycle.session.audience,
        authorityInstanceId: lifecycle.authority.authorityInstanceId,
        generation: lifecycle.generation,
        sessionId: lifecycle.session.sessionId,
      } satisfies SessionProductLease;
    });

    stub.holdNextWorkspace();
    const delayedRefresh = appWindow.evaluate(
      async ({ expectedLease, workspaceId }) =>
        (
          window as unknown as {
            commaNative: { productInbox: ProductInboxBridge };
          }
        ).commaNative.productInbox.refresh({
          session: expectedLease,
          workspaceId,
        }),
      { expectedLease: lease, workspaceId: WORKSPACE.id }
    );
    await stub.waitForDelayedWorkspace();

    await expect(
      appWindow.evaluate(
        async ({ expectedLease, workspaceId }) =>
          (
            window as unknown as {
              commaNative: { productInbox: ProductInboxBridge };
            }
          ).commaNative.productInbox.refresh({
            session: expectedLease,
            workspaceId,
          }),
        { expectedLease: lease, workspaceId: WORKSPACE_B.id }
      )
    ).resolves.toMatchObject({
      snapshot: { activeWorkspaceId: WORKSPACE_B.id },
    });
    stub.releaseDelayedWorkspace();
    await expect(delayedRefresh).rejects.toThrow();
    await expect(
      appWindow.evaluate(
        async (expectedLease) =>
          (
            window as unknown as {
              commaNative: { productInbox: ProductInboxBridge };
            }
          ).commaNative.productInbox.state.get({ session: expectedLease }),
        lease
      )
    ).resolves.toMatchObject({
      snapshot: { activeWorkspaceId: WORKSPACE_B.id },
    });

    await expect(
      appWindow.evaluate(
        async ({ cursor, expectedLease, workspaceId }) =>
          (
            window as unknown as {
              commaNative: { productInbox: ProductInboxBridge };
            }
          ).commaNative.productInbox.refresh({
            cursor,
            session: expectedLease,
            workspaceId,
          }),
        {
          cursor: NEXT_CURSOR,
          expectedLease: lease,
          workspaceId: WORKSPACE.id,
        }
      )
    ).resolves.toMatchObject({
      snapshot: {
        activeWorkspaceId: WORKSPACE.id,
        hasMore: false,
        items: [expect.objectContaining({ conversationId: NEXT_CONVERSATION.id })],
      },
    });
    expect(
      stub.conversationRequests.some(
        (request) => new URL(request).searchParams.get("cursor") === NEXT_CURSOR
      )
    ).toBe(true);
    expect(stub.authHeaders).toContain(`Bearer ${E2E_TOKEN}`);

    stub.setFail(true);
    await expect(
      appWindow.evaluate(
        async ({ expectedLease, workspaceId }) =>
          (
            window as unknown as {
              commaNative: { productInbox: ProductInboxBridge };
            }
          ).commaNative.productInbox.refresh({
            session: expectedLease,
            workspaceId,
          }),
        { expectedLease: lease, workspaceId: WORKSPACE.id }
      )
    ).resolves.toMatchObject({
      snapshot: {
        activeWorkspaceId: WORKSPACE.id,
        source: "cache",
      },
    });
  } finally {
    await app.close();
    await stub.close();
  }
});

test("native Inbox retries a selected Group that the previous Group stream cannot recover", async ({
  browserName: _browserName,
}, testInfo) => {
  // This native refresh does not change the renderer's selected Workspace.
  // Keep Group A finite so its automatic pagination cannot replace the B retry.
  const stub = await startSalixStub({ paginate: false });
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
    await appWindow.getByRole("link", { name: "Inbox" }).click();
    await expect(appWindow.getByText(CONVERSATION.title)).toBeVisible();
    await expect
      .poll(
        () =>
          stub.eventStreamRequests.filter(
            (request) =>
              new URL(request).pathname ===
              `/v1/comma/groups/${WORKSPACE.group_id}/conversations/events`
          ).length
      )
      .toBeGreaterThan(0);

    const lease = await currentProductLease(appWindow);
    stub.failNextWorkspaceBConversationRead();
    await expect(
      appWindow.evaluate(
        async ({ expectedLease, workspaceId }) =>
          (
            window as unknown as {
              commaNative: { productInbox: ProductInboxBridge };
            }
          ).commaNative.productInbox.refresh({
            session: expectedLease,
            workspaceId,
          }),
        { expectedLease: lease, workspaceId: WORKSPACE_B.id }
      )
    ).resolves.toMatchObject({
      snapshot: { activeWorkspaceId: WORKSPACE_B.id },
    });
    await stub.waitForFailedWorkspaceBConversationRead();

    // The grp_1 stream cannot resync grp_2. ProductInbox must use its bounded
    // list retry, settle grp_2, and only then transfer stream ownership.
    await expect
      .poll(
        () =>
          stub.conversationRequests.filter(
            (request) =>
              new URL(request).pathname ===
              `/v1/comma/groups/${WORKSPACE_B.group_id}/conversations`
          ).length
      )
      .toBe(2);
    await expect
      .poll(async () => {
        const state = await appWindow.evaluate(
          async (expectedLease) =>
            (
              window as unknown as {
                commaNative: { productInbox: ProductInboxBridge };
              }
            ).commaNative.productInbox.state.get({ session: expectedLease }),
          lease
        );
        return state.snapshot;
      })
      .toMatchObject({
        activeWorkspaceId: WORKSPACE_B.id,
        items: [expect.objectContaining({ conversationId: CONVERSATION_B.id })],
        source: "live-sync",
      });
  } finally {
    await app.close();
    await stub.close();
  }
});

test("Task review crosses Main and settles through the native chat bridge", async ({
  browserName: _browserName,
}, testInfo) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    sessionEmail: E2E_EMAIL,
    taskAssistantReply: "The reviewed result is ready.",
    taskSchedule: null,
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
    const inbox = await appWindow.evaluate(
      async (session) =>
        (
          window as unknown as {
            commaNative: { productInbox: ProductInboxBridge };
          }
        ).commaNative.productInbox.state.get({ session }),
      lease
    );
    expect(inbox.snapshot.items).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          conversationId: chatSmokeTaskConversation.id,
          groupId: chatSmokeWorkspace.group_id,
          kind: "agent_task",
          status: "ready_for_review",
        }),
      ])
    );

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
    await taskDoneButton(await openTaskDetails(appWindow)).click();
    expect(stub.taskAcceptRequestCount).toBe(1);
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

    await expect.poll(() => nativeTaskListStatus(appWindow, lease)).toBe("completed");
    await expect
      .poll(() => stub.taskListEventStreamRequestCount)
      .toBeGreaterThan(taskListEventStreamsBeforeFailure);
    await expect
      .poll(() => stub.activeTaskListEventStreams)
      .toBe(activeTaskListEventStreamsBeforeFailure);
  } finally {
    await app.close();
    await stub.close();
  }
});

// The macOS status-item menu is out of Playwright's reach, so Main records
// each menu it installs and clicks the requested Task row once, through the
// row's own click handler. The Task comes from the ProductInbox projection,
// and the shortcut comes from a preference change made in the renderer.
test("the menu-bar menu lists recent Tasks, opens one, and follows customized shortcuts", async ({
  browserName: _browserName,
}, testInfo) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    sessionEmail: E2E_EMAIL,
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
  const menuRows = async (): Promise<
    { accelerator?: string; id?: string; label?: string; type?: string }[]
  > => {
    try {
      return JSON.parse(await readFile(menuFilePath, "utf8"));
    } catch {
      return [];
    }
  };

  try {
    const appWindow = await findElectronWindowByRole(app, "complementary", {
      name: "App sidebar",
    });
    await expect(appWindow).toHaveURL(
      new RegExp(
        `#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    const rows = await menuRows();
    expect(rows).toContainEqual(
      expect.objectContaining({ id: taskRowId, label: chatSmokeTaskConversation.title })
    );
    // Open Comma and Open Side Chat are the only commands above the Tasks,
    // which start with their section title.
    expect(rows.findIndex((row) => row.type === "separator")).toBe(2);
    expect(rows[3]).toMatchObject({ type: "header" });
    // The Settings row shows the chord the renderer publishes for the app menu.
    const settingsAccelerator = async () =>
      (await menuRows()).find((row) => row.accelerator?.endsWith("+,"))?.accelerator;
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
    await app.close();
    await stub.close();
  }
});

test("native Task review converges after a stale detail refresh before retrying acceptance", async ({
  browserName: _browserName,
}, testInfo) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    sessionEmail: E2E_EMAIL,
    taskAcceptConflictOnce: true,
    taskAssistantReply: "The reviewed result is ready.",
    taskSchedule: null,
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
    await appWindow.evaluate(() => {
      const scope = window as unknown as {
        commaTaskReviewRace?: {
          leaseIds: string[];
          originalRandomUuid: typeof crypto.randomUUID;
        };
      };
      const originalRandomUuid = crypto.randomUUID.bind(crypto);
      scope.commaTaskReviewRace = { leaseIds: [], originalRandomUuid };
      Object.defineProperty(crypto, "randomUUID", {
        configurable: true,
        value: () => {
          const leaseId = originalRandomUuid();
          scope.commaTaskReviewRace?.leaseIds.push(leaseId);
          return leaseId;
        },
      });
    });
    await task.click();

    const session = await currentProductLease(appWindow);
    await expect
      .poll(() =>
        nativeTaskConversation(
          appWindow,
          session,
          chatSmokeWorkspace.group_id,
          chatSmokeTaskConversation.id
        )
      )
      .toMatchObject({ reviewVersion: 2, status: "ready_for_review" });

    const raceLease = await appWindow.evaluate(
      ({ conversationId, groupId, session: leaseSession, workspaceId }) => {
        const scope = window as unknown as {
          commaNative: CommaNativeBridge;
          commaTaskReviewRace?: {
            leaseIds: string[];
            originalRandomUuid: typeof crypto.randomUUID;
          };
        };
        const capture = scope.commaTaskReviewRace;
        if (!capture || capture.leaseIds.length !== 1) {
          throw new Error(
            `Expected one retained Chat lease, observed ${capture?.leaseIds.length ?? 0}.`
          );
        }
        Object.defineProperty(crypto, "randomUUID", {
          configurable: true,
          value: capture.originalRandomUuid,
        });
        delete scope.commaTaskReviewRace;
        return {
          conversationId,
          groupId,
          leaseId: capture.leaseIds[0]!,
          session: leaseSession,
          subscriberId: `${scope.commaNative.self.windowId}:${groupId}/${conversationId}`,
          workspaceId,
        };
      },
      {
        conversationId: chatSmokeTaskConversation.id,
        groupId: chatSmokeWorkspace.group_id,
        session,
        workspaceId: chatSmokeWorkspace.id,
      }
    );

    const detailRequestsBeforeRace = stub.taskDetailRequestCount;
    stub.holdNextTaskDetail();
    await appWindow.evaluate(
      async (lease) =>
        (
          window as unknown as { commaNative: CommaNativeBridge }
        ).commaNative.chat.refresh(lease),
      raceLease
    );
    await stub.waitForDelayedTaskDetail();
    expect(stub.taskDetailRequestCount).toBe(detailRequestsBeforeRace + 1);

    await taskDoneButton(await openTaskDetails(appWindow)).click();
    await expect.poll(() => stub.taskAcceptRequestCount).toBe(1);

    stub.releaseDelayedTaskDetail();
    await expect
      .poll(() => stub.taskDetailRequestCount)
      .toBeGreaterThan(detailRequestsBeforeRace + 1);
    await expect
      .poll(() =>
        nativeTaskConversation(
          appWindow,
          session,
          chatSmokeWorkspace.group_id,
          chatSmokeTaskConversation.id
        )
      )
      .toMatchObject({ reviewVersion: 3, status: "ready_for_review" });

    await taskDoneButton(await openTaskDetails(appWindow)).click();
    expect(stub.taskAcceptRequestCount).toBe(2);
    await expect
      .poll(() =>
        nativeTaskConversation(
          appWindow,
          session,
          chatSmokeWorkspace.group_id,
          chatSmokeTaskConversation.id
        )
      )
      .toEqual(expect.objectContaining({ status: "completed" }));
  } finally {
    await app.close();
    await stub.close();
  }
});

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
      const snapshot = (
        await (
          window as unknown as {
            commaNative: {
              chat: {
                state: {
                  get: (input: { session: SessionProductLease }) => Promise<{
                    snapshot: ChatRuntimeSnapshot;
                  }>;
                };
              };
            };
          }
        ).commaNative.chat.state.get({ session: expectedSession })
      ).snapshot;
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

function nativeTaskListStatus(
  appWindow: import("@playwright/test").Page,
  session: SessionProductLease
) {
  return appWindow.evaluate(
    async ({ expectedSession, taskConversationId }) => {
      const snapshot = await (
        window as unknown as {
          commaNative: { productInbox: ProductInboxBridge };
        }
      ).commaNative.productInbox.state.get({ session: expectedSession });
      return snapshot.snapshot.items.find(
        (item) => item.conversationId === taskConversationId
      )?.status;
    },
    {
      expectedSession: session,
      taskConversationId: chatSmokeTaskConversation.id,
    }
  );
}
