import { expect, test } from "@playwright/test";
import type { ServerResponse } from "node:http";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeWorkspaceChat, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

test("Session history is opt-in, releases open views when disabled and remembers the Debug setting", async ({
  page,
}) => {
  const historyRequests: URL[] = [];
  const streams = new Set<ServerResponse>();
  let streamRequests = 0;
  const originalInput = `<system-reminder>${"IM provider context ".repeat(40)}</system-reminder>\nTelegram message from user in chat:\nSession debug record 我今天的天气如何`;
  const stub = await startChatSmokeStub({
    sessionEmail: "history-debug@comma.local",
    sessionHistory(url) {
      historyRequests.push(url);
      return {
        body: {
          conversation_id: chatSmokeWorkspaceChat.id,
          participant_id: "ptp-router-smoke",
          records: [
            {
              id: "1",
              kind: "user",
              timestamp_ms: Date.now(),
              content: { content: originalInput },
              input_text: "Session debug record 我今天的天气如何",
              input_source: {
                provider: "telegram",
                actor_type: "user",
                chat_type: "private",
              },
            },
            {
              id: "2",
              kind: "user",
              content: { content: '{"input_source":{"provider":"telegram"}}' },
            },
            {
              id: "3",
              kind: "tool",
              content: {
                tool_name: "location.request",
                status: "completed",
                content: JSON.stringify({
                  status: "question_delivered",
                  request_id: "request-1",
                }),
                duration_ms: 200,
              },
            },
          ],
          has_more: false,
          next_before: null,
        },
      };
    },
    sessionHistoryEvents(_url, response) {
      streamRequests++;
      streams.add(response);
      response.on("close", () => streams.delete(response));
    },
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "history-debug@comma.local",
      token: "comma_sess_history_debug",
    });
    await page.goto("/");
    const participant = page.getByTestId("session-history-participant");
    const preview = page.getByTestId("session-history-preview");
    const history = page.getByTestId("session-history-page");
    const toggle = page.getByRole("switch", {
      name: "Show Session history",
      exact: true,
    });
    const toggleControl = page.locator(
      '[data-setting-id="debug.session-history.enabled"] [data-slot="settings-control"] .cursor-pointer'
    );
    const savedEnabled = () =>
      page.evaluate(
        () =>
          JSON.parse(localStorage.getItem("comma.client-settings") ?? "{}")
            .sessionHistoryEnabled
      );
    await expect(page.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
    await expect(participant).toHaveCount(0);
    await expect(history).toHaveCount(0);
    // Let retained-view effects run: a hidden feature must not request history.
    await page.waitForTimeout(250);
    expect(historyRequests).toHaveLength(0);
    expect(streamRequests).toBe(0);

    await page.evaluate(() => {
      location.hash = "#/settings?category=debug";
    });
    await expect(toggle).not.toBeChecked();
    await toggleControl.click();
    await expect(toggle).toBeChecked();
    await expect.poll(savedEnabled).toBe(true);
    await page.getByRole("button", { name: "Close settings", exact: true }).click();
    await expect(participant).toBeVisible();
    await participant.hover();
    await expect(preview).toContainText("Session debug record");
    await expect(preview).toContainText("我今天的天气如何");
    await expect(preview).toContainText("Telegram · Private chat");
    await expect(preview).not.toContainText("IM provider context");
    await participant.click();
    await expect(history).toContainText("Session debug record");
    await expect(history).toContainText("我今天的天气如何");
    await expect(history).toContainText("Telegram · Private chat");
    await expect(history).not.toContainText("IM provider context");
    await expect(history.locator('[data-record-id="2"]')).toContainText(
      "Source not recorded"
    );
    await expect(history).toContainText(
      "Location request sent; reply arrives separately"
    );
    await history.screenshot({
      path: test.info().outputPath("telegram-input-summary.png"),
    });
    const inputRow = history.locator('[data-record-id="1"]');
    await inputRow.locator(":scope > details > summary").click();
    const tree = inputRow.getByTestId("session-json");
    await expect(tree).toBeVisible();
    const nodes = tree.locator("details");
    for (;;) {
      const index = await nodes.evaluateAll((elements) =>
        elements.findIndex((element) => !element.hasAttribute("open"))
      );
      if (index === -1) break;
      const node = nodes.nth(index);
      await node.locator(":scope > summary").click();
      await expect(node.locator(":scope > .comma-session-json-children")).toBeVisible();
    }
    expect(JSON.parse((await tree.textContent())!).content.content).toBe(originalInput);
    await inputRow.locator(":scope > details > summary").click();
    await expect.poll(() => streams.size).toBe(1);

    await page.getByRole("textbox", { name: "AI prompt" }).click();
    await participant.hover();
    await expect(preview).toBeVisible();
    await page.evaluate(() => {
      location.hash = "#/settings?category=debug";
    });
    await expect(toggle).toBeChecked();
    // The Settings modal retains the already open Session until the switch changes.
    await expect(history).toHaveCount(1);
    expect(streams.size).toBe(1);
    await toggleControl.click();
    await expect(toggle).not.toBeChecked();
    await expect.poll(savedEnabled).toBe(false);
    await expect(participant).toHaveCount(0);
    await expect(preview).toHaveCount(0);
    await expect(history).toHaveCount(0);
    await expect.poll(() => streams.size).toBe(0);
    await page.getByRole("button", { name: "Close settings", exact: true }).click();

    const readsBeforeReload = historyRequests.length;
    const streamsBeforeReload = streamRequests;
    await page.reload();
    await expect(page.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
    await expect(participant).toHaveCount(0);
    await expect(history).toHaveCount(0);
    await page.waitForTimeout(250);
    expect(historyRequests).toHaveLength(readsBeforeReload);
    expect(streamRequests).toBe(streamsBeforeReload);

    await page.evaluate(() => {
      location.hash = "#/settings?category=debug";
    });
    await expect(toggle).not.toBeChecked();
    await toggleControl.click();
    await expect(toggle).toBeChecked();
    await expect.poll(savedEnabled).toBe(true);
    await page.getByRole("button", { name: "Close settings", exact: true }).click();
    await page.reload();
    await expect(participant).toBeVisible();
    await page.getByRole("textbox", { name: "AI prompt" }).click();
    await participant.hover();
    await expect(preview).toContainText("Session debug record");
    await participant.click();
    await expect(history).toContainText("Session debug record");
    await expect.poll(() => streams.size).toBe(1);
  } finally {
    await stub.close();
  }
});
