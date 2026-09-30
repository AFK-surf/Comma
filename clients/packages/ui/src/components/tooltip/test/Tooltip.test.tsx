import { describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";

import { Button } from "../../Button";
import { Tooltip } from "../Tooltip";

describe("Tooltip", () => {
  it("renders the Figma surface and shortcut keycaps", async () => {
    render(
      <Tooltip
        defaultOpen
        delay={0}
        content="Comma assistant"
        placement="right"
        shortcut={["G", "C"]}
      >
        <button type="button">Target</button>
      </Tooltip>
    );

    const tooltip = screen.getByRole("tooltip");
    const bubble = tooltip.querySelector('[data-slot="tooltip-bubble"]');
    const shortcut = screen.getByLabelText("Keyboard shortcut: G C");

    expect(tooltip).toHaveAttribute("data-side", "right");
    expect(tooltip).toHaveAttribute("data-instant", "true");
    expect(tooltip).toHaveClass("comma-tooltip");
    expect(bubble).toHaveClass(
      "rounded-md",
      "border-tooltip-border",
      "bg-tooltip-bg",
      "shadow-xs"
    );
    expect(shortcut.querySelectorAll("kbd")).toHaveLength(2);
    expect(screen.getByText("G")).toHaveClass(
      "size-[calc(18px*0.9)]",
      "bg-tooltip-shortcut-bg"
    );
    expect(screen.getByText("C")).toHaveClass(
      "size-[calc(18px*0.9)]",
      "bg-tooltip-shortcut-bg"
    );
    expect(document.querySelector('[data-slot="tooltip-arrow"]')).toBeNull();
  });

  it("places shortcut keycaps between the label and suffix", () => {
    render(
      <Tooltip
        defaultOpen
        delay={0}
        content="Click or hold"
        shortcut={["⌃", "D"]}
        suffix="to dictate"
      >
        <button type="button">Target</button>
      </Tooltip>
    );

    expect(screen.getByRole("tooltip")).toHaveTextContent("Click or hold");
    expect(screen.getByRole("tooltip")).toHaveTextContent("to dictate");
    expect(
      screen.getByLabelText("Keyboard shortcut: ⌃ D").querySelectorAll("kbd")
    ).toHaveLength(2);
  });

  it("renders stacked shortcut rows", () => {
    render(
      <Tooltip
        defaultOpen
        delay={0}
        content="Send"
        rows={[
          { label: "Send", shortcut: "↩", shortcutLabel: "Enter" },
          { label: "New line", shortcut: ["⇧", "↩"], shortcutLabel: "Shift Enter" },
        ]}
      >
        <button type="button">Target</button>
      </Tooltip>
    );

    expect(screen.getByRole("tooltip")).toHaveTextContent("Send");
    expect(screen.getByRole("tooltip")).toHaveTextContent("New line");
    expect(screen.getByLabelText("Keyboard shortcut: Enter")).toHaveTextContent("↩");
    expect(
      screen.getByLabelText("Keyboard shortcut: Shift Enter").querySelectorAll("kbd")
    ).toHaveLength(2);
  });

  it("uses direct placement names while preserving the legacy arrow mapping", async () => {
    const { rerender } = render(
      <Tooltip defaultOpen delay={0} content="Tip" placement="bottom">
        <button type="button">Target</button>
      </Tooltip>
    );

    expect(screen.getByRole("tooltip")).toHaveAttribute("data-side", "bottom");

    rerender(
      <Tooltip defaultOpen delay={0} content="Tip" arrow="right">
        <button type="button">Target</button>
      </Tooltip>
    );

    expect(screen.getByRole("tooltip")).toHaveAttribute("data-side", "left");
  });

  it("opens immediately without motion on keyboard focus", async () => {
    const user = userEvent.setup();
    render(
      <Tooltip content="Keyboard tip" delay={300}>
        <Button>Focus target</Button>
      </Tooltip>
    );

    await user.tab();

    expect(
      await screen.findByRole("tooltip", { name: "Keyboard tip" })
    ).toHaveAttribute("data-instant", "true");
  });

  it("supports controlled visibility without blocking a later reopen", async () => {
    const user = userEvent.setup();
    const onOpenChange = vi.fn();
    const { rerender } = render(
      <Tooltip
        content="Controlled tip"
        delay={0}
        isOpen={false}
        onOpenChange={onOpenChange}
      >
        <Button>Controlled trigger</Button>
      </Tooltip>
    );
    const trigger = screen.getByRole("button", { name: "Controlled trigger" });

    setInteractionModality("pointer");
    await user.hover(trigger);
    expect(onOpenChange).toHaveBeenLastCalledWith(true);
    expect(screen.queryByRole("tooltip")).toBeNull();

    rerender(
      <Tooltip content="Controlled tip" delay={0} isOpen onOpenChange={onOpenChange}>
        <Button>Controlled trigger</Button>
      </Tooltip>
    );
    expect(screen.getByRole("tooltip")).toHaveTextContent("Controlled tip");

    rerender(
      <Tooltip
        content="Controlled tip"
        delay={0}
        isOpen={false}
        onOpenChange={onOpenChange}
      >
        <Button>Controlled trigger</Button>
      </Tooltip>
    );
    expect(screen.queryByRole("tooltip")).toBeNull();

    await user.unhover(trigger);
    await user.hover(trigger);
    expect(onOpenChange).toHaveBeenLastCalledWith(true);
  });

  it("keeps the tooltip surface continuous while moving between adjacent triggers", async () => {
    const user = userEvent.setup();
    render(
      <div>
        <Tooltip content="First" delay={10}>
          <Button>First trigger</Button>
        </Tooltip>
        <Tooltip content="Second" delay={10}>
          <Button>Second trigger</Button>
        </Tooltip>
      </div>
    );

    const firstTrigger = screen.getByRole("button", { name: "First trigger" });
    const secondTrigger = screen.getByRole("button", { name: "Second trigger" });

    setInteractionModality("pointer");
    await user.hover(firstTrigger);
    expect(await screen.findByText("First")).toBeInTheDocument();

    await user.unhover(firstTrigger);
    expect(screen.getByText("First")).toBeInTheDocument();

    await user.hover(secondTrigger);
    const secondTooltip = await screen.findByRole("tooltip", { name: "Second" });
    expect(secondTooltip).toHaveAttribute("data-instant", "true");
    await waitFor(() => expect(screen.queryByText("First")).not.toBeInTheDocument());
  });

  it("starts a new motion cycle after the previous surface unmounts", async () => {
    const user = userEvent.setup();
    render(
      <div>
        <Tooltip closeDelay={0} content="First cycle" delay={10}>
          <Button>First cycle trigger</Button>
        </Tooltip>
        <Tooltip content="Second cycle" delay={10}>
          <Button>Second cycle trigger</Button>
        </Tooltip>
      </div>
    );

    const firstTrigger = screen.getByRole("button", {
      name: "First cycle trigger",
    });
    const secondTrigger = screen.getByRole("button", {
      name: "Second cycle trigger",
    });

    setInteractionModality("pointer");
    await user.hover(firstTrigger);
    expect(await screen.findByText("First cycle")).toBeInTheDocument();

    await user.unhover(firstTrigger);
    await waitFor(() =>
      expect(screen.queryByText("First cycle")).not.toBeInTheDocument()
    );
    await user.hover(secondTrigger);

    expect(
      await screen.findByRole("tooltip", { name: "Second cycle" })
    ).not.toHaveAttribute("data-instant");
  });

  it("widens word keycaps such as Space", () => {
    render(
      <Tooltip defaultOpen delay={0} content="Play" shortcut="Space">
        <button type="button">Target</button>
      </Tooltip>
    );

    const spaceKey = screen.getByText("Space");
    expect(spaceKey).toHaveClass(
      "h-[calc(18px*0.9)]",
      "min-w-[calc(18px*0.9)]",
      "px-xs"
    );
    expect(spaceKey).not.toHaveClass("size-[calc(18px*0.9)]");
  });
});
