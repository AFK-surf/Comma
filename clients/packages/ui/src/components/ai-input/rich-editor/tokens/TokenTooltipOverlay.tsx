import { Overlay } from "react-aria";
import {
  aiInputRichTokenTooltip,
  aiInputRichTokenTooltipPositioner,
  aiInputRichTokenTooltipText,
  aiInputRichTokenTooltipTitle,
} from "../../styles";
import type { TokenTooltipState } from "./useTokenTooltip";

/** The token tooltip, portaled so the editor's overflow never clips it. */
export const TokenTooltipOverlay = ({
  tooltip: { tokenTooltip, tokenTooltipId, tokenTooltipRef },
}: {
  tooltip: TokenTooltipState;
}) => (
  <Overlay disableFocusManagement>
    <div
      className={aiInputRichTokenTooltipPositioner}
      style={{
        left: tokenTooltip.left,
        top: tokenTooltip.top,
        transform:
          tokenTooltip.placement === "above"
            ? "translate(-50%, -100%)"
            : "translate(-50%, 0)",
      }}
    >
      <div
        aria-hidden={!tokenTooltip.isOpen}
        className={aiInputRichTokenTooltip}
        data-animate={String(tokenTooltip.shouldAnimate)}
        data-placement={tokenTooltip.placement}
        data-state={tokenTooltip.isOpen ? "open" : "closed"}
        id={tokenTooltipId}
        ref={tokenTooltipRef}
        role="tooltip"
      >
        <span className={aiInputRichTokenTooltipTitle}>{tokenTooltip.title}</span>
        <span className={aiInputRichTokenTooltipText}>{tokenTooltip.description}</span>
      </div>
    </div>
  </Overlay>
);
