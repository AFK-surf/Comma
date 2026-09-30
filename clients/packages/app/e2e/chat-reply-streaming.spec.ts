import { expect, test, type Locator, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

const wireMessage = (
  id: string,
  text: string,
  actor: "user" | "router" | "worker",
  time: number
) => ({
  actor_type: actor === "user" ? "user" : "agent",
  ...(actor === "user"
    ? {}
    : {
        agent_id: `actor_${actor}`,
        role_label: actor === "router" ? "delegator" : "worker",
      }),
  message_id: id,
  thread_root_message_id: id,
  content: [{ type: "text", text }],
  created_at: time,
  kind: "message",
});

test("reply previews load an older message only on demand and allow retry after a read failure", async ({
  page,
}) => {
  const target = wireMessage(
    "old-worker",
    "The original worker proposal.",
    "worker",
    1720000000
  );
  const stub = await startChatSmokeStub({
    taskStatus: "active",
    taskTranscript: [
      {
        ...wireMessage(
          "recent-reply",
          "I reviewed the original proposal.",
          "router",
          1720001000
        ),
        reply_to_message_id: target.message_id,
        thread_root_message_id: target.message_id,
      },
    ],
  });
  let reads = 0;
  await page.route("**/messages/old-worker/context", async (route) => {
    reads += 1;
    await route.fulfill({
      status: reads === 1 ? 503 : 200,
      contentType: "application/json",
      body: JSON.stringify(reads === 1 ? { error: "unavailable" } : { data: [target] }),
    });
  });
  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "reply-history@comma.local",
      token: "comma_sess_reply_history",
    });
    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const preview = page.locator('[data-reply-preview-target="old-worker"]');
    await expect(preview).toContainText("View earlier message");
    expect(reads).toBe(0);
    await preview.click();
    await expect(
      page.getByText("Could not load the referenced message. Please try again.")
    ).toBeVisible();
    await expect(preview).toBeEnabled();
    await preview.click();
    const original = page.locator('article[data-message-id="old-worker"]');
    await expect(original).toContainText("The original worker proposal.");
    await expect(original).toBeFocused();
    await expect(original).toBeInViewport();
    await expect(page.locator(".comma-chat-history-gap")).toHaveText("Later messages");
    await expect(page.locator('[data-message-id="recent-reply"]')).toBeVisible();
    expect(reads).toBe(2);
  } finally {
    await stub.close();
  }
});

