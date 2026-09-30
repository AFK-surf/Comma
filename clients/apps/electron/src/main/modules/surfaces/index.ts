import type {
  NativeInfo,
  NotchStatus,
  SurfaceList,
  SurfaceBounds,
  SurfaceLifecycle,
  ViewSurface,
  WindowCreateInput,
  WindowFullScreen,
  WindowSurface,
  WindowTargetInput,
} from "@comma/native-bridge";

interface WindowLike {
  close(): void;
  focus(): void;
  getBounds(): { x: number; y: number; width: number; height: number };
  isFocused(): boolean;
  isFullScreen(): boolean;
  isMaximized(): boolean;
  isMinimized(): boolean;
  isVisible(): boolean;
  restore?(): void;
  show?(): void;
}

interface WindowRegistration {
  id: string;
  ownerId?: string | undefined;
  role: string;
  route: string;
  window: WindowLike;
}

interface ViewRegistration {
  bounds: SurfaceBounds;
  id: string;
  lifecycle: SurfaceLifecycle;
  ownerWindowId: string;
  partition?: string | undefined;
  role: string;
  view: object;
}

type StateChangePublisher = (state: SurfaceList) => Promise<void> | void;

export interface NativeWindowOpenRequest {
  route: string;
  role: "main-window";
  windowId: string;
}

export class NativeSurfaceService {
  readonly #getNativeInfo: () => NativeInfo;
  readonly #getNotchStatus: () => Promise<NotchStatus> | NotchStatus;
  readonly #onStateChanged: StateChangePublisher | undefined;
  readonly #views = new Map<string, ViewRegistration>();
  readonly #windows = new Map<string, WindowRegistration>();

  constructor({
    getNativeInfo,
    getNotchStatus,
    onStateChanged,
  }: {
    getNativeInfo: () => NativeInfo;
    getNotchStatus: () => Promise<NotchStatus> | NotchStatus;
    onStateChanged?: StateChangePublisher | undefined;
  }) {
    this.#getNativeInfo = getNativeInfo;
    this.#getNotchStatus = getNotchStatus;
    this.#onStateChanged = onStateChanged;
  }

  async registerWindow(registration: WindowRegistration) {
    this.#windows.set(registration.id, registration);
    try {
      await this.#publishStateChange();
    } catch (error: unknown) {
      if (this.#windows.get(registration.id)?.window === registration.window) {
        this.#windows.delete(registration.id);
      }
      throw error;
    }
  }

  async unregisterWindow(windowId: string, expectedWindow?: WindowLike) {
    const registration = this.#windows.get(windowId);
    if (!registration || (expectedWindow && registration.window !== expectedWindow)) {
      return;
    }

    this.#windows.delete(windowId);
    for (const [viewId, view] of this.#views) {
      if (view.ownerWindowId === windowId) {
        this.#views.delete(viewId);
      }
    }
    await this.#publishStateChange();
  }

  async registerView(registration: ViewRegistration) {
    if (!this.#windows.has(registration.ownerWindowId)) {
      throw new Error(`Owner window ${registration.ownerWindowId} is not registered.`);
    }

    this.#views.set(registration.id, registration);
    try {
      await this.#publishStateChange();
    } catch (error: unknown) {
      if (this.#views.get(registration.id)?.view === registration.view) {
        this.#views.delete(registration.id);
      }
      throw error;
    }
  }

  async updateView(
    viewId: string,
    expectedView: object,
    patch: Partial<Pick<ViewRegistration, "bounds" | "lifecycle">>
  ) {
    const registration = this.#views.get(viewId);
    if (!registration || registration.view !== expectedView) {
      return false;
    }

    const updated = { ...registration, ...patch };
    this.#views.set(viewId, updated);
    try {
      await this.#publishStateChange();
    } catch (error: unknown) {
      if (this.#views.get(viewId) === updated) {
        this.#views.set(viewId, registration);
      }
      throw error;
    }
    return true;
  }

  async unregisterView(viewId: string, expectedView?: object) {
    const registration = this.#views.get(viewId);
    if (!registration || (expectedView && registration.view !== expectedView)) {
      return;
    }

    this.#views.delete(viewId);
    await this.#publishStateChange();
  }

