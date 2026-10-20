import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

test("replying to a message gathers its thread and sends into it", async ({
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 1280, height: 844 });
  const stub = await startChatSmokeStub({
    assistantReply: "Here is the launch email draft.",
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "reply@comma.local",
      token: "comma_sess_reply_thread",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    const composer = content.getByRole("textbox", { name: "AI prompt" });
    await composer.fill("Draft the launch email");
    await content.getByRole("button", { name: "Send", exact: true }).click();
    const answer = content.locator('[data-message-id="msg-assistant-smoke"]').first();
    await expect(answer).toContainText("Here is the launch email draft.");

    await answer
      .getByText("Here is the launch email draft.")
      .click({ button: "right" });
    await page.getByRole("menuitem", { name: "Reply" }).click();

    const thread = content.getByRole("region", { name: "Reply thread" });
    await expect(thread).toBeVisible();
    await expect(thread).toContainText("Draft the launch email");
    await expect(thread).toContainText("Here is the launch email draft.");
    await expect(composer).toBeFocused();
    // Let the thread finish gathering before the visual record.
    await thread.evaluate((element) =>
      Promise.all(
        element.getAnimations({ subtree: true }).map((animation) => animation.finished)
      )
    );
    await page.screenshot({ path: testInfo.outputPath("reply-thread-open.png") });

    // Once Home has a conversation its starter Send gives way to the regular one.
    await composer.fill("Make it shorter");
    const replySent = page.waitForRequest(
      (request) =>
        request.method() === "POST" &&
        new URL(request.url()).pathname.endsWith("/messages") &&
        request.postData()?.includes('"Make it shorter"') === true
    );
    await content.getByRole("button", { name: "Send message", exact: true }).click();
    const reply = (await replySent).postDataJSON() as { reply_to_message_id?: string };
    expect(reply.reply_to_message_id).toBe("msg-assistant-smoke");
    await expect(thread).toBeVisible();

    // A click on the dimmed space above the gathered thread closes it.
    await thread.click({ position: { x: 40, y: 40 } });
    await expect(thread).toHaveCount(0);
  } finally {
    await stub.close();
  }
});
