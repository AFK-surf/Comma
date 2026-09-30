import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  readCollapsedHomeRails,
  subscribeCollapsedHomeRails,
  toggleCollapsedHomeRail,
} from "../homeRailCollapse";

describe("homeRailCollapse", () => {
  beforeEach(() => {
    // The module cache keys off the raw stored string, so clearing storage is
    // enough to invalidate a shape left by earlier tests.
    window.localStorage.clear();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("keeps each rail's collapse across a reload", () => {
    expect(readCollapsedHomeRails()).toEqual({ greet: false, tasks: false });

    toggleCollapsedHomeRail("greet");
    expect(readCollapsedHomeRails()).toEqual({ greet: true, tasks: false });
    // What a fresh launch would read.
    expect(JSON.parse(window.localStorage.getItem("comma.homeRailCollapsed")!)).toEqual(
      {
        greet: true,
        tasks: false,
      }
    );

    toggleCollapsedHomeRail("tasks");
    expect(readCollapsedHomeRails()).toEqual({ greet: true, tasks: true });

    toggleCollapsedHomeRail("greet");
    expect(readCollapsedHomeRails()).toEqual({ greet: false, tasks: true });
  });

  it("notifies subscribers and keeps snapshot identity stable between writes", () => {
    const listener = vi.fn();
    const unsubscribe = subscribeCollapsedHomeRails(listener);
    const first = readCollapsedHomeRails();
    expect(readCollapsedHomeRails()).toBe(first);

    toggleCollapsedHomeRail("tasks");
    expect(listener).toHaveBeenCalledTimes(1);
    const collapsed = readCollapsedHomeRails();
    expect(collapsed).not.toBe(first);
    expect(readCollapsedHomeRails()).toBe(collapsed);

    unsubscribe();
    toggleCollapsedHomeRail("greet");
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it("keeps session toggles when persistence rejects writes", () => {
    const nativeSetItem = Storage.prototype.setItem;
    const setItem = vi.spyOn(Storage.prototype, "setItem").mockImplementation(function (
      this: Storage,
      key,
      value
    ) {
      if (key === "comma.homeRailCollapsed") {
        throw new DOMException("Storage quota exhausted", "QuotaExceededError");
      }
      nativeSetItem.call(this, key, value);
    });

    toggleCollapsedHomeRail("greet");
    expect(readCollapsedHomeRails()).toEqual({ greet: true, tasks: false });

    toggleCollapsedHomeRail("tasks");
    expect(readCollapsedHomeRails()).toEqual({ greet: true, tasks: true });

    toggleCollapsedHomeRail("greet");
    expect(readCollapsedHomeRails()).toEqual({ greet: false, tasks: true });
    expect(window.localStorage.getItem("comma.homeRailCollapsed")).toBeNull();

    // A real storage update still supersedes the volatile in-session shape.
    setItem.mockRestore();
    window.localStorage.setItem(
      "comma.homeRailCollapsed",
      JSON.stringify({ greet: true, tasks: false })
    );
    window.dispatchEvent(
      new StorageEvent("storage", { key: "comma.homeRailCollapsed" })
    );
    expect(readCollapsedHomeRails()).toEqual({ greet: true, tasks: false });
  });

  it("follows a collapse made in another window", () => {
    const listener = vi.fn();
    const unsubscribe = subscribeCollapsedHomeRails(listener);
    window.localStorage.setItem(
      "comma.homeRailCollapsed",
      JSON.stringify({ greet: false, tasks: true })
    );
    window.dispatchEvent(
      new StorageEvent("storage", { key: "comma.homeRailCollapsed" })
    );
    expect(listener).toHaveBeenCalledTimes(1);
    expect(readCollapsedHomeRails()).toEqual({ greet: false, tasks: true });
    unsubscribe();
  });

  it("opens Home again on a corrupted or foreign payload", () => {
    window.localStorage.setItem("comma.homeRailCollapsed", "{not json");
    expect(readCollapsedHomeRails()).toEqual({ greet: false, tasks: false });

    window.localStorage.setItem(
      "comma.homeRailCollapsed",
      JSON.stringify({ greet: 1 })
    );
    expect(readCollapsedHomeRails()).toEqual({ greet: false, tasks: false });

    toggleCollapsedHomeRail("greet");
    expect(readCollapsedHomeRails()).toEqual({ greet: true, tasks: false });
  });
});
