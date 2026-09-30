import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

test("remote browser paints frames and admits mouse and keyboard only after takeover", async ({
  page,
}, testInfo) => {
  const stub = await startChatSmokeStub({ taskStatus: "active" });
  const participantId = "ptc_browser_worker";
  stub.setTaskParticipants([], {
    participant_id: participantId,
    actor_id: "agent-browser-e2e",
    name: "Browser worker",
  });
  let active = false;
  let scopedReads = 0;
  const inputs: Record<string, unknown>[] = [];
  let control = "agent";
  let revision = 0;
  let streams = 0;
  let cleared = false;
  let storageError: string | null = null;
  const binding = () => ({
    agent_id: "agent-browser-e2e",
    session_id: "browser-e2e",
    status: "ready",
    control,
    busy: false,
    storage_error: storageError,
    updated_at: new Date(1780000000000 + revision).toISOString(),
  });
  const data = await page.evaluate(() => {
    const surface = document.createElement("canvas");
    surface.width = 16;
    surface.height = 9;
    const context = surface.getContext("2d")!;
    context.fillStyle = "red";
    context.fillRect(0, 0, 16, 9);
    return surface.toDataURL("image/jpeg").split(",")[1];
  });
  await page.route("**/v1/comma/workspaces/*/browsers**", async (route) => {
    const request = route.request();
    const headers = {
      "access-control-allow-origin":
        request.headers().origin ?? "http://127.0.0.1:4173",
      "access-control-allow-credentials": "true",
      "access-control-allow-headers":
        "authorization,content-type,x-comma-session-transport",
      "access-control-allow-methods": "GET,POST,OPTIONS",
    };
    if (request.method() === "OPTIONS") return route.fulfill({ status: 204, headers });
    if (request.url().includes("/events?")) {
      streams++;
      return route.fulfill({
        headers,
        contentType: "text/event-stream",
        body: `data: ${JSON.stringify({ browser: binding(), can_control: control === "human", frame: { data, tab_id: "tab", metadata: { deviceWidth: 1280, deviceHeight: 720 } } })}\n\n`,
      });
    }
    const url = new URL(request.url());
    const matchesSession =
      url.searchParams.get("conversation_id") === chatSmokeTaskConversation.id &&
      url.searchParams.get("participant_id") === participantId;
    if (request.method() === "GET" && matchesSession) scopedReads++;
    let body: unknown = {
      browsers: matchesSession
        ? active
          ? [binding()]
          : []
        : [
            {
              ...binding(),
              agent_id: "another-agent",
              session_id: "another-session",
            },
          ],
    };
    if (request.method() === "POST" && url.pathname.endsWith("/clear-storage")) {
      cleared = true;
      return route.fulfill({
        headers,
        contentType: "application/json",
        body: JSON.stringify({ cleared: true }),
      });
    }
    if (request.method() === "POST") {
      const command = request.postDataJSON();
      if (command.operation === "take_control") {
        control = "human";
        revision++;
      }
      if (command.operation === "return_control") {
        storageError = "browser_storage_partially_saved";
        control = "agent";
        revision++;
      }
      if (command.operation === "input") inputs.push(command.args.input);
      if (command.operation === "close" || command.operation === "clear_storage")
        active = false;
      if (command.operation === "clear_storage") cleared = true;
      body = {
        ...binding(),
        status: active ? "ready" : "closed",
        tabs: [
          { tab_id: "tab", title: "Remote test page", url: "https://example.com" },
        ],
      };
    }
    await route.fulfill({
      headers,
      contentType: "application/json",
      body: JSON.stringify(body),
    });
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "browser-e2e@comma.local",
      token: "comma_sess_browser_e2e",
    });
    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const browserButton = page
      .locator("header")
      .getByRole("button", { name: "Browser", exact: true });
    await expect.poll(() => scopedReads).toBeGreaterThan(0);
    await expect(
      page.getByRole("button", { name: "Browser", exact: true })
    ).toHaveCount(0);
    active = true;
    await expect(browserButton).toBeVisible({ timeout: 15_000 });
    await expect(browserButton).toHaveAttribute("aria-expanded", "false");
    await page.screenshot({ path: testInfo.outputPath("browser-header.png") });
    await browserButton.click();
    await expect(browserButton).toHaveAttribute("aria-expanded", "true");
    const panel = page.getByRole("region", { name: "Agent browser" });
    await expect(
      panel.getByText("Logins and website storage are shared", { exact: false })
    ).toBeVisible();
    const canvas = panel.locator("canvas");
    await expect
      .poll(() => canvas.evaluate((node: HTMLCanvasElement) => node.width))
      .toBe(16);
    await canvas.click({ position: { x: 30, y: 20 } });
    expect(inputs).toHaveLength(0);
    await panel.getByRole("button", { name: "Take control", exact: true }).click();
    await expect(panel.getByRole("button", { name: "Return to agent" })).toBeVisible();
    await canvas.click({ position: { x: 30, y: 20 } });
    await canvas.press("Tab");
    await panel
      .getByRole("textbox", { name: "Text to type in the browser" })
      .fill("中文輸入");
    await panel.getByRole("button", { name: "Send text" }).click();
    await expect
      .poll(() => inputs.some((input) => input.type === "mousePressed"))
      .toBe(true);
    await expect
      .poll(() =>
        inputs.some((input) => input.type === "keyDown" && input.key === "Tab")
      )
      .toBe(true);
    await expect
      .poll(() =>
        inputs.some((input) => input.type === "text" && input.text === "中文輸入")
      )
      .toBe(true);
    await panel.getByRole("button", { name: "Return to agent" }).click();
    await expect(panel.getByRole("textbox")).toBeDisabled();
    await expect(panel.getByRole("alert")).toHaveText(
      "Some browser changes were saved. Recent changes on other sites may be missing after recovery."
    );
    await browserButton.click();
    await expect(browserButton).toHaveAttribute("aria-expanded", "false");
    await expect(panel).not.toBeVisible();
    const stopped = streams;
    await page.waitForTimeout(500);
    expect(streams).toBe(stopped);
    await browserButton.click();
    await panel.getByRole("button", { name: "Close browser", exact: true }).click();
    await expect(browserButton).toHaveCount(0);
    await expect(panel).not.toBeVisible();
    active = true;
    await expect(browserButton).toBeVisible({ timeout: 15_000 });
    await browserButton.click();
    await panel.getByRole("button", { name: "Clear shared logins…" }).click();
    const confirmation = panel.getByRole("group", {
      name: "Clear shared browser data",
    });
    await expect(confirmation).toBeVisible();
    expect(cleared).toBe(false);
    await confirmation.getByRole("button", { name: "Cancel", exact: true }).click();
    expect(cleared).toBe(false);
    await panel.getByRole("button", { name: "Clear shared logins…" }).click();
    await confirmation.getByRole("button", { name: "Clear and close" }).click();
    await expect.poll(() => cleared).toBe(true);
    await expect(browserButton).toHaveCount(0);
    cleared = false;
    await page.goto("/#/settings?category=browser");
    await expect(
      page.locator('[data-slot="settings-sidebar-item"][aria-current="page"]')
    ).toHaveText("Browser");
    await page.getByRole("button", { name: "Clear shared logins…" }).click();
    const clearDialog = page.getByRole("dialog", {
      name: "Clear shared logins",
      exact: true,
    });
    await expect(clearDialog).toBeVisible();
    await clearDialog.getByRole("button", { name: "Cancel", exact: true }).click();
    expect(cleared).toBe(false);
    await page.getByRole("button", { name: "Clear shared logins…" }).click();
    await clearDialog
      .getByRole("button", { name: "Clear shared logins", exact: true })
      .click();
    await expect.poll(() => cleared).toBe(true);
    await expect(page.getByText("Saved browser logins cleared.")).toBeVisible();
  } finally {
    await stub.close();
  }
});
