type ManagedWindowId = string;
type ManagedWindowRole =
  | "site-permission-menu"
  | "meeting-recorder-window"
  | "dev-workbench"
  | "main-window"
  | "onboarding-window";

/** The window's page, as far as its loads are concerned. */
interface ManagedWebContentsLike {
  id: number;
  on(
    event: "did-start-navigation",
    listener: (details: NavigationStart) => void
  ): unknown;
  on(event: "did-finish-load", listener: () => void): unknown;
  on(event: "did-fail-load", listener: LoadFailure): unknown;
  removeListener(
    event: "did-start-navigation",
    listener: (details: NavigationStart) => void
  ): unknown;
  removeListener(event: "did-finish-load", listener: () => void): unknown;
  removeListener(event: "did-fail-load", listener: LoadFailure): unknown;
}

/** Electron's `did-fail-load`: its code (-3 when another navigation replaced the load), and whether of the page. */
type LoadFailure = (
  event: unknown,
  errorCode: number,
  errorDescription: string,
  validatedURL: string,
  isMainFrame: boolean
) => void;

/** What Electron says of a navigation as it starts (`did-start-navigation`). */
interface NavigationStart {
  isMainFrame: boolean;
  isSameDocument: boolean;
}

interface ManagedBrowserWindowLike {
  webContents: ManagedWebContentsLike;
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

  /** The loads followed now (`followDocument`): a close ends them, as no load of the window ends after it. */
  const loads = new Set<ReturnType<typeof followDocument>>();
  browserWindow.on("closed", () => {
    closed = true;
    for (const followed of loads) followed.abandon();
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

  /**
   * Starts the page's load. `loaded` is its end: the end of the new document's load, whichever navigation brought it.
   * A load that failed is logged and unregisters the window.
   */
  const load = async (): Promise<{ loaded: Promise<void> }> => {
    let loadPromise: Promise<unknown>;
    const document = followDocument(browserWindow.webContents);
    loads.add(document);
    try {
      loadPromise = browserWindow.loadURL(loadUrl);
    } catch (error: unknown) {
      loads.delete(document);
      document.abandon();
      logger.error(`${failureLabel} load failed: ${errorMessage(error)}`);
      await cleanupRegistration();
      throw error;
    }

    return {
      loaded: loadPromise
        .then(
          () => document.outcome(),
          (error: unknown) => document.outcome(error)
        )
        .then(async (failure) => {
          if (failure === undefined || closed) return;
          logger.error(`${failureLabel} load failed: ${errorMessage(failure)}`);
          await cleanupRegistration();
        })
        .finally(() => loads.delete(document)),
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

/**
 * Follows the page from the start of a load. Electron's `loadURL` can settle before the document it started does: a
 * route change of the page it replaces (same document) stops that page's loading, and `loadURL` then rejects with
 * `ERR_FAILED` while the new document goes on loading. So the outcome is the document's own: once no new document is
 * loading, the failure of the last one that failed (none if it finished), or, when none started, `loadURL`'s.
 */
function followDocument(contents: ManagedWebContentsLike) {
  let loading = false;
  let started = false;
  let failure: Error | undefined;
  let settle: (() => void) | undefined;
  const onStart = (details: NavigationStart) => {
    if (!details.isMainFrame || details.isSameDocument) return;
    loading = true;
    started = true;
    failure = undefined;
  };
  const ended = () => {
    loading = false;
    settle?.();
  };
  // A load another navigation replaced fails with -3 while that one goes on.
  const onFail: LoadFailure = (_event, errorCode, description, url, isMainFrame) => {
    if (!isMainFrame || errorCode === -3) return;
    failure = new Error(`${description} (${errorCode}) loading '${url}'`);
    ended();
  };
  contents.on("did-start-navigation", onStart);
  contents.on("did-finish-load", ended);
  contents.on("did-fail-load", onFail);
  const stop = () => {
    contents.removeListener("did-start-navigation", onStart);
    contents.removeListener("did-finish-load", ended);
    contents.removeListener("did-fail-load", onFail);
  };
  return {
    /** The load's failure once no new document is loading; undefined when the page loaded. */
    outcome: async (loadError?: unknown): Promise<unknown> => {
      if (loading)
        await new Promise<void>((resolve) => {
          settle = resolve;
        });
      stop();
      if (started) return failure;
      // No new document started: the load never began (a bad URL), or a navigation already over replaced it.
      return loadError === undefined || isAbortedLoad(loadError)
        ? undefined
        : loadError;
    },
    /** The window closed: no load of it ends any more. */
    abandon: () => {
      stop();
      ended();
    },
  };
}

/** Electron rejects `loadURL` with `ERR_ABORTED` when another navigation of the page replaces the load. */
function isAbortedLoad(error: unknown) {
  return (error as { code?: unknown } | null)?.code === "ERR_ABORTED";
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
