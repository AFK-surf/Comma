// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";
import { applyDocumentReducedMotion } from "../storybook/reducedMotion";
import { commaReducedMotionAttribute, isReducedMotionEnabled } from "../tokens";

describe("Storybook reduced motion toolbar", () => {
  afterEach(() => applyDocumentReducedMotion("full"));

  it("applies the same root preference consumed by Comma motion helpers", () => {
    applyDocumentReducedMotion("reduced");

    expect(document.documentElement.getAttribute(commaReducedMotionAttribute)).toBe(
      "true"
    );
    expect(isReducedMotionEnabled()).toBe(true);

    applyDocumentReducedMotion("full");
    expect(document.documentElement.getAttribute(commaReducedMotionAttribute)).toBe(
      "false"
    );
  });
});
