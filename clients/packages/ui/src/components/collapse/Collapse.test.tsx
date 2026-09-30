import { describe, expect, it } from "vitest";
import { render, screen } from "@comma/test-utils/render";
import { Collapse, CollapseContent } from "./Collapse";

describe("Collapse", () => {
  it("renders content when open by default", () => {
    render(
      <Collapse defaultOpen>
        <CollapseContent>
          <p>Panel body</p>
        </CollapseContent>
      </Collapse>
    );

    expect(screen.getByText("Panel body")).toBeInTheDocument();
    expect(
      screen.getByText("Panel body").closest(".collapse-content")
    ).toBeInTheDocument();
    expect(document.querySelector(".collapse-container")).toHaveAttribute(
      "data-state",
      "open"
    );
  });

  it("updates data-state when controlled open changes", () => {
    const { container, rerender } = render(
      <Collapse open>
        <CollapseContent>
          <p>Body</p>
        </CollapseContent>
      </Collapse>
    );

    expect(container.querySelector(".collapse-container")).toHaveAttribute(
      "data-state",
      "open"
    );
    expect(screen.getByText("Body")).toBeInTheDocument();

    rerender(
      <Collapse open={false}>
        <CollapseContent>
          <p>Body</p>
        </CollapseContent>
      </Collapse>
    );

    expect(container.querySelector(".collapse-container")).toHaveAttribute(
      "data-state",
      "closed"
    );
  });

  it("marks closed content with data-state closed", () => {
    const { container } = render(
      <Collapse open={false}>
        <CollapseContent>
          <p>Hidden panel</p>
        </CollapseContent>
      </Collapse>
    );

    expect(container.querySelector(".collapse-container")).toHaveAttribute(
      "data-state",
      "closed"
    );
  });

  it("skips enter animation when initially open", () => {
    const { container } = render(
      <Collapse defaultOpen>
        <CollapseContent>
          <p>Panel body</p>
        </CollapseContent>
      </Collapse>
    );

    expect(container.querySelector(".collapse-container")).toHaveAttribute(
      "data-skip-enter",
      ""
    );
  });

  it("plays enter animation after opening from a closed initial state", () => {
    const { container, rerender } = render(
      <Collapse open={false}>
        <CollapseContent>
          <p>Body</p>
        </CollapseContent>
      </Collapse>
    );

    expect(container.querySelector(".collapse-container")).not.toHaveAttribute(
      "data-skip-enter"
    );

    rerender(
      <Collapse open>
        <CollapseContent>
          <p>Body</p>
        </CollapseContent>
      </Collapse>
    );

    expect(container.querySelector(".collapse-container")).not.toHaveAttribute(
      "data-skip-enter"
    );
  });

  it("plays enter animation after reopening from initially open", () => {
    const { container, rerender } = render(
      <Collapse open>
        <CollapseContent>
          <p>Body</p>
        </CollapseContent>
      </Collapse>
    );

    expect(container.querySelector(".collapse-container")).toHaveAttribute(
      "data-skip-enter",
      ""
    );

    rerender(
      <Collapse open={false}>
        <CollapseContent>
          <p>Body</p>
        </CollapseContent>
      </Collapse>
    );

    rerender(
      <Collapse open>
        <CollapseContent>
          <p>Body</p>
        </CollapseContent>
      </Collapse>
    );

    expect(container.querySelector(".collapse-container")).not.toHaveAttribute(
      "data-skip-enter"
    );
  });

  it("applies className to content and containerClassName to the height container", () => {
    const { container } = render(
      <Collapse defaultOpen>
        <CollapseContent
          className="p-lg content-layer"
          containerClassName="container-layer"
        >
          <p>Animated body</p>
        </CollapseContent>
      </Collapse>
    );

    const collapseContainer = container.querySelector(".collapse-container");
    const wrapper = container.querySelector(".collapse-content-wrapper");
    const content = container.querySelector(".collapse-content");

    expect(collapseContainer).toHaveClass("container-layer");
    expect(collapseContainer).not.toHaveClass("p-lg");
    expect(wrapper).toBeInTheDocument();
    expect(collapseContainer).toContainElement(wrapper as HTMLElement);
    expect(wrapper as HTMLElement).toContainElement(content as HTMLElement);
    expect(content).toHaveClass("content-layer", "p-lg");
    expect(content).toContainElement(screen.getByText("Animated body"));
  });
});
