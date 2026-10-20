import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { startChatSmokeStub } from "../../../e2e/p0/chat-stub";

// The canonical and Participant snapshots cross independent server owners.
// Only their publication is atomic; this fixture makes later HTTP chunks late
// so a DOM final-state assertion cannot miss the previous clear/replay flash.
test("reconnect keeps an observed reply visible through its first snapshot and later events", async ({
  page,
}, info) => {
  const first = "The paragraph already received stays visible.";
  const final = `${first} Generation continues after reconnect.`;
  const stub = await startChatSmokeStub({
    assistantDraft: first,
    assistantReply: final,
    streamAssistantReply: true,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "reconnect@comma.local",
      token: "comma_reconnect_presentation",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    await content
      .getByRole("textbox", { name: "AI prompt" })
      .fill("Continue after reconnect");
    await content.getByRole("button", { name: "Send", exact: true }).click();
    const draft = content.getByTestId("chat-assistant-draft");
    await expect(draft).toContainText(first);
    const probe = await draft.evaluateHandle((original) => {
      const root = original.closest('[data-testid="chat-current-turn"]')!;
      const counts = { samples: 0, missing: 0, detached: 0, duplicate: 0 };
      let raf = 0;
      const sample = () => {
        counts.samples++;
        const current = root.querySelector('[data-slot="chat-assistant-output"]');
        if (!current?.getClientRects().length) counts.missing++;
        if (!original.isConnected) counts.detached++;
        if (root.querySelectorAll('[data-slot="chat-assistant-output"]').length > 1)
          counts.duplicate++;
      };
      const observer = new MutationObserver(sample);
      observer.observe(root, { childList: true, subtree: true });
      const frame = () => {
        sample();
        raf = requestAnimationFrame(frame);
      };
      frame();
      return {
        stop: () => {
          sample();
          observer.disconnect();
          cancelAnimationFrame(raf);
          return counts;
        },
      };
    });
    stub.reconnectStreamingReply();
    await expect.poll(() => stub.streamingReconnectCount).toBe(1);
    // Includes the deliberately separate post-snapshot status/draft replay.
    await page.waitForTimeout(180);
    await expect(draft).toContainText(first);
    stub.updateStreamingDraft(final);
    await expect(draft).toContainText(final);
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText(final);
    const counts = await probe.evaluate(({ stop }) => stop());
    expect(counts.samples).toBeGreaterThan(5);
    expect(counts).toMatchObject({ missing: 0, detached: 0, duplicate: 0 });
    await info.attach("continuous-reconnect-observation", {
      body: JSON.stringify(counts),
      contentType: "application/json",
    });
    await probe.dispose();
  } finally {
    await stub.close();
  }
});
