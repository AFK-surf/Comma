import type { CommaResolvedTheme } from "@comma/native-bridge";

export const opaqueWindowBackgroundColors = {
  dark: "#0f0f10",
  light: "#f4f4f5",
} as const;

export function opaqueWindowBackgroundColor(darkMode: boolean) {
  return darkMode
    ? opaqueWindowBackgroundColors.dark
    : opaqueWindowBackgroundColors.light;
}

export interface OpaqueBrowserWindowLike {
  isDestroyed(): boolean;
  on(event: "closed", listener: () => void): unknown;
  off(event: "closed", listener: () => void): unknown;
  setBackgroundColor(backgroundColor: string): void;
}

/** Keeps native backing surfaces aligned with Comma's renderer-resolved appearance. */
export class OpaqueWindowBackgroundController {
  readonly #releaseByWindow = new Map<OpaqueBrowserWindowLike, () => void>();
  #darkMode: boolean;
  #disposed = false;

  constructor(initialDarkMode: boolean) {
    this.#darkMode = initialDarkMode;
  }

  get backgroundColor() {
    return opaqueWindowBackgroundColor(this.#darkMode);
  }

  get darkMode() {
    return this.#darkMode;
  }

  setResolvedTheme(theme: CommaResolvedTheme) {
    if (this.#disposed) return theme;
    this.#darkMode = theme === "dark";
    this.#sync();
    return theme;
  }

  track(window: OpaqueBrowserWindowLike) {
    if (this.#disposed || this.#releaseByWindow.has(window)) return;

    const release = () => {
      this.#releaseByWindow.delete(window);
    };
    this.#releaseByWindow.set(window, release);
    window.on("closed", release);
    this.#apply(window);
  }

  dispose() {
    if (this.#disposed) return;
    this.#disposed = true;
    for (const [window, release] of this.#releaseByWindow) {
      window.off("closed", release);
    }
    this.#releaseByWindow.clear();
  }

  #sync() {
    for (const window of this.#releaseByWindow.keys()) {
      this.#apply(window);
    }
  }

  #apply(window: OpaqueBrowserWindowLike) {
    if (window.isDestroyed()) return;
    window.setBackgroundColor(this.backgroundColor);
  }
}
