export interface SideChatDevToolsWebContentsLike {
  closeDevTools(): void;
  isDestroyed(): boolean;
  on(event: "devtools-opened", listener: () => void): void;
  openDevTools(options: { activate: boolean; mode: "detach" }): void;
}

/**
 * Side Chat's native pass-through hit test intentionally covers only the chat
 * content frame. Docked DevTools render outside that frame and make the whole
 * BrowserWindow ignore mouse events, so normalize every opening to a separate
 * interactive window instead.
 */
export function installDetachedSideChatDevTools(
  webContents: SideChatDevToolsWebContentsLike,
  schedule: (callback: () => void) => void = setImmediate
) {
  let reopeningDetached = false;

  webContents.on("devtools-opened", () => {
    if (reopeningDetached) {
      reopeningDetached = false;
      return;
    }

    reopeningDetached = true;
    webContents.closeDevTools();
    schedule(() => {
      if (webContents.isDestroyed()) {
        reopeningDetached = false;
        return;
      }
      webContents.openDevTools({ activate: true, mode: "detach" });
    });
  });
}
