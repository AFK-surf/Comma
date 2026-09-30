import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { InlineTextEditor } from "../InlineTextEditor";

describe("InlineTextEditor", () => {
  it("opens over the text, commits on Enter and reverts on Escape", async () => {
    const user = userEvent.setup();
    const onCommit = vi.fn();
    render(
      <table>
        <tbody>
          <tr>
            <td>
              <InlineTextEditor
                disabled={false}
                label="Edit label name"
                onCommit={onCommit}
                placeholder="Label name"
                value="Work"
              />
            </td>
          </tr>
        </tbody>
      </table>
    );

    const trigger = screen.getByRole("button", { name: "Work" });
    await user.click(trigger);
    const input = await screen.findByTestId("inline-text-editor");
    expect(input).toHaveValue("Work");
    expect(trigger).toHaveAttribute("data-editing", "true");
    await user.clear(input);
    await user.type(input, "Design{Enter}");
    await waitFor(() => expect(onCommit).toHaveBeenCalledWith("Design"));
    await waitFor(() => expect(screen.queryByTestId("inline-text-editor")).toBeNull());

    onCommit.mockClear();
    await user.click(screen.getByRole("button", { name: "Work" }));
    const again = await screen.findByTestId("inline-text-editor");
    await user.type(again, " later{Escape}");
    await waitFor(() => expect(screen.queryByTestId("inline-text-editor")).toBeNull());
    expect(onCommit).not.toHaveBeenCalled();
  });

  it("opens once per request and stays closed while the row's write settles", async () => {
    const user = userEvent.setup();
    const onCommit = vi.fn();
    const view = (disabled: boolean) => (
      <table>
        <tbody>
          <tr>
            <td>
              <InlineTextEditor
                disabled={disabled}
                editRequest={1}
                label="Edit label name"
                onCommit={onCommit}
                placeholder="Label name"
                value="Work"
              />
            </td>
          </tr>
        </tbody>
      </table>
    );
    const { rerender } = render(view(false));
    const input = await screen.findByTestId("inline-text-editor");
    await user.clear(input);
    await user.type(input, "Design{Enter}");
    await waitFor(() => expect(onCommit).toHaveBeenCalledWith("Design"));
    // The row goes busy for the write, then idle again: no second opening.
    rerender(view(true));
    rerender(view(false));
    await waitFor(() => expect(screen.queryByTestId("inline-text-editor")).toBeNull());
    expect(onCommit).toHaveBeenCalledTimes(1);
  });
});
