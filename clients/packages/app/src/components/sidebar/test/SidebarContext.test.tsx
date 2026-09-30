import { act, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { CommaSidebarProvider, useCommaSidebar } from "../SidebarContext";

function RailProbe() {
  const { collapsed, toggleCollapsed } = useCommaSidebar();
  return (
    <button onClick={toggleCollapsed} type="button">
      {collapsed ? "collapsed" : "shown"}
    </button>
  );
}

const probe = () => screen.getByRole("button");

describe("CommaSidebarProvider", () => {
  it("hides the rail while the frame cannot hold it, and brings it back", () => {
    const { rerender } = render(
      <CommaSidebarProvider railFits={false}>
        <RailProbe />
      </CommaSidebarProvider>
    );
    expect(probe()).toHaveTextContent("collapsed");

    rerender(
      <CommaSidebarProvider railFits>
        <RailProbe />
      </CommaSidebarProvider>
    );
    expect(probe()).toHaveTextContent("shown");
  });

  it("keeps a rail the reader hid across a narrow spell", () => {
    const { rerender } = render(
      <CommaSidebarProvider railFits>
        <RailProbe />
      </CommaSidebarProvider>
    );
    act(() => probe().click());
    expect(probe()).toHaveTextContent("collapsed");

    rerender(
      <CommaSidebarProvider railFits={false}>
        <RailProbe />
      </CommaSidebarProvider>
    );
    rerender(
      <CommaSidebarProvider railFits>
        <RailProbe />
      </CommaSidebarProvider>
    );
    expect(probe()).toHaveTextContent("collapsed");
  });

  it("reads a toggle on a geometry-hidden rail as asking for the rail", () => {
    const { rerender } = render(
      <CommaSidebarProvider railFits={false}>
        <RailProbe />
      </CommaSidebarProvider>
    );
    // Hidden by geometry alone: the toggle records "shown", which geometry
    // still vetoes here...
    act(() => probe().click());
    expect(probe()).toHaveTextContent("collapsed");

    // ...and honours as soon as the frame can hold the rail again.
    rerender(
      <CommaSidebarProvider railFits>
        <RailProbe />
      </CommaSidebarProvider>
    );
    expect(probe()).toHaveTextContent("shown");
  });
});