test("chat bubbles group blocks, keep actions beside messages, and tighten consecutive speakers", async ({
  page,
}, testInfo) => {
  const stub = await startChatSmokeStub({
    taskStatus: "active",
    taskTranscript: [
      wireMessage("user-one", "First user message", "user", 1720000010),
      wireMessage("user-two", "Another user message", "user", 1720000011),
      wireMessage(
        "reply-one",
        "First reply.\n\n---\n\nSecond block.\n\n```ts\nconst status = 'ready';\n```",
        "router",
        1720000012
      ),
      wireMessage(
        "reply-two",
        "A long assistant reply remains readable. ".repeat(14),
        "worker",
        1720000013
      ),
    ],
  });
  try {
    await page.setViewportSize({ width: 1440, height: 1000 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-bubbles@comma.local",
      token: "comma_sess_chat_bubbles",
    });
    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const userOne = page.locator('[data-message-id="user-one"]');
    const userTwo = page.locator('[data-message-id="user-two"]');
    const replyOne = page.locator('[data-message-id="reply-one"]');
    const replyTwo = page.locator('[data-message-id="reply-two"]');
    await expect(replyOne.locator(".markdown-stream-bubble")).toHaveCount(3);
    await expect(replyTwo).toContainText("A long assistant reply");
    await userTwo.hover();
    const userBubble = await userTwo.locator(".comma-chat-user-bubble").boundingBox();
    const userCopy = await userTwo
      .getByRole("button", { name: "Copy message" })
      .boundingBox();
    expect(userCopy!.x + userCopy!.width).toBeLessThanOrEqual(userBubble!.x);
    expect(userCopy!.y).toBeLessThan(userBubble!.y + userBubble!.height);
    await replyTwo.hover();
    const assistantBubble = await replyTwo
      .locator(".markdown-stream-bubble")
      .boundingBox();
    const assistantCopy = await replyTwo
      .getByRole("button", { name: "Copy reply" })
      .boundingBox();
    expect(assistantCopy!.x).toBeGreaterThanOrEqual(
      assistantBubble!.x + assistantBubble!.width
    );
    expect(
      assistantCopy!.x - assistantBubble!.x - assistantBubble!.width
    ).toBeLessThanOrEqual(13);
    expect(assistantCopy!.y).toBeLessThan(assistantBubble!.y + assistantBubble!.height);
    expect(assistantBubble!.width).toBeLessThanOrEqual(500);
    for (const row of [replyOne, replyTwo]) {
      await expect(row.locator(".comma-chat-assistant-source-avatar")).toHaveCSS(
        "width",
        "16px"
      );
      await expect(row.locator(".comma-chat-assistant-source-avatar")).toHaveCSS(
        "height",
        "16px"
      );
    }
    const [a, b, c, d] = await Promise.all([
      userOne.boundingBox(),
      userTwo.boundingBox(),
      replyOne.boundingBox(),
      replyTwo.boundingBox(),
    ]);
    const userGap = b!.y - a!.y - a!.height;
    const speakerGap = c!.y - b!.y - b!.height;
    const assistantGap = d!.y - c!.y - c!.height;
    expect(userGap).toBeGreaterThanOrEqual(0);
    expect(assistantGap).toBeGreaterThanOrEqual(0);
    expect(userGap).toBeLessThan(speakerGap);
    expect(assistantGap).toBeLessThan(speakerGap);

    // Every surface uses one content edge even as the details panel folds.
    const inputWidths = new Map<number, number>();
    for (const width of [1440, 801, 800, 500]) {
      await page.setViewportSize({ width, height: 1000 });
      // ResizeObserver commits the panel fold after the viewport resize. Wait
      // for that state before collecting the transition or measuring widths.
      await expect(page.getByTestId("task-conversation-body")).toHaveAttribute(
        "data-panel-open",
        String(width === 1440)
      );
      await page.locator(".comma-chat-body").evaluate(async (body) => {
        await Promise.allSettled(
          body.getAnimations().map((animation) => animation.finished)
        );
      });
      await expect
        .poll(() =>
          page.evaluate(() => {
            const composer = document
              .querySelector(".comma-chat-composer")!
              .getBoundingClientRect();
            const viewport = document
              .querySelector(".comma-chat-scroll-viewport")!
              .getBoundingClientRect();
            return Array.from(
              document.querySelectorAll(".comma-chat-message-assistant")
            ).reduce((error, row) => {
              const bubble = row
                .querySelector(".markdown-stream-bubble")!
                .getBoundingClientRect();
              const avatar = row
                .querySelector(".comma-chat-assistant-source-avatar")!
                .getBoundingClientRect();
              const actions = row
                .querySelector(".comma-chat-message-actions")!
                .getBoundingClientRect();
              return Math.max(
                error,
                Math.abs(bubble.left - composer.left),
                viewport.left - avatar.left,
                avatar.right - bubble.left,
                actions.right - composer.right
              );
            }, 0);
          })
        )
        .toBeLessThanOrEqual(1);
      inputWidths.set(
        width,
        (await page.locator(".comma-chat-composer").boundingBox())!.width
      );
    }
    // A one-pixel window resize must resize the input continuously.
    expect(inputWidths.get(801)! - inputWidths.get(800)!).toBeCloseTo(1, 1);
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.screenshot({ path: testInfo.outputPath("chat-bubbles.png") });
  } finally {
    await stub.close();
  }
});

/**
 * Exercise send -> HTTP acknowledgment -> Participant SSE -> draft -> canonical
 * reply through the real browser host. The gates represent independently slow
 * network/agent boundaries, so local feedback cannot pass by racing a fast stub.
 */
