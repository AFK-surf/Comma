import { render, screen } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { SettingsShortcutKeycaps } from "../SettingsShortcutKeycaps";

describe("SettingsShortcutKeycaps", () => {
  it("renders compact and wide keycaps without becoming a button", () => {
    render(<SettingsShortcutKeycaps keys={["Space", "M", "Click"]} />);

    const shortcut = screen.getByLabelText("Keyboard shortcut: Space M Click");
    const spaceKey = screen.getByText("␣");
    const muteKey = screen.getByText("M");

    expect(shortcut).toHaveAttribute("data-slot", "settings-keycaps");
    expect(shortcut.tagName).toBe("SPAN");
    expect(screen.queryByRole("button")).toBeNull();
    expect(spaceKey.closest(".settings-shortcut__keycap-shell")).not.toHaveAttribute(
      "data-wide"
    );
    expect(
      screen.getByText("Click").closest(".settings-shortcut__keycap-shell")
    ).toHaveAttribute("data-wide", "true");
    expect(muteKey.closest(".settings-shortcut__keycap-shell")).not.toHaveAttribute(
      "data-wide"
    );
  });
});
