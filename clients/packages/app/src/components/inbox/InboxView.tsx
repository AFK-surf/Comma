import { InboxList } from "./InboxList";
import { PageLoading } from "@comma/ui";
import { formatNumber } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import type {
  ProductInboxItem,
  ProductInboxListResult,
  ProductInboxListSource,
} from "@comma/native-bridge";
import {
  Button,
  ContentHeader,
  ScrollArea,
  ScrollAreaLoadMore,
  XIcon,
  toast,
} from "@comma/ui";
import { useMemo, useState } from "react";
import { commaInboxConversationRailWidth } from "../shellGeometry";
import { useTaskReviewSeenMarks } from "../tasks/taskReviewAttention";
import { InboxActionsMenu } from "./InboxActionsMenu";
import { InboxFilterMenu } from "./filters/InboxFilterMenu";
import type { InboxWorkspaceSelector } from "./filters/InboxFilterPanels";
import {
  applyInboxFilters,
  countInboxItemsByPlatform,
  countInboxTasksByStatus,
  isInboxFiltered,
  unfilteredInbox,
} from "./filters/inboxFilters";
import { formatCompactRelative, groupInboxItems } from "./InboxGroup";
import {
  clearInboxItemUnread,
  deleteInboxItems,
  isInboxItemDeleted,
  isInboxItemUnread,
  markInboxItemsRead,
  markInboxItemsUnread,
  useInboxDeletedMarks,
  useInboxUnreadMarks,
} from "./inboxDeletion";
import { useInboxSyncToasts } from "./useInboxSyncToasts";

export interface InboxViewProps {
  loadMoreError?: string | undefined;
  loadMorePending?: boolean | undefined;
  onLoadMore?: (() => void) | undefined;
  result: ProductInboxListResult | null;
  selectedConversationId?: string | undefined;
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
  workspaceSelector,
}: InboxViewProps) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const [filters, setFilters] = useState(unfilteredInbox);
  const deletedMarks = useInboxDeletedMarks();
  const unreadMarks = useInboxUnreadMarks();
  const seenMarks = useTaskReviewSeenMarks();
  useInboxSyncToasts(result, loadMoreError, onLoadMore);
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
  const readItems = useMemo(
    () =>
      visibleItems.filter((item) => !isInboxItemUnread(seenMarks, unreadMarks, item)),
    [visibleItems, seenMarks, unreadMarks]
  );
  const filtered = isInboxFiltered(filters);
  const day = new Date().setHours(0, 0, 0, 0);
  const groups = useMemo(
    () => groupInboxItems(visibleItems, locale, day),
    [visibleItems, locale, day]
  );
  const platformCounts = useMemo(() => countInboxItemsByPlatform(items), [items]);
  const statusCounts = useMemo(() => countInboxTasksByStatus(items), [items]);
  const sourceLabels: Record<ProductInboxListSource, string> = {
    cache: messages.inbox_source_cache(),
    "live-sync": messages.inbox_source_live(),
    error: messages.inbox_source_error(),
    unavailable: messages.inbox_source_unavailable(),
  };

  // Deleting acts on what the rail lists right now, filters included.
  const deleteItems = (targets: readonly ProductInboxItem[]) => {
    deleteInboxItems(targets);
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
      className="flex h-full min-h-0 shrink-0 flex-col border-r-[0.5px] border-primary bg-main-panel-bg"
      data-testid="inbox-conversation-rail"
      style={{
        flexBasis: commaInboxConversationRailWidth,
        width: commaInboxConversationRailWidth,
      }}
    >
      <ContentHeader className="comma-inbox-rail-header justify-between">
        <h1 className="m-0 text-sm font-medium leading-5 tracking-[-0.14px] text-primary">
          {messages.inbox_title()}
        </h1>
        <div className="flex items-center gap-xs">
          <InboxActionsMenu
            canDeleteAll={visibleItems.length > 0}
            canDeleteRead={readItems.length > 0}
            onDeleteAll={() => deleteItems(visibleItems)}
            onDeleteRead={() => deleteItems(readItems)}
          />
          <InboxFilterMenu
            filters={filters}
            onFiltersChange={setFilters}
            platformCounts={platformCounts}
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

      {result && (visibleItems.length > 0 || result.hasMore) ? (
        <InboxList
          groups={groups}
          onDeleteItem={(item) => deleteItems([item])}
          onMarkReadItem={(item) => markInboxItemsRead([item])}
          onMarkUnreadItem={(item) => markInboxItemsUnread([item])}
          onOpenItem={(item) => clearInboxItemUnread([item.id])}
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
              hiddenCount={items.length - visibleItems.length}
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
          ) : (
            <InboxState title={messages.inbox_empty()} />
          )}
          {result && filtered ? (
            <InboxFilterFooter
              hiddenCount={items.length - visibleItems.length}
              onClear={() => setFilters(unfilteredInbox())}
            />
          ) : null}
        </ScrollArea>
      )}
    </aside>
  );
}

/** Loading and empty copy, centered in the rail. */
function InboxState({ title }: { title: string }) {
  return (
    <div
      className="flex min-h-48 flex-1 items-center justify-center text-center"
      data-testid="inbox-empty"
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
        iconTrailing={<XIcon />}
        onPress={onClear}
        size="sm"
      >
        {messages.inbox_clear_filters()}
      </Button>
    </div>
  );
}
