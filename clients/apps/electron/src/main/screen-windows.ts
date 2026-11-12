import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { BrowserWindowConstructorOptions } from "electron";
import { keepFullScreenInStep, type FullScreenWindow } from "./full-screen-in-step";

/**
 * A computer's screen in a window of its own (packages/app remote-screen/screenWindows.ts). The app's page opens a
 * blank document of its own origin under one of these names and renders the screen into it: the window runs in the
 * page's renderer, from the page's stream and decoder. No other copy of the app, no bridge, no route.
 *
 * Its name is `comma-screen:<window>:<screen>`: one window, and the screen it shows, by a key the page makes of it.
 * Main places the window: where that screen's window last was, or the size the page asks (its picture at a comfortable
 * size) in the middle of the display the app's window is on.
 */
export const screenWindowNamePrefix = "comma-screen:";

export type ScreenWindowRect = { x: number; y: number; width: number; height: number };
type Display = { workArea: ScreenWindowRect };
export type ScreenWindowDisplays = {
  all(): Display[];
  matching(rect: ScreenWindowRect): Display;
};

const MIN_WIDTH = 360;
const MIN_HEIGHT = 240;
/** What a window keeps clear of its display's edges, and a native title bar's room, where no size is remembered. */
const MARGIN = 48;
/** A remembered place shows at least this much of itself on a display, or the window opens as a new one. */
const VISIBLE = 96;
/** The screens whose last place is kept: the most recent ones. */
const REMEMBERED = 32;

type WindowContents = {
  setBackgroundThrottling(allowed: boolean): void;
  isDestroyed(): boolean;
  executeJavaScript(code: string): Promise<unknown>;
  setWindowOpenHandler(handler: () => { action: "deny" }): void;
  on(
    event: "will-navigate",
    listener: (event: { preventDefault(): void }) => void
  ): unknown;
  once(event: "destroyed", listener: () => void): unknown;
};

type ScreenWindow = FullScreenWindow & {
  webContents: WindowContents;
  once(event: "close" | "closed", listener: () => void): unknown;
  getNormalBounds(): ScreenWindowRect;
  isMinimized(): boolean;
  restore(): void;
  show(): void;
  focus(): void;
};

/** The screen's key in a screen window's name, or undefined for any other name. */
function screenKey(frameName: string): string | undefined {
  if (!frameName.startsWith(screenWindowNamePrefix)) return undefined;
  const key = frameName.slice(screenWindowNamePrefix.length).split(":")[1];
  return key && /^[0-9a-z]{1,16}$/.test(key) ? key : undefined;
}

/** The content size a page asks in its `window.open` features. */
function askedSize(features: string): { width: number; height: number } | undefined {
  const value = (name: string) =>
    Number(new RegExp(`(?:^|,)\\s*${name}\\s*=\\s*(\\d+)`).exec(features)?.[1]);
  const width = value("width");
  const height = value("height");
  return width > 0 && height > 0 ? { width, height } : undefined;
}

function overlap(a: ScreenWindowRect, b: ScreenWindowRect) {
  const width = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
  const height = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
  return width > 0 && height > 0 ? { width, height } : undefined;
}

const clamp = (value: number, low: number, high: number) =>
  Math.min(Math.max(value, low), Math.max(low, high));

/**
 * Where a screen window opens. A remembered place that still shows on a display is kept, moved and shrunk into that
 * display's work area. Otherwise the asked content size, shrunk to fit, in the middle of the work area of the display
 * the app's window is on. `content`: whether the size is the content's (a new place) or the whole window's.
 */
export function placeScreenWindow({
  remembered,
  asked,
  opener,
  displays,
}: {
  remembered?: ScreenWindowRect | undefined;
  asked?: { width: number; height: number } | undefined;
  opener: ScreenWindowRect;
  displays: ScreenWindowDisplays;
}): ScreenWindowRect & { content: boolean } {
  if (remembered) {
    let best: { area: ScreenWindowRect; shown: number } | undefined;
    for (const display of displays.all()) {
      const seen = overlap(remembered, display.workArea);
      if (!seen || seen.width < VISIBLE || seen.height < VISIBLE) continue;
      const shown = seen.width * seen.height;
      if (!best || shown > best.shown) best = { area: display.workArea, shown };
    }
    if (best) {
      const area = best.area;
      const width = Math.min(remembered.width, area.width);
      const height = Math.min(remembered.height, area.height);
      return {
        x: clamp(remembered.x, area.x, area.x + area.width - width),
        y: clamp(remembered.y, area.y, area.y + area.height - height),
        width,
        height,
        content: false,
      };
    }
  }
  const area = displays.matching(opener).workArea;
  const room = {
    width: Math.max(MIN_WIDTH, area.width - 2 * MARGIN),
    height: Math.max(MIN_HEIGHT, area.height - 2 * MARGIN),
  };
  const size = asked ?? { width: 960, height: 640 };
  // (shrunk as one: the picture keeps its shape)
  const scale = Math.min(1, room.width / size.width, room.height / size.height);
  const width = Math.max(MIN_WIDTH, Math.round(size.width * scale));
  const height = Math.max(MIN_HEIGHT, Math.round(size.height * scale));
  return {
    x: Math.round(area.x + (area.width - width) / 2),
    y: Math.round(area.y + (area.height - height) / 2),
    width,
    height,
    content: true,
  };
}

/** The last place of each screen's window, in a file of Main's: the most recent `REMEMBERED` screens. */
export class ScreenWindowPlaces {
  readonly #file: () => string | undefined;
  readonly #places = new Map<string, ScreenWindowRect>();
  #writing: Promise<void> = Promise.resolve();

