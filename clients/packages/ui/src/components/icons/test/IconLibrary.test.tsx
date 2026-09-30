import type { ComponentType } from "react";
import { describe, expect, it } from "vitest";
import { render } from "@comma/test-utils/render";
import { DialogEnterIcon } from "../../dialog/DialogShortcutIcons";
import {
  ToastCloseIcon,
  ToastInfoIcon,
  ToastSuccessIcon,
} from "../../toast/ToastIcons";
import type { IconProps } from "../createCentralIcon";
import * as icons from "../index";

type IconComponent = ComponentType<IconProps>;

const componentIcons = Object.entries(icons).filter(
  ([name, value]) =>
    (name.endsWith("Icon") || name === "StatusDot") && typeof value === "function"
) as Array<[string, IconComponent]>;

const statusIcons: Array<[string, IconComponent]> = [
  ["DialogEnterIcon", DialogEnterIcon],
  ["ToastInfoIcon", ToastInfoIcon],
  ["ToastSuccessIcon", ToastSuccessIcon],
  ["ToastCloseIcon", ToastCloseIcon],
];

const allIcons: Array<[string, IconComponent]> = [...componentIcons, ...statusIcons];

const renderIconLibrary = () =>
  render(
    <div>
      {allIcons.map(([name, Icon]) => (
        <Icon key={name} className={`icon-${name}`} />
      ))}
    </div>
  ).container;

describe("Central icon wrappers", () => {
  it("renders every UI icon through the Central icon SVG base", () => {
    const container = renderIconLibrary();

    const svgs = Array.from(container.querySelectorAll("svg"));

    expect(svgs).toHaveLength(allIcons.length);
    expect(svgs.every((svg) => svg.getAttribute("viewBox") === "0 0 24 24")).toBe(true);
    expect(svgs.every((svg) => svg.getAttribute("aria-hidden") === "true")).toBe(true);
    expect(svgs.every((svg) => svg.hasAttribute("data-comma-icon"))).toBe(true);
    expect(svgs.every((svg) => svg.querySelector("path,circle,g"))).toBe(true);
  });

  it("locks the supported nominal stroke widths and fill-only exceptions", () => {
    const container = renderIconLibrary();
    const nominalStrokeWidths = new Set(
      Array.from(container.querySelectorAll("[stroke-width]"), (shape) =>
        shape.getAttribute("stroke-width")
      )
    );

    // 1.5 comes from the glyphs taken pre-thinned: Central ships them fill-only
    // in the stroke-2 package, so they are sourced from stroke-1.5 instead,
    // where BookIcon happens to be a real stroke already at 1.5.
    expect(Array.from(nominalStrokeWidths).toSorted()).toEqual([
      "0.5",
      "0.75",
      "1.5",
      "2",
    ]);
    for (const exportName of ["PanelLeftIcon", "PanelRightIcon"]) {
      expect(
        container
          .querySelector(`svg.icon-${exportName}`)
          ?.querySelector("[stroke-width]"),
        exportName
      ).toBeNull();
    }
  });

  it("does not attach per-instance stroke state", () => {
    const { container } = render(<icons.SearchIcon className="default" />);

    expect(container.querySelector("svg.default")).not.toHaveAttribute("style");
  });
});
