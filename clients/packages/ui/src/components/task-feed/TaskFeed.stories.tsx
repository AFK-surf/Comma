import type { Meta, StoryObj } from "@storybook/react-vite";
import { useMemo, useState } from "react";
import { fn } from "storybook/test";
import { uiClock } from "../../clock";
import { TaskProgressContext } from "../task-workspace/taskProgress";
import { TaskWorkspace, type TaskWorkspaceTask } from "../task-workspace/TaskWorkspace";
import { cx } from "../utils";
import { TaskFeedView } from "./TaskFeedView";
import type { TaskFeedEntry, TaskFeedMedia } from "./types";

const NOW = uiClock.now();

export const STORY_ENTRIES: readonly TaskFeedEntry[] = [
  // Needs review (2)
  {
    id: "entry-review-1",
    conversationId: "conv-review-1",
    groupId: "group-1",
    clusterKey: "cluster-review-1",
    triggerKind: "brief",
    taskTitle: "Feed pagination latency benchmark",
    taskStatus: "needs_review",
    statusBucket: "needs_review",
    taskUpdatedAt: NOW - 14 * 60_000,
    reviewVersion: 7,
    isLoop: false,
    occurredAt: NOW - 14 * 60_000,
    milestones: [
      {
        title: "Opened PR #1842 with latency & heap charts",
        at: NOW - 14 * 60_000,
        messageId: "msg-rev-4",
      },
      {
        title: "Added deterministic cursor dedupe tests",
        at: NOW - 21 * 60_000,
        messageId: "msg-rev-3-tool",
      },
      {
        title: "Replaced per-item fan-out with indexed milestone window query",
        at: NOW - 30 * 60_000,
        messageId: "msg-rev-2",
      },
      {
        title: "Profiled feed hydration under 500 concurrent conversations",
        at: NOW - 41 * 60_000,
        messageId: "msg-rev-1",
      },
    ],
    milestoneCount: 6,
    outcomeMessageId: "msg-rev-4",
    outcomeText:
      "Cut p95 feed hydration latency from 42 ms to 18 ms and trimmed retained snapshot heap by 64%. Ready for review before merging PR #1842.",
    media: [
      { attachmentId: "att-latency-chart", filename: "latency-distribution.png" },
    ],
    files: [{ name: "feed-hydration-profile.json" }],
    pullRequest: {
      number: 1842,
      state: "open",
      url: "https://github.com/AFK-surf/Cue/pull/1842",
    },
  },
  {
    id: "entry-review-2",
    conversationId: "conv-review-2",
    groupId: "group-1",
    clusterKey: "cluster-review-2",
    triggerKind: "follow_up",
    taskTitle: "OAuth token refresh retry backoff",
    taskStatus: "needs_review",
    statusBucket: "needs_review",
    taskUpdatedAt: NOW - 38 * 60_000,
    reviewVersion: 3,
    isLoop: false,
    occurredAt: NOW - 38 * 60_000,
    milestones: [
      {
        title: "Verified single-flight refresh lock across parallel tabs",
        at: NOW - 38 * 60_000,
        messageId: "msg-rev2-2",
      },
      {
        title: "Added jittered exponential backoff for 429/503 responses",
        at: NOW - 52 * 60_000,
        messageId: "msg-rev2-1-tool",
      },
    ],
    milestoneCount: 2,
    outcomeMessageId: "msg-rev2-2",
    outcomeText:
      "Coalesced concurrent token refreshes into a single-flight lock with bounded jittered backoff. Awaiting final sign-off on PR #1845.",
    media: [],
    files: [],
    pullRequest: {
      number: 1845,
      state: "open",
      url: "https://github.com/AFK-surf/Cue/pull/1845",
    },
  },

  // In progress (2)
  {
    id: "entry-running-1",
    conversationId: "conv-running-1",
    groupId: "group-1",
    clusterKey: "cluster-running-1",
    triggerKind: "loop_run",
    taskTitle: "macOS staging release patrol",
    taskStatus: "in_progress",
    statusBucket: "in_progress",
    taskUpdatedAt: NOW - 2 * 60_000,
    isLoop: true,
    loopKind: "scheduled",
    occurredAt: NOW - 2 * 60_000,
    milestones: [
      {
        title: "Verified notarization staple and Gatekeeper assessment",
        at: NOW - 2 * 60_000,
        messageId: "msg-r2",
      },
      {
        title: "Fetched latest staging build 1428 artifacts",
        at: NOW - 9 * 60_000,
        messageId: "msg-r1-tool",
      },
      {
        title: "Provisioned clean macOS 15 arm64 runner image",
        at: NOW - 13 * 60_000,
        messageId: "msg-r0",
      },
    ],
    milestoneCount: 3,
    outcomeMessageId: "msg-r2",
    outcomeText:
      "Build 1428 passed notarization and Gatekeeper checks; executing clean-image cold-start smoke test for OAuth callback handoff.",
    media: [],
    files: [],
  },
  {
    id: "entry-running-2",
    conversationId: "conv-running-2",
    groupId: "group-1",
    clusterKey: "cluster-running-2",
    triggerKind: "brief",
    taskTitle: "WebSocket reconnect state compaction",
    taskStatus: "in_progress",
    statusBucket: "in_progress",
    taskUpdatedAt: NOW - 19 * 60_000,
    isLoop: false,
    occurredAt: NOW - 19 * 60_000,
    milestones: [
      {
        title: "Completed 148/200 flaky network reconnect cycles",
        at: NOW - 19 * 60_000,
        messageId: "msg-r2-2",
      },
      {
        title: "Coalesced bursty reconnect deltas into single snapshot patch",
        at: NOW - 31 * 60_000,
        messageId: "msg-r2-1-tool",
      },
    ],
    milestoneCount: 2,
    outcomeMessageId: "msg-r2-2",
    outcomeText:
      "Merged bursty post-sleep replay frames before React commit; stress test is at 148/200 reconnect cycles with zero duplicates.",
    media: [],
    files: [],
  },

  // Done (2)
  {
    id: "entry-done-1",
    conversationId: "conv-done-1",
    groupId: "group-1",
    clusterKey: "cluster-done-1",
    triggerKind: "brief",
    taskTitle: "Migrate task search index to trigram",
    taskStatus: "done",
    statusBucket: "done",
    taskUpdatedAt: NOW - 2 * 3_600_000,
    isLoop: false,
    occurredAt: NOW - 2 * 3_600_000,
    milestones: [
      {
        title: "Merged PR #1839 and verified p99 query latency",
        at: NOW - 2 * 3_600_000,
        messageId: "msg-d2",
      },
      {
        title: "Backfilled trigram index across 142k task titles",
        at: NOW - 3 * 3_600_000,
        messageId: "msg-d1-tool",
      },
    ],
    milestoneCount: 2,
    outcomeMessageId: "msg-d2",
    outcomeText:
      "Trigram index live in production. Substring task search p99 improved from 310 ms to 9 ms with zero read-lock impact.",
    media: [],
    files: [{ name: "trigram-bench-report.md" }],
    pullRequest: {
      number: 1839,
      state: "merged",
      url: "https://github.com/AFK-surf/Cue/pull/1839",
    },
  },
  {
    id: "entry-done-2",
    conversationId: "conv-done-2",
    groupId: "group-1",
    clusterKey: "cluster-done-2",
    triggerKind: "loop_run",
    taskTitle: "Nightly crash symbol upload",
    taskStatus: "done",
    statusBucket: "done",
    taskUpdatedAt: NOW - 5 * 3_600_000,
    isLoop: true,
    loopKind: "scheduled",
    occurredAt: NOW - 5 * 3_600_000,
    milestones: [
      {
        title: "Pruned expired staging symbol archives (>30d)",
        at: NOW - 5 * 3_600_000,
        messageId: "msg-d2-2",
      },
      {
        title: "Uploaded 14 dSYM and source-map bundles to symbol server",
        at: NOW - 5 * 3_600_000 - 120_000,
        messageId: "msg-d2-1-tool",
      },
    ],
    milestoneCount: 2,
    outcomeMessageId: "msg-d2-2",
    outcomeText:
      "Uploaded 14 release 0.42.x symbol bundles and reclaimed 4.8 GB from expired staging archives.",
    media: [],
    files: [],
  },

  // Cancelled (1)
  {
    id: "entry-cancelled-1",
    conversationId: "conv-cancelled-1",
    groupId: "group-1",
    clusterKey: "cluster-cancelled-1",
    triggerKind: "brief",
    taskTitle: "Legacy polling fallback cleanup",
    taskStatus: "cancelled",
    statusBucket: "cancelled",
    taskUpdatedAt: NOW - 26 * 3_600_000,
    isLoop: false,
    occurredAt: NOW - 26 * 3_600_000,
    milestones: [
      {
        title: "Cancelled before rollout",
        at: NOW - 26 * 3_600_000,
        messageId: "msg-c1",
      },
    ],
    milestoneCount: 1,
    outcomeMessageId: "msg-c1",
    outcomeText:
      "Superseded by the unified SSE reconnect compaction work; keeping existing fallback untouched until next minor release.",
    media: [],
    files: [],
  },
];

