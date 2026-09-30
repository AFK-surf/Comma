import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

for (const width of [1280, 390]) {
  test(`sent plain URLs open through chat navigation at ${width}px`, async ({
    page,
  }, testInfo) => {
    await page.setViewportSize({ width, height: 844 });
    const text =
      "查看 https://example.com/docs?q=1&b=2。再看 http://example.org/path. `https://code.example`";
    const stub = await startChatSmokeStub({ assistantReply: "Acknowledged." });
    try {
      await installBrowserTestSession(page, {
        apiBaseUrl: stub.baseUrl,
        email: "links@comma.local",
        token: "comma_sess_text_links",
      });
      await page.goto("/");
      const content = page.getByRole("region", { name: "Content" });
      const composer = content.getByRole("textbox", { name: "AI prompt" });
      await composer.fill(text);
      await content.getByRole("button", { name: "Send", exact: true }).click();
      const bubble = content.locator('[data-slot="chat-user-output"]').last();
      const link = bubble.getByRole("link", {
        name: "https://example.com/docs?q=1&b=2",
        exact: true,
      });
      await expect(link).toHaveAttribute("href", "https://example.com/docs?q=1&b=2");
      await expect(bubble.getByRole("link")).toHaveCount(2);
      await expect(bubble).toContainText(text);
      await expect(content.locator('[data-message-id="msg-user-smoke"]')).toBeVisible();
      const selected = await bubble.evaluate((node) => {
        const range = document.createRange();
        range.selectNodeContents(node.querySelector(".comma-chat-user-bubble") ?? node);
        const selection = window.getSelection()!;
        selection.removeAllRanges();
        selection.addRange(range);
        const value = selection.toString();
        selection.removeAllRanges();
        return value;
      });
      expect(selected).toContain(text);
      await link.focus();
      await expect(link).toBeFocused();
      await page.keyboard.press("Enter");
      const browser = page.getByRole("tabpanel", { name: "Browser", exact: true });
      await expect(browser.getByRole("textbox", { name: "Address" })).toHaveValue(
        "https://example.com/docs?q=1&b=2"
      );
      await expect(
        browser.getByRole("link", { name: "Open in browser" })
      ).toHaveAttribute("href", "https://example.com/docs?q=1&b=2");
      await page.screenshot({
        path: testInfo.outputPath("text-links.png"),
        fullPage: true,
      });
      await page.reload();
      await expect(
        page.locator('[data-message-id="msg-user-smoke"]').getByRole("link")
      ).toHaveCount(2);
    } finally {
      await stub.close();
    }
  });
}
