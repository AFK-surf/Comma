import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useEffectEvent,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
  type RefObject,
} from "react";
import type { PopoverProps as AriaPopoverProps } from "react-aria-components";
import {
  ListLayout,
  Popover as AriaPopover,
  SelectStateContext as AriaSelectStateContext,
  Virtualizer,
} from "react-aria-components";
import { borderWidth, spacing, typeScale } from "../../tokens";
import { ChevronDownSmallIcon } from "../icons";
import {
  menuPopoverInPlaceExitingClasses,
  menuPopoverStaticClasses,
} from "../menu/styles";
import { ScrollArea } from "../scroll-area";
import { cx, definedProps } from "../utils";

export type SelectItemType = {
  id: string;
  label: string;
  subtitle?: string;
  disabled?: boolean;
  /** CSS font-family for the label, so a font option previews its face. */
  fontFamily?: string;
  leading?: ReactNode;
  separatorBefore?: boolean;
};

export type SelectContextValue = {
  contentAlign: "start" | "end";
  size: "xs" | "sm" | "md";
  /** Virtualized rows take the popover's width and truncate long labels. */
  virtualized?: boolean;
};

export const SelectContext = createContext<SelectContextValue>({
  contentAlign: "start",
  size: "md",
});

type SelectRowContentProps = {
  className?: string;
  indicator: ReactNode;
  leading?: ReactNode;
  isLabelFluid?: boolean;
  label: ReactNode;
};

export const selectRowHeightClassName = {
  xs: "h-[calc(var(--text-sm--line-height)+(var(--spacing-sm)*2))]",
  sm: "h-[calc(var(--text-sm--line-height)+(var(--spacing-md)*2))]",
  md: "h-[calc(var(--text-sm--line-height)+((var(--spacing-md)+var(--spacing-xxs))*2))]",
} as const;

export const SelectRowContent = ({
  className,
  indicator,
  leading,
  isLabelFluid = true,
  label,
}: SelectRowContentProps) => {
  const { contentAlign } = useContext(SelectContext);

  return (
    <span
      className={cx("flex min-w-0 items-center gap-md", className)}
      data-slot="dropdown-row-content"
    >
      {leading ? (
        <span
          aria-hidden="true"
          className="flex shrink-0 items-center"
          data-slot="dropdown-row-leading"
        >
          {leading}
        </span>
      ) : null}
      <span
        className={cx(
          "min-w-0 overflow-hidden whitespace-nowrap",
          isLabelFluid ? "flex-1" : "flex-auto",
          contentAlign === "end" ? "text-end" : "text-start"
        )}
        data-slot="dropdown-row-label"
      >
        {label}
      </span>
      <span
        className="flex size-5 shrink-0 items-center justify-center"
        data-slot="dropdown-row-indicator"
      >
        {indicator}
      </span>
    </span>
  );
};

type SelectPopoverProps = Omit<AriaPopoverProps, "children"> & {
  children?: ReactNode;
  items: SelectItemType[];
  size?: "xs" | "sm" | "md";
  /** Renders only the rows in view, for lists of hundreds of options. */
  virtualized?: boolean;
};

type ContentRevealMode = "idle" | "full" | "scroll";

export const selectItemHeight = {
  xs: typeScale.textSm.lineHeight + spacing.sm * 2,
  sm: typeScale.textSm.lineHeight + spacing.md * 2,
  md: typeScale.textSm.lineHeight + (spacing.md + spacing.xxs) * 2,
} as const;

const selectPopoverMaxHeight = {
  xs: { className: "max-h-56", rem: 14 },
  sm: { className: "max-h-56", rem: 14 },
  md: { className: "max-h-64", rem: 16 },
} as const;

export const selectSeparatorHeight = spacing.xs * 2 + borderWidth["0-5"];

