import type { Meta, StoryObj } from "@storybook/react-vite";
import { useMemo, useRef, useState } from "react";
import { expect, fn, userEvent, waitFor, within } from "storybook/test";
import { spacing } from "../../tokens";
import {
  ChatPanelMessageItem,
  CircleCheckIcon,
  CommandPalette,
  CommandPaletteHighlight,
  MarkdownStream,
  ScrollArea,
  type CommandPaletteGroup,
  type CommandPaletteItem,
} from "../index";

type StoryArgs = {
  onSelect: (item: CommandPaletteItem) => void;
};

const taskTitles = [
  "Analyze this Excel file",
  "Review the launch readiness checklist",
  "Summarize customer research notes",
  "Prepare the workspace migration",
  "Polish command palette interactions",
  "Audit task loading behavior",
  "Write the release announcement",
  "Resolve settings navigation feedback",
  "Compare the quarterly forecasts",
  "Triage the product inbox",
  "Document the keyboard shortcuts",
] as const;

const taskGroups: readonly CommandPaletteGroup[] = [
  {
    id: "tasks",
    heading: "Tasks",
    items: taskTitles.map((title, index) => ({
      value: `task-${index + 1}`,
      title,
      icon: <CircleCheckIcon className="text-fg-success-primary" />,
      meta: index < 4 ? "Aug 30" : "Aug 29",
    })),
  },
];

const searchGroups: readonly CommandPaletteGroup[] = [
  {
    id: "task-results",
    heading: "Tasks",
    items: [
      {
        value: "task-search-1",
        title: (
          <>
            Analyze this <CommandPaletteHighlight>Excel</CommandPaletteHighlight> file
          </>
        ),
        icon: <CircleCheckIcon className="text-fg-success-primary" />,
        meta: "Aug 30",
      },
      {
        value: "task-search-2",
        title: "Compare quarterly forecasts",
        subtitle: (
          <>
            Review the source <CommandPaletteHighlight>Excel</CommandPaletteHighlight>
            workbook before sharing the summary.
          </>
        ),
        icon: <CircleCheckIcon className="text-fg-success-primary" />,
        meta: "Aug 28",
      },
    ],
  },
];

const previewSummary = [
  "## Forecast summary",
  "",
  "Revenue is **8.4% ahead of plan**, but renewal timing creates a concentration risk near the end of the quarter.",
  "",
  "| Signal | Finding |",
  "| --- | --- |",
  "| Enterprise pipeline | Healthy coverage at `3.2x` target |",
  "| Renewals | 41% close in the final two weeks |",
  "| EMEA | Conversion is 6 points below the other regions |",
  "",
  "### Recommended next steps",
  "",
  "1. Assign an owner to each renewal above **$100k**.",
  "2. Review EMEA opportunities twice a week.",
  "3. Track timing risk separately from total pipeline value.",
  "",
  "> The biggest risk is timing, not demand. The current pipeline can still support the plan if the largest renewals stay on schedule.",
].join("\n");

const previewFollowUp = [
  "I also compared the regional tabs. The next review should focus on:",
  "",
  "- accounts without a confirmed decision date",
  "- renewals with no executive sponsor",
  "- EMEA deals that moved more than once",
  "",
  "The source remains `FY26-forecast.xlsx`, so the summary can be refreshed without changing the workflow.",
].join("\n");

const TaskPreviewSurface = ({ title }: { title: string }) => (
  <section className="flex h-full min-h-0 flex-col overflow-hidden rounded-2xl border-[length:var(--border-width-0-5)] border-primary bg-popup-secondary shadow-lg">
    <div className="flex h-10 shrink-0 items-center border-b-[length:var(--border-width-0-5)] border-primary px-lg">
      <h2 className="m-0 truncate text-xs font-medium text-secondary">{title}</h2>
    </div>
    <ScrollArea
      className="min-h-0 flex-1"
      contentClassName="flex min-h-full flex-col gap-xl px-lg py-xl"
      edgeEffect="mask"
      edgeMask={{ size: spacing["4xl"] }}
      orientation="vertical"
      scrollbarRevealSource="interaction"
      viewportClassName="h-full"
      viewportProps={{ tabIndex: -1 }}
    >
      <ChatPanelMessageItem
        message={{
          content:
            "Analyze the workbook, summarize the trend, and call out the biggest risk before the forecast review.",
          id: "preview-user-request",
          kind: "user",
        }}
        variant="conversation"
      />
      <ChatPanelMessageItem
        className="break-words"
        message={{
          content: (
            <MarkdownStream
              animation="none"
              className="break-words"
              content={previewSummary}
              final
              showCodeBlockCopy={false}
              showCodeBlockHeader={false}
              streamId="command-palette-preview-summary"
            />
          ),
          id: "preview-assistant-summary",
          kind: "assistant",
        }}
        variant="conversation"
      />
      <ChatPanelMessageItem
        message={{
          content: "Which accounts should the team review first?",
          id: "preview-user-follow-up",
          kind: "user",
        }}
        variant="conversation"
      />
      <ChatPanelMessageItem
        className="break-words"
        message={{
          content: (
            <MarkdownStream
              animation="none"
              className="break-words"
              content={previewFollowUp}
              final
              showCodeBlockCopy={false}
              showCodeBlockHeader={false}
              streamId="command-palette-preview-follow-up"
            />
          ),
          id: "preview-assistant-follow-up",
          kind: "assistant",
        }}
        variant="conversation"
      />
    </ScrollArea>
  </section>
);

