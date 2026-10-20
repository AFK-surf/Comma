import type { ElectronApplication, Page } from "@playwright/test";

/**
 * Reads a window's renderer, giving up after a second (or at the search's
 * deadline). A window whose document has not finished loading does not answer
 * an evaluate, and an unbounded read there held the whole search, and the
 * test, open while the window being searched for was already there.
 */
async function readWindow<T>(
  window: Page,
  read: () => T,
  deadline: number
): Promise<T | undefined> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const giveUp = new Promise<undefined>((resolve) => {
    timer = setTimeout(
      () => resolve(undefined),
      Math.max(0, Math.min(1_000, deadline - Date.now()))
    );
  });
  try {
    return await Promise.race([window.evaluate(read).catch(() => undefined), giveUp]);
  } finally {
    clearTimeout(timer);
  }
}

export async function findElectronWindowByNativeRole(
  app: ElectronApplication,
  role: string,
  timeoutMs = 15_000
): Promise<Page> {
  const deadline = Date.now() + timeoutMs;
  await app.firstWindow();

  while (Date.now() < deadline) {
    for (const window of app.windows()) {
      const nativeRole = await readWindow(
        window,
        () => {
          const rendererWindow = globalThis as typeof globalThis & {
            commaNative?: { self?: { role?: string } };
          };
          return rendererWindow.commaNative?.self?.role;
        },
        deadline
      );
      if (nativeRole === role) return window;
    }

    await app.waitForEvent("window", { timeout: 250 }).catch(() => undefined);
  }

  throw new Error(`Timed out waiting for Electron native role ${role}.`);
}

export async function findElectronWindowByNativeId(
  app: ElectronApplication,
  windowId: string | RegExp,
  timeoutMs = 15_000
): Promise<Page> {
  const expected = typeof windowId === "string" ? windowId : windowId.source;
  const deadline = Date.now() + timeoutMs;
  await app.firstWindow();

  while (Date.now() < deadline) {
    for (const window of app.windows()) {
      const nativeWindowId = await readWindow(
        window,
        () => {
          const rendererWindow = globalThis as typeof globalThis & {
            commaNative?: { self?: { windowId?: string } };
          };
          return rendererWindow.commaNative?.self?.windowId;
        },
        deadline
      );
      let matchesWindowId = nativeWindowId === windowId;
      if (nativeWindowId !== undefined && windowId instanceof RegExp) {
        windowId.lastIndex = 0;
        matchesWindowId = windowId.test(nativeWindowId);
      }
      if (matchesWindowId) {
        return window;
      }
    }

    await app.waitForEvent("window", { timeout: 250 }).catch(() => undefined);
  }

  throw new Error(`Timed out waiting for Electron native window id ${expected}.`);
}
