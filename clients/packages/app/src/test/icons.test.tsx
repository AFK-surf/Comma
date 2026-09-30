import { render } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { AppIcon, type AppIconName } from "../components/icons";

const appIconNames: AppIconName[] = [
  "arrow-left",
  "arrow-right",
  "arrow-up",
  "chevron-down",
  "clock",
  "edit",
  "home",
  "inbox",
  "layout-left",
  "layout-right",
  "mic",
  "plus",
  "reload",
  "search",
  "settings",
  "sparkles",
  "tasks",
];

describe("AppIcon", () => {
  it("renders app shell icons through the Central Icons wrappers", () => {
    const { container } = render(
      <div>
        {appIconNames.map((name) => (
          <AppIcon className={`icon-${name}`} key={name} name={name} />
        ))}
      </div>
    );

    const svgs = Array.from(container.querySelectorAll("svg"));

    expect(svgs).toHaveLength(appIconNames.length);
    expect(svgs.every((svg) => svg.getAttribute("viewBox") === "0 0 24 24")).toBe(true);
    expect(svgs.every((svg) => svg.getAttribute("aria-hidden") === "true")).toBe(true);

    const tasksIcon = container.querySelector(".icon-tasks")!;
    expect(tasksIcon.querySelector("mask")).toBeNull();
    expect(tasksIcon.querySelectorAll("path")).toHaveLength(4);
  });
});
