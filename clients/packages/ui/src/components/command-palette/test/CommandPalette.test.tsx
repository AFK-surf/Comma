import userEvent from "@testing-library/user-event";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { useState } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { commandPaletteLayout, motionDuration } from "../../../tokens";
import { ArchiveIcon, SettingsIcon } from "../../icons";
import { isNativeSurfaceSuppressed } from "../../native-surface/nativeSurfaceSuppression";
import {
  CommandPalette,
  CommandPaletteHighlight,
  type CommandPaletteGroup,
} from "../CommandPalette";

type TestValue = "archive-task" | "open-settings";

const archiveItem = {
  value: "archive-task",
  title: (
    <>
      <CommandPaletteHighlight>Archive</CommandPaletteHighlight> finished task
    </>
  ),
  subtitle: "Tasks · Completed",
  highlight: (
    <>
      Move this task to the <CommandPaletteHighlight>archive</CommandPaletteHighlight>.
    </>
  ),
  meta: "Yesterday",
  icon: <ArchiveIcon />,
} as const;

const settingsItem = {
  value: "open-settings",
  title: "Open settings",
  subtitle: "Navigation",
  meta: "⌘ ,",
  icon: <SettingsIcon />,
} as const;

const groups: readonly CommandPaletteGroup<TestValue>[] = [
  { id: "tasks", heading: "Tasks", items: [archiveItem] },
  { id: "actions", heading: "Actions", items: [settingsItem] },
];

const originalScrollIntoView = HTMLElement.prototype.scrollIntoView;

beforeEach(() => {
  HTMLElement.prototype.scrollIntoView = vi.fn();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  if (originalScrollIntoView) {
    HTMLElement.prototype.scrollIntoView = originalScrollIntoView;
  } else {
    Reflect.deleteProperty(HTMLElement.prototype, "scrollIntoView");
  }
});

