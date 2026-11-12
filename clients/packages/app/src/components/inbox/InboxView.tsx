import { countTaskLoopRules } from "@comma/core/task-loop-filter";
import { useTaskLoopRuleFilter } from "../tasks/useTaskLoopRuleFilter";
import { uiClock } from "@comma/ui/clock";
import { InboxList } from "./InboxList";
import { PageLoading } from "@comma/ui/components/PageLoading";
import { formatNumber } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  useCall,
  type ProductInboxItem,
  type ProductInboxListResult,
  type ProductInboxListSource,
} from "@comma/core-client";
import { Button } from "@comma/ui/components/Button";
import { ContentHeader } from "@comma/ui/components/content-header";
import { ScrollArea, ScrollAreaLoadMore } from "@comma/ui/components/scroll-area";
import { XIcon } from "@comma/ui/components/icons";
import { toast } from "@comma/ui/components/toast";
import { useNavigate } from "@tanstack/react-router";
import { useCallback, useEffect, useMemo, useRef } from "react";
import { useTaskReviewSeenMarks } from "../tasks/taskReviewAttention";
import { InboxActionsMenu } from "./InboxActionsMenu";
import { RailResizeHandle, useRailWidth } from "../railResize";
import { commaInboxConversationRailWidth } from "../shellGeometry";
import {
  InboxRequestRowView,
  InboxSentRowView,
  useInboxRequestRows,
  useInboxSentRows,
  type InboxRequestEntry,
  type InboxSentRow,
} from "./TaskRequestInbox";
import { InboxFilterMenu } from "./filters/InboxFilterMenu";
import { useInboxFilters } from "./filters/InboxFiltersState";
import type { InboxWorkspaceSelector } from "./filters/InboxFilterPanels";
import {
  applyInboxFilters,
  applyInboxRequestFilters,
  countInboxItemsByPlatform,
  countInboxRequests,
  countInboxTasksBySchedule,
  countInboxTasksByStatus,
  isInboxFiltered,
  unfilteredInbox,
} from "./filters/inboxFilters";
import {
  formatCompactRelative,
  groupInboxItems,
  normalizeTimestamp,
} from "./InboxGroup";
import type { InboxListEntry } from "./InboxList";
import {
  isInboxItemDeleted,
  isInboxItemUnread,
  useInboxMarkActions,
  useInboxDeletedMarks,
  useInboxUnreadMarks,
} from "./inboxDeletion";
import { useInboxSyncToasts } from "./useInboxSyncToasts";
import { usePublishTaskSequence, type TaskSequence } from "../tasks/taskSequence";

export interface InboxViewProps {
  loadMoreError?: string | undefined;
  loadMorePending?: boolean | undefined;
  onLoadMore?: (() => void) | undefined;
  result: ProductInboxListResult | null;
  selectedConversationId?: string | undefined;
  /** The request open in the detail pane, if one is. */
  selectedRequestId?: string | undefined;
  workspaceSelector?: InboxWorkspaceSelector | undefined;
}

/**
 * Figma 379:5180 — the Inbox conversation rail. Data and navigation stay in
 * the app layer; the visual rows, badges, controls, and scrolling come from
 * shared @comma/ui components. It renders caller-supplied source states without
 * fabricated data.
 */
