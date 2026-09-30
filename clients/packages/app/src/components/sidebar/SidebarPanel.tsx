import { useCommaMessages } from "@comma/i18n/react";
import { appKeybindingKeycaps, TooltipBubble } from "@comma/ui";
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
import { createPortal } from "react-dom";
import { useOptionalAppShortcutBinding } from "../shortcuts/commaAppShortcuts";
import { useRailFoldSpring } from "../railFoldSpring";
import { commaSidebarRailWidth } from "../shellGeometry";
import { useCommaSidebar } from "./SidebarContext";

// The rail's edge behaves like the Chat Sidebar's handle: the hint waits out a
// hover, then rides the pointer down the border a fixed step to its side.
const edgeTooltipShowDelay = 300;
const edgeTooltipPointerOffset = 14;
const edgeTooltipWindowInset = 8;

/**
 * The icon rail beside the content panel. The rail keeps its full width while
 * its slot animates between `--comma-sidebar-rail-width` and zero, so collapsing
 * slides it under the content panel instead of reflowing its items.
 */
export function CommaSidebarPanel({ children }: { children: ReactNode }) {
  const messages = useCommaMessages();
  const { collapsed } = useCommaSidebar();
  const slotRef = useRef<HTMLDivElement>(null);
  const collapsedWidth = useRef(0);
  // While the fold moves, the slot's own width is written directly. Writing
  // `--comma-sidebar-layout-width` instead would restyle every element in the
  // rail each frame, since that property is inherited.
  useRailFoldSpring(collapsed, {
    write: (progress, phase) => {
      const slot = slotRef.current;
      if (!slot) return;
      const body = slot.querySelector<HTMLElement>(".comma-sidebar-body");
      if (phase === "rest") {
        slot.style.removeProperty("flex-basis");
        slot.style.removeProperty("width");
        slot.removeAttribute("data-fold-moving");
        body?.style.removeProperty("--comma-sidebar-fold-progress");
        return;
      }
      const width = `${
        commaSidebarRailWidth +
        (collapsedWidth.current - commaSidebarRailWidth) * progress
      }px`;
      slot.style.flexBasis = width;
      slot.style.width = width;
      slot.setAttribute("data-fold-moving", "");
      body?.style.setProperty("--comma-sidebar-fold-progress", String(progress));
    },
    span: () => {
      const slot = slotRef.current;
      collapsedWidth.current = slot
        ? Number.parseFloat(getComputedStyle(slot).getPropertyValue("--spacing-md")) ||
          0
        : 0;
      return commaSidebarRailWidth - collapsedWidth.current;
    },
  });
  const sidebarStyle = {
    // Collapsed, the slot keeps the window's own gutter so the content panel
    // is inset from the left edge the same way it is from the right.
    "--comma-sidebar-layout-width": collapsed
      ? "var(--spacing-md)"
      : `${commaSidebarRailWidth}px`,
    "--comma-sidebar-rail-width": `${commaSidebarRailWidth}px`,
  } as CSSProperties;

  return (
    <div
      className="comma-sidebar-slot relative min-h-0 shrink-0"
      data-collapsed={collapsed}
      data-testid="comma-sidebar-slot"
      ref={slotRef}
      style={sidebarStyle}
    >
      <aside
        aria-label={messages.shell_app_sidebar()}
        className="comma-sidebar flex h-full min-h-0 min-w-0 flex-col bg-window"
        data-collapsed={collapsed}
        data-testid="comma-sidebar"
      >
        {children}
        <SidebarEdgeToggle />
      </aside>
    </div>
  );
}

/**
 * The rail's right edge is its own collapse control: a slim strip that shows a
 * hairline on hover and toggles on click. It has no drag behaviour — the rail
 * is a fixed width — but its hint follows the pointer along the border the way
 * the Chat Sidebar's does, since the strip runs the whole height of the window
 * and an anchored bubble would sit far from the cursor.
 */
function SidebarEdgeToggle() {
  const messages = useCommaMessages();
  const { collapsed, toggleCollapsed } = useCommaSidebar();
  const shortcut = useOptionalAppShortcutBinding("toggle-left-sidebar");
  const label = collapsed
    ? messages.shell_expand_sidebar()
    : messages.shell_collapse_sidebar();
  const [tooltipOpen, setTooltipOpen] = useState(false);
  const tooltipRef = useRef<HTMLDivElement | null>(null);
  const pointerPosition = useRef({ x: 0, y: 0 });
  const tooltipShowTimer = useRef<number | null>(null);

  const positionTooltip = useCallback(() => {
    const tooltip = tooltipRef.current;
    if (tooltip === null) return;

    const { x, y } = pointerPosition.current;
    const halfHeight = tooltip.offsetHeight / 2;
    const minX = edgeTooltipWindowInset;
    const maxX = Math.max(
      minX,
      window.innerWidth - edgeTooltipWindowInset - tooltip.offsetWidth
    );
    const clampedX = Math.min(Math.max(x + edgeTooltipPointerOffset, minX), maxX);
    const clampedY = Math.min(
      Math.max(y, edgeTooltipWindowInset + halfHeight),
      window.innerHeight - edgeTooltipWindowInset - halfHeight
    );
    tooltip.style.transform = `translate3d(${clampedX}px, ${clampedY}px, 0)`;
  }, []);

  useLayoutEffect(() => {
    if (tooltipOpen) positionTooltip();
  }, [positionTooltip, tooltipOpen]);

  const cancelTooltipShow = useCallback(() => {
    if (tooltipShowTimer.current === null) return;

    window.clearTimeout(tooltipShowTimer.current);
    tooltipShowTimer.current = null;
  }, []);

  useEffect(() => cancelTooltipShow, [cancelTooltipShow]);

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
        aria-expanded={!collapsed}
        aria-label={label}
        // The strip stays inside the rail: past its border the content panel
        // owns the gutter, where Home's own rail handles take their clicks.
        className="comma-sidebar-edge-toggle absolute inset-y-0 right-0 z-[3] w-2 cursor-col-resize border-0 bg-transparent p-0"
        // The border keeps the sidebar-edge cursor whatever the pointer-cursors
        // appearance setting does to ordinary buttons.
        data-comma-functional-cursor=""
        onClick={toggleCollapsed}
        onPointerDown={hideTooltip}
        onPointerEnter={(event) => {
          if (event.pointerType !== "mouse") return;

          trackPointer(event);
          cancelTooltipShow();
          tooltipShowTimer.current = window.setTimeout(() => {
            tooltipShowTimer.current = null;
            setTooltipOpen(true);
          }, edgeTooltipShowDelay);
        }}
        onPointerLeave={hideTooltip}
        onPointerMove={trackPointer}
        type="button"
      />
      {tooltipOpen
        ? createPortal(
            <div
              aria-hidden="true"
              className="comma-sidebar-edge-tooltip"
              data-testid="comma-sidebar-edge-tooltip"
              ref={tooltipRef}
            >
              <div className="comma-sidebar-edge-tooltip-bubble">
                <TooltipBubble
                  content={label}
                  shortcut={appKeybindingKeycaps(shortcut)}
                />
              </div>
            </div>,
            document.body
          )
        : null}
    </>
  );
}