test("sending responds immediately and streams one continuous reply", async ({
  page,
}, testInfo) => {
  const firstText = "The first part";
  const secondText = `${firstText} arrives while generation continues`;
  const finalText = `${secondText}, then the final part completes the reply.`;
  const stub = await startChatSmokeStub({
    assistantDraft: firstText,
    assistantReply: finalText,
    holdStreamingReplyStart: true,
    holdWorkspaceChatMessage: true,
    streamAssistantReply: true,
  });

  try {
    const content = await openChat(page, stub, "streaming");
    await stub.waitForInitialChatSnapshot();
    await content.getByRole("textbox", { name: "AI prompt" }).fill("Stream this reply");
    await content.getByRole("button", { name: "Send" }).click();

    const status = content.getByTestId("participant-status-slot");
    // The POST is still blocked and the last server Participant is stopped.
    // Previously this remained silent until the agent published its first event.
    await expect(status).toHaveAttribute("data-active", "true", { timeout: 500 });
    await expectCurrentSummary(status, "Thinking", 500);
    const activityContinuity = await observeActivityContinuity(status);
    await stub.waitForWorkspaceChatMessage();
    await expect(content.locator('[data-slot="chat-user-output"]')).toContainText(
      "Stream this reply"
    );
    await expect(content.getByTestId("chat-assistant-draft")).toHaveCount(0);

    stub.releaseWorkspaceChatMessage();
    await stub.waitForStreamingReplyReady();
    // A new snapshot can echo the previous stopped status after send succeeds;
    // that stale status must not end the local wait for this accepted turn.
    await expect(status).toHaveAttribute("data-active", "true");
    await expectCurrentSummary(status, "Thinking");

    // Keep the same visible mark across the local -> Participant -> source-bound
    // Activity handoff, even though the underlying source identity changes.
    stub.publishStreamingParticipantStatus("is thinking...");
    stub.publishStreamingActivity("thinking");
    await expect(status.locator(".comma-chat-thinking-logo")).not.toHaveAttribute(
      "data-participant-key",
      "optimistic-thinking"
    );
    await expectCurrentSummary(status, "Thinking");
    expect(
      await activityContinuity.evaluate(({ summary }) => summary.isConnected)
    ).toBe(true);
    await expectActivityContinuity(activityContinuity);

    await expectActivityContinuity(activityContinuity);
    await activityContinuity.evaluate(({ stop }) => stop());
    await activityContinuity.dispose();

    stub.startStreamingReply();
    await stub.waitForDraft();
    const draft = content.getByTestId("chat-assistant-draft");
    await expect(draft).toContainText(firstText);
    await expect(status).toBeHidden();
    await expectReplyReplacesActivity(content);

    const continuity = await draft.evaluateHandle((article) => {
      const turn = article.closest('[data-testid="chat-current-turn"]')!;
      const probe = { disconnected: 0, empty: 0, duplicates: 0, samples: 0 };
      const sample = () => {
        probe.samples += 1;
        if (!article.isConnected) probe.disconnected += 1;
        if (!article.querySelector(".markdown-stream")?.textContent?.trim()) {
          probe.empty += 1;
        }
        if (turn.querySelectorAll('[data-slot="chat-assistant-output"]').length > 1) {
          probe.duplicates += 1;
        }
      };
      const observer = new MutationObserver(sample);
      observer.observe(turn, { childList: true, subtree: true, characterData: true });
      return { article, observer, probe };
    });

    stub.updateStreamingDraft(secondText);
    await expect(draft).toContainText(secondText);
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toHaveCount(0);
    await expectReplyReplacesActivity(content);
    await content.screenshot({ path: testInfo.outputPath("streaming-draft.png") });

    stub.updateStreamingDraft(finalText);
    await expect(draft).toContainText(finalText);
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toHaveCount(0);
    expect(await continuity.evaluate(({ article }) => article.isConnected)).toBe(true);

    stub.completeStreamingReply();
    const canonical = content.locator('[data-message-id="msg-assistant-smoke"]');
    await expect(canonical).toContainText(finalText);
    await expect(content.locator('[data-slot="chat-assistant-output"]')).toHaveCount(1);
    await expect(draft).toHaveCount(0);
    await expect(status).toHaveAttribute("data-active", "false");
    await expect(status).toBeHidden();
    expect((await status.boundingBox())?.height).toBe(40);
    await content.screenshot({ path: testInfo.outputPath("canonical-reply.png") });

    const observed = await continuity.evaluate(({ article, observer, probe }) => {
      observer.disconnect();
      return {
        ...probe,
        sameCanonicalArticle:
          article.isConnected &&
          article.getAttribute("data-message-id") === "msg-assistant-smoke",
      };
    });
    expect(observed.samples).toBeGreaterThan(0);
    expect(observed).toMatchObject({
      disconnected: 0,
      empty: 0,
      duplicates: 0,
      sameCanonicalArticle: true,
    });
    await continuity.dispose();
  } finally {
    await stub.close();
  }
});

