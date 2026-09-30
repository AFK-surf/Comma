import userEvent from "@testing-library/user-event";
import { render, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { iconRegistryByExport } from "../../icons/iconRegistry";
import {
  SideChatCardsPanel,
  SideChatComposer,
  SideChatPanel,
  SideChatStatus,
  type SideChatTask,
} from "../SideChat";

function sideChatTask(
  statusBucket: SideChatTask["statusBucket"],
  activityStatus: string
): SideChatTask {
  return {
    activityStatus,
    conversationId: `cnv-${statusBucket}`,
    createdAt: Date.now(),
    groupId: "grp-1",
    id: `task-${statusBucket}`,
    statusBucket,
    title: `A ${statusBucket} task`,
    workspaceId: "wsp-1",
  };
}

function ComposerHarness({
  onHeightChange,
  onSubmit,
}: {
  onHeightChange?: (height: number) => void;
  onSubmit: (value: string) => void;
}) {
  const [value, setValue] = useState("");
  return (
    <SideChatComposer
      onSubmit={onSubmit}
      {...(onHeightChange ? { onTextareaHeightChange: onHeightChange } : {})}
      onValueChange={setValue}
      value={value}
    />
  );
}

describe("Side Chat UI", () => {
  it("uses the reviewed Central Icon variant for every Side Chat glyph", () => {
    const sideChatIcons = [
      "ArrowLeftIcon",
      "BubbleAlertIcon",
      "CircleCheckIcon",
      "CircleDashedIcon",
      "CircleInfoIcon",
      "CircleXIcon",
      "ListChecksIcon",
      "LoaderIcon",
      "PanelRightIcon",
      "SparklesIcon",
      "XIcon",
    ] as const;

    for (const iconName of sideChatIcons) {
      // PanelRightIcon is fill-only in the stroke-2 package, so it is sourced
      // pre-thinned at 1.5; everything else is thinned from 2 by the global
      // token. Both routes render at 1.5.
      const expected = iconName === "PanelRightIcon" ? 1.5 : 2;
      expect(iconRegistryByExport[iconName]?.variant.stroke, iconName).toBe(expected);
    }
    expect(iconRegistryByExport.ArrowUpIcon?.variant.stroke).toBe(2);
  });

  it("keeps conversation content mounted and inaccessible while task cards are visible", () => {
    const cards = <button type="button">Open task</button>;
    const messages = <button type="button">Send message</button>;
    const view = render(<SideChatPanel cards={cards}>{messages}</SideChatPanel>);
    const sendMessage = screen.getByRole("button", { name: "Send message" });
    expect(screen.queryByRole("button", { name: "Open task" })).toBeNull();

    view.rerender(
      <SideChatPanel cards={cards} cardsVisible>
        {messages}
      </SideChatPanel>
    );
    expect(screen.getByRole("button", { name: "Open task" })).toBeVisible();
    expect(screen.queryByRole("button", { name: "Send message" })).toBeNull();
    expect(sendMessage.parentElement).toHaveAttribute("inert");

    view.rerender(<SideChatPanel cards={cards}>{messages}</SideChatPanel>);
    expect(screen.getByRole("button", { name: "Send message" })).toBe(sendMessage);
    expect(sendMessage.parentElement).not.toHaveAttribute("inert");
  });

  it("inserts a newline with Shift+Enter and submits with Enter", async () => {
    const user = userEvent.setup();
    const onSubmit = vi.fn();
    render(<ComposerHarness onSubmit={onSubmit} />);
    const textarea = screen.getByRole("textbox", { name: "AI prompt" });

    expect(textarea.closest(".comma-side-chat-input")).toHaveAttribute(
      "data-multiline",
      "false"
    );

    await user.type(textarea, "first line{Shift>}{Enter}{/Shift}second line");
    expect(textarea).toHaveValue("first line\nsecond line");
    expect(onSubmit).not.toHaveBeenCalled();

    await user.keyboard("{Enter}");
    expect(onSubmit).toHaveBeenCalledWith("first line\nsecond line");
  });

  it("grows automatically up to four lines and then enables internal scrolling", () => {
    vi.spyOn(HTMLTextAreaElement.prototype, "scrollHeight", "get").mockReturnValue(120);
    const onHeightChange = vi.fn();
    render(<ComposerHarness onHeightChange={onHeightChange} onSubmit={vi.fn()} />);
    const textarea = screen.getByRole("textbox", { name: "AI prompt" });

    expect(textarea).toHaveStyle({ height: "80px", overflowY: "auto" });
    expect(textarea.closest(".comma-side-chat-input")).toHaveAttribute(
      "data-multiline",
      "true"
    );
    expect(onHeightChange).toHaveBeenLastCalledWith(80);
  });

  it("returns to the single-line capsule after multiline content is removed", async () => {
    const user = userEvent.setup();
    const scrollHeight = vi
      .spyOn(HTMLTextAreaElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLTextAreaElement) {
        if (this.style.transition !== "none") return 60;
        return this.value.includes("\n") ? 60 : 20;
      });

    try {
      render(<ComposerHarness onSubmit={vi.fn()} />);
      const textarea = screen.getByRole("textbox", { name: "AI prompt" });
      await user.type(textarea, "one{Shift>}{Enter}{/Shift}two");
      expect(textarea.closest(".comma-side-chat-input")).toHaveAttribute(
        "data-multiline",
        "true"
      );

      await user.clear(textarea);
      await user.type(textarea, "short");
      expect(textarea).toHaveStyle({ height: "20px" });
      expect(textarea.closest(".comma-side-chat-input")).toHaveAttribute(
        "data-multiline",
        "false"
      );
    } finally {
      scrollHeight.mockRestore();
    }
  });

  it("renders explicit capability states without fabricated tasks", async () => {
    const onRequiredHeight = vi.fn();
    const view = render(
      <SideChatCardsPanel
        capability={{ status: "planned" }}
        onRequiredHeight={onRequiredHeight}
      />
    );
    await waitFor(() =>
      expect(
        view.container
          .querySelector("status-indicator")
          ?.shadowRoot?.querySelectorAll('[role="radio"]')
      ).toHaveLength(5)
    );
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveAttribute(
      "data-capability",
      "needs-capability"
    );
    expect(screen.getByText("Task cards are planned")).toBeInTheDocument();
    expect(onRequiredHeight).toHaveBeenLastCalledWith(199);
  });

  it("reports the natural task list height instead of a fixed deck height", () => {
    const scrollHeight = vi
      .spyOn(HTMLElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        return this.matches('[data-slot="scroll-area-content"]') ? 500 : 900;
      });
    const onRequiredHeight = vi.fn();
    const tasks = [
      {
        activityStatus: "active" as const,
        conversationId: "cnv-task-1",
        groupId: "grp-1",
        createdAt: Date.now(),
        id: "task-1",
        statusBucket: "in_progress" as const,
        title: "A naturally sized task",
        workspaceId: "wsp-1",
      },
    ];
    try {
      const view = render(
        <SideChatCardsPanel
          capability={{ status: "ready", tasks }}
          onRequiredHeight={onRequiredHeight}
        />
      );
      expect(onRequiredHeight).toHaveBeenLastCalledWith(559);
      onRequiredHeight.mockClear();
      view.rerender(
        <SideChatCardsPanel
          capability={{ refreshing: true, status: "ready", tasks }}
          onRequiredHeight={onRequiredHeight}
        />
      );
      expect(onRequiredHeight).not.toHaveBeenCalled();
    } finally {
      scrollHeight.mockRestore();
    }
  });

  it("keeps the polling refresh indicator outside task list layout", () => {
    render(
      <SideChatCardsPanel
        capability={{
          refreshing: true,
          status: "ready",
          tasks: [
            {
              activityStatus: "active",
              conversationId: "cnv-task-refreshing",
              groupId: "grp-1",
              createdAt: Date.now(),
              id: "task-refreshing",
              statusBucket: "in_progress",
              title: "A task that is refreshing",
              workspaceId: "wsp-1",
            },
          ],
        }}
      />
    );

    const indicator = screen.getByText("Refreshing tasks");
    expect(indicator.closest('[data-slot="scroll-area-content"]')).toBeNull();
    expect(indicator.parentElement).toHaveClass("comma-side-chat-cards-column");
  });

  it("reports status content height to its business container", () => {
    const onRequiredHeight = vi.fn();
    render(<SideChatStatus onRequiredHeight={onRequiredHeight} title="Connecting" />);
    expect(onRequiredHeight).toHaveBeenCalled();
  });

  // Side Chat cards follow the Task card's progress-line rule so the same task
  // never reads differently depending on which surface shows it.
  it("shimmers the progress line only while a task is running", () => {
    const { container } = render(
      <SideChatCardsPanel
        capability={{
          status: "ready",
          tasks: [
            sideChatTask("in_progress", "running_tests"),
            sideChatTask("needs_review", "waiting_for_review"),
            sideChatTask("done", "completed"),
          ],
        }}
      />
    );

    const progress = container.querySelectorAll(".comma-shiny-text");
    expect(progress).toHaveLength(1);
    expect(progress[0]).toHaveTextContent("Running tests");
    expect(container.querySelectorAll('[data-slot="task-card-meta-row"]')).toHaveLength(
      1
    );
  });

  it("keeps the progress line on a running task with no current activity", () => {
    // The Comma assistant surface showed an "In progress" card with no line at
    // all, because an idle activity used to drop the row outright.
    const { container } = render(
      <SideChatCardsPanel
        capability={{
          status: "ready",
          tasks: [sideChatTask("in_progress", "idle")],
        }}
      />
    );

    const progress = container.querySelector(".comma-shiny-text");
    expect(progress).toBeTruthy();
    expect(progress).toHaveTextContent("In progress");
  });
});
