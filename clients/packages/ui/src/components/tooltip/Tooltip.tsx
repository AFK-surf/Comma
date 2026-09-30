import {
  Children,
  cloneElement,
  isValidElement,
  useCallback,
  useRef,
  useState,
  type FocusEventHandler,
  type ReactNode,
  type RefObject,
} from "react";
import type { TooltipProps as AriaTooltipProps } from "react-aria-components";
import {
  Tooltip as AriaTooltip,
  TooltipTrigger as AriaTooltipTrigger,
} from "react-aria-components";
import { cx } from "../utils";
import { motionDuration } from "../../tokens/motion";
import { spacing } from "../../tokens/spacing";
import { TooltipBubble, type TooltipRow } from "./TooltipBubble";

export type TooltipPlacement = "top" | "bottom" | "left" | "right";

/** @deprecated Prefer `placement`, which names the tooltip's location directly. */
export type TooltipArrow = TooltipPlacement;

const placementMap: Record<TooltipArrow, NonNullable<AriaTooltipProps["placement"]>> = {
  bottom: "top",
  top: "bottom",
  left: "right",
  right: "left",
};

export type { TooltipRow, TooltipShortcutKey } from "./TooltipBubble";

export interface TooltipProps {
  content: ReactNode;
  supportingText?: ReactNode;
  shortcut?: string | readonly string[];
  suffix?: ReactNode;
  rows?: readonly TooltipRow[];
  placement?: TooltipPlacement;
  /** @deprecated Prefer `placement`, which names the tooltip's location directly. */
  arrow?: TooltipArrow;
  defaultOpen?: boolean;
  isOpen?: boolean;
  isDisabled?: boolean;
  onOpenChange?: (isOpen: boolean) => void;
  delay?: number;
  closeDelay?: number;
  className?: string;
  /** Explicit positioning anchor for controlled composite triggers. */
  triggerRef?: RefObject<Element | null>;
  children: ReactNode;
}

interface ActiveTooltip {
  id: symbol;
  makeInstant: () => void;
}

// React Aria owns visibility and delay state; Comma only coordinates motion between
// the surfaces that are actually mounted during an adjacent handoff.
let activeTooltip: ActiveTooltip | null = null;

const wrapTrigger = (
  children: ReactNode,
  className: string | undefined,
  onFocus: FocusEventHandler<HTMLElement>
) => {
  const child = Children.only(children);
  if (
    !isValidElement<{
      className?: string;
      onFocus?: FocusEventHandler<HTMLElement>;
    }>(child)
  ) {
    return children;
  }

  const childOnFocus = child.props.onFocus;

  return cloneElement(child, {
    ...(className ? { className: cx(className, child.props.className) } : undefined),
    onFocus: (event) => {
      childOnFocus?.(event);
      onFocus(event);
    },
  });
};

/** Displays a concise label and optional key sequence on hover or keyboard focus. */
export const Tooltip = ({
  content,
  supportingText,
  shortcut,
  suffix,
  rows,
  placement,
  arrow,
  defaultOpen = false,
  isOpen,
  isDisabled = false,
  onOpenChange,
  delay = 300,
  closeDelay = motionDuration.tooltipHandoff,
  className,
  triggerRef,
  children,
}: TooltipProps) => {
  const [isInstant, setIsInstant] = useState(
    defaultOpen || isOpen === true || delay === 0
  );
  const tooltipId = useRef(Symbol("comma-tooltip"));
  const opensWithoutMotion = useRef(false);
  const id = tooltipId.current;
  const resolvedPlacement = placement ?? (arrow ? placementMap[arrow] : "bottom");
  const makeInstant = useCallback(() => setIsInstant(true), []);
  const handleTriggerFocus = useCallback<FocusEventHandler<HTMLElement>>((event) => {
    if (!event.currentTarget.matches(":focus-visible")) return;
    opensWithoutMotion.current = true;
    setIsInstant(true);
  }, []);
  const handleTooltipRef = useCallback(
    (element: HTMLDivElement | null) => {
      if (element) {
        activeTooltip = { id, makeInstant };
      } else if (activeTooltip?.id === id) {
        activeTooltip = null;
      }
    },
    [id, makeInstant]
  );

  const handleOpenChange = (nextOpen: boolean) => {
    if (nextOpen) {
      const previousTooltip = activeTooltip;
      if (previousTooltip?.id !== id) previousTooltip?.makeInstant();

      setIsInstant(
        opensWithoutMotion.current || delay === 0 || previousTooltip !== null
      );
      opensWithoutMotion.current = false;
    } else {
      opensWithoutMotion.current = false;
    }

    onOpenChange?.(nextOpen);
  };

  return (
    <AriaTooltipTrigger
      delay={delay}
      closeDelay={closeDelay}
      isDisabled={isDisabled}
      onOpenChange={handleOpenChange}
      {...(isOpen === undefined ? { defaultOpen } : { isOpen })}
    >
      {wrapTrigger(children, className, handleTriggerFocus)}
      <AriaTooltip
        data-instant={isInstant ? "true" : undefined}
        data-side={resolvedPlacement}
        placement={resolvedPlacement}
        offset={spacing.xs}
        {...(triggerRef ? { triggerRef } : {})}
        ref={handleTooltipRef}
        className="comma-tooltip outline-none"
      >
        <TooltipBubble
          content={content}
          supportingText={supportingText}
          {...(shortcut !== undefined ? { shortcut } : {})}
          {...(suffix !== undefined ? { suffix } : {})}
          {...(rows !== undefined ? { rows } : {})}
        />
      </AriaTooltip>
    </AriaTooltipTrigger>
  );
};
