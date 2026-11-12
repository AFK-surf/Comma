/**
 * While an element fills the screen, the root carries `data-comma-fullscreen`,
 * and styles.css clears every window app region. Electron keeps the regions of
 * the page under a full screen element at their places in the window, and a
 * press over a drag region never reaches the page. A window in full screen
 * does not move. Returns the way back.
 */
export function installFullscreenWindowRegions(document: Document) {
  const root = document.documentElement;
  const sync = () => {
    if (document.fullscreenElement) root.dataset.commaFullscreen = "";
    else delete root.dataset.commaFullscreen;
  };
  sync();
  document.addEventListener("fullscreenchange", sync);
  return () => {
    document.removeEventListener("fullscreenchange", sync);
    delete root.dataset.commaFullscreen;
  };
}