/**
 * How far the trigger label's text ink sits from the label box's own left
 * edge — the slack an end-aligned label leaves before its text. Trigger and
 * option rows share the same row geometry (leading, gap, indicator), so this
 * slack is exactly the cross offset that puts the checked option's ink over
 * the trigger's ink; start-aligned labels measure 0. Null when no measurable
 * label text renders (empty value, non-dropdown trigger). LTR only, like the
 * rest of the selection-aligned math.
 */
export function readTriggerLabelInkInsetPx(trigger: Element | null) {
  if (!trigger || typeof document === "undefined") return null;
  const label = trigger.querySelector('[data-slot="dropdown-trigger-label"]');
  if (!label?.textContent) return null;
  const range = document.createRange();
  range.selectNodeContents(label);
  // jsdom ranges have no layout; treat that as "no measurable ink".
  if (typeof range.getBoundingClientRect !== "function") return null;
  const inkRect = range.getBoundingClientRect();
  if (inkRect.width <= 0) return null;
  return inkRect.left - label.getBoundingClientRect().left;
}

export const countSeparatorsThroughIndex = (
  items: ReadonlyArray<{ separatorBefore?: boolean }>,
  selectedIndex: number
) =>
  items.slice(0, Math.max(selectedIndex, 0) + 1).filter((item) => item.separatorBefore)
    .length;

export interface AnchoredPopoverOffsetOptions {
  anchorIndex: number;
  chromeBorderWidth?: number;
  chromePaddingTop?: number;
  rowHeight: number;
  separatorCount?: number;
  triggerHeight?: number;
}

/**
 * Vertical offset from the trigger's bottom edge that places the anchor row's
 * center over the trigger's center, macOS pop-up style. With equal row and
 * trigger heights this collapses to the classic
 * `-(rowHeight * (index + 1) + chrome)` select offset.
 */
export const getAnchoredPopoverOffset = ({
  anchorIndex,
  chromeBorderWidth = borderWidth.default,
  chromePaddingTop = spacing.xs,
  rowHeight,
  separatorCount = 0,
  triggerHeight = rowHeight,
}: AnchoredPopoverOffsetOptions) =>
  -(
    (triggerHeight + rowHeight) / 2 +
    rowHeight * Math.max(anchorIndex, 0) +
    selectSeparatorHeight * Math.max(separatorCount, 0) +
    chromePaddingTop +
    chromeBorderWidth
  );

export const getSelectPopoverOffset = (
  size: "xs" | "sm" | "md",
  selectedIndex: number,
  renderedRowHeight = selectItemHeight[size],
  separatorCount = 0
) =>
  getAnchoredPopoverOffset({
    anchorIndex: selectedIndex,
    rowHeight: renderedRowHeight,
    separatorCount,
  });

export const getSelectPopoverVerticalSubpixelCorrection = (idealTop: number) =>
  idealTop - Math.floor(idealTop);

interface SelectPopoverTopConstraintOptions {
  offset: number;
  triggerHeight: number;
  triggerTop: number;
  viewportTop?: number;
  containerPadding?: number;
  overlaySafeTop?: number;
}

export const readOverlaySafeTopPx = (element: Element | null) => {
  if (!element || typeof window === "undefined") return 0;
  const raw = getComputedStyle(element)
    .getPropertyValue("--comma-overlay-safe-top")
    .trim();
  if (!raw) return 0;
  const value = Number.parseFloat(raw);
  if (!Number.isFinite(value) || value < 0) return 0;
  if (raw.endsWith("rem")) {
    const rootFontSize = Number.parseFloat(
      getComputedStyle(document.documentElement).fontSize
    );
    return value * (Number.isFinite(rootFontSize) ? rootFontSize : 16);
  }
  return value;
};

const resolvedTopInset = (containerPadding: number, overlaySafeTop: number) =>
  Math.max(containerPadding, overlaySafeTop);

