import {
  cloneElement,
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
  type FocusEvent,
  type HTMLAttributes,
  type KeyboardEvent,
  type PointerEvent,
  type ReactElement,
  type ReactNode,
  type Ref,
} from "react";
import {
  OverlayContainer,
  mergeProps,
  mergeRefs,
  useOverlayPosition,
} from "react-aria";
import { getInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import type { TooltipProps as AriaTooltipProps } from "react-aria-components";
import { uiClock, type CancelUiTimer } from "../../clock";
import { spacing } from "../../tokens/spacing";
import { cx } from "../utils";
import { suspendHoverCards } from "./HoverCard";

/** Items in the panel that arrow keys move between. */
export const HOVER_PANEL_ITEM = "data-hover-panel-item";

type HoverPanelTriggerProps = HTMLAttributes<HTMLElement> & {
  ref?: Ref<HTMLElement> | undefined;
};

export interface HoverPanelProps {
  /** The trigger: a link or button that forwards its ref. */
  children: ReactElement<HoverPanelTriggerProps>;
  className?: string;
  closeDelay?: number;
  /** Content people can use: links or buttons marked with `HOVER_PANEL_ITEM`. */
  content: ReactNode;
  delay?: number;
  /** Names the panel for assistive technology. */
  label: string;
  placement?: NonNullable<AriaTooltipProps["placement"]>;
}

/**
 * A hover card whose content people can use. Unlike `HoverCard`, which is a
 * read-only preview, this panel holds links or buttons.
 *
 * Pointer users open it by hovering the trigger and can move into it. Keyboard
 * users open it by focusing the trigger, press ArrowDown or ArrowUp to enter,
 * move between items with the arrow keys, and press Escape or Tab to return
 * to the trigger. A press on the trigger keeps its own action and closes the
 * panel until the pointer or focus leaves.
 *
 * Placed above its trigger, the panel is anchored by its bottom edge, so
 * content that grows extends upward.
 */
export function HoverPanel({
  children,
  className,
  closeDelay = 150,
  content,
  delay = 250,
  label,
  placement = "top start",
}: HoverPanelProps) {
  const panelId = useId();
  const triggerRef = useRef<HTMLElement | null>(null);
  const panelRef = useRef<HTMLDialogElement | null>(null);
  const timer = useRef<CancelUiTimer | undefined>(undefined);
  const dismissed = useRef(false);
  const [isOpen, setOpen] = useState(false);

  const clearTimer = useCallback(() => {
    if (timer.current !== undefined) timer.current();
    timer.current = undefined;
  }, []);
  const close = useCallback(
    (returnFocus: boolean) => {
      clearTimer();
      setOpen(false);
      if (!returnFocus) return;
      // Focus returns to a closed panel: it reopens on ArrowDown, not on this focus.
      dismissed.current = true;
      triggerRef.current?.focus();
    },
    [clearTimer]
  );
  useEffect(() => clearTimer, [clearTimer]);
  // Read-only hover cards stay closed while this panel is open.
  useEffect(() => (isOpen ? suspendHoverCards() : undefined), [isOpen]);
  // A press anywhere else closes the panel.
  useEffect(() => {
    if (!isOpen) return undefined;
    const onPointerDown = (event: globalThis.PointerEvent) => {
      const target = event.target as Node | null;
      if (triggerRef.current?.contains(target) || panelRef.current?.contains(target))
        return;
      close(false);
    };
    document.addEventListener("pointerdown", onPointerDown, true);
    return () => document.removeEventListener("pointerdown", onPointerDown, true);
  }, [close, isOpen]);

  const { overlayProps, placement: actualPlacement } = useOverlayPosition({
    targetRef: triggerRef,
    overlayRef: panelRef,
    placement,
    offset: spacing.md,
    isOpen,
    onClose: () => close(false),
  });

  const pointerEnter = (event: PointerEvent) => {
    if (event.pointerType === "touch") return;
    clearTimer();
    if (isOpen || dismissed.current) return;
    timer.current = uiClock.after(delay, () => setOpen(true));
  };
  const pointerLeave = (event: PointerEvent) => {
    if (event.pointerType === "touch") return;
    dismissed.current = false;
    clearTimer();
    timer.current = uiClock.after(closeDelay, () => setOpen(false));
  };
  const focusOut = (event: FocusEvent) => {
    const next = event.relatedTarget as Node | null;
    if (triggerRef.current?.contains(next) || panelRef.current?.contains(next)) return;
    dismissed.current = false;
    close(false);
  };
  const items = () =>
    Array.from(
      panelRef.current?.querySelectorAll<HTMLElement>(`[${HOVER_PANEL_ITEM}]`) ?? []
    );
  const focusItem = (pick: (list: HTMLElement[]) => HTMLElement | undefined) => {
    // The panel mounts with the open state; wait one frame for its items.
    uiClock.frame(() => pick(items())?.focus());
  };

  const trigger = cloneElement(
    children,
    mergeProps(children.props, {
      ref: mergeRefs(children.props.ref, triggerRef),
      "aria-controls": isOpen ? panelId : undefined,
      "aria-expanded": isOpen,
      "aria-haspopup": "dialog" as const,
      onPointerEnter: pointerEnter,
      onPointerLeave: pointerLeave,
      onFocus: () => {
        if (getInteractionModality() !== "keyboard" || dismissed.current) return;
        clearTimer();
        setOpen(true);
      },
      onBlur: focusOut,
      onKeyDown: (event: KeyboardEvent) => {
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault();
          clearTimer();
          setOpen(true);
          focusItem((list) => (event.key === "ArrowDown" ? list[0] : list.at(-1)));
        } else if (event.key === "Escape" && isOpen) {
          event.preventDefault();
          close(false);
        }
      },
      onClick: () => {
        dismissed.current = true;
        close(false);
      },
    })
  );

  return (
    <>
      {trigger}
      {isOpen ? (
        <OverlayContainer>
          {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- The panel moves focus between its own links and keeps itself open under the pointer. */}
          <dialog
            {...overlayProps}
            aria-label={label}
            className={cx(
              "comma-hover-panel z-50 m-0 rounded-xl border-[0.5px] border-primary bg-popup-primary p-0 text-primary shadow-lg outline-none",
              className
            )}
            data-placement={actualPlacement ?? undefined}
            data-slot="hover-panel"
            id={panelId}
            ref={panelRef}
            open
            onBlur={focusOut}
            onClick={(event) => {
              // An item does its own work, such as opening a page, then the panel closes.
              if ((event.target as Element).closest(`[${HOVER_PANEL_ITEM}]`))
                close(false);
            }}
            onKeyDown={(event) => {
              const list = items();
              const index = list.indexOf(document.activeElement as HTMLElement);
              if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                event.preventDefault();
                const step = event.key === "ArrowDown" ? 1 : -1;
                const next =
                  index === -1
                    ? step === 1
                      ? 0
                      : list.length - 1
                    : (index + step + list.length) % list.length;
                list[next]?.focus();
              } else if (event.key === "Home" || event.key === "End") {
                event.preventDefault();
                (event.key === "Home" ? list[0] : list.at(-1))?.focus();
              } else if (event.key === "Escape" || event.key === "Tab") {
                event.preventDefault();
                close(true);
              }
            }}
            onPointerEnter={pointerEnter}
            onPointerLeave={pointerLeave}
          >
            {content}
          </dialog>
        </OverlayContainer>
      ) : null}
    </>
  );
}
