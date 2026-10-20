import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import { expect, userEvent, waitFor, within } from "storybook/test";
import { HomeTaskCard } from "../home-tasks";
import type { VisibleTaskStatusBucket } from "@comma/i18n";
import type { TaskSummaryViewModel } from "../task-workspace";
import { indicatorIdToTaskStatus, taskStatusToIndicatorId } from "./statusMapping";
import { loadStatusIndicatorElement, StatusIndicator } from "./StatusIndicator";
import {
  StatusIndicatorPreview,
  statusIds,
  type StatusIndicatorElement,
} from "./StatusIndicatorPreview";

const meta = {
  title: "App components/Status Indicator",
  component: StatusIndicatorPreview,
  args: {
    value: "in-progress",
  },
  argTypes: {
    value: {
      control: "select",
      options: statusIds,
    },
  },
  loaders: [loadStatusIndicatorElement],
  parameters: {
    layout: "centered",
    docs: {
      description: {
        component:
          "Dependency-free Web Component from [zanwei/status-indicator-web-component](https://github.com/zanwei/status-indicator-web-component), themed with Comma Storybook tokens.",
      },
    },
  },
} satisfies Meta<typeof StatusIndicatorPreview>;

export default meta;
type Story = StoryObj<typeof meta>;

export const Default: Story = {};

export const KeyboardNavigation: Story = {
  play: async ({ canvasElement }) => {
    await waitFor(() => {
      expect(canvasElement.querySelector("status-indicator")).not.toBeNull();
    });
    const indicator =
      canvasElement.querySelector<StatusIndicatorElement>("status-indicator");
    await expect(indicator?.value).toBe("in-progress");
    await expect(indicator?.style.getPropertyValue("--si-pill-bg")).toBe(
      "var(--color-bg-quaternary)"
    );

    const selectedStatus = indicator?.shadowRoot?.querySelector<HTMLButtonElement>(
      '[role="radio"][aria-checked="true"]'
    );

    await expect(selectedStatus).not.toBeNull();
    await expect(
      indicator?.shadowRoot?.querySelector(".icon svg path")
    ).toHaveAttribute("stroke-width", "2");
    await expect(indicator?.shadowRoot?.querySelector(".glyph--spin")).toBeNull();
    await expect(indicator?.shadowRoot?.querySelector("path.check")).toBeNull();
    await expect(indicator?.style.getPropertyValue("--si-focus-ring")).toBe(
      "var(--color-fg-primary)"
    );
    selectedStatus?.focus();
    await userEvent.keyboard("{End}");
    await expect(indicator?.value).toBe("cancel");
    await expect(
      indicator?.shadowRoot?.querySelector('[role="radio"][aria-checked="true"]')
    ).toHaveTextContent("Cancel");
    await userEvent.keyboard("{Home}");
    await expect(indicator?.value).toBe("in-progress");
    await expect(
      indicator?.shadowRoot?.querySelector('[role="radio"][aria-checked="true"]')
    ).toHaveTextContent("In progress");

    const finalSelectedStatus = indicator?.shadowRoot?.querySelector<HTMLButtonElement>(
      '[role="radio"][aria-checked="true"]'
    );
    await expect(indicator?.shadowRoot?.activeElement).toBe(finalSelectedStatus);
    finalSelectedStatus?.blur();
    await expect(indicator?.shadowRoot?.activeElement).toBeNull();
  },
};

const boundTasks: TaskSummaryViewModel[] = [
  {
    activityStatus: "running",
    freshness: "fresh",
    id: "bound-progress",
    statusBucket: "in_progress",
    title: "Summarizing recent OpenAI's update and create a HTML",
    updatedAt: 1_778_025_600,
    worker: "claude",
  },
  {
    activityStatus: "ready_for_review",
    freshness: "fresh",
    id: "bound-review",
    statusBucket: "needs_review",
    title: "Review the launch checklist for the mobile beta",
    updatedAt: 1_778_112_000,
  },
  {
    activityStatus: "done",
    freshness: "fresh",
    id: "bound-done",
    statusBucket: "done",
    title: "Collect design tokens for the marketing site refresh",
    updatedAt: 1_778_198_400,
  },
  {
    activityStatus: "cancelled",
    freshness: "fresh",
    id: "bound-cancelled",
    statusBucket: "cancelled",
    title: "Spike the abandoned migration path",
    updatedAt: 1_778_284_800,
  },
];

