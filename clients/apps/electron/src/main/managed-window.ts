type ManagedWindowId = string;
type ManagedWindowRole =
  | "site-permission-menu"
  | "meeting-recorder-window"
  | "dev-workbench"
  | "main-window"
  | "onboarding-window";

interface ManagedBrowserWindowLike {
  webContents: { id: number };
  close(): void;
  focus(): void;
  getBounds(): { x: number; y: number; width: number; height: number };
  isFocused(): boolean;
  isFullScreen(): boolean;
  isMaximized(): boolean;
  isMinimized(): boolean;
  isVisible(): boolean;
  loadURL(url: string): Promise<unknown>;
  on(event: "closed" | "ready-to-show", listener: () => void): void;
  show(): void;
  showInactive(): void;
}

interface ManagedWindowLogger {
  error(message: string): void;
  warn(message: string): void;
}

interface ManagedWindowSurfaces {
  registerWindow(registration: {
    id: ManagedWindowId;
    role: ManagedWindowRole;
    route: string;
    window: ManagedBrowserWindowLike;
  }): Promise<void> | void;
  unregisterWindow(
    windowId: ManagedWindowId,
    expectedWindow?: ManagedBrowserWindowLike
  ): Promise<void> | void;
}

interface ManagedWindowRegistry {
  registerWindow(registration: {
    id: ManagedWindowId;
    role: ManagedWindowRole;
    window: ManagedBrowserWindowLike;
  }): void;
  unregisterWindow(
    windowId: ManagedWindowId,
    expectedWindow?: ManagedBrowserWindowLike
  ): void;
}

/**
 * A managed window's tie to Main's services. A reset of the app (`app.reset`) keeps the window and ties it to the new
 * services with `rebind`.
 */
export interface ManagedWindowBinding {
  /**
   * Takes the window out of the services it is registered with, registers it with `next`, and loads its page again:
   * the renderer starts as it does in a new window, with the new services. Resolves once the page has loaded.
   */
  rebind(next: {
    surfaces: ManagedWindowSurfaces;
    webContentsRegistry: ManagedWindowRegistry;
  }): Promise<void>;
}

export async function configureManagedWindow({
  browserWindow,
  failureLabel,
  id,
  installWindowSecurity,
  loadUrl,
  logger,
  role,
  route,
  showOnReady = true,
  showInactiveOnReady = false,
  surfaces,
  webContentsRegistry,
  onBound,
}: {
  browserWindow: ManagedBrowserWindowLike;
  failureLabel: string;
  id: ManagedWindowId;
  installWindowSecurity: () => void;
  loadUrl: string;
  logger: ManagedWindowLogger;
  role: ManagedWindowRole;
  route: string;
  showOnReady?: boolean | undefined;
  showInactiveOnReady?: boolean | undefined;
  surfaces: ManagedWindowSurfaces;
  webContentsRegistry: ManagedWindowRegistry;
  /** Takes the window's binding once it is registered and loading (see `ManagedWindowBinding`). */
  onBound?: (binding: ManagedWindowBinding) => void;
}): Promise<void> {
  let closed = false;
  // The services the window is registered with now; a rebind moves it to others.
  let services = { surfaces, webContentsRegistry };
  const cleanupRegistration = async (from = services) => {
    from.webContentsRegistry.unregisterWindow(id, browserWindow);
    try {
      await from.surfaces.unregisterWindow(id, browserWindow);
    } catch (error: unknown) {
      logger.warn(`${failureLabel} surface unregister failed: ${errorMessage(error)}`);
    }
  };

  browserWindow.on("closed", () => {
    closed = true;
    void cleanupRegistration();
  });
  // Electron also forwards `ready-to-show` from every hosted WebContentsView,
  // such as an in-app browser tab, on each new document. Only the window's
  // first paint shows it; later ones must not raise a background app.
  let readyToShowHandled = false;
  browserWindow.on("ready-to-show", () => {
    if (readyToShowHandled) return;
    readyToShowHandled = true;
    if (!showOnReady) return;
    if (showInactiveOnReady) {
      browserWindow.showInactive();
      return;
    }
    browserWindow.show();
  });

  const register = async () => {
    services.webContentsRegistry.registerWindow({
      id,
      role,
      window: browserWindow,
    });
    if (closed) {
      await cleanupRegistration();
      return false;
    }

    await services.surfaces.registerWindow({
      id,
      role,
      route,
      window: browserWindow,
    });
    if (closed) {
      // A registration implementation may only publish after its promise settles.
      // Clean again so a close during that pending work cannot leave a ghost entry.
      await cleanupRegistration();
      return false;
    }
    return true;
  };

  /** Starts the page's load. `loaded` is its end: a failed load is logged and unregisters the window. */
  const load = async (): Promise<{ loaded: Promise<void> }> => {
    let loadPromise: Promise<unknown>;
    try {
      loadPromise = browserWindow.loadURL(loadUrl);
    } catch (error: unknown) {
      logger.error(`${failureLabel} load failed: ${errorMessage(error)}`);
      await cleanupRegistration();
      throw error;
    }

    return {
      loaded: loadPromise.then(
        () => undefined,
        async (error: unknown) => {
          // A navigation of the window's own page (a reload, say) replaced this load; the window goes on loading.
          if (isAbortedLoad(error)) return;
          logger.error(`${failureLabel} load failed: ${errorMessage(error)}`);
          await cleanupRegistration();
        }
      ),
    };
  };

  try {
    installWindowSecurity();
    if (closed) return;
    if (!(await register())) return;
  } catch (error: unknown) {
    await cleanupRegistration();
    throw error;
  }
  await load();

  onBound?.({
    async rebind(next) {
      if (closed) return;
      const previous = services;
      services = next;
      await cleanupRegistration(previous);
      try {
        if (!(await register())) return;
      } catch (error: unknown) {
        await cleanupRegistration();
        throw error;
      }
      await (
        await load()
      ).loaded;
    },
  });
}

/** Electron rejects `loadURL` with `ERR_ABORTED` when another navigation of the page replaces the load. */
function isAbortedLoad(error: unknown) {
  return (error as { code?: unknown } | null)?.code === "ERR_ABORTED";
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
