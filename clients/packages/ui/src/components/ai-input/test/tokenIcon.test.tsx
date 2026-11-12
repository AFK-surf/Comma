import { expect, it } from "vitest";
import { sanitizedTokenIconElement } from "../rich-editor/tokens/tokenIcon";

it("draws a bundled logo in the token's text color and keeps a cross-origin image as it is", () => {
  const bundled = sanitizedTokenIconElement(
    `<img src="${location.origin}/assets/claude.svg" class="dark:invert">`
  ) as HTMLElement;
  expect(bundled.tagName).toBe("SPAN");
  expect(bundled.style.getPropertyValue("--comma-token-icon-mask")).toBe(
    `url("${location.origin}/assets/claude.svg")`
  );

  const remote = sanitizedTokenIconElement(
    `<img src="https://icons.example.com/linear.png">`
  ) as HTMLImageElement;
  expect(remote.tagName).toBe("IMG");
  expect(remote.src).toBe("https://icons.example.com/linear.png");
});
