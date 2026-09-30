import type { HTMLAttributes, ReactNode } from "react";
import { cx } from "../utils";

export interface ContentHeaderProps extends HTMLAttributes<HTMLElement> {
  children: ReactNode;
  /**
   * Makes non-interactive header content part of the native window drag region.
   * Links, buttons, and form controls remain interactive no-drag regions.
   */
  windowDragRegion?: boolean;
}

/**
 * Shared top bar for primary content surfaces.
 *
 * The window bar above the shell owns the macOS window controls, so this
 * header only has to keep its own 44px row and gutters.
 */
export const ContentHeader = ({
  children,
  className,
  windowDragRegion = true,
  ...rest
}: ContentHeaderProps) => (
  <header
    className={cx(
      "comma-content-header flex h-11 w-full shrink-0 items-center gap-md border-b-[0.5px] border-primary pl-xl pr-xl",
      className
    )}
    data-slot="content-header"
    data-window-drag-region={windowDragRegion ? "true" : "false"}
    {...rest}
  >
    {children}
  </header>
);
