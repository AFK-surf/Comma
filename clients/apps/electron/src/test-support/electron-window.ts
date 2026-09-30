type WindowRoleOptions = {
  name?: string | RegExp;
  timeoutMs?: number;
};

interface RoleLocator {
  count(): Promise<number>;
}

interface ElectronWindowLike {
  getByRole(role: string, options?: { name?: string | RegExp }): RoleLocator;
  waitForLoadState(
    state: "domcontentloaded",
    options?: { timeout?: number }
  ): Promise<void>;
  url(): string;
}

interface ElectronAppLike<Window extends ElectronWindowLike> {
  firstWindow(): Promise<Window>;
  waitForEvent(event: "window", options?: { timeout?: number }): Promise<Window>;
  windows(): Window[];
}

export async function findElectronWindowByRole<Window extends ElectronWindowLike>(
  app: ElectronAppLike<Window>,
  role: string,
  { name, timeoutMs = 15_000 }: WindowRoleOptions = {}
): Promise<Window> {
  const deadline = Date.now() + timeoutMs;
  const seen = new Set<Window>();
  const firstWindow = await app.firstWindow();
  seen.add(firstWindow);

  while (Date.now() <= deadline) {
    for (const window of app.windows()) {
      seen.add(window);
    }

    for (const window of seen) {
      if (await windowHasRole(window, role, name)) {
        return window;
      }
    }

    const remainingMs = deadline - Date.now();
    if (remainingMs <= 0) {
      break;
    }

    await app
      .waitForEvent("window", { timeout: Math.min(remainingMs, 250) })
      .then((window) => {
        seen.add(window);
      })
      .catch(() => {});
  }

  throw new Error(
    `Timed out waiting for Electron window with role ${role}${formatName(
      name
    )}. Seen windows: ${[...seen].map((window) => window.url()).join(", ")}`
  );
}

async function windowHasRole<Window extends ElectronWindowLike>(
  window: Window,
  role: string,
  name?: string | RegExp
) {
  await window.waitForLoadState("domcontentloaded", { timeout: 1_000 }).catch(() => {});
  const roleOptions = name === undefined ? undefined : { name };
  return (await window.getByRole(role, roleOptions).count()) > 0;
}

function formatName(name: string | RegExp | undefined) {
  return name === undefined ? "" : ` named ${String(name)}`;
}
