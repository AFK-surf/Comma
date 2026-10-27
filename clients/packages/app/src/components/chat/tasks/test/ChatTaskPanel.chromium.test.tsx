import "@comma/ui/styles.css";
import "@comma/app/styles.css";

import { initializeCommaI18n } from "@comma/i18n";
import { render } from "@comma/test-utils/render";
import { afterEach, expect, it, vi } from "vitest";
import { ChatTaskPanel } from "../ChatTaskPanel";
import type { ChatCreatedTask } from "../useChatCreatedTasks";

afterEach(() => {
  document.documentElement.style.removeProperty("--text-sm--line-height");
  document.body.replaceChildren();
});

const task = (index: number): ChatCreatedTask => ({
  archiveVersion: undefined,
  conversationId: `cnv_task_${index}`,
  messageId: undefined,
  needsAttention: false,
  needsInput: false,
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
