import {
  getNativeBridge,
  type MeetingRecorderWindowDrag,
  type MeetingRecorderWindowLayout,
} from "@comma/native-bridge";
import {
  useCallback,
  useLayoutEffect,
  useRef,
  type RefObject,
  type PointerEvent as ReactPointerEvent,
} from "react";

// shadow-lg extends 20px below the surface; keep it inside the native buffer.
const padding = 24;

const sendDrag = (input: MeetingRecorderWindowDrag) => {
  void getNativeBridge()
    .meetingRecorder.dragWindow(input)
    .catch(() => {});
};

const point = (
  event: ReactPointerEvent<HTMLDivElement>,
  phase: MeetingRecorderWindowDrag["phase"]
): MeetingRecorderWindowDrag => ({
  phase,
  screenX: event.screenX,
  screenY: event.screenY,
  reducedMotion:
    window.matchMedia("(prefers-reduced-motion: reduce)").matches ||
    document.documentElement.dataset.commaReducedMotion === "true",
});

/** Native bounds change at transition boundaries, never on every animation frame. */
export function useNativeRecorderWindow(
  root: RefObject<HTMLDivElement | null>,
  active: boolean
) {
  const measure = useRef<() => void>(() => {});
  const menu = useRef(false);
  const menuMeasureReady = useRef(false);
  const menuAbove = useRef<boolean | undefined>(undefined);
  const drag = useRef<number | undefined>(undefined);
  const dragFrame = useRef<number | undefined>(undefined);
  const latest = useRef<MeetingRecorderWindowDrag | undefined>(undefined);
  const onMenuOpenChange = useCallback((open: boolean) => {
    menu.current = open;
    if (open) menuMeasureReady.current = false;
    measure.current();
  }, []);
  useLayoutEffect(() => {
    if (!active || !root.current || typeof ResizeObserver === "undefined") return;
    const element = root.current;
    let disposed = false;
    let painted = false;
    let inFlight = false;
    let wanted: MeetingRecorderWindowLayout | undefined;
    let sent = "";
    const drain = () => {
      if (disposed || inFlight || !wanted) return;
      const input = wanted;
      wanted = undefined;
      const key = `${input.width}:${input.height}:${input.anchorY}`;
      if (key === sent) return;
      sent = key;
      inFlight = true;
      void getNativeBridge()
        .meetingRecorder.layoutWindow(input)
        .catch(() => {})
        .finally(() => {
          inFlight = false;
          if (menu.current && !menuMeasureReady.current && !disposed) {
            requestAnimationFrame(() =>
              requestAnimationFrame(() => {
                if (disposed || !menu.current) return;
                menuMeasureReady.current = true;
                measure.current();
              })
            );
          }
          drain();
        });
    };
    let observedMenu: Element | null = null;
    let envelope = { width: 0, height: 0 };
    let layoutRevision = 0;
    let layoutKey = "";
    const sample = () => {
      if (!painted || disposed) return;
      const motion = element.querySelector<HTMLElement>(".comma-recorder-motion");
      const card = element.querySelector<HTMLElement>('[data-slot="meeting-recorder"]');
      if (!motion || !card) return;
      if (!["recording", "paused"].includes(card.dataset.phase ?? "")) {
        menu.current = false;
      }
      const bounds = card.getBoundingClientRect();
      const style = getComputedStyle(motion);
      const compact = motion.hasAttribute("data-compact");
      const targetWidth = Number.parseFloat(
        style.getPropertyValue(
          compact ? "--meeting-recorder-compact-width" : "--meeting-recorder-width"
        )
      );
      const notice = card.querySelector(".comma-recorder-notice");
      const liveHeight = compact
        ? 42
        : !notice && ["recording", "paused"].includes(card.dataset.phase ?? "")
          ? 56
          : bounds.height;
      const key = `${card.dataset.phase}:${compact}:${notice?.textContent ?? ""}`;
      const target = { width: targetWidth, height: liveHeight };
      if (key !== layoutKey) {
        // Reserve both endpoint sizes once. CSS owns the 180ms interpolation;
        // resizing the OS window each frame otherwise races Chromium's viewport.
        const previous = envelope;
        layoutKey = key;
        envelope = {
          width: Math.max(previous.width, target.width),
          height: Math.max(previous.height, target.height),
        };
        const revision = ++layoutRevision;
        // Timers can fire before CSS has painted its endpoint (or the motion
        // duration can change). Never make an intermediate height permanent.
        // Ignore infinite decorative animations such as the live waveform.
        const animations = card
          .getAnimations({ subtree: true })
          .filter(
            (animation) => animation.effect?.getComputedTiming().endTime !== Infinity
          );
        void Promise.allSettled(animations.map((animation) => animation.finished)).then(
          () => {
            if (disposed || revision !== layoutRevision) return;
            envelope = { width: target.width, height: card.offsetHeight };
            schedule();
          }
        );
      }
      let width = Math.ceil(envelope.width + padding * 2);
      let height = Math.ceil(envelope.height + padding * 2);
      const popover = document.querySelector<HTMLElement>(".comma-recorder-menu");
      if (popover !== observedMenu) {
        if (observedMenu) observer.unobserve(observedMenu);
        observedMenu = popover;
        if (popover) observer.observe(popover);
      }
      let anchorY: number | undefined;
      if (menu.current || popover) {
        // Reserve a local menu strip, then fit its untransformed content height.
        // Unlike a centered popup canvas this adds no invisible area above the card.
        const extra =
          popover && menuMeasureReady.current
            ? Math.min(256, popover.offsetHeight + 8)
            : 248;
        width = Math.max(
          width,
          popover && menuMeasureReady.current ? popover.offsetWidth + padding * 2 : 420
        );
        height += extra;
        const inset = envelope.height / 2 + padding;
        if (menuAbove.current === undefined) {
          const screenCenter = window.screenY + bounds.y + bounds.height / 2;
          // Chromium exposes the work-area origin for displays above/below the primary.
          const { availTop } = window.screen as Screen & { availTop: number };
          menuAbove.current =
            availTop + window.screen.availHeight - screenCenter < inset + extra &&
            screenCenter - availTop > inset + extra;
        }
        anchorY = menuAbove.current ? height - inset : inset;
        element.style.top = menuAbove.current
          ? `calc(100% - ${inset}px)`
          : `${inset}px`;
      } else {
        menuAbove.current = undefined;
        element.style.top = "50%";
      }
      wanted = {
        width: Math.min(width, 720),
        height: Math.min(height, 640),
        ...(anchorY !== undefined ? { anchorY } : {}),
      };
      drain();
    };
    // Do not write geometry inside observer delivery: portal placement can resize
    // the observed menu again. Coalesce observations into the next frame instead.
    let measureFrame: number | undefined;
    const schedule = () => {
      if (measureFrame !== undefined) return;
      measureFrame = requestAnimationFrame(() => {
        measureFrame = undefined;
        if (!disposed) sample();
      });
    };
    const observer = new ResizeObserver(schedule);
    // Observe menu contents only. Root resizing is the animation itself, not
    // a request to resize the native window again.
    const mutation = new MutationObserver(schedule);
    mutation.observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["data-compact", "data-phase"],
    });
    const blur = () => {
      if (menu.current)
        document.activeElement?.dispatchEvent(
          new KeyboardEvent("keydown", { key: "Escape", bubbles: true })
        );
    };
    window.addEventListener("blur", blur);
    measure.current = sample;
    // First layout arrives only after React and its stylesheet have painted.
    let firstPaint = requestAnimationFrame(() => {
      firstPaint = requestAnimationFrame(() => {
        painted = true;
        sample();
      });
    });
    return () => {
      cancelAnimationFrame(firstPaint);
      disposed = true;
      menu.current = false;
      menuMeasureReady.current = false;
      menuAbove.current = undefined;
      if (measureFrame !== undefined) cancelAnimationFrame(measureFrame);
      layoutRevision += 1;
      observer.disconnect();
      mutation.disconnect();
      window.removeEventListener("blur", blur);
      measure.current = () => {};
      if (dragFrame.current) cancelAnimationFrame(dragFrame.current);
    };
  }, [active, root]);

  const finish = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (drag.current !== event.pointerId) return;
    if (dragFrame.current) cancelAnimationFrame(dragFrame.current);
    dragFrame.current = undefined;
    drag.current = undefined;
    sendDrag(point(event, "end"));
    if (event.currentTarget.hasPointerCapture(event.pointerId))
      event.currentTarget.releasePointerCapture(event.pointerId);
    event.currentTarget.removeAttribute("data-dragging");
  };
  return {
    onMenuOpenChange,
    dragHandlers: {
      onPointerDown: (event: ReactPointerEvent<HTMLDivElement>) => {
        if (
          event.button !== 0 ||
          !(event.target instanceof Element) ||
          event.target.closest("button, [role=menu], a, input")
        )
          return;
        event.preventDefault();
        drag.current = event.pointerId;
        event.currentTarget.setPointerCapture(event.pointerId);
        event.currentTarget.dataset.dragging = "true";
        sendDrag(point(event, "start"));
      },
      onPointerMove: (event: ReactPointerEvent<HTMLDivElement>) => {
        if (drag.current !== event.pointerId) return;
        latest.current = point(event, "move");
        if (dragFrame.current) return;
        dragFrame.current = requestAnimationFrame(() => {
          dragFrame.current = undefined;
          if (latest.current && drag.current !== undefined) sendDrag(latest.current);
        });
      },
      onPointerUp: finish,
      onPointerCancel: finish,
      onLostPointerCapture: finish,
    },
  };
}
