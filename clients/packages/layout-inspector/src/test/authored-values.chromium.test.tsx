import { afterEach, beforeEach, expect, it } from "vitest";
import importedStyles from "../../../../e2e/app-shell/fixtures/layout-inspector/src/imported.css?raw";
import fixtureStyles from "../../../../e2e/app-shell/fixtures/layout-inspector/src/styles.css?raw";
import {
  resolveAuthoredLayoutValues,
  type InspectedLayoutProperty,
} from "../authored-values";

// The cascade, @container, @scope, nesting and animations only resolve in a
// real CSS engine. A variable on a declaration that loses the cascade must
// never be reported as the source of the used value.
const fixtureMarkup = `
<button
  class="fixture-cascade-target"
  data-testid="cascade-target"
  type="button"
>
  Cascade target
</button>
<button
  class="fixture-animation-cascade-target"
  data-testid="animation-cascade-target"
  id="fixture-animation-cascade-target"
  type="button"
>
  Animated cascade target
</button>
<div class="fixture-cascade-same-parent">
  <button
    class="fixture-cascade-same-target"
    data-testid="cascade-same-target"
    id="fixture-cascade-same-target"
    type="button"
  >
    Same-value cascade target
  </button>
</div>
<div
  class="fixture-gap-target fixture-gap-target--percent"
  data-testid="percent-gap-target"
>
  <span>Percent A</span>
  <span>Percent B</span>
</div>
<div
  class="fixture-gap-target fixture-gap-target--calc"
  data-testid="calc-gap-target"
>
  <span>Calc A</span>
  <span>Calc B</span>
</div>
<div
  class="fixture-auto-flex-gap-target fixture-auto-flex-gap-target--percent"
  data-testid="auto-flex-percent-gap-target"
>
  <span>Auto percent A</span>
  <span>Auto percent B</span>
</div>
<div
  class="fixture-auto-flex-gap-target fixture-auto-flex-gap-target--calc"
  data-testid="auto-flex-calc-gap-target"
>
  <span>Auto calc A</span>
  <span>Auto calc B</span>
</div>
<div class="fixture-width-auto-parent">
  <div
    class="fixture-width-auto-target"
    data-testid="width-auto-target"
    id="fixture-width-auto-target"
  >
    Width auto target
  </div>
</div>
<div
  class="fixture-import-target"
  data-testid="import-target"
  id="fixture-import-target"
>
  Imported winner target
</div>
<div class="fixture-inherit-parent">
  <div
    class="fixture-inherit-target"
    data-testid="inherit-target"
    id="fixture-inherit-target"
  >
    Inherited conditional winner target
  </div>
</div>
<div
  class="fixture-border-source-target"
  data-testid="border-keyword-target"
  id="fixture-border-keyword-target"
>
  Border keyword target
</div>
<div
  class="fixture-border-source-target"
  data-testid="border-shorthand-target"
  id="fixture-border-shorthand-target"
>
  Border shorthand target
</div>
<div
  class="fixture-inactive-sheet-target"
  data-testid="inactive-media-sheet-target"
  id="fixture-inactive-media-target"
>
  Inactive media sheet target
</div>
<div
  class="fixture-inactive-sheet-target"
  data-testid="disabled-sheet-target"
  id="fixture-disabled-sheet-target"
>
  Disabled sheet target
</div>
<div
  class="fixture-declaration-identity-target"
  data-testid="declaration-identity-target"
>
  Declaration identity target
</div>
<div
  class="fixture-unrelated-nesting-target"
  data-testid="unrelated-subtree-nesting-target"
  id="fixture-unrelated-subtree-nesting-target"
>
  Unrelated-subtree nesting target
</div>
<div
  class="fixture-absent-trigger-nesting-target"
  data-testid="absent-trigger-nesting-target"
  id="fixture-absent-trigger-nesting-target"
>
  Absent-trigger nesting target
</div>
<div class="fixture-container-query-parent">
  <div
    class="fixture-context-cascade-target fixture-container-query-target"
    data-testid="container-query-target"
    id="fixture-container-query-target"
  >
    Container query target
  </div>
  <div
    class="fixture-context-cascade-target fixture-nested-container-target"
    data-testid="nested-container-target"
    id="fixture-nested-container-target"
  >
    Nested container declarations target
  </div>
  <div
    class="fixture-context-cascade-target fixture-font-context-target"
    data-testid="font-context-target"
    id="fixture-font-context-target"
  >
    Font-context conditional winner target
  </div>
  <div class="fixture-nested-sibling-trigger"></div>
  <div
    class="fixture-context-cascade-target fixture-nested-sibling-target"
    data-testid="nested-sibling-target"
    id="fixture-nested-sibling-target"
  >
    Nested sibling rule target
  </div>
</div>
<div class="fixture-scope-root">
  <div
    class="fixture-context-cascade-target fixture-scope-target"
    data-testid="scope-target"
    id="fixture-scope-target"
  >
    Scope target
  </div>
  <div
    class="fixture-context-cascade-target fixture-scope-nesting-target"
    data-testid="scope-nesting-target"
    id="fixture-scope-nesting-target"
  >
    Nested selector scope target
  </div>
  <div class="fixture-nested-scope-parent">
    <div
      class="fixture-context-cascade-target fixture-nested-scope-target"
      data-testid="nested-scope-target"
      id="fixture-nested-scope-target"
    >
      Nested scope rule target
    </div>
  </div>
</div>
<div class="fixture-overlap-scope-root">
  <div class="fixture-overlap-scope-root">
    <div class="fixture-overlap-scope-limit">
      <div
        class="fixture-context-cascade-target fixture-overlap-scope-target"
        data-testid="overlap-scope-target"
        id="fixture-overlap-scope-target"
      >
        Overlapping scope target
      </div>
    </div>
  </div>
</div>
`;

