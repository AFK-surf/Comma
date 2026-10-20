import type { ElectronApplication } from "@playwright/test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { expect, test, vi } from "vitest";
import {
  closeElectronTestApp,
  trackElectronTestApp,
} from "../e2e/close-electron-test-app";
import { MAIN_SHUTDOWN_COMPLETE_LINE } from "../src/main/e2e-shutdown-report";

// Keep a real child alive to check termination, not just whether kill was called.
// The stack sampler is stubbed: `sample` spends a second or more on a real pid.
test("a stalled window cleanup fails and releases its process", async () => {
  const child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
    stdio: "ignore",
  });
  await once(child, "spawn");
  let closeCalled = false;
  const app = {
    process: () => child,
    close: async () => {
      closeCalled = true;
      const exited = once(child, "exit");
      child.kill();
      await exited;
    },
  } as unknown as ElectronApplication;
  const recordHung = vi.fn();
  try {
    await expect(
      closeElectronTestApp(app, 100, () => new Promise<void>(() => {}), recordHung)
    ).rejects.toThrow("preparing windows");
    expect(closeCalled).toBe(false);
    expect(recordHung).toHaveBeenCalledExactlyOnceWith(child.pid);
    expect(child.exitCode !== null || child.signalCode !== null).toBe(true);
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, "exit");
      child.kill("SIGKILL");
      await exited;
    }
  }
});

/**
 * A Main stand-in in its own process group, as Playwright starts Electron. On
 * close (a line on stdin) it prints `report`, then keeps running, as Chromium
 * does while it flushes the profile. Close resolves only once it has exited.
 */
async function lingeringMain(report: string) {
  const child = spawn(
    "/bin/sh",
    ["-c", 'read -r _; printf "%s\\n" "$1"; exec sleep 3600', "main", report],
    { detached: true, stdio: ["pipe", "pipe", "ignore"] }
  );
  await once(child, "spawn");
  const exited = once(child, "exit");
  const app = {
    process: () => child,
    evaluate: async () => undefined,
    close: async () => {
      child.stdin.write("quit\n");
      await exited;
    },
  } as unknown as ElectronApplication;
  return { app, child, exited };
}

test("a Main that reports its finished shutdown closes without waiting for Chromium", async () => {
  const { app, child, exited } = await lingeringMain(MAIN_SHUTDOWN_COMPLETE_LINE);
  const recordHung = vi.fn();
  try {
    await closeElectronTestApp(app, 5_000, undefined, recordHung);
    await exited;
    expect(child.signalCode).toBe("SIGKILL");
    expect(recordHung).not.toHaveBeenCalled();
  } finally {
    if (child.exitCode === null && child.signalCode === null)
      process.kill(-child.pid!, "SIGKILL");
  }
});

test("a Main that never reports its shutdown still fails the close", async () => {
  const { app, child, exited } = await lingeringMain("some other output");
  const recordHung = vi.fn();
  try {
    await expect(closeElectronTestApp(app, 200, undefined, recordHung)).rejects.toThrow(
      "closing app; Main did not report its shutdown"
    );
    expect(recordHung).toHaveBeenCalledExactlyOnceWith(child.pid);
    await exited;
  } finally {
    if (child.exitCode === null && child.signalCode === null)
      process.kill(-child.pid!, "SIGKILL");
  }
});

test("a Main that crashes while closing fails the close", async () => {
  const child = spawn("/bin/sh", ["-c", "read -r _; kill -SEGV $$"], {
    stdio: ["pipe", "pipe", "ignore"],
  });
  await once(child, "spawn");
  const exited = once(child, "exit");
  const app = {
    process: () => child,
    evaluate: async () => undefined,
    close: async () => {
      child.stdin.write("quit\n");
      await exited;
    },
  } as unknown as ElectronApplication;
  await expect(closeElectronTestApp(app, 5_000)).rejects.toThrow(
    "exited by SIGSEGV while closing"
  );
});

/** What Playwright's calls on a disposed app throw. */
function gone(): never {
  throw new TypeError("Cannot read properties of undefined (reading '_object')");
}

/**
 * A Main that ran `script` (`$1` is the shutdown report line) and exited before
 * the close, tracked from its launch as `electron.launch` does. Playwright has
 * disposed the app: its process(), evaluate() and close() throw.
 */
async function exitedMain(script: string) {
  let disposed = false;
  const child = spawn("/bin/sh", ["-c", script, "main", MAIN_SHUTDOWN_COMPLETE_LINE], {
    stdio: ["ignore", "pipe", "ignore"],
  });
  const app = {
    process: () => (disposed ? gone() : child),
    evaluate: async () => gone(),
    close: async () => gone(),
  } as unknown as ElectronApplication;
  trackElectronTestApp(app);
  await once(child, "exit");
  disposed = true;
  return { app, child };
}

test("a Main that reported its shutdown before the close is killed, not closed again", async () => {
  const child = spawn(
    "/bin/sh",
    ["-c", 'printf "%s\\n" "$1"; exec sleep 3600', "main", MAIN_SHUTDOWN_COMPLETE_LINE],
    { detached: true, stdio: ["ignore", "pipe", "ignore"] }
  );
  await once(child, "spawn");
  const close = vi.fn();
  const app = {
    process: () => child,
    evaluate: async () => undefined,
    close,
  } as unknown as ElectronApplication;
  try {
    await trackElectronTestApp(app).report.promise;
    await closeElectronTestApp(app, 5_000);
    expect(close).not.toHaveBeenCalled();
    expect(child.signalCode).toBe("SIGKILL");
  } finally {
    if (child.exitCode === null && child.signalCode === null)
      process.kill(-child.pid!, "SIGKILL");
  }
});

test("a Main that exited with code 0 after its report is a finished close, though Playwright disposed the app", async () => {
  const { app, child } = await exitedMain('printf "%s\\n" "$1"; exit 0');
  await closeElectronTestApp(app, 5_000);
  expect(child.exitCode).toBe(0);
});

test("a Main that crashed before the close fails it", async () => {
  const { app } = await exitedMain('printf "%s\\n" "$1"; kill -SEGV $$');
  await expect(closeElectronTestApp(app, 5_000)).rejects.toThrow(
    "exited by SIGSEGV while closing"
  );
});

test("a Main that exited with a non-zero code before the close fails it", async () => {
  const { app } = await exitedMain('printf "%s\\n" "$1"; exit 70');
  await expect(closeElectronTestApp(app, 5_000)).rejects.toThrow(
    "exited with code 70 while closing"
  );
});

test("a Main that exited before the close without its report fails it", async () => {
  const { app } = await exitedMain("exit 0");
  await expect(closeElectronTestApp(app, 5_000)).rejects.toThrow(
    "exited before the close without reporting its shutdown"
  );
});
