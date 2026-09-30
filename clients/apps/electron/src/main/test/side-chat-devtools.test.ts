import { describe, expect, it, vi } from "vitest";
import {
  installDetachedSideChatDevTools,
  type SideChatDevToolsWebContentsLike,
} from "../side-chat-devtools";

function createWebContents() {
  let openedListener: (() => void) | undefined;
  const webContents: SideChatDevToolsWebContentsLike = {
    closeDevTools: vi.fn(),
    isDestroyed: vi.fn(() => false),
    on: vi.fn((_event, listener) => {
      openedListener = listener;
    }),
    openDevTools: vi.fn(),
  };
  return {
    emitOpened: () => openedListener?.(),
    webContents,
  };
}

describe("Side Chat DevTools", () => {
  it("reopens docked DevTools as an interactive detached window", () => {
    const scheduled: Array<() => void> = [];
    const { emitOpened, webContents } = createWebContents();
    installDetachedSideChatDevTools(webContents, (callback) =>
      scheduled.push(callback)
    );

    emitOpened();
    expect(webContents.closeDevTools).toHaveBeenCalledOnce();
    expect(scheduled).toHaveLength(1);

    scheduled[0]?.();
    expect(webContents.openDevTools).toHaveBeenCalledWith({
      activate: true,
      mode: "detach",
    });

    // Electron emits devtools-opened again for the detached replacement. It
    // must settle without recursively reopening itself.
    emitOpened();
    expect(webContents.closeDevTools).toHaveBeenCalledOnce();
  });

  it("does not reopen DevTools after the Side Chat renderer is destroyed", () => {
    const scheduled: Array<() => void> = [];
    const { emitOpened, webContents } = createWebContents();
    vi.mocked(webContents.isDestroyed).mockReturnValue(true);
    installDetachedSideChatDevTools(webContents, (callback) =>
      scheduled.push(callback)
    );

    emitOpened();
    scheduled[0]?.();

    expect(webContents.openDevTools).not.toHaveBeenCalled();
  });
});