test("internal waiting status stays private and messaging uses localized copy", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    holdStreamingReplyStart: true,
    streamAssistantReply: true,
  });

  try {
    const content = await openChat(page, stub, "activity-copy");
    await content
      .getByRole("textbox", { name: "AI prompt" })
      .fill("Send a short reply");
    await content.getByRole("button", { name: "Send" }).click();
    await stub.waitForStreamingReplyReady();
    const status = content.getByTestId("participant-status-slot");

    // This is the exact internal Participant status that leaked in the report.
    // A Participant with no public Activity only authorizes generic Thinking.
    stub.publishStreamingParticipantStatus(
      "is waiting: async tool call still running: im_api.internal.send_message"
    );
    await expectCurrentSummary(status, "Thinking");
    await expect(status).not.toContainText("async tool call");
    await expect(status).not.toContainText("im_api.internal.send_message");

    // Messaging is a structured phase, independent of the raw wait diagnostic.
    stub.publishStreamingActivity("messaging");
    await expectCurrentSummary(status, "Typing");
    await expect(status).not.toContainText("is waiting");
    await expect(content.getByTestId("chat-assistant-draft")).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("a rejected send ends local Thinking and offers retry", async ({ page }) => {
  const stub = await startChatSmokeStub({
    holdStreamingReplyStart: true,
    holdWorkspaceChatMessage: true,
    streamAssistantReply: true,
    workspaceChatMessageError: { error: "temporary_unavailable", status: 503 },
  });

  try {
    const content = await openChat(page, stub, "send-failure");
    await stub.waitForInitialChatSnapshot();
    await content.getByRole("textbox", { name: "AI prompt" }).fill("This send fails");
    await content.getByRole("button", { name: "Send" }).click();
    const status = content.getByTestId("participant-status-slot");
    await expectCurrentSummary(status, "Thinking", 500);
    await stub.waitForWorkspaceChatMessage();

    stub.releaseWorkspaceChatMessage();
    await expect(content.locator('[data-slot="chat-user-output"]')).toHaveAttribute(
      "data-delivery",
      "failed"
    );
    await expect(
      content.getByRole("button", { name: "Retry", exact: true })
    ).toBeVisible();
    await expect(status).toHaveAttribute("data-active", "false");
    await expect(status).toBeHidden();
    expect((await status.boundingBox())?.height).toBe(40);
    await expect(content.getByTestId("chat-assistant-draft")).toHaveCount(0);
  } finally {
    await stub.close();
  }
});

test("streamed prefixes stay sharp and keep settled characters in place", async ({
  page,
}, testInfo) => {
  const settledPrefix =
    "已经显示的文字保持清晰，行尾和下一行的位置也应保持稳定。".repeat(2);
  const additions = [
    "随后",
    "到达",
    "的正文",
    "持续增长",
    "，已有",
    "文字不应",
    "重新模糊",
    "或上下跳动。",
  ];
  const plainText = settledPrefix + additions.join("");
  const finalText = `${plainText}\n\n**新增内容**\n\n- 检查正文\n- 检查状态\n\n\`\`\`js\nconst ready = true;\n\`\`\``;
  const stub = await startChatSmokeStub({
    assistantDraft: settledPrefix,
    assistantReply: finalText,
    streamAssistantReply: true,
  });

  try {
    const content = await openChat(page, stub, "sharp-prefixes");
    await content.getByRole("textbox", { name: "AI prompt" }).fill("逐步显示这段正文");
    await content.getByRole("button", { name: "Send" }).click();
    await stub.waitForDraft();
    const draft = content.getByTestId("chat-assistant-draft");
    await expect(draft).toContainText(settledPrefix);
    // Start the geometry baseline after the initial text has settled. The
    // observer below starts before any new prefix and catches transient motion;
    // waiting for a final screenshot alone would miss the reported defect.
    await expect
      .poll(() => draft.locator(".markdown-stream-char-enter").count())
      .toBe(0);
    const stability = await observeSettledText(draft, settledPrefix);
    let cumulative = settledPrefix;
    for (const addition of additions) {
      cumulative += addition;
      stub.updateStreamingDraft(cumulative);
      await expect(draft).toContainText(cumulative);
      await expectReplyReplacesActivity(content);
      // Match the small, frequent real wire prefixes in the reviewed recording.
      await page.waitForTimeout(80);
    }
    // Also observe the old per-character spans being merged after their animation.
    await page.waitForTimeout(180);
    const observed = await stability.evaluate(({ stop }) => stop());
    await testInfo.attach("stream-text-stability.json", {
      body: JSON.stringify(observed, null, 2),
      contentType: "application/json",
    });
    await stability.dispose();
    const article = await draft.elementHandle();

    stub.updateStreamingDraft(finalText);
    await expect(draft.locator("strong")).toHaveText("新增内容");
    await expect(draft.locator("li")).toHaveCount(2);
    await expect(draft.locator("pre")).toContainText("const ready = true;");
    await expectReplyReplacesActivity(content);
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"]')
    ).toContainText("const ready = true;");
    await expect(content.locator('[data-slot="chat-assistant-output"]')).toHaveCount(1);
    expect(await article!.evaluate((node) => node.isConnected)).toBe(true);
    await expect(draft).toHaveCount(0);
    const status = content.getByTestId("participant-status-slot");
    await expect(status).toBeHidden();
    expect((await status.boundingBox())?.height).toBe(40);

    expect(observed.samples).toBeGreaterThan(8);
    expect(observed.baselineLineCount).toBeGreaterThanOrEqual(2);
    expect(observed).toMatchObject({
      blurredSamples: 0,
      translatedSamples: 0,
      motionAnimationSamples: 0,
      missingPrefixSamples: 0,
      detachedPrefixSamples: 0,
      replacedParagraphSamples: 0,
    });
    expect(observed.maxCharacterShiftPx).toBeLessThanOrEqual(0.5);
  } finally {
    await stub.close();
  }
});

