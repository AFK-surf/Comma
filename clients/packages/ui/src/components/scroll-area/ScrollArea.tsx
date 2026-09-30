import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  type CSSProperties,
  type HTMLAttributes,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
  type UIEventHandler,
  type WheelEventHandler,
} from "react";
import { cx } from "../utils";

export type ScrollAreaOrientation = "vertical" | "horizontal" | "both";
export type ScrollAreaEdgeEffect = "none" | "mask" | "blur";
export type ScrollAreaScrollbarVisibility =
  | "always"
  | "hover"
  | "scroll"
  | "scrollbar-hover";
export type ScrollAreaScrollbarRevealSource = "all" | "interaction";

type ScrollAreaEdgeAxis = "vertical" | "horizontal";

export interface ScrollEdgeMask {
  enabled?: boolean;
  size?: number;
  startSize?: number;
  endSize?: number;
  threshold?: number;
  startThreshold?: number;
  endThreshold?: number;
}

export interface ScrollEdgeBlur {
  enabled?: boolean;
  size?: number;
  startSize?: number;
  endSize?: number;
  minBlur?: number;
  maxBlur?: number;
  blurCurve?: number;
  layers?: number;
  maskCoverage?: number;
  maskCurve?: number;
  threshold?: number;
  startThreshold?: number;
  endThreshold?: number;
}

export interface ScrollAreaScrollbarOptions {
  enabled?: boolean;
  size?: number;
  inset?: number;
  minThumbSize?: number;
}

export interface ScrollAreaMetrics {
  clientHeight: number;
  maxScrollTop: number;
  scrollHeight: number;
  scrollTop: number;
}

export interface ScrollAreaProps extends Omit<
  HTMLAttributes<HTMLDivElement>,
  "children" | "onScroll"
> {
  children?: ReactNode;
  orientation?: ScrollAreaOrientation;
  scrollbar?: boolean | ScrollAreaScrollbarOptions;
  scrollbarVisibility?: ScrollAreaScrollbarVisibility;
  /**
   * Which scrolls reveal the scrollbar when visibility is `scroll`.
   * `interaction` excludes application-driven scroll position updates.
   */
  scrollbarRevealSource?: ScrollAreaScrollbarRevealSource;
  /** Delay before a scroll-triggered scrollbar hides. Only used by `scroll`. */
  scrollbarHideDelay?: number;
  /** Reveal the scrollbar when its track is hovered. Only used by `scroll`. */
  scrollbarHoverReveal?: boolean;
  edgeEffect?: ScrollAreaEdgeEffect;
  edgeMask?: boolean | ScrollEdgeMask;
  edgeBlur?: boolean | ScrollEdgeBlur;
  edgeTransitionDuration?: number;
  edgeTransitionEasing?: string;
  /**
   * Keep the content's inline layout size stable during an OS window resize.
   * The viewport still follows the window exactly; only the expensive document
   * subtree reflows once after the resize settles.
   */
  freezeContentInlineSizeOnWindowResize?: boolean;
  observeResize?: boolean;
  viewportClassName?: string;
  viewportProps?: Omit<
    HTMLAttributes<HTMLDivElement>,
    "children" | "className" | "onScroll"
  >;
  contentClassName?: string;
  contentStyle?: CSSProperties;
  /**
   * Also observe one content descendant with the shared ResizeObserver. Use
   * this when a fixed-size layout shell can hide meaningful inner resizes.
   * The caller passes the element: resolving a selector here would rescan the
   * whole content subtree on every render of a streaming transcript.
   */
  contentResizeTarget?: Element | null;
  onScroll?: UIEventHandler<HTMLDivElement>;
  /** Batched scroll geometry measured with the scrollbar metrics frame. */
  onMetricsChange?: (metrics: ScrollAreaMetrics) => void;
  /**
   * Notified from the shared ScrollArea resize observer whenever the content
   * element resizes. Prefer this over attaching per-instance `ResizeObserver`
   * logic around scroll areas.
   */
  onContentResize?: () => void;
  /** Notified from the same shared observer whenever the viewport resizes. */
  onViewportResize?: () => void;
}

type StyleWithVars = CSSProperties & Record<`--${string}`, string | number>;

interface NormalizedEdgeMask {
  enabled: boolean;
  startSize: number;
  endSize: number;
  startThreshold: number;
  endThreshold: number;
}

interface NormalizedEdgeBlur extends NormalizedEdgeMask {
  minBlur: number;
  maxBlur: number;
  blurCurve: number;
  layers: number;
  maskCoverage: number;
  maskCurve: number;
}

interface NormalizedScrollbar {
  enabled: boolean;
  size: number;
  inset: number;
  minThumbSize: number;
}

type ResizeCallback = () => void;

const resizeSubscriptions = new Map<Element, Set<ResizeCallback>>();
/**
 * How long after wheel input a scroll of the same viewport still counts as the
 * reader's. The browser scrolls a wheel itself, off the main thread, so the
 * two arrive as separate events; a smooth-scrolled wheel keeps moving the
 * viewport for about this long after the wheel that started it.
 */
const WHEEL_SCROLL_WINDOW_MS = 250;
const VIEWPORT_SELECTOR = '[data-slot="scroll-area-viewport"]';
const SCROLL_REVEAL_KEYS = new Set([
  " ",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "ArrowUp",
  "End",
  "Home",
  "PageDown",
  "PageUp",
]);
const TEXT_EDITING_SELECTOR = 'input, textarea, select, [contenteditable="true"]';
const SPACE_ACTIVATION_SELECTOR = 'button, a[href], [role="button"]';
let sharedResizeObserver: ResizeObserver | null = null;

const useIsomorphicLayoutEffect =
  typeof window === "undefined" ? useEffect : useLayoutEffect;

function clamp(value: number, min: number, max: number) {
  return Math.min(Math.max(value, min), max);
}

function px(value: number) {
  return `${Math.max(0, value)}px`;
}

function normalizeEdgeMask(edgeMask: ScrollAreaProps["edgeMask"]): NormalizedEdgeMask {
  if (!edgeMask) {
    return {
      enabled: false,
      startSize: 0,
      endSize: 0,
      startThreshold: 1,
      endThreshold: 1,
    };
  }

  const options = edgeMask === true ? {} : edgeMask;
  const size = options.size ?? 24;
  const threshold = options.threshold ?? 1;

  return {
    enabled: options.enabled ?? true,
    startSize: options.startSize ?? size,
    endSize: options.endSize ?? size,
    startThreshold: options.startThreshold ?? threshold,
    endThreshold: options.endThreshold ?? threshold,
  };
}

