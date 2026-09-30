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
  it("reapplies the Comma icon after restoring a hidden Dock tile", async () => {
    const dock = createDock(false);
    const restoreIcon = vi.fn();

    await applyCommaDockVisibility({ dock, restoreIcon, visible: true });

    expect(dock.show).toHaveBeenCalledOnce();
    expect(restoreIcon).toHaveBeenCalledOnce();
    expect(dock.show.mock.invocationCallOrder[0]).toBeLessThan(
      restoreIcon.mock.invocationCallOrder[0]!
    );
    expect(dock.hide).not.toHaveBeenCalled();
  });

  it("leaves a visible Dock tile alone instead of re-registering it", async () => {
    const dock = createDock(true);
    const restoreIcon = vi.fn();

    await applyCommaDockVisibility({ dock, restoreIcon, visible: true });

    expect(dock.show).not.toHaveBeenCalled();
    expect(restoreIcon).not.toHaveBeenCalled();
    expect(dock.hide).not.toHaveBeenCalled();
  });

  it("hides the Dock tile without changing its icon", async () => {
    const dock = createDock(true);
    const restoreIcon = vi.fn();

    await applyCommaDockVisibility({ dock, restoreIcon, visible: false });

    expect(dock.hide).toHaveBeenCalledOnce();
    expect(dock.show).not.toHaveBeenCalled();
    expect(restoreIcon).not.toHaveBeenCalled();
  });
});