test("completed code lines keep their syntax colors as the reply grows", async ({
  page,
}, testInfo) => {
  const firstLine = "const ready = true;";
  // “代码” requires full-document parsing for cross-root linkification. It must
  // not turn every appended prefix into a new code-block renderer identity.
  const start = `如果想用代码表达，可以这样写：\n\n\`\`\`js\n${firstLine}\n`;
  const codeTail =
    "const count = 1;\nfunction square(value) {\n  return value * value;\n}\nconsole.log(square(count));\n";
  const closed = `${start}${codeTail}\`\`\``;
  const prose = "\n\n这段代码已经完成，后续说明继续到达。";
  const finalText = closed + prose;
  const stub = await startChatSmokeStub({
    assistantDraft: start,
    assistantReply: finalText,
    streamAssistantReply: true,
  });
  try {
    const content = await openChat(page, stub, "code-colors");
    await content.getByRole("textbox", { name: "AI prompt" }).fill("逐步展示代码");
    await content.getByRole("button", { name: "Send" }).click();
    await stub.waitForDraft();
    const draft = content.getByTestId("chat-assistant-draft");
    await expect(
      draft.locator(".code-block-render:not(.code-block-render-pending) .line")
    ).toContainText(firstLine);
    const observer = await draft.evaluateHandle((root, fixedLine) => {
      const figure = root.querySelector(".markdown-stream-code-block")!;
      const renderer = figure.querySelector(".code-block-render")!;
      // oxlint-disable-next-line unicorn/consistent-function-scoping -- This helper runs in the browser's isolated evaluate context.
      const visible = (node: Element) => Boolean(node.getClientRects().length);
      const read = () => {
        const pres = [...root.querySelectorAll("pre")].filter(visible);
        const pre = pres[0];
        const colors: string[] = [];
        if (pre) {
          const walker = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT);
          let node: Node | null;
          while ((node = walker.nextNode()) && colors.length < fixedLine.length) {
            const color = getComputedStyle(node.parentElement!).color;
            for (let i = 0; i < (node.textContent?.length ?? 0); i += 1) {
              if (colors.length === fixedLine.length) break;
              colors.push(color);
            }
          }
        }
        return { code: pre?.textContent ?? "", colors, count: pres.length };
      };
      const baseline = read();
      const data = {
        baselineColors: baseline.colors,
        samples: 0,
        fallbackSamples: 0,
        colorRegressionSamples: 0,
        detachedCodeBlockSamples: 0,
        missingLineSamples: 0,
        duplicateSamples: 0,
        shortenedSamples: 0,
      };
      let maxLength = baseline.code.length;
      let raf = 0;
      const sample = () => {
        data.samples += 1;
        const now = read();
        if ([...root.querySelectorAll(".code-fallback-plain")].some(visible))
          data.fallbackSamples += 1;
        if (JSON.stringify(now.colors) !== JSON.stringify(baseline.colors))
          data.colorRegressionSamples += 1;
        if (!figure.isConnected || !renderer.isConnected)
          data.detachedCodeBlockSamples += 1;
        if (!now.code.startsWith(fixedLine)) data.missingLineSamples += 1;
        if (now.count !== 1) data.duplicateSamples += 1;
        if (now.code.length < maxLength) data.shortenedSamples += 1;
        maxLength = Math.max(maxLength, now.code.length);
      };
      const mutations = new MutationObserver(sample);
      mutations.observe(root, {
        subtree: true,
        childList: true,
        characterData: true,
        attributes: true,
      });
      const frame = () => {
        sample();
        raf = requestAnimationFrame(frame);
      };
      frame();
      return {
        stop() {
          sample();
          mutations.disconnect();
          cancelAnimationFrame(raf);
          return data;
        },
      };
    }, firstLine);
    let cumulative = start;
    for (const segment of [codeTail, "```", prose]) {
      for (let index = 0; index < segment.length; index += 3) {
        cumulative += segment.slice(index, index + 3);
        stub.updateStreamingDraft(cumulative);
        await page.waitForTimeout(80);
      }
      await expect(draft.locator("pre")).toContainText("console.log(square(count));");
    }
    await expect(draft).toContainText("这段代码已经完成，后续说明继续到达。");
    await expectReplyReplacesActivity(content);
    stub.completeStreamingReply();
    await expect(
      content.locator('[data-message-id="msg-assistant-smoke"] pre')
    ).toContainText("console.log(square(count));");
    const data = await observer.evaluate(({ stop }) => stop());
    await observer.dispose();
    await testInfo.attach("code-highlight-stability.json", {
      body: JSON.stringify(data, null, 2),
      contentType: "application/json",
    });
    expect(new Set(data.baselineColors).size).toBeGreaterThan(1);
    expect(data.samples).toBeGreaterThan(100);
    expect(data).toMatchObject({
      fallbackSamples: 0,
      colorRegressionSamples: 0,
      detachedCodeBlockSamples: 0,
      missingLineSamples: 0,
      duplicateSamples: 0,
      shortenedSamples: 0,
    });
  } finally {
    await stub.close();
  }
});

