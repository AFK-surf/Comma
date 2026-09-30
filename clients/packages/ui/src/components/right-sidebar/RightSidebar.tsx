/* oxlint-disable jsx-a11y/prefer-tag-over-role -- The adjustable separator must be focusable and operable, while an hr is non-interactive. */
import { useCommaMessages } from "@comma/i18n/react";
import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ComponentPropsWithoutRef,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
  type Ref,
} from "react";
import { createPortal } from "react-dom";
import { mergeRefs } from "react-aria";
import { PlusSmallIcon, XIcon } from "../icons";
import { ScrollArea } from "../scroll-area";
import {
  claimToastObstructionRight,
  releaseToastObstructionRight,
} from "../toast/toastObstruction";
import { TooltipBubble } from "../tooltip";
import { cx } from "../utils";
import { spacing } from "../../tokens/spacing";

/** The sidebar's own claim on the window's right edge; native views add theirs. */
const rightSidebarObstructionClaim = "right-sidebar";

export const RIGHT_SIDEBAR_DEFAULT_WIDTH = 440;
export const RIGHT_SIDEBAR_MIN_WIDTH = 320;
export const RIGHT_SIDEBAR_MAX_WIDTH = 720;

export type RightSidebarTab<TabId extends string = string> = {
  closable?: boolean | undefined;
  icon?: ReactNode | undefined;
  id: TabId;
  label: string;
  panelId?: string | undefined;
};

export interface RightSidebarProps<TabId extends string = string> extends Omit<
  ComponentPropsWithoutRef<"aside">,
  "aria-label" | "children"
> {
  activeTab: TabId;
  ariaLabel: string;
  children?: ReactNode;
  defaultWidth?: number;
  headerActions?: ReactNode;
  headerActionsClassName?: string | undefined;
  /**
   * The host's CSS clamps the rendered width to its live geometry (the product
   * shell: `100cqw` less the route minimum). `maxWidth` then bounds interaction
   * only — the drag, the keyboard, the separator's value — so the host may
   * update it once its geometry settles instead of on every frame of a window
   * resize.
   */
  hostClampsRenderedWidth?: boolean | undefined;
  maxWidth?: number;
  minWidth?: number;
  resizeEdge?: "left" | "right";
  resizeHandleAppearance?: "divider" | "invisible";
  resizeWidthMultiplier?: number;
  onAddTab?: (() => void) | undefined;
  onExitComplete?: (() => void) | undefined;
  onTabChange: (tabId: TabId) => void;
  onTabClose?: ((tabId: TabId) => void) | undefined;
  onWidthChange: (width: number) => void;
  /** Host geometry preview; when supplied, persist width only on pointer release. */
  onWidthPreview?: ((width: number) => void) | undefined;
  open: boolean;
  /** The aside itself, for hosts that measure its open and close in flight. */
  ref?: Ref<HTMLElement> | undefined;
  tabs: readonly RightSidebarTab<TabId>[];
  width: number;
}

export type RightSidebarToolbarButtonProps = ComponentPropsWithoutRef<"button">;

const clampWidth = (width: number, minWidth: number, maxWidth: number) =>
  Math.min(Math.max(Math.round(width), minWidth), maxWidth);

// The sidebar never renders wider than the window minus its insets.
const renderedWidthExpression = (width: number) =>
  `min(${width}px, calc(100vw - var(--comma-window-inset, 0px) - var(--comma-window-inset, 0px)))`;

const resizeTooltipShowDelay = 300;
const resizeTooltipPointerOffset = 14;
const resizeTooltipWindowInset = 8;

const defaultExitFallbackMs = 180;
const exitFallbackBufferMs = 30;

const parseCssTimeMs = (value: string) => {
  const parsed = Number.parseFloat(value);
  if (!Number.isFinite(parsed)) return 0;
  return value.trim().endsWith("ms") ? parsed : parsed * 1000;
};

