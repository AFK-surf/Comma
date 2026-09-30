import { useCommaMessages } from "@comma/i18n/react";
import { useEffect, useLayoutEffect, useRef } from "react";
import { Button } from "../Button";
import { LoadingIndicator } from "../LoadingIndicator";
import { cx } from "../utils";

const VIEWPORT_SELECTOR = '[data-slot="scroll-area-viewport"]';

export interface ScrollAreaLoadMoreProps {
  /** Another page exists. Nothing renders once it is false. */
  hasMore: boolean;
  /** A page request is in flight. */
  loading?: boolean | undefined;
  /**
   * The last page request failed. Loading stops until the reader scrolls the
   * end of the list out of view and back, or presses Retry; the host shows
   * what went wrong on its own error surface.
   */
  failed?: boolean | undefined;
  onLoadMore: () => void;
  /** The end the next page arrives at: `start` for older records above. */
  edge?: "start" | "end";
  /**
   * Load only when this area scrolls. For one column of several that share
   * one paged list, where a short column's visible end is not a request for
   * more (see `TaskWorkspace`).
   */
  onlyWhenScrollable?: boolean | undefined;
  /**
   * The host shows loading and failure in its own idiom (a menu's searching
   * row and retry); the trigger only watches the end of the list.
   */
  quiet?: boolean | undefined;
  className?: string | undefined;
}

/**
 * The end of a paged list inside a `ScrollArea`: the next page loads when the
 * reader scrolls to within one viewport of it, and again while a loaded page
 * still leaves the list short of filling the area. There is no button to
 * press; a page in flight shows the loading mark here.
 */
export function ScrollAreaLoadMore({
  className,
  edge = "end",
  failed = false,
  hasMore,
  loading = false,
  onLoadMore,
  onlyWhenScrollable = false,
  quiet = false,
}: ScrollAreaLoadMoreProps) {
  const messages = useCommaMessages();
  const sentinelRef = useRef<HTMLDivElement>(null);
  const onLoadMoreRef = useRef(onLoadMore);
  useLayoutEffect(() => {
    onLoadMoreRef.current = onLoadMore;
  });

  // One request per arrival at the end: the end has to leave view before it
  // asks again, or a request has to settle. Re-observed whenever one settles,
  // since the observer's first report says whether the list, grown by the
  // page, still leaves its end in reach.
  useEffect(() => {
    const sentinel = sentinelRef.current;
    if (!sentinel || !hasMore || loading || typeof IntersectionObserver === "undefined")
      return undefined;
    const root = sentinel.closest<HTMLElement>(VIEWPORT_SELECTOR);
    // After a failure the end has to leave view first, so a request that
    // keeps failing is never retried in a loop.
    let armed = !failed;
    const observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[entries.length - 1];
        if (!entry) return;
        if (!entry.isIntersecting) {
          armed = true;
          return;
        }
        if (!armed) return;
        if (onlyWhenScrollable && root && root.scrollHeight <= root.clientHeight)
          return;
        armed = false;
        onLoadMoreRef.current();
      },
      {
        root,
        rootMargin: edge === "start" ? "100% 0px 0px 0px" : "0px 0px 100% 0px",
      }
    );
    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [edge, failed, hasMore, loading, onlyWhenScrollable]);

  if (!hasMore) return null;
  return (
    <div
      className={cx("flex min-h-px flex-col items-center justify-center", className)}
      data-edge={edge}
      data-slot="scroll-area-load-more"
      ref={sentinelRef}
    >
      {quiet ? null : loading ? (
        <LoadingIndicator label={messages.common_loading_more()} />
      ) : failed ? (
        <Button hierarchy="link-gray" onPress={() => onLoadMoreRef.current()} size="sm">
          {messages.common_retry()}
        </Button>
      ) : null}
    </div>
  );
}
