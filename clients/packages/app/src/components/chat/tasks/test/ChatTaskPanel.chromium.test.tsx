import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import { initializeCommaI18n } from "@comma/i18n";
import { cleanup, render } from "@comma/test-utils/render";
import { afterEach, expect, it, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import { ChatTaskPanel } from "../ChatTaskPanel";
import type { ChatCreatedTask } from "../useChatCreatedTasks";

afterEach(() => {
  cleanup();
  document.documentElement.style.removeProperty("--text-sm--line-height");
  document.body.replaceChildren();
});

const task = (index: number): ChatCreatedTask => ({
  archiveVersion: undefined,
  conversationId: `cnv_task_${index}`,
  messageId: undefined,
  needsAttention: false,
  needsInput: false,
  loopStop: undefined,
  statusBucket: "in_progress",
  title: `Task ${index}`,
  turnKey: undefined,
  version: 1,
});

it("first paints its rows at the row height the font size sets, not the default's", async () => {
  initializeCommaI18n(["en"]);
  // A larger font-size preference: a taller line, so rows taller than the default's.
  document.documentElement.style.setProperty("--text-sm--line-height", "32px");
  const view = render(
    <ChatTaskPanel
      defaultOpenPopover="active"
      items={[task(1), task(2)]}
      onArchive={vi.fn(async () => {})}
      onDismiss={vi.fn()}
      onOpen={vi.fn()}
      onReveal={vi.fn()}
    />
  );
  const probe = view.container.querySelector(".comma-chat-task-panel-probe")!;
  const rows = view.container.querySelector<HTMLElement>(
    ".comma-chat-task-panel-rows"
  )!;

  // Observers report in the order they were made: this one reports after the
  // panel's, in the same rendering update, so it sees what the first paint shows.
  const painted = await new Promise<string>((resolve) => {
    const observer = new ResizeObserver(() => {
      observer.disconnect();
      resolve(rows.style.blockSize);
    });
    observer.observe(probe);
  });

  const { height, width } = probe.getBoundingClientRect();
  expect(height).toBeGreaterThan(28);
  expect(painted).toBe(`${2 * (height + width)}px`);
});

it("closes the active popover when clicking blank space beside the pill", async () => {
  initializeCommaI18n(["en"]);
  await page.viewport(800, 600);
  const loop = (index: number): ChatCreatedTask => ({
    ...task(index),
    loopStanding: { kind: "scheduled", text: "Every day at 8:00 AM" },
    statusBucket: "loops",
    title: `Daily loop ${index}`,
  });
  const view = render(
    <div style={{ paddingTop: 240, width: 640 }}>
      <ChatTaskPanel
        items={[loop(1), loop(2)]}
        onArchive={vi.fn(async () => {})}
        onDismiss={vi.fn()}
        onOpen={vi.fn()}
        onReveal={vi.fn()}
      />
    </div>
  );

  const pill = view.container.querySelector<HTMLElement>(
    '[data-testid="chat-task-panel-toggle"]'
  )!;
  const bar = view.container.querySelector<HTMLElement>(".comma-chat-dock-bar")!;

  await userEvent.click(pill);
  expect(
    view.container.querySelector('[data-testid="chat-dock-active-popover"]')
  ).not.toBeNull();

  const barRect = bar.getBoundingClientRect();
  const pillRect = pill.getBoundingClientRect();
  expect(barRect.right - pillRect.right).toBeGreaterThan(100);

  // Click in the blank area to the right of the Loops pill inside the dock bar.
  await userEvent.click(bar, {
    position: {
      x: Math.round((pillRect.right - barRect.left + barRect.width) / 2),
      y: Math.round(barRect.height / 2),
    },
  });
  expect(
    view.container.querySelector('[data-testid="chat-dock-active-popover"]')
  ).toBeNull();
});

it("stretches the left task focus bubble full width and keeps inline actions inside its border", async () => {
  initializeCommaI18n(["en"]);
  await page.viewport(800, 600);
  const reviewTask: ChatCreatedTask = {
    archiveVersion: 7,
    conversationId: "cnv_task_review",
    messageId: "msg_a1",
    needsAttention: true,
    needsInput: false,
    loopStop: undefined,
    statusBucket: "needs_review",
    title: "Daily 8am: Xiaohongshu pet posts Top10 breakdown and summary",
    turnKey: "msg_u1",
    version: 1,
  };
  const loopTask: ChatCreatedTask = {
    ...task(1),
    loopStanding: { kind: "scheduled", text: "Every day at 8:00 AM" },
    statusBucket: "loops",
    title: "Daily loop 1",
  };
  const view = render(
    <div style={{ paddingTop: 120, width: 640 }}>
      <ChatTaskPanel
        items={[reviewTask, loopTask]}
        onArchive={vi.fn(async () => {})}
        onDismiss={vi.fn()}
        onOpen={vi.fn()}
        onReveal={vi.fn()}
      />
    </div>
  );

  const bar = view.container.querySelector<HTMLElement>(".comma-chat-dock-bar")!;
  const focus = view.container.querySelector<HTMLElement>(
    '[data-testid="chat-task-item-cnv_task_review"]'
  )!;
  const pill = view.container.querySelector<HTMLElement>(
    '[data-testid="chat-task-panel-toggle"]'
  )!;
  const dismiss = view.container.querySelector<HTMLElement>(
    '[data-testid="chat-task-dismiss-cnv_task_review"]'
  )!;
  const reveal = view.container.querySelector<HTMLElement>(
    '[data-testid="chat-task-reveal-cnv_task_review"]'
  )!;
  const archive = focus.querySelector<HTMLElement>('[aria-label="Archive task"]')!;

  // Settle the one-shot arrival scale animation before reading layout rects.
  for (const animation of focus.getAnimations()) animation.finish();

  const barRect = bar.getBoundingClientRect();
  const focusRect = focus.getBoundingClientRect();
  const pillRect = pill.getBoundingClientRect();

  // Left bubble fills the bar and pushes the right pill flush with the bar's right edge.
  expect(Math.abs(pillRect.right - barRect.right)).toBeLessThanOrEqual(1);
  expect(Math.abs(focusRect.left - barRect.left)).toBeLessThanOrEqual(1);
  expect(focusRect.width).toBeGreaterThan(barRect.width - pillRect.width - 24);

  // Dismiss, Reveal in Chat, and Archive stay hidden at rest and appear strictly inside the bubble on hover.
  for (const button of [dismiss, reveal, archive]) {
    expect(getComputedStyle(button).opacity).toBe("0");
  }

  // Hovering either dock bubble keeps its border color and shadow unchanged.
  const focusBorderAtRest = getComputedStyle(focus).borderTopColor;
  const focusShadowAtRest = getComputedStyle(focus).boxShadow;
  const pillBorderAtRest = getComputedStyle(pill).borderTopColor;
  const pillShadowAtRest = getComputedStyle(pill).boxShadow;
  await userEvent.hover(focus);
  expect(getComputedStyle(focus).borderTopColor).toBe(focusBorderAtRest);
  expect(getComputedStyle(focus).boxShadow).toBe(focusShadowAtRest);
  for (const button of [dismiss, reveal, archive]) {
    expect(getComputedStyle(button).opacity).toBe("1");
    const rect = button.getBoundingClientRect();
    expect(rect.left).toBeGreaterThanOrEqual(focusRect.left);
    expect(rect.right).toBeLessThanOrEqual(focusRect.right);
  }
  await userEvent.hover(pill);
  expect(getComputedStyle(pill).borderTopColor).toBe(pillBorderAtRest);
  expect(getComputedStyle(pill).boxShadow).toBe(pillShadowAtRest);
});