async function observeSettledText(draft: Locator, prefix: string) {
  return draft.evaluateHandle((article, text) => {
    const markdown = article.querySelector<HTMLElement>(".markdown-stream")!;
    const paragraph = markdown.querySelector("p")!;
    const prefixNodes = new Set<Node>();
    const readCharacters = (rememberNodes = false) => {
      const current = markdown.querySelector("p");
      if (!current?.textContent?.startsWith(text)) return [];
      const origin = markdown.getBoundingClientRect();
      const walker = document.createTreeWalker(current, NodeFilter.SHOW_TEXT);
      const characters: { x: number; y: number }[] = [];
      let node: Node | null;
      while ((node = walker.nextNode()) && characters.length < text.length) {
        for (let index = 0; index < (node.textContent?.length ?? 0); index += 1) {
          if (characters.length === text.length) break;
          if (rememberNodes) prefixNodes.add(node);
          const range = document.createRange();
          range.setStart(node, index);
          range.setEnd(node, index + 1);
          const rect = range.getBoundingClientRect();
          characters.push({ x: rect.x - origin.x, y: rect.y - origin.y });
        }
      }
      return characters;
    };
    const baseline = readCharacters(true);
    if (baseline.length !== text.length)
      throw new Error("Missing settled prefix baseline");
    const probe = {
      baselineLineCount: new Set(baseline.map(({ y }) => Math.round(y))).size,
      samples: 0,
      blurredSamples: 0,
      translatedSamples: 0,
      motionAnimationSamples: 0,
      missingPrefixSamples: 0,
      detachedPrefixSamples: 0,
      replacedParagraphSamples: 0,
      maxCharacterShiftPx: 0,
    };
    const sample = () => {
      probe.samples += 1;
      if ([...prefixNodes].some((node) => !node.isConnected))
        probe.detachedPrefixSamples += 1;
      if (markdown.querySelector("p") !== paragraph)
        probe.replacedParagraphSamples += 1;
      const characters = readCharacters();
      if (characters.length !== baseline.length) probe.missingPrefixSamples += 1;
      for (let index = 0; index < characters.length; index += 1) {
        probe.maxCharacterShiftPx = Math.max(
          probe.maxCharacterShiftPx,
          Math.abs(characters[index]!.x - baseline[index]!.x),
          Math.abs(characters[index]!.y - baseline[index]!.y)
        );
      }
      // Text descendants only: the separate Thinking mark and opacity-only
      // streaming cursor retain their own intentional animations.
      for (const element of markdown.querySelectorAll<HTMLElement>("p, p *")) {
        if (!element.textContent?.trim()) continue;
        const style = getComputedStyle(element);
        const blur = Number(style.filter.match(/blur\(([\d.]+)px\)/)?.[1] ?? 0);
        if (blur > 0.01) probe.blurredSamples += 1;
        if (
          style.transform !== "none" &&
          !new DOMMatrixReadOnly(style.transform).isIdentity
        ) {
          probe.translatedSamples += 1;
        }
        if (
          element.getAnimations().some((animation) => {
            const effect = animation.effect;
            return (
              effect instanceof KeyframeEffect &&
              effect
                .getKeyframes()
                .some(
                  (frame) => frame.filter !== undefined || frame.transform !== undefined
                )
            );
          })
        )
          probe.motionAnimationSamples += 1;
      }
    };
    let animationFrame = 0;
    const observer = new MutationObserver(sample);
    observer.observe(markdown, {
      attributes: true,
      characterData: true,
      childList: true,
      subtree: true,
    });
    const frame = () => {
      sample();
      animationFrame = requestAnimationFrame(frame);
    };
    frame();
    return {
      stop() {
        sample();
        observer.disconnect();
        cancelAnimationFrame(animationFrame);
        return probe;
      },
    };
  }, prefix);
}

