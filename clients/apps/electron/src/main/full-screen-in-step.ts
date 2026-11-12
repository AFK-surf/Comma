/** What `keepFullScreenInStep` needs of a BrowserWindow. */
export type FullScreenWindow = {
  webContents: { executeJavaScript(code: string): Promise<unknown> };
  on(
    event:
      | "enter-html-full-screen"
      | "leave-html-full-screen"
      | "enter-full-screen"
      | "leave-full-screen",
    listener: () => void
  ): unknown;
  isDestroyed(): boolean;
  getSize(): number[];
  setSize(width: number, height: number): void;
  isFullScreen(): boolean;
  setFullScreen(fullScreen: boolean): void;
};

/**
 * Keeps the page's full screen and its window's native one in step (Electron 45, macOS). A page that changes its mind
 * while the window's native transition runs (the full-screen button pressed twice in quick succession) is otherwise
 * left out of step for good:
 *
 * - left during the way in: Electron counts the window's whole transition as the page's full screen and tells the page
 *   nothing more once the window is back. `document.exitFullscreen()` never settles, `document.fullscreenElement`
 *   stays set, and the page cannot fill the screen again. A resize tells the page: once the window is out and Main
 *   has the page out, a page that still thinks it is in is given one. The size goes back at once, so a zoomed window
 *   stays zoomed.
 * - asked again during the way out: the window goes back into full screen, but Electron takes the page out as the
 *   way out ends. A native full screen the page asked for and has since left is ended.
 *
 * A native full screen the person chose (the green button, the View menu) is theirs: a page that fills the screen
 * inside it starts no transition, and the window stays in full screen when the page leaves.
 */
export function keepFullScreenInStep(window: FullScreenWindow) {
  const contents = window.webContents;
  let pageFull = false;
  let pageAsked = false;
  let personFull = false;
  window.on("enter-html-full-screen", () => {
    pageFull = true;
    if (!personFull) pageAsked = true;
  });
  window.on("leave-html-full-screen", () => void (pageFull = false));
  window.on("enter-full-screen", () => {
    const left = pageAsked && !pageFull;
    personFull = !pageAsked;
    pageAsked = false;
    // (on a turn of Main's own: Electron runs the transitions it queued after this event)
    if (left)
      setImmediate(() => {
        if (!pageFull && !window.isDestroyed() && window.isFullScreen())
          window.setFullScreen(false);
      });
  });
  window.on("leave-full-screen", () => {
    personFull = false;
    if (pageFull) return;
    void contents
      .executeJavaScript("document.fullscreenElement !== null")
      .then((stale) => {
        if (stale !== true || pageFull || window.isDestroyed()) return;
        const [width = 0, height = 0] = window.getSize();
        window.setSize(width + 1, height);
        window.setSize(width, height);
      })
      .catch(() => undefined);
  });
}
