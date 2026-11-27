import { describe, expect, it } from "vitest";
import { render, screen } from "@comma/test-utils/render";
import { Badge } from "../Badge";

describe("Badge", () => {
  it("renders a solid color dot instead of an icon glyph when dot is set", () => {
    render(
      <Badge color="success" dot>
        success
      </Badge>
    );

    const badge = screen.getByText("success").closest("span");
    const dot = badge?.querySelector("span.rounded-full");

    expect(dot).toHaveClass("bg-utility-success-700", "size-1.5");
    expect(dot?.querySelector("svg")).toBeNull();
  });

  it("renders borderless tonal badges by default and merges caller overrides cleanly", () => {
    render(
      <>
        <Badge color="brand" size="xs" type="badge-color">
          Recommended
        </Badge>
        <Badge
          className="bg-transparent p-0 text-tertiary"
          color="success"
          dot
          size="sm"
        >
          Connected
        </Badge>
      </>
    );

    const recommended = screen.getByText("Recommended").closest("span");
    expect(recommended).not.toHaveClass("border");
    expect(recommended).toHaveClass("rounded-[5px]", "text-micro");

    const connected = screen.getByText("Connected").closest("span");
    expect(connected).toHaveClass("bg-transparent", "p-0", "text-tertiary");
  });
});
