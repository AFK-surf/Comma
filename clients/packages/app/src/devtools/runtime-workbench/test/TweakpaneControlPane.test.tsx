import { render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { TweakpaneControlPane } from "../TweakpaneControlPane";

vi.mock("tweakpane", () => ({
  Pane: class PaneMock {
    addBinding = vi.fn();
    addBlade = vi.fn();
    addButton = vi.fn(() => ({ on: vi.fn() }));
    addFolder = vi.fn(() => this);
    dispose = vi.fn();
  },
}));

describe("TweakpaneControlPane", () => {
  it("renders a light themed container and marks planned controls", () => {
    render(
      <TweakpaneControlPane
        controls={[
          {
            evidenceLabel: "native.info",
            id: "refresh-runtime",
            kind: "button",
            label: "Refresh runtime",
            status: "ready",
          },
          {
            evidenceLabel: "window.show",
            id: "show-window",
            kind: "button",
            label: "Show window",
            status: "needs-capability",
          },
        ]}
      />
    );

    expect(screen.getByTestId("runtime-workbench-tweakpane")).toHaveClass(
      "comma-workbench-pane"
    );
    expect(screen.getByText("Show window")).toHaveAttribute(
      "data-control-status",
      "needs-capability"
    );
  });
});
