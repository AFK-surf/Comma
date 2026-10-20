import { act, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { FlashNotice, showFlash } from "../src/flash";

describe("FlashNotice", () => {
  it("shows a notice left for its page without another re-render", () => {
    render(<FlashNotice pathname="/orgs/acme/projects/p-1/devices" />);
    expect(screen.queryByRole("status")).toBeNull();
    act(() =>
      showFlash(
        { kind: "info", text: "Device added." },
        "/orgs/acme/projects/p-1/devices"
      )
    );
    expect(screen.getByRole("status")).toHaveTextContent("Device added.");
  });
});
