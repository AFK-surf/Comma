import { describe, expect, it } from "vitest";
import { reconcileSidebarNavOrder } from "../sidebarNavOrder";

describe("reconcileSidebarNavOrder", () => {
  it.each([
    {
      name: "shows the default order for an empty preference",
      stored: [],
      expected: ["home", "inbox", "tasks", "drive", "plugins"],
    },
    {
      name: "keeps the reader's arrangement",
      stored: ["tasks", "home", "plugins", "inbox", "drive"],
      expected: ["tasks", "home", "plugins", "inbox", "drive"],
    },
    {
      name: "drops ids the build no longer ships and appends ones it newly does",
      stored: ["tasks", "archive", "home"],
      expected: ["tasks", "home", "inbox", "drive", "plugins"],
    },
    {
      name: "collapses a duplicated id to its first position",
      stored: ["inbox", "home", "inbox"],
      expected: ["inbox", "home", "tasks", "drive", "plugins"],
    },
  ])("$name", ({ stored, expected }) => {
    expect(reconcileSidebarNavOrder(stored)).toEqual(expected);
  });
});
