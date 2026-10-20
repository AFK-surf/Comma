import type { ReactNode } from "react";
import { BubbleAlertIcon, CircleCheckIcon, CircleXIcon, LoaderIcon } from "../icons";

export type ContentTaskIconState = "in-progress" | "review" | "done" | "cancel";

export type SidebarRunIconState = "success" | "attention" | "failed";

type IconStateDefinition = {
  label: string;
  renderIcon: () => ReactNode;
};

export const contentTaskIconStates: Record<ContentTaskIconState, IconStateDefinition> =
  {
    "in-progress": {
      label: "In progress",
      renderIcon: () => <LoaderIcon className="text-sidebar-icon-secondary" />,
    },
    review: {
      label: "Needs review",
      renderIcon: () => <BubbleAlertIcon className="text-fg-warning-secondary" />,
    },
    done: {
      label: "Done",
      renderIcon: () => <CircleCheckIcon className="text-fg-success-primary" />,
    },
    cancel: {
      label: "Cancel",
      renderIcon: () => <CircleXIcon className="text-fg-error-primary" />,
    },
  };

export const sidebarRunIconStates: Record<SidebarRunIconState, IconStateDefinition> = {
  success: {
    label: "Success",
    renderIcon: () => <CircleCheckIcon className="text-fg-success-primary" />,
  },
  attention: {
    label: "Needs attention",
    renderIcon: () => <BubbleAlertIcon className="text-fg-warning-secondary" />,
  },
  failed: {
    label: "Failed",
    renderIcon: () => <CircleXIcon className="text-fg-error-primary" />,
  },
};

export const resolveTaskListItemStoryIcon = (
  layout: "sidebar" | "content",
  contentIconState: ContentTaskIconState | undefined,
  sidebarIconState: SidebarRunIconState | undefined
) => {
  if (layout === "sidebar") {
    const state =
      sidebarRunIconStates[sidebarIconState ?? "success"] ??
      sidebarRunIconStates.success;
    return { label: state.label, icon: state.renderIcon() };
  }

  const state =
    contentTaskIconStates[contentIconState ?? "in-progress"] ??
    contentTaskIconStates["in-progress"];
  return { label: state.label, icon: state.renderIcon() };
};
