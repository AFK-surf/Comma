import { IconAlignmentCenter as CentralAlignmentCenterIcon } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconAlignmentCenter";
import { IconArrowsAllSides as CentralArrowsAllSidesIcon } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconArrowsAllSides";
import { IconLock as CentralLockIcon } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconLock";
import { IconUnlocked2 as CentralUnlockedIcon } from "@central-icons-react/round-outlined-radius-2-stroke-2/IconUnlocked2";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { cx } from "../../components/utils";
import {
  adaptRectToCanvas,
  applyMove,
  applyResize,
  centerRect,
  clampRectToCanvas,
  NO_GUIDES,
  snapRectToCenter,
  toRelativeRect,
  type CenterGuides,
  type Rect,
  type ResizeContainerMode,
  type ResizeEdges,
  type Size,
} from "./geometry";
import { createCentralIcon } from "../../components/icons/createCentralIcon";

const AlignmentCenterIcon = createCentralIcon(CentralAlignmentCenterIcon);
const ArrowsAllSidesIcon = createCentralIcon(CentralArrowsAllSidesIcon);
const LockIcon = createCentralIcon(CentralLockIcon);
const UnlockedIcon = createCentralIcon(CentralUnlockedIcon);

export type { ResizeContainerMode, Rect } from "./geometry";

export type ResizeContainerProps = {
  /** Initial content rect (in pixels relative to the canvas top-left). */
  defaultRect?: Partial<Rect>;
  /** Center the content within the canvas on first measure (ignores default x/y). */
  centered?: boolean;
  /** Controlled readout/resize mode. Falls back to internal state when omitted. */
  mode?: ResizeContainerMode;
  /** Initial mode when uncontrolled. */
  defaultMode?: ResizeContainerMode;
  onModeChange?: (mode: ResizeContainerMode) => void;
  /** Whether resize handles are visible on mount. Defaults to false. */
  defaultResizable?: boolean;
  /** Whether dragging the canvas moves the content on mount. Defaults to false. */
  defaultMovable?: boolean;
  /**
   * Whether center mode is on at mount. In center mode the content can't move,
   * stays centered, and resizes about the canvas center. Defaults to false.
   */
  defaultCenterMode?: boolean;
  /** Show + snap to center guide lines while dragging. Defaults to true. */
  centerGuides?: boolean;
  /** Snap distance in pixels for the center guides. */
  snapThreshold?: number;
  /** Smallest content size in pixels. */
  minWidth?: number;
  minHeight?: number;
  /**
   * Whether child overflow is clipped to the resizable content rect. Disable
   * this for visual overflow such as shadows and popovers. Defaults to true.
   */
  clipContent?: boolean;
  /** Notified whenever the content rect changes (pixel values). */
  onRectChange?: (rect: Rect, relative: Rect) => void;
  className?: string;
  children?: ReactNode;
};

type ActiveDrag =
  | { kind: "move"; pointerId: number; startX: number; startY: number; startRect: Rect }
  | {
      kind: "resize";
      pointerId: number;
      startX: number;
      startY: number;
      startRect: Rect;
      edges: ResizeEdges;
    };

type HandleConfig = {
  id: string;
  edges: ResizeEdges;
  className: string;
  cursor: string;
};

const NO_EDGES: ResizeEdges = { left: false, right: false, top: false, bottom: false };

/** Invisible full-length hit zones — each side resizes from anywhere along it. */
const EDGE_HANDLES: HandleConfig[] = [
  {
    id: "n",
    edges: { ...NO_EDGES, top: true },
    cursor: "ns-resize",
    className: "inset-x-0 top-0 h-2 -translate-y-1/2",
  },
  {
    id: "s",
    edges: { ...NO_EDGES, bottom: true },
    cursor: "ns-resize",
    className: "inset-x-0 bottom-0 h-2 translate-y-1/2",
  },
  {
    id: "w",
    edges: { ...NO_EDGES, left: true },
    cursor: "ew-resize",
    className: "inset-y-0 left-0 w-2",
  },
  {
    id: "e",
    edges: { ...NO_EDGES, right: true },
    cursor: "ew-resize",
    className: "inset-y-0 right-0 w-2",
  },
];