const LATENCY_BENCH_ROWS = [
  { label: "p50", beforeMs: 21, afterMs: 9, beforePct: 50, afterPct: 21 },
  { label: "p90", beforeMs: 34, afterMs: 14, beforePct: 81, afterPct: 33 },
  { label: "p95", beforeMs: 42, afterMs: 18, beforePct: 100, afterPct: 43 },
] as const;

function renderStoryMedia(media: readonly TaskFeedMedia[]) {
  if (media.length === 0) return null;
  return (
    <div className="overflow-hidden rounded-2xl border border-secondary bg-secondary/25 px-3.5 py-3">
      <div className="flex flex-wrap items-baseline justify-between gap-x-3">
        <span className="text-xs font-medium text-secondary">
          Feed hydration latency
        </span>
        <span className="shrink-0 text-xs font-semibold tabular-nums text-primary">
          42 ms → 18 ms <span className="font-normal text-tertiary">(-57%)</span>
        </span>
      </div>

      <div className="mt-2.5 flex flex-col gap-2">
        {LATENCY_BENCH_ROWS.map((row) => (
          <div
            className="grid grid-cols-[28px_minmax(0,1fr)_84px] items-center gap-2.5"
            key={row.label}
          >
            <span className="text-[11px] font-medium tabular-nums text-quaternary">
              {row.label}
            </span>
            <div className="flex flex-col gap-1">
              <div
                className="h-1.5 rounded-full bg-[var(--color-fg-quinary)]/45"
                style={{ width: `${row.beforePct}%` }}
              />
              <div
                className="h-1.5 rounded-full bg-brand-solid"
                style={{ width: `${row.afterPct}%` }}
              />
            </div>
            <span className="text-right text-[11px] tabular-nums text-tertiary">
              <span className="text-quaternary line-through">{row.beforeMs}ms</span>{" "}
              <span className="font-semibold text-primary">{row.afterMs}ms</span>
            </span>
          </div>
        ))}
      </div>

      <div className="mt-2.5 flex flex-wrap items-center justify-between gap-x-3 gap-y-1 border-t border-secondary pt-2 text-[11px] text-quaternary">
        <div className="flex flex-wrap items-center gap-x-3">
          <span className="inline-flex items-center gap-1.5">
            <span className="size-1.5 rounded-full bg-[var(--color-fg-quinary)]/60" />
            Before
          </span>
          <span className="inline-flex items-center gap-1.5 text-secondary">
            <span className="size-1.5 rounded-full bg-brand-solid" />
            After cursor cache
          </span>
        </div>
        <span className="tabular-nums text-tertiary">Heap 3.9 → 1.4 MB</span>
      </div>
    </div>
  );
}

