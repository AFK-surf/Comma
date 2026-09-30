import { BrowserWindow, screen } from "electron";
import type {
  MeetingRecorderState,
  MeetingRecorderWindowLayout,
  MeetingRecorderWindowDrag,
} from "@comma/native-bridge";
import { configureManagedWindow } from "./managed-window";
import { createMeetingRecorderWindowOptions } from "./window-options";
import type { NativeSurfaceService } from "./modules/surfaces";
import type { WebContentsRegistry } from "./modules/ipc";

import { recorderWindowBounds, type RecorderCenter } from "./recorder-window-geometry";

/** One native accessory bounded to the recorder and its currently open menu. */
export class MeetingRecorderWindow {
  #window: BrowserWindow | undefined;
  #size: MeetingRecorderWindowLayout = { width: 418, height: 112 };
  #center: RecorderCenter | undefined;
  #drag: { point: RecorderCenter; center: RecorderCenter } | undefined;
  #rebound: ReturnType<typeof setTimeout> | undefined;
  #loading: Promise<void> | undefined;
  #state: MeetingRecorderState | undefined;
  #ready = false;
  #painted = false;
  #closed = false;
  #loadFailure: Error | undefined;
  constructor(
    private readonly options: {
      preloadPath: string;
      url: string;
      surfaces: NativeSurfaceService;
      registry: WebContentsRegistry;
      secure(window: BrowserWindow): void;
      logger: { error(message: string): void; warn(message: string): void };
    }
  ) {
    screen.on("display-metrics-changed", this.#reposition);
    screen.on("display-removed", this.#reposition);
  }
  update(state: MeetingRecorderState) {
    this.#state = state;
    if (
      state.phase === "idle" ||
      (state.hideRecorder && state.phase !== "detected" && state.phase !== "error")
    ) {
      this.#window?.hide();
      if (state.phase === "idle") this.#painted = false;
      return;
    }
    void this.prepare()
      .then(() => this.#present())
      .catch((error) => this.options.logger.error(String(error)));
  }
  async prepare() {
    if (this.#loadFailure) throw this.#loadFailure;
    if (this.#closed) throw new Error("Recorder window is closed.");
    if (this.#loading) return this.#loading;
    if (this.#ready && this.#window && !this.#window.isDestroyed()) return;
    const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
    this.#center ??= {
      x: display.workArea.x + display.workArea.width / 2,
      y: display.workArea.y + 32 + this.#size.height / 2,
    };
    const window = new BrowserWindow(
      createMeetingRecorderWindowOptions({
        bounds: recorderWindowBounds(this.#center, this.#size, display.workArea),
        preloadPath: this.options.preloadPath,
      })
    );
    this.#window = window;
    window.setAlwaysOnTop(true, "floating");
    // Preserve the app's Dock preference when the recorder crosses Spaces.
    // Electron otherwise hides the Dock icon for visibleOnFullScreen.
    window.setVisibleOnAllWorkspaces(true, {
      skipTransformProcessType: true,
      visibleOnFullScreen: true,
    });
    window.setIgnoreMouseEvents(true, { forward: true });
    window.on("closed", () => {
      if (this.#window === window) {
        this.#window = undefined;
        this.#ready = false;
        this.#painted = false;
      }
    });
    this.#loading = configureManagedWindow({
      browserWindow: window,
      id: "meeting-recorder",
      role: "meeting-recorder-window",
      route: "/meeting-recorder",
      loadUrl: this.options.url,
      failureLabel: "meeting recorder",
      logger: this.options.logger,
      installWindowSecurity: () => this.options.secure(window),
      surfaces: this.options.surfaces,
      webContentsRegistry: this.options.registry,
      showOnReady: false,
    })
      .then(async () => {
        // Loading allows capture to start. Showing waits for the renderer's
        // first measured, painted recorder instead of exposing an empty document.
        if (window.webContents.isLoading())
          await new Promise<void>((resolve, reject) => {
            window.webContents.once("did-finish-load", () => resolve());
            window.webContents.once("did-fail-load", (_event, _code, description) =>
              reject(new Error(description))
            );
            window.once("closed", () =>
              reject(new Error("Recorder window closed during load."))
            );
          });
        if (this.#closed || window.isDestroyed())
          throw new Error("Recorder window is unavailable.");
        this.#ready = true;
        this.#present();
      })
      .catch((cause: unknown) => {
        this.#loadFailure = new Error(
          "Could not open the recording controls. Restart Comma and try again.",
          { cause }
        );
        if (!window.isDestroyed()) window.destroy();
        throw this.#loadFailure;
      })
      .finally(() => {
        this.#loading = undefined;
      });
    return this.#loading;
  }
  setInteractive(interactive: boolean) {
    if (this.#window && !this.#window.isDestroyed())
      this.#window.setIgnoreMouseEvents(!interactive, { forward: true });
  }
  #present() {
    if (
      !this.#ready ||
      !this.#painted ||
      !this.#window ||
      this.#closed ||
      this.#state?.phase === "idle" ||
      (this.#state?.hideRecorder &&
        this.#state.phase !== "detected" &&
        this.#state.phase !== "error") ||
      !this.#state
    )
      return;
    if (!this.#window.isVisible()) this.#window.showInactive();
  }
  layout(size: MeetingRecorderWindowLayout) {
    this.#painted = true;
    if (
      Math.ceil(size.width) === this.#size.width &&
      Math.ceil(size.height) === this.#size.height &&
      size.anchorY === this.#size.anchorY
    ) {
      this.#present();
      return;
    }
    this.#size = {
      ...size,
      width: Math.ceil(size.width),
      height: Math.ceil(size.height),
    };
    this.#apply(!this.#drag && !this.#rebound);
    this.#present();
  }
  drag(input: MeetingRecorderWindowDrag) {
    const window = this.#window;
    if (!window || window.isDestroyed()) return;
    const point = { x: input.screenX, y: input.screenY };
    if (input.phase === "start") {
      this.#stopRebound();
      const bounds = window.getBounds();
      this.#center = {
        x: bounds.x + bounds.width / 2,
        y: bounds.y + (this.#size.anchorY ?? bounds.height / 2),
      };
      this.#drag = { point, center: this.#center };
      return;
    }
    if (!this.#drag) return;
    this.#center = {
      x: this.#drag.center.x + point.x - this.#drag.point.x,
      y: this.#drag.center.y + point.y - this.#drag.point.y,
    };
    this.#apply(false);
    if (input.phase !== "end") return;
    this.#drag = undefined;
    const bounds = window.getBounds();
    const from = {
      x: bounds.x + bounds.width / 2,
      y: bounds.y + (this.#size.anchorY ?? bounds.height / 2),
    };
    const target = recorderWindowBounds(
      from,
      this.#size,
      screen.getDisplayMatching(bounds).workArea
    );
    const to = {
      x: target.x + target.width / 2,
      y: target.y + (this.#size.anchorY ?? target.height / 2),
    };
    if (input.reducedMotion || (from.x === to.x && from.y === to.y)) {
      this.#center = to;
      this.#apply(true);
      return;
    }
    // One bounded 180ms return per released drag, no idle polling.
    const started = performance.now();
    const step = () => {
      const progress = Math.min(1, (performance.now() - started) / 180);
      const eased = 1 - Math.pow(1 - progress, 3);
      this.#center = {
        x: from.x + (to.x - from.x) * eased,
        y: from.y + (to.y - from.y) * eased,
      };
      this.#apply(progress === 1);
      this.#rebound = progress < 1 ? setTimeout(step, 16) : undefined;
    };
    step();
  }
  #apply(clamp: boolean) {
    const window = this.#window;
    if (!window || window.isDestroyed() || !this.#center) return;
    const area = screen.getDisplayNearestPoint({
      x: Math.round(this.#center.x),
      y: Math.round(this.#center.y),
    }).workArea;
    const bounds = recorderWindowBounds(this.#center, this.#size, area, clamp);
    const current = window.getBounds();
    if (
      current.x !== bounds.x ||
      current.y !== bounds.y ||
      current.width !== bounds.width ||
      current.height !== bounds.height
    )
      window.setBounds(bounds);
    if (clamp) {
      const unclamped = recorderWindowBounds(this.#center, this.#size, area, false);
      this.#center = {
        x: this.#center.x + bounds.x - unclamped.x,
        y: this.#center.y + bounds.y - unclamped.y,
      };
    }
  }
  #stopRebound() {
    if (this.#rebound) clearTimeout(this.#rebound);
    this.#rebound = undefined;
  }
  #reposition = () => {
    this.#stopRebound();
    this.#drag = undefined;
    this.#apply(true);
  };
  close() {
    this.#stopRebound();
    this.#closed = true;
    screen.removeListener("display-metrics-changed", this.#reposition);
    screen.removeListener("display-removed", this.#reposition);
    this.#window?.destroy();
  }
}
