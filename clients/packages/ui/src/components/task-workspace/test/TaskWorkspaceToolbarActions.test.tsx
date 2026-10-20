import userEvent from "@testing-library/user-event";
import { render, screen, within } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { TaskSectionFilterPanel } from "../TaskWorkspaceToolbarActions";

describe("TaskSectionFilterPanel", () => {
  it("moves Tab from the search field straight to the options", async () => {
    const user = userEvent.setup();
    render(
      <TaskSectionFilterPanel
        section={{
          icon: null,
          id: "loopRule",
          label: "Trigger rule",
          narrowed: false,
          onChange: vi.fn(),
          options: [
            { count: 2, id: "all", label: "All tasks" },
            { count: 1, id: "pr", label: "Pull request updated" },
          ],
          selected: new Set(["all"]),
          selectionMode: "single",
        }}
      />
    );
    const panel = screen.getByRole("dialog", { name: "Trigger rule" });
    await user.click(within(panel).getByRole("textbox"));
    await user.tab();
    expect(within(panel).getByRole("menu", { name: "Trigger rule" })).toContainElement(
      document.activeElement as HTMLElement
    );
  });
});
