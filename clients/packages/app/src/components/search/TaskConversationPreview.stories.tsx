import type { Meta, StoryObj } from "@storybook/react-vite";
import { CircleCheckIcon, CommandPalette, type CommandPaletteGroup } from "@comma/ui";
import { useState } from "react";
import { expect, userEvent, waitFor, within } from "storybook/test";
import type { CommaApiClient, CommaConversation, SalixMessage } from "../../api";
import "../../styles.css";
import { TaskConversationPreview } from "./TaskConversationPreview";
import {
  TASK_PREVIEW_SEARCH_HIGHLIGHT,
  TASK_PREVIEW_SEARCH_HIGHLIGHT_RECT,
} from "./previewSearchHighlight";
import type { TaskConversationPreviewTarget } from "./taskConversationPreviewLoader";

const groupId = "storybook-command-preview-group";
const conversationId = "storybook-command-preview-task";
const workspaceId = "storybook-command-preview-workspace";
const previewUpdatedAt = 1_788_177_960;

const previewTurns = [
  {
    answer:
      "## Workbook loaded\n\nI found **18 months** of results across North America, EMEA, and APAC. The source contains revenue, pipeline, and renewal timing.",
    request: "Load the forecast workbook and identify the available signals.",
  },
  {
    answer:
      "## Revenue trend\n\nRevenue is **8.4% ahead of plan**. Growth is broad-based, although EMEA trails the other regions by six conversion points.",
    request: "Start with topline performance and regional variance.",
  },
  {
    answer:
      "## Renewal timing\n\n- 41% of renewal value closes in the final two weeks\n- 3 accounts represent more than one third of that value\n- 2 accounts still lack a confirmed decision date",
    request: "What does the renewal schedule look like?",
  },
  {
    answer:
      "## Regional comparison\n\n| Region | Coverage | Conversion |\n| --- | ---: | ---: |\n| North America | `3.4x` | 31% |\n| EMEA | `2.8x` | 24% |\n| APAC | `3.1x` | 30% |",
    request: "Compare pipeline coverage and conversion by region.",
  },
  {
    answer:
      "## Account review\n\n1. Assign an owner to every renewal above **$100k**.\n2. Confirm decision dates for the three largest accounts.\n3. Review EMEA opportunities twice each week.",
    request: "Which accounts should the team review first?",
  },
  {
    answer:
      "## Downside case\n\nIf the three largest renewals move by one month, the quarter finishes about **4.6% below plan**. Total pipeline remains sufficient; timing is the constraint.",
    request: "Model a downside scenario for the concentrated renewals.",
  },
  {
    answer:
      "## Ownership plan\n\n- Enterprise renewals → Sales leadership\n- EMEA conversion → Regional operations\n- Forecast refresh → Revenue operations\n\nEach owner should update `FY26-forecast.xlsx` before Friday.",
    request: "Turn the findings into a simple ownership plan.",
  },
  {
    answer:
      "## Final recommendation\n\n**Forecast risk** is concentrated in renewal timing, not demand.\n\n> Keep the plan, but manage the largest renewals as a separate weekly risk list.\n\nThe next review should verify dates, owners, and EMEA movement before changing the topline forecast.",
    request: "Summarize the most important conclusion for the forecast review.",
  },
] as const;

const previewMessages: SalixMessage[] = previewTurns.flatMap((turn, index) => {
  const userMessageId = `storybook-preview-user-${index + 1}`;
  const createdAt = 1_788_177_000 + index * 120;

  return [
    {
      actor_type: "user",
      content: [{ text: turn.request, type: "text" }],
      created_at: createdAt,
      kind: "message",
      message_id: userMessageId,
      user_id: "storybook-preview-user",
    },
    {
      actor_type: "agent",
      content:
        index === previewTurns.length - 1
          ? [
              { text: turn.answer, type: "text" },
              { text: "\n\nRelated Task: ", type: "text" },
              {
                conversation_id: "storybook-related-task",
                kind: "agent_task",
                presentation: "inline",
                title: "Review renewal owners",
                type: "conversation_ref",
                unavailable: false,
              },
            ]
          : [{ text: turn.answer, type: "text" }],
      created_at: createdAt + 60,
      agent_id: "storybook-preview-worker",
      kind: "message",
      message_id: `storybook-preview-assistant-${index + 1}`,
    },
  ];
});

const previewConversation: CommaConversation = {
  group_id: groupId,
  id: conversationId,
  kind: "agent_task",
  message_count: previewMessages.length,
  messages: previewMessages,
  status: "completed",
  title: "Analyze the quarterly forecast",
  updated_at: previewUpdatedAt,
};

const previewApi = {
  pollConversation: async () => ({
    conversation: previewConversation,
    notModified: false,
  }),
} as Partial<CommaApiClient> as CommaApiClient;

const previewTask: TaskConversationPreviewTarget = {
  conversationId,
  groupId,
  status: "completed",
  title: previewConversation.title,
  updatedAt: previewUpdatedAt,
  workspaceId,
};

const groups: readonly CommandPaletteGroup[] = [
  {
    heading: "Tasks",
    id: "task-history",
    items: [
      {
        icon: <CircleCheckIcon className="text-fg-success-primary" />,
        meta: "Aug 30",
        title: previewConversation.title,
        value: conversationId,
      },
    ],
  },
];

