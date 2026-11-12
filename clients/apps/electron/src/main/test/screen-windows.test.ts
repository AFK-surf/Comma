import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import {
  ScreenWindowPlaces,
  ScreenWindows,
  placeScreenWindow,
  type ScreenWindowRect,
} from "../screen-windows";
import { installSessionSecurity, installWindowSecurity } from "../security";

// Two displays side by side: the app's on the left, a smaller one on the right.
const left = { workArea: { x: 0, y: 25, width: 1920, height: 1055 } };
const right = { workArea: { x: 1920, y: 0, width: 1280, height: 800 } };
const displays = {
  all: () => [left, right],
  matching: (rect: ScreenWindowRect) => (rect.x >= 1920 ? right : left),
};
const appWindow = { x: 100, y: 100, width: 1440, height: 900 };
function contents() {
  const on = vi.fn();
  const destroyed: (() => void)[] = [];
  return {
    on,
    once: (_event: "destroyed", listener: () => void) => void destroyed.push(listener),
    destroy: () => destroyed.splice(0).forEach((listener) => listener()),
    isDestroyed: () => false,
    setBackgroundThrottling: vi.fn(),
    setWindowOpenHandler: vi.fn(),
    executeJavaScript: vi.fn(async (_code: string): Promise<unknown> => false),
    navigate: () => {
      const event = { preventDefault: vi.fn() };
      for (const [name, listener] of on.mock.calls)
        if (name === "will-navigate") listener(event);
      return event.preventDefault.mock.calls.length > 0;
    },
  };
}

function window() {
  const webContents = contents();
  const closing: (() => void)[] = [];
  const closed: (() => void)[] = [];
  const listeners = new Map<string, (() => void)[]>();
  let minimized = true;
  return {
    webContents,
    on: (event: string, listener: () => void) =>
      void listeners.set(event, [...(listeners.get(event) ?? []), listener]),
    emit: (event: string) => listeners.get(event)?.forEach((listener) => listener()),
    isDestroyed: () => false,
    size: [800, 520],
    getSize() {
      return [...this.size];
    },
    setSize: vi.fn(),
    isFullScreen: () => true,
    setFullScreen: vi.fn(),
    bounds: { x: 2000, y: 100, width: 800, height: 520 },
    getNormalBounds() {
      return this.bounds;
    },
    once: (event: "close" | "closed", listener: () => void) =>
      void (event === "close" ? closing : closed).push(listener),
    // Closed by Main (its close button): "close", its page goes, "closed".
    close() {
      closing.splice(0).forEach((listener) => listener());
      this.closeFromPage();
    },
    // Closed by the page (`window.close()`): no "close"; its page goes while the window is still there.
    closeFromPage() {
      webContents.destroy();
      closed.splice(0).forEach((listener) => listener());
    },
    isMinimized: () => minimized,
    restore: vi.fn(() => void (minimized = false)),
    show: vi.fn(),
    focus: vi.fn(),
  };
}

