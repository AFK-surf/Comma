import { expect, test } from "@playwright/test";
import { installSharedWorkerClock } from "../../../e2e/helpers/shared-worker-clock";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import { chatSmokeAssistantReply, startChatSmokeStub } from "../../../e2e/p0/chat-stub";

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

test("a previous request's canonical append cannot retire the current live draft", async ({
  page,
}, info) => {
  const first = "The second response is still streaming.";
  const final = `${first} Its later words remain visible.`;
  const stub = await startChatSmokeStub({
    priorUserMessage: "An earlier request whose canonical response is delayed.",
    assistantDraft: first,
    assistantReply: final,
    streamAssistantReply: true,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "independent-draft@comma.local",
      token: "comma_independent_draft",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    await content
      .getByRole("textbox", { name: "AI prompt" })
      .fill("Send a second request.");
    await content.getByRole("button", { name: /^Send(?: message)?$/ }).click();
    const draft = content.getByTestId("chat-assistant-draft");
    await expect(draft).toContainText(first);
    const original = await draft.elementHandle();
    // These are two independent owner facts. A new Message does not identify
    // which response produced it and cannot retire an unrelated live draft.
    stub.appendPriorAssistantReply("The earlier canonical answer arrives now.");
    await expect.poll(() => stub.streamingReconnectCount).toBe(1);
    await expect(content).toContainText("The earlier canonical answer arrives now.");
    await expect(draft).toContainText(first);
    expect(await draft.evaluate((node, before) => node === before, original)).toBe(
      true
    );
    stub.updateStreamingDraft(final);
    await expect(draft).toContainText(final);
    await expect(content.locator('[data-slot="chat-assistant-output"]')).toHaveCount(2);
    await page.screenshot({
      path: info.outputPath("independent-canonical-and-live-draft.png"),
    });
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText(final);
    await expect(draft).toHaveCount(0);
    await expect(content.locator('[data-slot="chat-assistant-output"]')).toHaveCount(2);
  } finally {
    await stub.close();
  }
});

test("a temporarily unavailable Participant cannot permanently retire a continuing reply", async ({
  page,
}) => {
  const first = "This response is still being generated.";
  const stub = await startChatSmokeStub({
    assistantDraft: first,
    assistantReply: `${first} Finished.`,
    streamAssistantReply: true,
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "owner-return@comma.local",
      token: "comma_owner_return",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    await content
      .getByRole("textbox", { name: "AI prompt" })
      .fill("Continue this reply");
    await content.getByRole("button", { name: "Send", exact: true }).click();
    await expect(content.getByTestId("chat-assistant-draft")).toContainText(first);
    stub.setParticipantSnapshotAvailable(false);
    stub.reconnectStreamingReply();
    await expect.poll(() => stub.streamingReconnectCount).toBe(1);
    await expect(content.getByTestId("chat-assistant-draft")).toHaveCount(0);
    await expect(content.locator('[data-message-id="msg-user-smoke"]')).toBeVisible();
    stub.setParticipantSnapshotAvailable(true);
    stub.reconnectStreamingReply();
    await expect.poll(() => stub.streamingReconnectCount).toBe(2);
    await expect(content.getByTestId("chat-assistant-draft")).toContainText(first);
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText("Finished.");
  } finally {
    await stub.close();
  }
});

test("an acknowledged silent reply becomes a static wait and yields to later progress", async ({
  page,
}, info) => {
  // The deadline belongs to the SharedWorker, not page.clock.
  const first = "The delayed reply has arrived.";
  const stub = await startChatSmokeStub({
    assistantDraft: first,
    assistantReply: `${first} Complete.`,
    holdStreamingReplyStart: true,
    streamAssistantReply: true,
  });
  let clock: Awaited<ReturnType<typeof installSharedWorkerClock>> | undefined;
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "silent-reply@comma.local",
      token: "comma_silent_reply",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    await content
      .getByRole("textbox", { name: "AI prompt" })
      .fill("Please send a reply.");
    clock = await installSharedWorkerClock(page);
    await content.getByRole("button", { name: "Send", exact: true }).click();
    const slot = content.getByTestId("participant-status-slot");
    await expect(slot).toHaveAttribute("data-state", "active", { timeout: 500 });
    await stub.waitForStreamingReplyReady();
    await clock.advance(149_999);
    await expect(slot).toHaveAttribute("data-state", "active");
    await clock.advance(1);
    await expect(slot).toHaveAttribute("data-state", "waiting");
    await expect(slot).toContainText("Message sent. No reply received yet.");
    await expect(slot.locator('[data-slot="ai-activity"]')).toHaveAttribute(
      "aria-busy",
      "false"
    );
    await expect(slot.locator(".comma-chat-activity-avatar")).toHaveCount(0);
    await expect(
      content.getByRole("button", { name: "Retry", exact: true })
    ).toHaveCount(0);
    await expect(content.getByRole("alert")).toHaveCount(0);
    await page.screenshot({ path: info.outputPath("static-wait.png") });
    stub.startStreamingReply();
    await expect(content.getByTestId("chat-assistant-draft")).toContainText(first);
    await expect(slot).not.toHaveAttribute("data-state", "waiting");
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText("Complete.");
    await expect(slot).toBeHidden();
  } finally {
    try {
      await clock?.dispose();
    } finally {
      await stub.close();
    }
  }
});

test("a brief connection loss reconnects without the stale-sync toast", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    holdCompletedWorkspaceChatEventStream: true,
  });
  let clock: Awaited<ReturnType<typeof installSharedWorkerClock>> | undefined;
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "lid-wake@comma.local",
      token: "comma_lid_wake",
    });
    await page.goto("/");
    const content = page.getByRole("region", { name: "Content" });
    await content.getByRole("textbox", { name: "AI prompt" }).fill("Before sleep");
    await content.getByRole("button", { name: "Send", exact: true }).click();
    await expect(content.getByText(chatSmokeAssistantReply)).toBeVisible();
    // Backoff timers belong to the SharedWorker channel, not page.clock.
    clock = await installSharedWorkerClock(page);
    await expect.poll(() => stub.activeCompletedWorkspaceChatEventStreams).toBe(1);
    const warning = page.getByTestId("chat-sync-warning");

    // Waking from sleep drops the stream; the retries fail until Wi-Fi rejoins.
    // Chromium may resend a reset request, so count drops only as progress.
    const dropsAfter = async (previous: number) => {
      await expect
        .poll(() => stub.droppedWorkspaceChatEventStreamCount)
        .toBeGreaterThan(previous);
      return stub.droppedWorkspaceChatEventStreamCount;
    };
    stub.setWorkspaceChatEventsUnreachable(true);
    let drops = await dropsAfter(0);
    for (const backoffMs of [1_000, 2_000]) {
      await expect(warning).toHaveCount(0);
      await clock.advance(backoffMs + 250);
      drops = await dropsAfter(drops);
    }
    await page.waitForTimeout(200);
    await expect(warning).toHaveCount(0);

    // A sustained outage still warns, and recovery clears the warning.
    await clock.advance(4_250);
    await dropsAfter(drops);
    await expect(warning).toContainText(
      "Connection interrupted. Showing the most recently synced content."
    );
    stub.setWorkspaceChatEventsUnreachable(false);
    await clock.advance(8_250);
    await expect.poll(() => stub.activeCompletedWorkspaceChatEventStreams).toBe(1);
    await expect(warning).toHaveCount(0);
    await expect(content.getByText(chatSmokeAssistantReply)).toBeVisible();
  } finally {
    try {
      await clock?.dispose();
    } finally {
      await stub.close();
    }
  }
});
