import { expect, test, type Locator } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

test("channel activity follows live participant updates, reconnects, and failure", async ({
  page,
}, testInfo) => {
  const stub = await startChatSmokeStub({ externalActivityProvider: "wechat" });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-channel-activity@comma.local",
      token: "comma_sess_channel_activity",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    const slot = content.getByTestId("participant-status-slot");
    await expectCurrentActivitySummary(slot, "Comma’s working on WeChat");

    stub.publishStreamingParticipantStatus("is thinking...");
    await expectCurrentActivitySummary(slot, "Thinking");
    const thinkingFrame = await slot
      .locator(".comma-chat-thinking-bubble")
      .evaluate((element) => {
        const style = getComputedStyle(element);
        const tail = getComputedStyle(element, "::before");
        return {
          height: element.getBoundingClientRect().height,
          padding: style.padding,
          tail: tail.content,
          animation: tail.animationName,
        };
      });

    for (const [provider, name] of [
      ["wechat", "WeChat"],
      ["telegram", "Telegram"],
      ["signal", "Signal"],
    ] as const) {
      stub.publishStreamingParticipantStatus("is thinking...", provider);
      await expectCurrentActivitySummary(slot, `Comma’s working on ${name}`);
      const pill = slot.locator(`[data-working-provider="${provider}"]`);
      await expect(pill).toBeVisible();
      await expect(pill).toBeInViewport({ ratio: 1 });
      const viewport = content.locator(".comma-chat-scroll-viewport");
      const viewportBounds = await viewport.boundingBox();
      const pillBounds = await pill.boundingBox();
      expect(pillBounds!.y).toBeGreaterThanOrEqual(viewportBounds!.y + 16);
      await expect(pill.locator("img")).toHaveCount(2);
      expect(
        await pill.evaluate((element) => {
          const style = getComputedStyle(element);
          const tail = getComputedStyle(element, "::before");
          return {
            height: element.getBoundingClientRect().height,
            padding: style.padding,
            tail: tail.content,
            animation: tail.animationName,
          };
        })
      ).toEqual(thinkingFrame);
      await page.waitForTimeout(800);
      await page.screenshot({ path: testInfo.outputPath(`${provider}-page.png`) });
      await pill.screenshot({
        path: testInfo.outputPath(`${provider}.png`),
        animations: "disabled",
      });
    }

    await page.reload();
    await expectCurrentActivitySummary(slot, "Comma’s working on Signal");
    await page.emulateMedia({ reducedMotion: "reduce" });
    const text = slot.locator(
      '.comma-ai-activity-text-layer:not([aria-hidden="true"]) .comma-ai-activity-text-summary'
    );
    await expect(text).toHaveCSS("background-image", "none");

    stub.publishStreamingParticipantStatus("is thinking...");
    await expect(slot.locator("[data-working-provider]")).toHaveCount(0);
    stub.publishStreamingParticipantStatus("is thinking...", "wechat");
    await expectCurrentActivitySummary(slot, "Comma’s working on WeChat");
    stub.publishStreamingParticipantStatus("", undefined, "stopped");
    await expect(slot).toHaveAttribute("data-active", "false");
    stub.publishStreamingParticipantStatus("is thinking...", "telegram");
    await expectCurrentActivitySummary(slot, "Comma’s working on Telegram");
    stub.publishStreamingParticipantStatus(
      "error: runtime failed",
      undefined,
      "error",
      "runtime_failed"
    );
    await expectCurrentActivitySummary(
      slot,
      "Stopped because of an error. Try sending again."
    );
    await expect(slot).not.toContainText("runtime failed");
    await expect(slot.locator("[data-working-provider]")).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

/**
 * A model request that dies before committing an assistant message used to be
 * invisible: the canonical Participant status settles to the same `stopped` an
 * ordinary finished turn reports, so the transcript-tail slot collapsed and the
 * send was indistinguishable from one the assistant simply chose not to answer.
 *
 * These cover the whole client path — SSE frame, channel, transcript-tail slot —
 * rather than the component in isolation.
 */
test("a failed turn reports the model connection error at the transcript tail", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ streamAssistantReply: true });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-failed-turn@comma.local",
      token: "comma_sess_failed_turn",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const prompt = content.getByRole("textbox", { name: "AI prompt" });
    await prompt.fill("刚才3点的那个会议的会议记录发一下，我看看");
    await content.getByRole("button", { name: "Send" }).click();
    await stub.waitForDraft();

    const participantStatus = content.getByTestId("participant-status-slot");
    await expect(participantStatus).toHaveAttribute("data-state", "active");

    stub.failStreamingReply();

    // Localized copy selected from the reason code, not the runtime's own
    // English `status` text, which stays out of the product surface.
    await expect(participantStatus).toHaveAttribute("data-state", "error");
    await expect(participantStatus).toHaveAttribute("data-active", "true");
    await expectCurrentActivitySummary(
      participantStatus,
      "Could not connect to the model. Try sending again."
    );
    await expect(participantStatus).not.toContainText("the model could not be reached");
  } finally {
    await stub.close();
  }
});

test("a failed turn's error survives a reload", async ({ page }) => {
  const stub = await startChatSmokeStub({ streamAssistantReply: true });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-failed-turn-reload@comma.local",
      token: "comma_sess_failed_turn_reload",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    await content.getByRole("textbox", { name: "AI prompt" }).fill("人呢");
    await content.getByRole("button", { name: "Send" }).click();
    await stub.waitForDraft();
    stub.failStreamingReply();

    const participantStatus = content.getByTestId("participant-status-slot");
    await expect(participantStatus).toHaveAttribute("data-state", "error");

    // The in-memory failure frame does not survive a reconnect — the runtime's
    // activity surface drops the session on the terminal idle. The durable
    // Participant status is what has to bring the line back.
    await page.reload();

    const reloaded = page
      .getByRole("region", { name: "Content" })
      .getByTestId("participant-status-slot");
    await expect(reloaded).toHaveAttribute("data-state", "error");
    await expectCurrentActivitySummary(
      reloaded,
      "Could not connect to the model. Try sending again."
    );
  } finally {
    await stub.close();
  }
});

test("a canonical non-model failure wins over a public tool failure frame", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({ streamAssistantReply: true });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "comma-non-model-failed-turn@comma.local",
      token: "comma_sess_non_model_failed_turn",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    await content.getByRole("textbox", { name: "AI prompt" }).fill("运行一下命令");
    await content.getByRole("button", { name: "Send" }).click();
    await stub.waitForDraft();

    stub.failStreamingReply({
      activity: "public-tool",
      issue: "visible_reply_repair_exhausted",
      status: "error: the session could not produce a visible reply",
    });

    const participantStatus = content.getByTestId("participant-status-slot");
    await expect(participantStatus).toHaveAttribute("data-state", "error");
    await expectCurrentActivitySummary(
      participantStatus,
      "Couldn’t finish the reply. Try sending again."
    );
    await expect(participantStatus).not.toContainText("visible reply");
    await expect(participantStatus).not.toContainText(
      "Could not connect to the model. Try sending again."
    );
    await expect(participantStatus).not.toContainText("The command failed");
  } finally {
    await stub.close();
  }
});

async function expectCurrentActivitySummary(slot: Locator, text: string) {
  const layer = slot.locator('.comma-ai-activity-text-layer:not([aria-hidden="true"])');
  await expect(layer).toHaveAttribute("data-motion", "rest");
  await expect(layer.locator(".comma-ai-activity-text-summary")).toHaveText(text);
}
