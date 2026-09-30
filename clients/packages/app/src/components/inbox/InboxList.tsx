import {
  defaultRangeExtractor,
  useVirtualizer,
  type Virtualizer,
  type Rect,
} from "@tanstack/react-virtual";
import { ScrollArea } from "@comma/ui";
import {
  useCallback,
  useMemo,
  useRef,
  useState,
  useLayoutEffect,
  type ReactNode,
} from "react";
import type { ProductInboxItem } from "@comma/native-bridge";
import type { TaskReviewSeenMarks } from "../tasks/taskReviewAttention";
import { InboxRow, type InboxGroupModel } from "./InboxGroup";
import { isInboxItemUnread, type InboxUnreadMarks } from "./inboxDeletion";

export function InboxList({
  groups,
  onDeleteItem,
  onMarkReadItem,
  onMarkUnreadItem,
  onOpenItem,
  seenMarks,
  selectedConversationId,
  unreadMarks,
  label,
  children,
}: {
  groups: InboxGroupModel[];
  onDeleteItem: (item: ProductInboxItem) => void;
  onMarkReadItem: (item: ProductInboxItem) => void;
  onMarkUnreadItem: (item: ProductInboxItem) => void;
  onOpenItem: (item: ProductInboxItem) => void;
  seenMarks: TaskReviewSeenMarks;
  selectedConversationId: string | undefined;
  unreadMarks: InboxUnreadMarks;
  label: string;
  children?: ReactNode;
}) {
  const viewport = useRef<HTMLDivElement>(null);
  const rectListener = useRef<
    ((rect: { width: number; height: number }) => void) | undefined
  >(undefined);
  const [probe, setProbe] = useState<HTMLDivElement | null>(null);
  const [rowHeight, setRowHeight] = useState(36);
  const [focusedId, setFocusedId] = useState<string | null>(null);
  const rows = useMemo(
    () =>
      groups.flatMap((group) =>
        group.items.map((item, index) => ({
          item,
          heading: index === 0 ? group.label : undefined,
          last: index === group.items.length - 1,
        }))
      ),
    [groups]
  );
  const focusedIndex = useMemo(
    () => rows.findIndex((row) => row.item.id === focusedId),
    [rows, focusedId]
  );
  const measure = useCallback(() => {
    const element = viewport.current;
    if (element)
      rectListener.current?.({
        width: element.clientWidth,
        height: element.clientHeight,
      });
    if (probe) setRowHeight(probe.getBoundingClientRect().height);
  }, [probe]);
  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => viewport.current,
    getItemKey: useCallback((index) => rows[index]!.item.id, [rows]),
    estimateSize: (index) =>
      rowHeight +
      (rows[index]!.heading ? rowHeight - 8 : 0) +
      (index === rows.length - 1 ? 0 : rows[index]!.last ? 12 : 2),
    overscan: 5,
    paddingStart: 12,
    initialRect: { width: 320, height: 720 },
    observeElementRect: useCallback(
      (
        instance: Virtualizer<HTMLDivElement, Element>,
        callback: (rect: Rect) => void
      ) => {
        rectListener.current = callback;
        const element = instance.scrollElement;
        if (element && element.clientHeight > 0)
          callback({ width: element.clientWidth, height: element.clientHeight });
        return () => {
          rectListener.current = undefined;
        };
      },
      []
    ),
    rangeExtractor: useCallback(
      (range) => {
        const indexes = defaultRangeExtractor(range);
        if (focusedIndex >= 0)
          for (
            let index = Math.max(0, focusedIndex - 1);
            index <= Math.min(rows.length - 1, focusedIndex + 1);
            index++
          )
            indexes.push(index);
        return [...new Set(indexes)].toSorted((a, b) => a - b);
      },
      [focusedIndex, rows.length]
    ),
  });
  useLayoutEffect(() => virtualizer.measure(), [rowHeight, virtualizer]);
  const minute = Math.floor(Date.now() / 60_000);
  return (
    <ScrollArea
      ref={viewport}
      className="min-h-0 flex-1"
      contentClassName="flex min-h-full flex-col gap-lg px-md pb-md"
      edgeEffect="mask"
      edgeMask={{ endSize: 24, startSize: 16 }}
      orientation="vertical"
      contentResizeTarget={probe}
      onContentResize={measure}
      onViewportResize={measure}
      viewportProps={{ "aria-label": label }}
    >
      <div
        ref={setProbe}
        aria-hidden
        style={{
          position: "absolute",
          visibility: "hidden",
          pointerEvents: "none",
          height: "calc(var(--text-sm--line-height) + var(--spacing-md) * 2)",
          width: 1,
        }}
      />
      <ul
        className="m-0 list-none p-0"
        aria-label={label}
        data-testid="inbox-list"
        style={{ height: virtualizer.getTotalSize(), position: "relative" }}
        onFocusCapture={(event) =>
          setFocusedId(
            (event.target as HTMLElement).closest<HTMLElement>("[data-inbox-row-id]")
              ?.dataset.inboxRowId ?? null
          )
        }
        onBlurCapture={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget as Node | null))
            setFocusedId(null);
        }}
      >
        {virtualizer.getVirtualItems().map((virtual) => {
          const { item, heading } = rows[virtual.index]!;
          return (
            <li
              key={virtual.key}
              aria-posinset={virtual.index + 1}
              aria-setsize={rows.length}
              data-inbox-row-id={item.id}
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                width: "100%",
                transform: `translateY(${virtual.start}px)`,
              }}
            >
              {heading ? (
                <h2 className="m-0 px-md pb-md text-sm font-medium leading-5 tracking-[-0.14px] text-quaternary">
                  {heading}
                </h2>
              ) : null}
              <InboxRow
                conversationId={item.conversationId}
                groupId={item.groupId}
                workspaceId={item.workspaceId}
                title={item.title}
                status={item.status}
                freshness={item.freshness}
                updatedAt={item.updatedAt}
                selected={item.conversationId === selectedConversationId}
                unread={isInboxItemUnread(seenMarks, unreadMarks, item)}
                minute={minute}
                onDelete={() => onDeleteItem(item)}
                onMarkRead={() => onMarkReadItem(item)}
                onMarkUnread={() => onMarkUnreadItem(item)}
                onOpen={() => onOpenItem(item)}
              />
            </li>
          );
        })}
      </ul>
      {children}
    </ScrollArea>
  );
}
