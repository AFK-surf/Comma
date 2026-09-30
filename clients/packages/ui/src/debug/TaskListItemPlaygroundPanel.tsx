import { Pane } from "tweakpane";
import { useEffect, useRef } from "react";
import type {
  ContentTaskIconState,
  SidebarRunIconState,
} from "../components/TaskListItem/taskListItemStoryIcons";

export type TaskListItemPlaygroundParams = {
  layout: "sidebar" | "content";
  contentIconState: ContentTaskIconState;
  sidebarIconState: SidebarRunIconState;
  dot: boolean;
  selected: boolean;
  tailMode: "none" | "sidebar-time" | "content-date" | "content-with-tag";
};

export const defaultTaskListItemPlaygroundParams: TaskListItemPlaygroundParams = {
  layout: "content",
  contentIconState: "review",
  sidebarIconState: "attention",
  dot: false,
  selected: true,
  tailMode: "content-with-tag",
};

export type TaskListItemPlaygroundPanelProps = {
  initial?: Partial<TaskListItemPlaygroundParams>;
  onChange: (params: TaskListItemPlaygroundParams) => void;
};

const contentIconOptions: Record<string, ContentTaskIconState> = {
  Backlog: "backlog",
  "In progress": "in-progress",
  "Needs review": "review",
  Done: "done",
  Cancel: "cancel",
};

const sidebarIconOptions: Record<string, SidebarRunIconState> = {
  Success: "success",
  "Needs attention": "attention",
  Failed: "failed",
};

/** Storybook-only debug panel for TaskListItem playground controls. */
export const TaskListItemPlaygroundPanel = ({
  initial,
  onChange,
}: TaskListItemPlaygroundPanelProps) => {
  const paneHostRef = useRef<HTMLDivElement>(null);
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  useEffect(() => {
    const host = paneHostRef.current;
    if (!host) return;

    const params: TaskListItemPlaygroundParams = {
      ...defaultTaskListItemPlaygroundParams,
      ...initial,
    };

    const pane = new Pane({
      title: "Task List Item",
      expanded: true,
    });
    pane.element.style.width = "280px";
    host.appendChild(pane.element);

    const sync = () => {
      onChangeRef.current({ ...params });
    };

    const layoutBinding = pane
      .addBinding(params, "layout", {
        label: "布局",
        options: {
          Sidebar: "sidebar",
          Content: "content",
        },
      })
      .on("change", sync);

    const contentIconBinding = pane
      .addBinding(params, "contentIconState", {
        label: "Content 状态",
        options: contentIconOptions,
      })
      .on("change", sync);

    const sidebarIconBinding = pane
      .addBinding(params, "sidebarIconState", {
        label: "Sidebar 状态",
        options: sidebarIconOptions,
      })
      .on("change", sync);

    const updateIconBindingVisibility = () => {
      const isSidebar = params.layout === "sidebar";
      contentIconBinding.hidden = isSidebar;
      sidebarIconBinding.hidden = !isSidebar;
    };

    layoutBinding.on("change", updateIconBindingVisibility);

    pane.addBinding(params, "dot", { label: "Dot (Sidebar)" }).on("change", sync);

    pane.addBinding(params, "selected", { label: "激活" }).on("change", sync);

    pane
      .addBinding(params, "tailMode", {
        label: "右侧内容",
        options: {
          无: "none",
          侧边栏时间: "sidebar-time",
          "Content 日期": "content-date",
          "Tag + 日期": "content-with-tag",
        },
      })
      .on("change", sync);

    updateIconBindingVisibility();
    sync();

    return () => {
      pane.dispose();
      host.replaceChildren();
    };
  }, [initial]);

  return <div ref={paneHostRef} className="fixed top-4 right-4 z-[9999] w-[280px]" />;
};