const STORY_PROGRESS_SOURCE = {
  progressOf(taskId: string) {
    if (taskId === "conv-running-1") {
      return "Running clean-image OAuth callback smoke test";
    }
    if (taskId === "conv-running-2") {
      return "Verifying zero duplicate frames across remaining 52 cycles";
    }
    return undefined;
  },
  subscribe() {
    return () => {};
  },
};

/**
 * Reuses Comma's real `@comma/ui` Task Chat primitives:
 * `<ContentHeader>`, `<ChatPanelMessageItem variant="task">`, and `<AiInput size="small">`.
 */
function InteractiveDeckStory({
  dark = false,
  defaultExpandedEntryIds,
  defaultReplyEntryId,
  initialEntries = STORY_ENTRIES,
}: {
  dark?: boolean;
  defaultExpandedEntryIds?: readonly string[];
  defaultReplyEntryId?: string;
  initialEntries?: readonly TaskFeedEntry[];
}) {
  const [entries, setEntries] = useState<readonly TaskFeedEntry[]>(initialEntries);
  const [lastSeenAt, setLastSeenAt] = useState<number>(NOW - 45 * 60_000);

  const handleApprove = (entry: TaskFeedEntry) => {
    setEntries((prev) =>
      prev.map((item) =>
        item.id === entry.id
          ? {
              ...item,
              statusBucket: "done",
              taskStatus: "done",
              reviewVersion: undefined,
            }
          : item
      )
    );
  };

  return (
    <TaskProgressContext.Provider value={STORY_PROGRESS_SOURCE}>
      <div
        className={cx(
          "h-screen w-screen overflow-hidden bg-todo-kanban-bg-column-primary",
          dark ? "dark" : ""
        )}
      >
        <TaskFeedView
          defaultExpandedEntryIds={defaultExpandedEntryIds}
          defaultReplyEntryId={defaultReplyEntryId}
          entries={entries}
          lastSeenAt={lastSeenAt}
          onApproveEntry={handleApprove}
          onMarkCaughtUp={() => setLastSeenAt(NOW)}
          onOpenEntry={fn()}
          onReplyEntry={fn()}
          renderMedia={renderStoryMedia}
        />
      </div>
    </TaskProgressContext.Provider>
  );
}