export const constrainSelectPopoverOffsetToViewportTop = ({
  offset,
  triggerHeight,
  triggerTop,
  viewportTop = 0,
  containerPadding = spacing.lg,
  overlaySafeTop = 0,
}: SelectPopoverTopConstraintOptions) =>
  Math.max(
    offset,
    viewportTop +
      resolvedTopInset(containerPadding, overlaySafeTop) -
      (triggerTop + triggerHeight)
  );

export const getSelectionAlignedPopoverLayout = ({
  items,
  selectedIndex,
  size = "sm",
  trigger,
}: {
  items: ReadonlyArray<{ separatorBefore?: boolean }>;
  selectedIndex: number;
  size?: "xs" | "sm" | "md";
  trigger: HTMLElement | null;
}) => {
  const triggerRect = trigger?.getBoundingClientRect();
  const renderedRowHeight =
    triggerRect && triggerRect.height > 0 ? triggerRect.height : selectItemHeight[size];
  const separatorCount = items.filter((item) => item.separatorBefore).length;
  const offset = getSelectPopoverOffset(
    size,
    selectedIndex,
    renderedRowHeight,
    countSeparatorsThroughIndex(items, selectedIndex)
  );
  const resolvedOffset =
    !triggerRect || triggerRect.height <= 0
      ? offset
      : constrainSelectPopoverOffsetToViewportTop({
          offset,
          triggerHeight: triggerRect.height,
          triggerTop: triggerRect.top,
          overlaySafeTop: readOverlaySafeTopPx(trigger),
        });
  const idealPopoverTop =
    triggerRect && triggerRect.height > 0
      ? triggerRect.bottom +
        (typeof window === "undefined" ? 0 : window.scrollY) +
        resolvedOffset
      : 0;
  const verticalSubpixelCorrection =
    triggerRect && triggerRect.height > 0
      ? getSelectPopoverVerticalSubpixelCorrection(idealPopoverTop)
      : 0;

  return {
    maxHeight:
      Math.ceil(
        renderedRowHeight * items.length +
          selectSeparatorHeight * separatorCount +
          spacing.xs * 2 +
          borderWidth.default * 2
      ) + 1,
    offset: resolvedOffset,
    paddingBottom: spacing.xs - verticalSubpixelCorrection,
    paddingTop: spacing.xs + verticalSubpixelCorrection,
  };
};

export const getSelectionAlignedPopoverOffset = (
  options: Parameters<typeof getSelectionAlignedPopoverLayout>[0]
) => getSelectionAlignedPopoverLayout(options).offset;

interface SelectPopoverViewportOptions {
  size: "xs" | "sm" | "md";
  selectedIndex: number;
  itemCount: number;
  triggerTop: number;
  viewportTop?: number;
  viewportHeight: number;
  containerPadding?: number;
  overlaySafeTop?: number;
  renderedRowHeight?: number;
  separatorCount?: number;
  separatorCountThroughAnchor?: number;
  triggerHeight?: number;
  chromeBorderWidth?: number;
  chromePaddingTop?: number;
}

export const isSelectPopoverViewportConstrained = ({
  size,
  selectedIndex,
  itemCount,
  triggerTop,
  viewportTop = 0,
  viewportHeight,
  containerPadding = spacing.lg,
  overlaySafeTop = 0,
  renderedRowHeight = selectItemHeight[size],
  separatorCount = 0,
  separatorCountThroughAnchor = 0,
  triggerHeight = renderedRowHeight,
  chromeBorderWidth = borderWidth.default,
  chromePaddingTop = spacing.xs,
}: SelectPopoverViewportOptions) => {
  const itemHeight = renderedRowHeight;
  const anchorIndex = Math.min(Math.max(selectedIndex, 0), Math.max(itemCount - 1, 0));
  const chromeTop = chromePaddingTop + chromeBorderWidth;
  const menuChrome = chromeTop * 2;
  const menuHeight =
    itemCount * itemHeight +
    Math.max(separatorCount, 0) * selectSeparatorHeight +
    menuChrome;
  const topInset = resolvedTopInset(containerPadding, overlaySafeTop);
  const idealTop =
    triggerTop +
    (triggerHeight - itemHeight) / 2 -
    (anchorIndex * itemHeight +
      Math.max(separatorCountThroughAnchor, 0) * selectSeparatorHeight +
      chromeTop);

  return (
    idealTop < viewportTop + topInset ||
    idealTop + menuHeight > viewportTop + viewportHeight - containerPadding
  );
};

