type ManagedWindowId = string;
type ManagedWindowRole =
  | "site-permission-menu"
  | "meeting-recorder-window"
  | "dev-workbench"
  | "main-window"
  | "side-chat-test-window"
  | "side-chat-window";

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
}) {
  let closed = false;
  const cleanupRegistration = async () => {
    webContentsRegistry.unregisterWindow(id, browserWindow);
    try {
      await surfaces.unregisterWindow(id, browserWindow);
    } catch (error: unknown) {
      logger.warn(`${failureLabel} surface unregister failed: ${errorMessage(error)}`);
    }
  };

  browserWindow.on("closed", () => {
    closed = true;
    void cleanupRegistration();
  });
  browserWindow.on("ready-to-show", () => {
    if (!showOnReady) return;
    if (showInactiveOnReady) {
      browserWindow.showInactive();
      return;
    }
    browserWindow.show();
  });

  try {
    installWindowSecurity();
    if (closed) return;

    webContentsRegistry.registerWindow({
      id,
      role,
      window: browserWindow,
    });
    if (closed) {
      await cleanupRegistration();
      return;
    }

    await surfaces.registerWindow({
      id,
      role,
      route,
      window: browserWindow,
    });
    if (closed) {
      // A registration implementation may only publish after its promise settles.
      // Clean again so a close during that pending work cannot leave a ghost entry.
      await cleanupRegistration();
      return;
    }
  } catch (error: unknown) {
    await cleanupRegistration();
    throw error;
  }

  let loadPromise: Promise<unknown>;
  try {
    loadPromise = browserWindow.loadURL(loadUrl);
  } catch (error: unknown) {
    logger.error(`${failureLabel} load failed: ${errorMessage(error)}`);
    await cleanupRegistration();
    throw error;
  }

  void loadPromise.catch(async (error: unknown) => {
    logger.error(`${failureLabel} load failed: ${errorMessage(error)}`);
    await cleanupRegistration();
  });
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
