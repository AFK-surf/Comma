import { BaseWindow, BrowserWindow, screen, shell } from "electron";
import {
  emptySitePermissionMenuState,
  type BrowserPageMenuItem,
  type SitePermissionMenuAction,
  type SitePermissionMenuState,
} from "@comma/native-bridge";
import { configureManagedWindow } from "./managed-window";
import { createSitePermissionMenuWindowOptions } from "./window-options";
import { getCurrentNativeCallerContext, type WebContentsRegistry } from "./modules/ipc";
import type { NativeSurfaceService } from "./modules/surfaces";
import type { SitePermissionPlatform } from "./modules/browser-sidebar/site-permissions";

type Settings = Parameters<SitePermissionPlatform["settings"]>[0];
const menuWidth = 352;
// The tallest the menu may grow; the renderer reports its height to fit it.
const menuHeight = 480;
export interface SitePermissionMenuProvider {
  read(input?: void): SitePermissionMenuState;
  act(input: SitePermissionMenuAction): void | Promise<void>;
}
export const unavailableSitePermissionMenu: SitePermissionMenuProvider = {
  read: () => emptySitePermissionMenuState,
  act: () => {
    throw new Error("Website permission menu is unavailable.");
  },
};

/** One preloaded child renderer per app, with fresh document-bound callbacks per opening. */
export class SitePermissionMenuWindow implements SitePermissionMenuProvider {
  #window: BrowserWindow | undefined;
  #owner: BaseWindow | undefined;
  #loading: Promise<void> | undefined;
  #active:
    | {
        input: Settings;
        generation: number;
        place(height: number): void;
        finish(picked?: BrowserPageMenuItem): void;
        fail(error: Error): void;
      }
    | undefined;
  #generation = 0;
  #revision = 0;
  constructor(
    private readonly options: {
      preloadPath: string;
      url: string;
      surfaces(): NativeSurfaceService;
      registry(): WebContentsRegistry;
      secure(window: BrowserWindow): void;
      onStateChanged(state: SitePermissionMenuState): void;
      logger: { error(message: string): void; warn(message: string): void };
    }
  ) {}

