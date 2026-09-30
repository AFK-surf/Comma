import { render, screen } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { ContentHeader } from "../ContentHeader";

describe("ContentHeader", () => {
  it("provides the shared titlebar geometry", () => {
    render(
      <ContentHeader aria-label="Page header">
        <h1>Inbox</h1>
      </ContentHeader>
    );

    const header = screen.getByRole("banner", { name: "Page header" });
    expect(header).toHaveClass("h-11", "items-center", "comma-content-header");
    expect(header).toHaveAttribute("data-slot", "content-header");
    expect(header).toHaveAttribute("data-window-drag-region", "true");
    expect(header).toHaveClass("pl-xl", "pr-xl");
  });

  it("can opt out of the native window drag region", () => {
    render(
      <ContentHeader aria-label="Embedded header" windowDragRegion={false}>
        Embedded
      </ContentHeader>
    );

    expect(screen.getByRole("banner", { name: "Embedded header" })).toHaveAttribute(
      "data-window-drag-region",
      "false"
    );
  });
});
