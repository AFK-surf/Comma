import { expect, test, type Locator } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

async function expectWechatMark(chip: Locator) {
  await expect(chip).toHaveText("WeChat");
  const mark = chip.locator("svg.comma-task-origin-wechat");
  await expect(mark).toBeVisible();
  await expect(mark).toHaveCSS("color", "rgb(7, 193, 96)");
  // Central's brand glyph is fill-only: inherited outline styling must not
  // turn it into a hollow or invisible mark in the real application's CSS.
  const path = mark.locator("path").first();
  await expect(path).toHaveCSS("fill", "rgb(7, 193, 96)");
  await expect(path).toHaveCSS("stroke", "none");
  expect(await path.getAttribute("d")).toBeTruthy();
}

test("WeChat task chips render the brand mark and retain platform navigation", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskConversationExtras: { origin: "wechat" },
    taskSchedule: null,
    taskStatus: "active",
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "wechat-origin@comma.local",
      token: "comma_sess_wechat_origin",
    });
    await page.goto("/#/tasks");
    const chip = page
      .locator('[data-slot="task-card"]')
      .first()
      .getByTestId("task-card-platform");
    await expectWechatMark(chip);
    await chip.click();
    await expect(page).toHaveURL(/platform=wechat/);
    await expectWechatMark(chip);

    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const panelOrigin = page.getByTestId("task-panel-origin");
    await expectWechatMark(panelOrigin);
    await panelOrigin.click();
    await expect(page).toHaveURL(/platform=wechat/);
    await expectWechatMark(chip);
  } finally {
    await stub.close();
  }
});
