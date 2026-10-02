import userEvent from "@testing-library/user-event";
import { act, fireEvent, render, screen } from "@comma/test-utils/render";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { formatSettingsShortcut, SettingsShortcut } from "../SettingsShortcut";

const shortcut = {
  key: "z",
  modifiers: {
    alt: false,
    control: true,
    meta: false,
    shift: false,
  },
} as const;

describe("SettingsShortcut", () => {
  it("records Option-Space from its physical key code", async () => {
    const onChange = vi.fn();
    render(
      <SettingsShortcut ariaLabel="Open Comma" value={null} onChange={onChange} />
    );
    const recorder = screen.getByRole("button", { name: /Open Comma:/ });
    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, { code: "Space", key: " ", altKey: true });
    fireEvent.keyUp(recorder, { code: "Space", key: " ", altKey: true });
    expect(onChange).toHaveBeenCalledWith({
      key: "space",
      modifiers: { alt: true, control: false, meta: false, shift: false },
    });
    expect(formatSettingsShortcut(onChange.mock.calls[0]![0])).toBe("Alt + Space");
  });

  it("records Option-Comma from its physical key, whatever character Option types", async () => {
    const onChange = vi.fn();
    render(
      <SettingsShortcut ariaLabel="Open Comma" value={null} onChange={onChange} />
    );
    const recorder = screen.getByRole("button", { name: /Open Comma:/ });
    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, { code: "Comma", key: "≤", altKey: true });
    fireEvent.keyUp(recorder, { code: "Comma", key: "≤", altKey: true });
    expect(onChange).toHaveBeenCalledWith({
      key: "comma",
      modifiers: { alt: true, control: false, meta: false, shift: false },
    });
    expect(formatSettingsShortcut(onChange.mock.calls[0]![0])).toBe("Alt + ,");
  });

  it("formats the default Control-Z shortcut", () => {
    expect(formatSettingsShortcut(shortcut)).toBe("Ctrl + Z");
    render(<SettingsShortcut ariaLabel="Open Side Chat" value={shortcut} />);

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    expect(recorder).toBeInTheDocument();
    expect(recorder).toHaveAttribute("data-state", "idle");
    expect(screen.getByText("⌃")).toBeInTheDocument();
    expect(screen.getByText("Z")).toBeInTheDocument();
    expect(screen.queryByText("Ctrl")).not.toBeInTheDocument();
  });

  it("renders an unset shortcut as two keycaps and can record from that state", async () => {
    const onChange = vi.fn();
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        emptyLabel="Not set"
        onChange={onChange}
        onClear={vi.fn()}
        value={null}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Not set",
    });
    expect(screen.getAllByText("-")).toHaveLength(2);

    await userEvent.click(recorder);
    expect(recorder).toHaveAttribute("data-state", "editing");
    expect(
      screen.queryByRole("button", { name: "Clear shortcut" })
    ).not.toBeInTheDocument();

    fireEvent.keyDown(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });
    fireEvent.keyUp(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });

    expect(onChange).toHaveBeenCalledWith({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
  });

  it("clears from the sibling circle-minus action without blur cancelling the click", async () => {
    const user = userEvent.setup();
    const onClear = vi.fn();
    const { rerender } = render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        clearLabel="Clear shortcut"
        emptyLabel="Not set"
        onClear={onClear}
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await user.click(recorder);

    const clear = screen.getByRole("button", { name: "Clear shortcut" });
    expect(clear).toHaveAttribute("data-slot", "settings-shortcut-clear");
    await user.tab();
    expect(clear).toHaveFocus();
    expect(recorder).toHaveAttribute("aria-pressed", "true");
    await user.click(clear);

    expect(onClear).toHaveBeenCalledOnce();
    expect(recorder).toHaveFocus();
    expect(recorder).toHaveAttribute("data-state", "idle");

    rerender(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        clearLabel="Clear shortcut"
        emptyLabel="Not set"
        onClear={onClear}
        value={null}
      />
    );
    expect(recorder).toHaveAccessibleName("Open Side Chat: Not set");
    expect(screen.getAllByText("-")).toHaveLength(2);
    expect(
      screen.queryByRole("button", { name: "Clear shortcut" })
    ).not.toBeInTheDocument();
  });

  it("keeps the unset state visible while an asynchronous clear is pending", async () => {
    const user = userEvent.setup();
    let rejectClear: ((reason?: unknown) => void) | undefined;
    const clearResult = new Promise<void>((_resolve, reject) => {
      rejectClear = reject;
    });
    const onClear = vi.fn(() => clearResult);
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        emptyLabel="Not set"
        onClear={onClear}
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await user.click(recorder);
    await user.tab();
    await user.click(screen.getByRole("button", { name: "Clear shortcut" }));

    expect(onClear).toHaveBeenCalledOnce();
    expect(recorder).not.toBeDisabled();
    expect(recorder).toHaveAttribute("aria-disabled", "true");
    expect(recorder).toHaveAttribute("aria-busy", "true");
    expect(recorder).toHaveFocus();
    expect(recorder).toHaveAccessibleName("Open Side Chat: Not set");
    expect(screen.getAllByText("-")).toHaveLength(2);

    await act(async () => {
      rejectClear?.(new Error("registration rejected"));
      await clearResult.catch(() => undefined);
    });

    expect(recorder).toHaveAccessibleName("Open Side Chat: Ctrl + Z");
    expect(screen.getByText("Z")).toBeInTheDocument();
    expect(recorder).toBeEnabled();
    expect(recorder).not.toHaveAttribute("aria-disabled");
    expect(recorder).not.toHaveAttribute("aria-busy");
    expect(recorder).toHaveFocus();
  });

  it.each(["Backspace", "Delete"])("clears with an unmodified %s key", async (key) => {
    const onClear = vi.fn();
    render(
      <SettingsShortcut ariaLabel="Open Side Chat" onClear={onClear} value={shortcut} />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, { key });

    expect(onClear).toHaveBeenCalledOnce();
    expect(recorder).toHaveAttribute("data-state", "idle");
  });

  it("mirrors commaboard editing and commits a preview on keyup", async () => {
    const onChange = vi.fn();
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        onChange={onChange}
        recordingLabel="Press shortcut"
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    expect(recorder).toHaveAttribute("data-state", "editing");
    expect(screen.queryByText("Press shortcut")).not.toBeInTheDocument();
    expect(screen.getByText("⌃")).toBeInTheDocument();
    expect(screen.getByText("Z")).toBeInTheDocument();

    fireEvent.keyDown(recorder, {
      code: "ControlLeft",
      ctrlKey: true,
      key: "Control",
    });
    expect(recorder).toHaveAttribute("data-state", "editing");
    expect(screen.getByText("⌃")).toBeInTheDocument();
    expect(screen.queryByText("Z")).not.toBeInTheDocument();

    fireEvent.keyDown(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });
    expect(recorder).toHaveAttribute("data-state", "recording");
    expect(screen.getByText("K")).toBeInTheDocument();
    expect(onChange).not.toHaveBeenCalled();

    fireEvent.keyUp(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });

    expect(onChange).toHaveBeenCalledWith({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
    expect(recorder).toHaveAttribute("aria-pressed", "false");
  });

  it("records the physical key position instead of the active keyboard layout", async () => {
    const onChange = vi.fn();
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        onChange={onChange}
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, {
      code: "KeyA",
      ctrlKey: true,
      key: "q",
    });

    expect(onChange).not.toHaveBeenCalled();
    expect(recorder).toHaveAttribute("data-state", "recording");
    expect(screen.getByText("A")).toBeInTheDocument();

    fireEvent.keyUp(recorder, {
      code: "KeyA",
      ctrlKey: true,
      key: "q",
    });

    expect(onChange).toHaveBeenCalledWith({
      key: "a",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: false,
      },
    });
  });

  it("does not commit after the active modifier is released first", async () => {
    const onChange = vi.fn();
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        onChange={onChange}
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, {
      code: "ControlLeft",
      ctrlKey: true,
      key: "Control",
    });
    fireEvent.keyDown(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });
    fireEvent.keyUp(recorder, {
      code: "ControlLeft",
      key: "Control",
    });
    fireEvent.keyUp(recorder, {
      code: "KeyK",
      key: "k",
    });

    expect(onChange).not.toHaveBeenCalled();
    expect(recorder).toHaveAttribute("data-state", "editing");
    expect(screen.getByText("Z")).toBeInTheDocument();
  });

  it("keeps a candidate when one of multiple modifiers remains pressed", async () => {
    const onChange = vi.fn();
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        onChange={onChange}
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, {
      code: "ControlLeft",
      ctrlKey: true,
      key: "Control",
    });
    fireEvent.keyDown(recorder, {
      code: "ShiftLeft",
      ctrlKey: true,
      key: "Shift",
      shiftKey: true,
    });
    expect(screen.getByText("⌃")).toBeInTheDocument();
    expect(screen.getByText("⇧")).toBeInTheDocument();
    expect(screen.queryByText("K")).not.toBeInTheDocument();

    fireEvent.keyDown(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
      shiftKey: true,
    });
    expect(screen.getByText("⌃")).toBeInTheDocument();
    expect(screen.getByText("⇧")).toBeInTheDocument();
    expect(screen.getByText("K")).toBeInTheDocument();
    fireEvent.keyUp(recorder, {
      code: "ShiftLeft",
      ctrlKey: true,
      key: "Shift",
    });

    expect(recorder).toHaveAttribute("data-state", "recording");
    expect(screen.getByText("K")).toBeInTheDocument();

    fireEvent.keyUp(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });

    expect(onChange).toHaveBeenCalledWith({
      key: "k",
      modifiers: {
        alt: false,
        control: true,
        meta: false,
        shift: true,
      },
    });
  });

  it("keeps clear available for modifier previews and hides it for candidates", async () => {
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        clearLabel="Clear shortcut"
        onClear={vi.fn()}
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    expect(screen.getByRole("button", { name: "Clear shortcut" })).toBeInTheDocument();

    fireEvent.keyDown(recorder, {
      code: "ControlLeft",
      ctrlKey: true,
      key: "Control",
    });
    expect(screen.getByRole("button", { name: "Clear shortcut" })).toBeInTheDocument();

    fireEvent.keyDown(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });
    expect(
      screen.queryByRole("button", { name: "Clear shortcut" })
    ).not.toBeInTheDocument();
  });

  it("requires Control, Alt, or Command and treats Shift as an addition", async () => {
    const onChange = vi.fn();
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        onChange={onChange}
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, {
      code: "ShiftLeft",
      key: "Shift",
      shiftKey: true,
    });
    fireEvent.keyDown(recorder, {
      code: "KeyK",
      key: "k",
      shiftKey: true,
    });
    fireEvent.keyUp(recorder, {
      code: "KeyK",
      key: "k",
      shiftKey: true,
    });

    expect(onChange).not.toHaveBeenCalled();
    expect(recorder).toHaveAttribute("data-state", "editing");
    expect(screen.getByText("Z")).toBeInTheDocument();
  });

  it("locks the committed candidate while registration is pending", async () => {
    let resolveRegistration: (() => void) | undefined;
    const registration = new Promise<void>((resolve) => {
      resolveRegistration = resolve;
    });
    const onChange = vi.fn();
    const Consumer = () => {
      const [registrationPending, setRegistrationPending] = useState(false);

      return (
        <SettingsShortcut
          ariaLabel="Open Side Chat"
          disabled={registrationPending}
          onChange={async (nextShortcut) => {
            onChange(nextShortcut);
            setRegistrationPending(true);
            try {
              await registration;
            } finally {
              setRegistrationPending(false);
            }
          }}
          value={shortcut}
        />
      );
    };
    render(<Consumer />);

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });
    fireEvent.keyUp(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });

    expect(onChange).toHaveBeenCalledOnce();
    expect(recorder).not.toBeDisabled();
    expect(recorder).toHaveAttribute("aria-disabled", "true");
    expect(recorder).toHaveAttribute("aria-busy", "true");
    expect(recorder).toHaveFocus();
    expect(recorder).toHaveAccessibleName("Open Side Chat: Ctrl + K");
    expect(screen.getByText("K")).toBeInTheDocument();
    expect(screen.queryByText("Z")).not.toBeInTheDocument();

    await act(async () => {
      resolveRegistration?.();
      await registration;
    });

    expect(recorder).toHaveAccessibleName("Open Side Chat: Ctrl + Z");
    expect(recorder).toBeEnabled();
    expect(recorder).not.toHaveAttribute("aria-disabled");
    expect(recorder).not.toHaveAttribute("aria-busy");
    expect(recorder).toHaveFocus();
  });

  it("rolls a rejected candidate back to the confirmed shortcut", async () => {
    let rejectRegistration: ((reason?: unknown) => void) | undefined;
    const registration = new Promise<void>((_resolve, reject) => {
      rejectRegistration = reject;
    });
    const onChange = vi.fn(() => registration);
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        onChange={onChange}
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });
    fireEvent.keyUp(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });

    expect(recorder).not.toBeDisabled();
    expect(recorder).toHaveAttribute("aria-disabled", "true");
    expect(recorder).toHaveAttribute("aria-busy", "true");
    expect(recorder).toHaveFocus();
    expect(recorder).toHaveAccessibleName("Open Side Chat: Ctrl + K");

    await act(async () => {
      rejectRegistration?.(new Error("registration rejected"));
      await registration.catch(() => undefined);
    });

    expect(recorder).toBeEnabled();
    expect(recorder).not.toHaveAttribute("aria-disabled");
    expect(recorder).not.toHaveAttribute("aria-busy");
    expect(recorder).toHaveFocus();
    expect(recorder).toHaveAccessibleName("Open Side Chat: Ctrl + Z");
    expect(screen.getByText("Z")).toBeInTheDocument();
    expect(screen.queryByText("K")).not.toBeInTheDocument();
  });

  it("blocks reentry while its asynchronous update is pending", async () => {
    let resolveRegistration: (() => void) | undefined;
    const registration = new Promise<void>((resolve) => {
      resolveRegistration = resolve;
    });
    const onChange = vi.fn(() => registration);
    const onClear = vi.fn();
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        onChange={onChange}
        onClear={onClear}
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });
    fireEvent.keyUp(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });

    expect(onChange).toHaveBeenCalledOnce();
    expect(recorder).toHaveAttribute("aria-disabled", "true");
    expect(recorder).toHaveAttribute("aria-busy", "true");

    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, {
      code: "KeyL",
      ctrlKey: true,
      key: "l",
    });
    fireEvent.keyUp(recorder, {
      code: "KeyL",
      ctrlKey: true,
      key: "l",
    });
    fireEvent.keyDown(recorder, { code: "Delete", key: "Delete" });

    expect(onChange).toHaveBeenCalledOnce();
    expect(onClear).not.toHaveBeenCalled();
    expect(recorder).toHaveAccessibleName("Open Side Chat: Ctrl + K");
    expect(recorder).toHaveAttribute("aria-disabled", "true");
    expect(recorder).toHaveAttribute("aria-busy", "true");

    await act(async () => {
      resolveRegistration?.();
      await registration;
    });

    expect(recorder).toHaveAccessibleName("Open Side Chat: Ctrl + Z");
    expect(recorder).not.toHaveAttribute("aria-disabled");
    expect(recorder).not.toHaveAttribute("aria-busy");
  });

  it("external disablement cancels capture and removes the clear action", async () => {
    const onClear = vi.fn();
    const { rerender } = render(
      <SettingsShortcut ariaLabel="Open Side Chat" onClear={onClear} value={shortcut} />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    expect(recorder).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("button", { name: "Clear shortcut" })).toBeInTheDocument();

    rerender(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        disabled
        onClear={onClear}
        value={shortcut}
      />
    );

    expect(recorder).toBeDisabled();
    expect(recorder).toHaveAttribute("aria-pressed", "false");
    expect(recorder).toHaveAttribute("data-state", "disabled");
    expect(recorder).toHaveAccessibleName("Open Side Chat: Ctrl + Z");
    expect(
      screen.queryByRole("button", { name: "Clear shortcut" })
    ).not.toBeInTheDocument();
    expect(onClear).not.toHaveBeenCalled();

    rerender(
      <SettingsShortcut ariaLabel="Open Side Chat" onClear={onClear} value={shortcut} />
    );
    expect(recorder).toBeEnabled();
    expect(recorder).toHaveAttribute("aria-pressed", "false");
    expect(recorder).toHaveAttribute("data-state", "idle");
  });

  it("disables recording while registration is pending and exposes failures", () => {
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        disabled
        errorMessage="Could not register this shortcut."
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    expect(recorder).toBeDisabled();
    expect(recorder).toHaveAttribute("data-state", "error");
    expect(screen.getByRole("alert")).toHaveTextContent(
      "Could not register this shortcut."
    );
  });

  it("hides a previous registration error while editing", async () => {
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        errorMessage="Could not register this shortcut."
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);

    expect(recorder).toHaveAttribute("data-state", "editing");
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("cancels recording with Escape", async () => {
    const onChange = vi.fn();
    render(
      <SettingsShortcut
        ariaLabel="Open Side Chat"
        onChange={onChange}
        value={shortcut}
      />
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await userEvent.click(recorder);
    fireEvent.keyDown(recorder, {
      code: "KeyK",
      ctrlKey: true,
      key: "k",
    });
    expect(recorder).toHaveAttribute("data-state", "recording");
    expect(screen.getByText("K")).toBeInTheDocument();

    fireEvent.keyDown(recorder, {
      code: "Escape",
      key: "Escape",
    });

    expect(onChange).not.toHaveBeenCalled();
    expect(recorder).toHaveAttribute("aria-pressed", "false");
    expect(recorder).toHaveAttribute("data-state", "idle");
    expect(recorder).toHaveAccessibleName("Open Side Chat: Ctrl + Z");
    expect(screen.getByText("Z")).toBeInTheDocument();
    expect(screen.queryByText("K")).not.toBeInTheDocument();
  });

  it("moves through the clear action before Tab cancels recording", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    const onClear = vi.fn();
    render(
      <>
        <SettingsShortcut
          ariaLabel="Open Side Chat"
          onChange={onChange}
          onClear={onClear}
          value={shortcut}
        />
        <button type="button">Next setting</button>
      </>
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    await user.click(recorder);
    expect(screen.getByRole("button", { name: "Clear shortcut" })).toBeInTheDocument();

    await user.tab();

    const clear = screen.getByRole("button", { name: "Clear shortcut" });
    expect(clear).toHaveFocus();
    expect(recorder).toHaveAttribute("aria-pressed", "true");
    expect(recorder).toHaveAttribute("data-state", "editing");

    await user.tab();

    expect(screen.getByRole("button", { name: "Next setting" })).toHaveFocus();
    expect(recorder).toHaveAttribute("aria-pressed", "false");
    expect(recorder).toHaveAttribute("data-state", "idle");
    expect(recorder).toHaveAccessibleName("Open Side Chat: Ctrl + Z");
    expect(
      screen.queryByRole("button", { name: "Clear shortcut" })
    ).not.toBeInTheDocument();
    expect(onChange).not.toHaveBeenCalled();
    expect(onClear).not.toHaveBeenCalled();
  });

  it("cancels recording when focus leaves the compound control", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    const onClear = vi.fn();
    render(
      <>
        <SettingsShortcut
          ariaLabel="Open Side Chat"
          onChange={onChange}
          onClear={onClear}
          value={shortcut}
        />
        <button type="button">Another setting</button>
      </>
    );

    const recorder = screen.getByRole("button", {
      name: "Open Side Chat: Ctrl + Z",
    });
    const outsideControl = screen.getByRole("button", {
      name: "Another setting",
    });
    await user.click(recorder);
    expect(recorder).toHaveAttribute("aria-pressed", "true");

    await user.click(outsideControl);

    expect(outsideControl).toHaveFocus();
    expect(recorder).toHaveAttribute("aria-pressed", "false");
    expect(recorder).toHaveAttribute("data-state", "idle");
    expect(recorder).toHaveAccessibleName("Open Side Chat: Ctrl + Z");
    expect(onChange).not.toHaveBeenCalled();
    expect(onClear).not.toHaveBeenCalled();
  });
});
