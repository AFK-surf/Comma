import { fireEvent, render, screen } from "@comma/test-utils/render";
import { useState } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { LayoutInspector } from "../LayoutInspector";

describe("LayoutInspector", () => {
  beforeEach(() => {
    vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
      callback(0);
      return 1;
    });
    vi.spyOn(window, "cancelAnimationFrame").mockImplementation(() => {});
  });

  afterEach(() => {
    document.body.style.cursor = "";
  });

  it("portals its UI to the document body above app stacking contexts", () => {
    render(<LayoutInspector defaultActive />);

    const inspector = screen.getByRole("status").closest(".comma-layout-inspector");

    expect(inspector?.parentElement).toBe(document.body);
    expect(inspector).toHaveAttribute("data-react-aria-top-layer", "true");
  });

  it("previews box geometry, pins details, and blocks the inspected click", () => {
    const businessClick = vi.fn();
    render(<InspectorFixture onBusinessClick={businessClick} />);
    const target = screen.getByTestId("inspect-target");

    fireEvent.pointerMove(target, { clientX: 140, clientY: 100 });

    expect(screen.getByTestId("layout-inspector-border-box")).toHaveStyle({
      top: "40px",
      left: "60px",
      width: "240px",
      height: "120px",
    });
    expect(screen.getByTestId("layout-inspector-dimension")).toHaveTextContent(
      "240px × 120px"
    );
    expect(
      document.querySelector('[data-inspector-segment="padding-top"]')
    ).toHaveAttribute("data-inspector-value", "4");
    expect(
      document.querySelector('[data-inspector-segment="margin-left"]')
    ).toHaveAttribute("data-inspector-value", "8");

    fireEvent.pointerDown(target, { button: 0, clientX: 140, clientY: 100 });
    fireEvent.click(target);

    const panel = screen.getByTestId("layout-inspector-panel");
    expect(panel).toBeInTheDocument();
    expect(screen.getByText("Selected element")).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Actions" })).not.toBeInTheDocument();
    expect(panel).not.toHaveTextContent("No pending changes");
    expect(panel).not.toHaveTextContent("Value format");
    expect(panel).not.toHaveTextContent("Variable previews");
    const boxModel = screen.getByTestId("layout-inspector-box-model");
    expect(boxModel).toHaveTextContent("240 × 120");
    expect(boxModel.querySelector(".comma-layout-inspector__box-diagram")).toBeNull();
    expect(
      boxModel.querySelector(
        ':scope > .comma-layout-inspector__box-layer[data-inspector-kind="margin"]'
      )
    ).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Properties" })).toBeInTheDocument();
    const sections = panel.querySelectorAll(
      ":scope > .comma-layout-inspector__panel-section"
    );
    expect(sections).toHaveLength(2);
    expect(sections[0]).toHaveAttribute("data-testid", "layout-inspector-box-model");
    expect(sections[1]).toHaveClass("comma-layout-inspector__properties");
    expect(screen.getByRole("region", { name: "Layout changes" })).toBeInTheDocument();
    expect(
      screen
        .getByLabelText("Padding left variable")
        .closest(".comma-layout-inspector__property")
        ?.querySelector('[data-direction="left"]')
    ).toBeInTheDocument();
    expect(businessClick).not.toHaveBeenCalled();
  });

  it("shows small segment labels and keeps border overlays opt-in", () => {
    render(<InspectorFixture />);
    const target = screen.getByTestId("inspect-target");

    fireEvent.pointerMove(target, { clientX: 140, clientY: 100 });

    expect(
      document.querySelector(
        '.comma-layout-inspector__segment-label[data-inspector-property="padding-left"]'
      )
    ).toHaveTextContent("p 4px");
    expect(
      document.querySelector(
        '.comma-layout-inspector__segment-label[data-inspector-property="border-left-width"]'
      )
    ).not.toBeInTheDocument();

    fireEvent.pointerDown(target, { button: 0, clientX: 140, clientY: 100 });
    fireEvent.click(screen.getByRole("button", { name: "Inspector settings" }));
    expect(screen.getByRole("switch", { name: "Show padding overlay" })).toBeChecked();
    expect(screen.getByRole("switch", { name: "Show gap overlay" })).toBeChecked();
    const borderSwitch = screen.getByRole("switch", {
      name: "Show border overlay",
    });
    expect(borderSwitch).not.toBeChecked();

    fireEvent.click(borderSwitch);
    expect(
      document.querySelector(
        '.comma-layout-inspector__segment-label[data-inspector-property="border-left-width"]'
      )
    ).toHaveTextContent("b 1px");
  });

  it("shows a retry when source copying fails and allows another attempt", async () => {
    const writeText = vi
      .fn()
      .mockRejectedValueOnce(new Error("Clipboard denied"))
      .mockResolvedValueOnce(undefined);
    const clipboardDescriptor = Object.getOwnPropertyDescriptor(navigator, "clipboard");
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });
    try {
      render(<InspectorFixture />);
      const target = screen.getByTestId("inspect-target");
      fireEvent.pointerMove(target, { clientX: 140, clientY: 100 });
      fireEvent.pointerDown(target, { button: 0, clientX: 140, clientY: 100 });
      const copySource = screen.getByRole("button", { name: "Copy source" });
      fireEvent.click(copySource);
      expect(await screen.findByText("Retry copy")).toBeInTheDocument();
      expect(document.querySelector("textarea")).toBeNull();
      fireEvent.click(copySource);
      expect(await screen.findByText("Copied")).toBeInTheDocument();
      expect(writeText).toHaveBeenLastCalledWith(
        expect.stringContaining('[data-testid="inspect-target"]')
      );
      expect(screen.getByTestId("copy-layout-prompt")).toBeDisabled();
    } finally {
      if (clipboardDescriptor)
        Object.defineProperty(navigator, "clipboard", clipboardDescriptor);
      else Reflect.deleteProperty(navigator, "clipboard");
    }
  });

  it("uses Escape to release a pin and then exit", () => {
    render(<InspectorFixture />);
    const target = screen.getByTestId("inspect-target");

    fireEvent.pointerMove(target, { clientX: 140, clientY: 100 });
    fireEvent.pointerDown(target, { button: 0, clientX: 140, clientY: 100 });
    expect(screen.getByTestId("layout-inspector-panel")).toBeInTheDocument();

    fireEvent.keyDown(window, { key: "Escape" });
    expect(screen.queryByTestId("layout-inspector-panel")).not.toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("hover to inspect");

    fireEvent.keyDown(window, { key: "Escape" });
    expect(screen.queryByRole("status")).not.toBeInTheDocument();
  });

  it("toggles from the keyboard shortcut", () => {
    render(<LayoutInspector />);

    fireEvent.keyDown(window, {
      code: "KeyL",
      ctrlKey: true,
      shiftKey: true,
    });

    expect(screen.getByRole("status")).toHaveTextContent("Layout Inspector");
  });

  it("opens all changes from the bottom card and clears one or all previews", () => {
    render(<InspectorFixture />);
    const target = screen.getByTestId("inspect-target");

    fireEvent.pointerMove(target, { clientX: 140, clientY: 100 });
    fireEvent.pointerDown(target, { button: 0, clientX: 140, clientY: 100 });
    fireEvent.change(screen.getByLabelText("Margin top variable"), {
      target: { value: "--spacing-2xl" },
    });
    fireEvent.change(screen.getByLabelText("Padding top variable"), {
      target: { value: "--spacing-md" },
    });

    expect(target.style.getPropertyValue("margin-top")).toBe("var(--spacing-2xl)");
    const pending = screen.getByTestId("layout-inspector-pending");
    expect(screen.getByTestId("layout-inspector-panel")).toContainElement(pending);
    expect(screen.queryByRole("dialog", { name: "Layout change list" })).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: /Changes2/ }));
    const changeList = screen.getByRole("dialog", { name: "Layout change list" });
    expect(changeList).toHaveTextContent("margin-top");
    expect(changeList).toHaveTextContent("padding-top");

    fireEvent.click(screen.getByRole("button", { name: /Clear margin-top on/ }));
    expect(target.style.marginTop).toBe("8px");
    expect(target.style.getPropertyValue("padding-top")).toBe("var(--spacing-md)");
    expect(changeList).not.toHaveTextContent("margin-top");

    fireEvent.click(screen.getByRole("button", { name: "Clear all" }));

    expect(screen.getByTestId("layout-inspector-pending")).toHaveTextContent(
      "Changes0"
    );
    expect(screen.queryByRole("dialog", { name: "Layout change list" })).toBeNull();
    expect(target.style.marginTop).toBe("8px");
    expect(target.style.paddingTop).toBe("4px");
    expect(target.style.getPropertyPriority("margin-top")).toBe("");
    expect(screen.getByRole("button", { name: "Clear all" })).toBeDisabled();
    expect(screen.getByTestId("copy-layout-prompt")).toBeDisabled();
  });

  it("defaults to pixels and switches overlay labels to variables", () => {
    render(<InspectorFixture />);
    const target = screen.getByTestId("inspect-target");

    fireEvent.pointerMove(target, { clientX: 140, clientY: 100 });
    fireEvent.pointerDown(target, { button: 0, clientX: 140, clientY: 100 });

    const inspector = screen
      .getByTestId("layout-inspector-panel")
      .closest(".comma-layout-inspector");
    fireEvent.click(screen.getByRole("button", { name: "Inspector settings" }));
    expect(screen.getByRole("radio", { name: "Pixels" })).toBeChecked();
    expect(screen.queryByRole("radio", { name: "Both" })).not.toBeInTheDocument();
    expect(inspector).toHaveAttribute("data-value-display-mode", "pixels");

    fireEvent.click(screen.getByRole("radio", { name: "Variables" }));
    expect(inspector).toHaveAttribute("data-value-display-mode", "variables");

    fireEvent.click(screen.getByRole("radio", { name: "Pixels" }));
    expect(inspector).toHaveAttribute("data-value-display-mode", "pixels");
  });

  it("opens header settings as a menu with three independent layer rows", () => {
    render(<InspectorFixture />);
    const target = screen.getByTestId("inspect-target");

    fireEvent.pointerMove(target, { clientX: 140, clientY: 100 });
    fireEvent.pointerDown(target, { button: 0, clientX: 140, clientY: 100 });

    const settingsButton = screen.getByRole("button", {
      name: "Inspector settings",
    });
    expect(settingsButton).toHaveAttribute("aria-expanded", "false");
    fireEvent.click(settingsButton);
    expect(settingsButton).toHaveAttribute("aria-expanded", "true");
    const settingsMenu = screen.getByRole("dialog", {
      name: "Inspector settings",
    });
    expect(settingsMenu).toHaveTextContent("Padding");
    expect(settingsMenu).toHaveTextContent("Border");
    expect(settingsMenu).toHaveTextContent("Gap");
    expect(settingsMenu).not.toHaveTextContent("Layers");
    expect(screen.getByRole("switch", { name: "Show padding overlay" })).toBeChecked();
    expect(
      screen.getByRole("switch", { name: "Show border overlay" })
    ).not.toBeChecked();

    fireEvent.keyDown(settingsMenu, { key: "Escape" });
    expect(
      screen.queryByRole("dialog", { name: "Inspector settings" })
    ).not.toBeInTheDocument();
    expect(settingsButton).toHaveAttribute("aria-expanded", "false");

    fireEvent.click(settingsButton);
    expect(screen.getByRole("switch", { name: "Show padding overlay" })).toBeChecked();
  });

  it("collapses property groups and uses the box model to reveal and focus a property", () => {
    render(<InspectorFixture />);
    const target = screen.getByTestId("inspect-target");

    fireEvent.pointerMove(target, { clientX: 140, clientY: 100 });
    fireEvent.pointerDown(target, { button: 0, clientX: 140, clientY: 100 });

    expect(screen.getByTestId("layout-inspector-properties-scroll")).toBeVisible();
    const collapsePadding = screen.getByRole("button", {
      name: "Collapse Padding",
    });
    expect(collapsePadding).toHaveAttribute("aria-expanded", "true");

    fireEvent.click(collapsePadding);
    expect(screen.getByRole("button", { name: "Expand Padding" })).toHaveAttribute(
      "aria-expanded",
      "false"
    );
    expect(screen.queryByLabelText("Padding left variable")).not.toBeInTheDocument();

    fireEvent.click(
      screen.getByRole("button", {
        name: "Show Padding left property",
      })
    );

    const paddingLeft = screen.getByLabelText("Padding left variable");
    expect(screen.getByRole("button", { name: "Collapse Padding" })).toHaveAttribute(
      "aria-expanded",
      "true"
    );
    expect(paddingLeft).toHaveFocus();
  });

  it("moves the panel by its header and restores automatic placement", () => {
    render(<InspectorFixture />);
    const target = screen.getByTestId("inspect-target");

    fireEvent.pointerMove(target, { clientX: 140, clientY: 100 });
    fireEvent.pointerDown(target, { button: 0, clientX: 140, clientY: 100 });

    const panel = screen.getByTestId("layout-inspector-panel");
    const header = screen.getByTitle(
      "Drag to move · double-click to restore automatic placement"
    );
    expect(panel).toHaveAttribute("data-placement", "right");
    expect(panel).toHaveStyle({ left: "308px" });

    fireEvent.pointerDown(header, {
      button: 0,
      clientX: 320,
      clientY: 80,
      pointerId: 1,
    });
    fireEvent.pointerMove(header, {
      clientX: 328,
      clientY: 80,
      pointerId: 1,
    });
    fireEvent.pointerUp(header, {
      clientX: 328,
      clientY: 80,
      pointerId: 1,
    });
    expect(panel).toHaveAttribute("data-placement", "manual");
    expect(panel).toHaveStyle({ left: "316px" });

    fireEvent.doubleClick(header);
    expect(panel).toHaveAttribute("data-placement", "right");
    expect(panel).toHaveStyle({ left: "308px" });

    const resizeHandle = screen.getByRole("button", {
      name: "Resize inspector panel",
    });
    fireEvent.keyDown(resizeHandle, { key: "ArrowRight" });
    expect(panel).toHaveAttribute("data-placement", "manual");
    expect(panel.style.width).toBe("368px");

    fireEvent.keyDown(resizeHandle, { key: "Home" });
    expect(panel.style.width).toBe("");
  });
});

function InspectorFixture({
  onBusinessClick = () => {},
}: {
  onBusinessClick?: () => void;
}) {
  const [clicked, setClicked] = useState(false);

  return (
    <>
      <button
        data-testid="inspect-target"
        onClick={() => {
          setClicked(true);
          onBusinessClick();
        }}
        ref={(element) => {
          if (!element) return;
          element.getBoundingClientRect = () =>
            ({
              bottom: 160,
              height: 120,
              left: 60,
              right: 300,
              top: 40,
              width: 240,
              x: 60,
              y: 40,
              toJSON: () => ({}),
            }) satisfies DOMRect;
        }}
        style={{
          border: "1px solid",
          columnGap: 12,
          display: "flex",
          height: 90,
          margin: 8,
          padding: 4,
          rowGap: 10,
          width: 210,
        }}
        type="button"
      >
        Inspect me
      </button>
      <span>{clicked ? "clicked" : "idle"}</span>
      <LayoutInspector
        defaultActive
        resolveVariables={() => [
          { label: "--spacing-md · 8px", value: "--spacing-md" },
          { label: "--spacing-2xl · 20px", value: "--spacing-2xl" },
        ]}
      />
    </>
  );
}
