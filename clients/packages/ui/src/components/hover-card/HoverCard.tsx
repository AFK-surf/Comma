import {
  OverlayContainer,
  mergeProps,
  mergeRefs,
  useFocusable,
  useOverlayPosition,
  useTooltip,
} from "react-aria";
import {
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  cloneElement,
  type ComponentProps,
  type HTMLAttributes,
  type PointerEvent,
  type ReactElement,
  type ReactNode,
  type Ref,
  type RefObject,
  type SyntheticEvent,
} from "react";
import {
  Focusable,
  Tooltip as AriaTooltip,
  TooltipContext,
  TooltipTriggerStateContext,
  useContextProps,
  TooltipTrigger as AriaTooltipTrigger,
  type TooltipProps as AriaTooltipProps,
} from "react-aria-components";
import { cx } from "../utils";
import { uiClock } from "../../clock";
import { spacing } from "../../tokens/spacing";

type FocusableChild = ComponentProps<typeof Focusable>["children"];
type TriggerProps = HTMLAttributes<HTMLElement> & {
  ref?: Ref<HTMLElement> | undefined;
};

type ActiveHoverCard = {
  id: symbol;
  close: () => void;
  makeInstant: () => void;
};

// Module-level handoff registry (same pattern as Tooltip): while one card is
// open, opening another must swap contents instantly — replaying the enter
// animation on every adjacent hover would flash a gap between cards.
let activeHoverCard: ActiveHoverCard | null = null;
let hoverCardSuspensionCount = 0;

/**
 * Close whichever hover card is open right now. Surfaces that take over the
 * pointer (a context menu opening over the same content) call this so a card
 * that was already showing does not linger behind the new surface.
 */
function dismissActiveHoverCard() {
  activeHoverCard?.close();
}

/**
 * Keep rich hover cards closed while another pointer-owned surface is active.
 * The counter allows independently mounted surfaces to share the suspension.
 */
export function suspendHoverCards() {
  hoverCardSuspensionCount += 1;
  dismissActiveHoverCard();

  return () => {
    hoverCardSuspensionCount -= 1;
  };
}
export interface HoverCardProps {
  /**
   * Positions the card against this element instead of the trigger. Use it when
   * several triggers stand in for one surface — the card then holds still as the
   * pointer crosses between them instead of hopping to each trigger's box.
   */
  anchorRef?: RefObject<Element | null> | undefined;
  boundaryRef?: RefObject<Element | null> | undefined;
  children: ReactElement;
  className?: string;
  closeDelay?: number;
  content: ReactNode;
  defaultOpen?: boolean;
  delay?: number;
  onOpenChange?: (open: boolean) => void;
  /**
   * Reports a hover the trigger cannot observe, such as a link inside a widget
   * frame. `delay` and `closeDelay` still apply, and the card stays open while
   * the pointer is over it.
   */
  open?: boolean | undefined;
  placement?: NonNullable<AriaTooltipProps["placement"]>;
  /**
   * Opens the card on pointer hover only. The trigger gets no tab stop, no
   * focus or keyboard handlers and no `aria-describedby`, so it can be a plain
   * element inside another control, such as a chip inside a card's button or
   * link. Give keyboard users the same details in another place.
   */
  pointerOnly?: boolean | undefined;
}

/**
 * A non-interactive rich preview for a link or button. React Aria owns hover,
 * keyboard focus, Escape dismissal, portal placement, and screen-reader
 * tooltip semantics; Focusable bridges those props onto arbitrary triggers.
 *
 * The card is not part of the control under its trigger. React sends events
 * from the card's portal to the trigger's ancestors, so presses in the card
 * stop at its root: a Task card's button, context menu or drag gesture does
 * not see them. Native defaults, such as text selection, still apply.
 * Stopping a React event also stops the native one at the portal's container,
 * so a document or window listener sees presses in a card only in the
 * capture phase.
 */
