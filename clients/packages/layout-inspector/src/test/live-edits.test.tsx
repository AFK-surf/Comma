import { afterEach, describe, expect, it } from "vitest";
import {
  buildPendingChangesPrompt,
  createElementSelector,
  describeElementTarget,
  variableOptionsForProperty,
  type PendingLayoutChange,
} from "../live-edits";

describe("layout inspector live edits", () => {
  afterEach(() => {
    document.body.replaceChildren();
  });

  it("offers the relevant design-token variables for each property", () => {
    const element = document.createElement("div");
    element.style.setProperty("--product-gutter", "16px");
    element.style.setProperty("--spacing-none", "0px");
    element.style.setProperty("--spacing-xl", "16px");
    element.style.setProperty("--border-width-default", "1px");
    element.style.setProperty("--container-md", "560px");
    document.body.append(element);
    const authoredValue = {
      computed: "16px",
      confidence: "authored" as const,
      expression: "var(--product-gutter)",
      variables: ["--product-gutter"],
    };

    expect(
      variableOptionsForProperty("margin-top", authoredValue, element).map(
        (option) => option.value
      )
    ).toEqual(
      expect.arrayContaining(["--product-gutter", "--spacing-none", "--spacing-xl"])
    );
    expect(
      variableOptionsForProperty("border-top-width", authoredValue, element).map(
        (option) => option.value
      )
    ).toEqual(expect.arrayContaining(["--product-gutter", "--border-width-default"]));
    expect(
      variableOptionsForProperty("width", authoredValue, element).map(
        (option) => option.value
      )
    ).toEqual(expect.arrayContaining(["--spacing-xl", "--container-md"]));
  });

  it("creates a stable selector using explicit test identity", () => {
    const element = document.createElement("button");
    element.dataset.testid = "settings-row";
    document.body.append(element);

    expect(createElementSelector(element)).toBe('[data-testid="settings-row"]');
  });

  it("omits React runtime ids and uses the complete class set as a source clue", () => {
    const sidebar = document.createElement("aside");
    sidebar.id = "«r_2q»";
    sidebar.className = "flex h-[1008px] flex-col";
    const firstSection = document.createElement("div");
    firstSection.className = "flex";
    const target = document.createElement("div");
    target.className = "flex min-h-0 flex-1 flex-col gap-xl";
    target.setAttribute(
      "data-comma-source",
      "clients/packages/ui/src/components/left-sidebar/LeftSidebar.tsx:907:7"
    );
    sidebar.append(firstSection, target);
    document.body.append(sidebar);

    const description = describeElementTarget(target);

    expect(description.selector).toBe("div.flex.min-h-0.flex-1.flex-col.gap-xl");
    expect(description.selector).not.toContain("r_2q");
    expect(description.classNames).toEqual([
      "flex",
      "min-h-0",
      "flex-1",
      "flex-col",
      "gap-xl",
    ]);
    expect(description.omittedRuntimeIds).toBe(true);
    expect(description.sourceLocation).toEqual({
      column: 7,
      file: "clients/packages/ui/src/components/left-sidebar/LeftSidebar.tsx",
      line: 907,
    });
    expect(description.position).toBe("2 of 2 <div> children");
  });

  it("builds a source-oriented prompt grouped by target", () => {
    const element = document.createElement("button");
    element.className = "fixture-card";
    element.dataset.testid = "layout-target";
    document.body.append(element);
    const change: PendingLayoutChange = {
      afterComputed: "20px",
      afterVariable: "--spacing-2xl",
      beforeComputed: "16px",
      beforeExpression: "var(--spacing-xl)",
      elementKey: "element-1",
      id: "element-1:margin-top",
      nodeLabel: "button.fixture-card",
      property: "margin-top",
      sourceSelector: ".fixture-card",
      target: describeElementTarget(element),
    };

    const prompt = buildPendingChangesPrompt([change]);

    expect(prompt).toContain('`[data-testid="layout-target"]`');
    expect(prompt).toContain("`fixture-card`");
    expect(prompt).toContain("`.fixture-card`");
    expect(prompt).toContain(
      "- margin-top: var(--spacing-xl) [16px] → var(--spacing-2xl) [20px]"
    );
  });

  it("includes source and change data without runtime-generated IDs", () => {
    const sidebar = document.createElement("aside");
    sidebar.id = "«r_2q»";
    const sibling = document.createElement("div");
    const element = document.createElement("div");
    element.className = "flex min-h-0 flex-1 flex-col gap-xl";
    element.setAttribute(
      "data-comma-source",
      "clients/packages/ui/src/components/left-sidebar/LeftSidebar.tsx:907:7"
    );
    sidebar.append(sibling, element);
    document.body.append(sidebar);
    const change: PendingLayoutChange = {
      afterComputed: "4px",
      afterVariable: "--spacing-xs",
      beforeComputed: "16px",
      beforeExpression: "var(--spacing-xl)",
      elementKey: "element-2",
      id: "element-2:row-gap",
      nodeLabel: "div.flex.min-h-0",
      property: "row-gap",
      sourceSelector: ".gap-xl",
      target: describeElementTarget(element),
    };

    const prompt = buildPendingChangesPrompt([change]);

    expect(prompt).not.toContain("r_2q");
    expect(prompt).toContain(
      "`clients/packages/ui/src/components/left-sidebar/LeftSidebar.tsx:907:7`"
    );
    expect(prompt).toContain("`flex min-h-0 flex-1 flex-col gap-xl`");
    expect(prompt).toContain(
      "row-gap: var(--spacing-xl) [16px] → var(--spacing-xs) [4px]"
    );
  });
});