async function openChat(
  page: Page,
  stub: Awaited<ReturnType<typeof startChatSmokeStub>>,
  id: string
) {
  await installBrowserTestSession(page, {
    apiBaseUrl: stub.baseUrl,
    email: `comma-chat-${id}@comma.local`,
    token: `comma_sess_chat_${id}`,
  });
  await page.goto("/");
  const content = page.getByRole("region", { name: "Content" });
  await expect(content.getByRole("textbox", { name: "AI prompt" })).toBeVisible();
  return content;
}

async function expectCurrentSummary(slot: Locator, text: string, timeout = 8_000) {
  await expect(
    slot.locator(
      '.comma-ai-activity-text-layer:not([aria-hidden="true"]) .comma-ai-activity-text-summary'
    )
  ).toHaveText(text, { timeout });
}

async function observeActivityContinuity(slot: Locator) {
  // Ignore the first appearance's intentional fade; all subsequent transitions
  // must preserve the visible row, mark and its running CSS animation.
  await expect
    .poll(() =>
      slot.locator(".comma-chat-thinking-logo").evaluate((avatar) => {
        return getComputedStyle(avatar).opacity;
      })
    )
    .toBe("1");
  return slot.evaluateHandle((element) => {
    const row = element.querySelector(".comma-chat-activity-row")!;
    const activity = element.querySelector('[data-slot="ai-activity"]')!;
    const avatar = element.querySelector(".comma-chat-thinking-logo")!;
    const logo = avatar.querySelector('[data-slot="comma-logo-animation"]')!;
    const scene = logo.querySelector(".comma-logo-animation__scene")!;
    const animation = scene.getAnimations()[0];
    const summary = element.querySelector(
      '.comma-ai-activity-text-layer:not([aria-hidden="true"]) .comma-ai-activity-text-summary'
    )!;
    const probe = {
      samples: 0,
      detached: 0,
      replaced: 0,
      hidden: 0,
      restarted: 0,
      hasAnimation: Boolean(animation),
    };
    const sample = () => {
      probe.samples += 1;
      if ([element, row, activity, avatar, logo].some((node) => !node.isConnected)) {
        probe.detached += 1;
      }
      if (element.querySelector('[data-slot="comma-logo-animation"]') !== logo) {
        probe.replaced += 1;
      }
      if (
        element.getAttribute("data-active") !== "true" ||
        !element.getClientRects().length ||
        getComputedStyle(row).opacity === "0" ||
        getComputedStyle(avatar).opacity === "0"
      ) {
        probe.hidden += 1;
      }
      if (scene.getAnimations()[0] !== animation) probe.restarted += 1;
    };
    const observer = new MutationObserver(sample);
    observer.observe(document.body, {
      attributes: true,
      childList: true,
      subtree: true,
    });
    let frame: number;
    const sampleFrame = () => {
      sample();
      frame = requestAnimationFrame(sampleFrame);
    };
    sampleFrame();
    return {
      probe,
      summary,
      stop: () => {
        observer.disconnect();
        cancelAnimationFrame(frame);
      },
    };
  });
}

async function expectActivityContinuity(
  handle: Awaited<ReturnType<typeof observeActivityContinuity>>
) {
  const observed = await handle.evaluate(({ probe }) => probe);
  expect(observed.samples).toBeGreaterThan(0);
  expect(observed).toMatchObject({
    detached: 0,
    replaced: 0,
    hidden: 0,
    restarted: 0,
    hasAnimation: true,
  });
}

async function expectReplyReplacesActivity(content: Locator) {
  const turn = content.getByTestId("chat-current-turn");
  const status = turn.getByTestId("participant-status-slot");
  await expect(status).toHaveCount(1);
  await expect(status).toBeHidden();
  expect((await status.boundingBox())?.height).toBe(40);
  await expect(turn.locator('[data-slot="chat-assistant-output"]')).toBeVisible();
}
