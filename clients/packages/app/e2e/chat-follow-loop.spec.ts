import { expect, test } from "@playwright/test";
import { installBrowserTestSession } from "../../../e2e/helpers/browser-auth";
import {
  chatSmokeTaskConversation,
  chatSmokeWorkspace,
  startChatSmokeStub,
} from "../../../e2e/p0/chat-stub";

test("a downward wheel reads a long reply without jumping to its tail", async ({
  page,
}) => {
  const assistantReply = Array.from(
    { length: 24 },
    (_, index) => `这是用于滚动回归的第 ${index + 1} 段回答。`
  ).join("\n\n");
  const stub = await startChatSmokeStub({
    assistantReply,
    priorAssistantReply: "这是更早一轮已经完成的回答。",
    priorUserMessage: "这是更早一轮的用户问题。",
  });

  try {
    await page.setViewportSize({ width: 1_000, height: 600 });
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "follow-loop-downward@comma.local",
      token: "comma_sess_follow_loop_downward",
    });
    await page.goto("/");

    const content = page.getByRole("region", { name: "Content" });
    const composer = content.locator(".comma-chat-composer");
    await composer
      .getByRole("textbox", { name: "AI prompt" })
      .fill("请生成足够长的回复用于滚动测试。");
    await composer.getByRole("button", { name: "Send" }).click();
    await expect(content.getByText("这是用于滚动回归的第 24 段回答。")).toBeVisible();

    const viewport = content.locator(".comma-chat-scroll-viewport");
    const readScrollTop = () => viewport.evaluate((node) => node.scrollTop);
    const distanceFromTail = () =>
      viewport.evaluate(
        (node) => node.scrollHeight - node.clientHeight - node.scrollTop
      );
    // Finish the outgoing animation before the reader starts a new gesture.
    await page.waitForTimeout(1_250);
    await expect.poll(distanceFromTail).toBeGreaterThan(250);
    const restingScrollTop = await readScrollTop();
    await viewport.hover();
    await page.mouse.wheel(0, 40);
    await expect.poll(readScrollTop).toBeCloseTo(restingScrollTop + 40, 0);

    // Settlement must not restore the old anchor after the reader moves down.
    await page.waitForTimeout(1_250);
    expect(await readScrollTop()).toBeCloseTo(restingScrollTop + 40, 0);

    const growReply = () =>
      viewport.evaluate(async (node) => {
        const reply = node.querySelector<HTMLElement>(
          '[data-chat-latest-turn="true"] .comma-chat-message-assistant:last-of-type'
        );
        if (!reply) throw new Error("Missing the latest reply");
        const previousHeight = node.scrollHeight;
        reply.style.minHeight = `${Math.ceil(reply.getBoundingClientRect().height) + 48}px`;
        await new Promise((resolve) => requestAnimationFrame(resolve));
        await new Promise((resolve) => requestAnimationFrame(resolve));
        return node.scrollHeight - previousHeight;
      });
    // Content can still grow after the reader starts reading this reply.
    expect(await growReply()).toBeGreaterThanOrEqual(47);
    expect(await readScrollTop()).toBeCloseTo(restingScrollTop + 40, 0);

    // Reaching the real tail must still resume following later content growth.
    await page.mouse.wheel(0, 10_000);
    await expect.poll(distanceFromTail).toBeLessThanOrEqual(1);
    expect(await growReply()).toBeGreaterThanOrEqual(47);
    await expect.poll(distanceFromTail).toBeLessThanOrEqual(1);
  } finally {
    await stub.close();
  }
});

/**
 * What the stick-to-bottom follow loop is allowed to cost while the newest
 * turn grows.
 *
 * That turn is the only one in a thread that keeps resizing — streamed text,
 * the activity line, a task panel gaining rows — so its ResizeObserver fires
 * about once a frame. ConversationThread renders the thread, the latest turn
 * shell and its inner turn, and hands those elements to the loop; re-finding
 * them by attribute selector instead would walk the whole mounted transcript
 * on every one of those ticks, which is why scrolling near a live turn used to
 * stutter in proportion to how much history was mounted.
 *
 * A Worker transcript is the sharpest surface for it: the whole conversation
 * mounts as one agent-authored turn, so the newest turn is both the tallest
 * thing on screen and the thing being resized.
 */
