import type { ElectronApplication } from "@playwright/test";

/** Bound cleanup of this test's process without treating forced exit as success. */
export async function closeElectronTestApp(
  app: ElectronApplication,
  timeoutMs = 10_000
): Promise<void> {
  const child = app.process();
  try {
    await within(
      app.close(),
      timeoutMs,
      `Electron test app did not exit within ${timeoutMs}ms`
    );
  } catch (error) {
    if (child.exitCode === null && child.signalCode === null) {
      let onExit: (() => void) | undefined;
      const exited = new Promise<void>((resolve) => {
        onExit = resolve;
        child.once("exit", onExit);
      });
      try {
        child.kill("SIGKILL");
        await within(exited, 5_000, "Electron test process did not stop after SIGKILL");
      } catch (cleanupError) {
        throw new Error(`Electron test cleanup failed after: ${String(error)}`, {
          cause: cleanupError,
        });
      } finally {
        if (onExit) child.off("exit", onExit);
      }
    }
    throw error;
  }
}

async function within<T>(work: Promise<T>, timeoutMs: number, message: string) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      work,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error(message)), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
