import { electronVideoOptions } from "../../../e2e/helpers/electron-video";
import { _electron as electron, expect, test, type Page } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  chatSmokeAssistantReply,
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";
import { recordElectronOnboardingCompleted } from "../../../e2e/helpers/electron-profile";
import { openTaskDetails, taskDoneButton } from "../../../e2e/helpers/task-panel";
import { findElectronWindowByRole } from "../src/test-support/electron-window";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

const E2E_TOKEN = "comma_sess_e2e_comma_center";
const E2E_EMAIL = "comma-center-e2e@example.com";
const HISTORY_PROBE_MESSAGE = "History probe message";

// Reload tests resolve initial setup immediately; later resolutions keep this
// delay. The credential-reconcile test retains the delay for every resolution.
// A Home visit that renders the transcript from the
// remembered conversation target never waits for it; one that has to resolve
// the target again cannot show the transcript before the delay elapses, so
// the transcript deadline below tells a carried target from a refetched one
// without a request counter.
const WORKSPACE_CHAT_DELAY_MS = 6_000;
const CARRIED_TRANSCRIPT_TIMEOUT_MS = 3_000;
// Long enough for a background resolution to have passed the stub delay.
const BACKGROUND_RESOLUTION_SETTLE_MS = WORKSPACE_CHAT_DELAY_MS + 2_000;

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

let userDataDir: string;

test.beforeEach(async () => {
  userDataDir = await mkdtemp(join(tmpdir(), "comma-center-history-e2e-"));
});

test.afterEach(async () => {
  await rm(userDataDir, { force: true, recursive: true });
});

async function sendHistoryProbe(appWindow: Page) {
  const content = appWindow.getByRole("region", { name: "Content" });
  const composer = content.locator(".comma-chat-composer");
  const textbox = composer.getByRole("textbox", { name: "AI prompt" });
  await expect(composer).toBeVisible({ timeout: 30_000 });
  await textbox.fill(HISTORY_PROBE_MESSAGE);
  const send = composer.getByRole("button", { name: "Send" });
  await expect(send).toBeEnabled({ timeout: 30_000 });
  await send.click();
  await expect(content.getByText(HISTORY_PROBE_MESSAGE)).toBeVisible();
  await expect(content.getByText(chatSmokeAssistantReply)).toBeVisible({
    timeout: 30_000,
  });
}

// Home renders the remembered conversation target's transcript at once; only
// a forgotten target leaves Home waiting on the stub's delayed resolution.
async function expectHomeTranscriptCarried(appWindow: Page) {
  await appWindow.getByRole("link", { exact: true, name: "Home" }).click();
  const content = appWindow.getByRole("region", { name: "Content" });
  await expect(content.getByText(HISTORY_PROBE_MESSAGE)).toBeVisible({
    timeout: CARRIED_TRANSCRIPT_TIMEOUT_MS,
  });
  await expect(content.getByText(chatSmokeAssistantReply)).toBeVisible({
    timeout: CARRIED_TRANSCRIPT_TIMEOUT_MS,
  });
}

// Regression coverage for the "history disappears when opening a Task" bug:
// a credential reconcile (the recovery a renderer product-transport 401/409
// triggers, or a token refresh) bumps the Session generation, which resets the
// main ChatCoordinator and remounts the renderer ChatProvider. Before the fix
// the remounted registry forgot the Home conversation target, so the next
// Home visit paid a full cold re-resolution before the transcript came back.
test("Home history survives a Session credential reconcile on a task route", async ({
  browserName: _browserName,
}, testInfo) => {
  test.setTimeout(180_000);
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    sessionEmail: E2E_EMAIL,
    taskAssistantReply: "The reviewed result is ready.",
    taskSchedule: null,
    taskStatus: "ready_for_review",
    workspaceChatDelayMs: WORKSPACE_CHAT_DELAY_MS,
  });
  recordElectronOnboardingCompleted(userDataDir, [stub.userId]);
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
    await sendHistoryProbe(appWindow);

    await appWindow.getByRole("link", { exact: true, name: "Tasks" }).click();
    const task = appWindow.getByTestId("tasks-route").getByRole("button", {
      name: chatSmokeTaskConversation.title,
    });
    await expect(task).toBeVisible({ timeout: 30_000 });
    await task.click();
    await expect(taskDoneButton(await openTaskDetails(appWindow))).toBeVisible({
      timeout: 15_000,
    });

    // Reconcile the Session in place — the same main-process path a renderer
    // 401/409 recovery takes (reportProductRejection -> bridge.reconcile).
    // acceptVerifiedCredential always bumps the generation.
    const bumpedGeneration = await appWindow.evaluate(async () => {
      const bridge = (
        window as unknown as {
          commaNative: {
            session: {
              reconcile: (
                input: unknown
              ) => Promise<{ ok: true; value: { generation: number } } | { ok: false }>;
              state: { get: () => Promise<Record<string, never>> };
            };
          };
        }
      ).commaNative;
      const lifecycle = (await bridge.session.state.get()) as unknown as {
        authority: { authorityInstanceId: string };
        generation: number;
        phase: string;
        session: { audience: string; sessionId: string };
      };
      if (lifecycle.phase !== "signed_in") {
        throw new Error(`unexpected session phase ${lifecycle.phase}`);
      }
      const result = await bridge.session.reconcile({
        expected: {
          authorityInstanceId: lifecycle.authority.authorityInstanceId,
          expectedAudience: lifecycle.session.audience,
          expectedSessionId: lifecycle.session.sessionId,
          generation: lifecycle.generation,
        },
        reason: "manual_retry",
      });
      if (!result.ok) {
        throw new Error(`reconcile failed: ${JSON.stringify(result)}`);
      }
      return result.value.generation;
    });
    expect(bumpedGeneration).toBeGreaterThan(1);

    // Let the provider remount land, then return to Home well inside the
    // stub delay: the remounted registry must still hold the target, so the
    // transcript is on screen before any re-resolution could answer.
    await appWindow.waitForTimeout(1_500);
    await expect(taskDoneButton(await openTaskDetails(appWindow))).toBeVisible();
    await expectHomeTranscriptCarried(appWindow);
  } finally {
    await app.close();
    await stub.close();
  }
});

