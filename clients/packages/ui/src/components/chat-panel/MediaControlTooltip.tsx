import type { ComponentProps, ReactNode } from "react";
import { Focusable } from "react-aria-components";
import { Tooltip } from "../tooltip";
import { useHoverOnlyTooltip } from "./useHoverOnlyTooltip";

export const mediaControlShortcuts = {
  play: "Space",
  mute: "M",
  playbackSpeed: ["<", ">"] as const,
} as const;

/**
 * A media control's tooltip: it opens on hover only, never on focus. While
 * `isDisabled`, it is closed and a hover does not open it.
 */
export const MediaControlTooltip = ({
  children,
  composite = false,
  content,
  isDisabled = false,
  placement = "top",
  shortcut,
}: {
  children: ReactNode;
  composite?: boolean;
  content: string;
  isDisabled?: boolean;
  placement?: "bottom" | "top";
  shortcut?: string | readonly string[];
}) => {
  const { isOpen, onOpenChange } = useHoverOnlyTooltip();

  return (
    <Tooltip
      content={content}
      isDisabled={isDisabled}
      isOpen={isOpen && !isDisabled}
      onOpenChange={onOpenChange}
      placement={placement}
      {...(shortcut === undefined ? {} : { shortcut })}
    >
      {composite ? (
        children
      ) : (
        <Focusable>
          {children as ComponentProps<typeof Focusable>["children"]}
        </Focusable>
      )}
    </Tooltip>
  );
};
