import userEvent from "@testing-library/user-event";
import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { render, screen, waitFor, within } from "@comma/test-utils/render";
import type { SideChatTask } from "@comma/ui";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  SideChatCardsPanel,
  type SideChatCardsCapabilityState,
} from "../SideChatCardsPanel";

describe("SideChatCardsPanel", () => {
  afterEach(() => {
    initializeCommaI18n(["en"]);
  });

  it("renders the honest five-bucket shell without fabricated task counts", async () => {
    render(<SideChatCardsPanel capability={{ status: "planned" }} />);

    const statusControls = await findStatusControls();
    expect(statusControls.getAllByRole("radio")).toHaveLength(5);
    expect(statusControls.getByRole("radio", { name: "In progress" })).toHaveAttribute(
      "aria-checked",
      "true"
    );
    expect(screen.getByRole("status")).toHaveAttribute(
      "data-capability",
      "needs-capability"
    );
    expect(screen.getByText("Task cards are planned")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Refresh" })).toBeNull();
    expect(screen.queryByRole("textbox")).toBeNull();
  });

  it("switches real buckets, refreshes an empty bucket, and supports detail back", async () => {
    const user = userEvent.setup();
    const onRefresh = vi.fn();
    render(
      <SideChatCardsPanel
        capability={{
          onRefresh,
          status: "ready",
          tasks: readyTasks,
        }}
      />
    );

    expect(onRefresh).toHaveBeenCalledOnce();
    const statusControls = await findStatusControls();

    expect(statusControls.getByRole("radio", { name: "In progress" })).toHaveAttribute(
      "aria-checked",
      "true"
    );
    expect(document.querySelector('[data-slot="scroll-area"]')).toHaveAttribute(
      "data-edge-effect",
      "none"
    );
    await user.click(
      screen.getByRole("button", { name: "Open task: Implement bridge" })
    );
    expect(screen.getByRole("heading", { name: "Implement bridge" })).toBeVisible();
    expect(screen.getByText("Renderer wiring is ready")).toBeInTheDocument();
    expect(document.querySelector("status-indicator")).toBeNull();
    expect(document.querySelector('[data-slot="scroll-area"]')).toHaveAttribute(
      "data-edge-effect",
      "none"
    );

    await user.click(screen.getByRole("button", { name: "Back to task cards" }));
    const restoredControls = await findStatusControls();
    await user.click(restoredControls.getByRole("radio", { name: "Needs Review" }));
    expect(screen.getByRole("tabpanel")).toHaveAttribute("data-bucket", "needs_review");
    expect(screen.getByText("No needs review tasks")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Refresh" }));
    expect(onRefresh).toHaveBeenCalledTimes(2);

    await user.click(restoredControls.getByRole("radio", { name: "Backlog" }));
    expect(screen.getByText("Audit blur parity")).toBeInTheDocument();
  });

  it("localizes a task activity phase without exposing its raw enum", () => {
    render(
      <CommaI18nProvider locale="zh-CN">
        <SideChatCardsPanel
          capability={{
            status: "ready",
            tasks: [{ ...readyTasks[0]!, lastMessage: undefined }],
          }}
        />
      </CommaI18nProvider>
    );

    expect(screen.getByText("正在运行测试")).toBeInTheDocument();
    expect(screen.queryByText("running_tests")).not.toBeInTheDocument();
  });

  it.each<{
    capability: SideChatCardsCapabilityState;
    capabilityName: string;
    title: string;
  }>([
    {
      capability: { status: "loading" },
      capabilityName: "loading",
      title: "Loading tasks",
    },
    {
      capability: {
        message: "Task service is offline",
        onRefresh: vi.fn(),
        status: "error",
      },
      capabilityName: "error",
      title: "Tasks unavailable",
    },
    {
      capability: { status: "ready", tasks: [] },
      capabilityName: "ready",
      title: "No in progress tasks",
    },
  ])(
    "only renders the $capabilityName state when supplied by capability state",
    ({ capability, capabilityName, title }) => {
      render(<SideChatCardsPanel capability={capability} />);

      expect(screen.getByRole("status")).toHaveAttribute(
        "data-capability",
        capabilityName
      );
      expect(screen.getByText(title)).toBeInTheDocument();
    }
  );
});

const readyTasks: SideChatTask[] = [
  {
    activityStatus: "running_tests",
    conversationId: "cnv_task_1",
    createdAt: 1_784_200_000,
    groupId: "grp_1",
    id: "task_1",
    lastMessage: {
      content: "Renderer wiring is ready",
    },
    statusBucket: "in_progress",
    title: "Implement bridge",
    workspaceId: "wsp_1",
  },
  {
    activityStatus: "idle",
    conversationId: "cnv_task_2",
    createdAt: 1_784_200_100,
    groupId: "grp_1",
    id: "task_2",
    statusBucket: "backlog",
    title: "Audit blur parity",
    workspaceId: "wsp_1",
  },
];

async function findStatusControls() {
  let root: ShadowRoot | undefined;
  await waitFor(() => {
    root = document.querySelector("status-indicator")?.shadowRoot ?? undefined;
    expect(root?.querySelectorAll('[role="radio"]')).toHaveLength(5);
  });
  return within(root! as unknown as HTMLElement);
}