const PreviewSkeleton = () => (
  <section
    aria-label="Loading task preview"
    className="flex h-full flex-col gap-xl rounded-2xl border-[length:var(--border-width-0-5)] border-primary bg-popup-secondary p-xl shadow-lg"
  >
    <span className="h-xl w-3/5 animate-pulse rounded-md bg-secondary motion-reduce:animate-none" />
    <span className="mt-xl h-7xl w-4/5 self-end animate-pulse rounded-xl bg-secondary motion-reduce:animate-none" />
    <span className="h-3xl w-full animate-pulse rounded-md bg-secondary motion-reduce:animate-none" />
    <span className="h-3xl w-4/5 animate-pulse rounded-md bg-secondary motion-reduce:animate-none" />
  </section>
);

const CommandPaletteStory = ({
  emptyTitle,
  groups,
  initialQuery = "",
  loading = false,
  onSelect,
  preview = true,
}: {
  emptyTitle?: string;
  groups: readonly CommandPaletteGroup[];
  initialQuery?: string;
  loading?: boolean;
  onSelect: StoryArgs["onSelect"];
  preview?: boolean | "loading";
}) => {
  const [open, setOpen] = useState(true);
  const [query, setQuery] = useState(initialQuery);
  const firstValue = groups[0]?.items[0]?.value;
  const [activeValue, setActiveValue] = useState(firstValue);
  const [previewValue, setPreviewValue] = useState(firstValue);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const previewItem = useMemo(
    () =>
      groups
        .flatMap((group) => group.items)
        .find((item) => item.value === previewValue),
    [groups, previewValue]
  );

  const handleOpenChange = (nextOpen: boolean) => {
    setOpen(nextOpen);
    if (!nextOpen) {
      window.setTimeout(() => triggerRef.current?.focus({ preventScroll: true }));
    }
  };

  const previewContent =
    preview === "loading" ? (
      <PreviewSkeleton />
    ) : preview ? (
      <TaskPreviewSurface
        title={
          typeof previewItem?.title === "string" ? previewItem.title : "Task preview"
        }
      />
    ) : undefined;

  return (
    <div className="min-h-screen bg-window p-4xl">
      <button
        className="h-5xl rounded-lg bg-main-panel-item-bg px-xl text-sm text-primary shadow-sm"
        onClick={() => setOpen(true)}
        ref={triggerRef}
        type="button"
      >
        Open search
      </button>
      <CommandPalette
        {...(activeValue ? { activeValue } : {})}
        {...(emptyTitle ? { emptyTitle } : {})}
        groups={groups}
        label="Search Comma"
        loading={loading}
        onActiveValueChange={(nextValue, source) => {
          setActiveValue(nextValue);
          if (source !== "pointer") setPreviewValue(nextValue);
        }}
        onOpenChange={handleOpenChange}
        onPointerIntent={setPreviewValue}
        onPointerIntentCancel={(cancelledValue) => {
          setActiveValue((currentValue) =>
            currentValue === cancelledValue ? previewValue : currentValue
          );
        }}
        onQueryChange={setQuery}
        onSelect={onSelect}
        open={open}
        placeholder="Search task"
        {...(previewContent ? { preview: previewContent } : {})}
        previewLabel="Task preview"
        query={query}
      />
    </div>
  );
};

const meta = {
  title: "App components/Search/Command Palette",
  parameters: {
    layout: "fullscreen",
  },
  args: {
    onSelect: fn(),
  },
} satisfies Meta<StoryArgs>;

export default meta;
type Story = StoryObj<StoryArgs>;

