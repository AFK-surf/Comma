import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

test.use({ locale: "en-US", viewport: { width: 1280, height: 900 } });

const text = (value: string) => [{ type: "text" as const, text: value }];
const wechatReplyRelationship = {
  reply_to_message_id: "wechat-user",
  thread_root_message_id: "wechat-user",
};

test("Home retains platform colors, hover source icons, and reply relationships across reload", async ({
  page,
}, info) => {
  const stub = await startChatSmokeStub({
    workspaceTranscript: [
      {
        message_id: "comma-user",
        actor_type: "user",
        kind: "message",
        created_at: 1_720_000_000,
        content: text("Keep my conversations together."),
      },
      {
        message_id: "wechat-user",
        actor_type: "system",
        kind: "message",
        created_at: 1_720_000_001,
        content: text("PRIVATE_PROVIDER_PROMPT"),
        agent_input: { role: "user", content: "PRIVATE_PROVIDER_PROMPT" },
        platform_message: {
          provider: "wechat",
          role: "user",
          content: text("今晚的餐厅订好了吗？"),
        },
      },
      {
        message_id: "wechat-reply",
        actor_type: "system",
        kind: "app_event",
        created_at: 1_720_000_002,
        ...wechatReplyRelationship,
        content: [],
        metadata: { event_type: "provider.message" },
        platform_message: {
          provider: "wechat",
          role: "assistant",
          content: text("订好了，今晚七点，两位。"),
        },
      },
      {
        message_id: "telegram-user",
        actor_type: "system",
        kind: "message",
        created_at: 1_720_000_003,
        content: text("PRIVATE_PROVIDER_PROMPT"),
        agent_input: { role: "user", content: "PRIVATE_PROVIDER_PROMPT" },
        platform_message: {
          provider: "telegram",
          role: "user",
          content: text("Send me the meeting notes."),
        },
      },
      {
        message_id: "telegram-reply",
        actor_type: "system",
        kind: "app_event",
        created_at: 1_720_000_004,
        content: [],
        metadata: { event_type: "provider.message" },
        platform_message: {
          provider: "telegram",
          role: "assistant",
          content: text("The notes are ready to review."),
        },
      },
      {
        message_id: "internal-status",
        actor_type: "system",
        kind: "app_event",
        created_at: 1_720_000_005,
        content: text("PRIVATE_DELIVERY_STATUS"),
        metadata: { event_type: "provider.status" },
      },
    ],
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "platform-chat@comma.local",
      token: "comma_platform_chat",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    const assertMessages = async () => {
      for (const [id, body, platform, color] of [
        ["wechat-user", "今晚的餐厅订好了吗？", "WeChat", "rgb(157, 242, 159)"],
        ["wechat-reply", "订好了，今晚七点，两位。", null, null],
        [
          "telegram-user",
          "Send me the meeting notes.",
          "Telegram",
          "rgb(184, 234, 247)",
        ],
        ["telegram-reply", "The notes are ready to review.", null, null],
      ]) {
        const message = content.locator(`article[data-message-id="${id}"]`);
        await expect(message).toHaveCount(1);
        await expect(message).toContainText(body!);
        if (platform) {
          const bubble = message.locator(".comma-chat-user-bubble");
          const actions = message.getByTestId(`chat-message-actions-${id}`);
          const badge = actions.getByTitle(platform, { exact: true });
          const copy = actions.getByRole("button", { name: "Copy message" });
          await expect
            .poll(() =>
              bubble.evaluate((element) => {
                const background = getComputedStyle(element).backgroundColor;
                return background === "rgba(0, 0, 0, 0)"
                  ? getComputedStyle(element, "::before").backgroundColor
                  : background;
              })
            )
            .toBe(color!);
          await expect(bubble).not.toHaveCSS("color", "rgb(255, 255, 255)");
          await page.mouse.move(0, 0);
          await expect(actions).toHaveCSS("opacity", "0");
          await bubble.hover();
          await expect(actions).toHaveCSS("opacity", "1");
          await expect(badge).toBeVisible();
          const iconBounds = (await badge.boundingBox())!;
          const copyBounds = (await copy.boundingBox())!;
          const bubbleBounds = (await bubble.boundingBox())!;
          expect(iconBounds.x).toBeGreaterThanOrEqual(0);
          expect(iconBounds.x + iconBounds.width).toBeLessThanOrEqual(copyBounds.x);
          expect(copyBounds.x + copyBounds.width).toBeLessThanOrEqual(bubbleBounds.x);
          expect(bubbleBounds.x + bubbleBounds.width).toBeLessThanOrEqual(
            page.viewportSize()!.width
          );
        } else {
          await expect(message.locator("[data-platform]")).toHaveCount(0);
        }
      }
      await expect(
        content.locator('[data-message-id="comma-user"] [data-platform]')
      ).toHaveCount(0);
      await expect(
        content.locator('article[data-message-id="wechat-reply"]')
      ).toHaveAttribute("data-reply-to-message-id", "wechat-user");
      const replyLine = content.locator('path[data-reply-source="wechat-reply"]');
      await expect(replyLine).toHaveAttribute("data-reply-target", "wechat-user");
      await expect(replyLine).toBeVisible();
      await expect(content).not.toContainText("PRIVATE_PROVIDER_PROMPT");
      await expect(content).not.toContainText("PRIVATE_DELIVERY_STATUS");
    };
    await assertMessages();
    await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
    await content
      .locator('[data-message-id="wechat-user"]')
      .getByRole("button", { name: "Copy message" })
      .click();
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(
      "今晚的餐厅订好了吗？"
    );
    await content
      .locator('[data-message-id="wechat-user"] .comma-chat-user-bubble')
      .hover();
    await page.screenshot({
      path: info.outputPath("home-platform-messages-light.png"),
    });
    await page.reload();
    await assertMessages();
    await page
      .locator(".comma-sidebar-body")
      .getByRole("button", { name: "Settings", exact: true })
      .click();
    await page.getByRole("button", { name: "Appearance", exact: true }).click();
    await page.getByRole("button", { name: /Select theme/ }).click();
    await page.getByRole("option", { name: "Dark", exact: true }).click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "Dark mode");
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog", { name: "Settings sections" })).toBeHidden();
    await assertMessages();
    await page.screenshot({ path: info.outputPath("home-platform-messages-dark.png") });
    await page.setViewportSize({ width: 390, height: 844 });
    await assertMessages();
    await page.screenshot({
      path: info.outputPath("home-platform-messages-narrow.png"),
    });
  } finally {
    await stub.close();
  }
});
