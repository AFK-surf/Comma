import "@comma/ui/styles.css";
import { CommaI18nProvider } from "@comma/i18n/react";
import { cleanup, render } from "@testing-library/react";
import { useRef, useState, type ReactNode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import { uiClock } from "../../../clock";
import { TaskProgressContext } from "../../task-workspace/taskProgress";
import {
  TaskWorkspace,
  type TaskWorkspaceTask,
} from "../../task-workspace/TaskWorkspace";
import { TaskFeedView } from "../TaskFeedView";
import type { TaskFeedEntry, TaskFeedSessionInspectorContext } from "../types";
import { useHorizontalDragScroll } from "../useHorizontalDragScroll";

afterEach(cleanup);

const NOW = uiClock.now();

const TEST_ENTRIES: readonly TaskFeedEntry[] = [
  {
    id: "entry-review-new",
    conversationId: "conv-review-new",
    groupId: "g1",
    clusterKey: "c-rev-new",
    triggerKind: "brief",
    taskTitle: "Feed pagination latency benchmark",
    taskStatus: "needs_review",
    statusBucket: "needs_review",
    taskUpdatedAt: NOW - 14 * 60_000,
    reviewVersion: 7,
    isLoop: false,
    occurredAt: NOW - 14 * 60_000,
    milestones: [
      { title: "Step 1 oldest", at: NOW - 41 * 60_000, messageId: "msg-rev-1" },
      { title: "Step 2 middle", at: NOW - 30 * 60_000, messageId: "msg-rev-2" },
      { title: "Step 3 newer", at: NOW - 21 * 60_000, messageId: "msg-rev-3" },
      { title: "Step 4 newest", at: NOW - 14 * 60_000, messageId: "msg-rev-4" },
    ],
    milestoneCount: 4,
    outcomeText: "p95 dropped from 42ms to 18ms.",
    media: [],
    files: [{ name: "feed-hydration-profile.json", mimeType: "application/json" }],
    pullRequest: {
      number: 1842,
      state: "open",
      url: "https://github.com/AFK-surf/Cue/pull/1842",
    },
  },
  {
    id: "entry-review-old",
    conversationId: "conv-review-old",
    groupId: "g1",
    clusterKey: "c-rev-old",
    triggerKind: "follow_up",
    taskTitle: "OAuth token refresh retry backoff",
    taskStatus: "needs_review",
    statusBucket: "needs_review",
    taskUpdatedAt: NOW - 38 * 60_000,
    reviewVersion: 3,
    isLoop: false,
    occurredAt: NOW - 38 * 60_000,
    milestones: [],
    milestoneCount: 0,
    outcomeText: "Coalesced concurrent token refreshes.",
    media: [],
    files: [],
  },
  {
    id: "entry-running-1",
    conversationId: "conv-running-1",
    groupId: "g1",
    clusterKey: "c-run-1",
    triggerKind: "loop_run",
    taskTitle: "macOS staging release patrol",
    taskStatus: "in_progress",
    statusBucket: "in_progress",
    taskUpdatedAt: NOW - 2 * 60_000,
    isLoop: true,
    occurredAt: NOW - 2 * 60_000,
    milestones: [
      {
        title: "Running cold-start smoke test",
        at: NOW - 2 * 60_000,
        messageId: "msg-r3",
      },
      { title: "Verified notarization", at: NOW - 5 * 60_000, messageId: "msg-r2" },
      { title: "Fetched build 1428", at: NOW - 9 * 60_000, messageId: "msg-r1" },
    ],
    milestoneCount: 3,
    outcomeText: "Running cold-start smoke test.",
    media: [],
    files: [],
  },
  {
    id: "entry-done-1",
    conversationId: "conv-done-1",
    groupId: "g1",
    clusterKey: "c-done-1",
    triggerKind: "brief",
    taskTitle: "Migrate task search index to trigram",
    taskStatus: "done",
    statusBucket: "done",
    taskUpdatedAt: NOW - 2 * 3_600_000,
    isLoop: false,
    occurredAt: NOW - 2 * 3_600_000,
    milestones: [
      { title: "Merged PR #1839", at: NOW - 2 * 3_600_000, messageId: "msg-d2" },
    ],
    milestoneCount: 1,
    outcomeText: "Substring search p99 is now 9ms.",
    media: [],
    files: [{ name: "report.md" }],
  },
  {
    id: "entry-cancelled-1",
    conversationId: "conv-cancelled-1",
    groupId: "g1",
    clusterKey: "c-can-1",
    triggerKind: "brief",
    taskTitle: "Legacy polling fallback cleanup",
    taskStatus: "cancelled",
    statusBucket: "cancelled",
    taskUpdatedAt: NOW - 26 * 3_600_000,
    isLoop: false,
    occurredAt: NOW - 26 * 3_600_000,
    milestones: [],
    milestoneCount: 0,
    outcomeText: "Superseded by SSE compaction.",
    media: [],
    files: [],
  },
];

function mount(node: ReactNode) {
  return render(
    <CommaI18nProvider locale="en">
      <div className="h-screen w-screen overflow-hidden">{node}</div>
    </CommaI18nProvider>
  );
}

function renderTestInspector(context: TaskFeedSessionInspectorContext) {
  return (
    <div
      data-inspector-conv={context.entry.conversationId}
      data-testid={`inspector-${context.entry.conversationId}`}
    >
      <span data-testid={`revealed-${context.entry.conversationId}`}>
        {context.revealMessageId ?? ""}
      </span>
    </div>
  );
}

describe("TaskFeedView V5 (Threads Multi-Column Deck + In-Column Drill-In)", () => {
  it("renders spacious columns side-by-side with strict newest-first order and no right split pane", async () => {
    await page.viewport(1280, 800);
    mount(
      <TaskFeedView
        entries={TEST_ENTRIES}
        lastSeenAt={NOW - 45 * 60_000}
        renderSessionInspector={renderTestInspector}
      />
    );

    const columns = Array.from(
      document.querySelectorAll<HTMLElement>('[data-slot="task-feed-column"]')
    );
    expect(columns.map((col) => col.dataset.column)).toEqual([
      "needs_review",
      "in_progress",
      "done",
    ]);

    // No right split inspector pane exists.
    expect(document.querySelector('[data-slot="task-feed-inspector-pane"]')).toBeNull();

    const reviewCol = columns[0]!;
    const reviewEntries = Array.from(
      reviewCol.querySelectorAll<HTMLElement>('[data-slot="task-feed-entry"]')
    );
    expect(reviewEntries.map((el) => el.dataset.entryId)).toEqual([
      "entry-review-new",
      "entry-review-old",
    ]);
    expect(
      reviewEntries[0]!.querySelector('[data-slot="task-feed-inspect-action"]')
    ).toBeNull();
  });

  it("drills into Session Detail inside the clicked column without squeezing sibling columns, supports simultaneous multi-column drill-in, and pops via Back/Escape", async () => {
    await page.viewport(1280, 800);
    mount(
      <TaskFeedView
        entries={TEST_ENTRIES}
        renderSessionInspector={renderTestInspector}
      />
    );

    // Click milestone in Needs review column -> drills in INSIDE Needs review column.
    // First expand earlier steps (only newest 1 milestone is shown by default).
    const reviewCol = document.querySelector<HTMLElement>(
      '[data-column="needs_review"]'
    )!;
    const progressCol = document.querySelector<HTMLElement>(
      '[data-column="in_progress"]'
    )!;
    await userEvent.click(
      reviewCol.querySelector<HTMLButtonElement>(
        '[data-slot="task-feed-steps-action"]'
      )!
    );
    await userEvent.click(page.getByRole("button", { name: /Step 3 newer/ }));

    expect(reviewCol.dataset.drilledIn).toBe("true");
    expect(progressCol.dataset.drilledIn).toBe("false");
    expect(
      reviewCol.querySelector('[data-testid="inspector-conv-review-new"]')
    ).not.toBeNull();
    expect(
      reviewCol.querySelector('[data-testid="revealed-conv-review-new"]')?.textContent
    ).toBe("msg-rev-3");
    // Sibling In progress column remains intact with its posts visible.
    expect(
      progressCol.querySelector('[data-entry-id="entry-running-1"]')
    ).not.toBeNull();

    // Simultaneously drill into a second task in In progress column!
    await userEvent.click(
      progressCol.querySelector<HTMLElement>('[data-slot="task-feed-title"]')!
    );
    expect(reviewCol.dataset.drilledIn).toBe("true");
    expect(progressCol.dataset.drilledIn).toBe("true");
    expect(
      progressCol.querySelector('[data-testid="inspector-conv-running-1"]')
    ).not.toBeNull();

    // Escape pops the most recently drilled-in column (In progress) while keeping Needs review drilled in.
    await userEvent.keyboard("{Escape}");
    expect(progressCol.dataset.drilledIn).toBe("false");
    expect(reviewCol.dataset.drilledIn).toBe("true");

    // Clicking ← Back button in Needs review returns to its Feed stream.
    await userEvent.click(
      reviewCol.querySelector<HTMLButtonElement>('[data-slot="task-feed-column-back"]')!
    );
    expect(reviewCol.dataset.drilledIn).toBe("false");
    expect(
      reviewCol.querySelector('[data-entry-id="entry-review-new"]')
    ).not.toBeNull();
  });

  it("deduplicates liveStep when it matches the newest milestone title", async () => {
    await page.viewport(1280, 800);
    const duplicateProgressSource = {
      progressOf(taskId: string) {
        return taskId === "conv-running-1"
          ? "Running cold-start smoke test"
          : undefined;
      },
      subscribe() {
        return () => {};
      },
    };

    mount(
      <TaskProgressContext.Provider value={duplicateProgressSource}>
        <TaskFeedView entries={TEST_ENTRIES} />
      </TaskProgressContext.Provider>
    );

    const runningPost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-running-1"]'
    )!;
    const timelineText =
      runningPost.querySelector('[data-slot="task-feed-timeline"]')?.textContent ?? "";
    const occurrences = timelineText.split("Running cold-start smoke test").length - 1;
    expect(occurrences).toBe(1);
    const liveStep = runningPost.querySelector<HTMLElement>(
      '[data-slot="task-feed-live-step"]'
    )!;
    expect(liveStep).not.toBeNull();
    expect(liveStep.querySelector("button")).not.toBeNull();
  });

  it("toggles Cancelled column via [+] popover and hides columns via column menu", async () => {
    await page.viewport(1280, 800);
    mount(<TaskFeedView entries={TEST_ENTRIES} />);

    await userEvent.click(page.getByRole("button", { name: "Manage columns" }));
    const cancelledToggle = document.querySelector<HTMLElement>(
      '[data-column-toggle="cancelled"]'
    );
    expect(cancelledToggle).not.toBeNull();
    await userEvent.click(cancelledToggle!);

    const columnsAfterAdd = Array.from(
      document.querySelectorAll<HTMLElement>('[data-slot="task-feed-column"]')
    );
    expect(columnsAfterAdd.map((col) => col.dataset.column)).toEqual([
      "needs_review",
      "in_progress",
      "done",
      "cancelled",
    ]);

    await userEvent.keyboard("{Escape}");
    await userEvent.click(
      page.getByRole("button", { name: "Cancelled Column options" })
    );
    await userEvent.click(page.getByRole("menuitem", { name: "Hide column" }));

    const columnsAfterHide = Array.from(
      document.querySelectorAll<HTMLElement>('[data-slot="task-feed-column"]')
    );
    expect(columnsAfterHide.map((col) => col.dataset.column)).toEqual([
      "needs_review",
      "in_progress",
      "done",
    ]);
  });

  it("shows only the latest 1 milestone by default and toggles earlier steps via the steps icon button without opening a dialog", async () => {
    await page.viewport(1280, 800);
    mount(<TaskFeedView entries={TEST_ENTRIES} />);

    const reviewPost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-review-new"]'
    )!;
    expect(
      reviewPost.querySelector('[data-slot="task-feed-toggle-earlier"]')
    ).toBeNull();
    expect(
      reviewPost.querySelector('[data-slot="task-feed-view-all-steps"]')
    ).toBeNull();

    const stepsBtn = reviewPost.querySelector<HTMLButtonElement>(
      '[data-slot="task-feed-steps-action"]'
    )!;
    expect(stepsBtn.getAttribute("aria-expanded")).toBe("false");
    expect(stepsBtn.getAttribute("aria-label")).toContain("Show 3 earlier steps");
    expect(
      reviewPost.querySelectorAll('[data-slot="task-feed-milestone"]')
    ).toHaveLength(1);

    await userEvent.click(stepsBtn);
    expect(stepsBtn.getAttribute("aria-expanded")).toBe("true");
    expect(stepsBtn.getAttribute("aria-label")).toContain("Hide earlier steps");
    expect(document.querySelectorAll('[role="dialog"]')).toHaveLength(0);

    const milestoneTimes = Array.from(
      reviewPost.querySelectorAll<HTMLElement>('[data-slot="task-feed-milestone"]')
    ).map((el) => Number(el.dataset.milestoneAt));
    expect(milestoneTimes).toHaveLength(4);
    for (let i = 1; i < milestoneTimes.length; i += 1) {
      expect(milestoneTimes[i - 1]!).toBeGreaterThanOrEqual(milestoneTimes[i]!);
    }

    await userEvent.click(stepsBtn);
    expect(stepsBtn.getAttribute("aria-expanded")).toBe("false");
    expect(
      reviewPost.querySelectorAll('[data-slot="task-feed-milestone"]')
    ).toHaveLength(1);
  });

  it("supports inline Reply via icon button and shows monochrome Approve only on needs_review entries", async () => {
    await page.viewport(1280, 800);
    const onApproveEntry = vi.fn();
    const onReplyEntry = vi.fn();
    mount(
      <TaskFeedView
        entries={TEST_ENTRIES}
        onApproveEntry={onApproveEntry}
        onReplyEntry={onReplyEntry}
      />
    );

    const reviewPost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-review-new"]'
    )!;
    const runningPost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-running-1"]'
    )!;
    const donePost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-done-1"]'
    )!;

    expect(
      reviewPost.querySelector('[data-slot="task-feed-approve-action"]')
    ).not.toBeNull();
    expect(
      runningPost.querySelector('[data-slot="task-feed-approve-action"]')
    ).toBeNull();
    expect(donePost.querySelector('[data-slot="task-feed-approve-action"]')).toBeNull();

    await userEvent.click(
      reviewPost.querySelector<HTMLButtonElement>(
        '[data-slot="task-feed-approve-action"]'
      )!
    );
    expect(onApproveEntry).toHaveBeenCalledWith(
      expect.objectContaining({ id: "entry-review-new", reviewVersion: 7 })
    );

    await userEvent.click(
      reviewPost.querySelector<HTMLButtonElement>(
        '[data-slot="task-feed-reply-action"]'
      )!
    );
    const input = page.getByRole("textbox", { name: "Reply to this task…" });
    await expect.element(input).toBeVisible();
    await userEvent.fill(input, "Ship it after rebase.");
    await userEvent.keyboard("{Enter}");
    expect(onReplyEntry).toHaveBeenCalledWith(
      expect.objectContaining({ id: "entry-review-new" }),
      "Ship it after rebase."
    );
    await expect.element(input).not.toBeInTheDocument();
  });

  it("degrades cleanly on narrow 480x800 viewport with minimalist status tabs and zero horizontal overflow", async () => {
    await page.viewport(480, 800);
    mount(<TaskFeedView entries={TEST_ENTRIES} />);

    const narrowView = document.querySelector<HTMLElement>(
      '[data-slot="task-feed-narrow-view"]'
    )!;
    expect(narrowView).not.toBeNull();
    expect(narrowView.scrollWidth).toBeLessThanOrEqual(narrowView.clientWidth + 1);

    await userEvent.click(page.getByRole("tab", { name: /In progress/ }));
    const visibleEntries = Array.from(
      narrowView.querySelectorAll<HTMLElement>('[data-slot="task-feed-entry"]')
    );
    expect(visibleEntries.map((el) => el.dataset.entryId)).toEqual(["entry-running-1"]);
  });

  it("keeps Board as default view in TaskWorkspace and switches cleanly into Feed Deck", async () => {
    await page.viewport(1280, 800);
    const tasks: readonly TaskWorkspaceTask[] = TEST_ENTRIES.map((entry) => ({
      activityStatus:
        entry.statusBucket === "in_progress"
          ? "working"
          : entry.statusBucket === "needs_review"
            ? "waiting_for_review"
            : "completed",
      archiveVersion: entry.taskUpdatedAt,
      conversationId: entry.conversationId,
      groupId: entry.groupId,
      id: entry.id,
      labels: [],
      messages: [],
      status: entry.taskStatus,
      statusBucket: entry.statusBucket,
      title: entry.taskTitle,
      updatedAt: entry.taskUpdatedAt,
      workspaceId: "ws-1",
    }));
    mount(
      <TaskWorkspace
        capabilityState="ready"
        feed={{ entries: TEST_ENTRIES }}
        onOpenTask={vi.fn()}
        tasks={tasks}
      />
    );

    await expect.element(page.getByTestId("tasks-route")).toBeVisible();
    expect(document.querySelector('[data-testid="tasks-feed"]')).toBeNull();
    const viewTrigger = document.querySelector<HTMLButtonElement>(
      '[data-slot="task-view-action"]'
    )!;
    await userEvent.click(viewTrigger);
    await userEvent.click(page.getByRole("menuitemradio", { name: "Feed" }));
    await expect.element(page.getByTestId("tasks-feed")).toBeVisible();
  });

  it("wraps PR and file attachment chips via renderPullRequest and renderFile slots", async () => {
    await page.viewport(1280, 800);
    const renderPullRequest = vi.fn((pr, _entry, defaultNode) => (
      <span data-testid={`wrapped-pr-${pr.number}`}>{defaultNode}</span>
    ));
    const renderFile = vi.fn((file, _entry, defaultNode) => (
      <span data-testid={`wrapped-file-${file.name}`}>{defaultNode}</span>
    ));
    mount(
      <TaskFeedView
        entries={TEST_ENTRIES}
        renderFile={renderFile}
        renderPullRequest={renderPullRequest}
      />
    );

    await expect.element(page.getByTestId("wrapped-pr-1842")).toBeVisible();
    await expect
      .element(page.getByTestId("wrapped-file-feed-hydration-profile.json"))
      .toBeVisible();
    expect(renderPullRequest).toHaveBeenCalled();
    expect(renderFile).toHaveBeenCalled();
  });

  it("renders error description with readable width instead of collapsing to spacing-sm", async () => {
    await page.viewport(1280, 800);
    mount(
      <TaskFeedView
        entries={[]}
        loadError="Unable to reach workspace task feed right now."
      />
    );

    const errorContainer = document.querySelector<HTMLElement>(
      '[data-slot="task-feed-error"]'
    );
    expect(errorContainer).not.toBeNull();
    const desc = errorContainer!.querySelectorAll("p")[1]!;
    expect(desc.getBoundingClientRect().width).toBeGreaterThanOrEqual(120);
  });

  it("renders native FileTypeIcon per file extension and shadow-xs on Approve button", async () => {
    await page.viewport(1280, 800);
    const richEntries = [
      {
        ...TEST_ENTRIES[0]!,
        files: [
          { name: "release-checklist.pdf", mimeType: "application/pdf" },
          { name: "feed-hydration-profile.json", mimeType: "application/json" },
          { name: "trigram-bench-report.md", mimeType: "text/markdown" },
        ],
      },
      {
        ...TEST_ENTRIES[1]!,
        files: [
          { name: "crash-symbols-1428.zip", mimeType: "application/zip" },
          { name: "smoke-oauth-flow.mp4", mimeType: "video/mp4" },
        ],
      },
    ];
    mount(<TaskFeedView entries={richEntries} onApproveEntry={vi.fn()} />);

    const icons = Array.from(
      document.querySelectorAll<HTMLElement>(
        '[data-slot="task-feed-file"] [data-testid="file-type-icon"]'
      )
    ).map((el) => el.dataset.fileType);
    expect(icons).toEqual(expect.arrayContaining(["pdf", "json", "md", "zip", "mp4"]));

    const approveBtn = document.querySelector<HTMLButtonElement>(
      '[data-slot="task-feed-approve-action"]'
    );
    expect(approveBtn).not.toBeNull();
  });

  it("renders multi-image media and file/PR attachment chips as single-row horizontal scroll strips", async () => {
    await page.viewport(1280, 800);
    const horizontalEntries = [
      {
        ...TEST_ENTRIES[0]!,
        media: [
          { attachmentId: "m1", filename: "chart-1.png", mimeType: "image/png" },
          { attachmentId: "m2", filename: "chart-2.png", mimeType: "image/png" },
          { attachmentId: "m3", filename: "chart-3.png", mimeType: "image/png" },
          { attachmentId: "m4", filename: "chart-4.png", mimeType: "image/png" },
        ],
        files: [
          { name: "anthropic-ipo-overview.html", mimeType: "text/html" },
          { name: "anthropic-ipo-report.md", mimeType: "text/markdown" },
          { name: "anthropic-ipo-brief.pdf", mimeType: "application/pdf" },
          { name: "valuation-model-summary.json", mimeType: "application/json" },
        ],
      },
    ];
    mount(<TaskFeedView entries={horizontalEntries} />);

    const mediaStrip = document.querySelector<HTMLElement>(
      '[data-slot="task-feed-media"]'
    )!;
    expect(mediaStrip.className).toContain("flex-nowrap");
    expect(mediaStrip.className).toContain("overflow-x-auto");
    expect(mediaStrip.className).not.toContain("-ml-[74px]");
    const mediaCells = Array.from(
      mediaStrip.querySelectorAll<HTMLElement>('[data-slot="task-feed-media-cell"]')
    );
    expect(mediaCells).toHaveLength(4);
    for (const cell of mediaCells) {
      expect(cell.className).toContain("shrink-0");
    }

    const attachments = document.querySelector<HTMLElement>(
      '[data-slot="task-feed-attachments"]'
    )!;
    expect(attachments.className).toContain("flex-nowrap");
    expect(attachments.className).toContain("overflow-x-auto");
    expect(attachments.className).not.toContain("-ml-[74px]");
    const fileChips = Array.from(
      attachments.querySelectorAll<HTMLElement>('[data-slot="task-feed-file"]')
    );
    expect(fileChips).toHaveLength(4);
    for (const chip of fileChips) {
      expect(chip.className).toContain("shrink-0");
    }
  });

  it("supports mouse drag-to-scroll via useHorizontalDragScroll and suppresses accidental clicks after dragging", async () => {
    await page.viewport(1280, 800);
    const onItemClick = vi.fn();

    function DragScrollHarness() {
      const ref = useRef<HTMLDivElement | null>(null);
      const { handlers, scrolledLeft } = useHorizontalDragScroll(ref);
      return (
        <div
          data-scrolled-left={scrolledLeft ? "true" : "false"}
          data-testid="drag-strip"
          ref={ref}
          style={{
            display: "flex",
            flexWrap: "nowrap",
            gap: "8px",
            overflowX: "auto",
            width: "240px",
          }}
          {...handlers}
        >
          {[0, 1, 2, 3].map((idx) => (
            <button
              data-testid={`drag-item-${idx}`}
              key={idx}
              onClick={() => onItemClick(idx)}
              style={{ flexShrink: 0, height: "40px", width: "160px" }}
              type="button"
            >
              Item {idx}
            </button>
          ))}
        </div>
      );
    }

    render(<DragScrollHarness />);

    const strip = document.querySelector<HTMLElement>('[data-testid="drag-strip"]')!;
    expect(strip.scrollWidth).toBeGreaterThan(strip.clientWidth);
    expect(strip.scrollLeft).toBe(0);
    expect(strip.dataset.scrolledLeft).toBe("false");

    const firstItem = document.querySelector<HTMLButtonElement>(
      '[data-testid="drag-item-0"]'
    )!;
    const rect = firstItem.getBoundingClientRect();

    // Drag > 4px: should scroll horizontally and suppress the resulting click.
    strip.dispatchEvent(
      new PointerEvent("pointerdown", {
        bubbles: true,
        button: 0,
        clientX: rect.left + 120,
        clientY: rect.top + 16,
        pointerId: 1,
        pointerType: "mouse",
      })
    );
    strip.dispatchEvent(
      new PointerEvent("pointermove", {
        bubbles: true,
        button: 0,
        clientX: rect.left + 20,
        clientY: rect.top + 16,
        pointerId: 1,
        pointerType: "mouse",
      })
    );
    strip.dispatchEvent(
      new PointerEvent("pointerup", {
        bubbles: true,
        button: 0,
        clientX: rect.left + 20,
        clientY: rect.top + 16,
        pointerId: 1,
        pointerType: "mouse",
      })
    );
    firstItem.dispatchEvent(
      new MouseEvent("click", { bubbles: true, cancelable: true })
    );

    expect(strip.scrollLeft).toBeGreaterThan(0);
    await expect
      .element(page.getByTestId("drag-strip"))
      .toHaveAttribute("data-scrolled-left", "true");
    expect(onItemClick).not.toHaveBeenCalled();

    // Normal click without drag: should trigger child click normally.
    await userEvent.click(firstItem);
    expect(onItemClick).toHaveBeenCalledTimes(1);
    expect(onItemClick).toHaveBeenCalledWith(0);
  });

  it("places action bar below milestone timeline and keeps 0px vertical shift when live activity text switches from 10 chars to 120 chars", async () => {
    await page.viewport(1280, 800);
    const styleEl = document.createElement("style");
    styleEl.textContent = `
      [data-testid="v14-jitter-wrap"] { width: 460px; }
      [data-testid="v14-jitter-wrap"] .truncate { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      [data-testid="v14-jitter-wrap"] .flex { display: flex; }
      [data-testid="v14-jitter-wrap"] .min-w-0 { min-width: 0; }
      [data-testid="v14-jitter-wrap"] .flex-1 { flex: 1 1 0%; }
      [data-testid="v14-jitter-wrap"] .shrink-0 { flex-shrink: 0; }
      [data-testid="v14-jitter-wrap"] .grid { display: grid; }
      [data-testid="v14-jitter-wrap"] button { max-width: 100%; }
    `;
    document.head.appendChild(styleEl);

    try {
      const shortText = "核对首日发行定价数据";
      const longText =
        "正在全面核对 2026 年 11 月 Anthropic 纳斯达克上市发行价、九点八亿股流通股本、两百六十亿美元芯片与云巨头联合战略定增锁定期条款、首日开盘破两万亿美元盘中峰值以及收盘估值区间交叉验证与多维度归因分析完整报告摘要";
      expect(longText.length).toBeGreaterThanOrEqual(110);

      const baseAt = TEST_ENTRIES[0]!.occurredAt;
      const makeRunningEntry = (liveText: string): TaskFeedEntry => ({
        ...TEST_ENTRIES[0]!,
        id: "entry-live-jitter",
        milestones: [
          {
            at: baseAt - 10_000,
            messageId: "m-jitter-1",
            title: liveText,
          },
          {
            at: baseAt - 60_000,
            messageId: "m-jitter-0",
            title: "初始化调研任务与数据源连接",
          },
        ],
        milestoneCount: 2,
        statusBucket: "needs_review",
      });

      function JitterHarness() {
        const [liveText, setLiveText] = useState(shortText);
        return (
          <div data-testid="v14-jitter-wrap">
            <button
              data-testid="switch-long-text"
              onClick={() => setLiveText(longText)}
              type="button"
            >
              Switch
            </button>
            <TaskFeedView
              entries={[makeRunningEntry(liveText)]}
              onApproveEntry={vi.fn()}
              onReplyEntry={vi.fn()}
            />
          </div>
        );
      }

      mount(<JitterHarness />);

      const post = document.querySelector<HTMLElement>(
        '[data-entry-id="entry-live-jitter"]'
      )!;
      const timeline = post.querySelector<HTMLElement>(
        '[data-slot="task-feed-timeline"]'
      )!;
      const actions = post.querySelector<HTMLElement>(
        '[data-slot="task-feed-actions"]'
      )!;

      // Action bar sits strictly BELOW the milestone timeline (at the bottom of the card).
      expect(actions.getBoundingClientRect().top).toBeGreaterThanOrEqual(
        timeline.getBoundingClientRect().bottom - 1
      );

      // Collapsed milestone uses single-line truncate with title tooltip.
      const collapsedTitle = post.querySelector<HTMLElement>(
        '[data-slot="task-feed-milestone"] span[title]'
      )!;
      expect(collapsedTitle.className).toContain("truncate");
      expect(collapsedTitle.className).not.toContain("line-clamp-2");

      const beforeTop = actions.getBoundingClientRect().top;

      // Switch live milestone text from 10 chars to long 110+ char string while collapsed.
      await userEvent.click(
        document.querySelector<HTMLButtonElement>('[data-testid="switch-long-text"]')!
      );

      const updatedTitle = post.querySelector<HTMLElement>(
        '[data-slot="task-feed-milestone"] span[title]'
      )!;
      expect(updatedTitle.textContent).toBe(longText);
      expect(updatedTitle.className).toContain("truncate");

      const afterTop = actions.getBoundingClientRect().top;
      expect(Math.abs(afterTop - beforeTop)).toBeLessThan(0.5);

      // Expanding reveals earlier steps with line-clamp-2.
      const stepsBtn = post.querySelector<HTMLButtonElement>(
        '[data-slot="task-feed-steps-action"]'
      )!;
      await userEvent.click(stepsBtn);
      expect(post.querySelectorAll('[data-slot="task-feed-milestone"]')).toHaveLength(
        2
      );
      const expandedTitle = post.querySelector<HTMLElement>(
        '[data-slot="task-feed-milestone"] span[title]'
      )!;
      expect(expandedTitle.className).toContain("line-clamp-2");
    } finally {
      styleEl.remove();
    }
  });

  it("places Open full task arrow in card header instead of ··· menu and removes it from action bar", async () => {
    await page.viewport(1280, 800);
    const onOpenEntry = vi.fn();
    mount(
      <TaskFeedView
        entries={TEST_ENTRIES}
        onApproveEntry={vi.fn()}
        onOpenEntry={onOpenEntry}
        onReplyEntry={vi.fn()}
      />
    );

    const reviewPost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-review-new"]'
    )!;
    expect(
      reviewPost.querySelector('[data-slot="task-feed-post-menu-trigger"]')
    ).toBeNull();
    const actions = reviewPost.querySelector<HTMLElement>(
      '[data-slot="task-feed-actions"]'
    )!;
    expect(
      actions.querySelector('[data-slot="task-feed-open-full-action"]')
    ).toBeNull();

    const headerOpenBtn = reviewPost.querySelector<HTMLButtonElement>(
      '[data-slot="task-feed-open-full-action"]'
    )!;
    expect(headerOpenBtn).not.toBeNull();
    await userEvent.click(headerOpenBtn);
    expect(onOpenEntry).toHaveBeenCalledTimes(1);
    expect(onOpenEntry).toHaveBeenCalledWith(TEST_ENTRIES[0]);
  });

  it("opens task chat when clicking post section whitespace without double-triggering on buttons or title", async () => {
    await page.viewport(1280, 800);
    const onApproveEntry = vi.fn();
    const onOpenEntry = vi.fn();
    const onReplyEntry = vi.fn();

    mount(
      <TaskFeedView
        entries={TEST_ENTRIES}
        onApproveEntry={onApproveEntry}
        onOpenEntry={onOpenEntry}
        onReplyEntry={onReplyEntry}
        renderSessionInspector={(ctx) => (
          <div data-testid={`inspector-${ctx.entry.id}`}>{ctx.entry.taskTitle}</div>
        )}
      />
    );

    const reviewPost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-review-new"]'
    )!;
    expect(reviewPost.className).toContain("cursor-pointer");

    // 1. Clicking internal action buttons must NOT bubble up to open the in-column task chat.
    await userEvent.click(
      reviewPost.querySelector<HTMLButtonElement>(
        '[data-slot="task-feed-approve-action"]'
      )!
    );
    expect(onApproveEntry).toHaveBeenCalledTimes(1);
    expect(document.querySelector('[data-slot="task-feed-column-chat"]')).toBeNull();

    await userEvent.click(
      reviewPost.querySelector<HTMLButtonElement>(
        '[data-slot="task-feed-steps-action"]'
      )!
    );
    expect(document.querySelector('[data-slot="task-feed-column-chat"]')).toBeNull();

    await userEvent.click(
      reviewPost.querySelector<HTMLButtonElement>(
        '[data-slot="task-feed-reply-action"]'
      )!
    );
    expect(
      reviewPost.querySelector('[data-slot="task-feed-inline-reply"]')
    ).not.toBeNull();
    expect(document.querySelector('[data-slot="task-feed-column-chat"]')).toBeNull();

    await userEvent.click(
      reviewPost.querySelector<HTMLButtonElement>(
        '[data-slot="task-feed-open-full-action"]'
      )!
    );
    expect(onOpenEntry).toHaveBeenCalledTimes(1);
    expect(document.querySelector('[data-slot="task-feed-column-chat"]')).toBeNull();

    // 2. Clicking the post section whitespace itself opens the in-column task chat.
    reviewPost.dispatchEvent(
      new MouseEvent("click", { bubbles: true, cancelable: true })
    );
    await expect.element(page.getByTestId("inspector-entry-review-new")).toBeVisible();

    // 3. Clicking the title triggers onOpenEntry exactly once (no double-trigger) when no inspector is passed.
    cleanup();
    const onSelectDirect = vi.fn();
    mount(
      <TaskFeedView
        entries={TEST_ENTRIES}
        onOpenEntry={onSelectDirect}
        onReplyEntry={vi.fn()}
      />
    );
    const titleBtn = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-review-new"] [data-slot="task-feed-title"]'
    )!;
    await userEvent.click(titleBtn);
    expect(onSelectDirect).toHaveBeenCalledTimes(1);
  });

  it("renders native shimmer only on the latest in_progress step and applies capsule hover/active motion classes on icon actions", async () => {
    await page.viewport(1280, 800);
    mount(
      <TaskFeedView
        entries={TEST_ENTRIES}
        onApproveEntry={vi.fn()}
        onOpenEntry={vi.fn()}
        onReplyEntry={vi.fn()}
      />
    );

    const runningPost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-running-1"]'
    )!;
    const reviewPost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-review-new"]'
    )!;
    const donePost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-done-1"]'
    )!;

    // 1. Latest milestone on in_progress card renders .comma-shiny-text with data-shimmer="true" even without SSE liveStep.
    const runningLatestStep = runningPost.querySelector<HTMLElement>(
      '[data-slot="task-feed-milestone"]'
    )!;
    expect(runningLatestStep.dataset.shimmer).toBe("true");
    expect(runningLatestStep.querySelector(".comma-shiny-text")).not.toBeNull();

    // Needs review and done cards do NOT render shimmer.
    expect(reviewPost.querySelector(".comma-shiny-text")).toBeNull();
    expect(reviewPost.querySelector('[data-shimmer="true"]')).toBeNull();
    expect(donePost.querySelector(".comma-shiny-text")).toBeNull();
    expect(donePost.querySelector('[data-shimmer="true"]')).toBeNull();

    // Expanding in_progress shows earlier steps WITHOUT shimmer (only index 0 shimmers).
    const runningStepsBtn = runningPost.querySelector<HTMLButtonElement>(
      '[data-slot="task-feed-steps-action"]'
    )!;
    expect(runningStepsBtn.className).toContain("comma-task-feed-icon-action");
    expect(runningStepsBtn.dataset.active).toBe("false");
    await userEvent.click(runningStepsBtn);
    expect(runningStepsBtn.dataset.active).toBe("true");

    const expandedSteps = Array.from(
      runningPost.querySelectorAll<HTMLElement>('[data-slot="task-feed-milestone"]')
    );
    expect(expandedSteps).toHaveLength(3);
    expect(expandedSteps[0]!.dataset.shimmer).toBe("true");
    expect(expandedSteps[0]!.querySelector(".comma-shiny-text")).not.toBeNull();
    expect(expandedSteps[1]!.dataset.shimmer).toBeUndefined();
    expect(expandedSteps[1]!.querySelector(".comma-shiny-text")).toBeNull();
    expect(expandedSteps[2]!.dataset.shimmer).toBeUndefined();
    expect(expandedSteps[2]!.querySelector(".comma-shiny-text")).toBeNull();

    // 2. Reply and Open-full icon buttons also carry .comma-task-feed-icon-action and toggle data-active cleanly.
    const replyBtn = reviewPost.querySelector<HTMLButtonElement>(
      '[data-slot="task-feed-reply-action"]'
    )!;
    const openFullBtn = reviewPost.querySelector<HTMLButtonElement>(
      '[data-slot="task-feed-open-full-action"]'
    )!;
    expect(replyBtn.className).toContain("comma-task-feed-icon-action");
    expect(openFullBtn.className).toContain("comma-task-feed-icon-action");
    expect(replyBtn.dataset.active).toBe("false");
    await userEvent.click(replyBtn);
    expect(replyBtn.dataset.active).toBe("true");
  });

  it("shows All tasks + Filter in TaskWorkspace Feed mode, narrows to centered single Cancelled column, and shows filter empty state", async () => {
    await page.viewport(1280, 800);
    const tasks: readonly TaskWorkspaceTask[] = TEST_ENTRIES.map((entry) => ({
      activityStatus:
        entry.statusBucket === "in_progress"
          ? "working"
          : entry.statusBucket === "needs_review"
            ? "waiting_for_review"
            : "completed",
      archiveVersion: entry.taskUpdatedAt,
      conversationId: entry.conversationId,
      groupId: entry.groupId,
      id: entry.id,
      labels: [],
      messages: [],
      status: entry.taskStatus,
      statusBucket: entry.statusBucket,
      title: entry.taskTitle,
      updatedAt: entry.taskUpdatedAt,
      workspaceId: "ws-1",
    }));

    mount(
      <TaskWorkspace
        capabilityState="ready"
        feed={{ entries: TEST_ENTRIES }}
        initialView="feed"
        onOpenTask={vi.fn()}
        tasks={tasks}
      />
    );

    await expect.element(page.getByText("All tasks")).toBeVisible();
    const filterTrigger = document.querySelector<HTMLButtonElement>(
      '[data-slot="task-status-filter-trigger"]'
    )!;
    expect(filterTrigger).not.toBeNull();
    expect(filterTrigger.dataset.filtered).toBe("false");
    expect(document.querySelector('[data-slot="task-status-filter-badge"]')).toBeNull();

    // Open Filter -> Status and uncheck Needs Review, In progress, Done so only Cancelled remains.
    await userEvent.click(filterTrigger);
    await userEvent.click(page.getByRole("menuitem", { name: "Status" }));
    const statusDialog = page.getByRole("dialog", { name: "Status" });
    await expect.element(statusDialog).toBeVisible();
    await userEvent.click(
      statusDialog.getByRole("menuitemcheckbox", { name: "Needs Review" })
    );
    await userEvent.click(
      statusDialog.getByRole("menuitemcheckbox", { name: "In progress" })
    );
    await userEvent.click(statusDialog.getByRole("menuitemcheckbox", { name: "Done" }));

    await expect.element(page.getByText("Filtered tasks")).toBeVisible();
    expect(filterTrigger.dataset.filtered).toBe("true");
    expect(
      document.querySelector('[data-slot="task-status-filter-badge"]')
    ).not.toBeNull();

    // Feed converges to a single Cancelled column and hides the column manager.
    const cols = Array.from(
      document.querySelectorAll<HTMLElement>('[data-slot="task-feed-column"]')
    );
    expect(cols.map((col) => col.dataset.column)).toEqual(["cancelled"]);
    expect(document.querySelector('[data-slot="task-feed-add-column"]')).toBeNull();

    // Uncheck Cancelled as well -> renders TaskWorkspaceFilterEmptyState.
    await userEvent.click(
      statusDialog.getByRole("menuitemcheckbox", { name: "Cancelled" })
    );
    expect(
      document.querySelector('[data-slot="task-workspace-filter-empty-state"]')
    ).not.toBeNull();
  });

  it("renders error state instead of loading skeleton when both loading and loadError are set", async () => {
    await page.viewport(1280, 800);
    const onRetry = vi.fn();
    mount(
      <TaskFeedView entries={[]} loadError="Failed to load" loading onRetry={onRetry} />
    );

    expect(document.querySelector('[data-slot="task-feed-error"]')).not.toBeNull();
    expect(document.querySelector('[data-slot="task-feed-loading"]')).toBeNull();
    await expect.element(page.getByText("Failed to load")).toBeVisible();
  });

  it("removes fixed bottom Load more button and triggers ScrollAreaLoadMore when scrolling a tall column to the end", async () => {
    await page.viewport(1280, 600);
    let loadMoreCalled!: () => void;
    const loadMoreRequested = new Promise<void>((resolve) => {
      loadMoreCalled = resolve;
    });
    const onLoadMore = vi.fn(() => loadMoreCalled());
    const tallEntries: TaskFeedEntry[] = Array.from({ length: 12 }, (_, idx) => ({
      ...TEST_ENTRIES[0]!,
      id: `entry-tall-${idx}`,
      conversationId: `conv-tall-${idx}`,
      taskTitle: `Tall task item ${idx + 1}`,
      occurredAt: NOW - (idx + 1) * 60_000,
    }));

    mount(<TaskFeedView entries={tallEntries} hasMore onLoadMore={onLoadMore} />);

    // No fixed bottom "Load more" button exists.
    expect(
      Array.from(document.querySelectorAll("button")).find((btn) =>
        /load more/i.test(btn.textContent ?? "")
      )
    ).toBeUndefined();

    const reviewViewport = document.querySelector<HTMLElement>(
      '[data-column="needs_review"] [data-slot="scroll-area-viewport"]'
    )!;
    expect(reviewViewport).not.toBeNull();
    expect(reviewViewport.scrollHeight).toBeGreaterThan(reviewViewport.clientHeight);
    expect(
      reviewViewport.querySelector('[data-slot="scroll-area-load-more"]')
    ).not.toBeNull();

    // Scroll to the bottom of the scrollable column to trigger onLoadMore.
    reviewViewport.scrollTop = reviewViewport.scrollHeight;
    reviewViewport.dispatchEvent(new Event("scroll"));
    await loadMoreRequested;
    expect(onLoadMore).toHaveBeenCalled();
  });

  it("fits 3 columns at 1440 wide without sideways scrolling", async () => {
    await page.viewport(1440, 900);
    // Long copy widens each column's max-content past its share of the deck.
    const longCopy = "Profiled feed hydration under concurrent conversations ".repeat(
      8
    );
    mount(
      <TaskFeedView
        entries={TEST_ENTRIES.map((entry) => ({ ...entry, outcomeText: longCopy }))}
      />
    );

    const deck = document.querySelector<HTMLElement>(
      '[data-slot="task-feed-desktop-deck"]'
    )!;
    const outerViewport = deck.querySelector<HTMLElement>(
      ':scope > [data-slot="scroll-area"] > [data-slot="scroll-area-viewport"]'
    )!;
    expect(deck.querySelectorAll('[data-slot="task-feed-column"]')).toHaveLength(3);
    expect(outerViewport.scrollWidth).toBe(outerViewport.clientWidth);
  });

  it("scrolls 4 columns horizontally at 1200x800 without clipping the 4th column", async () => {
    await page.viewport(1200, 800);
    mount(
      <TaskFeedView
        defaultVisibleColumns={["needs_review", "in_progress", "done", "cancelled"]}
        entries={TEST_ENTRIES}
      />
    );

    const deck = document.querySelector<HTMLElement>(
      '[data-slot="task-feed-desktop-deck"]'
    )!;
    const outerViewport = deck.querySelector<HTMLElement>(
      ':scope > [data-slot="scroll-area"] > [data-slot="scroll-area-viewport"]'
    )!;
    expect(outerViewport).not.toBeNull();
    expect(outerViewport.scrollWidth).toBeGreaterThan(outerViewport.clientWidth);
    // At the left end the 1st column starts inside the viewport, not clipped.
    const firstCol = deck.querySelector<HTMLElement>('[data-column="needs_review"]')!;
    expect(firstCol.getBoundingClientRect().left).toBeGreaterThanOrEqual(
      outerViewport.getBoundingClientRect().left
    );

    // Scroll to the right end and verify the 4th column fits completely inside the viewport.
    outerViewport.scrollLeft = outerViewport.scrollWidth - outerViewport.clientWidth;
    const viewportRect = outerViewport.getBoundingClientRect();
    const fourthCol = deck.querySelector<HTMLElement>('[data-column="cancelled"]')!;
    const fourthRect = fourthCol.getBoundingClientRect();
    expect(fourthRect.right).toBeLessThanOrEqual(viewportRect.right + 1);
    expect(fourthRect.left).toBeGreaterThanOrEqual(viewportRect.left - 1);
  });

  it("keeps card shadow-xs unchanged on hover", async () => {
    await page.viewport(1280, 800);
    mount(<TaskFeedView entries={TEST_ENTRIES} onOpenEntry={vi.fn()} />);

    const card = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-review-new"]'
    )!;
    const beforeShadow = getComputedStyle(card).boxShadow;
    expect(beforeShadow).not.toBe("none");

    await userEvent.hover(card);
    const afterShadow = getComputedStyle(card).boxShadow;
    expect(afterShadow).toBe(beforeShadow);
  });

  it("keeps task title free of underline on hover", async () => {
    await page.viewport(1280, 800);
    const onOpenEntry = vi.fn();
    mount(<TaskFeedView entries={TEST_ENTRIES} onOpenEntry={onOpenEntry} />);

    const titleEl = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-review-new"] [data-slot="task-feed-title"]'
    )!;
    expect(getComputedStyle(titleEl).textDecorationLine).toBe("none");

    await userEvent.hover(titleEl);
    expect(getComputedStyle(titleEl).textDecorationLine).toBe("none");

    await userEvent.click(titleEl);
    expect(onOpenEntry).toHaveBeenCalledTimes(1);
  });

  it("keeps timestamp inline at the end of a 2-line wrapped title with no 3rd-line drop or left indent", async () => {
    await page.viewport(1280, 800);
    const wrappedEntry: TaskFeedEntry = {
      ...TEST_ENTRIES[0]!,
      id: "entry-wrapped-cn",
      conversationId: "conv-wrapped-cn",
      taskTitle: "每天 8:00 小红书宠物热门帖 Top10 拆解并汇总周报",
      occurredAt: NOW - 2 * 86_400_000,
    };

    mount(
      <div style={{ width: "360px", height: "600px" }}>
        <TaskFeedView
          defaultVisibleColumns={["needs_review"]}
          entries={[wrappedEntry]}
          onOpenEntry={vi.fn()}
        />
      </div>
    );

    const card = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-wrapped-cn"]'
    )!;
    const titleEl = card.querySelector<HTMLElement>('[data-slot="task-feed-title"]')!;
    const timeEl = card.querySelector<HTMLElement>("time")!;
    expect(titleEl.tagName).toBe("SPAN");
    expect(titleEl.getAttribute("role")).toBe("button");

    const titleRects = Array.from(titleEl.getClientRects()).filter((r) => r.width > 0);
    expect(titleRects.length).toBeGreaterThanOrEqual(2);
    const lastTitleLine = titleRects[titleRects.length - 1]!;
    const timeRect = timeEl.getBoundingClientRect();

    // Timestamp sits on the same baseline/line as the last line of the wrapped title, right after it.
    expect(Math.abs(timeRect.bottom - lastTitleLine.bottom)).toBeLessThanOrEqual(6);
    expect(timeRect.left).toBeGreaterThanOrEqual(lastTitleLine.right - 1);
  });

  it("wraps the milestone dot inside the button and applies uniform gray hover background", async () => {
    await page.viewport(1280, 800);
    mount(
      <TaskFeedView
        entries={TEST_ENTRIES}
        onOpenEntry={vi.fn()}
        renderSessionInspector={renderTestInspector}
      />
    );

    const card = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-review-new"]'
    )!;
    const milestone = card.querySelector<HTMLElement>(
      '[data-slot="task-feed-milestone"]'
    )!;
    const btn = milestone.querySelector<HTMLButtonElement>("button")!;
    expect(btn).not.toBeNull();
    // Button wraps the dot indicator (rounded-full) as well as the text.
    expect(btn.querySelector(".rounded-full")).not.toBeNull();

    const cardBg = getComputedStyle(card).backgroundColor;
    await userEvent.hover(btn);
    // The hover tint is a color transition: settle it before reading the color.
    await Promise.all(btn.getAnimations().map((animation) => animation.finished));
    expect(getComputedStyle(btn).backgroundColor).not.toBe("rgba(0, 0, 0, 0)");
    expect(getComputedStyle(btn).backgroundColor).not.toBe(cardBg);

    // The hover target fills the entire timeline block edge-to-edge (0px outer inset).
    const timeline = card.querySelector<HTMLElement>(
      '[data-slot="task-feed-timeline"]'
    )!;
    const timelineRect = timeline.getBoundingClientRect();
    const btnRect = btn.getBoundingClientRect();
    expect(Math.abs(btnRect.left - timelineRect.left)).toBeLessThan(0.5);
    expect(Math.abs(btnRect.right - timelineRect.right)).toBeLessThan(0.5);
    expect(Math.abs(btnRect.top - timelineRect.top)).toBeLessThan(0.5);
    expect(Math.abs(btnRect.bottom - timelineRect.bottom)).toBeLessThan(0.5);
  });

  it("collapses inline reply composer when clicking blank space outside or inside the card, without opening the card inspector or losing the draft", async () => {
    await page.viewport(1280, 800);
    mount(
      <TaskFeedView
        entries={TEST_ENTRIES}
        onReplyEntry={vi.fn()}
        renderSessionInspector={renderTestInspector}
      />
    );

    const runningCol = document.querySelector<HTMLElement>(
      '[data-column="in_progress"]'
    )!;
    const runningPost = runningCol.querySelector<HTMLElement>(
      '[data-entry-id="entry-running-1"]'
    )!;
    const runningReplyBtn = runningPost.querySelector<HTMLButtonElement>(
      '[data-slot="task-feed-reply-action"]'
    )!;

    // 1. Open reply and type a draft; clicking inside the reply pill keeps it open.
    await userEvent.click(runningReplyBtn);
    const input = runningPost.querySelector<HTMLInputElement>("input")!;
    expect(input).not.toBeNull();
    expect(document.activeElement).toBe(input);
    await userEvent.fill(input, "Keep this draft");
    await userEvent.click(
      runningPost.querySelector<HTMLElement>('[data-slot="task-feed-inline-reply"]')!
    );
    expect(
      runningPost.querySelector('[data-slot="task-feed-inline-reply"]')
    ).not.toBeNull();

    // 2. Clicking blank space outside the card collapses the reply composer, preserves draft, and does not steal focus back to the reply button.
    const emptyColViewport = document.querySelector<HTMLElement>(
      '[data-column="done"] [data-slot="scroll-area-viewport"]'
    )!;
    const colRect = emptyColViewport.getBoundingClientRect();
    await userEvent.click(emptyColViewport, {
      position: { x: colRect.width / 2, y: colRect.height - 24 },
    });
    await expect
      .element(page.getByRole("textbox", { name: "Reply to this task…" }))
      .not.toBeInTheDocument();
    expect(runningReplyBtn.dataset.active).toBe("false");
    expect(document.activeElement).not.toBe(runningReplyBtn);
    expect(runningCol.dataset.drilledIn).toBe("false");

    // 3. Reopening preserves the draft; clicking blank space inside the same card collapses the composer WITHOUT drilling into the task inspector.
    await userEvent.click(runningReplyBtn);
    const reopenedInput = runningPost.querySelector<HTMLInputElement>("input")!;
    expect(reopenedInput.value).toBe("Keep this draft");

    const actionsBar = runningPost.querySelector<HTMLElement>(
      '[data-slot="task-feed-actions"]'
    )!;
    const actionsRect = actionsBar.getBoundingClientRect();
    await userEvent.click(actionsBar, {
      position: { x: actionsRect.width - 12, y: actionsRect.height / 2 },
    });
    await expect
      .element(page.getByRole("textbox", { name: "Reply to this task…" }))
      .not.toBeInTheDocument();
    expect(runningReplyBtn.dataset.active).toBe("false");
    expect(runningCol.dataset.drilledIn).toBe("false");

    // Clicking the card whitespace again (now closed) drills into the inspector as usual.
    await userEvent.click(actionsBar, {
      position: { x: actionsRect.width - 12, y: actionsRect.height / 2 },
    });
    expect(runningCol.dataset.drilledIn).toBe("true");
  });

  it("keeps inline reply open when pointer drag starts inside the input and releases outside, and switches cleanly to another card's reply", async () => {
    await page.viewport(1280, 800);
    mount(
      <TaskFeedView
        entries={TEST_ENTRIES}
        onReplyEntry={vi.fn()}
        renderSessionInspector={renderTestInspector}
      />
    );

    const reviewPost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-review-new"]'
    )!;
    const runningPost = document.querySelector<HTMLElement>(
      '[data-entry-id="entry-running-1"]'
    )!;
    const reviewReplyBtn = reviewPost.querySelector<HTMLButtonElement>(
      '[data-slot="task-feed-reply-action"]'
    )!;
    const runningReplyBtn = runningPost.querySelector<HTMLButtonElement>(
      '[data-slot="task-feed-reply-action"]'
    )!;

    await userEvent.click(reviewReplyBtn);
    const reviewInput = reviewPost.querySelector<HTMLInputElement>("input")!;
    expect(reviewInput).not.toBeNull();

    // Drag selection starting inside the input and ending outside produces a click outside the composer: must stay open.
    reviewInput.dispatchEvent(
      new PointerEvent("pointerdown", { bubbles: true, button: 0, pointerId: 1 })
    );
    reviewPost.dispatchEvent(
      new MouseEvent("click", { bubbles: true, cancelable: true, detail: 1 })
    );
    expect(
      reviewPost.querySelector('[data-slot="task-feed-inline-reply"]')
    ).not.toBeNull();
    expect(document.querySelector('[data-slot="task-feed-column-chat"]')).toBeNull();

    // Clicking another card's reply button collapses the first card's reply and opens + focuses the second.
    await userEvent.click(runningReplyBtn);
    await expect
      .element(page.getByRole("textbox", { name: "Reply to this task…" }))
      .toBeVisible();
    const runningInput = runningPost.querySelector<HTMLInputElement>("input")!;
    expect(runningInput).not.toBeNull();
    expect(document.activeElement).toBe(runningInput);
    expect(reviewReplyBtn.dataset.active).toBe("false");
    expect(runningReplyBtn.dataset.active).toBe("true");
  });
});