describe("CommandPalette", () => {
  it("renders search results and the preview in an accessible modal", async () => {
    const onSelect = vi.fn();
    render(
      <CommandPalette
        emptyTitle="No results found"
        groups={groups}
        label="Search Comma"
        onOpenChange={vi.fn()}
        onQueryChange={vi.fn()}
        onSelect={onSelect}
        open
        preview={<section>Task conversation</section>}
        previewLabel="Task preview"
        query="archive"
      />
    );

    expect(screen.getByRole("dialog", { name: "Search Comma" })).toBeVisible();
    expect(screen.getByRole("region", { name: "Task preview" })).toHaveTextContent(
      "Task conversation"
    );
    expect(screen.getByRole("status")).toHaveTextContent("Search results: 2");
    expect(isNativeSurfaceSuppressed()).toBe(true);

    await waitFor(() => {
      expect(
        screen.getByRole("option", { name: /Archive finished task/ })
      ).toHaveAttribute("aria-selected", "true");
    });
  });

  it("does not mount a hidden preview below the split breakpoint", () => {
    let matches = false;
    const listeners = new Set<() => void>();
    const mediaQuery = {
      get matches() {
        return matches;
      },
      addEventListener: (_type: string, listener: () => void) => {
        listeners.add(listener);
      },
      removeEventListener: (_type: string, listener: () => void) => {
        listeners.delete(listener);
      },
    } as MediaQueryList;
    const matchMedia = vi.fn(() => mediaQuery);
    vi.stubGlobal("matchMedia", matchMedia);

    render(
      <CommandPalette
        groups={groups}
        label="Search Comma"
        onOpenChange={vi.fn()}
        onQueryChange={vi.fn()}
        onSelect={vi.fn()}
        open
        preview={<section data-testid="responsive-preview">Task preview</section>}
        previewLabel="Task preview"
        query=""
      />
    );

    expect(screen.queryByTestId("responsive-preview")).toBeNull();
    expect(
      document.querySelector('[data-slot="command-palette-content"]')
    ).toHaveAttribute("data-has-preview", "false");
    expect(matchMedia).toHaveBeenCalledWith(
      `(min-width: ${commandPaletteLayout.previewMinViewportWidth}px)`
    );

    act(() => {
      matches = true;
      listeners.forEach((listener) => listener());
    });

    expect(screen.getByTestId("responsive-preview")).toBeInTheDocument();
  });

  it("loops through results and reports the selected typed item", async () => {
    const user = userEvent.setup();
    const onSelect = vi.fn();
    render(
      <CommandPalette<TestValue>
        groups={groups}
        label="Search Comma"
        onOpenChange={vi.fn()}
        onQueryChange={vi.fn()}
        onSelect={onSelect}
        open
        query=""
      />
    );

    const input = screen.getByRole("combobox", { name: "Search Comma" });
    expect(input).toHaveClass("outline-none", "text-sm");
    expect(input).not.toHaveClass("leading-5");
    expect(input).not.toHaveClass("tracking-[-0.14px]");
    expect(input.className).not.toMatch(/focus-visible:(?:ring|shadow)/);
    await waitFor(() => {
      expect(
        screen.getByRole("option", { name: /Archive finished task/ })
      ).toHaveAttribute("aria-selected", "true");
    });

    input.focus();
    await user.keyboard("{ArrowUp}{Enter}");

    expect(onSelect).toHaveBeenCalledOnce();
    expect(onSelect).toHaveBeenCalledWith(settingsItem);
    expect(screen.getByRole("dialog", { name: "Search Comma" })).toBeInTheDocument();
  });

  it("keeps selection immediate while pointer-owned preview work waits for intent", async () => {
    const user = userEvent.setup();
    const onActiveValueChange = vi.fn();
    const onPointerIntent = vi.fn();
    const onPointerIntentCancel = vi.fn();
    const SourceHarness = () => {
      const [activeValue, setActiveValue] = useState<TestValue>("archive-task");
      const [previewValue, setPreviewValue] = useState<TestValue>("archive-task");

      return (
        <CommandPalette<TestValue>
          activeValue={activeValue}
          groups={groups}
          label="Search Comma"
          onActiveValueChange={(value, source) => {
            onActiveValueChange(value, source);
            setActiveValue(value);
            if (source !== "pointer") setPreviewValue(value);
          }}
          onOpenChange={vi.fn()}
          onPointerIntent={(value) => {
            onPointerIntent(value);
            setPreviewValue(value);
          }}
          onPointerIntentCancel={(value) => {
            onPointerIntentCancel(value);
            setActiveValue((currentValue) =>
              currentValue === value ? previewValue : currentValue
            );
          }}
          onQueryChange={vi.fn()}
          onSelect={vi.fn()}
          open
          preview={<span>{previewValue}</span>}
          previewLabel="Task preview"
          query=""
        />
      );
    };
    render(<SourceHarness />);

    const input = screen.getByRole("combobox", { name: "Search Comma" });
    await waitFor(() => {
      expect(
        screen.getByRole("option", { name: /Archive finished task/ })
      ).toHaveAttribute("aria-selected", "true");
    });
    onActiveValueChange.mockClear();

    input.focus();
    await user.keyboard("{ArrowDown}");
    await waitFor(() => {
      expect(onActiveValueChange).toHaveBeenLastCalledWith("open-settings", "keyboard");
    });

    onActiveValueChange.mockClear();
    const archiveOption = screen.getByRole("option", {
      name: /Archive finished task/,
    });
    const settingsOption = screen.getByRole("option", { name: /Open settings/ });
    expect(screen.getByRole("region", { name: "Task preview" })).toHaveTextContent(
      "open-settings"
    );

    vi.useFakeTimers();
    fireEvent.pointerMove(archiveOption, { pointerType: "mouse" });

    expect(onActiveValueChange).toHaveBeenCalledOnce();
    expect(onActiveValueChange).toHaveBeenLastCalledWith("archive-task", "pointer");
    expect(archiveOption).toHaveAttribute("aria-selected", "true");
    expect(settingsOption).toHaveAttribute("aria-selected", "false");
    expect(onPointerIntent).not.toHaveBeenCalled();
    expect(screen.getByRole("region", { name: "Task preview" })).toHaveTextContent(
      "open-settings"
    );

    fireEvent.pointerLeave(archiveOption, { pointerType: "mouse" });
    fireEvent.pointerMove(screen.getByRole("region", { name: "Task preview" }), {
      pointerType: "mouse",
    });
    act(() => vi.advanceTimersByTime(motionDuration.pointerIntent));

    expect(onPointerIntentCancel).toHaveBeenCalledOnce();
    expect(onPointerIntentCancel).toHaveBeenLastCalledWith("archive-task");
    expect(settingsOption).toHaveAttribute("aria-selected", "true");
    expect(archiveOption).toHaveAttribute("aria-selected", "false");
    expect(onPointerIntent).not.toHaveBeenCalled();
    expect(screen.getByRole("region", { name: "Task preview" })).toHaveTextContent(
      "open-settings"
    );

    onActiveValueChange.mockClear();
    onPointerIntentCancel.mockClear();
    fireEvent.pointerMove(archiveOption, { pointerType: "mouse" });
    expect(onActiveValueChange).toHaveBeenCalledOnce();
    expect(onActiveValueChange).toHaveBeenLastCalledWith("archive-task", "pointer");
    expect(archiveOption).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("region", { name: "Task preview" })).toHaveTextContent(
      "open-settings"
    );

    act(() => vi.advanceTimersByTime(motionDuration.pointerIntent - 1));
    expect(onPointerIntent).not.toHaveBeenCalled();
    expect(screen.getByRole("region", { name: "Task preview" })).toHaveTextContent(
      "open-settings"
    );

    act(() => vi.advanceTimersByTime(1));
    expect(onPointerIntent).toHaveBeenCalledOnce();
    expect(onPointerIntent).toHaveBeenLastCalledWith("archive-task");
    expect(onPointerIntentCancel).not.toHaveBeenCalled();
    expect(archiveOption).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("region", { name: "Task preview" })).toHaveTextContent(
      "archive-task"
    );
  });

  it("accepts a controlled active item", async () => {
    render(
      <CommandPalette<TestValue>
        activeValue="open-settings"
        groups={groups}
        label="Search Comma"
        onActiveValueChange={vi.fn()}
        onOpenChange={vi.fn()}
        onQueryChange={vi.fn()}
        onSelect={vi.fn()}
        open
        query=""
      />
    );

    await waitFor(() => {
      expect(screen.getByRole("option", { name: /Open settings/ })).toHaveAttribute(
        "aria-selected",
        "true"
      );
    });
  });

  it("keeps query and open state controlled", async () => {
    const user = userEvent.setup();
    const onOpenChange = vi.fn();
    const onQueryChange = vi.fn();
    render(
      <CommandPalette
        closeLabel="Close command palette"
        groups={groups}
        label="Search Comma"
        onOpenChange={onOpenChange}
        onQueryChange={onQueryChange}
        onSelect={vi.fn()}
        open
        query="go"
      />
    );

    const input = screen.getByRole("combobox", { name: "Search Comma" });
    await user.type(input, "x");
    expect(onQueryChange).toHaveBeenCalledWith("gox");
    expect(input).toHaveValue("go");

    await user.click(screen.getByRole("button", { name: "Close command palette" }));
    expect(onOpenChange).toHaveBeenCalledWith(false);
  });

  it("lets the focused close button own Enter without selecting a command", async () => {
    const user = userEvent.setup();
    const onOpenChange = vi.fn();
    const onSelect = vi.fn();
    render(
      <CommandPalette
        closeLabel="Close command palette"
        groups={groups}
        label="Search Comma"
        onOpenChange={onOpenChange}
        onQueryChange={vi.fn()}
        onSelect={onSelect}
        open
        query=""
      />
    );

    const close = screen.getByRole("button", { name: "Close command palette" });
    expect(close).toHaveClass(
      "outline-none",
      "hover:bg-sidebar-bg-item",
      "focus-visible:shadow-focus-gray-shadow-xs"
    );
    close.focus();
    await user.keyboard("{Enter}");

    expect(onOpenChange).toHaveBeenCalledOnce();
    expect(onOpenChange).toHaveBeenCalledWith(false);
    expect(onSelect).not.toHaveBeenCalled();
  });

  it("leaves Ctrl+K unhandled for the application shortcut listener", async () => {
    const user = userEvent.setup();
    const observed: boolean[] = [];
    const listener = (event: KeyboardEvent) => {
      if (event.key === "k" && event.ctrlKey) observed.push(event.defaultPrevented);
    };
    window.addEventListener("keydown", listener);

    render(
      <CommandPalette
        groups={groups}
        label="Search Comma"
        onOpenChange={vi.fn()}
        onQueryChange={vi.fn()}
        onSelect={vi.fn()}
        open
        query=""
      />
    );

    screen.getByRole("combobox", { name: "Search Comma" }).focus();
    await user.keyboard("{Control>}k{/Control}");
    window.removeEventListener("keydown", listener);

    expect(observed).toEqual([false]);
  });

  it("shows mutually exclusive loading and empty states", () => {
    const props = {
      groups: [],
      label: "Search Comma",
      onOpenChange: vi.fn(),
      onQueryChange: vi.fn(),
      onSelect: vi.fn(),
      open: true,
      query: "missing",
    } as const;
    const { rerender, unmount } = render(
      <CommandPalette {...props} emptyDescription="Try another task title or action." />
    );

    expect(screen.getByText("No results found")).toBeInTheDocument();
    expect(screen.getByText("Try another task title or action.")).toBeInTheDocument();
    const emptyState = document.querySelector<HTMLElement>(
      '[data-slot="command-palette-empty"]'
    );
    expect(emptyState).toHaveClass("size-full", "items-center", "justify-center");
    expect(emptyState?.closest('[data-slot="scroll-area-content"]')).toBeNull();
    expect(document.querySelector('[data-slot="scroll-area"]')).toBeNull();
    expect(screen.getByRole("status")).toHaveTextContent(
      "Search results: No results found Try another task title or action."
    );
    expect(screen.queryByRole("progressbar")).not.toBeInTheDocument();

    rerender(
      <CommandPalette
        {...props}
        groups={groups}
        loading
        loadingLabel="Indexing tasks"
        loadingProgress={35}
      />
    );
    expect(screen.queryByText("No results found")).not.toBeInTheDocument();
    expect(screen.queryByText("Tasks")).not.toBeInTheDocument();
    expect(screen.getByRole("progressbar", { name: "Indexing tasks" })).toHaveAttribute(
      "aria-valuenow",
      "35"
    );
    const loadingState = document.querySelector<HTMLElement>(
      '[data-slot="command-palette-loading"]'
    );
    expect(loadingState?.closest('[data-slot="scroll-area-content"]')).toBeNull();
    expect(document.querySelector('[data-slot="scroll-area"]')).toBeNull();
    expect(screen.getByRole("status")).toHaveTextContent(
      "Search results: Indexing tasks"
    );

    unmount();
    expect(isNativeSurfaceSuppressed()).toBe(false);
  });
});
