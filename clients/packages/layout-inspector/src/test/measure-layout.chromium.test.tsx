import { afterEach, describe, expect, it } from "vitest";
import { measureElement } from "../measure-layout";

// Used gaps depend on real layout: percentages and calc() resolve against the
// container only in a browser engine, so these run in the browser project.
function mount(css: string, html: string) {
  const style = document.createElement("style");
  style.textContent = css;
  document.head.append(style);
  const host = document.createElement("div");
  host.innerHTML = html;
  document.body.append(host);
  return host.firstElementChild as HTMLElement;
}

function gutter(target: HTMLElement, axis: "column" | "row") {
  const [first, second] = [...target.children].map((child) =>
    child.getBoundingClientRect()
  );
  return axis === "column" ? second!.left - first!.right : second!.top - first!.bottom;
}

afterEach(() => {
  document.head.replaceChildren();
  document.body.replaceChildren();
});

describe("layout inspector used gaps", () => {
  it.each([
    ["10%", 40],
    ["calc(10% + 5px)", 45],
  ])("measures a grid column gap of %s from the used geometry", (gap, expected) => {
    const target = mount(
      `.grid { display: grid; grid-template-columns: 1fr 1fr; width: 400px; height: 56px; column-gap: ${gap}; }`,
      `<div class="grid"><span>A</span><span>B</span></div>`
    );
    const measurement = measureElement(target)!;
    expect(gutter(target, "column")).toBeCloseTo(expected, 1);
    expect(measurement.gap.column).toBeCloseTo(expected, 1);
    const segment = measurement.segments.find((item) => item.property === "column-gap");
    expect(segment?.value).toBeCloseTo(expected, 1);
    expect(segment?.rect.width).toBeCloseTo(expected, 1);
  });

  it.each([
    // A percentage row gap in an auto-height flex column resolves to zero.
    ["10%", 0],
    ["calc(10% + 5px)", 5],
  ])("measures an auto-height flex row gap of %s", (gap, expected) => {
    const target = mount(
      `.flex { display: flex; flex-direction: column; width: 220px; height: auto; row-gap: ${gap}; }
       .flex span { flex: 0 0 20px; min-height: 20px; }`,
      `<div class="flex"><span>A</span><span>B</span></div>`
    );
    const measurement = measureElement(target)!;
    expect(gutter(target, "row")).toBeCloseTo(expected, 1);
    expect(measurement.gap.row).toBeCloseTo(expected, 1);
    const segment = measurement.segments.find((item) => item.property === "row-gap");
    if (expected === 0) expect(segment).toBeUndefined();
    else expect(segment?.rect.height).toBeCloseTo(expected, 1);
  });

  it.each([
    // The first item's margin is separation, not gap.
    ["10%", 0, 10],
    ["calc(10% + 5px)", 5, 15],
  ])(
    "excludes a flex item's margin from a %s row gap",
    (gap, expectedGap, separation) => {
      const target = mount(
        `.flex { display: flex; flex-direction: column; width: 220px; height: auto; row-gap: ${gap}; }
       .flex > span { min-height: 20px; }
       .flex > span:first-child { margin-bottom: 10px; }`,
        `<div class="flex"><span>A</span><span>B</span></div>`
      );
      const measurement = measureElement(target)!;
      expect(gutter(target, "row")).toBeCloseTo(separation, 1);
      expect(measurement.gap.row).toBeCloseTo(expectedGap, 1);
      const segment = measurement.segments.find((item) => item.property === "row-gap");
      if (expectedGap === 0) expect(segment).toBeUndefined();
      else expect(segment?.rect.height).toBeCloseTo(expectedGap, 1);
    }
  );

  it("excludes distributed alignment space from the used gap", () => {
    const target = mount(
      `.flex { display: flex; flex-direction: column; width: 220px; height: 100px; justify-content: space-between; row-gap: 10%; }
       .flex > span { min-height: 20px; }`,
      `<div class="flex"><span>A</span><span>B</span></div>`
    );
    const measurement = measureElement(target)!;
    expect(gutter(target, "row")).toBeGreaterThan(10);
    expect(measurement.gap.row).toBeCloseTo(10, 1);
    expect(
      measurement.segments.find((item) => item.property === "row-gap")?.value
    ).toBeCloseTo(10, 1);
  });
});
