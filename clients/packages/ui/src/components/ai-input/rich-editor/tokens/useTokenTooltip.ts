import {
  useCallback,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type RefObject,
} from "react";
import type { AiInputRichTokenSegment } from "../../richText";
import { closestTokenElement } from "./tokenElement";

const TOKEN_TOOLTIP_OFFSET_PX = 8;

interface TokenTooltip {
  title: string;
  description: string;
  anchorTop: number;
  anchorBottom: number;
  left: number;
  top: number;
  placement: "above" | "below";
  isOpen: boolean;
  shouldAnimate: boolean;
}

export const CLOSED_TOKEN_TOOLTIP: TokenTooltip = {
  title: "",
  description: "",
  anchorTop: 0,
  anchorBottom: 0,
  left: 0,
  top: 0,
  placement: "above",
  isOpen: false,
  shouldAnimate: false,
};

export type TokenTooltipState = ReturnType<typeof useTokenTooltip>;

/**
 * The description tooltip for the token under the pointer or focus. It opens
 * above the token and, once measured, flips below when there is no room.
 */
export function useTokenTooltip(
  tokenMapRef: RefObject<Map<string, AiInputRichTokenSegment>>
) {
  const tokenTooltipRef = useRef<HTMLDivElement | null>(null);
  const [tokenTooltip, setTokenTooltip] = useState<TokenTooltip>(CLOSED_TOKEN_TOOLTIP);
  const tokenTooltipId = useId();

  useLayoutEffect(() => {
    if (!tokenTooltip.isOpen || !tokenTooltipRef.current) return;

    const tooltipHeight = tokenTooltipRef.current.getBoundingClientRect().height;
    const placement =
      tokenTooltip.anchorTop - TOKEN_TOOLTIP_OFFSET_PX >= tooltipHeight
        ? "above"
        : "below";
    const top =
      placement === "above"
        ? tokenTooltip.anchorTop - TOKEN_TOOLTIP_OFFSET_PX
        : tokenTooltip.anchorBottom + TOKEN_TOOLTIP_OFFSET_PX;

    if (placement === tokenTooltip.placement && top === tokenTooltip.top) return;
    setTokenTooltip((current) => ({ ...current, placement, top }));
  }, [tokenTooltip]);

  const hideTokenTooltip = useCallback((shouldAnimate: boolean) => {
    setTokenTooltip((current) => ({ ...current, isOpen: false, shouldAnimate }));
  }, []);

  const showTokenTooltip = (target: EventTarget | null, shouldAnimate: boolean) => {
    const tokenElement = closestTokenElement(target);
    const tokenId = tokenElement?.dataset.aiInputToken;
    const token = tokenId ? tokenMapRef.current.get(tokenId) : undefined;
    if (!tokenElement || !token?.description) {
      hideTokenTooltip(shouldAnimate);
      return;
    }

    const bounds = tokenElement.getBoundingClientRect();
    setTokenTooltip({
      title: token.label,
      description: token.description,
      anchorTop: bounds.top,
      anchorBottom: bounds.bottom,
      left: Math.min(
        Math.max(bounds.left + bounds.width / 2, 158),
        window.innerWidth - 158
      ),
      top: bounds.top - TOKEN_TOOLTIP_OFFSET_PX,
      placement: "above",
      isOpen: true,
      shouldAnimate,
    });
  };

  return {
    hideTokenTooltip,
    setTokenTooltip,
    showTokenTooltip,
    tokenTooltip,
    tokenTooltipId,
    tokenTooltipRef,
  };
}