/** Visible square corner handles. */
const CORNER_HANDLES: HandleConfig[] = [
  {
    id: "nw",
    edges: { ...NO_EDGES, top: true, left: true },
    cursor: "nwse-resize",
    className: "left-0 top-0 -translate-x-1/2 -translate-y-1/2",
  },
  {
    id: "ne",
    edges: { ...NO_EDGES, top: true, right: true },
    cursor: "nesw-resize",
    className: "right-0 top-0 translate-x-1/2 -translate-y-1/2",
  },
  {
    id: "se",
    edges: { ...NO_EDGES, bottom: true, right: true },
    cursor: "nwse-resize",
    className: "right-0 bottom-0 translate-x-1/2 translate-y-1/2",
  },
  {
    id: "sw",
    edges: { ...NO_EDGES, bottom: true, left: true },
    cursor: "nesw-resize",
    className: "left-0 bottom-0 -translate-x-1/2 translate-y-1/2",
  },
];

const DEFAULT_RECT: Rect = { x: 120, y: 96, width: 520, height: 360 };

const formatPx = (value: number) => `${Math.round(value)}px`;
const formatPercent = (value: number) => `${(value * 100).toFixed(1)}%`;

/**
 * Dev-only transparent canvas that hosts a single content box you can drag and
 * resize. All controls and the live x/y/w/h readout live in a bottom bar; the
 * resize handles stay hidden until you unlock resizing.
 */