test("following the newest turn rescans nothing while it grows", async ({ page }) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: Array.from(
      { length: 60 },
      (_, index) =>
        `第 ${index + 1} 条 Worker 记录。${"这是一段够长的正文，用来把转录撑过一屏。".repeat(8)}`
    ),
    taskSchedule: null,
    taskStatus: "completed",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "follow-loop@comma.local",
      token: "comma_sess_follow_loop",
    });
    // Counted from before the app loads so nothing in the thread's lifetime is
    // missed. Only selectors that name a turn are counted: those are the ones
    // whose match lives at the end of the transcript, so they can never exit
    // early and always cost a full subtree walk.
    await page.addInitScript(() => {
      const counts = { scans: 0 };
      (
        window as unknown as { commaFollowLoopProbe: typeof counts }
      ).commaFollowLoopProbe = counts;
      const namesATurn = /data-chat-turn-anchor|data-chat-latest-turn/;
      const querySelector = Element.prototype.querySelector;
      const querySelectorAll = Element.prototype.querySelectorAll;
      Element.prototype.querySelector = function (selector: string) {
        if (namesATurn.test(selector)) counts.scans += 1;
        return querySelector.call(this, selector) as never;
      };
      Element.prototype.querySelectorAll = function (selector: string) {
        if (namesATurn.test(selector)) counts.scans += 1;
        return querySelectorAll.call(this, selector) as never;
      };
    });
    await page.goto("/");

    await page.locator('[data-slot="task-card"]').first().click();
    await expect(page).toHaveURL(
      new RegExp(
        `#/tasks/${chatSmokeWorkspace.id}/${chatSmokeWorkspace.group_id}/${chatSmokeTaskConversation.id}$`
      )
    );

    const content = page.getByRole("region", { name: "Content" });
    const viewport = content.locator(".comma-chat-scroll-viewport:visible");
    await expect(content.getByText("第 60 条 Worker 记录。").last()).toBeVisible();
    await expect(viewport).toHaveCount(1);
    // Let the thread settle: mount and the first reveal legitimately resolve
    // turns, and this test is about the steady state that follows them.
    await page.waitForTimeout(800);

    const growth = await viewport.evaluate(async (node) => {
      const probe = (window as unknown as { commaFollowLoopProbe: { scans: number } })
        .commaFollowLoopProbe;
      const shell = node.querySelector<HTMLElement>('[data-chat-latest-turn="true"]');
      const grown = shell?.querySelector<HTMLElement>(
        ".comma-chat-message-assistant:last-of-type"
      );
      if (!shell || !grown) throw new Error("Missing the latest turn to grow");

      // Grow an existing message rather than appending one: the turn resizes
      // exactly as streamed content resizes it, without changing which child
      // is last and disturbing the thread's structural CSS.
      const baseHeight = grown.getBoundingClientRect().height;
      const step = 12;
      const ticks = 20;
      const startingMaxScrollTop = Math.round(node.scrollHeight - node.clientHeight);
      const distancesFromBottom: number[] = [];
      probe.scans = 0;
      for (let tick = 1; tick <= ticks; tick += 1) {
        grown.style.minHeight = `${Math.round(baseHeight) + tick * step}px`;
        // Two frames: the observer delivers after the first, the follow write
        // it makes is settled by the second.
        await new Promise((resolve) => requestAnimationFrame(resolve));
        await new Promise((resolve) => requestAnimationFrame(resolve));
        distancesFromBottom.push(
          Math.round(node.scrollHeight - node.clientHeight - node.scrollTop)
        );
      }
      const endingMaxScrollTop = Math.round(node.scrollHeight - node.clientHeight);
      grown.style.removeProperty("min-height");

      return {
        distancesFromBottom,
        grew: endingMaxScrollTop - startingMaxScrollTop,
        scans: probe.scans,
        step,
        ticks,
      };
    });

    // The turn really did resize under the observer on every tick, so the
    // assertions below are about a loop that ran, not one that never woke.
    expect(growth.grew).toBeGreaterThanOrEqual(growth.ticks * growth.step - 1);
    // It ran without ever going looking for a turn.
    expect(growth.scans).toBe(0);
    // And it still followed. This transcript is agent-authored throughout and
    // opens pinned to its tail, so following means the tail stays under the
    // reader as the turn grows; a loop that lost the element it writes for
    // would let every tick's new pixels push the bottom away.
    // The newest-turn-top rule, which the same call resolves, is covered by
    // shell-layout.spec.ts "automatic chat following stays hidden while native
    // wheel remains visible".
    for (const [index, distance] of growth.distancesFromBottom.entries()) {
      expect(
        distance,
        `the thread fell behind its tail on tick ${index + 1}`
      ).toBeLessThanOrEqual(1);
    }
  } finally {
    await stub.close();
  }
});

