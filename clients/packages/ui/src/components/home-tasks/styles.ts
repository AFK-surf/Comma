/* Comma home Tasks rail section (Figma Comma-App 1036:28913 / 1036:28957). */

export const homeTasksRoot = "flex h-full min-h-0 flex-col";

// min-h-7 keeps the header box the height of an icon button, so the title
// centre line matches the Routines rail header even without an add button.
export const homeTasksHeader =
  "mb-lg flex min-h-7 shrink-0 items-center justify-between px-xs";

export const homeTasksTitle =
  "m-0 text-sm font-medium leading-5 tracking-[-0.14px] text-secondary";

export const homeTasksAddButton =
  "flex size-7 shrink-0 cursor-pointer items-center justify-center rounded-sm border-none bg-transparent p-0 text-sidebar-icon-primary outline-none transition-[background-color,box-shadow,scale] hover:bg-sidebar-bg-item focus-visible:shadow-focus-gray active:scale-[var(--motion-scale-tactile-pressed)]";

export const homeTasksAddIcon =
  "comma-icon-slot inline-flex size-5 items-center justify-center [&_svg]:size-full";

export const homeTasksViewport =
  "comma-home-tasks-viewport relative min-h-0 flex-1 overflow-hidden";

/* Each status page is its own ScrollArea so an outgoing panel keeps its
   scroll position while it slides away, and clipped cards fade through the
   shared eased edge mask instead of hitting a hard line. */
export const homeTasksPanel = "comma-home-tasks-panel h-full";

/* Horizontal padding keeps card focus rings inside the scrollport. */
export const homeTasksList = "m-0 flex list-none flex-col gap-md p-0 px-xs py-xs";

export const homeTasksItem = "comma-home-tasks-item";

/* Centered and balanced like the Tasks route's empty states, so the filtered
   copy stays readable if the rail is narrow enough to wrap it. */
export const homeTasksEmpty =
  "comma-home-tasks-empty m-0 flex h-full items-center justify-center px-xs text-balance text-center text-sm font-normal leading-5 text-quaternary";

export const homeTasksFooter =
  "comma-home-tasks-footer flex shrink-0 items-center justify-center pt-lg";

/* The rail card is the Tasks board card: the button owns the click target and
   the card's interactive affordances reach it through the shared group. */
export const homeTaskCardButton =
  "group/task-card w-full cursor-pointer border-0 bg-transparent p-0 text-left";
