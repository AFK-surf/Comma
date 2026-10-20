import { describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { HOVER_PANEL_ITEM, HoverPanel } from "../HoverPanel";

function Panel({
  onItem = vi.fn(),
  onTrigger = vi.fn(),
}: {
  onItem?: (title: string) => void;
  onTrigger?: () => void;
}) {
  return (
    <HoverPanel
      closeDelay={0}
      delay={0}
      label="2 tasks"
      content={
        <ul>
          {["Weekly report", "Q3 bills"].map((title) => (
            <li key={title}>
              <button
                type="button"
                {...{ [HOVER_PANEL_ITEM]: "" }}
                onClick={() => onItem(title)}
              >
                {title}
              </button>
            </li>
          ))}
        </ul>
      }
    >
      <button type="button" onClick={onTrigger}>
        Working on 2 tasks
      </button>
    </HoverPanel>
  );
}

describe("HoverPanel", () => {
  it("stays open while the pointer moves into it, so its items can be used", async () => {
    const onItem = vi.fn();
    const user = userEvent.setup();
    render(<Panel onItem={onItem} />);

    await user.hover(screen.getByRole("button", { name: "Working on 2 tasks" }));
    const panel = await screen.findByRole("dialog", { name: "2 tasks" });
    const item = within(panel).getByRole("button", { name: "Q3 bills" });
    await user.hover(item);
    await user.click(item);

    expect(onItem).toHaveBeenCalledExactlyOnceWith("Q3 bills");
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  });

  it("lets keyboard users enter, move between items and return to the trigger", async () => {
    const user = userEvent.setup();
    render(<Panel />);
    setInteractionModality("keyboard");

    await user.tab();
    const trigger = screen.getByRole("button", { name: "Working on 2 tasks" });
    expect(trigger).toHaveFocus();
    expect(await screen.findByRole("dialog", { name: "2 tasks" })).toBeInTheDocument();

    await user.keyboard("{ArrowDown}");
    const first = screen.getByRole("button", { name: "Weekly report" });
    await waitFor(() => expect(first).toHaveFocus());
    await user.keyboard("{ArrowDown}");
    expect(screen.getByRole("button", { name: "Q3 bills" })).toHaveFocus();
    await user.keyboard("{ArrowDown}");
    expect(first).toHaveFocus();

    await user.keyboard("{Escape}");
    expect(trigger).toHaveFocus();
    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("keeps the trigger's own action and closes on a press", async () => {
    const onTrigger = vi.fn();
    const user = userEvent.setup();
    render(<Panel onTrigger={onTrigger} />);
    setInteractionModality("pointer");

    const trigger = screen.getByRole("button", { name: "Working on 2 tasks" });
    await user.hover(trigger);
    await screen.findByRole("dialog", { name: "2 tasks" });
    await user.click(trigger);

    expect(onTrigger).toHaveBeenCalledOnce();
    expect(screen.queryByRole("dialog")).toBeNull();
  });
});
