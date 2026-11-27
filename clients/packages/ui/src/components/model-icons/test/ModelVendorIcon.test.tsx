import { render } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { hasModelIcon } from "../ModelIcon";
import { ModelVendorIcon } from "../ModelVendorIcon";

describe("ModelVendorIcon", () => {
  it("renders Comma's mark for the comma vendor instead of the sparkles fallback", () => {
    expect(hasModelIcon("comma")).toBe(true);

    const { container } = render(<ModelVendorIcon vendor="comma" />);
    expect(container.querySelector('[data-slot="comma-mark"]')).not.toBeNull();
    expect(container.querySelector("[data-comma-icon]")).toBeNull();

    const tinted = render(<ModelVendorIcon tint vendor="comma" />);
    expect(tinted.container.querySelector('[data-slot="comma-mark"]')).not.toBeNull();
    expect(tinted.container.querySelector("[data-comma-icon]")).toBeNull();
  });

  it("falls back to the generic sparkles icon for unknown vendors", () => {
    expect(hasModelIcon("unknown-vendor")).toBe(false);

    const { container } = render(<ModelVendorIcon vendor="unknown-vendor" />);
    expect(container.querySelector('[data-slot="comma-mark"]')).toBeNull();
    expect(container.querySelector("[data-comma-icon]")).not.toBeNull();
  });
});