export interface SelectionAlignedPopoverOptions {
  /** Border width of the popover chrome; enters the anchor offset math. */
  chromeBorderWidth?: number;
  containerPadding?: number;
  isOpen: boolean;
  items: ReadonlyArray<{ separatorBefore?: boolean }>;
  /** Explicit offset override; skips the selection-aligned math. */
  offset?: number | undefined;
  /** Height of one popover row; defaults to the measured trigger height. */
  rowHeight?: number | undefined;
  selectedIndex: number;
  size?: "xs" | "sm" | "md";
  triggerRef?: RefObject<Element | null> | null | undefined;
}

/**
 * Shared macOS-pop-up positioning for selection popovers: the checked row's
 * center opens over the trigger's center, the offset follows the selection on
 * every open, the popover clamps to the viewport top (scrolling a long list to
 * keep the checked row in place), and clipped content reveals itself when the
 * pointer reaches the bottom chevron.
 */
export const useSelectionAlignedPopover = ({
  chromeBorderWidth = borderWidth.default,
  containerPadding = spacing.lg,
  isOpen,
  items,
  offset,
  rowHeight,
  selectedIndex,
  size = "md",
  triggerRef,
}: SelectionAlignedPopoverOptions) => {
  // Only an open popover is positioned. This runs during render, and trigger
  // rects and visual-viewport metrics both force a synchronous reflow, so a
  // closed select must not read them: each render of a host that holds
  // several (a Settings page) would otherwise reflow once per select.
  const trigger = isOpen ? (triggerRef?.current ?? null) : null;
  const triggerRect = trigger?.getBoundingClientRect();
  const measuredTriggerHeight =
    triggerRect && triggerRect.height > 0 ? triggerRect.height : undefined;
  const renderedRowHeight =
    rowHeight ?? measuredTriggerHeight ?? selectItemHeight[size];
  const triggerHeight = measuredTriggerHeight ?? renderedRowHeight;
  const anchorIndex = Math.max(selectedIndex, 0);
  const separatorCountThroughAnchor = countSeparatorsThroughIndex(items, anchorIndex);
  const separatorCount = items.filter((item) => item.separatorBefore).length;
  const visualViewport =
    typeof window === "undefined" ? undefined : window.visualViewport;
  const overlaySafeTop = readOverlaySafeTopPx(trigger);
  const isViewportConstrained = triggerRect
    ? isSelectPopoverViewportConstrained({
        size,
        selectedIndex: anchorIndex,
        itemCount: items.length,
        triggerTop: triggerRect.top,
        viewportTop: visualViewport?.offsetTop ?? 0,
        viewportHeight: visualViewport?.height ?? window.innerHeight,
        containerPadding,
        overlaySafeTop,
        renderedRowHeight,
        separatorCount,
        separatorCountThroughAnchor,
        triggerHeight,
        chromeBorderWidth,
      })
    : false;
  const resolvedContainerPadding = isViewportConstrained
    ? spacing.none
    : containerPadding;
  const resolvedTopInsetPx = resolvedTopInset(resolvedContainerPadding, overlaySafeTop);
  const [contentExpansion, setContentExpansion] = useState(0);
  const [contentRevealMode, setContentRevealMode] = useState<ContentRevealMode>("idle");
  const scrollViewportRef = useRef<HTMLDivElement>(null);
  const revealAllContent = useCallback(() => {
    const viewport = scrollViewportRef.current;

    if (!viewport) {
      return;
    }

    const overflowHeight = Math.max(0, viewport.scrollHeight - viewport.clientHeight);
    const popover = viewport.closest<HTMLElement>(
      '[data-positioning="selection-aligned"]'
    );

    if (!popover || overflowHeight < 1) {
      return;
    }

    const viewportTop = window.visualViewport?.offsetTop ?? 0;
    const popoverRect = popover.getBoundingClientRect();
    const availableSpaceAbove = Math.max(
      0,
      popoverRect.top - viewportTop - resolvedTopInsetPx
    );
    const rootFontSize = Number.parseFloat(
      window.getComputedStyle(document.documentElement).fontSize
    );
    const maxPopoverHeight =
      selectPopoverMaxHeight[size].rem *
      (Number.isFinite(rootFontSize) ? rootFontSize : 16);
    const availableHeightGrowth = Math.max(0, maxPopoverHeight - popoverRect.height);
    const expansion = Math.min(
      overflowHeight,
      availableSpaceAbove,
      availableHeightGrowth
    );
    const revealsAllContent = expansion >= overflowHeight - 1;

    if (revealsAllContent) {
      viewport.scrollTop = 0;
    }
    setContentExpansion(expansion);
    setContentRevealMode(revealsAllContent ? "full" : "scroll");
  }, [resolvedTopInsetPx, size]);

  const revealFromPointer = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => {
      if (contentRevealMode !== "idle") return;
      const popover = event.currentTarget.closest<HTMLElement>(
        '[data-positioning="selection-aligned"]'
      );
      if (!popover) return;
      if (popover.getBoundingClientRect().bottom - event.clientY > spacing["4xl"]) {
        return;
      }
      revealAllContent();
    },
    [contentRevealMode, revealAllContent]
  );

  useEffect(() => {
    if (!isOpen) {
      setContentExpansion(0);
      setContentRevealMode("idle");
    }
  }, [isOpen]);

  const selectionAlignedOffset =
    (offset ??
      getAnchoredPopoverOffset({
        anchorIndex,
        chromeBorderWidth,
        rowHeight: renderedRowHeight,
        separatorCount: separatorCountThroughAnchor,
        triggerHeight,
      })) - contentExpansion;
  const resolvedOffset = triggerRect
    ? constrainSelectPopoverOffsetToViewportTop({
        offset: selectionAlignedOffset,
        triggerHeight: triggerRect.height,
        triggerTop: triggerRect.top,
        viewportTop: visualViewport?.offsetTop ?? 0,
        containerPadding: resolvedContainerPadding,
        overlaySafeTop,
      })
    : selectionAlignedOffset;
  // The viewport-top clamp moves the popover, and the checked row with it,
  // below the aligned place. A short list may just move. When that would carry
  // the checked row past the viewport bottom, the list scrolls by the same
  // distance, so the row stays over the trigger like a macOS pop-up.
  const clampShift = resolvedOffset - selectionAlignedOffset;
  const scrollsToAnchor =
    triggerRect !== undefined &&
    clampShift > 0 &&
    triggerRect.top + (triggerRect.height + renderedRowHeight) / 2 + clampShift >
      (visualViewport?.offsetTop ?? 0) +
        (visualViewport?.height ?? window.innerHeight) -
        resolvedTopInsetPx -
        spacing.xs -
        chromeBorderWidth;
  const anchorScrollTop = scrollsToAnchor ? clampShift : 0;
  // Scrolled by the shift, the popover shows the rows from there to the end.
  const anchorScrollMaxHeight = scrollsToAnchor
    ? renderedRowHeight * items.length +
      selectSeparatorHeight * separatorCount +
      (spacing.xs + chromeBorderWidth) * 2 -
      clampShift
    : undefined;
  const readAnchorScrollTop = useEffectEvent(() => anchorScrollTop);

  useEffect(() => {
    if (!isOpen) return;
    const viewport = scrollViewportRef.current;
    if (!viewport) return;

    // React Aria scrolls the focused option into view as the list opens. The
    // offset has already placed that option, so restore the scroll it assumes.
    const restoreAnchorScroll = () => {
      const scrollTop = readAnchorScrollTop();
      if (Math.abs(viewport.scrollTop - scrollTop) > 1) {
        viewport.scrollTop = scrollTop;
      }
    };

    restoreAnchorScroll();
    const frame = requestAnimationFrame(restoreAnchorScroll);
    const timeout = window.setTimeout(restoreAnchorScroll, 0);
    return () => {
      cancelAnimationFrame(frame);
      window.clearTimeout(timeout);
    };
  }, [anchorIndex, isOpen]);

  const idealPopoverTop = triggerRect
    ? triggerRect.bottom +
      (typeof window === "undefined" ? 0 : window.scrollY) +
      resolvedOffset
    : 0;
  const verticalSubpixelCorrection =
    getSelectPopoverVerticalSubpixelCorrection(idealPopoverTop);
  // macOS pop-ups anchor the TEXT, not the control box: the checked option's
  // ink opens exactly over the trigger's ink, so a trigger whose label text
  // sits away from its label box's start (e.g. end-aligned toward its
  // chevron) slides the popover sideways instead of moving the text.
  // Start-aligned triggers measure no slack and resolve to zero.
  const crossOffset = trigger ? (readTriggerLabelInkInsetPx(trigger) ?? 0) : 0;

  return {
    anchorIndex,
    contentExpansion,
    contentPaddingBottom: spacing.xs - verticalSubpixelCorrection,
    contentPaddingTop: spacing.xs + verticalSubpixelCorrection,
    contentRevealMode,
    isViewportConstrained,
    maxHeightClassName: selectPopoverMaxHeight[size].className,
    popoverDataProps: {
      "data-anchor-index": anchorIndex,
      "data-content-expanded": contentExpansion > 0 || undefined,
      "data-content-fully-expanded": contentRevealMode === "full" || undefined,
      "data-positioning": "selection-aligned" as const,
      "data-scroll-fallback": contentRevealMode === "scroll" || undefined,
      "data-viewport-constrained": isViewportConstrained || undefined,
    },
    popoverPositionProps: {
      containerPadding: resolvedTopInsetPx,
      crossOffset,
      maxHeight: anchorScrollMaxHeight,
      offset: resolvedOffset,
      shouldFlip: false,
    },
    revealAllContent,
    revealFromPointer,
    rowHeight: renderedRowHeight,
    scrollViewportRef,
  };
};

