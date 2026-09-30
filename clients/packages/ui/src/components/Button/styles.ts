import type { ButtonHierarchy, ButtonSize } from "./types";

export const baseClasses =
  "inline-flex items-center justify-center gap-1 font-medium transition-colors " +
  "focus:outline-none disabled:cursor-not-allowed whitespace-nowrap";

export const hierarchyClasses: Record<ButtonHierarchy, string> = {
  primary:
    "bg-button-primary-bg text-button-primary-fg border border-button-primary-border shadow-xs " +
    "hover:bg-button-primary-bg-hover hover:border-button-primary-border-hover " +
    "focus-visible:shadow-focus-brand-shadow-xs " +
    "disabled:bg-disabled disabled:border-secondary disabled:text-disabled disabled:shadow-none",
  "secondary-color":
    "bg-button-secondary-color-bg text-button-secondary-color-fg border border-button-secondary-color-border shadow-xs " +
    "hover:bg-button-secondary-color-bg-hover hover:text-button-secondary-color-fg-hover hover:border-button-secondary-color-border-hover " +
    "focus-visible:shadow-focus-brand-shadow-xs " +
    "disabled:bg-disabled disabled:border-secondary disabled:text-disabled",
  "secondary-gray":
    "bg-button-secondary-bg text-button-secondary-fg border border-button-secondary-border shadow-xs " +
    "hover:bg-secondary hover:text-primary " +
    "focus-visible:shadow-focus-gray-shadow-xs " +
    "disabled:bg-disabled disabled:border-secondary disabled:text-disabled",
  "tertiary-color":
    "bg-transparent text-button-tertiary-color-fg border border-transparent " +
    "hover:bg-button-tertiary-color-bg-hover hover:text-button-tertiary-color-fg-hover " +
    "focus-visible:shadow-focus-brand " +
    "disabled:text-disabled",
  "tertiary-gray":
    "bg-transparent text-button-tertiary-fg border border-transparent " +
    "[--comma-button-hover-bg:var(--color-button-tertiary-bg-hover)] [--comma-button-hover-fg:var(--color-button-tertiary-fg-hover)] " +
    "hover:bg-[var(--comma-button-hover-bg)] hover:text-[var(--comma-button-hover-fg)] " +
    "focus-visible:shadow-focus-gray " +
    "disabled:text-disabled",
  "link-color":
    "bg-transparent text-button-tertiary-color-fg border-0 shadow-none p-0 h-auto " +
    "hover:text-button-tertiary-color-fg-hover " +
    "focus-visible:shadow-focus-brand " +
    "disabled:text-disabled",
  "link-gray":
    "bg-transparent text-button-tertiary-fg border-0 shadow-none p-0 h-auto " +
    "hover:text-button-tertiary-fg-hover " +
    "focus-visible:shadow-focus-gray " +
    "disabled:text-disabled",
  destructive:
    "bg-button-primary-error-bg text-button-primary-error-fg border border-button-primary-error-border shadow-xs " +
    "hover:bg-button-primary-error-bg-hover hover:border-button-primary-error-border-hover " +
    "focus-visible:shadow-focus-error-shadow-xs " +
    "disabled:bg-error-200 disabled:border-error-200 disabled:text-white/70",
};

export const sizeClasses: Record<ButtonSize, string> = {
  xs: "h-4xl px-md text-sm rounded-md",
  sm: "h-9 px-3 text-sm rounded-md",
  md: "h-10 px-[14px] py-2.5 text-sm rounded-md",
  lg: "h-11 px-4 text-md rounded-md",
};

export const iconOnlySizeClasses: Record<ButtonSize, string> = {
  xs: "h-4xl w-4xl p-sm rounded-sm",
  sm: "h-9 w-9 p-2 rounded-sm",
  md: "h-10 w-10 p-2.5 rounded-sm",
  lg: "h-11 w-11 p-3 rounded-sm",
};

export const linkSizeClasses: Record<ButtonSize, string> = {
  xs: "text-sm",
  sm: "text-sm",
  md: "text-sm",
  lg: "text-md",
};

/** Status indicator shown before button label when `dotLeading` is set. */
export const dotSizeClasses: Record<ButtonSize, string> = {
  xs: "size-1.5",
  sm: "size-1.5",
  md: "size-2",
  lg: "size-2",
};

/** Icon slot scales with button size; child SVGs fill the slot. */
export const iconSlotClasses: Record<ButtonSize, string> = {
  xs: "comma-icon-slot inline-flex size-4 shrink-0 items-center justify-center [&_svg]:size-full",
  sm: "comma-icon-slot inline-flex size-4 shrink-0 items-center justify-center [&_svg]:size-full",
  md: "comma-icon-slot inline-flex size-5 shrink-0 items-center justify-center [&_svg]:size-full",
  lg: "comma-icon-slot inline-flex size-5 shrink-0 items-center justify-center [&_svg]:size-full",
};
