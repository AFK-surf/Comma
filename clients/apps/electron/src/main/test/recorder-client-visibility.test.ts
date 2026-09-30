import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import { bindRecorderClientVisibility } from "../recorder-client-visibility";

function fixture(visible = false, minimized = false) {
  const events = new EventEmitter();
  const window = Object.assign(events, {
    show: vi.fn(() => {
      visible = true;
      minimized = false;
    }),
    showInactive: vi.fn(() => {
      visible = true;
    }),
    hide: vi.fn(() => {
      visible = false;
    }),
    minimize: vi.fn(() => {
      minimized = true;
    }),
    restore: vi.fn(() => {
      minimized = false;
    }),
    isVisible: () => visible,
    isMinimized: () => minimized,
    isDestroyed: vi.fn(() => false),
  });
  const nativeShow = window.show;
  const publish = vi.fn();
  let current = true;
  bindRecorderClientVisibility(window, publish, () => current);
  return {
    events,
    nativeShow,
    window,
    publish,
    replace: () => {
      current = false;
    },
  };
}

describe("recorder client native visibility", () => {
  it("initializes from the native snapshot", () => {
    expect(fixture(true).publish).toHaveBeenLastCalledWith(true);
    expect(fixture(true, true).publish).toHaveBeenLastCalledWith(false);
  });
  it("accepts show even when the native getter still reports hidden", () => {
    const f = fixture();
    f.events.emit("show");
    expect(f.window.isVisible()).toBe(false);
    expect(f.publish).toHaveBeenLastCalledWith(true);
  });
  it("maps hide, minimize, restore and close without stale getter reads", () => {
    const f = fixture(true);
    for (const [event, expected] of [
      ["hide", false],
      ["show", true],
      ["minimize", false],
      ["restore", true],
      ["closed", false],
    ] as const) {
      f.events.emit(event);
      expect(f.publish).toHaveBeenLastCalledWith(expected);
    }
  });
  it("ignores events from a replaced primary window", () => {
    const f = fixture();
    f.replace();
    f.publish.mockClear();
    f.events.emit("show");
    f.events.emit("closed");
    expect(f.publish).not.toHaveBeenCalled();
  });
  it("never publishes a destroyed window as visible", () => {
    const f = fixture();
    f.window.isDestroyed.mockReturnValue(true);
    f.events.emit("show");
    expect(f.publish).toHaveBeenLastCalledWith(false);
  });
});

it("reconciles successful native commands that emit no events", () => {
  const f = fixture();
  for (const [method, expected] of [
    ["show", true],
    ["hide", false],
    ["showInactive", true],
    ["minimize", false],
    ["restore", true],
  ] as const) {
    f.window[method]();
    expect(f.publish).toHaveBeenLastCalledWith(expected);
  }
});
it("ignores completed commands on a replaced primary window", () => {
  const f = fixture();
  f.replace();
  f.publish.mockClear();
  f.window.show();
  expect(f.publish).not.toHaveBeenCalled();
});

it("preserves native command failure without publishing success", () => {
  const f = fixture();
  f.nativeShow.mockImplementation(() => {
    throw new Error("native show failed");
  });
  f.publish.mockClear();
  expect(() => f.window.show()).toThrow("native show failed");
  expect(f.publish).not.toHaveBeenCalled();
});
