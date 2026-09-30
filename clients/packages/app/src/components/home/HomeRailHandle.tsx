import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useId,
  useRef,
  useState,
} from "react";
import { Button as AriaButton } from "react-aria-components";
import { TooltipBubble } from "@comma/ui";
import { createPortal } from "react-dom";
import { useCommaMessages } from "@comma/i18n/react";
import { commaHomeRailMinWidth, type CommaHomeRailName } from "../shellGeometry";
import { useHomeRailCollapse } from "./HomeRailFolds";

function preventResizeSelection(event: Event) {
  event.preventDefault();
}

/**
 * The full-height seam resizes or shuts a Home rail and brings it back.
 *
 * It owns the gutter between the rail and the chat column, and rides that
 * boundary as the rail closes (styles.css) — so the same control that sat
 * beside the open rail ends up hugging the route's edge, which is where a
 * reader looks for a shut panel.
 *
 * A collapsed rail reveals its indicator on collapse and window-wide mouse
 * movement, then hides it after one second of idle time. An expanded rail
 * shows a short hint for three seconds when the mouse enters its content.
 * Movement inside the content does not restart the hint. Direct handle
 * hover, keyboard focus, and resizing retain their existing feedback.
 *
 * A rail the route itself folded has nothing to expand into, so no handle is
 * rendered there — it comes back with the width, exactly as before.
 */