const expectStateFillsContent = async (document: Document, slot: string) => {
  const content = document.querySelector<HTMLElement>(
    '[data-slot="command-palette-content"]'
  );
  const state = document.querySelector<HTMLElement>(`[data-slot="${slot}"]`);

  await waitFor(() => {
    expect(content).not.toBeNull();
    expect(state).not.toBeNull();
    const contentRect = content?.getBoundingClientRect();
    const stateRect = state?.getBoundingClientRect();
    expect(Math.abs((stateRect?.x ?? 0) - (contentRect?.x ?? 0))).toBeLessThanOrEqual(
      1
    );
    expect(Math.abs((stateRect?.y ?? 0) - (contentRect?.y ?? 0))).toBeLessThanOrEqual(
      1
    );
    expect(
      Math.abs((stateRect?.width ?? 0) - (contentRect?.width ?? 0))
    ).toBeLessThanOrEqual(1);
    expect(
      Math.abs((stateRect?.height ?? 0) - (contentRect?.height ?? 0))
    ).toBeLessThanOrEqual(1);
  });
};

export const TaskHistory: Story = {
  render: ({ onSelect }) => (
    <CommandPaletteStory groups={taskGroups} onSelect={onSelect} />
  ),
  play: async ({ args, canvasElement }) => {
    const page = within(canvasElement.ownerDocument.body);
    const input = await page.findByRole("combobox", { name: "Search Comma" });
    const modal = canvasElement.ownerDocument.querySelector<HTMLElement>(
      '[data-slot="command-palette-modal"]'
    );
    const overlay = canvasElement.ownerDocument.querySelector<HTMLElement>(
      '[data-slot="command-palette-overlay"]'
    );
    const content = canvasElement.ownerDocument.querySelector<HTMLElement>(
      '[data-slot="command-palette-content"]'
    );
    const preview = page.getByRole("region", { name: "Task preview" });
    const previewViewport = preview.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    const reducedMotion =
      canvasElement.ownerDocument.documentElement.dataset.commaReducedMotion === "true";

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
      expect(overlay ? getComputedStyle(overlay).backgroundColor : "").toBe(
        "rgba(0, 0, 0, 0.1)"
      );
      expect(overlay ? getComputedStyle(overlay).transitionProperty : "").toBe(
        "opacity"
      );
      expect(overlay ? getComputedStyle(overlay).transitionDuration : "").toBe(
        reducedMotion ? "0s" : "0.12s"
      );
      expect(modal ? getComputedStyle(modal).transitionProperty : "").toBe(
        "opacity, transform"
      );
      expect(modal ? getComputedStyle(modal).transitionDuration : "").toBe(
        reducedMotion ? "0s" : "0.12s, 0.2s"
      );
      expect(taskColumn).toBe(384);
      expect(Math.abs(previewColumn - previewRect.width)).toBeLessThanOrEqual(1);
      expect(content ? getComputedStyle(content).columnGap : "").toBe("16px");
      expect(preview.firstElementChild).toHaveClass("bg-popup-secondary", "shadow-lg");
      expect(
        Math.abs(previewRect.height - Math.max(0, (contentRect?.height ?? 0) - 20))
      ).toBeLessThanOrEqual(1);
      expect(previewViewport?.scrollHeight ?? 0).toBeGreaterThan(
        previewViewport?.clientHeight ?? 0
      );
      expect(
        previewViewport
          ? getComputedStyle(previewViewport)
              .getPropertyValue("--scroll-area-edge-mask-end")
              .trim()
          : ""
      ).toBe("32px");
    });

    await userEvent.click(input);
    await expect(input).toHaveFocus();
    await userEvent.keyboard("{ArrowDown}{Enter}");
    await expect(args.onSelect).toHaveBeenCalledWith(
      expect.objectContaining({ value: "task-2" })
    );
    await userEvent.keyboard("{Escape}");
    const trigger = page.getByRole("button", { name: "Open search" });
    await waitFor(() => expect(trigger).toHaveFocus());
    await userEvent.click(trigger);
    const reopenedInput = page.getByRole("combobox", { name: "Search Comma" });
    await userEvent.click(reopenedInput);
    await expect(reopenedInput).toHaveFocus();
  },
};

export const SearchActive: Story = {
  render: ({ onSelect }) => (
    <CommandPaletteStory
      groups={searchGroups}
      initialQuery="Excel"
      onSelect={onSelect}
    />
  ),
};

export const DarkTaskHistory: Story = {
  globals: {
    theme: "dark",
  },
  render: ({ onSelect }) => (
    <CommandPaletteStory groups={taskGroups} onSelect={onSelect} />
  ),
  play: async ({ canvasElement }) => {
    const overlay = canvasElement.ownerDocument.querySelector<HTMLElement>(
      '[data-slot="command-palette-overlay"]'
    );

    await waitFor(() =>
      expect(overlay ? getComputedStyle(overlay).backgroundColor : "").toBe(
        "rgba(0, 0, 0, 0.3)"
      )
    );
  },
};