const getExitFallbackMs = (element: HTMLElement | null) => {
  if (!element) return defaultExitFallbackMs;

  const styles = window.getComputedStyle(element);
  const properties = styles.transitionProperty.split(",").map((value) => value.trim());
  const durations = styles.transitionDuration
    .split(",")
    .map((value) => parseCssTimeMs(value));
  const delays = styles.transitionDelay
    .split(",")
    .map((value) => parseCssTimeMs(value));
  if (!properties.some(Boolean) || durations.length === 0) {
    return defaultExitFallbackMs;
  }

  const widthTransitionMs = properties.reduce((longest, property, index) => {
    if (property !== "all" && property !== "width") return longest;
    const duration = durations[index % durations.length] ?? 0;
    const delay = delays[index % delays.length] ?? 0;
    return Math.max(longest, duration + delay);
  }, 0);
  return widthTransitionMs > 0
    ? Math.ceil(widthTransitionMs + exitFallbackBufferMs)
    : 0;
};

export const RightSidebarToolbarButton = ({
  className,
  type = "button",
  ...props
}: RightSidebarToolbarButtonProps) => (
  <button
    className={cx(
      "comma-chat-sidebar-toolbar-button inline-flex size-7 items-center justify-center rounded-sm border-0 bg-transparent p-0 text-tertiary outline-none transition-[background-color,color,transform] duration-150 ease-[cubic-bezier(0.23,1,0.32,1)] [-webkit-app-region:no-drag] focus-visible:shadow-focus-gray",
      className
    )}
    type={type}
    {...props}
  />
);

