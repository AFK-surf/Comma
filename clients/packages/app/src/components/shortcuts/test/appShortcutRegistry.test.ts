import { describe, expect, it } from "vitest";
import { appShortcutIds } from "../appShortcutRegistry";

describe("appShortcutRegistry", () => {
  it("only advertises shortcuts with reachable runtime owners", () => {
    expect(appShortcutIds).toEqual([
      "go-settings",
      "go-comma-assistant",
      "go-search",
      "go-inbox",
      "go-drive",
      "go-tasks",
      "go-plugins",
      "toggle-left-sidebar",
      "history-back",
      "history-forward",
      "toggle-right-sidebar",
    ]);
  });
});