export const ReducedMotionTaskHistory: Story = {
  globals: {
    motionPreference: "reduced",
  },
  render: ({ onSelect }) => (
    <CommandPaletteStory groups={taskGroups} onSelect={onSelect} />
  ),
  play: async ({ canvasElement }) => {
    const document = canvasElement.ownerDocument;
    const overlay = document.querySelector<HTMLElement>(
      '[data-slot="command-palette-overlay"]'
    );
    const modal = document.querySelector<HTMLElement>(
      '[data-slot="command-palette-modal"]'
    );

    await waitFor(() => {
      expect(document.documentElement.dataset.commaReducedMotion).toBe("true");
      expect(overlay ? getComputedStyle(overlay).transitionDuration : "").toBe("0s");
      expect(modal ? getComputedStyle(modal).transitionDuration : "").toBe("0s");
    });
  },
};

export const NoResults: Story = {
  render: ({ onSelect }) => (
    <CommandPaletteStory
      groups={[]}
      initialQuery="missing"
      onSelect={onSelect}
      preview={false}
    />
  ),
  play: async ({ canvasElement }) => {
    await expectStateFillsContent(canvasElement.ownerDocument, "command-palette-empty");
  },
};

export const SearchUnavailable: Story = {
  render: ({ onSelect }) => (
    <CommandPaletteStory
      emptyTitle="Unable to search tasks. Try again in a moment."
      groups={[]}
      initialQuery="forecast"
      onSelect={onSelect}
      preview={false}
    />
  ),
  play: async ({ canvasElement }) => {
    await expectStateFillsContent(canvasElement.ownerDocument, "command-palette-empty");
  },
};

export const PreviewLoading: Story = {
  render: ({ onSelect }) => (
    <CommandPaletteStory groups={taskGroups} onSelect={onSelect} preview="loading" />
  ),
};

export const LoadingResults: Story = {
  render: ({ onSelect }) => (
    <CommandPaletteStory groups={[]} loading onSelect={onSelect} preview={false} />
  ),
  play: async ({ canvasElement }) => {
    const document = canvasElement.ownerDocument;
    const loading = document.querySelector<HTMLElement>(
      '[data-slot="command-palette-loading"]'
    );
    const logo = loading?.querySelector('[data-slot="comma-logo-animation"]');
    const scene = logo?.querySelector(".comma-logo-animation__scene");

    await expect(loading).toHaveAccessibleName("Loading results");
    await waitFor(() => expect(logo).toBeVisible());
    await expect(scene).toBeInTheDocument();

    await expectStateFillsContent(document, "command-palette-loading");
    await waitFor(() => {
      const reducedMotion =
        document.documentElement.dataset.commaReducedMotion === "true" ||
        document.defaultView!.matchMedia("(prefers-reduced-motion: reduce)").matches;
      const style = getComputedStyle(scene!);
      if (reducedMotion) {
        expect(style.animationName).toBe("none");
      } else {
        expect(style.animationName).not.toBe("none");
        expect(Number.parseFloat(style.animationDuration)).toBeGreaterThan(0);
        expect(style.animationPlayState).toBe("running");
      }
    });
  },
};

export const LoadingResultsReducedMotion: Story = {
  ...LoadingResults,
  globals: { motionPreference: "reduced" },
};

export const LongTaskHistory: Story = {
  render: ({ onSelect }) => (
    <CommandPaletteStory
      groups={[
        {
          id: "long-task-list",
          heading: "Tasks",
          items: Array.from({ length: 48 }, (_, index) => ({
            value: `long-task-${index + 1}`,
            title: `Task result ${index + 1}`,
            icon: <CircleCheckIcon className="text-fg-success-primary" />,
            meta: index % 2 === 0 ? "Aug 30" : "Aug 29",
          })),
        },
      ]}
      onSelect={onSelect}
    />
  ),
  play: async ({ canvasElement }) => {
    const document = canvasElement.ownerDocument;
    const content = document.querySelector<HTMLElement>(
      '[data-slot="command-palette-content"]'
    );
    const results = content?.firstElementChild;
    const scrollbar = results?.querySelector<HTMLElement>(
      ".comma-scroll-area__scrollbar--vertical"
    );
    const metas = Array.from(
      results?.querySelectorAll<HTMLElement>(
        '[data-slot="command-palette-item-meta"]'
      ) ?? []
    );

    await waitFor(() => {
      const scrollbarRect = scrollbar?.getBoundingClientRect();
      expect(scrollbarRect?.width ?? 0).toBeGreaterThan(0);
      expect(
        results
          ? getComputedStyle(
              results.querySelector('[data-slot="scroll-area-viewport"]')!
            )
              .getPropertyValue("--scroll-area-edge-mask-end")
              .trim()
          : ""
      ).toBe("32px");
      expect(metas.length).toBeGreaterThan(0);
      expect(
        Math.max(...metas.map((itemMeta) => itemMeta.getBoundingClientRect().right))
      ).toBeLessThan(scrollbarRect?.left ?? 0);
    });
  },
};