const target = (testId: string) =>
  document.querySelector<HTMLElement>(`[data-testid="${testId}"]`)!;

beforeEach(async () => {
  const tokens = document.createElement("style");
  tokens.textContent = `:root {
    --border-width-default: 1px;
    --spacing-xl: 16px;
    --spacing-2xl: 20px;
    --spacing-3xl: 24px;
  }`;
  const fixture = document.createElement("style");
  // A raw style tag cannot resolve the fixture's relative @import, so the
  // imported sheet arrives as a data URL and stays an @import rule.
  fixture.textContent = fixtureStyles.replace(
    /@import[^;]+;/,
    `@import url("data:text/css,${encodeURIComponent(importedStyles)}");`
  );
  document.head.append(tokens, fixture);
  document.body.innerHTML = fixtureMarkup;
  await expect
    .poll(() => getComputedStyle(target("import-target")).width)
    .toBe("100px");
});

afterEach(() => {
  document.head.replaceChildren();
  document.body.replaceChildren();
});

it.each<[string, InspectedLayoutProperty, string[]]>([
  ["cascade-target", "margin-top", ["--spacing-xl", "--spacing-transition"]],
  ["cascade-same-target", "margin-left", ["--spacing-loser"]],
  ["animation-cascade-target", "margin-top", ["--fixture-animation-spacing-loser"]],
  ["width-auto-target", "width", ["--fixture-width-loser"]],
  ["import-target", "width", ["--fixture-import-loser"]],
  ["inherit-target", "width", ["--fixture-inherit-loser"]],
  ["container-query-target", "width", ["--fixture-container-loser"]],
  ["nested-container-target", "width", ["--fixture-nested-container-loser"]],
  ["nested-sibling-target", "width", ["--fixture-nested-sibling-loser"]],
  ["scope-target", "width", ["--fixture-scope-loser"]],
  ["scope-nesting-target", "width", ["--fixture-scope-loser"]],
  ["nested-scope-target", "width", ["--fixture-nested-scope-loser"]],
  ["overlap-scope-target", "width", ["--fixture-overlap-scope-loser"]],
  ["unrelated-subtree-nesting-target", "width", ["--fixture-unrelated-nesting-loser"]],
  [
    "absent-trigger-nesting-target",
    "height",
    ["--fixture-absent-trigger-nesting-loser"],
  ],
  ["font-context-target", "width", ["--fixture-font-width-loser"]],
])("never attributes %s's %s to a losing variable", (testId, property, losers) => {
  if (testId === "unrelated-subtree-nesting-target") {
    // The winning rule nests under a trigger in an unrelated subtree.
    const trigger = document.createElement("div");
    trigger.innerHTML =
      '<span class="fixture-unrelated-nesting-trigger">Nesting trigger</span>';
    document.body.append(trigger);
  }
  const element = target(testId);
  // The loser really loses: changing it leaves the used value alone.
  const before = getComputedStyle(element).getPropertyValue(property);
  for (const loser of losers) element.style.setProperty(loser, "80px");
  expect(getComputedStyle(element).getPropertyValue(property)).toBe(before);
  for (const loser of losers) element.style.removeProperty(loser);

  const value = resolveAuthoredLayoutValues(element)[property];
  for (const loser of losers) {
    expect(value.variables).not.toContain(loser);
    expect(value.expression ?? "").not.toContain(loser);
  }
});

const shadowLinkedSheet = `@scope { #fixture-shadow-link-target { width: 100px; } }`;

function mountShadowScopeFixture() {
  const host = document.createElement("div");
  document.body.append(host);
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = `
    <link rel="stylesheet" href="data:text/css,${encodeURIComponent(shadowLinkedSheet)}" />
    <style>
      .fixture-shadow-scope-target,
      .fixture-shadow-nested-scope-target,
      .fixture-shadow-host-nesting-target,
      .fixture-shadow-link-target {
        --fixture-shadow-scope-loser: 100px;
        display: block;
        min-height: 40px;
        width: var(--fixture-shadow-scope-loser);
      }
      @scope {
        :scope > #fixture-shadow-scope-target { width: 100px; }
        @scope (:scope > .fixture-shadow-inner) {
          #fixture-shadow-nested-scope-target { width: 100px; }
        }
      }
      :host {
        #fixture-shadow-host-nesting-target { width: 100px; }
      }
    </style>
    <div class="fixture-shadow-scope-target" id="fixture-shadow-scope-target"></div>
    <div class="fixture-shadow-inner">
      <div class="fixture-shadow-nested-scope-target" id="fixture-shadow-nested-scope-target"></div>
    </div>
    <div class="fixture-shadow-link-target" id="fixture-shadow-link-target"></div>
    <div class="fixture-shadow-host-nesting-target" id="fixture-shadow-host-nesting-target"></div>
  `;
  return root;
}

it.each([
  "fixture-shadow-scope-target",
  "fixture-shadow-nested-scope-target",
  "fixture-shadow-link-target",
  "fixture-shadow-host-nesting-target",
])("keeps the implicit shadow scope winner of #%s ambiguous", async (id) => {
  const root = mountShadowScopeFixture();
  const element = root.getElementById(id)!;
  await expect.poll(() => getComputedStyle(element).width).toBe("100px");
  element.style.setProperty("--fixture-shadow-scope-loser", "80px");
  expect(getComputedStyle(element).width).toBe("100px");
  element.style.removeProperty("--fixture-shadow-scope-loser");

  expect(resolveAuthoredLayoutValues(element).width).toMatchObject({
    computed: "100px",
    confidence: "computed",
    variables: [],
  });
});