export function HoverCard({
  anchorRef,
  boundaryRef,
  children,
  className,
  closeDelay = 100,
  content,
  defaultOpen = false,
  delay = 250,
  onOpenChange,
  open: hoverOpen,
  placement = "bottom start",
  pointerOnly = false,
}: HoverCardProps) {
  const pointerOverCard = useRef(false);
  const dismissedByPress = useRef(false);
  const openRef = useRef(defaultOpen);
  const [isOpen, setIsOpen] = useState(defaultOpen);
  const [isInstant, setIsInstant] = useState(false);
  const cardIdRef = useRef<symbol | null>(null);
  cardIdRef.current ??= Symbol("comma-hover-card");
  const id = cardIdRef.current;
  const makeInstant = useCallback(() => setIsInstant(true), []);
  const updateOpen = useCallback(
    (open: boolean) => {
      if (openRef.current === open) return;
      openRef.current = open;
      setIsOpen(open);
      onOpenChange?.(open);
    },
    [onOpenChange]
  );
  const close = useCallback(() => {
    pointerOverCard.current = false;
    updateOpen(false);
  }, [updateOpen]);
  const handleCardRef = useCallback(
    (element: HTMLDivElement | null) => {
      if (element) {
        activeHoverCard = { close, id, makeInstant };
      } else if (activeHoverCard?.id === id) {
        activeHoverCard = null;
      }
    },
    [close, id, makeInstant]
  );
  const handleOpenChange = (open: boolean) => {
    if (open && (hoverCardSuspensionCount > 0 || dismissedByPress.current)) return;
    if (open) {
      const previousCard = activeHoverCard;
      // Close the outgoing card without its exit animation and open this one
      // without its enter animation: the handoff reads as one card moving.
      if (previousCard && previousCard.id !== id) previousCard.makeInstant();
      setIsInstant(previousCard !== null && previousCard.id !== id);
    }
    if (!open && pointerOverCard.current) return;
    updateOpen(open);
  };
  const handleOpenChangeRef = useRef(handleOpenChange);
  handleOpenChangeRef.current = handleOpenChange;

  useEffect(() => {
    if (hoverOpen === undefined) return;
    const timer = uiClock.after(hoverOpen ? delay : closeDelay, () =>
      handleOpenChangeRef.current(hoverOpen)
    );
    return () => timer();
  }, [closeDelay, delay, hoverOpen]);

  useEffect(() => {
    if (!isOpen) return;

    const handleEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      pointerOverCard.current = false;
      updateOpen(false);
    };
    document.addEventListener("keydown", handleEscape, true);
    return () => document.removeEventListener("keydown", handleEscape, true);
  }, [isOpen, updateOpen]);

  const trigger = children as ReactElement<TriggerProps>;
  // A press keeps the card closed until the trigger loses focus. A pointer-only
  // trigger never takes focus, so the pointer leaving it ends the press.
  const dismissibleTrigger = cloneElement(trigger, {
    onClick: (event) => {
      dismissedByPress.current = true;
      close();
      trigger.props.onClick?.(event);
    },
    onBlur: (event) => {
      dismissedByPress.current = false;
      trigger.props.onBlur?.(event);
    },
    ...(pointerOnly
      ? {
          onPointerLeave: (event: PointerEvent<HTMLElement>) => {
            dismissedByPress.current = false;
            trigger.props.onPointerLeave?.(event);
          },
        }
      : {}),
  });
  return (
    <AriaTooltipTrigger
      closeDelay={closeDelay}
      delay={delay}
      isOpen={isOpen}
      onOpenChange={handleOpenChange}
    >
      {pointerOnly ? (
        <PointerTrigger>{dismissibleTrigger}</PointerTrigger>
      ) : (
        <Focusable>{dismissibleTrigger as FocusableChild}</Focusable>
      )}
      <HoverCardTooltip
        className={cx(
          "comma-hover-card z-50 w-[320px] rounded-xl border-[0.5px] border-primary bg-popup-primary p-sm shadow-lg outline-none",
          className
        )}
        boundaryRef={boundaryRef}
        data-instant={isInstant ? "true" : undefined}
        data-slot="hover-card"
        offset={spacing.md}
        onMouseEnter={() => {
          pointerOverCard.current = true;
        }}
        onMouseLeave={() => {
          pointerOverCard.current = false;
          updateOpen(false);
        }}
        placement={placement}
        ref={handleCardRef}
        {...(anchorRef ? { triggerRef: anchorRef } : {})}
      >
        {content}
      </HoverCardTooltip>
    </AriaTooltipTrigger>
  );
}