function ProductionTaskPreviewStory() {
  const [activeValue, setActiveValue] = useState(conversationId);
  const [query, setQuery] = useState("");

  return (
    <div className="min-h-screen bg-window p-4xl">
      <CommandPalette
        activeValue={activeValue}
        groups={groups}
        label="Search Comma"
        onActiveValueChange={setActiveValue}
        onOpenChange={() => {}}
        onQueryChange={setQuery}
        onSelect={() => {}}
        open
        placeholder="Search tasks"
        preview={
          <TaskConversationPreview
            apiClient={previewApi}
            searchQuery={query}
            task={previewTask}
          />
        }
        previewLabel="Task preview"
        query={query}
      />
    </div>
  );
}

const meta = {
  component: ProductionTaskPreviewStory,
  parameters: {
    layout: "fullscreen",
  },
  title: "App components/Search/Command Palette/Production task preview",
} satisfies Meta<typeof ProductionTaskPreviewStory>;

export default meta;
type Story = StoryObj<typeof meta>;

export const CompleteConversation: Story = {
  play: async ({ canvasElement }) => {
    const document = canvasElement.ownerDocument;
    const page = within(document.body);
    const thread = await waitFor(() => {
      const element = document.querySelector<HTMLElement>(
        '[data-slot="task-conversation-preview-thread"]'
      );
      expect(element).toHaveAttribute("data-variant", "command-preview");
      return element!;
    });
    const modal = document.querySelector<HTMLElement>(
      '[data-slot="command-palette-modal"]'
    );
    const content = document.querySelector<HTMLElement>(
      '[data-slot="command-palette-content"]'
    );
    const preview = page.getByRole("region", { name: "Task preview" });
    const viewport = thread.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    const surface = document.querySelector<HTMLElement>(
      '[data-slot="task-conversation-preview"]'
    );
    const inlineTask = thread.querySelector<HTMLElement>(
      '[data-testid="chat-inline-task-storybook-related-task"]'
    );
    const transcript = thread.querySelector<HTMLElement>(".comma-chat-thread");
    const turn = thread.querySelector<HTMLElement>(".comma-chat-turn");

    await waitFor(() => {
      expect(
        Array.from(thread.querySelectorAll("strong"), (element) =>
          element.textContent?.trim()
        )
      ).toContain("Forecast risk");
      expect(thread.querySelector("table")).not.toBeNull();
      expect(thread.querySelector("blockquote")).not.toBeNull();
    });
    await userEvent.type(
      page.getByRole("combobox", { name: "Search Comma" }),
      "forecast"
    );
    await waitFor(() => {
      const usesNativeHighlight =
        typeof window.Highlight === "function" &&
        CSS.highlights?.has(TASK_PREVIEW_SEARCH_HIGHLIGHT);
      const fallbackRects = document.querySelectorAll(
        `[data-slot="${TASK_PREVIEW_SEARCH_HIGHLIGHT_RECT}"]`
      );
      expect(Boolean(usesNativeHighlight) || fallbackRects.length > 0).toBe(true);
    });
    expect(thread.querySelector(".comma-chat-message-actions")).toBeNull();
    expect(transcript).toHaveAttribute("inert");
    expect(viewport).toHaveAttribute("aria-hidden", "true");
    expect(viewport).toHaveAttribute("tabindex", "-1");
    expect(transcript ? getComputedStyle(transcript).pointerEvents : "").toBe("none");
    expect(inlineTask ? getComputedStyle(inlineTask).pointerEvents : "").toBe("none");
    const inlineTaskRect = inlineTask?.getBoundingClientRect();
    const inlineTaskHit = inlineTaskRect
      ? document.elementFromPoint(
          inlineTaskRect.left + inlineTaskRect.width / 2,
          inlineTaskRect.top + inlineTaskRect.height / 2
        )
      : null;
    expect(inlineTaskHit?.closest('[data-testid^="chat-inline-task-"]')).toBeNull();
    expect(surface).toHaveClass("bg-popup-secondary", "shadow-lg");

    await waitFor(() => {
      const previewRect = preview.getBoundingClientRect();
      const contentRect = content?.getBoundingClientRect();
      const [taskColumn = 0, previewColumn = 0] = content
        ? getComputedStyle(content)
            .gridTemplateColumns.split(" ")
            .map(Number.parseFloat)
        : [];

      expect(modal?.getBoundingClientRect().width).toBe(
        Math.min(832, document.documentElement.clientWidth - 32)
      );
      expect(modal?.getBoundingClientRect().height).toBe(
        Math.min(704, document.documentElement.clientHeight - 32)
      );
      expect(taskColumn).toBe(384);
      expect(Math.abs(previewColumn - previewRect.width)).toBeLessThanOrEqual(1);
      expect(content ? getComputedStyle(content).columnGap : "").toBe("16px");
      expect(turn ? getComputedStyle(turn).rowGap : "").toBe("16px");
      expect(
        Math.abs(previewRect.height - Math.max(0, (contentRect?.height ?? 0) - 20))
      ).toBeLessThanOrEqual(1);
      expect(viewport?.scrollHeight ?? 0).toBeGreaterThan(viewport?.clientHeight ?? 0);
      expect(
        viewport
          ? getComputedStyle(viewport)
              .getPropertyValue("--scroll-area-edge-mask-start")
              .trim()
          : ""
      ).toBe("32px");
    });
  },
};
