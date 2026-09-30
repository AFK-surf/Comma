import { afterEach, describe, expect, it, vi } from "vitest";
import {
  resolveAuthoredLayoutValues,
  splitTopLevelWhitespace,
} from "../authored-values";

describe("layout inspector authored values", () => {
  afterEach(() => {
    document.head.replaceChildren();
    document.body.replaceChildren();
  });

  it("keeps functions intact while splitting shorthand values", () => {
    expect(
      splitTopLevelWhitespace("var(--spacing-xs) calc(var(--spacing-sm) * 2) 12px 16px")
    ).toEqual(["var(--spacing-xs)", "calc(var(--spacing-sm) * 2)", "12px", "16px"]);
  });

  it("finds CSS variables in inline shorthand declarations", () => {
    const element = document.createElement("div");
    element.style.setProperty("--spacing-xs", "4px");
    element.style.padding = "var(--spacing-xs)";
    document.body.append(element);

    const values = resolveAuthoredLayoutValues(element);

    expect(values["padding-top"]).toMatchObject({
      confidence: "authored",
      expression: "var(--spacing-xs)",
      variables: ["--spacing-xs"],
    });
    expect(values["padding-right"]).toMatchObject({
      confidence: "authored",
      expression: "var(--spacing-xs)",
      variables: ["--spacing-xs"],
    });
  });

  it.each([
    ["missing", undefined],
    ["invalid", "red"],
  ])("does not claim authored provenance for an %s inline variable", (_case, value) => {
    const element = document.createElement("div");
    if (value) element.style.setProperty("--space-width", value);
    element.style.width = "var(--space-width)";
    document.body.append(element);

    expect(resolveAuthoredLayoutValues(element).width).toMatchObject({
      confidence: "computed",
      variables: [],
    });
  });

  it("does not mistake an invalid zero-height variable for authored", () => {
    const element = document.createElement("div");
    element.style.setProperty("--space-height", "red");
    element.style.height = "var(--space-height)";
    document.body.append(element);

    expect(resolveAuthoredLayoutValues(element).height).toMatchObject({
      confidence: "computed",
      variables: [],
    });
  });

  it("marks unique matching spacing variables as inferred rather than authored", () => {
    const element = document.createElement("div");
    element.style.setProperty("--space-large", "12px");
    element.style.paddingTop = "12px";
    document.body.append(element);

    expect(resolveAuthoredLayoutValues(element)["padding-top"]).toEqual({
      computed: "12px",
      confidence: "inferred",
      variables: ["--space-large"],
    });
  });

  it("does not claim authored provenance when a stylesheet is inaccessible", () => {
    const style = document.createElement("style");
    style.textContent = ".opaque { width: 100px; }";
    document.head.append(style);
    const sheet = style.sheet;
    if (!sheet) throw new Error("Opaque stylesheet fixture was unavailable.");
    Object.defineProperty(sheet, "cssRules", {
      configurable: true,
      get() {
        throw new DOMException("Stylesheet is cross-origin.", "SecurityError");
      },
    });

    const element = document.createElement("div");
    element.style.setProperty("--space-width", "100px");
    element.style.width = "var(--space-width)";
    document.body.append(element);

    expect(resolveAuthoredLayoutValues(element).width).toMatchObject({
      confidence: "computed",
      variables: [],
    });
  });

  it("matches each stylesheet rule once while resolving every inspected property", () => {
    const ruleCount = 80;
    const style = document.createElement("style");
    style.textContent = [
      ...Array.from(
        { length: ruleCount },
        (_, index) => `.unmatched-${index} { color: rgb(${index}, 0, 0); }`
      ),
      ".matched { padding-top: var(--spacing-xs); }",
    ].join("\n");
    document.head.append(style);

    const element = document.createElement("div");
    element.className = "matched";
    element.style.setProperty("--spacing-xs", "4px");
    document.body.append(element);

    const matches = vi.spyOn(element, "matches");

    resolveAuthoredLayoutValues(element);

    expect(matches).toHaveBeenCalledTimes(ruleCount + 1);
  });
});