  async focusWindow(windowId: string) {
    const registration = this.#getWindow(windowId);
    if (!registration.window.isVisible()) {
      registration.window.show?.();
    }
    if (registration.window.isMinimized()) {
      registration.window.restore?.();
    }
    registration.window.focus();
    return this.snapshot();
  }

  async closeWindow(windowId: string) {
    const registration = this.#getWindow(windowId);
    registration.window.close();
    if (this.#windows.get(windowId)?.window === registration.window) {
      this.#windows.delete(windowId);
      for (const [viewId, view] of this.#views) {
        if (view.ownerWindowId === windowId) {
          this.#views.delete(viewId);
        }
      }
    }
    const state = await this.snapshot();
    await this.#publishStateChange(state);
    return state;
  }

  state(): Promise<SurfaceList> {
    return this.snapshot();
  }

  windowFullScreen(windowId: string): WindowFullScreen {
    return { fullScreen: this.#getWindow(windowId).window.isFullScreen() };
  }

  async snapshot(): Promise<SurfaceList> {
    return {
      notch: await this.#getNotchStatus(),
      panels: [],
      platform: this.#getNativeInfo(),
      views: Array.from(this.#views.values(), (registration) =>
        toViewSurface(registration)
      ),
      windows: Array.from(this.#windows.values(), (registration) =>
        toWindowSurface(registration)
      ),
    };
  }

  #getWindow(windowId: string) {
    const registration = this.#windows.get(windowId);

    if (!registration) {
      throw new Error(`Window ${windowId} is not registered.`);
    }

    return registration;
  }

  async #publishStateChange(state?: SurfaceList) {
    if (!this.#onStateChanged) {
      return;
    }

    await this.#onStateChanged(state ?? (await this.snapshot()));
  }
}

function toViewSurface(registration: ViewRegistration): ViewSurface {
  return {
    bounds: registration.bounds,
    id: registration.id,
    lifecycle: registration.lifecycle,
    owner: {
      id: registration.ownerWindowId,
      kind: "window",
    },
    ...(registration.partition ? { partition: registration.partition } : {}),
    role: registration.role,
    surfaceId: registration.id,
    windowId: registration.ownerWindowId,
  };
}

export class NativeWindowCommandService {
  readonly #activateApplication: () => void;
  readonly #nextWindowId: () => string;
  readonly #openWindow: (request: NativeWindowOpenRequest) => Promise<void> | void;
  readonly #surfaces: NativeSurfaceService;

  constructor({
    activateApplication = () => undefined,
    nextWindowId = createDynamicWindowIdFactory(),
    openWindow,
    surfaces,
  }: {
    activateApplication?: (() => void) | undefined;
    nextWindowId?: (() => string) | undefined;
    openWindow: (request: NativeWindowOpenRequest) => Promise<void> | void;
    surfaces: NativeSurfaceService;
  }) {
    this.#activateApplication = activateApplication;
    this.#nextWindowId = nextWindowId;
    this.#openWindow = openWindow;
    this.#surfaces = surfaces;
  }

  async create(input: WindowCreateInput) {
    const request: NativeWindowOpenRequest = {
      role: "main-window",
      route: input.route,
      windowId: this.#nextWindowId(),
    };

    await this.#openWindow(request);
    return this.#surfaces.state();
  }

  focus(input: WindowTargetInput) {
    this.#activateApplication();
    return this.#surfaces.focusWindow(input.windowId);
  }

  close(input: WindowTargetInput) {
    return this.#surfaces.closeWindow(input.windowId);
  }
}

function createDynamicWindowIdFactory() {
  let nextId = 0;

  return () => {
    nextId += 1;
    return `win_dynamic_${nextId}`;
  };
}

function toWindowSurface(registration: WindowRegistration): WindowSurface {
  return {
    bounds: registration.window.getBounds(),
    focused: registration.window.isFocused(),
    id: registration.id,
    lifecycle: "ready",
    owner: {
      id: registration.ownerId ?? "app",
      kind: registration.ownerId ? "window" : "app",
    },
    role: registration.role,
    route: registration.route,
    state: getWindowState(registration.window),
    surfaceId: registration.id,
    visible: registration.window.isVisible(),
  };
}

function getWindowState(window: WindowLike): WindowSurface["state"] {
  if (window.isFullScreen()) {
    return "fullscreen";
  }

  if (window.isMaximized()) {
    return "maximized";
  }

  if (window.isMinimized()) {
    return "minimized";
  }

  return "normal";
}
