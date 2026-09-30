export const menuSurfaceClasses =
  "rounded-xl border-[length:var(--border-width-0-5)] border-primary bg-popup-secondary text-sm text-secondary shadow-lg outline-none";

export const menuClasses = `w-60 py-sm ${menuSurfaceClasses}`;
/** Compact surface for short edit actions (Cut/Copy/Paste) — hug content instead of the task-menu width. */
export const menuCompactClasses = `w-fit min-w-44 py-sm ${menuSurfaceClasses}`;
export const menuEmbeddedClasses = "w-full outline-none";

export const menuItemGutterClasses = "px-sm";
export const menuItemRowChromeClasses = "rounded-sm px-md";

export const menuItemClasses = {
  root: "w-full outline-none",
  gutter: menuItemGutterClasses,
  content:
    "flex min-w-0 scale-100 select-none transition-[scale,background-color,color] duration-[var(--motion-duration-feedback-out)] ease-[var(--motion-easing-smooth-out)] motion-reduce:transition-none",
  row: `items-center gap-lg ${menuItemRowChromeClasses} py-sm font-medium`,
  sidebar:
    "text-sidebar-text-secondary duration-[var(--motion-duration-menu-exit)] ease-[var(--motion-easing-surface-smooth-out)]",
  tile: "min-h-[var(--spacing-7xl)] flex-col items-center justify-center rounded-sm bg-fg-button-secondary px-md py-sm text-sm font-medium text-primary shadow-xs ring-1 ring-primary ring-inset",
  interactive: "cursor-pointer",
  pressed:
    "scale-[var(--motion-scale-pressed)] duration-[var(--motion-duration-feedback-in)] motion-reduce:scale-100",
  tilePressed:
    "scale-[var(--motion-scale-tactile-pressed)] duration-[var(--motion-duration-feedback-in)] motion-reduce:scale-100",
  active: "bg-quaternary",
  activeSidebar: "bg-quaternary text-sidebar-text-highlight",
  activeDestructive: "bg-menu-hover-error",
  focused: "shadow-focus-gray",
  tileFocused: "shadow-focus-brand-shadow-xs",
  tileSelected: "bg-fg-button-active",
  disabled: "cursor-not-allowed opacity-50",
  destructive: "text-error-primary",
  leading: "flex min-w-0 flex-1 items-center gap-md",
  leadingTile: "flex min-w-0 flex-col items-center justify-center gap-xs",
  icon: "comma-icon-slot flex size-xl shrink-0 items-center justify-center [&_svg]:size-full",
  iconSidebar: "text-sidebar-icon-primary",
  iconTile:
    "comma-icon-slot flex size-2xl shrink-0 items-center justify-center [&_svg]:size-full",
  iconHovered: "text-fg-secondary",
  label: "min-w-0 flex-1 truncate",
  labelTile: "min-w-0 text-center",
  shortcut: "shrink-0 whitespace-nowrap text-xs font-regular text-quaternary",
} as const;

/**
 * The filter field a searchable surface opens with (Tasks status / worker,
 * the composer's Drive panel): a plain row flush with the surface, closed by
 * a hairline, with no box of its own.
 */
export const menuFilterFieldClasses =
  "rounded-none border-0 border-b-[length:var(--border-width-0-5)] border-primary bg-transparent shadow-none ring-0";

export const menuSeparatorClasses =
  "my-xs border-t-[length:var(--border-width-0-5)] border-primary";

export const menuPopoverClasses =
  "z-50 origin-[var(--trigger-anchor-point)] scale-100 translate-0 opacity-100 outline-none transition-[opacity,scale,translate] duration-[var(--motion-duration-menu-enter)] ease-[var(--motion-easing-surface-smooth-out)] motion-reduce:scale-100 motion-reduce:transition-none [-webkit-app-region:no-drag]";

export const menuPopoverFadeClasses =
  "z-50 opacity-100 outline-none transition-opacity duration-[var(--motion-duration-menu-enter)] ease-[var(--motion-easing-surface-smooth-out)] motion-reduce:transition-none [-webkit-app-region:no-drag]";

export const menuPopoverStaticClasses =
  "z-50 outline-none [-webkit-app-region:no-drag]";

export const menuPopoverStaticExitingClasses =
  "data-[exiting]:pointer-events-none opacity-0";

/**
 * Exit for a surface that opens in place over its own hidden trigger (the
 * selection-aligned select). Such a surface pairs this with
 * `menuPopoverStaticClasses` and has no entry: the checked row replaces the
 * trigger label pixel for pixel, so an entry fade dims that label for its whole
 * duration. Only the exit animates, over the trigger that is already back.
 */
export const menuPopoverInPlaceExitingClasses =
  "data-[exiting]:pointer-events-none opacity-0 transition-opacity duration-[var(--motion-duration-menu-exit)] ease-[var(--motion-easing-surface-smooth-out)] motion-reduce:transition-none";

export const menuPopoverEnteringClasses =
  "scale-[var(--motion-scale-menu-enter)] motion-safe:data-[placement=bottom]:-translate-y-[var(--motion-distance-menu-enter)] motion-safe:data-[placement=top]:translate-y-[var(--motion-distance-menu-enter)] motion-safe:data-[placement=right]:-translate-x-[var(--motion-distance-menu-enter)] motion-safe:data-[placement=left]:translate-x-[var(--motion-distance-menu-enter)] opacity-0 duration-[var(--motion-duration-menu-enter)]";

export const menuPopoverExitingClasses =
  "data-[exiting]:pointer-events-none scale-[var(--motion-scale-menu-exit)] opacity-0 duration-[var(--motion-duration-menu-exit)]";

export const menuPopoverFadeEnteringClasses =
  "opacity-0 duration-[var(--motion-duration-menu-enter)]";

export const menuPopoverFadeExitingClasses =
  "data-[exiting]:pointer-events-none opacity-0 duration-[var(--motion-duration-menu-exit)]";
