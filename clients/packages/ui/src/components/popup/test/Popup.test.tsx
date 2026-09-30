import { describe, expect, it } from "vitest";
import { render, screen } from "@comma/test-utils/render";
import { Popup } from "../Popup";

describe("Popup", () => {
  it("renders dialog content in the requested width", () => {
    render(<Popup width="sm">Quick actions</Popup>);

    expect(screen.getByRole("dialog")).toHaveClass("w-[280px]");
    expect(screen.getByText("Quick actions")).toBeInTheDocument();
  });
});
