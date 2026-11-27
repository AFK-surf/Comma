import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type DragEvent,
  type MouseEvent,
  type PointerEvent,
  type RefObject,
} from "react";

const DRAG_THRESHOLD_PX = 4;

export interface HorizontalDragScrollResult {
  canScroll: boolean;
  dragging: boolean;
  scrolledLeft: boolean;
  scrollableRight: boolean;
  handlers: {
    onClickCapture: (event: MouseEvent<HTMLElement>) => void;
    onDragStart: (event: DragEvent<HTMLElement>) => void;
    onPointerCancel: (event: PointerEvent<HTMLElement>) => void;
    onPointerDown: (event: PointerEvent<HTMLElement>) => void;
    onPointerMove: (event: PointerEvent<HTMLElement>) => void;
    onPointerUp: (event: PointerEvent<HTMLElement>) => void;
  };
}

export function useHorizontalDragScroll(
  ref: RefObject<HTMLElement | null>
): HorizontalDragScrollResult {
  const [canScroll, setCanScroll] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [scrolledLeft, setScrolledLeft] = useState(false);
  const [scrollableRight, setScrollableRight] = useState(false);

  const stateRef = useRef<{
    active: boolean;
    pointerId: number | null;
    startX: number;
    startScrollLeft: number;
    moved: boolean;
    suppressNextClick: boolean;
  }>({
    active: false,
    pointerId: null,
    startX: 0,
    startScrollLeft: 0,
    moved: false,
    suppressNextClick: false,
  });

  useEffect(() => {
    const el = ref.current;
    if (!el) return undefined;

    const onScroll = () => {
      setScrolledLeft(el.scrollLeft > 2);
      setScrollableRight(el.scrollLeft + el.clientWidth < el.scrollWidth - 2);
    };
    const update = () => {
      setCanScroll(el.scrollWidth > el.clientWidth + 1);
      onScroll();
    };
    el.addEventListener("scroll", onScroll, { passive: true });

    let observer: ResizeObserver | undefined;
    if (typeof ResizeObserver !== "undefined") {
      observer = new ResizeObserver(update);
      observer.observe(el);
      for (const child of Array.from(el.children)) {
        observer.observe(child);
      }
    } else {
      update();
    }
    return () => {
      el.removeEventListener("scroll", onScroll);
      observer?.disconnect();
    };
  }, [ref]);

  const endDrag = useCallback(
    (event: PointerEvent<HTMLElement>) => {
      const st = stateRef.current;
      if (!st.active || st.pointerId !== event.pointerId) return;
      const el = ref.current;
      if (el && el.hasPointerCapture(event.pointerId)) {
        try {
          el.releasePointerCapture(event.pointerId);
        } catch {
          // ignore if capture was already released
        }
      }
      st.active = false;
      st.pointerId = null;
      if (st.moved) {
        st.suppressNextClick = true;
      }
      st.moved = false;
      setDragging(false);
    },
    [ref]
  );

  const onPointerDown = useCallback(
    (event: PointerEvent<HTMLElement>) => {
      if (event.pointerType !== "mouse" || event.button !== 0) return;
      const el = ref.current;
      if (!el || el.scrollWidth <= el.clientWidth + 1) return;
      stateRef.current = {
        active: true,
        pointerId: event.pointerId,
        startX: event.clientX,
        startScrollLeft: el.scrollLeft,
        moved: false,
        suppressNextClick: false,
      };
    },
    [ref]
  );

  const onPointerMove = useCallback(
    (event: PointerEvent<HTMLElement>) => {
      const st = stateRef.current;
      if (!st.active || st.pointerId !== event.pointerId) return;
      const el = ref.current;
      if (!el) return;
      const dx = event.clientX - st.startX;
      if (!st.moved && Math.abs(dx) > DRAG_THRESHOLD_PX) {
        st.moved = true;
        setDragging(true);
        try {
          el.setPointerCapture(event.pointerId);
        } catch {
          // ignore synthetic pointer events without active capture target
        }
      }
      if (st.moved) {
        el.scrollLeft = st.startScrollLeft - dx;
      }
    },
    [ref]
  );

  const onClickCapture = useCallback((event: MouseEvent<HTMLElement>) => {
    const st = stateRef.current;
    if (st.suppressNextClick || st.moved) {
      st.suppressNextClick = false;
      st.moved = false;
      event.preventDefault();
      event.stopPropagation();
    }
  }, []);

  const onDragStart = useCallback((event: DragEvent<HTMLElement>) => {
    event.preventDefault();
  }, []);

  return {
    canScroll,
    dragging,
    scrolledLeft,
    scrollableRight,
    handlers: {
      onClickCapture,
      onDragStart,
      onPointerCancel: endDrag,
      onPointerDown,
      onPointerMove,
      onPointerUp: endDrag,
    },
  };
}