/** The bottom chevron that reveals viewport-clipped rows on hover. */
export const SelectionAlignedRevealIndicator = ({
  onReveal,
}: {
  onReveal: () => void;
}) => (
  <div
    aria-hidden="true"
    className="comma-selection-reveal-indicator pointer-events-none absolute inset-x-0 bottom-0 z-10 flex h-4xl items-center justify-center"
    data-slot="dropdown-scroll-down"
  >
    <span
      className="pointer-events-none"
      data-slot="dropdown-scroll-down-hit"
      onMouseEnter={onReveal}
    >
      <ChevronDownSmallIcon className="size-5 text-quaternary" />
    </span>
  </div>
);

/**
 * Lays out rows at a fixed height and mounts only those in view. The rows
 * scroll with the enclosing ScrollArea. The trigger is measured only while the
 * popover is open, so the height taken on open also serves the exit fade.
 */
const VirtualizedRows = ({
  children,
  rowHeight,
}: {
  children: ReactNode;
  rowHeight: number;
}) => {
  const [layoutOptions] = useState(() => ({ loaderHeight: rowHeight, rowHeight }));
  return (
    <Virtualizer layout={ListLayout} layoutOptions={layoutOptions}>
      {children}
    </Virtualizer>
  );
};

export const SelectPopover = ({
  size = "md",
  className,
  children,
  containerPadding = spacing.lg,
  items,
  offset,
  placement = "bottom start",
  shouldFlip = false,
  triggerRef,
  virtualized = false,
  ...props
}: SelectPopoverProps) => {
  const selectState = useContext(AriaSelectStateContext);
  const popoverRef = useRef<HTMLDivElement>(null);
  const isOpen = selectState?.isOpen;
  // Keep this listener stable when keyboard modality updates the Select state.
  const close = useEffectEvent(() => selectState?.close());
  useEffect(() => {
    const trigger = triggerRef?.current;
    if (!isOpen || !trigger) return;
    const document = trigger.ownerDocument;
    // Focus can briefly leave the menu during an exit/reopen transition.
    // The menu's local Escape handler cannot receive those key events.
    const dismiss = (event: KeyboardEvent) => {
      if (
        event.key !== "Escape" ||
        event.isComposing ||
        (event.target !== document.body &&
          !(event.target instanceof Node && trigger.contains(event.target)))
      )
        return;
      event.preventDefault();
      event.stopPropagation();
      close();
    };
    document.addEventListener("keydown", dismiss, true);
    return () => document.removeEventListener("keydown", dismiss, true);
  }, [isOpen, triggerRef]);
  useEffect(() => {
    const popover = popoverRef.current;
    if (!popover || isOpen === undefined) return;
    // React Aria removes background inertness in its passive-effect cleanup.
    // Move owned focus out before inert blurs it into the containing modal.
    if (!isOpen && popover.contains(popover.ownerDocument.activeElement)) {
      const trigger = triggerRef?.current;
      if (trigger instanceof HTMLElement) trigger.focus({ preventScroll: true });
    }
    popover.inert = !isOpen;
  }, [isOpen, triggerRef]);
  const selectedIndex =
    selectState?.selectedKey != null
      ? items.findIndex((item) => item.id === String(selectState.selectedKey))
      : 0;
  const aligned = useSelectionAlignedPopover({
    containerPadding,
    isOpen: selectState?.isOpen ?? false,
    items,
    offset,
    selectedIndex,
    size,
    triggerRef,
  });

  return (
    <AriaPopover
      {...props}
      {...definedProps({ triggerRef })}
      {...aligned.popoverDataProps}
      data-animation="in-place"
      ref={popoverRef}
      containerPadding={aligned.popoverPositionProps.containerPadding}
      crossOffset={aligned.popoverPositionProps.crossOffset}
      {...definedProps({ maxHeight: aligned.popoverPositionProps.maxHeight })}
      offset={aligned.popoverPositionProps.offset}
      placement={placement}
      shouldFlip={shouldFlip}
      className={(state) =>
        cx(
          "z-50 w-max min-w-[var(--trigger-width)] max-w-[calc(100vw-(var(--spacing-lg)*2))] overflow-hidden rounded-xl border bg-primary shadow-lg outline-none [-webkit-app-region:no-drag]",
          aligned.maxHeightClassName,
          menuPopoverStaticClasses,
          state.isExiting && menuPopoverInPlaceExitingClasses,
          typeof className === "function" ? className(state) : className
        )
      }
    >
      <ScrollArea
        ref={aligned.scrollViewportRef}
        className="max-h-[inherit]"
        contentClassName="min-w-full"
        contentStyle={{
          paddingBottom: `${aligned.contentPaddingBottom}px`,
          paddingTop: `${aligned.contentPaddingTop}px`,
        }}
        edgeBlur={{ endSize: spacing["3xl"], startSize: spacing["3xl"] }}
        edgeEffect={aligned.contentRevealMode === "full" ? "none" : "blur"}
        scrollbar={false}
        viewportClassName="max-h-[inherit]"
        viewportProps={{ onPointerMove: aligned.revealFromPointer, tabIndex: -1 }}
      >
        {virtualized ? (
          <VirtualizedRows rowHeight={aligned.rowHeight}>{children}</VirtualizedRows>
        ) : (
          children
        )}
      </ScrollArea>
      <SelectionAlignedRevealIndicator onReveal={aligned.revealAllContent} />
    </AriaPopover>
  );
};
