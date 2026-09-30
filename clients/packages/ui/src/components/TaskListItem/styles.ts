export type TaskListItemLayout = "sidebar" | "content";

const taskListItemRootBase =
  "flex w-full items-center gap-lg overflow-hidden rounded-xl text-sm leading-5 tracking-[-0.14px] outline-none";

export const taskListItemRootByLayout: Record<TaskListItemLayout, string> = {
  content: `${taskListItemRootBase} min-h-11 gap-lg p-lg`,
  sidebar: `${taskListItemRootBase} gap-lg px-lg py-md`,
};

export const taskListItemRoot = taskListItemRootByLayout.content;

export const taskListItemInteractive = "hover:bg-sidebar-bg-item";

export const taskListItemSelected = "bg-sidebar-bg-item";

/** Checked into a multi-selection: a thin brand wash over the whole row, chips included, a little deeper on hover. */
export const taskListItemChecked =
  "relative after:pointer-events-none after:absolute after:inset-0 after:bg-utility-brand-50/30 after:content-[''] hover:after:bg-utility-brand-50/45";

export const taskListItemDisabled = "cursor-not-allowed opacity-60";

export const taskListItemSidebarMain =
  "flex min-w-0 flex-1 items-center overflow-hidden text-primary";

export const taskListItemContentMain =
  "flex min-w-0 flex-1 items-center gap-md text-primary";

/** Invisible 18px slot that mirrors the group header chevron so row icons align under it. */
export const taskListItemContentHandle = "size-[18px] shrink-0 opacity-0";

export const taskListItemIconSlot =
  "comma-icon-slot task-list-item-icon-stage inline-flex shrink-0 items-center justify-center [&_svg]:size-full";

export const taskListItemIconSlotByLayout: Record<TaskListItemLayout, string> = {
  content: "size-[18px]",
  sidebar: "size-5 mr-2",
};

export const taskListItemIconLayer =
  "task-list-item-icon-layer inline-flex size-full items-center justify-center";

export const taskListItemDotTrack =
  "task-list-item-dot-track inline-flex shrink-0 items-center";

export const taskListItemDotInner =
  "task-list-item-dot-inner inline-flex shrink-0 items-center";

// Same blue as the chat task panel's attention dot (Figma 1364:12149).
export const taskListItemDot = "size-2 shrink-0 rounded-full bg-utility-brand-400";

export const taskListItemTitleByLayout: Record<TaskListItemLayout, string> = {
  content: "min-w-0 flex-1 truncate text-left font-medium text-primary",
  sidebar: "min-w-0 flex-1 truncate text-left font-normal text-primary",
};

export const taskListItemTitle = taskListItemTitleByLayout.content;

/**
 * Chips between the title and the date. Wide rows keep them whole and let the
 * title truncate; the list's compact container state (app styles) lets them
 * shrink, overlap and fold instead.
 */
export const taskListItemBadges = "flex shrink-0 items-center gap-xs";

export const taskListItemTailContents = "contents";

export const taskListItemTailDate =
  "shrink-0 whitespace-nowrap font-normal text-quaternary";

export const taskListItemTailByLayout: Record<TaskListItemLayout, string> = {
  content: taskListItemTailDate,
  sidebar:
    "flex shrink-0 items-center gap-md whitespace-nowrap font-medium text-quaternary",
};

export const taskListItemTail = taskListItemTailByLayout.content;

export type TaskListGroupAccent = "neutral" | "warning" | "success" | "error";

export const taskListGroupRoot = "flex w-full flex-col gap-xxs";

export const taskListGroupHeader =
  "flex w-full items-center rounded-md px-lg py-md text-left outline-none focus-visible:shadow-focus-gray";

export const taskListGroupHeaderAccent: Record<TaskListGroupAccent, string> = {
  neutral: "bg-secondary",
  warning:
    "bg-[linear-gradient(90deg,var(--color-todo-list-bg-needs-review-main)_-8.01%,var(--color-todo-list-bg-group-fade)_27.82%,var(--color-todo-list-bg-group-fade)_100%)]",
  success:
    "bg-[linear-gradient(90deg,var(--color-todo-list-bg-done)_-8.01%,var(--color-todo-list-bg-group-fade)_27.82%,var(--color-todo-list-bg-group-fade)_100%)]",
  error:
    "bg-[linear-gradient(90deg,var(--color-todo-list-bg-cancel)_-8.01%,var(--color-todo-list-bg-group-fade)_27.82%,var(--color-todo-list-bg-group-fade)_100%)]",
};

export const taskListGroupHeaderInner = "flex min-w-0 items-center gap-md";

export const taskListGroupChevron =
  "comma-icon-slot inline-flex size-[18px] shrink-0 items-center justify-center text-quaternary transition-transform [&_svg]:size-full";

export const taskListGroupChevronCollapsed = "rotate-180";

export const taskListGroupIcon =
  "comma-icon-slot inline-flex size-[18px] shrink-0 items-center justify-center [&_svg]:size-full";

export const taskListGroupLabel =
  "truncate text-sm font-medium leading-5 tracking-[-0.14px] text-primary";

export const taskListGroupCount =
  "shrink-0 font-mono text-sm leading-5 text-quaternary tabular-nums";

export const taskListGroupBody = "flex flex-col";
