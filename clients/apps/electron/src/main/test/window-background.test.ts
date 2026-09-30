import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import {
  OpaqueWindowBackgroundController,
  opaqueWindowBackgroundColor,
} from "../window-background";

class TestWindow extends EventEmitter {
  destroyed = false;
  setBackgroundColor = vi.fn<(backgroundColor: string) => void>();

  isDestroyed() {
    return this.destroyed;
  }
}

describe("opaqueWindowBackgroundColor", () => {
  it("maps Electron's resolved theme to the Comma window tokens", () => {
    expect(opaqueWindowBackgroundColor(false)).toBe("#f4f4f5");
    expect(opaqueWindowBackgroundColor(true)).toBe("#0f0f10");
  });
});

describe("OpaqueWindowBackgroundController", () => {
  it("applies the initial theme and follows Comma's resolved appearance", () => {
    const window = new TestWindow();
    const controller = new OpaqueWindowBackgroundController(false);

    controller.track(window);
    expect(window.setBackgroundColor).toHaveBeenLastCalledWith("#f4f4f5");
    expect(controller.darkMode).toBe(false);

    expect(controller.setResolvedTheme("dark")).toBe("dark");
    expect(controller.darkMode).toBe(true);
    expect(controller.backgroundColor).toBe("#0f0f10");
    expect(window.setBackgroundColor).toHaveBeenLastCalledWith("#0f0f10");

    const laterWindow = new TestWindow();
    controller.track(laterWindow);
    expect(laterWindow.setBackgroundColor).toHaveBeenLastCalledWith("#0f0f10");

    controller.dispose();
  });

  it("stops updating closed windows and removes their lifecycle listeners", () => {
    const window = new TestWindow();
    const controller = new OpaqueWindowBackgroundController(false);

    controller.track(window);
    expect(window.listenerCount("closed")).toBe(1);
    window.emit("closed");
    controller.setResolvedTheme("dark");
    expect(window.setBackgroundColor).toHaveBeenCalledTimes(1);

    const openWindow = new TestWindow();
    controller.track(openWindow);
    controller.dispose();
    expect(openWindow.listenerCount("closed")).toBe(0);
    controller.setResolvedTheme("light");
    expect(openWindow.setBackgroundColor).toHaveBeenCalledTimes(1);
  });
});
