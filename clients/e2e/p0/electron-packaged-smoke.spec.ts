import { chromium, expect, test } from "@playwright/test";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { createServer } from "node:net";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronOutDir = resolve(electronAppDir, "out");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const require = createRequire(import.meta.url);
const electronDistDir = resolve(require.resolve("electron/package.json"), "..", "dist");

interface LaunchTarget {
  executable: string;
  extraArgs: string[];
}

function electronPackageExecutable() {
  if (process.platform === "darwin") {
    return resolve(
      process.cwd(),
      electronDistDir,
      "Electron.app/Contents/MacOS/Electron"
    );
  }

  if (process.platform === "win32") {
    return resolve(electronDistDir, "electron.exe");
  }

  return resolve(electronDistDir, "electron");
}

function electronTestEnv() {
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...env } = process.env;
  return {
    ...env,
    NODE_ENV: "test",
  };
}

function findPackagedExecutable(): LaunchTarget {
  if (!existsSync(electronOutDir)) {
    return {
      executable: electronPackageExecutable(),
      extraArgs: [electronMain],
    };
  }

  const packageDirs = readdirSync(electronOutDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => join(electronOutDir, entry.name));

  for (const packageDir of packageDirs) {
    if (process.platform === "darwin") {
      const appBundle = readdirSync(packageDir, { withFileTypes: true }).find(
        (entry) => entry.isDirectory() && entry.name.endsWith(".app")
      );
      if (!appBundle) {
        continue;
      }

      const macOsDir = join(packageDir, appBundle.name, "Contents", "MacOS");
      const executable = readdirSync(macOsDir, { withFileTypes: true }).find((entry) =>
        entry.isFile()
      );
      if (executable) {
        return { executable: join(macOsDir, executable.name), extraArgs: [] };
      }
    }

    if (process.platform === "win32") {
      const executable = readdirSync(packageDir, { withFileTypes: true }).find(
        (entry) => entry.isFile() && entry.name.endsWith(".exe")
      );
      if (executable) {
        return { executable: join(packageDir, executable.name), extraArgs: [] };
      }
    }

    if (process.platform === "linux") {
      const executable = readdirSync(packageDir, { withFileTypes: true }).find(
        (entry) => entry.isFile() && !entry.name.includes(".")
      );
      if (executable) {
        return { executable: join(packageDir, executable.name), extraArgs: [] };
      }
    }
  }

  throw new Error(`No packaged Electron executable found in ${electronOutDir}`);
}

async function getFreePort() {
  const server = createServer();
  await new Promise<void>((done, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", done);
  });

  const address = server.address();
  await new Promise<void>((done, reject) => {
    server.close((error) => (error ? reject(error) : done()));
  });

  if (!address || typeof address === "string") {
    throw new Error("Unable to allocate a local debugging port");
  }

  return address.port;
}

async function waitForDebugPort(
  port: number,
  appProcess: ChildProcessWithoutNullStreams,
  output: string[]
) {
  const endpoint = `http://127.0.0.1:${port}/json/version`;
  const deadline = Date.now() + 30_000;

  while (Date.now() < deadline) {
    if (appProcess.exitCode !== null) {
      throw new Error(`Packaged Electron app exited with code ${appProcess.exitCode}`);
    }

    const wsEndpoint = output
      .join("")
      .match(/DevTools listening on (ws:\/\/[^\s]+)/)?.[1];
    if (wsEndpoint) {
      return wsEndpoint;
    }

    try {
      const response = await fetch(endpoint);
      if (response.ok) {
        return `http://127.0.0.1:${port}`;
      }
    } catch {
      // Keep polling until the packaged app finishes creating its first window.
    }

    await new Promise((done) => setTimeout(done, 250));
  }

  throw new Error(`Timed out waiting for packaged Electron debug port ${port}`);
}

test("packaged electron app opens after build", async ({
  browserName: _browserName,
}, testInfo) => {
  test.setTimeout(60_000);

  const port = await getFreePort();
  const userDataDir = await mkdtemp(join(tmpdir(), "comma-electron-packaged-"));
  const launchTarget = findPackagedExecutable();
  const appProcess = spawn(
    launchTarget.executable,
    [
      ...launchTarget.extraArgs,
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${userDataDir}`,
    ],
    {
      cwd: electronAppDir,
      env: electronTestEnv(),
    }
  );
  const output: string[] = [];

  try {
    appProcess.stdout.on("data", (chunk) => output.push(chunk.toString()));
    appProcess.stderr.on("data", (chunk) => output.push(chunk.toString()));

    const cdpEndpoint = await waitForDebugPort(port, appProcess, output);
    const browser = await chromium.connectOverCDP(cdpEndpoint);
    try {
      const context = browser.contexts()[0];
      if (!context) {
        throw new Error("Packaged Electron app did not expose a browser context");
      }

      const page = context.pages()[0] ?? (await context.waitForEvent("page"));

      const rendererErrors: string[] = [];
      page.on("pageerror", (error) => rendererErrors.push(error.message));
      page.on("requestfailed", (request) => {
        if (request.resourceType() === "script") {
          rendererErrors.push(`${request.url()}: ${request.failure()?.errorText}`);
        }
      });
      // DOM readiness precedes the deferred application import. Wait for a
      // visible, interactive application surface rather than an empty root.
      await expect(page.locator("#root").getByRole("button").first()).toBeVisible({
        timeout: 30000,
      });
      expect(rendererErrors, "Renderer or application chunk load failures").toEqual([]);
      expect(
        output.join(""),
        "Application chunk load failures before CDP attached"
      ).not.toMatch(
        /Failed to fetch dynamically imported module|ERR_MODULE_NOT_FOUND|ChunkLoadError/
      );
    } finally {
      await browser.close();
    }
  } catch (error) {
    await testInfo.attach("electron-packaged-output", {
      body: output.join(""),
      contentType: "text/plain",
    });
    throw error;
  } finally {
    if (appProcess.exitCode === null) {
      appProcess.kill();
    }
  }
});
