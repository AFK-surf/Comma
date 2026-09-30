import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  installWindowViewportSync,
  type ViewportSyncEvent,
  type ViewportSyncWindowLike,
} from "../window-viewport-sync";

function fakeWindow({
  content = [1912, 1108],
  viewport = [1440, 1024],
  zoom = 1,
}: { content?: number[]; viewport?: number[]; zoom?: number } = {}) {
  const listeners = new Map<ViewportSyncEvent, Array<() => void>>();
  const state = { content, destroyed: false, loading: false, viewport, visible: true };
  const sizes: Array<[number, number]> = [];
  const window: ViewportSyncWindowLike = {
    getContentSize: () => state.content,
    isDestroyed: () => state.destroyed,
    isVisible: () => state.visible,
    on: (event, listener) => {
      listeners.set(event, [...(listeners.get(event) ?? []), listener]);
    },
    setContentSize: (width, height) => {
      sizes.push([width, height]);
      state.content = [width, height];
    },
    webContents: {
      executeJavaScript: async () => state.viewport,
      getZoomFactor: () => zoom,
      isLoading: () => state.loading,
    },
  };
  const emit = (event: ViewportSyncEvent) => {
    for (const listener of listeners.get(event) ?? []) listener();
  };
  return { emit, sizes, state, window };
}

const settle = async () => {
  await vi.advanceTimersByTimeAsync(200);
};

describe("installWindowViewportSync", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("nudges the content box when the renderer still holds the creation size", async () => {
    const { emit, sizes, window } = fakeWindow();
    installWindowViewportSync(window);
    emit("show");
    await settle();
    expect(sizes).toEqual([
      [1912, 1109],
      [1912, 1108],
    ]);
  });

  it.each(["resize", "zoom", "hidden"])(
    "discards a pending probe after the window changes: %s",
    async (change) => {
      const { emit, sizes, state, window } = fakeWindow();
      let respond!: (value: number[]) => void;
      window.webContents.executeJavaScript = () =>
        new Promise((resolve) => {
          respond = resolve;
        });
      const uninstall = installWindowViewportSync(window);
      emit("show");
      await settle();
      if (change === "resize") {
        state.content = [1600, 900];
        emit("resize");
      } else if (change === "zoom") {
        window.webContents.getZoomFactor = () => 2;
      } else {
        state.visible = false;
      }
      respond([800, 450]);
      await Promise.resolve();
      expect(sizes).toEqual([]);
      uninstall();
    }
  );

  it("leaves a viewport that matches the content box alone", async () => {
    const { emit, sizes, window } = fakeWindow({ viewport: [1912, 1108] });
    installWindowViewportSync(window);
    emit("maximize");
    await settle();
    expect(sizes).toEqual([]);
  });

  it("does not fight a paused live resize and repairs a stale viewport after release", async () => {
    const { emit, sizes, state, window } = fakeWindow();
    installWindowViewportSync(window);
    emit("will-resize");
    state.content = [1600, 900];
    emit("resize");
    emit("show");
    // The mouse can remain down much longer than the debounce period.
    await vi.advanceTimersByTimeAsync(1_000);
    expect(sizes).toEqual([]);
    emit("resized");
    await settle();
    expect(sizes).toEqual([
      [1600, 901],
      [1600, 900],
    ]);
  });

  it("discards a viewport response if the user starts dragging while it is pending", async () => {
    const { emit, sizes, window } = fakeWindow();
    let respond!: (value: number[]) => void;
    window.webContents.executeJavaScript = () =>
      new Promise((resolve) => {
        respond = resolve;
      });
    const uninstall = installWindowViewportSync(window);
    emit("show");
    await settle();
    emit("will-resize");
    respond([1440, 1024]);
    await Promise.resolve();
    expect(sizes).toEqual([]);
    uninstall();
  });

  it("compares in CSS pixels when the page is zoomed", async () => {
    const { emit, sizes, window } = fakeWindow({ viewport: [956, 554], zoom: 2 });
    installWindowViewportSync(window);
    emit("resize");
    await settle();
    expect(sizes).toEqual([]);
  });

  it("coalesces a resize stream into one check and nudges once per size", async () => {
    const { emit, sizes, state, window } = fakeWindow();
    installWindowViewportSync(window);
    emit("resize");
    emit("resize");
    emit("resize");
    await settle();
    expect(sizes).toHaveLength(2);
    // The nudge's own resize events re-check; a renderer that still disagrees
    // at the same size is not shaken again.
    emit("resize");
    await settle();
    expect(sizes).toHaveLength(2);
    // A new size gets a fresh nudge.
    state.content = [1600, 900];
    emit("resize");
    await settle();
    expect(sizes.slice(2)).toEqual([
      [1600, 901],
      [1600, 900],
    ]);
  });

  it("skips hidden, loading, and destroyed windows, and stops once uninstalled", async () => {
    const { emit, sizes, state, window } = fakeWindow();
    const uninstall = installWindowViewportSync(window);
    state.visible = false;
    emit("show");
    await settle();
    state.visible = true;
    state.loading = true;
    emit("show");
    await settle();
    state.loading = false;
    uninstall();
    emit("show");
    await settle();
    expect(sizes).toEqual([]);
  });
});