/**
 * Every code block and table in a reply is its own horizontal scroller. A
 * vertical wheel over one still moves the transcript, so it is still the
 * reader leaving the tail. While that wheel was read as the nested scroller's
 * own, following stayed on: the next resize of the newest turn wrote the
 * viewport back to the tail, and the reader's every step up was undone — with
 * the thread's tail edge state, and the restyle it carries, flipping each time.
 */
test("a wheel over a code block leaves the tail and stays away", async ({ page }) => {
  const stub = await startChatSmokeStub({
    includeTaskInInbox: true,
    taskAssistantMessages: Array.from({ length: 30 }, (_, index) =>
      [
        `第 ${index + 1} 条 Worker 记录。${"这是一段够长的正文。".repeat(6)}`,
        "",
        "```ts",
        `export const step${index} = ${index};`,
        "```",
      ].join("\n")
    ),
    taskSchedule: null,
    taskStatus: "completed",
  });

  try {
    await installBrowserTestSession(page, {
      apiBaseUrl: stub.baseUrl,
      email: "follow-loop-code-block@comma.local",
      token: "comma_sess_follow_loop_code_block",
    });
    await page.goto("/");

    await page.locator('[data-slot="task-card"]').first().click();
    const content = page.getByRole("region", { name: "Content" });
    const viewport = content.locator(".comma-chat-scroll-viewport:visible");
    await expect(content.getByText("第 30 条 Worker 记录。").last()).toBeVisible();
    await expect(viewport).toHaveCount(1);
    await page.waitForTimeout(800);

    const distanceFromTail = () =>
      viewport.evaluate((node) =>
        Math.round(node.scrollHeight - node.clientHeight - node.scrollTop)
      );
    expect(await distanceFromTail()).toBeLessThanOrEqual(1);

    // The pointer rests on the newest reply's code block, inside its scroller.
    const codeScroller = viewport
      .locator('[data-slot="scroll-area"][data-orientation="horizontal"]')
      .last();
    await codeScroller.hover();
    await page.mouse.wheel(0, -240);
    await expect.poll(distanceFromTail).toBeGreaterThanOrEqual(200);

    // The newest turn keeps resizing, as a streamed reply does. A thread that
    // is still following answers each resize by returning to the tail.
    await viewport.evaluate(async (node) => {
      const grown = node.querySelector<HTMLElement>(
        '[data-chat-latest-turn="true"] .comma-chat-message-assistant:last-of-type'
      );
      if (!grown) throw new Error("Missing the latest message to grow");
      const baseHeight = grown.getBoundingClientRect().height;
      for (let tick = 1; tick <= 6; tick += 1) {
        grown.style.minHeight = `${Math.round(baseHeight) + tick * 12}px`;
        await new Promise((resolve) => requestAnimationFrame(resolve));
        await new Promise((resolve) => requestAnimationFrame(resolve));
      }
    });
    expect(await distanceFromTail()).toBeGreaterThanOrEqual(200);
  } finally {
    await stub.close();
  }
});
