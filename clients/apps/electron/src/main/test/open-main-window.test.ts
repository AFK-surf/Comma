import { describe, expect, it, vi } from "vitest";
import { openOrCreateMainWindow } from "../open-main-window";

describe("openOrCreateMainWindow", () => {
  it("restores, shows, and focuses the existing main window", async () => {
    const window = createWindowMock({ minimized: true });
    const createMainWindow = vi.fn(async () => undefined);

    await openOrCreateMainWindow({ createWindow: createMainWindow, window });

    expect(window.restore).toHaveBeenCalledOnce();
    expect(window.show).toHaveBeenCalledOnce();
    expect(window.focus).toHaveBeenCalledOnce();
    expect(createMainWindow).not.toHaveBeenCalled();
  });

  it("creates a replacement when the main window was closed", async () => {
    const window = createWindowMock({ destroyed: true });
    const createMainWindow = vi.fn(async () => undefined);

    await openOrCreateMainWindow({ createWindow: createMainWindow, window });

    expect(createMainWindow).toHaveBeenCalledOnce();
    expect(window.show).not.toHaveBeenCalled();
    expect(window.focus).not.toHaveBeenCalled();
  });

  it("shows an existing automated window without activating it", async () => {
    const window = createWindowMock();

    await openOrCreateMainWindow({
      activate: false,
      createWindow: vi.fn(async () => undefined),
      window,
    });

    expect(window.showInactive).toHaveBeenCalledOnce();
    expect(window.show).not.toHaveBeenCalled();
    expect(window.focus).not.toHaveBeenCalled();
  });
});

function createWindowMock({
  destroyed = false,
  minimized = false,
}: {
  destroyed?: boolean;
  minimized?: boolean;
} = {}) {
  return {
    focus: vi.fn(),
    isDestroyed: vi.fn(() => destroyed),
    isMinimized: vi.fn(() => minimized),
    restore: vi.fn(),
    show: vi.fn(),
    showInactive: vi.fn(),
  };
}
