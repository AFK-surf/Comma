import userEvent from "@testing-library/user-event";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { AppKeybindingShortcut } from "../AppKeybindingShortcut";
import { sequenceKeybinding } from "../appKeybinding";

describe("AppKeybindingShortcut", () => {
  it("records a two-key sequence and reports it", async () => {
    const onChange = vi.fn();
    render(
      <AppKeybindingShortcut
        ariaLabel="Go to Inbox"
        onChange={onChange}
        value={sequenceKeybinding("KeyG", "KeyI")}
      />
    );

    const control = screen.getByRole("button", { name: "Go to Inbox: G then I" });
    await userEvent.click(control);
    await userEvent.keyboard("ab");

    await waitFor(
      () =>
        expect(onChange).toHaveBeenCalledWith({
          kind: "sequence",
          codes: ["KeyA", "KeyB"],
        }),
      { timeout: 2_000 }
    );
  });

  it("ignores auto-repeat while recording a sequence", async () => {
    const onChange = vi.fn();
    render(
      <AppKeybindingShortcut
        ariaLabel="Go to Inbox"
        onChange={onChange}
        value={sequenceKeybinding("KeyG", "KeyI")}
      />
    );

    const control = screen.getByRole("button", { name: "Go to Inbox: G then I" });
    await userEvent.click(control);
    fireEvent.keyDown(control, { code: "KeyG", key: "g" });
    fireEvent.keyDown(control, { code: "KeyG", key: "g", repeat: true });
    fireEvent.keyDown(control, { code: "KeyG", key: "g", repeat: true });

    expect(onChange).not.toHaveBeenCalled();

    fireEvent.keyDown(control, { code: "KeyI", key: "i" });
    await waitFor(
      () =>
        expect(onChange).toHaveBeenCalledWith({
          kind: "sequence",
          codes: ["KeyG", "KeyI"],
        }),
      { timeout: 2_000 }
    );
  });

  it("shows readable modifier previews while recording on Windows", async () => {
    render(
      <AppKeybindingShortcut
        ariaLabel="Toggle sidebar"
        platform="windows"
        value={sequenceKeybinding("KeyG", "KeyI")}
      />
    );

    const control = screen.getByRole("button", {
      name: "Toggle sidebar: G then I",
    });
    await userEvent.click(control);
    fireEvent.keyDown(control, {
      code: "ControlLeft",
      ctrlKey: true,
      key: "Control",
    });

    expect(screen.getByText("Ctrl", { selector: "kbd" })).toBeInTheDocument();
  });
});
