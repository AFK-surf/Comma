import {
  LEFT_RAIL_WIDTH,
  RIGHT_SIDEBAR_DEFAULT_WIDTH,
  RIGHT_SIDEBAR_MAX_WIDTH,
  RIGHT_SIDEBAR_MIN_WIDTH,
} from "@comma/ui";

// The app sidebar is a fixed icon rail beside the content panel; the window
// bar above both spans the whole frame, so no shell width depends on sidebar
// state.
export const commaSidebarRailWidth = LEFT_RAIL_WIDTH;
export const commaChatSidebarDefaultWidth = RIGHT_SIDEBAR_DEFAULT_WIDTH;
export const commaChatSidebarMinWidth = RIGHT_SIDEBAR_MIN_WIDTH;
export const commaChatSidebarMaxWidth = RIGHT_SIDEBAR_MAX_WIDTH;
export const commaDefaultPrimaryContentMinWidth = 240;
// Home keeps its chat column at least this wide; below that the rails are
// eaten by the drag (see .comma-home-layout in styles.css) and the Chat Sidebar
// yields once the route would drop below chat-min plus the layout's two
// gutters.
export const commaHomeChatMinWidth = 393;
export const commaHomeLayoutGutter = 16;
export const commaHomeContentMinWidth =
  commaHomeChatMinWidth + commaHomeLayoutGutter * 2;
// Home rails may shrink below their preferred width without squeezing chat.
export const commaHomeRailMinWidth = 240;
export const commaHomeGreetPreferredMinWidth = 300;
export const commaHomeTasksPreferredWidth = 300;
export const commaHomeGreetFoldWidth =
  commaHomeContentMinWidth + commaHomeRailMinWidth + commaHomeLayoutGutter;
export const commaHomeTasksFoldWidth =
  commaHomeGreetFoldWidth + commaHomeGreetPreferredMinWidth + commaHomeLayoutGutter;
export const commaHomeTasksFullWidth =
  commaHomeTasksFoldWidth + commaHomeTasksPreferredWidth - commaHomeRailMinWidth;

export type CommaHomeRailName = "greet" | "tasks";

export interface CommaHomeRailFolds {
  greet: boolean;
  tasks: boolean;
}

export const commaHomeRailFoldsOpen: CommaHomeRailFolds = {
  greet: false,
  tasks: false,
};

/**
 * A rail is out of the layout when the route cannot hold it (`folds`) or when
 * the reader shut it from its edge handle (`collapsed`). The layout combines
 * both causes before it assigns space. Both use the same fold transition.
 */
export function mergeHomeRailFolds(
  folds: CommaHomeRailFolds,
  collapsed: CommaHomeRailFolds
): CommaHomeRailFolds {
  if (!collapsed.greet && !collapsed.tasks) return folds;
  return {
    greet: folds.greet || collapsed.greet,
    tasks: folds.tasks || collapsed.tasks,
  };
}

/**
 * A rail folds exactly at the route width where it can no longer hold its
 * 240px content floor beside the chat column's, and comes back the moment it
 * fits again.
 *
 * No hysteresis: the threshold is a hard geometric constraint in both
 * directions, and holding a rail shut at a width it fits in is a worse lie
 * than the wobble a hand parked on the threshold could produce. Folding does
 * not change the route width either, so there is no feedback loop to damp —
 * only literal jitter, which the fold's own transition smooths.
 */
export function resolveHomeRailFolds({
  previous,
  routeWidth,
  greetWidth = commaHomeGreetPreferredMinWidth,
  greetCollapsed = false,
}: {
  greetWidth?: number;
  greetCollapsed?: boolean;
  previous: CommaHomeRailFolds;
  routeWidth: number;
}): CommaHomeRailFolds {
  const greet = routeWidth < commaHomeGreetFoldWidth;
  const tasks =
    routeWidth <
    commaHomeGreetFoldWidth + (greetCollapsed ? 0 : greetWidth + commaHomeLayoutGutter);
  if (greet === previous.greet && tasks === previous.tasks) return previous;
  return { greet, tasks };
}

/**
 * The Chat Sidebar may grow until the product route reaches its declared
 * minimum (e.g. Home's 393px chat column + gutters). Derived from the window
 * frame rather than the content box, minus the fixed app rail. An unmeasured
 * frame leaves the sidebar at its default maximum.
 */
export function chatSidebarMaxWidthForFrame({
  appSidebarFloor,
  frameWidth,
  primaryContentMinWidth,
}: {
  appSidebarFloor: number;
  frameWidth: number;
  primaryContentMinWidth: number;
}) {
  if (frameWidth <= 0) return undefined;
  return Math.max(
    commaChatSidebarMinWidth,
    Math.floor(frameWidth - appSidebarFloor - primaryContentMinWidth)
  );
}

/**
 * Whether the frame holds the rail beside the route's minimum and, while the
 * Chat Sidebar is open, that sidebar's minimum as well. Below that the rail
 * yields its column, the way the wide sidebar used to auto-collapse in a
 * narrow window. An unmeasured frame keeps the rail.
 */
export function railFitsFrame({
  chatSidebarOpen,
  frameWidth,
  primaryContentMinWidth,
}: {
  chatSidebarOpen: boolean;
  frameWidth: number;
  primaryContentMinWidth: number;
}) {
  if (frameWidth <= 0) return true;
  const trailingMinWidth = chatSidebarOpen ? commaChatSidebarMinWidth : 0;
  return (
    frameWidth >= commaSidebarRailWidth + primaryContentMinWidth + trailingMinWidth
  );
}

export const commaInboxConversationRailWidth = 320;
/** Drive's space rail; the file list keeps the default minimum beside it. */
export const commaDriveSpaceRailWidth = 320;