function StatusIndicatorWithTasks() {
  const [bucket, setBucket] = useState<VisibleTaskStatusBucket>("in_progress");
  const visible = boundTasks.filter((task) => task.statusBucket === bucket);

  return (
    <div
      style={{
        display: "grid",
        gap: "var(--spacing-2xl)",
        inlineSize: 320,
      }}
    >
      <ul
        data-testid="bound-task-list"
        style={{
          display: "grid",
          gap: "var(--spacing-md)",
          listStyle: "none",
          margin: 0,
          minBlockSize: 96,
          padding: 0,
        }}
      >
        {visible.map((task) => (
          <li key={task.id}>
            <HomeTaskCard onOpen={() => undefined} task={task} />
          </li>
        ))}
      </ul>
      <div style={{ display: "flex", justifyContent: "center" }}>
        <StatusIndicator
          onChange={(id) => setBucket(indicatorIdToTaskStatus(id))}
          value={taskStatusToIndicatorId(bucket)}
        />
      </div>
    </div>
  );
}

export const WithTasks: Story = {
  parameters: {
    docs: {
      description: {
        story:
          "The indicator bound to task status buckets: `taskStatusToIndicatorId` / `indicatorIdToTaskStatus` map `TaskStatusBucket` values onto the indicator's segment ids, so selecting a segment filters the task cards. This is the binding the Comma home Tasks rail uses.",
      },
    },
  },
  render: () => <StatusIndicatorWithTasks />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    await waitFor(() => {
      expect(canvas.getAllByTestId("home-task-card")).toHaveLength(1);
    });
    await expect(canvas.getByTestId("home-task-card")).toHaveTextContent(
      "Summarizing recent OpenAI's update and create a HTML"
    );

    await waitFor(() => {
      const lazy =
        canvasElement.querySelector<StatusIndicatorElement>("status-indicator");
      expect(lazy?.shadowRoot?.querySelectorAll('[role="radio"]')).toHaveLength(4);
    });
    const indicator =
      canvasElement.querySelector<StatusIndicatorElement>("status-indicator");
    const segments =
      indicator?.shadowRoot?.querySelectorAll<HTMLElement>('[role="radio"]');
    await userEvent.click(segments![1]!);

    await waitFor(() => {
      expect(canvas.getByTestId("home-task-card")).toHaveTextContent(
        "Review the launch checklist for the mobile beta"
      );
    });
    await expect(indicator?.value).toBe("needs-review");
  },
};

export const KeyboardShortcuts: Story = {
  parameters: {
    docs: {
      description: {
        story:
          "Each status is available through its global macOS Option shortcut while the indicator is mounted: ⌥1 through ⌥4. The shortcut changes the bound task bucket without moving focus. In a text field, such as the composer, a key that types an ASCII character, a letter, a quotation mark or a dead key types it: on a Mac, Option+2 types @ in Swedish and “ in German. Rare symbols such as the US layout's ¡ ™ £ ¢ stay with the shortcut. On Windows and Linux, where Alt with a digit types nothing, the shortcut always runs.",
      },
    },
  },
  render: () => (
    <div
      style={{
        display: "grid",
        gap: "var(--spacing-2xl)",
        inlineSize: 320,
      }}
    >
      <div
        aria-label="Shortcut focus target"
        contentEditable
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a rich text field, as the composer is; an input or textarea is not one.
        role="textbox"
        style={{
          border: "var(--border-width-1) solid var(--color-border-primary)",
          borderRadius: "var(--radius-md)",
          padding: "var(--spacing-md)",
        }}
        suppressContentEditableWarning
      >
        Draft task note
      </div>
      <StatusIndicatorWithTasks />
    </div>
  ),
};