describe("screen windows", () => {
  it("lets the app's page open its blank screen windows alone", () => {
    const setWindowOpenHandler = vi.fn();
    const screens = new ScreenWindows({ displays });
    installWindowSecurity({
      childWindowOptions: (details) => screens.options(details, appWindow),
      webContents: { on: vi.fn(), setWindowOpenHandler },
    });
    const open = setWindowOpenHandler.mock.calls[0]![0] as (details: {
      url: string;
      frameName: string;
      features?: string;
    }) => { action: string };

    expect(open({ url: "about:blank", frameName: "comma-screen:1" }).action).toBe(
      "allow"
    );
    expect(open({ url: "about:blank", frameName: "other" }).action).toBe("deny");
    expect(
      open({ url: "https://example.com", frameName: "comma-screen:1" }).action
    ).toBe("deny");
  });

  it("keeps the page unthrottled while one is open, and lets a screen window navigate or open nothing", () => {
    const screens = new ScreenWindows({ displays });
    const page = contents();
    const first = window();
    const second = window();
    screens.adopt(page, first, "comma-screen:a:k1");
    screens.adopt(page, second, "comma-screen:b:k2");

    expect(page.setBackgroundThrottling).toHaveBeenLastCalledWith(false);
    expect(screens.has(first.webContents)).toBe(true);
    expect(first.webContents.navigate()).toBe(true);
    const openFromScreen = first.webContents.setWindowOpenHandler.mock
      .calls[0]![0] as () => {
      action: string;
    };
    expect(openFromScreen().action).toBe("deny");

    first.close();
    expect(page.setBackgroundThrottling).toHaveBeenCalledTimes(2);
    second.close();
    expect(page.setBackgroundThrottling).toHaveBeenLastCalledWith(true);
    expect(screens.has(first.webContents)).toBe(false);
  });

  it("brings a screen window forward by its name, out of the Dock too, while it is open", () => {
    const screens = new ScreenWindows({ displays });
    const shown = window();
    screens.adopt(contents(), shown, "comma-screen:a:k1");

    expect(screens.focus("comma-screen:b:k2")).toBe(false);
    expect(screens.focus("comma-screen:a:k1")).toBe(true);
    expect(shown.restore).toHaveBeenCalled();
    expect(shown.focus).toHaveBeenCalled();
    shown.close();
    expect(screens.focus("comma-screen:a:k1")).toBe(false);
  });

  it("opens a new screen window at the size the page asks, shrunk to fit, centred on the app window's display", () => {
    expect(
      placeScreenWindow({
        asked: { width: 960, height: 588 },
        opener: appWindow,
        displays,
      })
    ).toEqual({ x: 480, y: 259, width: 960, height: 588, content: true });
    // A phone's tall picture on a short display: shrunk as one, inside the margins.
    const tall = placeScreenWindow({
      asked: { width: 600, height: 1008 },
      opener: { ...appWindow, x: 2000 },
      displays,
    });
    expect(tall.height).toBe(800 - 2 * 48);
    expect(tall.width / tall.height).toBeCloseTo(600 / 1008, 2);
    expect(tall.x).toBe(1920 + Math.round((1280 - tall.width) / 2));
  });

  it("puts a remembered window back where it was, moved in when the displays changed, and new when it shows on none", () => {
    const place = (remembered: ScreenWindowRect) =>
      placeScreenWindow({
        remembered,
        asked: { width: 960, height: 588 },
        opener: appWindow,
        displays,
      });
    const kept = { x: 2000, y: 100, width: 800, height: 520 };
    expect(place(kept)).toEqual({ ...kept, content: false });
    // Half off the right display's edge: moved in, whole.
    expect(place({ x: 2900, y: 600, width: 800, height: 520 })).toEqual({
      x: 3200 - 800,
      y: 800 - 520,
      width: 800,
      height: 520,
      content: false,
    });
    // On a display that is gone: a new window in the middle of the app's display.
    expect(place({ x: 5000, y: 0, width: 800, height: 520 })).toMatchObject({
      x: 480,
      content: true,
    });
  });

  it("keeps each screen's last place as its window closes, by Main or by its page, for the next window of that screen, across launches", async () => {
    const directory = await mkdtemp(join(tmpdir(), "screen-windows-"));
    const file = join(directory, "screen-windows.json");
    try {
      const places = new ScreenWindowPlaces(() => file);
      const screens = new ScreenWindows({ displays, places });
      const shown = window();
      screens.adopt(contents(), shown, "comma-screen:w1:abc");
      shown.bounds = { x: 2100, y: 150, width: 900, height: 600 };
      shown.close();
      // Closed by the page (moved back to the side panel): kept as well.
      const moved = window();
      screens.adopt(contents(), moved, "comma-screen:w3:def");
      moved.bounds = { x: 300, y: 200, width: 1100, height: 700 };
      moved.closeFromPage();
      await places.set("other", { x: 0, y: 25, width: 400, height: 300 });

      const next = new ScreenWindows({
        displays,
        places: new ScreenWindowPlaces(() => file),
      });
      await next.load();
      const open = (key: string) =>
        next.options(
          {
            url: "about:blank",
            frameName: `comma-screen:w2:${key}`,
            features: "width=960,height=588",
          },
          appWindow
        );
      expect(open("abc")).toMatchObject({
        x: 2100,
        y: 150,
        width: 900,
        height: 600,
        useContentSize: false,
      });
      expect(open("def")).toMatchObject({
        x: 300,
        y: 200,
        width: 1100,
        height: 700,
        useContentSize: false,
      });
      // Another screen opens as a new one.
      expect(open("xyz")).toMatchObject({
        width: 960,
        height: 588,
        useContentSize: true,
      });
      expect(JSON.parse(await readFile(file, "utf8")).screens).not.toHaveProperty("w1");
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("keeps the places of the most recent screens alone", async () => {
    const places = new ScreenWindowPlaces();
    for (let index = 0; index < 40; index += 1)
      void places.set(`s${index}`, { x: index, y: 25, width: 400, height: 300 });
    expect(places.get("s7")).toBeUndefined();
    expect(places.get("s8")).toBeDefined();
    expect(places.get("s39")).toBeDefined();
  });

  it("lets a screen window fill the screen and take Escape, and nothing else", () => {
    const screen = {};
    const setPermissionRequestHandler = vi.fn();
    installSessionSecurity(
      { setPermissionCheckHandler: vi.fn(), setPermissionRequestHandler },
      { appOrigins: ["assets://."], appChildWindow: (from) => from === screen }
    );
    const request = setPermissionRequestHandler.mock.calls[0]![0] as (
      webContents: unknown,
      permission: string,
      callback: (granted: boolean) => void,
      details: Record<string, unknown>
    ) => void;
    const answer = (
      from: unknown,
      permission: string,
      details: Record<string, unknown>
    ) => {
      let granted: boolean | undefined;
      request(from, permission, (value) => (granted = value), details);
      return granted;
    };
    const blank = { isMainFrame: true, requestingUrl: "about:blank" };

    expect(answer(screen, "fullscreen", blank)).toBe(true);
    expect(answer(screen, "keyboardLock", blank)).toBe(true);
    expect(answer(screen, "media", { ...blank, mediaTypes: ["audio"] })).toBe(false);
    expect(answer({}, "fullscreen", blank)).toBe(false);
  });
});
