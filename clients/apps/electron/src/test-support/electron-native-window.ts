import type { ElectronApplication, Page } from "@playwright/test";

export async function findElectronWindowByNativeRole(
  app: ElectronApplication,
  role: string,
  timeoutMs = 15_000
): Promise<Page> {
  const deadline = Date.now() + timeoutMs;
  await app.firstWindow();

  while (Date.now() < deadline) {
    for (const window of app.windows()) {
      const nativeRole = await window
        .evaluate(() => {
          const rendererWindow = globalThis as typeof globalThis & {
            commaNative?: { self?: { role?: string } };
          };
          return rendererWindow.commaNative?.self?.role;
        })
        .catch(() => undefined);
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
      const nativeWindowId = await window
        .evaluate(() => {
          const rendererWindow = globalThis as typeof globalThis & {
            commaNative?: { self?: { windowId?: string } };
          };
          return rendererWindow.commaNative?.self?.windowId;
        })
        .catch(() => undefined);
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
