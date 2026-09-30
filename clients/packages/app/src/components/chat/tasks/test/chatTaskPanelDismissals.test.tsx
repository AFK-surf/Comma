import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  dismissPanelTask,
  readDismissedPanelTasks,
  restorePanelTask,
  subscribeDismissedPanelTasks,
} from "../chatTaskPanelDismissals";

describe("chatTaskPanelDismissals", () => {
  beforeEach(() => {
    // The module cache keys off the raw stored string, so clearing storage
    // is enough to invalidate marks left by earlier tests.
    window.localStorage.clear();
  });

  it("dismisses and restores a task", () => {
    expect(readDismissedPanelTasks().has("cnv-1")).toBe(false);
    dismissPanelTask("cnv-1");
    expect(readDismissedPanelTasks().has("cnv-1")).toBe(true);
    restorePanelTask("cnv-1");
    expect(readDismissedPanelTasks().has("cnv-1")).toBe(false);
  });

  it("notifies subscribers and keeps snapshot identity stable between writes", () => {
    const listener = vi.fn();
    const unsubscribe = subscribeDismissedPanelTasks(listener);
    const first = readDismissedPanelTasks();
    expect(readDismissedPanelTasks()).toBe(first);

    dismissPanelTask("cnv-1");
    expect(listener).toHaveBeenCalledTimes(1);
    expect(readDismissedPanelTasks()).not.toBe(first);

    // No-op writes do not emit.
    dismissPanelTask("cnv-1");
    restorePanelTask("cnv-other");
    expect(listener).toHaveBeenCalledTimes(1);

    unsubscribe();
    dismissPanelTask("cnv-2");
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it("survives a corrupted stored payload", () => {
    window.localStorage.setItem("comma.chatTaskPanelDismissed", "{not json");
    expect(readDismissedPanelTasks().size).toBe(0);
    dismissPanelTask("cnv-1");
    expect(readDismissedPanelTasks().has("cnv-1")).toBe(true);
  });

  it("evicts the oldest acknowledgements past the cap", () => {
    for (let index = 0; index < 301; index += 1) {
      dismissPanelTask(`cnv-${index}`);
    }
    const dismissed = readDismissedPanelTasks();
    expect(dismissed.size).toBe(300);
    expect(dismissed.has("cnv-0")).toBe(false);
    expect(dismissed.has("cnv-300")).toBe(true);
  });
});
