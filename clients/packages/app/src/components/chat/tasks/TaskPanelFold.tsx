import {
  useLayoutEffect,
  useState,
  useSyncExternalStore,
  type ReactNode,
  type RefObject,
} from "react";
import { useOptionalChatSidebar } from "../../chat-sidebar/ChatSidebarContext";
import { TaskDetailsPanel } from "./TaskDetailsPanel";
import { TaskDetailsPopover, type TaskDetailsPopoverProps } from "./TaskDetailsPopover";

/** Fallback when the theme does not expose the breakpoint token. */
const TASK_PANEL_COLLAPSE_FALLBACK_PX = 1024;

/**
 * Whether the Task details sit in their own column (`true`) or have folded
 * behind the header trigger. A window drag crosses the breakpoint mid-drag,
 * so the decision lives outside the route's React state: a fold re-renders
 * only its three readers (the body grid, the column, the folded trigger), not
 * the conversation that owns it.
 */
export interface TaskPanelFold {
  getSnapshot: () => boolean;
  subscribe: (listener: () => void) => () => void;
}

function createTaskPanelFold(): TaskPanelFold & { set: (open: boolean) => void } {
  let open = true;
  const listeners = new Set<() => void>();
  return {
    getSnapshot: () => open,
    set: (next) => {
      if (next === open) return;
      open = next;
      for (const listener of listeners) listener();
    },
    subscribe: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

/**
 * Folds the column below the `--container-2xl` breakpoint of its host. Width
 * is the only input: a folded route offers the details through the header
 * popover instead, so nothing here needs a manual override.
 *
 * The width is the host's settled one: while the Chat Sidebar beside it opens
 * or closes, the measured width is a frame of the sidebar's transition, and
 * folding on that squeezes the thread first and lets it spring back once the
 * fold lands. Subtracting the width the sidebar has yet to take
 * (`pendingTrailingWidth`) folds in the same frame the sidebar starts moving,
 * so the thread runs one monotonic reflow.
 */
export function useTaskPanelFold(
  hostRef: RefObject<HTMLElement | null>,
  enabled: boolean
): TaskPanelFold {
  const [fold] = useState(createTaskPanelFold);
  const sidebar = useOptionalChatSidebar();
  const trailingOpen = sidebar?.isOpen ?? false;
  const pendingTrailingWidth = sidebar?.pendingTrailingWidth;

  // A layout effect, and keyed on the sidebar's open state: the fold has to
  // be decided in the commit that starts the sidebar's transition, before the
  // first frame of it paints.
  useLayoutEffect(() => {
    if (!enabled) return undefined;
    const host = hostRef.current;
    if (!host || typeof ResizeObserver === "undefined") return undefined;

    const threshold = () => {
      const raw = getComputedStyle(host).getPropertyValue("--container-2xl");
      const parsed = Number.parseFloat(raw);
      return Number.isFinite(parsed) && parsed > 0
        ? parsed
        : TASK_PANEL_COLLAPSE_FALLBACK_PX;
    };
    // A host that has not been laid out yet (or is display:none) measures 0;
    // that is "unknown", not "narrow", so it never folds the panel.
    const measure = (width: number) => {
      const settled = width - (pendingTrailingWidth?.(host) ?? 0);
      if (settled > 0) fold.set(settled >= threshold());
    };

    measure(host.getBoundingClientRect().width);
    const observer = new ResizeObserver((entries) => {
      const entry = entries[0];
      if (entry) measure(entry.contentRect.width);
    });
    observer.observe(host);
    return () => observer.disconnect();
  }, [enabled, fold, hostRef, pendingTrailingWidth, trailingOpen]);

  return fold;
}

export function useTaskPanelOpen(fold: TaskPanelFold): boolean {
  return useSyncExternalStore(fold.subscribe, fold.getSnapshot, fold.getSnapshot);
}

/**
 * The Task body: the thread beside the details column. `children` is the
 * owner's element, so a fold reconciles this grid and the column only.
 */
export function TaskPanelBody({
  children,
  fold,
  floatingTrigger,
  panel,
}: {
  children: ReactNode;
  fold: TaskPanelFold;
  /**
   * The rail has no header row to hold the trigger, so once folded it floats
   * over the transcript's top-right corner instead of taking a row.
   */
  floatingTrigger: boolean;
  panel: TaskDetailsPopoverProps;
}) {
  const open = useTaskPanelOpen(fold);
  return (
    <div
      className="comma-chat-body"
      data-panel-open={open ? "true" : "false"}
      data-testid="task-conversation-body"
    >
      <div className="comma-chat-main">{children}</div>
      <TaskDetailsPanel {...panel} key={panel.conversation.id} open={open} />
      {floatingTrigger && !open ? (
        <div className="comma-task-panel-float">
          <TaskDetailsPopover {...panel} />
        </div>
      ) : null}
    </div>
  );
}

/** The header's details trigger, present only while the column is folded. */
export function TaskPanelFoldedTrigger({
  fold,
  panel,
}: {
  fold: TaskPanelFold;
  panel: TaskDetailsPopoverProps;
}) {
  return useTaskPanelOpen(fold) ? null : <TaskDetailsPopover {...panel} />;
}
