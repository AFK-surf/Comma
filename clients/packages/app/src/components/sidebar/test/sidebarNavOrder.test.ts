import { describe, expect, it } from "vitest";
import { reconcileSidebarNavOrder, sidebarNavItemIds } from "../sidebarNavOrder";

describe("reconcileSidebarNavOrder", () => {
  it("shows the default order for an empty preference", () => {
    expect(reconcileSidebarNavOrder([])).toEqual([
      "home",
      "inbox",
      "tasks",
      "drive",
      "plugins",
    ]);
    expect(sidebarNavItemIds).toEqual(reconcileSidebarNavOrder([]));
  });

  it("keeps the reader's arrangement", () => {
    expect(
      reconcileSidebarNavOrder(["tasks", "home", "plugins", "inbox", "drive"])
    ).toEqual(["tasks", "home", "plugins", "inbox", "drive"]);
  });

  it("drops ids the build no longer ships and appends ones it newly does", () => {
    expect(reconcileSidebarNavOrder(["tasks", "archive", "home"])).toEqual([
      "tasks",
      "home",
      "inbox",
      "drive",
      "plugins",
    ]);
  });

  it("collapses a duplicated id to its first position", () => {
    expect(reconcileSidebarNavOrder(["inbox", "home", "inbox"])).toEqual([
      "inbox",
      "home",
      "tasks",
      "drive",
      "plugins",
    ]);
  });
});