export function InboxView({
  loadMoreError,
  loadMorePending = false,
  onLoadMore,
  result,
  selectedConversationId,
  selectedRequestId,
  workspaceSelector,
}: InboxViewProps) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  // The reader may widen the list up to half the window; its divider resets it.
  const railRef = useRef<HTMLElement | null>(null);
  const { width: railWidth, setWidth: setRailWidth } = useRailWidth(
    "comma.inboxRailWidth",
    commaInboxConversationRailWidth
  );
  const [filters, setFilters] = useInboxFilters();
  const deletedMarks = useInboxDeletedMarks();
  const markActions = useInboxMarkActions();
  const unreadMarks = useInboxUnreadMarks();
  const seenMarks = useTaskReviewSeenMarks();
  useInboxSyncToasts(result, loadMoreError, onLoadMore);
  // Someone's requests waiting for the owner are notifications too, among the Tasks by when they came, until answered.
  // A request is no Task's platform, status or schedule, so any filter hides the requests with the rest it leaves out.
  const call = useCall();
  // Requests the person sent follow along too, as the Tasks they asked for.
  const incomingRows = useInboxRequestRows();
  const allSentRows = useInboxSentRows();
  // A sent request the person deleted stays hidden until its decision or its Task's status changes.
  const sentRows = useMemo(
    () => allSentRows.filter((row) => !isInboxItemDeleted(deletedMarks, row)),
    [allSentRows, deletedMarks]
  );
  const allRequestRows = useMemo<InboxRequestEntry[]>(
    () => [...incomingRows, ...sentRows],
    [incomingRows, sentRows]
  );
  // Opening the Inbox reads them again: the server tells no client of a new one.
  useEffect(() => {
    void call("taskRequests.refresh", {}).catch(() => undefined);
  }, [call]);
  // Archived conversations and deleted notifications leave the rail; filters
  // only hide rows, and the footer reports how many.
  const items = useMemo(
    () =>
      (result?.items ?? []).filter(
        (item) => item.status !== "archived" && !isInboxItemDeleted(deletedMarks, item)
      ),
    [result?.items, deletedMarks]
  );
  const visibleItems = useMemo(
    () => applyInboxFilters(items, filters),
    [items, filters]
  );
  const [readItems, unreadItems] = useMemo(() => {
    const read: ProductInboxItem[] = [];
    const unread: ProductInboxItem[] = [];
    for (const item of visibleItems) {
      (isInboxItemUnread(seenMarks, unreadMarks, item) ? unread : read).push(item);
    }
    return [read, unread];
  }, [visibleItems, seenMarks, unreadMarks]);
  const filtered = isInboxFiltered(filters);
  const requestRows = useMemo(
    () =>
      filtered ? applyInboxRequestFilters(allRequestRows, filters) : allRequestRows,
    [allRequestRows, filtered, filters]
  );
  const hiddenCount =
    items.length - visibleItems.length + allRequestRows.length - requestRows.length;
  const day = new Date(uiClock.now()).setHours(0, 0, 0, 0);
  const groups = useMemo(
    () => groupInboxItems(mergeByTime(visibleItems, requestRows), locale, day),
    [visibleItems, requestRows, locale, day]
  );
  // The open conversation's header steps through the rail in the order it shows.
  const navigate = useNavigate();
  const { clearUnread } = markActions;
  const sequence = useMemo<TaskSequence | undefined>(() => {
    if (!result) return undefined;
    // Stepping goes through the Tasks: a request is answered from its own pane, not stepped through.
    const rows = groups
      .flatMap((group) => group.items)
      .filter((row): row is ProductInboxItem => !isRequestRow(row));
    return {
      entries: rows,
      open: (index) => {
        const item = rows[index];
        if (!item) return;
        clearUnread([item.id]);
        void navigate({
          params: {
            conversationId: item.conversationId,
            groupId: item.groupId,
            workspaceId: item.workspaceId,
          },
          replace: true,
          to: "/inbox/$workspaceId/$groupId/$conversationId",
        });
      },
    };
  }, [clearUnread, groups, navigate, result]);
  usePublishTaskSequence(sequence);
  const platformCounts = useMemo(() => countInboxItemsByPlatform(items), [items]);
  const requestCounts = useMemo(
    () =>
      countInboxRequests(
        items,
        allRequestRows,
        messages.task_requests_unknown_person(),
        locale
      ),
    [allRequestRows, items, locale, messages]
  );
  const statusCounts = useMemo(() => countInboxTasksByStatus(items), [items]);
  const scheduleCounts = useMemo(() => countInboxTasksBySchedule(items), [items]);
  const loopTasks = useMemo(
    () => items.filter((item) => item.kind === "agent_task"),
    [items]
  );
  const loopRules = useMemo(() => countTaskLoopRules(loopTasks), [loopTasks]);
  const editLoopRule = useCallback(
    (loopRule: string | undefined) =>
      setFilters((current) => ({ ...current, loopRule })),
    [setFilters]
  );
  const ruleSection = useTaskLoopRuleFilter(
    loopRules,
    loopTasks.length,
    filters.loopRule,
    editLoopRule
  );
  const sourceLabels: Record<ProductInboxListSource, string> = {
    cache: messages.inbox_source_cache(),
    "live-sync": messages.inbox_source_live(),
    error: messages.inbox_source_error(),
    unavailable: messages.inbox_source_unavailable(),
  };

  // Deleting acts on what the rail lists right now, filters included: its Tasks and the sent requests already decided
  // (one still waiting is withdrawn, not hidden; none carries the attention dot). Deleting the open one closes it too.
  const decidedSentRows = requestRows.filter(
    (row): row is InboxSentRow =>
      row.kind === "task_request_sent" && row.sent.status !== "pending"
  );
  const deleteItems = (targets: readonly (ProductInboxItem | InboxSentRow)[]) => {
    markActions.deleteItems(targets);
    if (
      targets.some((target) =>
        isRequestRow(target)
          ? target.sent.id === selectedRequestId
          : target.conversationId === selectedConversationId
      )
    ) {
      void navigate({ replace: true, to: "/inbox" });
    }
    toast.success(
      messages.inbox_deleted_count({
        count: targets.length,
        formattedCount: formatNumber(targets.length, locale),
      })
    );
  };

  return (
    <aside
      aria-label={messages.inbox_region()}
      className="relative flex h-full min-h-0 shrink-0 flex-col border-r-[0.5px] border-primary bg-main-panel-bg"
      data-testid="inbox-conversation-rail"
      ref={railRef}
      style={{ flexBasis: railWidth, width: railWidth }}
    >
      <RailResizeHandle
        hint={messages.rail_resize_hint()}
        label={messages.inbox_rail_resize()}
        minWidth={commaInboxConversationRailWidth}
        onWidthChange={setRailWidth}
        rail={railRef}
        testId="inbox-rail-resize"
        width={railWidth}
      />
      <ContentHeader className="comma-inbox-rail-header justify-between">
        <h1 className="m-0 text-sm font-medium leading-5 tracking-[-0.14px] text-primary">
          {messages.inbox_title()}
        </h1>
        <div className="flex items-center gap-xs">
          <InboxActionsMenu
            canDeleteAll={visibleItems.length + decidedSentRows.length > 0}
            canDeleteRead={readItems.length + decidedSentRows.length > 0}
            canMarkAllRead={unreadItems.length > 0}
            onDeleteAll={() => deleteItems([...visibleItems, ...decidedSentRows])}
            onDeleteRead={() => deleteItems([...readItems, ...decidedSentRows])}
            onMarkAllRead={() => markActions.markRead(unreadItems)}
          />
          <InboxFilterMenu
            filters={filters}
            onFiltersChange={setFilters}
            platformCounts={platformCounts}
            requestCounts={requestCounts}
            scheduleCounts={scheduleCounts}
            ruleSection={ruleSection}
            statusCounts={statusCounts}
            workspaceSelector={workspaceSelector}
          />
        </div>
      </ContentHeader>

      {result ? (
        <span
          className="app-sr-only"
          data-source={result.source}
          data-testid="inbox-source"
        >
          {sourceLabels[result.source]}
          {result.lastSyncedAt
            ? ` · ${formatCompactRelative(result.lastSyncedAt, locale)}`
            : ""}
        </span>
      ) : null}

      {result &&
      (visibleItems.length > 0 || requestRows.length > 0 || result.hasMore) ? (
        <InboxList
          groups={groups}
          renderRequest={(row) =>
            row.kind === "task_request_sent" ? (
              <InboxSentRowView
                onDelete={() => deleteItems([row])}
                row={row}
                selected={row.sent.id === selectedRequestId}
              />
            ) : (
              <InboxRequestRowView
                row={row}
                selected={row.request.id === selectedRequestId}
              />
            )
          }
          onDeleteItem={(item) => deleteItems([item])}
          onMarkReadItem={(item) => markActions.markRead([item])}
          onMarkUnreadItem={(item) => markActions.markUnread([item])}
          onOpenItem={(item) => markActions.clearUnread([item.id])}
          seenMarks={seenMarks}
          selectedConversationId={selectedConversationId}
          unreadMarks={unreadMarks}
          label={messages.inbox_list()}
        >
          {/* Source pages can contain only hidden notifications. Fetch them in
              the background. The error toast owns the retry action. */}
          {onLoadMore ? (
            <ScrollAreaLoadMore
              className="px-md"
              failed={loadMoreError !== undefined}
              hasMore={result.hasMore === true}
              loading={loadMorePending}
              onLoadMore={onLoadMore}
              quiet
            />
          ) : null}
          {result && filtered ? (
            <InboxFilterFooter
              hiddenCount={hiddenCount}
              onClear={() => setFilters(unfilteredInbox())}
            />
          ) : null}
        </InboxList>
      ) : (
        <ScrollArea
          className="min-h-0 flex-1"
          contentClassName="flex min-h-full flex-col gap-lg px-md pb-md pt-lg"
          edgeEffect="mask"
          edgeMask={{ endSize: 24, startSize: 16 }}
          viewportProps={{ "aria-label": messages.inbox_list() }}
        >
          {!result ? (
            <PageLoading label={messages.inbox_loading()} indicator="spinner" />
          ) : null}
          {result && filtered ? (
            <InboxFilterFooter
              hiddenCount={hiddenCount}
              onClear={() => setFilters(unfilteredInbox())}
            />
          ) : null}
        </ScrollArea>
      )}
      {result &&
      requestRows.length === 0 &&
      visibleItems.length === 0 &&
      !result.hasMore ? (
        // On the rail's own middle, level with the detail pane's empty state beside it.
        <InboxState overlay title={messages.inbox_empty()} />
      ) : null}
    </aside>
  );
}

