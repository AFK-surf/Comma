import { useCommaMessages } from "@comma/i18n/react";
import { ScrollArea, type ScrollEdgeMask } from "@comma/ui/components/scroll-area";
import type { ReactNode } from "react";
import type { useStickToBottom } from "./useStickToBottom";
import type { MeasuredThreadResize } from "./useMeasuredThreadResize";
import type { ThreadScrollbar } from "./useThreadScrollbar";

const CHAT_AWAY_SCROLL_KEYS = new Set(["ArrowUp", "Home", "PageUp"]);
const CHAT_TOWARD_SCROLL_KEYS = new Set(["ArrowDown", "PageDown"]);
const SPACE_ACTIVATION_SELECTOR =
  'button, input, select, textarea, [contenteditable="true"]';

type Follow = ReturnType<typeof useStickToBottom>;

export function ThreadScrollViewport({
  children,
  contentResizeTarget,
  displayOnly,
  edgeMask,
  follow: {
    handleFocusChange,
    handleScrollGestureStart,
    handleScrollIntent,
    scrollRootRef,
    scrollToBottom,
    showScrollToBottom,
  },
  freezeContentInlineSizeOnWindowResize,
  overlay,
  resize: {
    handleMeasuredContentResize,
    handleMeasuredViewportResize,
    handleThreadMetrics,
  },
  scrollbar: { hasThreadOverflow, scrollEnabled, updateScrollEnabled },
}: {
  children: ReactNode;
  contentResizeTarget: HTMLElement | null;
  displayOnly: boolean;
  edgeMask: ScrollEdgeMask;
  follow: Pick<
    Follow,
    | "handleFocusChange"
    | "handleScrollGestureStart"
    | "handleScrollIntent"
    | "scrollRootRef"
    | "scrollToBottom"
    | "showScrollToBottom"
  >;
  freezeContentInlineSizeOnWindowResize: boolean;
  /** A layer over the transcript, such as an open reply thread. */
  overlay?: ReactNode;
  resize: MeasuredThreadResize;
  scrollbar: ThreadScrollbar;
}) {
  const messagesApi = useCommaMessages();
  return (
    <div className="comma-chat-thread-zone">
      <ScrollArea
        ref={scrollRootRef}
        className="min-h-0 flex-1"
        contentClassName="min-h-full"
        // The latest turn keeps resizing inside a shell whose own size is
        // pinned by its reserve, so the shared observer has to watch it too.
        contentResizeTarget={contentResizeTarget}
        edgeEffect="mask"
        edgeMask={edgeMask}
        freezeContentInlineSizeOnWindowResize={freezeContentInlineSizeOnWindowResize}
        onContentResize={handleMeasuredContentResize}
        onMetricsChange={handleThreadMetrics}
        onPointerDownCapture={(event) => {
          if (
            event.target instanceof Element &&
            event.target.closest('[data-slot="scroll-area-scrollbar"]')
          ) {
            handleScrollGestureStart();
          }
        }}
        onViewportResize={handleMeasuredViewportResize}
        scrollbar={scrollEnabled}
        scrollbarRevealSource="interaction"
        viewportClassName="comma-chat-scroll-viewport"
        viewportProps={{
          ...(displayOnly
            ? { "aria-hidden": true, tabIndex: -1 }
            : { "aria-label": messagesApi.chat_thread_label(), role: "log" }),
          onFocusCapture: (event) => handleFocusChange(event.target),
          onKeyDown: (event) => {
            if (!scrollEnabled) {
              return;
            }
            if (event.key === "End") {
              scrollToBottom();
            } else if (CHAT_AWAY_SCROLL_KEYS.has(event.key)) {
              handleScrollIntent("away");
            } else if (CHAT_TOWARD_SCROLL_KEYS.has(event.key)) {
              handleScrollIntent("toward");
            } else if (
              event.key === " " &&
              !(
                event.target instanceof Element &&
                event.target.closest(SPACE_ACTIVATION_SELECTOR)
              )
            ) {
              handleScrollIntent(event.shiftKey ? "away" : "toward");
            }
          },
          onTouchStart: () => {
            if (scrollEnabled) {
              handleScrollGestureStart();
            }
          },
          onWheelCapture: (event) => {
            const sourceViewport =
              event.target instanceof Element
                ? event.target.closest('[data-slot="scroll-area-viewport"]')
                : null;
            const canScroll = scrollEnabled || hasThreadOverflow();
            // A nested vertical scroller answers the wheel itself. A nested
            // horizontal one — every code block and table — never moves this
            // axis, so a wheel over it is still the reader moving the
            // transcript. Reading it as someone else's left following on, and
            // the next metrics frame pulled each step back to the tail.
            const nestedScrollsThisAxis =
              sourceViewport !== event.currentTarget &&
              sourceViewport
                ?.closest('[data-slot="scroll-area"]')
                ?.getAttribute("data-orientation") !== "horizontal";
            // A diagonal wheel can still move this vertical viewport natively
            // when its horizontal delta is larger. Release following for that
            // vertical intent too, or the next metrics frame pulls it back.
            if (nestedScrollsThisAxis || !canScroll || event.deltaY === 0) {
              return;
            }
            if (!scrollEnabled) {
              updateScrollEnabled("preserve");
            }
            handleScrollIntent(event.deltaY < 0 ? "away" : "toward");
          },
        }}
      >
        {children}
      </ScrollArea>

      {overlay}

      {showScrollToBottom ? (
        <button
          aria-label={messagesApi.chat_back_to_bottom()}
          className="comma-chat-new-pill"
          onClick={scrollToBottom}
          type="button"
        >
          <span aria-hidden="true">↓</span> {messagesApi.chat_back_to_bottom()}
        </button>
      ) : null}
    </div>
  );
}
