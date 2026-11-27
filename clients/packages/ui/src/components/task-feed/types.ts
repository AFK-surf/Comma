import type { ReactElement, ReactNode } from "react";
import type { TaskStatusBucket } from "../task-workspace/taskStatus";

export type TaskFeedTriggerKind =
  | "brief"
  | "follow_up"
  | "loop_run"
  | "run"
  | "unknown";

export type TaskFeedStatusFilter = "all" | "needs_review" | "in_progress" | "done";

export type TaskFeedColumnId = "needs_review" | "in_progress" | "done" | "cancelled";

export interface TaskFeedMilestone {
  title: string;
  at?: number | undefined;
  messageId?: string | undefined;
}

export interface TaskFeedMedia {
  attachmentId: string;
  mimeType?: string | undefined;
  width?: number | undefined;
  height?: number | undefined;
  filename?: string | undefined;
}

export interface TaskFeedFile {
  name: string;
  mimeType?: string | undefined;
}

export interface TaskFeedPullRequest {
  number: number;
  state: "open" | "draft" | "merged" | "closed";
  url: string;
}

export interface TaskFeedEntry {
  id: string;
  conversationId: string;
  groupId: string;
  clusterKey: string;
  triggerKind: TaskFeedTriggerKind;
  triggerText?: string | undefined;
  taskTitle: string;
  taskStatus: string;
  statusBucket: TaskStatusBucket;
  taskUpdatedAt: number;
  reviewVersion?: number | undefined;
  origin?: string | undefined;
  isLoop: boolean;
  loopKind?: string | undefined;
  occurredAt: number;
  milestones: readonly TaskFeedMilestone[];
  milestoneCount: number;
  outcomeMessageId?: string | undefined;
  outcomeText?: string | undefined;
  media: readonly TaskFeedMedia[];
  files: readonly TaskFeedFile[];
  pullRequest?: TaskFeedPullRequest | undefined;
}

export interface TaskFeedSessionInspectorContext {
  entry: TaskFeedEntry;
  onApproveEntry?: ((entry: TaskFeedEntry) => Promise<void> | void) | undefined;
  onClose: () => void;
  onOpenFullTask?: ((entry: TaskFeedEntry, messageId?: string) => void) | undefined;
  onReplyEntry?:
    | ((entry: TaskFeedEntry, text: string) => Promise<void> | void)
    | undefined;
  revealMessageId?: string | undefined;
}

export interface TaskFeedViewProps {
  allowedColumns?: readonly TaskFeedColumnId[] | undefined;
  attentionOnly?: boolean | undefined;
  className?: string | undefined;
  defaultExpandedEntryIds?: readonly string[] | undefined;
  defaultReplyEntryId?: string | undefined;
  defaultRevealMessageId?: string | undefined;
  defaultSelectedEntryId?: string | undefined;
  defaultVisibleColumns?: readonly TaskFeedColumnId[] | undefined;
  entries: readonly TaskFeedEntry[];
  filterActive?: boolean | undefined;
  hasMore?: boolean | undefined;
  lastSeenAt?: number | undefined;
  loadError?: string | undefined;
  loadMoreError?: string | undefined;
  loadMorePending?: boolean | undefined;
  loading?: boolean | undefined;
  onApproveEntry?: ((entry: TaskFeedEntry) => Promise<void> | void) | undefined;
  onAttentionOnlyChange?: ((attentionOnly: boolean) => void) | undefined;
  onCreateTask?: (() => void) | undefined;
  onLoadMore?: (() => Promise<void> | void) | undefined;
  onMarkCaughtUp?: (() => Promise<void> | void) | undefined;
  onOpenEntry?: ((entry: TaskFeedEntry, messageId?: string) => void) | undefined;
  onReplyEntry?:
    | ((entry: TaskFeedEntry, text: string) => Promise<void> | void)
    | undefined;
  onRetry?: (() => Promise<void> | void) | undefined;
  onRevealMilestone?: ((entry: TaskFeedEntry, messageId: string) => void) | undefined;
  renderFile?:
    | ((
        file: TaskFeedFile,
        entry: TaskFeedEntry,
        defaultNode: ReactElement
      ) => ReactNode)
    | undefined;
  renderMedia?:
    | ((media: readonly TaskFeedMedia[], entry: TaskFeedEntry) => ReactNode)
    | undefined;
  renderPullRequest?:
    | ((
        pullRequest: TaskFeedPullRequest,
        entry: TaskFeedEntry,
        defaultNode: ReactElement
      ) => ReactNode)
    | undefined;
  /**
   * Renders the desktop right-pane Live Session Inspector for the currently
   * selected Feed entry. On narrow viewports (< 960px), the inspector hides and
   * entry clicks fall back to `onOpenEntry` / `onRevealMilestone`.
   */
  renderSessionInspector?:
    | ((context: TaskFeedSessionInspectorContext) => ReactNode)
    | undefined;
}
