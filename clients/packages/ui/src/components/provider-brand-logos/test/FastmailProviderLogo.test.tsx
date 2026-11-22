import { render } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { resolveProviderBrandLogo } from "../providerBrandLogoResolver";

describe("FastmailProviderLogo", () => {
  it.each(["Fastmail", "fastmail", " Fast Mail "])(
    "renders a decorative provider mark for %s",
    (name) => {
      const Logo = resolveProviderBrandLogo(name);
      expect(Logo).toBeDefined();
      const { container } = render(Logo ? <Logo className="provider-mark" /> : null);
      const svg = container.querySelector("svg");
      expect(svg).toHaveAttribute("data-provider-logo", "fastmail");
      expect(svg).toHaveAttribute("aria-hidden", "true");
      expect(svg).toHaveAttribute("focusable", "false");
      expect(svg).toHaveClass("provider-mark");
    }
  );
});