export const RightSidebar = <TabId extends string = string>({
  activeTab,
  ariaLabel,
  children,
  className,
  defaultWidth = RIGHT_SIDEBAR_DEFAULT_WIDTH,
  headerActions,
  headerActionsClassName,
  hostClampsRenderedWidth = false,
  maxWidth = RIGHT_SIDEBAR_MAX_WIDTH,
  minWidth = RIGHT_SIDEBAR_MIN_WIDTH,
  resizeEdge = "left",
  resizeHandleAppearance = "divider",
  resizeWidthMultiplier = 1,
  onAddTab,
  onExitComplete,
  onTabChange,
  onTabClose,
  onTransitionEnd,
  onWidthChange,
  onWidthPreview,
  open,
  ref,
  style,
  tabs,
  width,
  ...asideProps
}: RightSidebarProps<TabId>) => {
  const [resizing, setResizing] = useState(false);
  const constrainedWidth = clampWidth(width, minWidth, maxWidth);
  const renderedWidth = hostClampsRenderedWidth
    ? clampWidth(width, minWidth, Number.POSITIVE_INFINITY)
    : constrainedWidth;
  // The drag handlers read the latest bounds/callback through this ref so a
  // maximum that changes mid-drag (host frame or route minimum) still clamps.
  const resizeBoundsRef = useRef({ maxWidth, minWidth, onWidthChange });
  resizeBoundsRef.current = { maxWidth, minWidth, onWidthChange };
  const exitCompletedRef = useRef(!open);
  const keyboardClosingTabRef = useRef<TabId | null>(null);
  const onExitCompleteRef = useRef(onExitComplete);
  const previousOpenRef = useRef(open);
  const sidebarRef = useRef<HTMLElement | null>(null);
  const asideRef = useMemo(
    () => (ref ? mergeRefs(sidebarRef, ref) : sidebarRef),
    [ref]
  );
  const stopResizeRef = useRef<(() => void) | undefined>(undefined);
  const tablistRef = useRef<HTMLDivElement | null>(null);
  // Browser tab strips hold every tab at its width while the pointer that
  // closed one stays on the strip, so the next tab's close button slides in
  // under it; the strip reflows once the pointer leaves.
  const [lockedTabWidths, setLockedTabWidths] = useState<ReadonlyMap<
    TabId,
    number
  > | null>(null);
  const tabWidthLock =
    lockedTabWidths !== null && tabs.every((tab) => lockedTabWidths.has(tab.id))
      ? lockedTabWidths
      : null;
  onExitCompleteRef.current = onExitComplete;
  const resolvedActiveTab = tabs.some((tab) => tab.id === activeTab)
    ? activeTab
    : tabs[0]?.id;
  const tabVisibilityLayoutKey = JSON.stringify(
    tabs.map((tab) => [
      tab.id,
      tab.label,
      tab.closable === true,
      tab.icon !== undefined,
    ])
  );

  useEffect(
    () => () => {
      stopResizeRef.current?.();
    },
    []
  );

  // The drag writes the width vars straight to the element; once the drag is
  // over (or the committed width changes) make the element match the committed
  // width even when React's style diff sees no change.
  useLayoutEffect(() => {
    if (resizing) return;
    const sidebar = sidebarRef.current;
    if (!sidebar) return;
    sidebar.style.setProperty("--comma-chat-sidebar-width", `${renderedWidth}px`);
    sidebar.style.setProperty(
      "--comma-right-sidebar-rendered-width",
      renderedWidthExpression(renderedWidth)
    );
  }, [renderedWidth, resizing]);

  // Whatever shares the window's bottom-right corner (the toast stack, Drive's
  // transfer panel) belongs to the content column, not to this panel: it
  // steps left by however much of the right edge the sidebar covers. The
  // aside's own width is what transitions, so observing it republishes on
  // every frame of the open and close; at 0 the claim is released. A native
  // browser view inside adds its own claim for the frames it composites.
  useEffect(() => {
    const sidebar = sidebarRef.current;
    if (!open || !sidebar || typeof ResizeObserver === "undefined") {
      // A closed aside still measures its half-pixel border; only an open one
      // covers anything.
      releaseToastObstructionRight(rightSidebarObstructionClaim);
      return undefined;
    }
    const publish = () => {
      const covered = sidebar.getBoundingClientRect().width;
      if (covered > 0)
        claimToastObstructionRight(rightSidebarObstructionClaim, covered);
      else releaseToastObstructionRight(rightSidebarObstructionClaim);
    };
    const observer = new ResizeObserver(publish);
    observer.observe(sidebar);
    // The first claim waits a frame: a rect read here, in the commit that
    // flipped the aside open, forces the whole window's style recalc inside
    // that commit and once more at the frame, when the rest of the commit
    // has dirtied styles again. At the next frame one recalc serves both.
    const firstFrame = requestAnimationFrame(publish);
    return () => {
      cancelAnimationFrame(firstFrame);
      observer.disconnect();
      releaseToastObstructionRight(rightSidebarObstructionClaim);
    };
  }, [open]);

  useEffect(() => {
    const wasOpen = previousOpenRef.current;
    previousOpenRef.current = open;
    if (open) {
      exitCompletedRef.current = false;
      return undefined;
    }
    if (!wasOpen) return undefined;

    exitCompletedRef.current = false;
    const reduceMotion = window.matchMedia?.(
      "(prefers-reduced-motion: reduce)"
    ).matches;
    const exitFallbackMs = reduceMotion ? 0 : getExitFallbackMs(sidebarRef.current);
    const timeout = window.setTimeout(() => {
      if (exitCompletedRef.current) return;
      exitCompletedRef.current = true;
      onExitCompleteRef.current?.();
    }, exitFallbackMs);
    return () => window.clearTimeout(timeout);
  }, [open]);

  useEffect(() => {
    if (resolvedActiveTab === undefined || resolvedActiveTab === activeTab) return;
    onTabChange(resolvedActiveTab);
  }, [activeTab, onTabChange, resolvedActiveTab]);

  // A tab that arrives mid-lock has no width to hold, and a closed sidebar
  // never sees the pointer leave.
  useEffect(() => {
    if (lockedTabWidths !== null && (tabWidthLock === null || !open)) {
      setLockedTabWidths(null);
    }
  }, [lockedTabWidths, open, tabWidthLock]);

  useEffect(() => {
    if (!open || resolvedActiveTab === undefined) return;

    const activeTabElement = Array.from(
      tablistRef.current?.querySelectorAll<HTMLButtonElement>('[role="tab"]') ?? []
    ).find((tabElement) => tabElement.dataset.tab === resolvedActiveTab);
    const viewport = tablistRef.current;
    if (!activeTabElement || !viewport) return;
    // Only the tab strip owns this reveal. Walking the ancestor scroll
    // chain also measures containers that do not own the selected tab.
    const view = viewport.getBoundingClientRect();
    const tab = activeTabElement.getBoundingClientRect();
    if (tab.left < view.left) viewport.scrollLeft += tab.left - view.left;
    else if (tab.right > view.right) viewport.scrollLeft += tab.right - view.right;
  }, [constrainedWidth, open, resolvedActiveTab, tabVisibilityLayoutKey]);

  useEffect(() => {
    const keyboardClosingTab = keyboardClosingTabRef.current;
    if (
      keyboardClosingTab === null ||
      tabs.some((tab) => tab.id === keyboardClosingTab)
    ) {
      return;
    }

    keyboardClosingTabRef.current = null;
    if (resolvedActiveTab === undefined) return;
    Array.from(
      tablistRef.current?.querySelectorAll<HTMLButtonElement>('[role="tab"]') ?? []
    )
      .find((tabElement) => tabElement.dataset.tab === resolvedActiveTab)
      ?.focus();
  }, [resolvedActiveTab, tabs, tabVisibilityLayoutKey]);

  const handleResizePointerDown = (event: ReactPointerEvent<HTMLButtonElement>) => {
    if (event.button !== 0) return;

    stopResizeRef.current?.();

    const resizeHandle = event.currentTarget;
    const sidebar = sidebarRef.current;
    const pointerId = event.pointerId;
    // The drag is anchored at (pointer x, width) and clamped to [minWidth,
    // maxWidth]; hosts pass the width at which their content reaches its
    // minimum as maxWidth. At a bound the anchor follows the pointer so
    // reversing direction responds immediately (no dead zone). The anchor is
    // the width the handle is drawn at: a host that clamps the rendered width
    // in CSS can show less than its last committed maximum allows.
    const drawnWidth = sidebar ? Math.round(sidebar.getBoundingClientRect().width) : 0;
    let anchorX = event.clientX;
    let anchorWidth =
      drawnWidth > 0 ? Math.min(constrainedWidth, drawnWidth) : constrainedWidth;
    let pendingWidth: number | null = null;
    let previewedWidth = anchorWidth;
    let commitFrame: number | null = null;
    event.preventDefault();
    try {
      resizeHandle.setPointerCapture?.(pointerId);
    } catch {
      // Capturing an inactive pointer throws; the window listeners below
      // keep the drag working without capture.
    }
    setResizing(true);

    const commitPendingWidth = () => {
      commitFrame = null;
      if (pendingWidth === null) return;
      const next = pendingWidth;
      pendingWidth = null;
      if (onWidthPreview) {
        previewedWidth = next;
        sidebar?.style.setProperty("--comma-chat-sidebar-width", `${next}px`);
        sidebar?.style.setProperty(
          "--comma-right-sidebar-rendered-width",
          renderedWidthExpression(next)
        );
        resizeHandle.setAttribute("aria-valuenow", String(next));
        onWidthPreview(next);
      } else {
        resizeBoundsRef.current.onWidthChange(next);
      }
    };
    // Centered hosts move their siblings with the width. Commit that geometry
    // together; an imperative width-only write would put the edge ahead of chat.
    // Other hosts retain their immediate local width update.
    const applyWidth = (next: number) => {
      if (onWidthPreview) {
        pendingWidth = next;
        if (commitFrame === null)
          commitFrame = requestAnimationFrame(commitPendingWidth);
        return;
      }

      if (resizeWidthMultiplier === 1) {
        sidebar?.style.setProperty("--comma-chat-sidebar-width", `${next}px`);
        sidebar?.style.setProperty(
          "--comma-right-sidebar-rendered-width",
          renderedWidthExpression(next)
        );
      }
      if (commitFrame === null) {
        resizeBoundsRef.current.onWidthChange(next);
        commitFrame =
          typeof requestAnimationFrame === "function"
            ? requestAnimationFrame(commitPendingWidth)
            : null;
        return;
      }
      pendingWidth = next;
    };
    const handlePointerMove = (moveEvent: PointerEvent) => {
      if (moveEvent.pointerId !== pointerId) return;
      const rawWidth = Math.round(
        anchorWidth +
          (moveEvent.clientX - anchorX) *
            (resizeEdge === "right" ? 1 : -1) *
            resizeWidthMultiplier
      );
      const { maxWidth: currentMax, minWidth: currentMin } = resizeBoundsRef.current;
      const next = clampWidth(rawWidth, currentMin, currentMax);
      if (next !== rawWidth) {
        anchorWidth = next;
        anchorX = moveEvent.clientX;
      }
      applyWidth(next);
    };
    let stopped = false;
    const releaseTracking = () => {
      resizeHandle.removeEventListener("lostpointercapture", handlePointerEnd);
      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("pointerup", handlePointerEnd);
      window.removeEventListener("pointercancel", handlePointerEnd);
      if (resizeHandle.hasPointerCapture?.(pointerId)) {
        resizeHandle.releasePointerCapture(pointerId);
      }
    };
    const stopResize = () => {
      if (stopped) return;
      stopped = true;
      if (commitFrame !== null) {
        cancelAnimationFrame(commitFrame);
        commitPendingWidth();
      }
      if (onWidthPreview) resizeBoundsRef.current.onWidthChange(previewedWidth);
      releaseTracking();
      setResizing(false);
      stopResizeRef.current = undefined;
    };
    const handlePointerEnd = (endEvent: PointerEvent) => {
      if (endEvent.pointerId !== pointerId) return;
      if (stopped) return;
      stopResize();
    };

    stopResizeRef.current = stopResize;
    resizeHandle.addEventListener("lostpointercapture", handlePointerEnd);
    window.addEventListener("pointermove", handlePointerMove);
    window.addEventListener("pointerup", handlePointerEnd);
    window.addEventListener("pointercancel", handlePointerEnd);
  };

  const handleResizeKeyDown = (event: ReactKeyboardEvent<HTMLButtonElement>) => {
    let nextWidth: number | undefined;
    if (event.key === "ArrowLeft")
      nextWidth = constrainedWidth + (resizeEdge === "right" ? -16 : 16);
    if (event.key === "ArrowRight")
      nextWidth = constrainedWidth + (resizeEdge === "right" ? 16 : -16);
    if (event.key === "Home") nextWidth = minWidth;
    if (event.key === "End") nextWidth = maxWidth;
    if (nextWidth === undefined) return;

    event.preventDefault();
    onWidthChange(clampWidth(nextWidth, minWidth, maxWidth));
  };

  const closeTab = (tabId: TabId, byPointer: boolean) => {
    if (byPointer) {
      const widths = new Map<TabId, number>();
      for (const item of tablistRef.current?.querySelectorAll<HTMLElement>(
        "[data-tab-item]"
      ) ?? []) {
        widths.set(item.dataset.tabItem as TabId, item.getBoundingClientRect().width);
      }
      widths.delete(tabId);
      setLockedTabWidths(widths);
    }
    onTabClose?.(tabId);
  };

  const handleTabKeyDown = (
    event: ReactKeyboardEvent<HTMLButtonElement>,
    tabIndex: number
  ) => {
    let nextTabIndex: number | undefined;
    if (event.key === "ArrowLeft") {
      nextTabIndex = (tabIndex - 1 + tabs.length) % tabs.length;
    }
    if (event.key === "ArrowRight") {
      nextTabIndex = (tabIndex + 1) % tabs.length;
    }
    if (event.key === "Home") nextTabIndex = 0;
    if (event.key === "End") nextTabIndex = tabs.length - 1;
    if (nextTabIndex === undefined || tabs.length === 0) return;

    const nextTab = tabs[nextTabIndex];
    if (!nextTab) return;
    event.preventDefault();
    onTabChange(nextTab.id);
    tablistRef.current
      ?.querySelectorAll<HTMLButtonElement>('[role="tab"]')
      .item(nextTabIndex)
      .focus();
  };

  const sidebarStyle = {
    ...style,
    "--comma-chat-sidebar-width": `${renderedWidth}px`,
    "--comma-right-sidebar-rendered-width": renderedWidthExpression(renderedWidth),
  } as CSSProperties;

  return (
    <aside
      {...asideProps}
      aria-hidden={!open}
      aria-label={open ? ariaLabel : undefined}
      className={cx(
        "comma-chat-sidebar group/right-sidebar relative z-[7] flex max-w-full min-w-0 flex-[0_0_auto] overflow-hidden transition-[width] duration-150 ease-[cubic-bezier(0.23,1,0.32,1)] [width:var(--comma-right-sidebar-rendered-width)] [-webkit-app-region:no-drag] motion-reduce:transition-none data-[open=false]:pointer-events-none data-[open=false]:w-0 data-[open=true]:overflow-visible data-[resizing=true]:transition-none",
        className
      )}
      data-active-tab={resolvedActiveTab}
      data-open={open ? "true" : "false"}
      data-resizing={resizing ? "true" : "false"}
      data-slot="right-sidebar"
      inert={!open ? true : undefined}
      onTransitionEnd={(event) => {
        onTransitionEnd?.(event);
        if (
          !open &&
          !exitCompletedRef.current &&
          event.currentTarget === event.target &&
          event.propertyName === "width"
        ) {
          exitCompletedRef.current = true;
          onExitCompleteRef.current?.();
        }
      }}
      ref={asideRef}
      style={sidebarStyle}
    >
      <div className="comma-chat-sidebar-surface relative flex h-full flex-col border-l-[0.5px] border-primary bg-main-panel-bg [width:var(--comma-right-sidebar-rendered-width)] [min-width:var(--comma-right-sidebar-rendered-width)]">
        <RightSidebarResizeHandle
          ariaLabel={ariaLabel}
          constrainedWidth={constrainedWidth}
          defaultWidth={defaultWidth}
          maxWidth={maxWidth}
          minWidth={minWidth}
          onKeyDown={handleResizeKeyDown}
          onWidthChange={onWidthChange}
          open={open}
          resizing={resizing}
          resizeEdge={resizeEdge}
          appearance={resizeHandleAppearance}
          startResize={handleResizePointerDown}
        />

        <header
          className={cx(
            "comma-chat-sidebar-header flex h-11 shrink-0 items-center justify-between gap-sm border-b-[0.5px] border-primary py-0 pr-2.5 [-webkit-app-region:no-drag]",
            tabs.length === 0 ? "pl-xs" : "pl-lg"
          )}
        >
          <div
            className={cx(
              "flex min-w-0 flex-1 items-center",
              tabs.length > 0 && "gap-sm"
            )}
            onPointerLeave={() => {
              if (lockedTabWidths !== null) setLockedTabWidths(null);
            }}
          >
            <ScrollArea
              className="comma-chat-sidebar-tabs min-w-0 [-webkit-app-region:no-drag]"
              contentClassName="flex items-center gap-sm"
              // Past this width every tab sits at its minimum and the strip
              // scrolls; below it the tabs share the strip.
              contentStyle={{
                minWidth: `calc(${tabs.length} * var(--comma-right-sidebar-tab-min-width) + ${Math.max(tabs.length - 1, 0)} * var(--spacing-sm))`,
              }}
              data-tab-width-locked={tabWidthLock === null ? undefined : "true"}
              edgeEffect="mask"
              edgeMask={{ size: spacing["3xl"] }}
              orientation="horizontal"
              ref={tablistRef}
              scrollbar={false}
              viewportProps={{
                "aria-label": `${ariaLabel} content`,
                role: "tablist",
                tabIndex: -1,
              }}
            >
              {tabs.map((tab, tabIndex) => {
                const selected = resolvedActiveTab === tab.id;
                const lockedWidth = tabWidthLock?.get(tab.id);
                return (
                  <div
                    className="comma-right-sidebar-tab-item group/tab relative flex items-center"
                    data-closable={tab.closable ? "true" : "false"}
                    data-tab-item={tab.id}
                    key={tab.id}
                    role="presentation"
                    style={
                      lockedWidth === undefined
                        ? undefined
                        : { maxWidth: `${lockedWidth}px` }
                    }
                  >
                    <button
                      aria-controls={tab.panelId}
                      aria-selected={selected}
                      className={cx(
                        "comma-right-sidebar-tab relative flex w-full max-w-[180px] min-w-0 items-center gap-xs rounded-xs border-0 bg-transparent py-xs pl-xs pr-md text-left text-sm font-medium leading-5 tracking-[-0.14px] text-quaternary outline-none transition-[transform,background-color,color] duration-150 ease-[cubic-bezier(0.23,1,0.32,1)] focus-visible:shadow-focus-gray",
                        selected && "comma-right-sidebar-tab-selected"
                      )}
                      data-tab={tab.id}
                      onAuxClick={(event) => {
                        if (event.button !== 1 || !tab.closable) return;
                        event.preventDefault();
                        closeTab(tab.id, true);
                      }}
                      onClick={() => onTabChange(tab.id)}
                      onKeyDown={(event) => handleTabKeyDown(event, tabIndex)}
                      onMouseDown={(event) => {
                        // Middle-click closes; keep it from starting autoscroll.
                        if (event.button === 1 && tab.closable) event.preventDefault();
                      }}
                      role="tab"
                      tabIndex={selected ? 0 : -1}
                      title={tab.label}
                      type="button"
                    >
                      {tab.icon ? (
                        <span className="inline-flex size-5 shrink-0 items-center justify-center [&_svg]:size-5">
                          {tab.icon}
                        </span>
                      ) : null}
                      <span className="min-w-0 truncate">{tab.label}</span>
                    </button>
                    {tab.closable ? (
                      <button
                        aria-label={`Close ${tab.label}`}
                        className="comma-right-sidebar-tab-close pointer-events-none absolute top-1/2 right-xs inline-flex size-5 -translate-y-1/2 items-center justify-center rounded-sm border-0 bg-transparent p-0 outline-none transition-colors duration-150 focus-visible:shadow-focus-gray"
                        onClick={(event) => {
                          event.stopPropagation();
                          if (
                            selected &&
                            event.detail === 0 &&
                            event.currentTarget.ownerDocument.activeElement ===
                              event.currentTarget
                          ) {
                            keyboardClosingTabRef.current = tab.id;
                          }
                          closeTab(tab.id, event.detail > 0);
                        }}
                        tabIndex={selected ? 0 : -1}
                        title={`Close ${tab.label}`}
                        type="button"
                      >
                        <XIcon
                          aria-hidden
                          className="comma-right-sidebar-tab-close-icon size-5 text-tertiary opacity-0"
                        />
                      </button>
                    ) : null}
                  </div>
                );
              })}
            </ScrollArea>
            {onAddTab ? (
              <button
                aria-label="New tab"
                className="comma-right-sidebar-add-tab inline-flex size-7 shrink-0 items-center justify-center rounded-sm border-0 bg-transparent p-xs text-sidebar-icon-primary outline-none transition-[transform,background-color,color] duration-150 ease-[cubic-bezier(0.23,1,0.32,1)] focus-visible:shadow-focus-gray"
                onClick={onAddTab}
                type="button"
              >
                <PlusSmallIcon className="size-5" />
              </button>
            ) : null}
          </div>
          <div
            className={cx(
              "flex shrink-0 items-center gap-xs pr-2",
              headerActionsClassName
            )}
          >
            {headerActions}
          </div>
        </header>

        <div className="comma-chat-sidebar-panels flex min-h-0 min-w-0 flex-1 flex-col">
          {children}
        </div>
      </div>
    </aside>
  );
};