/**
 * Gives a pointer-only trigger the hover and press handlers of React Aria's
 * tooltip trigger, and makes its element the card's anchor. The tab stop, the
 * focus and keyboard handlers and `aria-describedby` are left out.
 */
function PointerTrigger({ children }: { children: ReactElement<TriggerProps> }) {
  const ref = useRef<HTMLElement | null>(null);
  // useFocusable reads the tooltip trigger's props and syncs its anchor ref.
  const { focusableProps } = useFocusable({}, ref);
  const pointerProps = Object.fromEntries(
    Object.entries(focusableProps).filter(([name]) =>
      /^on(?:Pointer|Mouse|Touch)/.test(name)
    )
  );
  return cloneElement(children, {
    ...mergeProps(pointerProps, children.props),
    ref: mergeRefs(children.props.ref, ref),
  });
}

const stopBubbling = (event: SyntheticEvent) => event.stopPropagation();

/** Presses in the card stop at its root. They keep their native defaults. */
const cardPressHandlers = {
  onAuxClick: stopBubbling,
  onClick: stopBubbling,
  onContextMenu: stopBubbling,
  onDoubleClick: stopBubbling,
  onMouseDown: stopBubbling,
  onPointerDown: stopBubbling,
};

type HoverCardTooltipProps = Omit<
  ComponentProps<typeof AriaTooltip>,
  "children" | "className"
> & {
  boundaryRef?: RefObject<Element | null> | undefined;
  children: ReactNode;
  className: string;
  "data-instant"?: string | undefined;
};

function HoverCardTooltip({ boundaryRef, ...props }: HoverCardTooltipProps) {
  if (!boundaryRef) return <AriaTooltip {...props} {...cardPressHandlers} />;
  return <BoundedTooltip {...props} boundaryRef={boundaryRef} />;
}

// Tooltip does not expose a collision boundary. Use its public hooks for
// bounded cards so React Aria still owns positioning and tooltip semantics.
function BoundedTooltip({
  boundaryRef,
  ref,
  ...props
}: HoverCardTooltipProps & { boundaryRef: RefObject<Element | null> }) {
  const [contextProps, tooltipRef] = useContextProps(
    props,
    ref ?? null,
    TooltipContext
  );
  const state = useContext(TooltipTriggerStateContext)!;
  if (!state.isOpen) return null;
  return (
    <OverlayContainer>
      <BoundedTooltipContent
        {...contextProps}
        boundaryRef={boundaryRef}
        ref={tooltipRef}
      />
    </OverlayContainer>
  );
}

function BoundedTooltipContent({
  boundaryRef,
  ref,
  ...props
}: HoverCardTooltipProps & { boundaryRef: RefObject<Element | null> }) {
  const overlayRef = useRef<HTMLDivElement>(null);
  const state = useContext(TooltipTriggerStateContext)!;
  const { overlayProps, placement } = useOverlayPosition({
    ...(boundaryRef.current ? { boundaryElement: boundaryRef.current } : {}),
    targetRef: props.triggerRef!,
    overlayRef,
    placement: props.placement ?? "bottom start",
    offset: props.offset ?? spacing.md,
    isOpen: state.isOpen,
    onClose: () => state.close(true),
  });
  const { tooltipProps } = useTooltip(props, state);
  const merged = mergeProps(tooltipProps, cardPressHandlers, {
    onMouseEnter: props.onMouseEnter,
    onMouseLeave: props.onMouseLeave,
  });
  return (
    <div
      {...merged}
      className={props.className}
      data-bounded="true"
      data-instant={props["data-instant"]}
      data-placement={placement ?? undefined}
      data-slot="hover-card"
      ref={(element) => {
        overlayRef.current = element;
        if (typeof ref === "function") return ref(element);
        if (ref) ref.current = element;
      }}
      style={{
        ...overlayProps.style,
        maxWidth: Math.max(0, (boundaryRef.current?.clientWidth ?? 344) - 24),
      }}
    >
      {props.children}
    </div>
  );
}