export const ResizeContainer = ({
  defaultRect,
  centered = false,
  mode: modeProp,
  defaultMode = "pixel",
  onModeChange,
  defaultResizable = false,
  defaultMovable = false,
  defaultCenterMode = false,
  centerGuides = true,
  snapThreshold = 6,
  minWidth = 80,
  minHeight = 60,
  clipContent = true,
  onRectChange,
  className,
  children,
}: ResizeContainerProps) => {
  const canvasRef = useRef<HTMLDivElement>(null);
  const prevCanvasRef = useRef<Size | null>(null);
  const dragRef = useRef<ActiveDrag | null>(null);
  const lastPointerRef = useRef<{ x: number; y: number }>({ x: 0, y: 0 });

  const [internalMode, setInternalMode] = useState<ResizeContainerMode>(defaultMode);
  const mode = modeProp ?? internalMode;
  const [resizable, setResizable] = useState(defaultResizable);
  const [movable, setMovable] = useState(defaultMovable);
  const [centerMode, setCenterMode] = useState(defaultCenterMode);
  const minSize: Size = { width: minWidth, height: minHeight };

  const [canvasSize, setCanvasSize] = useState<Size>({ width: 0, height: 0 });
  const [rect, setRect] = useState<Rect>(() => ({ ...DEFAULT_RECT, ...defaultRect }));
  const [guides, setGuides] = useState<CenterGuides>(NO_GUIDES);

  const modeRef = useRef(mode);
  modeRef.current = mode;
  const minSizeRef = useRef(minSize);
  minSizeRef.current = minSize;
  const centeredRef = useRef(centered);
  centeredRef.current = centered;
  const centerGuidesRef = useRef(centerGuides);
  centerGuidesRef.current = centerGuides;
  const snapThresholdRef = useRef(snapThreshold);
  snapThresholdRef.current = snapThreshold;
  const centerModeRef = useRef(centerMode);
  centerModeRef.current = centerMode;

  const setMode = useCallback(
    (next: ResizeContainerMode) => {
      if (modeProp === undefined) setInternalMode(next);
      onModeChange?.(next);
    },
    [modeProp, onModeChange]
  );

  const onRectChangeRef = useRef(onRectChange);
  onRectChangeRef.current = onRectChange;

  useEffect(() => {
    if (canvasSize.width > 0 && canvasSize.height > 0) {
      onRectChangeRef.current?.(rect, toRelativeRect(rect, canvasSize));
    }
  }, [rect, canvasSize]);

  useLayoutEffect(() => {
    const node = canvasRef.current;
    if (!node) return;

    const observer = new ResizeObserver((entries) => {
      const entry = entries[0];
      if (!entry) return;
      const next: Size = {
        width: entry.contentRect.width,
        height: entry.contentRect.height,
      };
      if (next.width <= 0 || next.height <= 0) return;

      const prev = prevCanvasRef.current;
      prevCanvasRef.current = next;
      setCanvasSize(next);
      setRect((current) => {
        const adapted = prev
          ? adaptRectToCanvas(current, prev, next, modeRef.current, minSizeRef.current)
          : clampRectToCanvas(
              centeredRef.current || centerModeRef.current
                ? centerRect(current, next)
                : current,
              next,
              minSizeRef.current
            );
        return centerModeRef.current ? centerRect(adapted, next) : adapted;
      });
    });

    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  // Re-center the content whenever center mode is enabled.
  useEffect(() => {
    const canvas = prevCanvasRef.current;
    if (!centerMode || !canvas) return;
    setRect((current) => centerRect(current, canvas));
  }, [centerMode]);

  // Recompute the rect from the latest pointer position and modifier state.
  // Shift locks the move axis; Alt/Option resizes from the center.
  // Reads only refs so it stays referentially stable across renders.
  const recompute = useCallback((modifiers: { shiftKey: boolean; altKey: boolean }) => {
    const drag = dragRef.current;
    const canvas = prevCanvasRef.current;
    if (!drag || !canvas) return;

    const dx = lastPointerRef.current.x - drag.startX;
    const dy = lastPointerRef.current.y - drag.startY;

    if (drag.kind === "move") {
      const moved = applyMove(drag.startRect, dx, dy, canvas, {
        lockAxis: modifiers.shiftKey,
      });
      if (centerGuidesRef.current) {
        const snapped = snapRectToCenter(moved, canvas, snapThresholdRef.current);
        setRect(snapped.rect);
        setGuides(snapped.guides);
      } else {
        setRect(moved);
      }
      return;
    }

    setRect(
      applyResize(drag.startRect, drag.edges, dx, dy, canvas, minSizeRef.current, {
        fromCenter: modifiers.altKey || centerModeRef.current,
      })
    );
    setGuides(NO_GUIDES);
  }, []);

  const cleanupDragRef = useRef<() => void>(() => {});

  const beginDrag = useCallback(
    (drag: ActiveDrag) => {
      cleanupDragRef.current();
      dragRef.current = drag;
      lastPointerRef.current = { x: drag.startX, y: drag.startY };

      const onPointerMove = (event: PointerEvent) => {
        if (!dragRef.current || event.pointerId !== dragRef.current.pointerId) return;
        lastPointerRef.current = { x: event.clientX, y: event.clientY };
        recompute({ shiftKey: event.shiftKey, altKey: event.altKey });
      };
      // Re-apply the modifier the moment Shift / Alt is pressed or released mid-drag.
      const onModifierKey = (event: KeyboardEvent) => {
        if (event.key !== "Shift" && event.key !== "Alt") return;
        recompute({ shiftKey: event.shiftKey, altKey: event.altKey });
      };
      const cleanup = () => {
        window.removeEventListener("pointermove", onPointerMove);
        window.removeEventListener("pointerup", onPointerUp);
        window.removeEventListener("pointercancel", onPointerUp);
        window.removeEventListener("keydown", onModifierKey);
        window.removeEventListener("keyup", onModifierKey);
        cleanupDragRef.current = () => {};
      };
      const onPointerUp = (event: PointerEvent) => {
        if (!dragRef.current || event.pointerId !== dragRef.current.pointerId) return;
        dragRef.current = null;
        setGuides(NO_GUIDES);
        cleanup();
      };

      cleanupDragRef.current = cleanup;
      window.addEventListener("pointermove", onPointerMove);
      window.addEventListener("pointerup", onPointerUp);
      window.addEventListener("pointercancel", onPointerUp);
      window.addEventListener("keydown", onModifierKey);
      window.addEventListener("keyup", onModifierKey);
    },
    [recompute]
  );

  useEffect(() => () => cleanupDragRef.current(), []);

  // Move is driven from the canvas background so the content stays interactive.
  const onCanvasPointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return;
    if (!movable || centerMode) return;
    if (event.target !== event.currentTarget) return;
    event.preventDefault();
    beginDrag({
      kind: "move",
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      startRect: rect,
    });
  };

  const onHandlePointerDown =
    (edges: ResizeEdges) => (event: ReactPointerEvent<HTMLDivElement>) => {
      if (event.button !== 0) return;
      event.preventDefault();
      event.stopPropagation();
      beginDrag({
        kind: "resize",
        pointerId: event.pointerId,
        startX: event.clientX,
        startY: event.clientY,
        startRect: rect,
        edges,
      });
    };

  const relative = toRelativeRect(rect, canvasSize);
  const readout: Array<{ label: string; value: string }> =
    mode === "pixel"
      ? [
          { label: "x", value: formatPx(rect.x) },
          { label: "y", value: formatPx(rect.y) },
          { label: "w", value: formatPx(rect.width) },
          { label: "h", value: formatPx(rect.height) },
        ]
      : [
          { label: "x", value: formatPercent(relative.x) },
          { label: "y", value: formatPercent(relative.y) },
          { label: "w", value: formatPercent(relative.width) },
          { label: "h", value: formatPercent(relative.height) },
        ];

  const contentStyle: CSSProperties = {
    transform: `translate(${rect.x}px, ${rect.y}px)`,
    width: rect.width,
    height: rect.height,
  };

  const canvasMovable = movable && !centerMode;

  return (
    <div
      className={cx(
        "relative h-screen w-full select-none overflow-hidden bg-transparent",
        canvasMovable && "cursor-grab",
        className
      )}
      data-slot="resize-canvas"
      onPointerDown={onCanvasPointerDown}
      ref={canvasRef}
    >
      <div
        className="absolute left-0 top-0 bg-primary"
        data-locked={!resizable}
        data-slot="resize-content"
        style={contentStyle}
      >
        <div
          className={cx(
            "relative size-full",
            clipContent ? "overflow-hidden" : "overflow-visible"
          )}
          data-slot="resize-viewport"
        >
          {children}
        </div>

        {resizable && (
          <>
            <div
              className="pointer-events-none absolute inset-0 z-10 border border-dashed border-brand-solid"
              data-slot="resize-outline"
            />
            {EDGE_HANDLES.map((handle) => (
              <div
                className={cx("absolute z-10 touch-none", handle.className)}
                data-handle={handle.id}
                key={handle.id}
                onPointerDown={onHandlePointerDown(handle.edges)}
                style={{ cursor: handle.cursor }}
              />
            ))}
            {CORNER_HANDLES.map((handle) => (
              <div
                className={cx(
                  "absolute z-20 size-2 touch-none rounded-[1px] border border-brand-solid bg-primary",
                  handle.className
                )}
                data-handle={handle.id}
                key={handle.id}
                onPointerDown={onHandlePointerDown(handle.edges)}
                style={{ cursor: handle.cursor }}
              />
            ))}
          </>
        )}
      </div>

      {guides.vertical && (
        <div
          className="pointer-events-none absolute inset-y-0 left-1/2 z-30 w-px -translate-x-1/2 bg-error-500"
          data-guide="vertical"
        />
      )}
      {guides.horizontal && (
        <div
          className="pointer-events-none absolute inset-x-0 top-1/2 z-30 h-px -translate-y-1/2 bg-error-500"
          data-guide="horizontal"
        />
      )}

      <ControlBar
        centerMode={centerMode}
        mode={mode}
        movable={movable}
        onModeChange={setMode}
        onToggleCenterMode={() => setCenterMode((value) => !value)}
        onToggleMovable={() => setMovable((value) => !value)}
        onToggleResizable={() => setResizable((value) => !value)}
        readout={readout}
        resizable={resizable}
      />
    </div>
  );
};

const ToggleButton = ({
  active,
  disabled,
  title,
  slot,
  onClick,
  children,
}: {
  active: boolean;
  disabled?: boolean;
  title: string;
  slot: string;
  onClick: () => void;
  children: ReactNode;
}) => (
  <button
    aria-pressed={active}
    className={cx(
      "inline-flex size-7 items-center justify-center rounded-lg transition-colors",
      "text-quaternary hover:bg-secondary hover:text-primary",
      active && "text-fg-brand-primary hover:text-fg-brand-primary",
      disabled &&
        "cursor-not-allowed opacity-40 hover:bg-transparent hover:text-quaternary"
    )}
    data-active={active}
    data-slot={slot}
    disabled={disabled}
    onClick={onClick}
    title={title}
    type="button"
  >
    {children}
  </button>
);

const ControlBar = ({
  mode,
  onModeChange,
  resizable,
  onToggleResizable,
  movable,
  onToggleMovable,
  centerMode,
  onToggleCenterMode,
  readout,
}: {
  mode: ResizeContainerMode;
  onModeChange: (mode: ResizeContainerMode) => void;
  resizable: boolean;
  onToggleResizable: () => void;
  movable: boolean;
  onToggleMovable: () => void;
  centerMode: boolean;
  onToggleCenterMode: () => void;
  readout: Array<{ label: string; value: string }>;
}) => (
  <div
    className="absolute bottom-4 left-4 z-20 flex items-center gap-md"
    data-slot="resize-control-bar"
  >
    <div className="flex items-center gap-xxs">
      <ToggleButton
        active={resizable}
        onClick={onToggleResizable}
        slot="resize-lock"
        title={resizable ? "缩放：开（点击锁定）" : "缩放：关"}
      >
        {resizable ? (
          <UnlockedIcon className="size-4" />
        ) : (
          <LockIcon className="size-4" />
        )}
      </ToggleButton>
      <ToggleButton
        active={movable && !centerMode}
        disabled={centerMode}
        onClick={onToggleMovable}
        slot="resize-move"
        title={
          centerMode
            ? "居中模式下不可移动"
            : movable
              ? "拖拽画布移动：开"
              : "拖拽画布移动：关"
        }
      >
        <ArrowsAllSidesIcon className="size-4" />
      </ToggleButton>
      <ToggleButton
        active={centerMode}
        onClick={onToggleCenterMode}
        slot="resize-center-mode"
        title={centerMode ? "居中模式：开" : "居中模式：关"}
      >
        <AlignmentCenterIcon className="size-4" />
      </ToggleButton>
    </div>

    <span className="h-5 w-px bg-border-secondary" />

    <div
      className="flex items-center gap-xxs rounded-lg bg-secondary p-xxs"
      data-slot="resize-mode-toggle"
    >
      {(["pixel", "relative"] as const).map((value) => (
        <button
          className={cx(
            "rounded-md px-md py-xs text-xs font-medium transition-colors",
            mode === value
              ? "bg-primary text-primary shadow-sm"
              : "text-quaternary hover:text-primary"
          )}
          data-active={mode === value}
          key={value}
          onClick={() => onModeChange(value)}
          type="button"
        >
          {value === "pixel" ? "固定像素" : "相对值"}
        </button>
      ))}
    </div>

    <span className="h-5 w-px bg-border-secondary" />

    <div
      className="flex items-center gap-md font-mono text-sm tabular-nums text-primary"
      data-slot="resize-readout"
    >
      {readout.map((item) => (
        <div className="flex items-center gap-xs" key={item.label}>
          <span className="text-quaternary">{item.label}</span>
          <span data-readout={item.label}>{item.value}</span>
        </div>
      ))}
    </div>

    {resizable && (
      <>
        <span className="h-5 w-px bg-border-secondary" />
        <span className="text-xs text-quaternary" data-slot="resize-shift-hint">
          <kbd className="rounded bg-secondary px-xs py-px font-mono">⌥ Option</kbd>
          缩放锁中心 ·{" "}
          <kbd className="rounded bg-secondary px-xs py-px font-mono">Shift</kbd>
          移动锁方向
        </span>
      </>
    )}
  </div>
);