function normalizeEdgeBlur(edgeBlur: ScrollAreaProps["edgeBlur"]): NormalizedEdgeBlur {
  if (!edgeBlur) {
    return {
      enabled: false,
      startSize: 0,
      endSize: 0,
      startThreshold: 1,
      endThreshold: 1,
      minBlur: 0,
      maxBlur: 0,
      blurCurve: 1,
      layers: 0,
      maskCoverage: 0,
      maskCurve: 1,
    };
  }

  const options = edgeBlur === true ? {} : edgeBlur;
  const size = options.size ?? 36;
  const threshold = options.threshold ?? 1;
  const minBlur = Math.max(0, options.minBlur ?? 0);
  const maxBlur = Math.max(minBlur, options.maxBlur ?? 14);

  return {
    enabled: options.enabled ?? true,
    startSize: options.startSize ?? size,
    endSize: options.endSize ?? size,
    startThreshold: options.startThreshold ?? threshold,
    endThreshold: options.endThreshold ?? threshold,
    minBlur,
    maxBlur,
    blurCurve: clamp(options.blurCurve ?? 3.1, 0.2, 4),
    layers: clamp(Math.round(options.layers ?? 4), 1, 8),
    maskCoverage: clamp(options.maskCoverage ?? 100, 0, 100),
    maskCurve: clamp(options.maskCurve ?? 1.7, 0.2, 4),
  };
}

function normalizeScrollbar(
  scrollbar: ScrollAreaProps["scrollbar"]
): NormalizedScrollbar {
  if (scrollbar === false) {
    return {
      enabled: false,
      size: 0,
      inset: 0,
      minThumbSize: 0,
    };
  }

  const options = scrollbar === true || scrollbar == null ? {} : scrollbar;

  return {
    enabled: options.enabled ?? true,
    size: options.size ?? 8,
    inset: options.inset ?? 2,
    minThumbSize: options.minThumbSize ?? 28,
  };
}

function observeElementResize(element: Element, callback: ResizeCallback) {
  const ResizeObserverCtor = globalThis.ResizeObserver;

  if (!ResizeObserverCtor) {
    return undefined;
  }

  let callbacks = resizeSubscriptions.get(element);
  if (!callbacks) {
    callbacks = new Set();
    resizeSubscriptions.set(element, callbacks);
  }

  callbacks.add(callback);

  if (!sharedResizeObserver) {
    // One observer handles every ScrollArea instance to keep dynamic lists cheap.
    sharedResizeObserver = new ResizeObserverCtor((entries) => {
      const pendingCallbacks = new Set<ResizeCallback>();

      for (const entry of entries) {
        const targetCallbacks = resizeSubscriptions.get(entry.target);
        targetCallbacks?.forEach((targetCallback) =>
          pendingCallbacks.add(targetCallback)
        );
      }

      pendingCallbacks.forEach((pendingCallback) => pendingCallback());
    });
  }

  sharedResizeObserver.observe(element);

  return () => {
    const activeCallbacks = resizeSubscriptions.get(element);
    activeCallbacks?.delete(callback);

    if (!activeCallbacks?.size) {
      resizeSubscriptions.delete(element);
      sharedResizeObserver?.unobserve(element);
    }

    if (!resizeSubscriptions.size) {
      sharedResizeObserver?.disconnect();
      sharedResizeObserver = null;
    }
  };
}

function requestMeasureFrame(callback: () => void) {
  if (typeof window !== "undefined" && window.requestAnimationFrame) {
    return window.requestAnimationFrame(callback);
  }

  return globalThis.setTimeout(callback, 16) as unknown as number;
}

function cancelMeasureFrame(frame: number) {
  if (typeof window !== "undefined" && window.cancelAnimationFrame) {
    window.cancelAnimationFrame(frame);
    return;
  }

  globalThis.clearTimeout(frame);
}

function resolveEdgeAxis(orientation: ScrollAreaOrientation): ScrollAreaEdgeAxis {
  return orientation === "horizontal" ? "horizontal" : "vertical";
}

function resolveEdgeEffect(
  edgeEffect: ScrollAreaEdgeEffect | undefined,
  edgeMask: ScrollAreaProps["edgeMask"],
  edgeBlur: ScrollAreaProps["edgeBlur"]
): ScrollAreaEdgeEffect {
  if (edgeEffect) {
    return edgeEffect;
  }

  if (edgeMask) {
    return "mask";
  }

  if (edgeBlur) {
    return "blur";
  }

  return "none";
}

function canScrollAxis(orientation: ScrollAreaOrientation, axis: ScrollAreaEdgeAxis) {
  if (orientation === "both") {
    return true;
  }

  return orientation === axis;
}

function setDatasetBoolean(element: HTMLElement, key: string, value: boolean) {
  const nextValue = value ? "true" : "false";
  if (element.dataset[key] !== nextValue) {
    element.dataset[key] = nextValue;
  }
}

/**
 * The root keeps the edge state for its siblings and its own size rules. The
 * blur layers read theirs from their own edge element instead: a descendant
 * rule keyed on the root makes each flip of the state restyle the whole
 * scrolled subtree, blurred or not — a transcript, every time a chat leaves
 * its tail. An edge element only shows while the blur effect is the active one.
 */
function setEdgeVisible(
  root: HTMLElement,
  edgeBlur: { element: HTMLElement | null; enabled: boolean },
  key: "edgeStartVisible" | "edgeEndVisible",
  visible: boolean
) {
  setDatasetBoolean(root, key, visible);
  if (edgeBlur.element) {
    setDatasetBoolean(edgeBlur.element, "visible", edgeBlur.enabled && visible);
  }
}

function setStyleProperty(element: HTMLElement, property: string, value: string) {
  if (element.style.getPropertyValue(property) !== value) {
    element.style.setProperty(property, value);
  }
}

function normalizeWheelDelta(delta: number, deltaMode: number, viewportSize: number) {
  if (deltaMode === 1) {
    return delta * 16;
  }

  if (deltaMode === 2) {
    return delta * viewportSize;
  }

  return delta;
}

function isDirectScrollKey(event: KeyboardEvent) {
  if (
    event.altKey ||
    event.ctrlKey ||
    event.metaKey ||
    !SCROLL_REVEAL_KEYS.has(event.key)
  ) {
    return false;
  }

  const target = event.target instanceof Element ? event.target : null;
  if (target?.closest(TEXT_EDITING_SELECTOR)) {
    return false;
  }

  return !(event.key === " " && target?.closest(SPACE_ACTIVATION_SELECTOR));
}

interface BlurLayer {
  blur: number;
  stop: number;
}