  /** `file`: where they are kept, asked once Main knows its data directory. */
  constructor(file: () => string | undefined = () => undefined) {
    this.#file = file;
  }

  /** Reads the file; a missing or unreadable one is no places. */
  async load() {
    const file = this.#file();
    if (!file) return;
    try {
      const stored = JSON.parse(await readFile(file, "utf8")) as {
        version?: unknown;
        screens?: Record<string, unknown>;
      };
      if (stored.version !== 1 || !stored.screens) return;
      for (const [key, rect] of Object.entries(stored.screens))
        if (isRect(rect)) this.#places.set(key, rect);
    } catch {
      // (none yet, or not ours to read: the windows open as new ones)
    }
  }

  get(key: string): ScreenWindowRect | undefined {
    return this.#places.get(key);
  }

  set(key: string, rect: ScreenWindowRect) {
    this.#places.delete(key);
    this.#places.set(key, rect);
    for (const oldest of this.#places.keys()) {
      if (this.#places.size <= REMEMBERED) break;
      this.#places.delete(oldest);
    }
    this.#writing = this.#writing.then(() => this.#write()).catch(() => undefined);
    return this.#writing;
  }

  async #write() {
    const file = this.#file();
    if (!file) return;
    const temporary = `${file}.${process.pid}.tmp`;
    await mkdir(dirname(file), { recursive: true });
    await writeFile(
      temporary,
      `${JSON.stringify({ version: 1, screens: Object.fromEntries(this.#places) })}\n`
    );
    await rename(temporary, file);
  }
}

function isRect(value: unknown): value is ScreenWindowRect {
  if (!value || typeof value !== "object") return false;
  const rect = value as Record<string, unknown>;
  return (
    ["x", "y", "width", "height"].every((side) => Number.isFinite(rect[side])) &&
    (rect.width as number) >= MIN_WIDTH &&
    (rect.height as number) >= MIN_HEIGHT
  );
}

/**
 * The screen windows open now, for the session's permissions: their blank top document is the app's page's (full
 * screen, the keyboard lock).
 *
 * While a page has one open, the page is not throttled as its own window hides: the screen it shows plays from that
 * page's timers, and a minimized app window would otherwise slow them to one a second or less.
 */
export class ScreenWindows {
  readonly #open = new Set<WindowContents>();
  readonly #named = new Map<string, ScreenWindow>();
  readonly #byOpener = new Map<WindowContents, Set<WindowContents>>();
  readonly #displays: ScreenWindowDisplays;
  readonly #places: ScreenWindowPlaces;

  constructor({
    displays,
    places = new ScreenWindowPlaces(),
  }: {
    displays: ScreenWindowDisplays;
    places?: ScreenWindowPlaces;
  }) {
    this.#displays = displays;
    this.#places = places;
  }

  /** Reads the screens' last places, once Main knows its data directory. */
  load() {
    return this.#places.load();
  }

  /**
   * What a screen window opens with, or undefined for any other window the page asks for. `opener`: the bounds of the
   * app's window that asks.
   */
  options(
    {
      url,
      frameName,
      features = "",
    }: { url: string; frameName: string; features?: string },
    opener: ScreenWindowRect
  ): BrowserWindowConstructorOptions | undefined {
    if (url !== "about:blank" || !frameName.startsWith(screenWindowNamePrefix))
      return undefined;
    const key = screenKey(frameName);
    const { content, ...place } = placeScreenWindow({
      remembered: key ? this.#places.get(key) : undefined,
      asked: askedSize(features),
      opener,
      displays: this.#displays,
    });
    return {
      ...place,
      useContentSize: content,
      minWidth: MIN_WIDTH,
      minHeight: MIN_HEIGHT,
      autoHideMenuBar: true,
      fullscreenable: true,
    };
  }

  adopt(opener: WindowContents, window: ScreenWindow, name: string) {
    const contents = window.webContents;
    this.#named.set(name, window);
    contents.setWindowOpenHandler(() => ({ action: "deny" }));
    contents.on("will-navigate", (event) => event.preventDefault());
    this.#open.add(contents);
    const children = this.#byOpener.get(opener) ?? new Set();
    this.#byOpener.set(opener, children);
    children.add(contents);
    opener.setBackgroundThrottling(false);
    keepFullScreenInStep(window);
    // Its place as it goes, out of full screen or the Dock: where the screen's next window opens. Closed by Main (its
    // close button) it says "close" first; closed by the page (`window.close()`: moved back to the side panel, or the
    // page going) it says no "close", and its page goes while the window is still there.
    const key = screenKey(name);
    if (key) {
      let kept = false;
      const keep = () => {
        if (kept || window.isDestroyed()) return;
        kept = true;
        void this.#places.set(key, window.getNormalBounds());
      };
      window.once("close", keep);
      contents.once("destroyed", keep);
    }
    window.once("closed", () => {
      if (this.#named.get(name) === window) this.#named.delete(name);
      this.#open.delete(contents);
      children.delete(contents);
      if (children.size > 0) return;
      this.#byOpener.delete(opener);
      if (!opener.isDestroyed()) opener.setBackgroundThrottling(true);
    });
  }

  /** Brings the screen window of this name forward, out of the Dock too. Returns whether there is one. */
  focus(name: string): boolean {
    const window = this.#named.get(name);
    if (!window) return false;
    if (window.isMinimized()) window.restore();
    window.show();
    window.focus();
    return true;
  }

  has(contents: unknown): boolean {
    return this.#open.has(contents as WindowContents);
  }
}