const WORKSPACE_TASKS: readonly TaskWorkspaceTask[] = STORY_ENTRIES.map((entry) => ({
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
  loop: entry.isLoop ? { kind: "scheduled" as const } : undefined,
  messages: [],
  status: entry.taskStatus,
  statusBucket: entry.statusBucket,
  title: entry.taskTitle,
  updatedAt: entry.taskUpdatedAt,
  workspaceId: "ws-1",
}));

function WorkspaceIntegrationStory() {
  const [entries, setEntries] = useState<readonly TaskFeedEntry[]>(STORY_ENTRIES);
  const [lastSeenAt, setLastSeenAt] = useState<number>(NOW - 45 * 60_000);

  const feedProps = useMemo(
    () => ({
      entries,
      lastSeenAt,
      onApproveEntry: (entry: TaskFeedEntry) => {
        setEntries((prev) =>
          prev.map((item) =>
            item.id === entry.id
              ? {
                  ...item,
                  statusBucket: "done",
                  taskStatus: "done",
                  reviewVersion: undefined,
                }
              : item
          )
        );
      },
      onMarkCaughtUp: () => setLastSeenAt(NOW),
      onOpenEntry: fn(),
      onReplyEntry: fn(),
      renderMedia: renderStoryMedia,
    }),
    [entries, lastSeenAt]
  );

  return (
    <TaskProgressContext.Provider value={STORY_PROGRESS_SOURCE}>
      <div className="h-screen w-screen overflow-hidden bg-main-panel-bg">
        <TaskWorkspace
          capabilityState="ready"
          feed={feedProps}
          initialView="board"
          onOpenTask={fn()}
          tasks={WORKSPACE_TASKS}
        />
      </div>
    </TaskProgressContext.Provider>
  );
}

const meta: Meta<typeof TaskFeedView> = {
  title: "Tasks/TaskFeed",
  component: TaskFeedView,
  excludeStories: ["STORY_ENTRIES"],
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;
type Story = StoryObj<typeof TaskFeedView>;

export const ThreadsDeckLight: Story = {
  render: () => <InteractiveDeckStory />,
};

export const ThreadsDeckDark: Story = {
  render: () => <InteractiveDeckStory dark />,
};

export const ThreadsDeckNarrow: Story = {
  render: () => <InteractiveDeckStory />,
};

export const ThreadsDeckEmptyColumns: Story = {
  render: () => (
    <InteractiveDeckStory
      initialEntries={STORY_ENTRIES.filter(
        (entry) => entry.statusBucket === "needs_review"
      )}
    />
  ),
};

export const WorkspaceIntegration: Story = {
  render: () => <WorkspaceIntegrationStory />,
};
