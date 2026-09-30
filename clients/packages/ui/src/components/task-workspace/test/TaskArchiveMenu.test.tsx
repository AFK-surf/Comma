import { initializeCommaI18n } from "@comma/i18n";
import { fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { TaskArchiveMenu, type TaskArchiveAction } from "../TaskArchiveMenu";

describe("TaskArchiveMenu", () => {
  beforeEach(() => initializeCommaI18n(["en"]));

  it.each([
    { inline: false, tagName: "DIV" },
    { inline: true, tagName: "SPAN" },
  ])(
    "keeps its $tagName wrapper while archive eligibility changes",
    async ({ inline, tagName }) => {
      const user = userEvent.setup();
      const run = vi.fn().mockResolvedValue(undefined);
      const allowed: TaskArchiveAction = { run };
      const disabled: TaskArchiveAction = {
        disabledReason: "This task cannot be archived",
        run,
      };
      const view = (action?: TaskArchiveAction) => (
        <TaskArchiveMenu action={action} inline={inline}>
          <button data-testid="task-link">Open task</button>
        </TaskArchiveMenu>
      );
      const { rerender } = render(view());
      const child = screen.getByTestId("task-link");
      const wrapper = child.parentElement;

      expect(wrapper?.tagName).toBe(tagName);
      expect(screen.queryByRole("button", { name: "Archive task" })).toBeNull();

      fireEvent.contextMenu(wrapper!);
      expect(run).not.toHaveBeenCalled();
      rerender(view(allowed));
      expect(screen.getByTestId("task-link")).toBe(child);
      expect(child.parentElement).toBe(wrapper);
      await user.click(screen.getByRole("button", { name: "Archive task" }));
      expect(screen.getByRole("menuitem", { name: "Archive task" })).toBeVisible();

      rerender(view(disabled));
      expect(screen.getByTestId("task-link")).toBe(child);
      expect(child.parentElement).toBe(wrapper);
      expect(screen.queryByRole("button", { name: "Archive task" })).toBeNull();
      await waitFor(() =>
        expect(screen.queryByRole("menuitem", { name: "Archive task" })).toBeNull()
      );
      fireEvent.contextMenu(wrapper!);
      expect(run).not.toHaveBeenCalled();
      expect(screen.queryByRole("menuitem", { name: "Archive task" })).toBeNull();

      rerender(view(allowed));
      expect(screen.getByTestId("task-link")).toBe(child);
      expect(child.parentElement).toBe(wrapper);
      expect(screen.getByRole("button", { name: "Archive task" })).toBeVisible();
      expect(screen.queryByRole("menuitem", { name: "Archive task" })).toBeNull();
    }
  );

  it("keeps More as an overlay sibling of the wrapped control", async () => {
    const run = vi.fn().mockResolvedValue(undefined);
    const user = userEvent.setup();
    render(
      <TaskArchiveMenu action={{ run }}>
        <button type="button">Open task</button>
      </TaskArchiveMenu>
    );

    const open = screen.getByRole("button", { name: "Open task" });
    const more = screen.getByRole("button", { name: "Archive task" });
    expect(open.contains(more)).toBe(false);
    expect(open.parentElement).toContainElement(more);

    await user.click(more);
    await user.click(screen.getByRole("menuitem", { name: "Archive task" }));
    expect(run).toHaveBeenCalledOnce();
  });

  it("lets a caller place More among sibling hover actions", async () => {
    const run = vi.fn().mockResolvedValue(undefined);
    const onOpen = vi.fn();
    const user = userEvent.setup();
    render(
      <TaskArchiveMenu action={{ run }}>
        {(trigger) => (
          <div data-testid="cluster">
            <button onClick={onOpen} type="button">
              Open task
            </button>
            <button type="button">Dismiss</button>
            {trigger}
          </div>
        )}
      </TaskArchiveMenu>
    );

    const cluster = screen.getByTestId("cluster");
    const more = screen.getByRole("button", { name: "Archive task" });
    expect(cluster).toContainElement(more);
    expect(cluster.parentElement?.querySelector(":scope > span.absolute")).toBeNull();

    await user.click(more);
    expect(onOpen).not.toHaveBeenCalled();
    await user.click(screen.getByRole("menuitem", { name: "Archive task" }));
    expect(run).toHaveBeenCalledOnce();
  });

  it("renders children without Archive when Archive is unavailable", () => {
    render(
      <TaskArchiveMenu>
        {(trigger) => (
          <div>
            <button type="button">Open task</button>
            {trigger}
          </div>
        )}
      </TaskArchiveMenu>
    );

    expect(screen.getByRole("button", { name: "Open task" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Archive task" })).toBeNull();
  });
});