  prepare(owner: unknown): Promise<void> {
    if (!(owner instanceof BaseWindow) || owner.isDestroyed()) return Promise.resolve();
    if (this.#owner === owner && this.#window && !this.#window.isDestroyed())
      return this.#loading ?? Promise.resolve();
    // Background registration in another owner must not interrupt an open menu.
    if (this.#active) return Promise.resolve();
    this.close();
    const window = new BrowserWindow(
      createSitePermissionMenuWindowOptions({
        parent: owner,
        bounds: { x: 0, y: 0, width: menuWidth, height: menuHeight },
        preloadPath: this.options.preloadPath,
      })
    );
    this.#window = window;
    this.#owner = owner;
    const destroy = () => {
      if (!window.isDestroyed()) window.destroy();
    };
    const fail = (error: Error) => {
      this.#active?.fail(error);
      destroy();
    };
    owner.once("closed", destroy);
    window.on("blur", () => this.#active?.finish());
    window.on("closed", () => {
      owner.removeListener("closed", destroy);
      if (this.#window !== window) return;
      this.#active?.finish();
      this.#window = undefined;
      this.#owner = undefined;
      this.#loading = undefined;
    });
    window.webContents.on("render-process-gone", () =>
      fail(new Error("Website permissions closed unexpectedly. Open them again."))
    );
    window.webContents.on("did-fail-load", () =>
      fail(new Error("Could not open website permissions. Try again."))
    );
    this.#loading = configureManagedWindow({
      browserWindow: window,
      id: "site-permission-menu",
      role: "site-permission-menu",
      route: "/site-permission-menu",
      loadUrl: this.options.url,
      showOnReady: false,
      failureLabel: "website permission menu",
      logger: this.options.logger,
      installWindowSecurity: () => this.options.secure(window),
      surfaces: this.options.surfaces(),
      webContentsRegistry: this.options.registry(),
    }).catch((error: unknown) => {
      fail(error instanceof Error ? error : new Error(String(error)));
      throw error;
    });
    return this.#loading;
  }

  async open(input: Settings): Promise<BrowserPageMenuItem | undefined> {
    this.#active?.finish();
    const owner = input.owner;
    if (!(owner instanceof BaseWindow) || owner.isDestroyed() || input.signal.aborted)
      return;
    await this.prepare(owner);
    const window = this.#window;
    if (!window || window.isDestroyed() || owner.isDestroyed() || input.signal.aborted)
      return;
    const ownerBounds = owner.getContentBounds();
    const anchor = input.anchor;
    const point = anchor
      ? {
          x: ownerBounds.x + anchor.x + anchor.width,
          y: ownerBounds.y + anchor.y + anchor.height + 4,
        }
      : screen.getCursorScreenPoint();
    const area = screen.getDisplayNearestPoint(point).workArea;
    const place = (contentHeight: number) => {
      const width = menuWidth,
        height = Math.round(Math.min(menuHeight, Math.max(1, contentHeight)));
      window.setBounds({
        x: Math.round(
          Math.max(area.x, Math.min(point.x - width + 12, area.x + area.width - width))
        ),
        y: Math.round(
          Math.max(area.y, Math.min(point.y - 12, area.y + area.height - height))
        ),
        width,
        height,
      });
    };
    // Lay the hidden menu out at full height; presenting fits it to the menu.
    place(menuHeight);
    return new Promise<BrowserPageMenuItem | undefined>((resolve, reject) => {
      let finished = false;
      // Listeners get the bare dismissal: an event argument is never a pick.
      const dismiss = () => finish();
      const finish = (picked?: BrowserPageMenuItem) => {
        if (finished) return;
        finished = true;
        input.signal.removeEventListener("abort", dismiss);
        owner.removeListener("hide", dismiss);
        owner.removeListener("minimize", dismiss);
        owner.removeListener("move", dismiss);
        owner.removeListener("resize", dismiss);
        this.#active = undefined;
        if (!window.isDestroyed()) window.hide();
        this.#publish();
        resolve(picked);
      };
      this.#active = {
        input: {
          ...input,
          site: input.site && { ...input.site, choices: { ...input.site.choices } },
        },
        generation: ++this.#generation,
        place,
        finish,
        fail: (error) => {
          reject(error);
          finish();
        },
      };
      input.signal.addEventListener("abort", dismiss, { once: true });
      owner.on("hide", dismiss);
      owner.on("minimize", dismiss);
      owner.on("move", dismiss);
      owner.on("resize", dismiss);
      this.#publish();
      // The renderer acknowledges this generation after committing the new menu.
      // Until then the native window remains hidden, so an old origin cannot flash.
    });
  }
  #requireCaller() {
    if (
      !this.#window ||
      this.#window.isDestroyed() ||
      getCurrentNativeCallerContext().webContentsId !== this.#window.webContents.id
    )
      throw new Error("Website permission menu is unavailable. Open it again.");
  }
  #snapshot(): SitePermissionMenuState {
    const input = this.#active?.input;
    return {
      generation: this.#generation,
      revision: this.#revision,
      menu: input
        ? {
            site: input.site
              ? { origin: input.site.origin, choices: { ...input.site.choices } }
              : null,
            systemSettings: process.platform === "darwin",
          }
        : null,
    };
  }
  #publish() {
    this.#revision++;
    this.options.onStateChanged(this.#snapshot());
  }
  read(): SitePermissionMenuState {
    this.#requireCaller();
    return this.#snapshot();
  }
  async act(action: SitePermissionMenuAction) {
    this.#requireCaller();
    const active = this.#active;
    // Reusing the renderer does not reuse a site's authority: delayed actions
    // from a dismissed presentation cannot affect a later one in the same window.
    if (
      !active ||
      active.input.signal.aborted ||
      action.generation !== active.generation
    )
      throw new Error("Website permission menu has closed. Open it again.");
    const site = active.input.site;
    switch (action.action) {
      case "present":
        active.place(action.height);
        if (!this.#window!.isVisible()) this.#window!.show();
        break;
      case "pick":
        active.finish(action.item);
        break;
      case "change":
        if (!site) throw new Error("This page has no website permissions.");
        site.change(action.media, action.value);
        site.choices[action.media] = action.value;
        this.#publish();
        break;
      case "reset":
        if (!site) throw new Error("This page has no website permissions.");
        site.reset();
        site.choices = { microphone: "ask", camera: "ask" };
        this.#publish();
        break;
      case "reload":
        if (!site) throw new Error("This page has no website permissions.");
        site.reload();
        active.finish();
        break;
      case "close":
        active.finish();
        break;
      case "system-settings":
        if (process.platform === "darwin")
          await shell.openExternal(
            `x-apple.systempreferences:com.apple.preference.security?Privacy_${action.media === "camera" ? "Camera" : "Microphone"}`
          );
        else if (process.platform === "win32")
          await shell.openExternal(
            `ms-settings:privacy-${action.media === "camera" ? "webcam" : "microphone"}`
          );
        break;
    }
  }
  close() {
    this.#active?.finish();
    this.#window?.destroy();
  }
}