const isRequestRow = (row: InboxListEntry): row is InboxRequestEntry =>
  "kind" in row && (row.kind === "task_request" || row.kind === "task_request_sent");

/**
 * The Tasks in the order the list gives them, with each request placed before the first Task older than it: the
 * Tasks keep their order, and a request sits among them by when it came.
 */
function mergeByTime(
  items: readonly ProductInboxItem[],
  requests: readonly InboxRequestEntry[]
): InboxListEntry[] {
  const waiting = requests.toSorted(
    (a, b) => normalizeTimestamp(b.updatedAt) - normalizeTimestamp(a.updatedAt)
  );
  const merged: InboxListEntry[] = [];
  let next = 0;
  for (const item of items) {
    const time = normalizeTimestamp(item.updatedAt);
    while (next < waiting.length && normalizeTimestamp(waiting[next]!.updatedAt) > time)
      merged.push(waiting[next++]!);
    merged.push(item);
  }
  return [...merged, ...waiting.slice(next)];
}

/** Loading and empty copy, centered in the rail or the detail pane. */
export function InboxState({
  overlay = false,
  testId = "inbox-empty",
  title,
}: {
  /** Centred on the whole of its positioned container, over what else it holds, rather than in the flow. */
  overlay?: boolean;
  testId?: string;
  title: string;
}) {
  return (
    <div
      className={
        overlay
          ? "pointer-events-none absolute inset-0 flex items-center justify-center text-center"
          : "flex min-h-48 flex-1 items-center justify-center text-center"
      }
      data-testid={testId}
    >
      <span className="text-sm text-tertiary">{title}</span>
    </div>
  );
}

/** Follows the last row while a filter is on, saying what the filter hides. */
function InboxFilterFooter({
  hiddenCount,
  onClear,
}: {
  hiddenCount: number;
  onClear: () => void;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();

  return (
    <div
      className="flex flex-col items-center gap-xs px-md text-center"
      data-testid="inbox-filter-footer"
    >
      <p className="m-0 text-sm leading-5">
        <span className="font-medium text-primary">
          {messages.inbox_filter_notification_count({
            count: hiddenCount,
            formattedCount: formatNumber(hiddenCount, locale),
          })}
        </span>{" "}
        <span className="text-tertiary">{messages.inbox_hidden_by_filters()}</span>
      </p>
      <Button
        hierarchy="tertiary-gray"
        className="h-3xl! pl-sm [--comma-button-hover-bg:var(--color-bg-quaternary)]"
        iconTrailing={<XIcon />}
        onPress={onClear}
        size="xs"
      >
        {messages.inbox_clear_filters()}
      </Button>
    </div>
  );
}