// Regression coverage for the "Home is cold after a renderer reload on a
// non-Home route" bug: only HomeRoute resolved the Home conversation target,
// so after a ⌘R on /plugins nothing knew the Workspace conversation until the
// user next visited Home and waited out a full resolution there. The
// bootstrap now resolves the target from any product route.
test("the Home conversation target resolves after a renderer reload on a non-Home route", async ({
  browserName: _browserName,
}, testInfo) => {
  test.setTimeout(180_000);
  const stub = await startChatSmokeStub({
    sessionEmail: E2E_EMAIL,
    workspaceChatDelayMs: WORKSPACE_CHAT_DELAY_MS,
    workspaceChatFirstResolutionDelayMs: 0,
  });
  recordElectronOnboardingCompleted(userDataDir, [stub.userId]);
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
    await sendHistoryProbe(appWindow);

    const pluginsLink = appWindow.getByRole("link", { exact: true, name: "Plugins" });
    await pluginsLink.click();
    await expect(pluginsLink).toHaveAttribute("aria-current", "page");

    // The renderer reload drops every in-memory carry — this is the ⌘R repro.
    await appWindow.reload();
    await appWindow.waitForLoadState("domcontentloaded");

    // The hash route survives the reload: the app boots back onto Plugins.
    await expect(
      appWindow.getByRole("link", { exact: true, name: "Plugins" })
    ).toHaveAttribute("aria-current", "page", { timeout: 30_000 });

    // Without visiting Home, the bootstrap resolves the Workspace conversation
    // in the background; once it has had the stub delay to do so, Home opens
    // straight onto the transcript instead of resolving from scratch.
    await appWindow.waitForTimeout(BACKGROUND_RESOLUTION_SETTLE_MS);
    await expect(
      appWindow.getByRole("link", { exact: true, name: "Plugins" })
    ).toHaveAttribute("aria-current", "page");
    await expectHomeTranscriptCarried(appWindow);
  } finally {
    await app.close();
    await stub.close();
  }
});

// Multi-Workspace regression for the reload bootstrap: resolving the Home
// conversation target in the background must not activate the resolved
// (default) Workspace — doing so would rescope every active-Workspace
// subscriber (e.g. /tasks) away from the Workspace the user selected. The
// probe runs on a Task detail route because it is addressed by explicit route
// ids and does not reconcile the user's active Workspace. The only writer that
// could clobber the selected id after the reload is therefore the bootstrap
// itself.
test("reload bootstrap keeps the selected Workspace on a non-Home route", async ({
  browserName: _browserName,
}, testInfo) => {
  test.setTimeout(180_000);
  const stub = await startChatSmokeStub({
    additionalWorkspaces: [
      { group_id: "grp_selected", id: "wsp_selected", name: "Selected Workspace" },
    ],
    sessionEmail: E2E_EMAIL,
    workspaceChatDelayMs: WORKSPACE_CHAT_DELAY_MS,
    workspaceChatFirstResolutionDelayMs: 0,
  });
  recordElectronOnboardingCompleted(userDataDir, [stub.userId]);
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
    await sendHistoryProbe(appWindow);

    // Search is a palette over the current route now, not a location, so the
    // reload probe runs on a Task detail route: addressed by explicit ids, and
    // it does not reconcile the user's active Workspace.
    const taskPath = `/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`;
    await appWindow.evaluate((path) => {
      window.location.hash = `#${path}`;
    }, taskPath);
    await expect
      .poll(() => appWindow.evaluate(() => window.location.hash))
      .toBe(`#${taskPath}`);
    await expect(
      appWindow.getByRole("heading", {
        level: 1,
        name: chatSmokeTaskConversation.title,
      })
    ).toBeVisible({ timeout: 30_000 });

    // The user's Workspace selection, as another Workspace than the default
    // one the bootstrap will resolve.
    await appWindow.evaluate(() => {
      localStorage.setItem("comma.activeWorkspaceId", "wsp_selected");
    });

    await appWindow.reload();
    await appWindow.waitForLoadState("domcontentloaded");

    await expect
      .poll(() => appWindow.evaluate(() => window.location.hash))
      .toBe(`#${taskPath}`);
    await expect(
      appWindow.getByRole("heading", {
        level: 1,
        name: chatSmokeTaskConversation.title,
      })
    ).toBeVisible({ timeout: 30_000 });

    // The bootstrap has resolved the default Workspace's conversation by now
    // (the stub delay has passed)...
    await appWindow.waitForTimeout(BACKGROUND_RESOLUTION_SETTLE_MS);
    await expect(
      appWindow.getByRole("heading", {
        level: 1,
        name: chatSmokeTaskConversation.title,
      })
    ).toBeVisible();

    // ...and the selected Workspace stayed selected.
    expect(
      await appWindow.evaluate(() => localStorage.getItem("comma.activeWorkspaceId"))
    ).toBe("wsp_selected");

    // The background resolution did remember the target: Home opens straight
    // onto the transcript without resolving again.
    await expectHomeTranscriptCarried(appWindow);
  } finally {
    await app.close();
    await stub.close();
  }
});
