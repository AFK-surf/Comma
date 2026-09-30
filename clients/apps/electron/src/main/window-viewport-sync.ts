// A window created hidden and resized before Chromium first paints it — a
// maximize before `show()`, the system zooming it while it is occluded —
// can leave the renderer's viewport at the size the window was created with
// until the next real resize; the shell then paints 1440×1024 into a window
// that is far larger (or smaller). Whenever the window's size may have
// changed, ask the renderer what it thinks it is and, on a mismatch, move
// the content box one pixel and back so Chromium picks the real size up.

export const viewportSyncEvents = [
  "show",
  "will-resize",
  "resize",
  "resized",
  "maximize",
  "unmaximize",
  "enter-full-screen",
  "leave-full-screen",
] as const;

export type ViewportSyncEvent = (typeof viewportSyncEvents)[number];

export interface ViewportSyncWindowLike {
  webContents: {
    executeJavaScript(code: string): Promise<unknown>;
    getZoomFactor(): number;
    isLoading(): boolean;
  };
  getContentSize(): number[];
  isDestroyed(): boolean;
  isVisible(): boolean;
  on(event: ViewportSyncEvent, listener: () => void): unknown;
  setContentSize(width: number, height: number): void;
}

const viewportProbe = "[window.innerWidth, window.innerHeight]";
// Coalesce programmatic changes. Native live resizing waits for `resized`,
// since a quiet event stream does not mean the user released the window edge.
const settleDelayMs = 120;

/**
 * Keeps the renderer's viewport in step with the window's content box.
 * Returns the uninstaller.
 */
export function installWindowViewportSync(
  window: ViewportSyncWindowLike,
  {
    log,
    settleMs = settleDelayMs,
  }: { log?: { info(message: string): void }; settleMs?: number } = {}
) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let nudgedAt: string | undefined;
  let installed = true;
  let generation = 0;
  let liveResize = false;

  const check = async () => {
    timer = undefined;
    if (!installed || liveResize || window.isDestroyed() || !window.isVisible()) return;
    if (window.webContents.isLoading()) return;
    const probeGeneration = generation;
    const [width = 0, height = 0] = window.getContentSize();
    const zoom = window.webContents.getZoomFactor() || 1;
    let viewport: unknown;
    try {
      viewport = await window.webContents.executeJavaScript(viewportProbe);
    } catch {
      return;
    }
    if (!installed || liveResize || window.isDestroyed() || !window.isVisible()) return;
    if (probeGeneration !== generation || window.webContents.isLoading()) return;
    const [currentWidth, currentHeight] = window.getContentSize();
    if (
      currentWidth !== width ||
      currentHeight !== height ||
      (window.webContents.getZoomFactor() || 1) !== zoom
    )
      return;
    if (!Array.isArray(viewport) || viewport.length !== 2) return;
    const [innerWidth, innerHeight] = viewport as [number, number];
    const matches =
      Math.abs(innerWidth - width / zoom) <= 1 &&
      Math.abs(innerHeight - height / zoom) <= 1;
    const size = `${width}x${height}`;
    if (matches) {
      nudgedAt = undefined;
      return;
    }
    // One nudge per size: a renderer that still disagrees afterwards (a page
    // scaling itself, say) is not a stale viewport and must not be shaken again.
    if (nudgedAt === size) return;
    nudgedAt = size;
    log?.info(
      `window viewport ${innerWidth}x${innerHeight} lags the ${size} content box; nudging`
    );
    window.setContentSize(width, height + 1);
    window.setContentSize(width, height);
  };

  const schedule = (event: ViewportSyncEvent) => {
    if (!installed) return;
    generation += 1;
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    if (event === "will-resize") liveResize = true;
    else if (event === "resized") liveResize = false;
    if (liveResize) return;
    timer = setTimeout(() => void check(), settleMs);
  };
  for (const event of viewportSyncEvents) window.on(event, () => schedule(event));

  return () => {
    installed = false;
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
  };
}