function createBlurLayers(config: NormalizedEdgeBlur): BlurLayer[] {
  const blurRange = Math.max(0, config.maxBlur - config.minBlur);

  if (!config.layers) {
    return [];
  }

  return Array.from({ length: config.layers }, (_, index) => {
    const progress = config.layers === 1 ? 1 : index / (config.layers - 1);
    const blurProgress = (index + 1) / config.layers;
    const maskProgress = Math.pow(progress, config.maskCurve);

    return {
      blur: Number(
        (config.minBlur + blurRange * Math.pow(blurProgress, config.blurCurve)).toFixed(
          2
        )
      ),
      stop: Number(Math.max(0, config.maskCoverage * (1 - maskProgress)).toFixed(2)),
    };
  });
}

function getBlurDirection(edgeAxis: ScrollAreaEdgeAxis, edge: "start" | "end") {
  if (edgeAxis === "horizontal") {
    return edge === "start" ? "to right" : "to left";
  }

  return edge === "start" ? "to bottom" : "to top";
}

export const ScrollArea = forwardRef<HTMLDivElement, ScrollAreaProps>(
  (
    {
      className,
      children,
      orientation = "vertical",
      scrollbar = true,
      scrollbarVisibility = "scroll",
      scrollbarRevealSource = "all",
      scrollbarHideDelay = 500,
      scrollbarHoverReveal = true,
      edgeEffect: edgeEffectProp,
      edgeMask,
      edgeBlur,
      edgeTransitionDuration = 450,
      edgeTransitionEasing = "cubic-bezier(0.16, 1, 0.3, 1)",
      freezeContentInlineSizeOnWindowResize = false,
      observeResize = true,
      viewportClassName,
      viewportProps,
      contentClassName,
      contentStyle,
      contentResizeTarget,
      onScroll,
      onMetricsChange,
      onContentResize,
      onViewportResize,
      onPointerEnter,
      style,
      ...rootProps
    },
    forwardedRef
  ) => {
    const rootRef = useRef<HTMLDivElement>(null);
    const viewportRef = useRef<HTMLDivElement>(null);
    const contentRef = useRef<HTMLDivElement>(null);
    const verticalScrollbarRef = useRef<HTMLDivElement>(null);
    const horizontalScrollbarRef = useRef<HTMLDivElement>(null);
    const verticalThumbRef = useRef<HTMLDivElement>(null);
    const horizontalThumbRef = useRef<HTMLDivElement>(null);
    const contentScrollSizeRef = useRef<number | null>(null);
    const measureFrameRef = useRef<number | null>(null);
    const metricsMeasurePendingRef = useRef(false);
    const pendingViewportResizeRef = useRef(false);
    const pendingContentResizeNotificationRef = useRef(false);
    const scrollEndTimeoutRef = useRef<number | null>(null);
    const windowResizeEndTimeoutRef = useRef<number | null>(null);
    const windowResizingRef = useRef(false);
    const dragCleanupRef = useRef<(() => void) | null>(null);
    const viewportBlockSizeRef = useRef(0);
    const viewportInlineSizeRef = useRef(0);
    const viewportScrollSizeRef = useRef(0);
    const lastWheelInputAtRef = useRef(Number.NEGATIVE_INFINITY);
    const wheelMappingRef = useRef<{
      handler: (event: WheelEvent) => void;
      viewport: HTMLDivElement;
    } | null>(null);
    const syncWheelMappingRef = useRef<((hasOverflowX: boolean) => void) | null>(null);
    const edgeBlurStartRef = useRef<HTMLDivElement | null>(null);
    const edgeBlurEndRef = useRef<HTMLDivElement | null>(null);
    const edgeTransitionRef = useRef<{
      armed: boolean;
      frame: number | null;
      state: string | null;
    }>({ armed: false, frame: null, state: null });
    const onViewportResizeRef = useRef(onViewportResize);
    const onMetricsChangeRef = useRef(onMetricsChange);
    useIsomorphicLayoutEffect(() => {
      onViewportResizeRef.current = onViewportResize;
      onMetricsChangeRef.current = onMetricsChange;
    });
    const edgeAxis = resolveEdgeAxis(orientation);
    const edgeEffect = resolveEdgeEffect(edgeEffectProp, edgeMask, edgeBlur);
    const maskConfig = useMemo(
      () =>
        normalizeEdgeMask(
          edgeEffect === "mask"
            ? edgeMask === false
              ? false
              : edgeMask || true
            : false
        ),
      [edgeEffect, edgeMask]
    );
    const blurConfig = useMemo(
      () =>
        normalizeEdgeBlur(
          edgeEffect === "blur"
            ? edgeBlur === false
              ? false
              : edgeBlur || true
            : false
        ),
      [edgeBlur, edgeEffect]
    );
    const blurRenderConfig = useMemo(
      () =>
        normalizeEdgeBlur(
          edgeBlur === false
            ? false
            : edgeBlur || edgeEffect === "blur" || edgeEffectProp != null
        ),
      [edgeBlur, edgeEffect, edgeEffectProp]
    );
    const scrollbarConfig = useMemo(() => normalizeScrollbar(scrollbar), [scrollbar]);
    const normalizedScrollbarHideDelay = Number.isFinite(scrollbarHideDelay)
      ? Math.max(0, scrollbarHideDelay)
      : 500;
    const blurLayers = useMemo(
      () => createBlurLayers(blurRenderConfig),
      [blurRenderConfig]
    );
    const renderEdgeBlur = blurRenderConfig.enabled && blurLayers.length > 0;
    const {
      onWheel: viewportOnWheel,
      style: viewportStyle,
      tabIndex: viewportTabIndex,
      ...viewportRestProps
    } = viewportProps ?? {};

    // The scrollbars are what this state shows, so they carry it. On the root
    // it keyed a rule over `.comma-scroll-area__scrollbar`, and every reveal and
    // hide restyled the scrollbar of each area nested inside: all the code
    // blocks and tables of a transcript, twice per wheel.
    const setScrolling = useCallback((scrolling: boolean) => {
      for (const ownScrollbar of [
        verticalScrollbarRef.current,
        horizontalScrollbarRef.current,
      ]) {
        if (ownScrollbar) {
          setDatasetBoolean(ownScrollbar, "scrolling", scrolling);
        }
      }
    }, []);

    const clearScrollingState = useCallback(() => {
      setScrolling(false);

      if (scrollEndTimeoutRef.current !== null && typeof window !== "undefined") {
        window.clearTimeout(scrollEndTimeoutRef.current);
        scrollEndTimeoutRef.current = null;
      }
    }, [setScrolling]);

    /**
     * An area's first edge state is not a change. A measurement reads layout
     * before it writes, which resolves the fade at its registered 0px, so the
     * first sizes eased in over the whole edge duration, after the content was
     * already on screen. The edge transitions arm only when a state has held
     * for two frames: an owner that opens away from the start (a transcript at
     * its tail) positions itself within the first frames, and each such step
     * restarts the wait. An area that loses its overflow starts over.
     */
    const syncEdgeTransition = useCallback((edgeState: string | null) => {
      const transition = edgeTransitionRef.current;
      const apply = () => {
        for (const element of [
          viewportRef.current,
          edgeBlurStartRef.current,
          edgeBlurEndRef.current,
        ]) {
          if (element) setDatasetBoolean(element, "edgeTransition", transition.armed);
        }
      };
      if (edgeState !== null && (transition.armed || transition.state === edgeState)) {
        // Edge elements that mount later take the armed state with them.
        apply();
        return;
      }
      if (transition.frame !== null) {
        cancelMeasureFrame(transition.frame);
        transition.frame = null;
      }
      transition.armed = false;
      transition.state = edgeState;
      apply();
      if (edgeState === null) {
        return;
      }
      transition.frame = requestMeasureFrame(() => {
        transition.frame = requestMeasureFrame(() => {
          transition.frame = null;
          transition.armed = true;
          apply();
        });
      });
    }, []);

    const updateMetrics = useCallback(() => {
      const root = rootRef.current;
      const viewport = viewportRef.current;

      if (!root || !viewport) {
        return;
      }

      const supportsX = canScrollAxis(orientation, "horizontal");
      const supportsY = canScrollAxis(orientation, "vertical");
      // Read every layout-dependent value before mutating datasets or inline
      // styles. Interleaving these reads with writes forces synchronous layout
      // repeatedly when wrapping content changes its scroll height during a
      // window resize.
      const viewportClientWidth = viewport.clientWidth;
      const viewportClientHeight = viewport.clientHeight;
      const viewportScrollWidth = viewport.scrollWidth;
      const viewportScrollHeight = viewport.scrollHeight;
      const viewportScrollLeft = viewport.scrollLeft;
      const viewportScrollTop = viewport.scrollTop;
      const content = contentRef.current;
      const contentScrollSize = content
        ? orientation === "horizontal"
          ? content.scrollWidth
          : content.scrollHeight
        : null;
      const maxScrollX = Math.max(0, viewportScrollWidth - viewportClientWidth);
      const maxScrollY = Math.max(0, viewportScrollHeight - viewportClientHeight);
      const hasOverflowX = supportsX && maxScrollX > 1;
      const hasOverflowY = supportsY && maxScrollY > 1;
      if (!hasOverflowX && !hasOverflowY) {
        clearScrollingState();
      }
      const edgeMaxScroll = edgeAxis === "vertical" ? maxScrollY : maxScrollX;
      const edgeScrollPosition =
        edgeAxis === "vertical" ? viewportScrollTop : viewportScrollLeft;
      const edgeHasOverflow = edgeAxis === "vertical" ? hasOverflowY : hasOverflowX;
      const startThreshold = Math.max(
        maskConfig.startThreshold,
        blurConfig.startThreshold
      );
      const endThreshold = Math.max(maskConfig.endThreshold, blurConfig.endThreshold);
      const isAtEdgeStart = !edgeHasOverflow || edgeScrollPosition <= startThreshold;
      const isAtEdgeEnd =
        !edgeHasOverflow || edgeScrollPosition >= edgeMaxScroll - endThreshold;

      onMetricsChangeRef.current?.({
        clientHeight: viewportClientHeight,
        maxScrollTop: maxScrollY,
        scrollHeight: viewportScrollHeight,
        scrollTop: viewportScrollTop,
      });

      // Resize consumers read transcript geometry and may restore its scroll
      // position. Notify them while this measurement's layout is still clean,
      // before scrollbar and edge writes invalidate descendant styles.
      if (viewportBlockSizeRef.current !== viewportClientHeight) {
        viewportBlockSizeRef.current = viewportClientHeight;
        onViewportResizeRef.current?.();
      }

      setDatasetBoolean(root, "hasOverflowX", hasOverflowX);
      setDatasetBoolean(root, "hasOverflowY", hasOverflowY);
      syncEdgeTransition(edgeHasOverflow ? `${isAtEdgeStart}|${isAtEdgeEnd}` : null);
      setEdgeVisible(
        root,
        { element: edgeBlurStartRef.current, enabled: blurConfig.enabled },
        "edgeStartVisible",
        edgeHasOverflow && !isAtEdgeStart
      );
      setEdgeVisible(
        root,
        { element: edgeBlurEndRef.current, enabled: blurConfig.enabled },
        "edgeEndVisible",
        edgeHasOverflow && !isAtEdgeEnd
      );
      setDatasetBoolean(root, "scrollXStart", !hasOverflowX || viewportScrollLeft <= 1);
      setDatasetBoolean(
        root,
        "scrollXEnd",
        !hasOverflowX || viewportScrollLeft >= maxScrollX - 1
      );
      setDatasetBoolean(root, "scrollYStart", !hasOverflowY || viewportScrollTop <= 1);
      setDatasetBoolean(
        root,
        "scrollYEnd",
        !hasOverflowY || viewportScrollTop >= maxScrollY - 1
      );

      const trackInset = scrollbarConfig.inset;
      const verticalTrackLength = Math.max(0, viewportClientHeight - trackInset * 2);
      const horizontalTrackLength = Math.max(0, viewportClientWidth - trackInset * 2);
      const verticalThumbSize = hasOverflowY
        ? clamp(
            (viewportClientHeight / viewportScrollHeight) * verticalTrackLength,
            Math.min(scrollbarConfig.minThumbSize, verticalTrackLength),
            verticalTrackLength
          )
        : 0;
      const horizontalThumbSize = hasOverflowX
        ? clamp(
            (viewportClientWidth / viewportScrollWidth) * horizontalTrackLength,
            Math.min(scrollbarConfig.minThumbSize, horizontalTrackLength),
            horizontalTrackLength
          )
        : 0;
      const verticalThumbOffset =
        hasOverflowY && maxScrollY > 0
          ? (viewportScrollTop / maxScrollY) *
            Math.max(0, verticalTrackLength - verticalThumbSize)
          : 0;
      const horizontalThumbOffset =
        hasOverflowX && maxScrollX > 0
          ? (viewportScrollLeft / maxScrollX) *
            Math.max(0, horizontalTrackLength - horizontalThumbSize)
          : 0;

      // These dimensions belong to the thumb. An inherited variable on the
      // root invalidates the document subtree whenever animated content grows.
      const verticalThumb = verticalThumbRef.current;
      if (verticalThumb) {
        setStyleProperty(verticalThumb, "height", px(verticalThumbSize));
        setStyleProperty(
          verticalThumb,
          "transform",
          `translate3d(0, ${px(verticalThumbOffset)}, 0)`
        );
      }
      const horizontalThumb = horizontalThumbRef.current;
      if (horizontalThumb) {
        setStyleProperty(horizontalThumb, "width", px(horizontalThumbSize));
        setStyleProperty(
          horizontalThumb,
          "transform",
          `translate3d(${px(horizontalThumbOffset)}, 0, 0)`
        );
      }
      // The viewport's size is never published as a custom property: on the
      // root it would inherit into the whole scrolled subtree and restyle every
      // descendant each time the viewport's height steps. Content that sizes
      // against the scrollport makes the viewport a size container instead.
      setStyleProperty(
        viewport,
        "--scroll-area-edge-mask-start",
        px(maskConfig.enabled && !isAtEdgeStart ? maskConfig.startSize : 0)
      );
      setStyleProperty(
        viewport,
        "--scroll-area-edge-mask-end",
        px(maskConfig.enabled && !isAtEdgeEnd ? maskConfig.endSize : 0)
      );

      viewportInlineSizeRef.current = viewportClientWidth;
      viewportScrollSizeRef.current = viewportScrollHeight;
      syncWheelMappingRef.current?.(hasOverflowX);

      if (contentScrollSize !== null) {
        contentScrollSizeRef.current = contentScrollSize;
      }
    }, [
      blurConfig.enabled,
      blurConfig.endThreshold,
      blurConfig.startThreshold,
      clearScrollingState,
      edgeAxis,
      maskConfig.enabled,
      maskConfig.endSize,
      maskConfig.endThreshold,
      maskConfig.startSize,
      maskConfig.startThreshold,
      orientation,
      scrollbarConfig.inset,
      scrollbarConfig.minThumbSize,
      syncEdgeTransition,
    ]);

    const scheduleMeasure = useCallback(
      (measureMetrics = true) => {
        if (measureMetrics) {
          metricsMeasurePendingRef.current = true;
        }
        if (measureFrameRef.current !== null) {
          return;
        }

        measureFrameRef.current = requestMeasureFrame(() => {
          measureFrameRef.current = null;
          const measurePendingMetrics = metricsMeasurePendingRef.current;
          metricsMeasurePendingRef.current = false;
          const notifyViewportResize = pendingViewportResizeRef.current;
          pendingViewportResizeRef.current = false;
          const previousBlockSize = viewportBlockSizeRef.current;
          if (measurePendingMetrics) {
            updateMetrics();
          }
          if (
            notifyViewportResize &&
            viewportBlockSizeRef.current === previousBlockSize
          ) {
            onViewportResizeRef.current?.();
          }
        });
      },
      [updateMetrics]
    );

    const scheduleViewportMeasure = useCallback(() => {
      if (orientation === "vertical" && windowResizingRef.current) {
        pendingViewportResizeRef.current = true;
        metricsMeasurePendingRef.current = true;
        return;
      }

      pendingViewportResizeRef.current = true;
      const viewport = viewportRef.current;
      const requiresMetrics =
        orientation !== "vertical" ||
        !viewport ||
        viewport.clientHeight !== viewportBlockSizeRef.current ||
        viewport.scrollHeight !== viewportScrollSizeRef.current;
      scheduleMeasure(requiresMetrics);
    }, [orientation, scheduleMeasure]);

    const scheduleContentMeasure = useCallback(() => {
      if (orientation === "vertical" && windowResizingRef.current) {
        metricsMeasurePendingRef.current = true;
        return;
      }

      const content = contentRef.current;
      if (!content || orientation === "both") {
        scheduleMeasure();
        return;
      }

      const scrollSize =
        orientation === "horizontal" ? content.scrollWidth : content.scrollHeight;
      if (contentScrollSizeRef.current === scrollSize) {
        return;
      }

      contentScrollSizeRef.current = scrollSize;
      scheduleMeasure();
    }, [orientation, scheduleMeasure]);

    const markScrolling = useCallback(() => {
      const viewport = viewportRef.current;

      if (!viewport || scrollbarVisibility !== "scroll") {
        return;
      }

      const hasOverflowX =
        canScrollAxis(orientation, "horizontal") &&
        viewport.scrollWidth - viewport.clientWidth > 1;
      const hasOverflowY =
        canScrollAxis(orientation, "vertical") &&
        viewport.scrollHeight - viewport.clientHeight > 1;

      if (!hasOverflowX && !hasOverflowY) {
        clearScrollingState();
        return;
      }

      setScrolling(true);

      if (scrollEndTimeoutRef.current !== null) {
        window.clearTimeout(scrollEndTimeoutRef.current);
      }

      scrollEndTimeoutRef.current = window.setTimeout(() => {
        scrollEndTimeoutRef.current = null;
        setScrolling(false);
      }, normalizedScrollbarHideDelay);
    }, [
      clearScrollingState,
      normalizedScrollbarHideDelay,
      orientation,
      scrollbarVisibility,
      setScrolling,
    ]);

    const handleScroll = useCallback<UIEventHandler<HTMLDivElement>>(
      (event) => {
        scheduleMeasure();
        // The browser scrolls a wheel itself, so an `interaction` reveal joins
        // the wheel to the scroll it caused: a scroll with no wheel just before
        // it is the application's, and stays hidden.
        if (
          scrollbarRevealSource === "all" ||
          performance.now() - lastWheelInputAtRef.current <= WHEEL_SCROLL_WINDOW_MS
        ) {
          markScrolling();
        }
        onScroll?.(event);
      },
      [markScrolling, onScroll, scheduleMeasure, scrollbarRevealSource]
    );

    const handleViewportWheel = useCallback<WheelEventHandler<HTMLDivElement>>(
      (event) => {
        if (scrollbarRevealSource === "interaction") {
          lastWheelInputAtRef.current = performance.now();
        }
        viewportOnWheel?.(event);
      },
      [scrollbarRevealSource, viewportOnWheel]
    );

    // The one wheel the browser cannot route: an ordinary mouse has no
    // horizontal wheel, so over a horizontal area its vertical wheel scrolls
    // sideways. Everything else — every vertical area, and a horizontal
    // gesture over this one — is scrolled natively, on the compositor, where a
    // busy main thread cannot stall it.
    const handleHorizontalWheel = useCallback(
      (event: WheelEvent) => {
        const viewport = viewportRef.current;
        if (event.defaultPrevented || !viewport) {
          return;
        }

        const deltaX = normalizeWheelDelta(
          event.deltaX,
          event.deltaMode,
          viewport.clientWidth
        );
        const deltaY = normalizeWheelDelta(
          event.deltaY,
          event.deltaMode,
          viewport.clientHeight
        );
        if (Math.abs(deltaX) > Math.abs(deltaY)) {
          return;
        }
        // A vertical wheel that started inside a nested area belongs to that
        // area's axis, even once it has reached its end: it is never
        // reinterpreted here as a sideways scroll.
        const sourceViewport =
          event.target instanceof Element
            ? event.target.closest(VIEWPORT_SELECTOR)
            : null;
        if (sourceViewport !== null && sourceViewport !== viewport) {
          return;
        }

        const previousScrollLeft = viewport.scrollLeft;
        const maxScrollLeft = Math.max(0, viewport.scrollWidth - viewport.clientWidth);
        const nextScrollLeft = clamp(previousScrollLeft + deltaY, 0, maxScrollLeft);
        // At its end the wheel is left alone, so it chains to the vertical
        // area around this one like any other vertical wheel. The widths are
        // rounded while scrollLeft is not: the browser can rest up to a pixel
        // short of that rounded end (114.5 of 115) and never reach it.
        if (
          nextScrollLeft === previousScrollLeft ||
          (deltaY > 0 && previousScrollLeft >= maxScrollLeft - 1)
        ) {
          return;
        }

        viewport.scrollLeft = nextScrollLeft;
        event.preventDefault();
        scheduleMeasure();
        markScrolling();
      },
      [markScrolling, scheduleMeasure]
    );

    // A wheel listener that may cancel makes the browser hold every wheel over
    // the element until the main thread answers. Only an area with something to
    // scroll sideways carries one, so a wheel over a code block or table that
    // fits stays on the compositor.
    const syncWheelMapping = useCallback(
      (hasOverflowX: boolean) => {
        const viewport = viewportRef.current;
        const attached = wheelMappingRef.current;
        const needed =
          orientation === "horizontal" && hasOverflowX && viewport !== null;
        if (
          needed &&
          attached?.viewport === viewport &&
          attached.handler === handleHorizontalWheel
        ) {
          return;
        }
        if (attached) {
          attached.viewport.removeEventListener("wheel", attached.handler);
          wheelMappingRef.current = null;
        }
        if (needed) {
          viewport.addEventListener("wheel", handleHorizontalWheel, { passive: false });
          wheelMappingRef.current = { handler: handleHorizontalWheel, viewport };
        }
      },
      [handleHorizontalWheel, orientation]
    );

    const beginScrollbarDrag = useCallback(
      (axis: ScrollAreaEdgeAxis, event: ReactPointerEvent<HTMLDivElement>) => {
        if (event.button !== 0) {
          return;
        }

        const root = rootRef.current;
        const viewport = viewportRef.current;

        if (!root || !viewport) {
          return;
        }

        const hasOverflow =
          axis === "vertical"
            ? root.dataset.hasOverflowY === "true"
            : root.dataset.hasOverflowX === "true";

        if (!hasOverflow) {
          return;
        }

        event.preventDefault();

        const track = event.currentTarget;
        const trackRect = track.getBoundingClientRect();
        const pointerStart = axis === "vertical" ? event.clientY : event.clientX;
        const trackStart = axis === "vertical" ? trackRect.top : trackRect.left;
        const trackLength = axis === "vertical" ? trackRect.height : trackRect.width;
        const thumbSize = Number.parseFloat(
          axis === "vertical"
            ? (verticalThumbRef.current?.style.height ?? "")
            : (horizontalThumbRef.current?.style.width ?? "")
        );
        const safeThumbSize = Number.isFinite(thumbSize)
          ? thumbSize
          : scrollbarConfig.minThumbSize;
        const maxScroll =
          axis === "vertical"
            ? viewport.scrollHeight - viewport.clientHeight
            : viewport.scrollWidth - viewport.clientWidth;
        const maxThumbOffset = Math.max(1, trackLength - safeThumbSize);
        const target = event.target as HTMLElement | null;
        const isThumb = Boolean(target?.closest('[data-slot="scroll-area-thumb"]'));

        let scrollStart =
          axis === "vertical" ? viewport.scrollTop : viewport.scrollLeft;
        let adjustedPointerStart = pointerStart;

        if (!isThumb) {
          const nextThumbOffset = clamp(
            pointerStart - trackStart - safeThumbSize / 2,
            0,
            maxThumbOffset
          );
          scrollStart = (nextThumbOffset / maxThumbOffset) * maxScroll;
          adjustedPointerStart = pointerStart;

          if (axis === "vertical") {
            viewport.scrollTop = scrollStart;
          } else {
            viewport.scrollLeft = scrollStart;
          }

          scheduleMeasure();
        }

        setDatasetBoolean(root, "dragging", true);

        const handlePointerMove = (pointerEvent: PointerEvent) => {
          const pointer =
            axis === "vertical" ? pointerEvent.clientY : pointerEvent.clientX;
          const delta = pointer - adjustedPointerStart;
          const nextScroll = clamp(
            scrollStart + (delta / maxThumbOffset) * maxScroll,
            0,
            maxScroll
          );

          if (axis === "vertical") {
            viewport.scrollTop = nextScroll;
          } else {
            viewport.scrollLeft = nextScroll;
          }

          scheduleMeasure();
          markScrolling();
        };

        const finishDrag = () => {
          setDatasetBoolean(root, "dragging", false);
          window.removeEventListener("pointermove", handlePointerMove);
          window.removeEventListener("pointerup", finishDrag);
          window.removeEventListener("pointercancel", finishDrag);
          dragCleanupRef.current = null;
        };

        dragCleanupRef.current?.();
        dragCleanupRef.current = finishDrag;
        window.addEventListener("pointermove", handlePointerMove);
        window.addEventListener("pointerup", finishDrag);
        window.addEventListener("pointercancel", finishDrag);
      },
      [markScrolling, scheduleMeasure, scrollbarConfig.minThumbSize]
    );

    // Sideways overflow can change with no box resizing for an observer to
    // report: highlighted code replaces its fallback inside a `pre` of the
    // same size. The answer only matters under a pointer, for the hover
    // scrollbar and the wheel mapping, so that is when it is read again.
    const handlePointerEnter = useCallback(
      (event: ReactPointerEvent<HTMLDivElement>) => {
        if (orientation !== "vertical") {
          scheduleMeasure();
        }
        onPointerEnter?.(event);
      },
      [onPointerEnter, orientation, scheduleMeasure]
    );

    useImperativeHandle(forwardedRef, () => viewportRef.current as HTMLDivElement);

    // Edge elements that mount later take the current edge state with them.
    useIsomorphicLayoutEffect(() => {
      updateMetrics();
    }, [renderEdgeBlur, updateMetrics]);

    useEffect(() => {
      scheduleMeasure();
      const transition = edgeTransitionRef.current;

      return () => {
        if (measureFrameRef.current !== null) {
          cancelMeasureFrame(measureFrameRef.current);
          measureFrameRef.current = null;
        }
        metricsMeasurePendingRef.current = false;
        pendingViewportResizeRef.current = false;
        // This cleanup also runs when the measure callback changes identity.
        // Forget the waiting state so the next measurement restarts the wait.
        if (transition.frame !== null) {
          cancelMeasureFrame(transition.frame);
          transition.frame = null;
          transition.state = null;
        }
      };
    }, [scheduleMeasure]);

    const hasViewportResizeCallback = Boolean(onViewportResize);

    useEffect(() => {
      if (!observeResize && !hasViewportResizeCallback) {
        return undefined;
      }

      const viewport = viewportRef.current;
      const content = contentRef.current;

      if (!viewport) {
        return undefined;
      }

      const cleanupViewport = observeElementResize(viewport, scheduleViewportMeasure);
      const cleanupContent =
        observeResize && content
          ? observeElementResize(content, scheduleContentMeasure)
          : undefined;

      return () => {
        cleanupViewport?.();
        cleanupContent?.();
      };
    }, [
      hasViewportResizeCallback,
      observeResize,
      scheduleMeasure,
      scheduleContentMeasure,
      scheduleViewportMeasure,
    ]);

    const onContentResizeRef = useRef(onContentResize);
    useIsomorphicLayoutEffect(() => {
      onContentResizeRef.current = onContentResize;
    });
    const hasContentResizeCallback = Boolean(onContentResize);
    const notifyContentResize = useCallback(() => {
      if (orientation === "vertical" && windowResizingRef.current) {
        pendingContentResizeNotificationRef.current = true;
        return;
      }
      onContentResizeRef.current?.();
    }, [orientation]);

    useEffect(() => {
      if (!hasContentResizeCallback) {
        return undefined;
      }

      const content = contentRef.current;
      if (!content) {
        return undefined;
      }

      return observeElementResize(content, notifyContentResize);
    }, [hasContentResizeCallback, notifyContentResize]);

    useEffect(() => {
      if (
        !hasContentResizeCallback ||
        !contentResizeTarget ||
        contentResizeTarget === contentRef.current
      ) {
        return undefined;
      }

      return observeElementResize(contentResizeTarget, notifyContentResize);
    }, [contentResizeTarget, hasContentResizeCallback, notifyContentResize]);

    useEffect(() => {
      if (
        typeof window === "undefined" ||
        (typeof globalThis.ResizeObserver !== "undefined" &&
          (observeResize || hasViewportResizeCallback))
      ) {
        return undefined;
      }

      window.addEventListener("resize", scheduleViewportMeasure);

      return () => {
        window.removeEventListener("resize", scheduleViewportMeasure);
      };
    }, [hasViewportResizeCallback, observeResize, scheduleViewportMeasure]);

    useEffect(() => {
      if (
        typeof window === "undefined" ||
        (orientation !== "vertical" && !maskConfig.enabled)
      ) {
        return undefined;
      }
      const mountedRoot = rootRef.current;

      const handleWindowResize = () => {
        const startingResize = !windowResizingRef.current;
        windowResizingRef.current = true;
        const root = rootRef.current;
        const viewport = viewportRef.current;
        if (startingResize && freezeContentInlineSizeOnWindowResize && root) {
          const inlineSize =
            viewportInlineSizeRef.current || viewport?.clientWidth || 0;
          if (inlineSize > 0) {
            setStyleProperty(
              root,
              "--scroll-area-resize-content-inline-size",
              px(inlineSize)
            );
            setDatasetBoolean(root, "freezeContentInlineSize", true);
          }
        }
        if (root && maskConfig.enabled) {
          setDatasetBoolean(root, "windowResizing", true);
        }

        if (windowResizeEndTimeoutRef.current !== null) {
          window.clearTimeout(windowResizeEndTimeoutRef.current);
        }
        windowResizeEndTimeoutRef.current = window.setTimeout(() => {
          windowResizeEndTimeoutRef.current = null;
          windowResizingRef.current = false;
          const currentRoot = rootRef.current;
          if (currentRoot && maskConfig.enabled) {
            setDatasetBoolean(currentRoot, "windowResizing", false);
          }
          if (currentRoot && freezeContentInlineSizeOnWindowResize) {
            setDatasetBoolean(currentRoot, "freezeContentInlineSize", false);
            currentRoot.style.removeProperty(
              "--scroll-area-resize-content-inline-size"
            );
          }
          scheduleViewportMeasure();
          if (pendingContentResizeNotificationRef.current) {
            pendingContentResizeNotificationRef.current = false;
            onContentResizeRef.current?.();
          }
        }, 120);
      };

      window.addEventListener("resize", handleWindowResize);
      return () => {
        window.removeEventListener("resize", handleWindowResize);
        windowResizingRef.current = false;
        pendingContentResizeNotificationRef.current = false;
        if (mountedRoot && maskConfig.enabled) {
          setDatasetBoolean(mountedRoot, "windowResizing", false);
        }
        if (mountedRoot && freezeContentInlineSizeOnWindowResize) {
          setDatasetBoolean(mountedRoot, "freezeContentInlineSize", false);
          mountedRoot.style.removeProperty("--scroll-area-resize-content-inline-size");
        }
        if (windowResizeEndTimeoutRef.current !== null) {
          window.clearTimeout(windowResizeEndTimeoutRef.current);
          windowResizeEndTimeoutRef.current = null;
        }
      };
    }, [
      freezeContentInlineSizeOnWindowResize,
      maskConfig.enabled,
      orientation,
      scheduleViewportMeasure,
    ]);

    useEffect(() => {
      syncWheelMappingRef.current = syncWheelMapping;
      syncWheelMapping(rootRef.current?.dataset.hasOverflowX === "true");

      return () => {
        syncWheelMappingRef.current = null;
        syncWheelMapping(false);
      };
    }, [syncWheelMapping]);

    useEffect(() => {
      if (scrollbarRevealSource !== "interaction") {
        return undefined;
      }

      const viewport = viewportRef.current;
      if (!viewport) {
        return undefined;
      }

      const handleKeyDown = (event: KeyboardEvent) => {
        if (!event.defaultPrevented && isDirectScrollKey(event)) {
          markScrolling();
        }
      };
      const handleTouchMove = (event: TouchEvent) => {
        if (!event.defaultPrevented) {
          markScrolling();
        }
      };

      viewport.addEventListener("keydown", handleKeyDown);
      viewport.addEventListener("touchmove", handleTouchMove, { passive: true });

      return () => {
        viewport.removeEventListener("keydown", handleKeyDown);
        viewport.removeEventListener("touchmove", handleTouchMove);
      };
    }, [markScrolling, scrollbarRevealSource]);

    useEffect(() => {
      if (scrollbarVisibility !== "scroll") {
        clearScrollingState();
      }
    }, [clearScrollingState, scrollbarVisibility]);

    useEffect(() => {
      return () => {
        dragCleanupRef.current?.();

        if (scrollEndTimeoutRef.current !== null && typeof window !== "undefined") {
          window.clearTimeout(scrollEndTimeoutRef.current);
        }

        if (
          windowResizeEndTimeoutRef.current !== null &&
          typeof window !== "undefined"
        ) {
          window.clearTimeout(windowResizeEndTimeoutRef.current);
        }
      };
    }, []);

    const rootStyle = {
      ...style,
      "--scroll-area-scrollbar-size": px(scrollbarConfig.size),
      "--scroll-area-scrollbar-inset": px(scrollbarConfig.inset),
      "--scroll-area-edge-blur-target-start-size": px(blurRenderConfig.startSize),
      "--scroll-area-edge-blur-target-end-size": px(blurRenderConfig.endSize),
      "--scroll-area-edge-transition-duration": `${Math.max(
        0,
        edgeTransitionDuration
      )}ms`,
      "--scroll-area-edge-transition-easing": edgeTransitionEasing,
    } as StyleWithVars;

    const showVerticalScrollbar =
      scrollbarConfig.enabled && canScrollAxis(orientation, "vertical");
    const showHorizontalScrollbar =
      scrollbarConfig.enabled && canScrollAxis(orientation, "horizontal");
    return (
      <div
        {...rootProps}
        ref={rootRef}
        className={cx("comma-scroll-area", className)}
        data-slot="scroll-area"
        data-orientation={orientation}
        data-edge-axis={edgeAxis}
        data-edge-effect={edgeEffect}
        data-edge-mask={maskConfig.enabled ? "true" : "false"}
        data-edge-blur={blurConfig.enabled ? "true" : "false"}
        data-scrollbar-visibility={scrollbarVisibility}
        data-scrollbar-reveal-source={scrollbarRevealSource}
        data-scrollbar-hover-reveal={scrollbarHoverReveal ? "true" : "false"}
        onPointerEnter={handlePointerEnter}
        style={rootStyle}
      >
        <div
          {...viewportRestProps}
          ref={viewportRef}
          className={cx("comma-scroll-area__viewport", viewportClassName)}
          data-slot="scroll-area-viewport"
          onScroll={handleScroll}
          onWheel={handleViewportWheel}
          style={viewportStyle}
          tabIndex={viewportTabIndex ?? 0}
        >
          <div
            ref={contentRef}
            className={cx("comma-scroll-area__content", contentClassName)}
            data-slot="scroll-area-content"
            style={contentStyle}
          >
            {children}
          </div>
        </div>

        {renderEdgeBlur && (
          <>
            <div
              aria-hidden
              className="comma-scroll-area__edge-blur comma-scroll-area__edge-blur--start"
              data-axis={edgeAxis}
              data-edge="start"
              data-slot="scroll-area-edge-blur-start"
              ref={edgeBlurStartRef}
            >
              {blurLayers.map((layer, index) => (
                <div
                  className="comma-scroll-area__edge-blur-layer"
                  key={`start-${index}`}
                  style={
                    {
                      "--scroll-area-edge-blur-layer-blur": `${layer.blur}px`,
                      maskImage: `linear-gradient(${getBlurDirection(
                        edgeAxis,
                        "start"
                      )}, black 0%, black ${layer.stop}%, transparent 100%)`,
                      WebkitMaskImage: `linear-gradient(${getBlurDirection(
                        edgeAxis,
                        "start"
                      )}, black 0%, black ${layer.stop}%, transparent 100%)`,
                    } as StyleWithVars
                  }
                />
              ))}
            </div>
            <div
              aria-hidden
              className="comma-scroll-area__edge-blur comma-scroll-area__edge-blur--end"
              data-axis={edgeAxis}
              data-edge="end"
              data-slot="scroll-area-edge-blur-end"
              ref={edgeBlurEndRef}
            >
              {blurLayers.map((layer, index) => (
                <div
                  className="comma-scroll-area__edge-blur-layer"
                  key={`end-${index}`}
                  style={
                    {
                      "--scroll-area-edge-blur-layer-blur": `${layer.blur}px`,
                      maskImage: `linear-gradient(${getBlurDirection(
                        edgeAxis,
                        "end"
                      )}, black 0%, black ${layer.stop}%, transparent 100%)`,
                      WebkitMaskImage: `linear-gradient(${getBlurDirection(
                        edgeAxis,
                        "end"
                      )}, black 0%, black ${layer.stop}%, transparent 100%)`,
                    } as StyleWithVars
                  }
                />
              ))}
            </div>
          </>
        )}

        {showVerticalScrollbar && (
          <div
            aria-hidden
            className="comma-scroll-area__scrollbar comma-scroll-area__scrollbar--vertical"
            data-axis="vertical"
            data-slot="scroll-area-scrollbar"
            onPointerDown={(event) => beginScrollbarDrag("vertical", event)}
            ref={verticalScrollbarRef}
          >
            <div
              ref={verticalThumbRef}
              className="comma-scroll-area__thumb comma-scroll-area__thumb--vertical"
              data-slot="scroll-area-thumb"
            />
          </div>
        )}
        {showHorizontalScrollbar && (
          <div
            aria-hidden
            className="comma-scroll-area__scrollbar comma-scroll-area__scrollbar--horizontal"
            data-axis="horizontal"
            data-slot="scroll-area-scrollbar"
            onPointerDown={(event) => beginScrollbarDrag("horizontal", event)}
            ref={horizontalScrollbarRef}
          >
            <div
              ref={horizontalThumbRef}
              className="comma-scroll-area__thumb comma-scroll-area__thumb--horizontal"
              data-slot="scroll-area-thumb"
            />
          </div>
        )}
      </div>
    );
  }
);

ScrollArea.displayName = "ScrollArea";