function RightSidebarResizeHandle({
  ariaLabel,
  constrainedWidth,
  defaultWidth,
  maxWidth,
  minWidth,
  onKeyDown,
  onWidthChange,
  open,
  resizing,
  startResize,
  resizeEdge,
  appearance,
}: {
  ariaLabel: string;
  constrainedWidth: number;
  defaultWidth: number;
  maxWidth: number;
  minWidth: number;
  onKeyDown: (event: ReactKeyboardEvent<HTMLButtonElement>) => void;
  onWidthChange: (width: number) => void;
  open: boolean;
  resizing: boolean;
  startResize: (event: ReactPointerEvent<HTMLButtonElement>) => void;
  resizeEdge: "left" | "right";
  appearance: "divider" | "invisible";
}) {
  const messages = useCommaMessages();
  const [tooltipOpen, setTooltipOpen] = useState(false);
  const tooltipRef = useRef<HTMLDivElement | null>(null);
  const pointerPosition = useRef({ x: 0, y: 0 });
  const tooltipShowTimer = useRef<number | null>(null);
  const resizeDescriptionId = useId();
  const dragToResize = messages.shell_sidebar_drag_to_resize();

  const positionTooltip = useCallback(() => {
    const tooltip = tooltipRef.current;
    if (tooltip === null) {
      return;
    }

    const { x, y } = pointerPosition.current;
    const tooltipWidth = tooltip.offsetWidth;
    const halfHeight = tooltip.offsetHeight / 2;
    const minX = resizeTooltipWindowInset;
    const maxX = Math.max(
      minX,
      window.innerWidth - resizeTooltipWindowInset - tooltipWidth
    );
    const rightX = x + resizeTooltipPointerOffset;
    const leftX = x - resizeTooltipPointerOffset - tooltipWidth;
    const preferredX = leftX >= minX ? leftX : rightX;
    const clampedX = Math.min(Math.max(preferredX, minX), maxX);
    const clampedY = Math.min(
      Math.max(y, resizeTooltipWindowInset + halfHeight),
      window.innerHeight - resizeTooltipWindowInset - halfHeight
    );
    tooltip.style.transform = `translate3d(${clampedX}px, ${clampedY}px, 0)`;
  }, []);

  useLayoutEffect(() => {
    if (tooltipOpen) {
      positionTooltip();
    }
  }, [positionTooltip, tooltipOpen]);

  const cancelTooltipShow = useCallback(() => {
    if (tooltipShowTimer.current === null) {
      return;
    }

    window.clearTimeout(tooltipShowTimer.current);
    tooltipShowTimer.current = null;
  }, []);

  useEffect(() => cancelTooltipShow, [cancelTooltipShow]);

  useEffect(() => {
    if (open) {
      return;
    }

    cancelTooltipShow();
    setTooltipOpen(false);
  }, [cancelTooltipShow, open]);

  const trackPointer = (event: ReactPointerEvent<HTMLElement>) => {
    pointerPosition.current = { x: event.clientX, y: event.clientY };
    positionTooltip();
  };

  const hideTooltip = () => {
    cancelTooltipShow();
    setTooltipOpen(false);
  };

  return (
    <>
      <button
        aria-describedby={resizeDescriptionId}
        aria-label={`Resize ${ariaLabel.toLocaleLowerCase()}`}
        aria-orientation="vertical"
        aria-valuemax={maxWidth}
        aria-valuemin={minWidth}
        aria-valuenow={constrainedWidth}
        // Most of the hit area sits outside the sidebar: a native browser view (Electron
        // WebContentsView) covers the sidebar surface and would swallow presses on it.
        className={`${appearance === "invisible" ? "comma-chat-sidebar-resize-hotspot pointer-events-auto outline-none" : "comma-chat-sidebar-resize-handle"} absolute inset-y-0 z-[8] w-4 cursor-col-resize border-0 bg-transparent p-0 [-webkit-app-region:no-drag]`}
        style={resizeEdge === "right" ? { right: -12 } : { left: -12 }}
        data-comma-functional-cursor=""
        onDoubleClick={() =>
          onWidthChange(clampWidth(defaultWidth, minWidth, maxWidth))
        }
        onKeyDown={onKeyDown}
        onPointerDown={(event) => {
          hideTooltip();
          startResize(event);
        }}
        onPointerEnter={(event) => {
          if (appearance === "invisible" || !open || event.pointerType !== "mouse") {
            return;
          }

          trackPointer(event);
          cancelTooltipShow();
          tooltipShowTimer.current = window.setTimeout(() => {
            tooltipShowTimer.current = null;
            setTooltipOpen(true);
          }, resizeTooltipShowDelay);
        }}
        onPointerLeave={hideTooltip}
        onPointerMove={trackPointer}
        role="separator"
        type="button"
      />
      <span className="sr-only" id={resizeDescriptionId}>
        {dragToResize}
      </span>
      {resizing
        ? createPortal(
            <div
              aria-hidden="true"
              className="comma-chat-sidebar-resize-cursor-overlay"
            />,
            document.body
          )
        : null}
      {open && tooltipOpen
        ? createPortal(
            <div
              aria-hidden="true"
              className="comma-chat-sidebar-resize-tooltip"
              data-testid="comma-chat-sidebar-resize-tooltip"
              ref={tooltipRef}
            >
              <div className="comma-chat-sidebar-resize-tooltip-bubble">
                <TooltipBubble content={dragToResize} />
              </div>
            </div>,
            document.body
          )
        : null}
    </>
  );
}
