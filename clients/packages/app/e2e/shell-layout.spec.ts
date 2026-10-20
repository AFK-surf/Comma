import { waitForSettledMotion } from "../../../e2e/helpers/motion";
import { expect, test, type Locator, type Page } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  chatSmokeWorkspaceChat,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";
import { iconStrokeWidth } from "../../ui/src/tokens/icons";
import { parseCssColor, type CssRgbaColor } from "../../../e2e/helpers/css-color";
import {
  commaThemeLightnessMax,
  commaThemeLightnessMin,
} from "../../ui/src/tokens/colors/oklch";

// Web shell layout scenarios that do not run on the test clock yet. The other
// scenarios of the web shell's layout are in
// e2e/app-shell/shell-layout.chromium.test.ts.

const srgbChannelToLinear = (channel: number) => {
  const s = channel / 255;
  return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
};

const relativeLuminance = ({ b, g, r }: CssRgbaColor) =>
  0.2126 * srgbChannelToLinear(r) +
  0.7152 * srgbChannelToLinear(g) +
  0.0722 * srgbChannelToLinear(b);

const contrastRatio = (a: CssRgbaColor, b: CssRgbaColor) => {
  const left = relativeLuminance(a);
  const right = relativeLuminance(b);
  const [hi, lo] = left > right ? [left, right] : [right, left];
  return (hi + 0.05) / (lo + 0.05);
};

const contrastAgainstPaintedBackground = async (locator: Locator) => {
  const pair = await locator.evaluate((element) => {
    const fg = getComputedStyle(element).color;
    const backgrounds: string[] = [];
    let node: Element | null = element;
    while (node) {
      backgrounds.push(getComputedStyle(node).backgroundColor);
      node = node.parentElement;
    }
    return { backgrounds, fg };
  });
  const fg = parseCssColor(pair.fg);
  const bg = pair.backgrounds.map(parseCssColor).find((color) => color.a > 0.95);
  if (!bg) throw new Error("No opaque background behind the sampled text.");
  return contrastRatio(fg, bg);
};

const contrastOfPrimaryTextOnPrimaryBg = async (page: Page) => {
  const pair = await page.evaluate(() => {
    const probe = document.createElement("span");
    probe.style.color = "var(--color-text-primary)";
    probe.style.backgroundColor = "var(--color-bg-primary)";
    document.documentElement.append(probe);
    const style = getComputedStyle(probe);
    const result = { background: style.backgroundColor, color: style.color };
    probe.remove();
    return result;
  });
  return contrastRatio(parseCssColor(pair.color), parseCssColor(pair.background));
};

