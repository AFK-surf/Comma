import {
  OverlayContainer,
  mergeProps,
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
  type ReactElement,
  type ReactNode,
  type RefObject,
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
import { spacing } from "../../tokens/spacing";

type FocusableChild = ComponentProps<typeof Focusable>["children"];

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
  placement?: NonNullable<AriaTooltipProps["placement"]>;
}

/**
 * A non-interactive rich preview for a link or button. React Aria owns hover,
 * keyboard focus, Escape dismissal, portal placement, and screen-reader
 * tooltip semantics; Focusable bridges those props onto arbitrary triggers.
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
  placement = "bottom start",
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

  const trigger = children as ReactElement<HTMLAttributes<HTMLElement>>;
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
  });
  return (
    <AriaTooltipTrigger
      closeDelay={closeDelay}
      delay={delay}
      isOpen={isOpen}
      onOpenChange={handleOpenChange}
    >
      <Focusable>{dismissibleTrigger as FocusableChild}</Focusable>
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
  if (!boundaryRef) return <AriaTooltip {...props} />;
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
  const merged = mergeProps(tooltipProps, {
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
