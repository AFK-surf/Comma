import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import {
  keepClearElementMoved,
  registerKeepClearElement,
} from "../keep-clear/keepClear";

/** One bounded UI position; pointer capture keeps release reliable outside the card. */
export function DraggableRecorder({
  children,
  placement = "bottom-left",
  label,
  containment,
}: {
  children: ReactNode;
  placement?: "bottom-left" | "top-center";
  label: string;
  containment?: HTMLElement | null | undefined;
}) {
  const root = useRef<HTMLDivElement>(null);
  const drag = useRef<
    { pointer: number; x: number; y: number; left: number; top: number } | undefined
  >(undefined);
  // Store the center so hover resizing grows equally on both sides, including
  // after a drag. Only the work-area clamp may shift that center near an edge.
  const [position, setPosition] = useState<{ x: number; y: number }>();
  const [dragging, setDragging] = useState(false);
  const positioning = useRef(false);
  const clamp = useCallback(
    (x: number, y: number) => {
      const bounds = root.current!.getBoundingClientRect();
      const area = containment?.getBoundingClientRect();
      return {
        x: Math.max(
          (area?.left ?? 0) + bounds.width / 2 + 8,
          Math.min(x, (area?.right ?? window.innerWidth) - bounds.width / 2 - 8)
        ),
        y: Math.max(
          (area?.top ?? 0) + bounds.height / 2 + 8,
          Math.min(y, (area?.bottom ?? window.innerHeight) - bounds.height / 2 - 8)
        ),
      };
    },
    [containment]
  );
  useLayoutEffect(() => {
    // Switching CSS anchors to center coordinates must not animate left/top.
    // Keep transitions disabled until React commits and flushes that position.
    root.current!.style.transition = "none";
    positioning.current = true;
    const bounds = root.current!.getBoundingClientRect();
    setPosition(clamp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2));
  }, [clamp]);
  useLayoutEffect(() => {
    if (!position || !positioning.current) return;
    root.current!.getBoundingClientRect();
    root.current!.style.removeProperty("transition");
    positioning.current = false;
  }, [position]);
  // Recording controls stay in view: a floating video moves off them.
  useLayoutEffect(() => registerKeepClearElement(root.current!), []);
  useLayoutEffect(() => {
    if (!dragging) keepClearElementMoved();
  }, [dragging, position]);
  useEffect(() => {
    const resize = () => {
      setPosition((current) => {
        if (!current || drag.current) return current;
        const next = clamp(current.x, current.y);
        return next.x === current.x && next.y === current.y ? current : next;
      });
      // Hover and phase change the card's size around the same centre.
      if (!drag.current) keepClearElementMoved();
    };
    window.addEventListener("resize", resize);
    // Exactly one card per surface. Clamp again when hover/phase changes its
    // dimensions, so expanding a compact card at the edge stays reachable.
    const observer =
      typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(resize);
    if (root.current) observer?.observe(root.current);
    if (containment) observer?.observe(containment);
    return () => {
      window.removeEventListener("resize", resize);
      observer?.disconnect();
    };
  }, [clamp, containment]);
  const finish = () => {
    drag.current = undefined;
    setDragging(false);
    const bounds = root.current!.getBoundingClientRect();
    setPosition(clamp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2));
  };
  return (
    <div
      ref={root}
      className="comma-draggable-recorder"
      data-placement={placement}
      data-contained={containment ? true : undefined}
      data-dragging={dragging || undefined}
      data-recorder-interactive
      aria-label={label}
      style={
        position
          ? {
              left: position.x,
              top: position.y,
              bottom: "auto",
              transform: "translate(-50%, -50%)",
            }
          : undefined
      }
      onPointerDown={(event) => {
        if (
          event.button !== 0 ||
          !(event.target instanceof Element) ||
          event.target.closest("button, [role=menu], a, input")
        )
          return;
        event.preventDefault();
        const bounds = event.currentTarget.getBoundingClientRect();
        drag.current = {
          pointer: event.pointerId,
          x: event.clientX,
          y: event.clientY,
          left: bounds.x + bounds.width / 2,
          top: bounds.y + bounds.height / 2,
        };
        setPosition({ x: drag.current.left, y: drag.current.top });
        setDragging(true);
        event.currentTarget.setPointerCapture(event.pointerId);
      }}
      onPointerMove={(event) => {
        const current = drag.current;
        if (!current || event.pointerId !== current.pointer) return;
        const x = current.left + event.clientX - current.x;
        const y = current.top + event.clientY - current.y;
        setPosition(containment ? clamp(x, y) : { x, y });
      }}
      onPointerUp={(event) => {
        if (drag.current?.pointer !== event.pointerId) return;
        event.currentTarget.releasePointerCapture(event.pointerId);
        finish();
      }}
      onLostPointerCapture={() => {
        if (drag.current) finish();
      }}
    >
      {children}
    </div>
  );
}
