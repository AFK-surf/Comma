import { render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { ChoiceList } from "../ChoiceList";

const OPTIONS = [
  { id: "off", label: "Off", description: "No proactive reminders." },
  { id: "action", label: "Action needed", description: "Only when input is needed." },
];

describe("ChoiceList", () => {
  it("selects a radio option and omits shortcut hints when no key handler is attached", async () => {
    const user = userEvent.setup();
    const onChange = vi.fn();
    const { container } = render(
      <>
        <h2 id="heading">Notifications</h2>
        <ChoiceList
          labelledBy="heading"
          name="notifications"
          onChange={onChange}
          options={OPTIONS}
          value={["action"]}
        />
      </>
    );

    const group = screen.getByRole("radiogroup", { name: "Notifications" });
    expect(group).toBeInTheDocument();
    expect(screen.getByRole("radio", { name: /^Action needed/ })).toBeChecked();
    expect(screen.getByRole("radio", { name: /^Off/ })).not.toHaveAttribute(
      "aria-keyshortcuts"
    );
    expect(container.querySelectorAll("kbd")).toHaveLength(0);

    await user.click(screen.getByRole("radio", { name: /^Off/ }));
    expect(onChange).toHaveBeenCalledWith(["off"]);
  });

  it("renders shortcut hints when keyboard shortcuts are wired", () => {
    const { container } = render(
      <>
        <h2 id="heading">Notifications</h2>
        <ChoiceList
          labelledBy="heading"
          name="notifications-keys"
          onChange={() => undefined}
          onOptionKeyDown={() => undefined}
          options={OPTIONS}
          value={["action"]}
        />
      </>
    );

    expect(screen.getByRole("radio", { name: /^Off/ })).toHaveAttribute(
      "aria-keyshortcuts",
      "1"
    );
    expect(container.querySelectorAll("kbd")).toHaveLength(2);
  });
});