export function HomeRailCollapseHandle({
  controls,
  label,
  name,
}: {
  controls: string;
  label: string;
  name: CommaHomeRailName;
}) {
  const messages = useCommaMessages();
  const { autoFolded, collapsed, toggleCollapsed, setWidth } =
    useHomeRailCollapse(name);
  const handleRef = useRef<HTMLButtonElement | null>(null);
  const stopResizeRef = useRef<(() => void) | null>(null);
  const draggedRef = useRef(false);
  const [resizing, setResizing] = useState(false);
  const tooltipId = useId();
  const [tooltipOpen, setTooltipOpen] = useState(false);
  const tooltipRef = useRef<HTMLDivElement | null>(null);
  const tooltipTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pointerPosition = useRef({ x: 0, y: 0 });
  const positionTooltip = useCallback(() => {
    const tooltip = tooltipRef.current;
    if (!tooltip) return;
    const { x, y } = pointerPosition.current;
    const halfHeight = tooltip.offsetHeight / 2;
    const desiredX = name === "tasks" ? x - 14 - tooltip.offsetWidth : x + 14;
    const left = Math.min(
      Math.max(desiredX, 8),
      Math.max(8, window.innerWidth - 8 - tooltip.offsetWidth)
    );
    const top = Math.min(
      Math.max(y, 8 + halfHeight),
      window.innerHeight - 8 - halfHeight
    );
    tooltip.style.transform = `translate3d(${left}px, ${top}px, 0)`;
  }, [name]);
  const cancelTooltipTimer = useCallback(() => {
    if (tooltipTimer.current !== null) clearTimeout(tooltipTimer.current);
    tooltipTimer.current = null;
  }, []);
  const hideTooltip = useCallback(() => {
    cancelTooltipTimer();
    setTooltipOpen(false);
  }, [cancelTooltipTimer]);
  useEffect(() => cancelTooltipTimer, [cancelTooltipTimer]);
  useEffect(() => hideTooltip(), [autoFolded, collapsed, hideTooltip]);
  useLayoutEffect(() => {
    if (tooltipOpen) positionTooltip();
  }, [tooltipOpen, collapsed, positionTooltip]);

  useEffect(() => () => stopResizeRef.current?.(), []);

  useEffect(() => {
    const handle = handleRef.current;
    const rail = document.getElementById(controls);
    if (!handle || !rail || autoFolded || collapsed) return;

    // At most one timer per expanded rail. Content movement does not renew it.
    // Only the handle changes, without layout reads or content renders.
    let hintTimer: ReturnType<typeof setTimeout> | undefined;
    const hide = () => {
      clearTimeout(hintTimer);
      handle.dataset.regionHint = "false";
    };
    const reveal = () => {
      clearTimeout(hintTimer);
      handle.dataset.regionHint = "true";
      hintTimer = setTimeout(hide, 3000);
    };
    const enter = (event: PointerEvent) => {
      if (event.pointerType === "mouse") reveal();
    };
    rail.addEventListener("pointerenter", enter);
    rail.addEventListener("pointerleave", hide);
    // An opening rail can arrive underneath a stationary mouse.
    if (rail.matches(":hover")) reveal();
    return () => {
      clearTimeout(hintTimer);
      rail.removeEventListener("pointerenter", enter);
      rail.removeEventListener("pointerleave", hide);
      delete handle.dataset.regionHint;
    };
  }, [autoFolded, collapsed, controls]);

  useEffect(() => {
    const handle = handleRef.current;
    if (!handle || autoFolded || !collapsed) return;

    // At most two local timers/listeners, one per collapsed Home rail.
    let idleTimer: ReturnType<typeof setTimeout>;
    const reveal = () => {
      handle.dataset.mouseActive = "true";
      clearTimeout(idleTimer);
      idleTimer = setTimeout(() => {
        handle.dataset.mouseActive = "false";
      }, 1000);
    };
    const track = (event: PointerEvent) => {
      if (event.pointerType === "mouse") reveal();
    };

    reveal();
    window.addEventListener("pointermove", track, { capture: true, passive: true });
    return () => {
      clearTimeout(idleTimer);
      window.removeEventListener("pointermove", track, true);
      delete handle.dataset.mouseActive;
    };
  }, [autoFolded, collapsed]);

  if (autoFolded) return null;

  return (
    <>
      <AriaButton
        aria-controls={controls}
        {...(tooltipOpen ? { "aria-describedby": tooltipId } : {})}
        aria-expanded={!collapsed}
        aria-label={
          collapsed
            ? messages.home_expand_panel({ panel: label })
            : messages.home_collapse_panel({ panel: label })
        }
        className={`comma-home-rail-handle comma-home-${name}-rail-handle`}
        data-comma-functional-cursor=""
        data-no-press-feedback
        data-testid={`home-${name}-rail-handle`}
        onPointerEnter={(event) => {
          if (event.pointerType !== "mouse" || event.buttons !== 0) return;
          pointerPosition.current = { x: event.clientX, y: event.clientY };
          cancelTooltipTimer();
          tooltipTimer.current = setTimeout(() => {
            tooltipTimer.current = null;
            setTooltipOpen(true);
          }, 300);
        }}
        onPointerMove={(event) => {
          pointerPosition.current = { x: event.clientX, y: event.clientY };
          positionTooltip();
        }}
        onPointerLeave={hideTooltip}
        onFocus={(event) => {
          if (!event.currentTarget.matches(":focus-visible")) return;
          const box = event.currentTarget.getBoundingClientRect();
          pointerPosition.current = {
            x: box.x + box.width / 2,
            y: box.y + box.height / 2,
          };
          setTooltipOpen(true);
        }}
        onBlur={hideTooltip}
        onPointerDown={(event) => {
          hideTooltip();
          draggedRef.current = false;
          if (event.button !== 0 || collapsed || !setWidth) return;
          stopResizeRef.current?.();
          const handle = event.currentTarget;
          const layout = handle.closest<HTMLElement>(".comma-home-layout");
          const rail = document.getElementById(controls);
          if (!layout || !rail) return;
          const direction = name === "greet" ? 1 : -1;
          let anchorX = event.clientX;
          let anchorWidth = rail.getBoundingClientRect().width;
          const pointerId = event.pointerId;
          const chat = layout.querySelector<HTMLElement>(".comma-home-chat");
          const maxWidth = Math.max(
            commaHomeRailMinWidth,
            anchorWidth + (chat?.getBoundingClientRect().width ?? 393) - 393
          );
          document.addEventListener("selectstart", preventResizeSelection, true);
          layout.dataset.resizing = name;
          // Preview only the latest width per frame on its layout owner. Keeping
          // those frames out of React avoids rendering the shell and both rails
          // for each pointer move; release commits the final preference once.
          const widthProperty = `--comma-home-${name}-preferred`;
          let resizeFrame: number | undefined;
          let pendingWidth: number | undefined;
          let previewedWidth: number | undefined;
          let stopped = false;
          const flushWidth = () => {
            if (resizeFrame !== undefined) cancelAnimationFrame(resizeFrame);
            resizeFrame = undefined;
            if (pendingWidth === undefined) return;
            const width = pendingWidth;
            pendingWidth = undefined;
            if (width === previewedWidth) return;
            previewedWidth = width;
            layout.style.setProperty(widthProperty, `${width}px`);
          };
          const stop = () => {
            if (stopped) return;
            stopped = true;
            flushWidth();
            // Leave the final preview in place until React takes ownership of
            // that same value. Removing it here would flash the previous width.
            if (previewedWidth !== undefined) setWidth(name, previewedWidth);
            window.removeEventListener("pointermove", move);
            window.removeEventListener("pointerup", finish);
            window.removeEventListener("pointercancel", finish);
            window.removeEventListener("blur", stop);
            handle.removeEventListener("lostpointercapture", stop);
            document.removeEventListener("selectstart", preventResizeSelection, true);
            delete layout.dataset.resizing;
            setResizing(false);
            stopResizeRef.current = null;
            if (handle.hasPointerCapture?.(pointerId))
              handle.releasePointerCapture(pointerId);
          };
          const finish = (up: PointerEvent) => {
            if (up.pointerId === pointerId) stop();
          };
          const move = (moveEvent: PointerEvent) => {
            if (moveEvent.pointerId !== pointerId) return;
            const delta = (moveEvent.clientX - anchorX) * direction;
            if (!draggedRef.current && Math.abs(delta) < 3) return;
            // React Aria hit-tests a plain press on release. Add the cursor
            // shield only once this is a drag, so it cannot cover a click.
            if (!draggedRef.current) setResizing(true);
            draggedRef.current = true;
            const requested = anchorWidth + delta;
            if (requested < commaHomeRailMinWidth) {
              stop();
              toggleCollapsed(name);
              return;
            }
            pendingWidth = Math.min(maxWidth, requested);
            resizeFrame ??= requestAnimationFrame(flushWidth);
            // At the upper bound, reversing direction must respond immediately.
            if (requested > maxWidth) {
              anchorX = moveEvent.clientX;
              anchorWidth = maxWidth;
            }
          };
          stopResizeRef.current = stop;
          window.addEventListener("pointermove", move);
          window.addEventListener("pointerup", finish);
          window.addEventListener("pointercancel", finish);
          window.addEventListener("blur", stop);
          handle.addEventListener("lostpointercapture", stop);
          try {
            handle.setPointerCapture(pointerId);
          } catch {
            /* Window listeners suffice. */
          }
        }}
        onKeyDown={(event) => {
          if (event.key === "Escape") hideTooltip();
          if (
            collapsed ||
            !setWidth ||
            !["ArrowLeft", "ArrowRight", "Home"].includes(event.key)
          )
            return;
          event.preventDefault();
          const rail = document.getElementById(controls);
          const current = rail?.getBoundingClientRect().width ?? commaHomeRailMinWidth;
          const chatWidth =
            rail
              ?.closest(".comma-home-layout")
              ?.querySelector(".comma-home-chat")
              ?.getBoundingClientRect().width ?? 393;
          const delta =
            (event.key === "ArrowRight" ? 16 : -16) * (name === "greet" ? 1 : -1);
          setWidth(
            name,
            event.key === "Home"
              ? commaHomeRailMinWidth
              : Math.max(
                  commaHomeRailMinWidth,
                  Math.min(current + chatWidth - 393, current + delta)
                )
          );
        }}
        onPress={(event) => {
          if (
            draggedRef.current &&
            event.pointerType !== "keyboard" &&
            event.pointerType !== "virtual"
          ) {
            draggedRef.current = false;
            return;
          }
          hideTooltip();
          toggleCollapsed(name);
        }}
        ref={handleRef}
        {...(resizing ? { style: { cursor: "col-resize" } } : {})}
        type="button"
      />
      {resizing
        ? createPortal(
            <div
              aria-hidden="true"
              className="fixed inset-0 z-[60] cursor-col-resize"
              data-testid="home-rail-resize-cursor-overlay"
            />,
            document.body
          )
        : null}
      {tooltipOpen
        ? createPortal(
            <div
              className="comma-sidebar-edge-tooltip comma-home-rail-tooltip"
              role="tooltip"
              id={tooltipId}
              data-testid={`home-${name}-rail-tooltip`}
              ref={tooltipRef}
            >
              <div className="comma-sidebar-edge-tooltip-bubble">
                <TooltipBubble
                  content={
                    collapsed
                      ? messages.home_panel_click_to_expand()
                      : messages.home_panel_click_to_collapse()
                  }
                  rows={
                    collapsed
                      ? [{ label: messages.home_panel_click_to_expand() }]
                      : [
                          { label: messages.home_panel_click_to_collapse() },
                          { label: messages.shell_sidebar_drag_to_resize() },
                        ]
                  }
                />
              </div>
            </div>,
            document.body
          )
        : null}
    </>
  );
}
