import { describe, expect, it, vi } from "vitest";
import { WebContentsRegistry } from "../modules/ipc";

describe("WebContentsRegistry", () => {
  it("resolves caller context from a registered window webContents id", () => {
    const registry = new WebContentsRegistry();

    registry.registerWindow({
      id: "win_main",
      role: "main-window",
      window: { webContents: { id: 42 } },
    });

    expect(
      registry.resolveCallerContext({
        sender: { id: 42 },
        senderFrame: { url: "assets://./#/inbox" },
      })
    ).toEqual({
      origin: "assets://.",
      role: "main-window",
      webContentsId: 42,
      windowId: "win_main",
    });
  });

  it("returns unknown caller context when the webContents is not registered", () => {
    const registry = new WebContentsRegistry();

    expect(
      registry.resolveCallerContext({
        sender: { id: 99 },
        senderFrame: { url: "https://example.test/app" },
      })
    ).toEqual({
      origin: "https://example.test",
      role: "unknown",
      webContentsId: 99,
      windowId: "unknown",
    });
  });

  it("selects target webContents by explicit window and role selectors", () => {
    const registry = new WebContentsRegistry();
    const mainWebContents = { id: 42, send() {} };
    const panelWebContents = { id: 43, send() {} };
    registry.registerWindow({
      id: "win_main",
      role: "main-window",
      window: { webContents: mainWebContents },
    });
    registry.registerWindow({
      id: "win_panel",
      role: "panel",
      window: { webContents: panelWebContents },
    });

    expect(
      registry.targetWebContents({ type: "window", windowId: "win_panel" })
    ).toEqual([panelWebContents]);
    expect(registry.targetWebContents({ type: "role", role: "main-window" })).toEqual([
      mainWebContents,
    ]);
  });

  it("does not let a late close from an old window generation unregister its replacement", () => {
    const registry = new WebContentsRegistry();
    const oldWindow = { webContents: { id: 42 } };
    const replacementWindow = { webContents: { id: 43 } };

    registry.registerWindow({
      id: "win_reused",
      role: "main-window",
      window: oldWindow,
    });
    registry.registerWindow({
      id: "win_reused",
      role: "main-window",
      window: replacementWindow,
    });
    registry.unregisterWindow("win_reused", oldWindow);

    expect(registry.getWindowRegistration("win_reused")?.window).toBe(
      replacementWindow
    );
    expect(registry.getWindowRegistrationByWebContentsId(42)).toBeUndefined();
    expect(registry.getWindowRegistrationByWebContentsId(43)?.window).toBe(
      replacementWindow
    );
  });

  it("unregisters the exact window after Electron destroys its live webContents id", () => {
    const registry = new WebContentsRegistry();
    const removed = vi.fn();
    let currentWebContents = { id: 42 };
    const window = {
      get webContents() {
        return currentWebContents;
      },
    };
    registry.onWindowUnregistered(removed);
    registry.registerWindow({
      id: "win_dynamic_1",
      role: "main-window",
      window,
    });

    currentWebContents = { id: -1 };
    registry.unregisterWindow("win_dynamic_1", window);

    expect(registry.getWindowRegistrationByWebContentsId(42)).toBeUndefined();
    expect(removed).toHaveBeenCalledOnce();
    expect(removed).toHaveBeenCalledWith(
      expect.objectContaining({ id: "win_dynamic_1", window })
    );
  });
});
