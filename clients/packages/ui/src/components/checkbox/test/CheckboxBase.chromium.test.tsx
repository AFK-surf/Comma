import "@comma/ui/styles.css";

import { CheckboxBase } from "@comma/ui/components/checkbox/CheckboxBase";
import type { ReactElement } from "react";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";

// The glyph's stroke width on screen, in real Chromium with the shared
// stylesheet. Icon strokes keep their width at every icon size
// (`vector-effect: non-scaling-stroke`, styles.css), so the token the box sets
// is the width the window draws, not a width in the glyph's 24-unit viewBox.

let root: Root | undefined;

function mount(element: ReactElement) {
  const host = document.createElement("div");
  document.body.append(host);
  const created = createRoot(host);
  root = created;
  // Committed before the test reads the glyph: no frame to wait for.
  flushSync(() => created.render(element));
  return host;
}

function readGlyph(host: HTMLElement) {
  const glyph = host.querySelector<SVGSVGElement>(
    "span.opacity-100 svg[data-comma-icon]"
  );
  if (!glyph) throw new Error("The box shows no glyph.");
  const stroke = glyph.querySelector<SVGElement>("[stroke-width]");
  if (!stroke) throw new Error("The glyph has no stroke.");
  const style = getComputedStyle(stroke);
  return {
    frame: glyph.getBoundingClientRect().width,
    strokeWidth: style.strokeWidth,
    vectorEffect: style.vectorEffect,
  };
}

afterEach(() => {
  root?.unmount();
  root = undefined;
  document.body.replaceChildren();
});

describe("CheckboxBase glyph stroke", () => {
  it("draws the tick and the dash at the design's 1.67px in both box sizes", () => {
    // The design: a 12px frame inside the 16px box, the tick's stroke 1.67px.
    // The token used to be read in viewBox units, where 3.33 of 24 drew 1.67px
    // in this frame; as a width on screen it drew the tick at 3.33px.
    for (const size of ["sm", "md"] as const) {
      for (const state of [{ isSelected: true }, { isIndeterminate: true }]) {
        const host = mount(<CheckboxBase size={size} {...state} />);
        const glyph = readGlyph(host);
        // sm: the 16px box, less its border, less 1px each side. md: the 20px
        // box's 18px padding box, inset 15% each side.
        expect(glyph.frame, `${size} frame`).toBeCloseTo(size === "sm" ? 12 : 12.6, 1);
        expect(glyph.vectorEffect, `${size} vector effect`).toBe("non-scaling-stroke");
        expect(glyph.strokeWidth, `${size} stroke`).toBe("1.67px");
        root?.unmount();
        root = undefined;
        host.remove();
      }
    }
  });
});
