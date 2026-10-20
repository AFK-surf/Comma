import { describe, expect, it, vi } from "vitest";
import { applyCommaDockVisibility } from "../dock-visibility";

function createDock(visible: boolean) {
  return {
    hide: vi.fn(),
    isVisible: vi.fn(() => visible),
    show: vi.fn(async () => undefined),
  };
}

describe("applyCommaDockVisibility", () => {
  it("shows a hidden Dock tile from the app bundle", async () => {
    const dock = createDock(false);
    await applyCommaDockVisibility({ dock, visible: true });

    expect(dock.show).toHaveBeenCalledOnce();
    expect(dock.hide).not.toHaveBeenCalled();
  });

  it("leaves a visible Dock tile alone instead of re-registering it", async () => {
    const dock = createDock(true);
    await applyCommaDockVisibility({ dock, visible: true });

    expect(dock.show).not.toHaveBeenCalled();
    expect(dock.hide).not.toHaveBeenCalled();
  });

  it("hides the Dock tile without changing its icon", async () => {
    const dock = createDock(true);
    await applyCommaDockVisibility({ dock, visible: false });

    expect(dock.hide).toHaveBeenCalledOnce();
    expect(dock.show).not.toHaveBeenCalled();
  });
});
