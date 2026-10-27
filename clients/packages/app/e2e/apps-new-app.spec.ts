import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspace, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// New app on the Apps page goes to Home with the start of a build request in the composer and the caret after it,
// so the viewer types the rest. Nothing is sent.
test("New app leaves a build request in Home's composer, ready to finish", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    extraRoutes: async (_req, url, res) => {
      if (url.pathname !== `/v1/comma/workspaces/${chatSmokeWorkspace.id}/apps`)
        return false;
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ data: [] }));
      return true;
    },
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "apps@comma.local",
      token: "comma_sess_apps",
    });
    await page.goto("/#/apps");
    await page.getByRole("button", { name: "New app" }).first().click();
    const editor = page.locator('.comma-chat-composer-frame [contenteditable="true"]');
    await expect(editor).toBeFocused();
    await expect(editor).toHaveText("Build a Comma app that");
    await page.keyboard.type("tracks water");
    await expect(editor).toHaveText("Build a Comma app that tracks water");
  } finally {
    await stub.close();
  }
});
