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
});