test("committed inline Task opens a sidebar tab and Command-click opens its detail route", async ({
  page,
}) => {
  const assistantReply = "我已经处理了";
  const stub = await startChatSmokeStub({
    assistantReply,
    inlineTaskBoundaryCases: true,
    inlineTaskReference: true,
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "inline-task@comma.local",
      token: "comma_sess_inline_task",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer.getByRole("textbox", { name: "AI prompt" }).fill("请完成冒烟任务");
    const previewResponse = page.waitForResponse(
      (response) =>
        response.url().endsWith(`/${chatSmokeTaskConversation.id}/preview`) &&
        response.status() === 200
    );
    await composer.getByRole("button", { name: "Send" }).click();

    const assistantMessage = content.locator('[data-message-id="msg-assistant-smoke"]');
    const inlineTask = assistantMessage.getByTestId(
      `chat-inline-task-${chatSmokeTaskConversation.id}`
    );
    const sentence = assistantMessage.locator("p");

    await expect(inlineTask).toBeVisible();
    await expect(sentence).toHaveText(
      `${assistantReply} ${chatSmokeTaskConversation.title} 已完成。`
    );
    await expect(
      assistantMessage.getByTestId(`chat-ref-card-${chatSmokeTaskConversation.id}`)
    ).toHaveCount(0);

    for (const messageId of [
      "msg-assistant-inline-info",
      "msg-assistant-inline-quote",
      "msg-assistant-inline-indented",
      "msg-assistant-inline-cr",
    ]) {
      const boundaryMessage = content.locator(`[data-message-id="${messageId}"]`);
      const boundaryInline = boundaryMessage.getByTestId(
        `chat-inline-task-${chatSmokeTaskConversation.id}`
      );
      await expect(boundaryInline).toBeVisible();
      expect(
        await boundaryInline.evaluate(
          (element) => element.closest("code, pre, blockquote") === null
        )
      ).toBe(true);
    }

    const privateMessage = content.locator(
      '[data-message-id="msg-assistant-inline-private"]'
    );
    await expect(privateMessage).toContainText("Visible");
    await expect(privateMessage).not.toContainText("secret");
    await expect(
      privateMessage.getByTestId(`chat-inline-task-${chatSmokeTaskConversation.id}`)
    ).toHaveCount(0);

    const emphasisMessage = content.locator(
      '[data-message-id="msg-assistant-inline-emphasis"]'
    );
    const emphasisInline = emphasisMessage.getByTestId(
      `chat-inline-task-${chatSmokeTaskConversation.id}`
    );
    await expect(emphasisInline).toBeVisible();
    await expect(emphasisMessage.locator("strong")).toHaveText(
      `before ${chatSmokeTaskConversation.title} after`
    );
    expect(
      await emphasisInline.evaluate((element) => element.closest("strong") !== null)
    ).toBe(true);
    await expect(emphasisMessage).not.toContainText("**");

    const referenceMessage = content.locator(
      '[data-message-id="msg-assistant-inline-reference"]'
    );
    await expect(
      referenceMessage.getByRole("link", { name: "documentation" })
    ).toHaveAttribute("href", "https://example.com/docs");
    const referenceInline = referenceMessage.getByTestId(
      `chat-inline-task-${chatSmokeTaskConversation.id}`
    );
    await expect(referenceInline).toBeVisible();

    // This sentence closes with "." directly against the mention, the way
    // Chinese prose also sets its punctuation ("已完成并发布 <mention>："): the
    // surrounding text contributes no space of its own. The pill owns that
    // gutter, so the trailing prose must start outside its background rather
    // than sliding under it.
    const trailingGutter = await referenceInline.evaluate((element) => {
      const paragraph = element.parentElement;
      const last = paragraph?.lastChild;
      if (!paragraph || !last || last === element) return null;
      const trailing = document.createRange();
      trailing.setStartAfter(element);
      trailing.setEndAfter(last);
      const pill = element.getBoundingClientRect();
      const sameLine = Array.from(trailing.getClientRects()).find(
        (rect) => Math.abs(rect.top - pill.top) < pill.height
      );
      return sameLine ? sameLine.left - pill.right : null;
    });
    expect(trailingGutter).not.toBeNull();
    expect(trailingGutter!).toBeGreaterThanOrEqual(2);

    const hoverCard = page.locator('[data-slot="hover-card"]');
    // Rendering the boundary-case messages can still move the transcript after
    // the first pointer entry. Re-enter the trigger if that dismisses the card,
    // rather than waiting forever on a detached tooltip. Keep real hover and
    // pointer-transfer assertions; do not force actions or disable animation.
    await expect(async () => {
      await inlineTask.hover({ timeout: 1_000 });
      await expect(hoverCard).toBeVisible({ timeout: 1_000 });
      await expect(hoverCard.locator('[data-slot="task-card-title"]')).toHaveText(
        chatSmokeTaskConversation.title,
        { timeout: 1_000 }
      );
      await hoverCard.hover({ timeout: 1_000 });
      await page.waitForTimeout(150);
      await expect(hoverCard).toBeVisible({ timeout: 1_000 });
    }).toPass();
    await previewResponse;

    const commaCenterUrl = page.url();
    await inlineTask.click();
    await expect(page).toHaveURL(commaCenterUrl);
    const sidebar = content.getByTestId("chat-sidebar");
    await expect(sidebar).toHaveAttribute("data-open", "true");
    await expect(
      sidebar.getByRole("tab", { name: chatSmokeTaskConversation.title })
    ).toHaveAttribute("aria-selected", "true");
    await expect(
      sidebar.getByTestId(`chat-sidebar-conversation-${chatSmokeTaskConversation.id}`)
    ).toBeVisible();

    // Command-click opens Task details from the inbox transcript.
    await page.goto(
      `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeWorkspaceChat.id}`
    );
    await content
      .locator('[data-message-id="msg-assistant-smoke"]:visible')
      .getByTestId(`chat-inline-task-${chatSmokeTaskConversation.id}`)
      .click({ modifiers: ["Meta"] });
    await expect(page).toHaveURL(
      new RegExp(
        `#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );
    await expect(
      content.getByRole("heading", { name: chatSmokeTaskConversation.title })
    ).toBeVisible();
  } finally {
    await stub.close();
  }
});

test("short chat stays non-scrollable and uses a compact latest turn after overflow", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    assistantReply: "我会从这里开始回答。",
    priorUserMessage: "这是上一条连续发送的用户消息。",
  });

  try {
    await page.setViewportSize({ width: 1_299, height: 1_245 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "chat-turn-anchor@comma.local",
      token: "comma_sess_chat_turn_anchor",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    const userText =
      "请仔细分析这个需要跨越多个阶段的长问题，并且确保在窗口变窄、文字重新换行以及回答继续增长时，我刚刚发出的消息仍然能作为这一轮对话的清晰起点；即使内容宽度发生变化，也保持连续消息之间的紧凑间距。";
    await composer.getByRole("textbox", { name: "AI prompt" }).fill(userText);
    await composer.getByRole("button", { name: "Send" }).click();

    const latestTurn = content.getByTestId("chat-latest-turn");
    const chatScrollArea = content.locator(
      '.comma-chat-thread-zone > [data-slot="scroll-area"]'
    );
    const chatViewport = chatScrollArea.locator(
      ':scope > [data-slot="scroll-area-viewport"]'
    );
    const verticalScrollbar = chatScrollArea.locator(
      ':scope > [data-slot="scroll-area-scrollbar"][data-axis="vertical"]'
    );
    const previousUserMessage = content.locator(
      '[data-message-id="msg-prior-user-smoke"]'
    );
    const latestUserMessage = latestTurn.locator(".comma-chat-message-user");
    await expect(previousUserMessage).toHaveCount(1);
    await expect(latestUserMessage).toContainText(userText);
    await expect(latestTurn.locator(".comma-chat-message-assistant")).toContainText(
      "我会从这里开始回答。"
    );

    const readTurnGeometry = () =>
      latestTurn.evaluate((turn) => {
        const viewport = turn
          .closest('[data-slot="scroll-area"]')
          ?.querySelector<HTMLElement>('[data-slot="scroll-area-viewport"]');
        const thread = turn.closest<HTMLElement>(".comma-chat-thread");
        const innerTurn = turn.querySelector<HTMLElement>(":scope > .comma-chat-turn");
        const userMessage = turn.querySelector<HTMLElement>(".comma-chat-message-user");
        if (!viewport || !thread || !innerTurn || !userMessage) {
          throw new Error("Missing chat turn geometry");
        }
        const viewportRect = viewport.getBoundingClientRect();
        const userRect = userMessage.getBoundingClientRect();
        const paddingBottom = Number.parseFloat(getComputedStyle(turn).paddingBottom);
        const reservedHeight = Math.max(
          0,
          turn.clientHeight - innerTurn.scrollHeight - paddingBottom
        );
        return {
          anchorDelta: Math.round(userRect.top - viewportRect.top),
          anchored: turn.classList.contains("comma-chat-latest-turn"),
          meaningfulOverflow: Math.round(
            thread.scrollHeight - reservedHeight - viewport.clientHeight
          ),
          minHeight: Math.round(Number.parseFloat(getComputedStyle(turn).minHeight)),
          paddingBottom,
          rawOverflow: Math.round(viewport.scrollHeight - viewport.clientHeight),
          scrollTop: Math.round(viewport.scrollTop),
          topInset: Math.round(Number.parseFloat(getComputedStyle(thread).paddingTop)),
          userHeight: Math.round(userRect.height),
          viewportHeight: Math.round(viewportRect.height),
        };
      });

    const readPreviousUserBottom = () =>
      previousUserMessage.evaluate((previous) => {
        const viewport = previous
          .closest('[data-slot="scroll-area"]')
          ?.querySelector<HTMLElement>('[data-slot="scroll-area-viewport"]');
        if (!viewport) {
          throw new Error("Missing chat viewport");
        }
        return Math.round(
          previous.getBoundingClientRect().bottom - viewport.getBoundingClientRect().top
        );
      });

    await expect
      .poll(async () => (await readTurnGeometry()).rawOverflow)
      .toBeLessThanOrEqual(1);
    await expect(latestTurn).toHaveCSS("padding-bottom", "48px");
    await expect(latestTurn).not.toHaveAttribute("data-chat-outgoing-turn", "true");
    const wideGeometry = await readTurnGeometry();
    expect(wideGeometry.anchored).toBe(false);
    expect(wideGeometry.paddingBottom).toBe(48);
    expect(wideGeometry.meaningfulOverflow).toBeLessThanOrEqual(1);
    expect(wideGeometry.scrollTop).toBe(0);
    expect(await readPreviousUserBottom()).toBeGreaterThan(0);
    await expect(chatScrollArea).toHaveAttribute("data-has-overflow-y", "false");
    await expect(verticalScrollbar).toHaveCount(0);
    await chatViewport.hover();
    // The browser scrolls a wheel itself, off the main thread, so the driver
    // is not told when it has been spent. Wait until this one has reached the
    // page and a frame has passed, or it can land on the overflow made below.
    // The listener is in place before the wheel is sent: an evaluate that is
    // still starting when the wheel arrives misses it and never settles.
    await chatViewport.evaluate((viewport) => {
      (window as unknown as { wheelSpent: Promise<void> }).wheelSpent = new Promise(
        (resolve) => {
          viewport.addEventListener(
            "wheel",
            () => requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
            { once: true, passive: true }
          );
        }
      );
    });
    await page.mouse.wheel(0, 320);
    await page.evaluate(
      () => (window as unknown as { wheelSpent: Promise<void> }).wheelSpent
    );
    await expect.poll(async () => (await readTurnGeometry()).scrollTop).toBe(0);

    const asyncLayoutGrowth = await page.addStyleTag({
      content: '[data-testid="chat-current-turn"] { min-height: 1200px !important; }',
    });

    await expect
      .poll(async () => (await readTurnGeometry()).rawOverflow)
      .toBeGreaterThan(1);
    await expect(verticalScrollbar).toHaveCount(1);
    await expect(latestTurn).toHaveClass(/comma-chat-latest-turn/);
    await expect
      .poll(async () => {
        const geometry = await readTurnGeometry();
        return geometry.anchorDelta === geometry.topInset;
      })
      .toBe(true);
    await expect
      .poll(readPreviousUserBottom)
      .toBeLessThanOrEqual((await readTurnGeometry()).topInset - 4);

    await asyncLayoutGrowth.evaluate((style) => style.parentNode?.removeChild(style));

    await expect
      .poll(async () => (await readTurnGeometry()).rawOverflow)
      .toBeLessThanOrEqual(1);
    await expect(latestTurn).not.toHaveClass(/comma-chat-latest-turn/);
    await expect(verticalScrollbar).toHaveCount(0);
    await expect.poll(async () => (await readTurnGeometry()).scrollTop).toBe(0);

    await page.setViewportSize({ width: 861, height: 420 });

    await expect
      .poll(async () => (await readTurnGeometry()).meaningfulOverflow)
      .toBeGreaterThan(1);
    await expect(chatScrollArea).toHaveAttribute("data-has-overflow-y", "true");
    await expect(verticalScrollbar).toHaveCount(1);
    await expect
      .poll(async () => {
        const geometry = await readTurnGeometry();
        return geometry.anchorDelta === geometry.topInset;
      })
      .toBe(true);
    await expect
      .poll(readPreviousUserBottom)
      .toBeLessThanOrEqual((await readTurnGeometry()).topInset - 4);
    const overflowGeometry = await readTurnGeometry();
    expect(overflowGeometry.minHeight).toBe(200);
    expect(overflowGeometry.paddingBottom).toBe(48);
    expect(overflowGeometry.scrollTop).toBeGreaterThan(0);

    await page.setViewportSize({ width: 760, height: 420 });

    await expect
      .poll(async () => {
        const geometry = await readTurnGeometry();
        return geometry.anchorDelta === geometry.topInset;
      })
      .toBe(true);
    await expect
      .poll(readPreviousUserBottom)
      .toBeLessThanOrEqual((await readTurnGeometry()).topInset - 4);
    const resizedOverflowGeometry = await readTurnGeometry();
    expect(resizedOverflowGeometry.minHeight).toBe(200);
    expect(resizedOverflowGeometry.paddingBottom).toBe(48);

    await page.addStyleTag({
      content: ".comma-chat-user-bubble { max-width: 180px !important; }",
    });

    await expect
      .poll(async () => (await readTurnGeometry()).userHeight)
      .toBeGreaterThan(resizedOverflowGeometry.userHeight);
    await expect
      .poll(async () => {
        const geometry = await readTurnGeometry();
        return geometry.anchorDelta === geometry.topInset;
      })
      .toBe(true);
    await expect
      .poll(readPreviousUserBottom)
      .toBeLessThanOrEqual((await readTurnGeometry()).topInset - 4);

    const readChatEdgeMask = () =>
      chatScrollArea.evaluate((scrollArea) => {
        const viewport = scrollArea.querySelector<HTMLElement>(
          ':scope > [data-slot="scroll-area-viewport"]'
        );
        if (!viewport) throw new Error("Missing chat viewport");
        const styles = getComputedStyle(viewport);
        return {
          effect: scrollArea.getAttribute("data-edge-effect"),
          end: Number.parseFloat(
            viewport.style.getPropertyValue("--scroll-area-edge-mask-end")
          ),
          maskImage: styles.maskImage,
          start: Number.parseFloat(
            viewport.style.getPropertyValue("--scroll-area-edge-mask-start")
          ),
        };
      });
    await chatViewport.focus();
    await page.keyboard.press("Home");
    await expect.poll(async () => (await readTurnGeometry()).scrollTop).toBe(0);
    await expect.poll(readChatEdgeMask).toMatchObject({
      effect: "mask",
      end: 24,
      start: 0,
    });
    expect((await readChatEdgeMask()).maskImage).toContain("linear-gradient");

    await chatViewport.evaluate((viewport) => {
      viewport.scrollTop = (viewport.scrollHeight - viewport.clientHeight) / 2;
      viewport.dispatchEvent(new Event("scroll", { bubbles: true }));
    });
    await expect.poll(readChatEdgeMask).toMatchObject({ end: 24, start: 16 });

    await page.keyboard.press("End");
    await expect.poll(readChatEdgeMask).toMatchObject({ end: 0, start: 16 });

    // The chat rewraps with the window, not once it settles: the thread opts out
    // of the ScrollArea's window-resize inline-size freeze, so the text follows a
    // window drag exactly as it follows a Chat Sidebar drag. Sampled inside the
    // page — the freeze releases 120ms after the last resize event, which a
    // round-trip read would miss entirely.
    await page.evaluate(() => {
      const samples: { frozen: string | null; width: number }[] = [];
      (
        window as unknown as { commaChatWidthSamples: typeof samples }
      ).commaChatWidthSamples = samples;
      const tick = () => {
        const column = document.querySelector(".comma-chat-column");
        const scrollArea = column?.closest(".comma-scroll-area");
        samples.push({
          frozen: scrollArea?.getAttribute("data-freeze-content-inline-size") ?? null,
          width: Math.round(column?.getBoundingClientRect().width ?? 0),
        });
        if (samples.length < 40) requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    await page.setViewportSize({ width: 1_020, height: 1_245 });
    await page.waitForTimeout(500);
    const widthSamples = await page.evaluate(
      () =>
        (
          window as unknown as {
            commaChatWidthSamples: { frozen: string | null; width: number }[];
          }
        ).commaChatWidthSamples
    );
    expect(widthSamples.length).toBeGreaterThan(5);
    expect(widthSamples.some((sample) => sample.frozen === "true")).toBe(false);
    // Was: every sample a constant 345 — Home's 393px chat floor minus the
    // column's 2x24px padding — because the window drag ate the rails 1:1
    // around a chat column pinned at its floor, which made a constant width the
    // control that isolated the freeze flag. A window drag with no Chat Sidebar
    // open now folds the rail in one transitioned step instead, so the column
    // moves through intermediate widths while the fold plays and no width is
    // constant across the samples. The freeze flag above is the claim; there is
    // no longer a stable width to hold alongside it.
  } finally {
    await stub.close();
  }
});

for (const reducedMotion of [false]) {
  test(`sending reserves the final turn spacing${reducedMotion ? " without motion" : " before the bubble flight"}`, async ({
    page,
  }) => {
    const stub = await startChatSmokeStub({
      assistantReply: "A short reply.",
      priorUserMessage: "Earlier context that fills the conversation. ".repeat(100),
    });
    try {
      await page.emulateMedia({
        reducedMotion: reducedMotion ? "reduce" : "no-preference",
      });
      await page.setViewportSize({ width: 861, height: 600 });
      await installBrowserTestSession(page, {
        apiBaseUrl: stub.baseUrl,
        email: "chat-spacing@comma.local",
        token: "comma_sess_chat_spacing",
      });
      await page.goto("/");
      const content = page.getByRole("region", { name: "Content" });
      const composer = content.locator(".comma-chat-composer");
      await composer.getByRole("textbox", { name: "AI prompt" }).fill("A new question");
      // Sample from the first paint. Space grows with the flight and must
      // reach its final size before the bubble settles.
      await page.evaluate(() => {
        const samples: {
          minHeight: number;
          padding: number;
          landingDelta: number | undefined;
        }[] = [];
        (
          window as unknown as { turnSpacingSamples: typeof samples }
        ).turnSpacingSamples = samples;
        const deadline = performance.now() + 3000;
        const sample = () => {
          const turn = document.querySelector('[data-chat-outgoing-turn="true"]');
          if (turn) {
            const style = getComputedStyle(turn);
            const bubble = turn.querySelector('[data-outgoing-presentation="flying"]');
            const slot = bubble?.closest(".comma-chat-user-bubble-slot");
            samples.push({
              minHeight: parseFloat(style.minHeight),
              padding: parseFloat(style.paddingBottom),
              landingDelta:
                bubble && slot
                  ? Math.abs(
                      bubble.getBoundingClientRect().bottom -
                        slot.getBoundingClientRect().bottom
                    )
                  : undefined,
            });
          }
          if (performance.now() < deadline) requestAnimationFrame(sample);
        };
        requestAnimationFrame(sample);
      });
      await composer.getByRole("button", { name: "Send" }).click();
      const latestTurn = content.getByTestId("chat-latest-turn");
      await expect(latestTurn).toHaveCSS("min-height", "200px");
      await expect(latestTurn).toHaveCSS("padding-bottom", "48px");
      await expect(latestTurn).not.toHaveAttribute("data-chat-outgoing-turn", "true");
      const samples = await page.evaluate(
        () =>
          (
            window as unknown as {
              turnSpacingSamples: {
                minHeight: number;
                padding: number;
                landingDelta: number | undefined;
              }[];
            }
          ).turnSpacingSamples
      );
      expect(samples.length).toBeGreaterThan(0);
      expect(
        samples.every((sample) => sample.padding >= 0 && sample.padding <= 48)
      ).toBe(true);
      expect(
        samples.every((sample) => sample.minHeight >= 0 && sample.minHeight <= 200)
      ).toBe(true);
      if (reducedMotion) {
        expect(samples.every((sample) => sample.padding === 48)).toBe(true);
      } else {
        expect(
          samples.some((sample) => sample.padding > 0 && sample.padding < 48)
        ).toBe(true);
      }
      if (!reducedMotion) {
        // The last painted flight frame must already land in the real slot;
        // clearing the top-layer presentation must not teleport the bubble.
        const landing = samples.findLast((sample) => sample.landingDelta !== undefined);
        expect(landing?.landingDelta).toBeLessThanOrEqual(1);
      }
      const viewport = content.locator(
        '.comma-chat-thread-zone [data-slot="scroll-area-viewport"]'
      );
      await viewport.evaluate((element) => {
        element.scrollTop = element.scrollHeight;
      });
      const bottomGap = await latestTurn.evaluate((turn) => {
        const inner = turn.querySelector(".comma-chat-turn")!;
        const scrollport = turn.closest('[data-slot="scroll-area-viewport"]')!;
        return (
          scrollport.getBoundingClientRect().bottom -
          inner.getBoundingClientRect().bottom
        );
      });
      expect(Math.round(bottomGap)).toBe(48);
    } finally {
      await stub.close();
    }
  });
}

// A modal locks page scroll by writing `overflow` on the document root. The
// document never scrolls, and any new style on the root restyles every
// element, so opening and closing Settings must leave the root style as is.

test("the window bar's Chat sidebar toggle stays clickable on every product route", async ({
  page,
}) => {
  await installBrowserTestSession(page, {
    apiBaseUrl: "http://127.0.0.1:65535",
    email: "hidden-rail@comma.local",
    token: "comma_sess_hidden_rail",
  });
  await page.route("http://127.0.0.1:65535/v1/comma/me/bootstrap", async (route) => {
    await route.fulfill({
      body: JSON.stringify({ error: "forbidden" }),
      contentType: "application/json",
      status: 403,
    });
  });
  // Settings is not in this list: it opens as a modal that owns the pointer,
  // so the bar below it is deliberately out of reach while it is up.
  for (const route of ["/", "/#/inbox", "/#/tasks", "/#/plugins"]) {
    await page.goto(route);

    const toggle = page
      .getByTestId("comma-window-bar")
      .getByRole("button", { name: "New tab" });
    await expect(toggle).toBeVisible();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    // The toggle is a no-drag control of the drag bar, above a panel that
    // paints no drag strip of its own; it is the hit target at its centre.
    await expect
      .poll(() =>
        toggle.evaluate((button) => {
          const rect = button.getBoundingClientRect();
          const bar = button.closest<HTMLElement>('[data-testid="comma-window-bar"]')!;
          const frameRect = document
            .querySelector<HTMLElement>(".comma-window-frame")!
            .getBoundingClientRect();
          const content = document.querySelector<HTMLElement>(".comma-content")!;
          const contentRect = content.getBoundingClientRect();
          return {
            aboveContent: rect.bottom <= contentRect.top,
            appRegion: getComputedStyle(button).getPropertyValue("-webkit-app-region"),
            barAppRegion: getComputedStyle(bar).getPropertyValue("-webkit-app-region"),
            contentAligned: Math.abs(contentRect.right - frameRect.right) < 0.5,
            contentDragStrip: getComputedStyle(content, "::before").content,
            hitTarget: document
              .elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)
              ?.closest("button")
              ?.getAttribute("aria-label"),
          };
        })
      )
      .toEqual({
        aboveContent: true,
        appRegion: "no-drag",
        barAppRegion: "drag",
        contentAligned: true,
        contentDragStrip: "none",
        hitTarget: "New tab",
      });

    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "true");
    const sidebar = page.getByRole("complementary", { name: "Chat" });
    await expect(sidebar).toHaveAttribute("data-open", "true");
    // The sidebar opens inside the panel, beside the route's own surface.
    expect(
      await sidebar.evaluate((element) => Boolean(element.closest(".comma-content")))
    ).toBe(true);
    await expect(sidebar.getByRole("tab", { name: "New tab" })).toBeVisible();
    await expect(sidebar.getByRole("textbox", { name: "Address" })).toBeVisible();
    await toggle.click();
    await expect(toggle).toHaveAttribute("aria-expanded", "false");
    await expect(sidebar).toHaveCount(0);
  }
});

test("a window drag folds the Task details column in step with the window", async ({
  page,
}) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: Array.from(
      { length: 40 },
      (_, index) =>
        `第 ${index + 1} 条 Worker 记录。${"这是一段够长的正文，用来把转录撑过一屏。".repeat(6)}`
    ),
    taskStatus: "completed",
  });
  let labelReads = 0;
  page.on("request", (request) => {
    if (new URL(request.url()).pathname.endsWith("/task-labels")) labelReads += 1;
  });

  try {
    await page.setViewportSize({ width: 1280, height: 800 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "window-fold@comma.local",
      token: "comma_sess_window_fold",
    });
    await page.goto(
      `/#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`
    );
    const body = page.locator(".comma-chat-body");
    await expect(body).toHaveAttribute("data-panel-open", "true");
    await expect(page.getByText("第 40 条 Worker 记录。").last()).toBeVisible();
    // Showing the details reads the Group's label catalog once.
    await expect.poll(() => labelReads).toBeGreaterThan(0);

    // Straddle the column's breakpoint (the route's --container-2xl, 1024px).
    const chrome = await page.evaluate(
      () =>
        window.innerWidth -
        document.querySelector(".comma-chat-route")!.getBoundingClientRect().width
    );
    const wide = Math.ceil(1024 + chrome) + 8;
    const narrow = wide - 16;
    await page.setViewportSize({ width: wide, height: 800 });
    await expect(body).toHaveAttribute("data-panel-open", "true");
    await page.waitForTimeout(700);
    const readsBeforeDrag = labelReads;

    const cdp = await page.context().newCDPSession(page);
    const restyled: number[] = [];
    cdp.on("Tracing.dataCollected", ({ value }) => {
      for (const event of value as {
        args?: { elementCount?: number };
        name?: string;
      }[])
        if (event.name === "UpdateLayoutTree" && event.args?.elementCount)
          restyled.push(event.args.elementCount);
    });
    const tracingDone = new Promise<void>((resolve) =>
      cdp.once("Tracing.tracingComplete", () => resolve())
    );
    await cdp.send("Tracing.start", {
      categories: "devtools.timeline",
      transferMode: "ReportEvents",
    });
    await page.evaluate(() => {
      const panel = document.querySelector('[data-testid="task-details-panel"]')!;
      const widths: number[] = [];
      let sampling = true;
      const sample = () => {
        widths.push(Math.round(panel.getBoundingClientRect().width));
        if (sampling) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
      (window as Window & { commaTaskPanelSamples?: unknown }).commaTaskPanelSamples = {
        stop: () => {
          sampling = false;
          return widths;
        },
      };
    });
    // A hand dragging the window edge back and forth across the breakpoint.
    for (let pass = 0; pass < 3; pass += 1) {
      await page.setViewportSize({ width: narrow, height: 800 });
      await expect(body).toHaveAttribute("data-panel-open", "false");
      await page.waitForTimeout(80);
      await page.setViewportSize({ width: wide, height: 800 });
      await expect(body).toHaveAttribute("data-panel-open", "true");
      await page.waitForTimeout(80);
    }
    const widths = await page.evaluate(() =>
      (
        window as Window & { commaTaskPanelSamples?: { stop: () => number[] } }
      ).commaTaskPanelSamples!.stop()
    );
    await cdp.send("Tracing.end");
    await tracingDone;

    // The column is either there or folded in every frame: the fold lands in
    // the frame the window crosses the breakpoint, with no track transition
    // chasing the edge. Was: a 150ms grid transition played every crossing.
    const openWidth = widths[0]!;
    expect(openWidth).toBeGreaterThan(0);
    expect(widths).toContain(0);
    expect(widths.filter((width) => width !== 0 && width !== openWidth)).toEqual([]);
    // A fold restyles the grid it changes, not the transcript inside it. Was:
    // an inherited custom property flipped on the body restyled every node of
    // the thread in the frame of each crossing.
    const threadNodes = await page
      .locator(".comma-chat-main")
      .evaluate((main) => main.querySelectorAll("*").length);
    expect(Math.max(...restyled)).toBeLessThan(threadNodes / 4);
    // Width is not a new look at the Task: unfolding reads nothing more.
    expect(labelReads).toBe(readsBeforeDrag);
  } finally {
    await stub.close();
  }
});

// The settings modal scales in from 95%, so every rect read while it is still
// entering comes back short. Wait for the card to reach its resting transform.
async function expectSettledSettingsModal(page: Page) {
  const dialog = page.getByRole("dialog", { name: "Settings sections" });
  await expect(dialog).toBeVisible();
  await expect
    .poll(() =>
      dialog.evaluate((element) => getComputedStyle(element.parentElement!).transform)
    )
    .toBe("none");
  return dialog;
}

// Firefox only (the app-shell-firefox-icon-geometry project): on Chromium the
// test runs on the test clock in e2e/app-shell/shell-layout.chromium.test.ts.
test("font size preference scales core conversation typography without changing icon geometry", async ({
  browserName,
  page,
}) => {
  test.skip(browserName !== "firefox", "Chromium runs it on the test clock");
  const stub = await startChatSmokeStub({
    taskAssistantReply: "Core conversation typography",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "font-size@comma.local",
      token: "comma_sess_font_size",
    });
    const conversationUrl = `/#/inbox/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}`;
    await page.goto(conversationUrl);

    const assistantMessage = page.locator(".comma-chat-message-assistant").first();
    await expect(assistantMessage).toBeVisible();
    const defaultFontSize = await assistantMessage.evaluate((element) =>
      Number.parseFloat(getComputedStyle(element).fontSize)
    );

    await page.goto("/#/settings");
    await expectSettledSettingsModal(page);
    await expect(page.locator("html")).toHaveAttribute(
      "data-comma-font-size",
      "default"
    );
    const computerUseButton = page.getByRole("button", { name: "Computer use" });
    const mixedStrokeIcon = computerUseButton.locator("svg[data-comma-icon]");
    await expect(mixedStrokeIcon).toBeVisible();
    const readMixedStrokeIcon = () =>
      mixedStrokeIcon.evaluate((element) => {
        const readStroke = (nominal: string) => {
          const shape = element.querySelector(`[stroke-width="${nominal}"]`);
          if (!shape) throw new Error(`Missing stroke-width=${nominal}`);
          const computed = getComputedStyle(shape).getPropertyValue("stroke-width");
          return {
            computed: Number(computed.match(/[\d.]+/)?.[0]),
            nominal: Number(shape.getAttribute("stroke-width")),
          };
        };

        return {
          stroke075: readStroke("0.75"),
          stroke2: readStroke("2"),
          globalStroke: Number(
            getComputedStyle(element).getPropertyValue("--comma-icon-stroke-width")
          ),
          scale: getComputedStyle(element).scale,
          width: element.getBoundingClientRect().width,
        };
      });
    const readActionRect = () =>
      computerUseButton.evaluate((element) => {
        const { height, width } = element.getBoundingClientRect();
        return {
          clientHeight: element.clientHeight,
          height,
          scrollHeight: element.scrollHeight,
          rootFontSize: Number.parseFloat(
            getComputedStyle(document.documentElement).fontSize
          ),
          width,
        };
      });
    const defaultIcon = await readMixedStrokeIcon();
    expect(defaultIcon.globalStroke).toBe(iconStrokeWidth);
    expect(defaultIcon.scale).toBe("1");
    expect(defaultIcon.stroke2.computed).toBeCloseTo(iconStrokeWidth, 4);
    expect(defaultIcon.stroke075.computed).toBeCloseTo(0.75, 4);
    const defaultActionRect = await readActionRect();
    // Compact category rows are 1.75rem, so their height follows font size.
    // Labels must remain contained while icon geometry stays unchanged.
    expect(defaultActionRect.height).toBeCloseTo(
      1.75 * defaultActionRect.rootFontSize,
      1
    );
    expect(defaultActionRect.scrollHeight).toBeLessThanOrEqual(
      defaultActionRect.clientHeight
    );

    await page.getByRole("button", { name: "Appearance" }).click();
    await page.getByRole("button", { name: /Select font size/ }).click();
    await page.getByRole("option", { name: "Small" }).click();
    await expect(page.locator("html")).toHaveAttribute("data-comma-font-size", "small");
    await expect
      .poll(async () => (await readMixedStrokeIcon()).width)
      .toBeCloseTo(defaultIcon.width, 1);
    const smallIcon = await readMixedStrokeIcon();
    expect(smallIcon.globalStroke).toBe(iconStrokeWidth);
    expect(smallIcon.scale).toBe("1");
    expect(smallIcon.stroke2.nominal).toBe(defaultIcon.stroke2.nominal);
    expect(smallIcon.stroke075.nominal).toBe(defaultIcon.stroke075.nominal);
    expect(smallIcon.stroke2.computed).toBeCloseTo(defaultIcon.stroke2.computed, 4);
    expect(smallIcon.stroke075.computed).toBeCloseTo(0.75, 4);
    const smallActionRect = await readActionRect();
    expect(smallActionRect.width).toBe(defaultActionRect.width);
    expect(smallActionRect.height).toBeCloseTo(1.75 * smallActionRect.rootFontSize, 1);
    expect(smallActionRect.scrollHeight).toBeLessThanOrEqual(
      smallActionRect.clientHeight
    );

    await page.getByRole("button", { name: /Select font size/ }).click();
    await page.getByRole("option", { name: "Large" }).click();
    await expect(page.locator("html")).toHaveAttribute("data-comma-font-size", "large");
    await expect
      .poll(async () => (await readMixedStrokeIcon()).width)
      .toBeCloseTo(defaultIcon.width, 1);
    const largeIcon = await readMixedStrokeIcon();
    expect(largeIcon.globalStroke).toBe(iconStrokeWidth);
    expect(largeIcon.scale).toBe("1");
    expect(largeIcon.stroke2.nominal).toBe(defaultIcon.stroke2.nominal);
    expect(largeIcon.stroke075.nominal).toBe(defaultIcon.stroke075.nominal);
    expect(largeIcon.stroke2.computed).toBeCloseTo(defaultIcon.stroke2.computed, 4);
    expect(largeIcon.stroke075.computed).toBeCloseTo(0.75, 4);
    const largeActionRect = await readActionRect();
    expect(largeActionRect.width).toBe(defaultActionRect.width);
    expect(largeActionRect.height).toBeCloseTo(1.75 * largeActionRect.rootFontSize, 1);
    expect(largeActionRect.scrollHeight).toBeLessThanOrEqual(
      largeActionRect.clientHeight
    );

    const fontSizeTrigger = page.getByRole("button", { name: /Select font size/ });
    const dropdownCollisionPadding = await page
      .locator("html")
      .evaluate((element) =>
        Number.parseFloat(getComputedStyle(element).getPropertyValue("--spacing-lg"))
      );
    await fontSizeTrigger.click();
    const selectedLargeOption = page.getByRole("option", { name: "Large" });
    await expect
      .poll(() =>
        Promise.all([
          fontSizeTrigger.evaluate((element) => element.getBoundingClientRect().top),
          selectedLargeOption.evaluate(
            (element) => element.getBoundingClientRect().top
          ),
        ]).then(([triggerTop, optionTop]) => Math.abs(optionTop - triggerTop))
      )
      .toBeLessThanOrEqual(1);
    await page.keyboard.press("Escape");
    await expect(fontSizeTrigger).toHaveAttribute("aria-expanded", "false");
    await expect(page.locator('[data-slot="dropdown-popover"]')).toHaveCount(0);

    await page.setViewportSize({ width: 1280, height: 180 });
    await fontSizeTrigger.evaluate((element, targetTop) => {
      const panel = element.closest('[data-slot="settings-panel"]');
      const viewport = panel?.querySelector<HTMLElement>(
        '[data-slot="scroll-area-viewport"]'
      );

      if (!viewport) {
        throw new Error("Missing Settings scroll viewport");
      }

      viewport.scrollTop += element.getBoundingClientRect().top - targetTop;
    }, dropdownCollisionPadding);
    await expect
      .poll(() =>
        fontSizeTrigger.evaluate((element) => element.getBoundingClientRect().top)
      )
      .toBeLessThanOrEqual(dropdownCollisionPadding + 1);

    await fontSizeTrigger.click();
    const constrainedPopover = page.locator('[data-slot="dropdown-popover"]');
    await expect(constrainedPopover).toHaveAttribute(
      "data-viewport-constrained",
      "true"
    );
    await expect
      .poll(() =>
        constrainedPopover.evaluate((element) => element.getBoundingClientRect().top)
      )
      .toBeGreaterThanOrEqual(dropdownCollisionPadding - 1);

    await waitForSettledMotion(constrainedPopover);
    await expect(
      page.getByRole("option", { name: "Large", exact: true })
    ).toBeFocused();
    await page.keyboard.press("ArrowUp");
    await page.keyboard.press("ArrowUp");
    const firstFontSizeOption = page.getByRole("option", { name: "Small" });
    await expect(firstFontSizeOption).toBeFocused();
    // The list scrolls the focused option into view after the key press; the
    // claim is where the option ends up, not where it is mid-scroll.
    const optionRect = () =>
      firstFontSizeOption.evaluate((element) => {
        const { bottom, top } = element.getBoundingClientRect();
        return { bottom, top };
      });
    await expect
      .poll(async () => (await optionRect()).top)
      .toBeGreaterThanOrEqual(dropdownCollisionPadding - 1);
    expect((await optionRect()).bottom).toBeLessThanOrEqual(
      page.viewportSize()!.height - dropdownCollisionPadding + 1
    );
    await page.keyboard.press("Enter");
    await expect(page.locator("html")).toHaveAttribute("data-comma-font-size", "small");

    await fontSizeTrigger.click();
    await page.getByRole("option", { name: "Large" }).click();
    await expect(page.locator("html")).toHaveAttribute("data-comma-font-size", "large");
    await page.setViewportSize({ width: 1280, height: 800 });

    await page.goto(conversationUrl);

    await expect
      .poll(() =>
        assistantMessage.evaluate((element) =>
          Number.parseFloat(getComputedStyle(element).fontSize)
        )
      )
      .toBeGreaterThan(defaultFontSize);
  } finally {
    await stub.close();
  }
});

test("Appearance Custom theme is edited from Settings and restored after reload", async ({
  page,
}) => {
  const stub = await startChatSmokeStub();

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "custom-theme@comma.local",
      token: "comma_sess_custom_theme",
    });
    await page.goto("/#/settings");
    await page.getByRole("button", { name: "Appearance" }).click();
    const themeTrigger = page.getByRole("button", { name: /Select theme/ });
    await themeTrigger.click();
    const selectedThemeOption = page.getByRole("option", { name: "Default" });
    await expect(themeTrigger).toHaveClass(/opacity-0/);
    await expect(page.locator('[data-slot="dropdown-popover"]')).toHaveAttribute(
      "data-positioning",
      "selection-aligned"
    );
    await expect
      .poll(() =>
        Promise.all([
          themeTrigger.evaluate((element) => element.getBoundingClientRect().top),
          selectedThemeOption.evaluate(
            (element) => element.getBoundingClientRect().top
          ),
        ]).then(([triggerTop, optionTop]) => Math.abs(optionTop - triggerTop))
      )
      .toBeLessThanOrEqual(1);
    const customOption = page.getByRole("option", { name: "Custom" });
    await customOption.click();

    const studio = page.getByRole("dialog", { name: "Custom", exact: true });
    await expect(studio).toBeVisible();
    await expect(customOption).toBeHidden();
    await waitForSettledMotion(studio);
    await expect(themeTrigger).toHaveAttribute("aria-label", "Select theme: Custom");
    const back = studio.getByRole("button", { name: "Back to themes" });
    await expect(back).toBeFocused();

    // The studio popover raises its own focus scope inside the settings modal,
    // and both scopes step the first Tab, so it skips Auto. Light and Dark come
    // before the channel row.
    for (let step = 0; step < 5; step += 1) await page.keyboard.press("Tab");
    const keyboardHue = studio.getByRole("slider", { name: "Hue" });
    await expect(keyboardHue).toBeFocused();
    const keyboardHueStart = Number(await keyboardHue.getAttribute("aria-valuenow"));
    await page.keyboard.press("ArrowUp");
    await expect(keyboardHue).toHaveAttribute(
      "aria-valuenow",
      String(keyboardHueStart + 1)
    );
    await page.keyboard.press("ArrowDown");
    await expect(keyboardHue).toHaveAttribute(
      "aria-valuenow",
      String(keyboardHueStart)
    );
    await page.keyboard.press("ArrowRight");
    await expect(keyboardHue).toHaveAttribute(
      "aria-valuenow",
      String(keyboardHueStart + 1)
    );
    await page.keyboard.press("ArrowLeft");
    await expect(keyboardHue).toHaveAttribute(
      "aria-valuenow",
      String(keyboardHueStart)
    );
    await page.keyboard.press("Home");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "0");
    await page.keyboard.press("ArrowLeft");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "0");
    await page.keyboard.press("ArrowDown");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "0");
    await page.keyboard.press("End");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "360");
    await page.keyboard.press("ArrowRight");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "360");
    await page.keyboard.press("ArrowUp");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "360");
    await expect(keyboardHue).toHaveAttribute("aria-valuemax", "360");
    await page.keyboard.press("Home");
    await expect(keyboardHue).toHaveAttribute("aria-valuenow", "0");
    for (let step = 0; step < 6; step += 1) await page.keyboard.press("Shift+Tab");
    await expect(back).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(page.locator('[data-slot="menu-popover"]')).toHaveCount(0);
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
        })
    );
    await expect(page.locator('[data-slot="dropdown-popover"]')).toHaveAttribute(
      "data-anchor-index",
      "5"
    );
    await expect(customOption).toBeFocused();
    await page.keyboard.press("ArrowUp");
    const signalDarkOption = page.getByRole("option", { name: "Signal Dark" });
    await expect(signalDarkOption).toBeFocused();

    // Return to Custom for the rest of this scenario after the keyboard-only path.
    await signalDarkOption.click();
    await themeTrigger.click();
    await customOption.click();
    await expect(studio).toBeVisible();

    // Mutation records retain intermediate values, including a synchronous
    // clear-and-restore that a final DOM assertion or frame sample would miss.
    const themeMutations = await page.evaluateHandle(() => {
      const records: MutationRecord[] = [];
      const observer = new MutationObserver((mutations) => records.push(...mutations));
      observer.observe(document.documentElement, {
        attributes: true,
        attributeOldValue: true,
        attributeFilter: [
          "data-theme",
          "data-comma-theme",
          "data-comma-font-size",
          "data-comma-pointer-cursors",
          "data-comma-reduced-motion",
          "style",
        ],
      });
      return { observer, records };
    });

    await studio.getByRole("button", { name: "Light" }).click();

    const lightness = studio.getByRole("slider", { name: "Lightness" });
    const chroma = studio.getByRole("slider", { name: "Chroma" });
    const hue = studio.getByRole("slider", { name: "Hue" });
    await lightness.focus();
    const lightnessBefore = await lightness.getAttribute("aria-valuenow");
    await page.keyboard.press("End");
    await expect(lightness).not.toHaveAttribute("aria-valuenow", lightnessBefore ?? "");
    await expect(lightness).toHaveAttribute(
      "aria-valuenow",
      String(Math.round(commaThemeLightnessMax * 100))
    );

    const description = studio.getByText(
      "Drag any indicator to move the color. The other two follow on their own planes."
    );
    expect(await contrastOfPrimaryTextOnPrimaryBg(page)).toBeGreaterThanOrEqual(4.5);
    expect(await contrastAgainstPaintedBackground(description)).toBeGreaterThanOrEqual(
      3
    );

    await hue.focus();
    const hueBeforeKeyboard = await hue.getAttribute("aria-valuenow");
    await page.keyboard.press("ArrowRight");
    await expect(hue).not.toHaveAttribute("aria-valuenow", hueBeforeKeyboard ?? "");

    await chroma.focus();
    const chromaBeforeKeyboard = await chroma.getAttribute("aria-valuenow");
    await page.keyboard.press("ArrowUp");
    await expect(chroma).not.toHaveAttribute(
      "aria-valuenow",
      chromaBeforeKeyboard ?? ""
    );

    await studio.getByRole("button", { name: "Dark" }).click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "Dark mode");
    await lightness.focus();
    await page.keyboard.press("Home");
    await expect(lightness).toHaveAttribute(
      "aria-valuenow",
      String(Math.round(commaThemeLightnessMin * 100))
    );
    expect(await contrastOfPrimaryTextOnPrimaryBg(page)).toBeGreaterThanOrEqual(4.5);
    expect(await contrastAgainstPaintedBackground(description)).toBeGreaterThanOrEqual(
      3
    );

    const pad = studio.getByRole("group", { name: "Hue, chroma, and lightness pad" });
    const box = await pad.boundingBox();
    expect(box).not.toBeNull();
    // The mode switch sits above the pad, so it never covers an indicator.
    const schemeBox = await studio.getByRole("button", { name: "Auto" }).boundingBox();
    expect(schemeBox!.y + schemeBox!.height).toBeLessThanOrEqual(box!.y);
    const channelValues = async () => ({
      chroma: await chroma.getAttribute("aria-valuenow"),
      hue: await hue.getAttribute("aria-valuenow"),
      lightness: await lightness.getAttribute("aria-valuenow"),
    });
    const beforeDrag = await channelValues();
    // Restyling the app restyles the whole document (about 250 ms with Settings
    // open), so a drag previews in the studio and writes the theme on release.
    const dragThemeWrites = await page.evaluateHandle(() => {
      const root = document.documentElement;
      const read = () =>
        ["--comma-theme-h", "--comma-theme-c", "--comma-theme-l"]
          .map((property) => root.style.getPropertyValue(property))
          .join(" ");
      const state = {
        count: 0,
        last: read(),
        observer: null as MutationObserver | null,
      };
      state.observer = new MutationObserver(() => {
        const next = read();
        if (next === state.last) return;
        state.last = next;
        state.count += 1;
      });
      state.observer.observe(root, { attributes: true, attributeFilter: ["style"] });
      return state;
    });
    await page.mouse.move(box!.x + box!.width * 0.2, box!.y + box!.height * 0.55);
    await page.mouse.down();
    await page.mouse.move(box!.x + box!.width * 0.85, box!.y + box!.height * 0.2, {
      steps: 8,
    });
    const duringDrag = await channelValues();
    expect(duringDrag).not.toEqual(beforeDrag);
    expect(await dragThemeWrites.evaluate((state) => state.count)).toBe(0);
    await page.mouse.up();
    await expect.poll(() => dragThemeWrites.evaluate((state) => state.count)).toBe(1);
    await dragThemeWrites.evaluate((state) => state.observer?.disconnect());
    await dragThemeWrites.dispose();
    expect(await channelValues()).toEqual(duringDrag);
    expect(
      await page.evaluate(() =>
        Math.round(
          Number.parseFloat(
            document.documentElement.style.getPropertyValue("--comma-theme-h")
          )
        )
      )
    ).toBe(Number(duringDrag.hue));

    const themeGaps = await themeMutations.evaluate(({ observer, records }) => {
      records.push(...observer.takeRecords());
      observer.disconnect();
      const styleProbe = document.createElement("div");
      return records
        .filter((record) => {
          if (record.attributeName !== "style") return record.oldValue === null;
          styleProbe.setAttribute("style", record.oldValue ?? "");
          return ["--comma-theme-h", "--comma-theme-c", "--comma-theme-l"].some(
            (property) => !styleProbe.style.getPropertyValue(property)
          );
        })
        .map((record) => ({ attribute: record.attributeName, value: record.oldValue }));
    });
    await themeMutations.dispose();
    expect(themeGaps).toEqual([]);

    await studio.getByRole("button", { name: "Auto" }).click();
    await page.emulateMedia({ colorScheme: "dark" });
    await expect(page.locator("html")).toHaveAttribute("data-theme", "Dark mode");
    const stored = await page.evaluate(
      () =>
        JSON.parse(localStorage.getItem("comma.client-settings") ?? "null")?.appearance
    );
    expect(stored).toMatchObject({
      theme: "custom",
      customScheme: "system",
    });

    await page.reload();
    await expect(page.locator("html")).toHaveAttribute("data-theme", "Dark mode");
    await page.emulateMedia({ colorScheme: "light" });
    await expect(page.locator("html")).toHaveAttribute("data-theme", "Light mode");
    await page.getByRole("button", { name: "Appearance" }).click();
    await expect(page.getByRole("button", { name: /Select theme/ })).toHaveAttribute(
      "aria-label",
      "Select theme: Custom"
    );
    await expect(page.getByRole("button", { name: /Select theme/ })).toContainText(
      "Custom"
    );
    await page.getByRole("button", { name: /Select theme/ }).click();
    await expect(
      page.getByRole("dialog", { name: "Custom", exact: true })
    ).toBeVisible();
    const restored = await page.evaluate(
      () =>
        JSON.parse(localStorage.getItem("comma.client-settings") ?? "null")?.appearance
    );
    expect(restored).toMatchObject({
      theme: "custom",
      customScheme: "system",
      customHue: stored.customHue,
      customChroma: stored.customChroma,
      customLightness: stored.customLightness,
    });
  } finally {
    await stub.close();
  }
});
