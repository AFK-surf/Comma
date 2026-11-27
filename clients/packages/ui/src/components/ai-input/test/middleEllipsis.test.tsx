import { render } from "@testing-library/react";
import { expect, it } from "vitest";
import {
  fitMiddleEllipsis,
  MiddleEllipsis,
  splitMiddleEllipsis,
} from "../attachments/MiddleEllipsis";

/** 6px a narrow character and 12px a wide one, as a 12px font about measures them. */
const measure = (text: string) =>
  Array.from(text).reduce(
    (width, char) => width + (char.codePointAt(0)! > 0xff ? 12 : 6),
    0
  );

it("keeps a short path whole, and a long one's last folder or last characters as the part never cut", () => {
  expect(splitMiddleEllipsis("~/Desktop")).toEqual({ head: "~/Desktop", tail: "" });
  expect(splitMiddleEllipsis("~/Workspace/AFK-surf/Cue/scripts")).toEqual({
    head: "~/Workspace/AFK-surf/Cue",
    tail: "/scripts",
  });
  expect(splitMiddleEllipsis("~/Downloads/2026-q4-campaign-assets")).toEqual({
    head: "~/Downloads/2026-q4-campaig",
    tail: "n-assets",
  });
  // A CJK character reads twice as wide: four of them make the tail.
  expect(splitMiddleEllipsis("~/下载/二〇二六年第四季度素材归档")).toEqual({
    head: "~/下载/二〇二六年第四季度",
    tail: "素材归档",
  });
});

it("cuts a path that does not fit in its middle, the ellipsis against the tail, and keeps one that fits", () => {
  expect(fitMiddleEllipsis("~/Desktop", 104, measure)).toBe("~/Desktop");
  expect(fitMiddleEllipsis("~/Downloads/2026-q4-campaign-assets", 110, measure)).toBe(
    "~/Downlo…n-assets"
  );
  expect(fitMiddleEllipsis("~/Workspace/AFK-surf/Cue/scripts", 110, measure)).toBe(
    "~/Worksp…/scripts"
  );
  expect(fitMiddleEllipsis("~/下载/二〇二六年第四季度素材归档", 120, measure)).toBe(
    "~/下载/二…素材归档"
  );
  // Too narrow even for the tail: the start, cut at its end.
  expect(fitMiddleEllipsis("~/Downloads/2026-q4-campaign-assets", 40, measure)).toBe(
    "~/Do…"
  );
  // A width not known yet keeps the whole text.
  expect(fitMiddleEllipsis("~/Downloads/2026-q4-campaign-assets", 0, measure)).toBe(
    "~/Downloads/2026-q4-campaign-assets"
  );
});

it("shows the whole path where its box has no width yet", () => {
  const { container } = render(
    <MiddleEllipsis text="~/Downloads/2026-q4-campaign-assets" />
  );
  expect(container.textContent).toBe("~/Downloads/2026-q4-campaign-assets");
});
