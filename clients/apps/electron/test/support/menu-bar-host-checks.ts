import {
  spawn,
  spawnSync,
  type ChildProcessWithoutNullStreams,
} from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import {
  chatProtocolVersion,
  statusMenuClientFrameSchema,
  statusMenuHostFrameSchema,
  type StatusMenuClientFrame,
  type StatusMenuHostFrame,
} from "@comma/chat-contract";
import { afterEach, describe, expect, it } from "vitest";
import {
  menuBarAppName,
  menuBarHostDistAppPath,
  packagedMenuBarHostAppPath,
} from "../../scripts/native-paths";

const appDir = resolve(import.meta.dirname, "../..");
/**
 * The built menu-bar helper's bundle and protocol, run by `native-build.test.ts`, one of the
 * test files that may do real IO (determinism/unit-real-io.txt). With
 * COMMA_VERIFY_PACKAGED_HELPERS=1 it checks the helper inside the packaged Electron app.
 */
export function describeMenuBarHost() {
  const requirePackagedHelper = process.env.COMMA_VERIFY_PACKAGED_HELPERS === "1";
  const packagedElectronApp = requirePackagedHelper
    ? process.env.COMMA_ELECTRON_APP_BUNDLE ||
      findPackagedElectronApp(resolve(appDir, "out"))
    : undefined;
  if (requirePackagedHelper && !packagedElectronApp) {
    throw new Error(
      `COMMA_VERIFY_PACKAGED_HELPERS=1 but no Electron app containing the packaged menu-bar helper was found under ${resolve(appDir, "out")}.`
    );
  }
  const helperApp = packagedElectronApp
    ? packagedMenuBarHostAppPath(packagedElectronApp)
    : menuBarHostDistAppPath(appDir);
  const helperExecutable = resolve(helperApp, "Contents/MacOS", menuBarAppName);
  if (requirePackagedHelper && !existsSync(helperExecutable)) {
    throw new Error(
      `COMMA_VERIFY_PACKAGED_HELPERS=1 but ${packagedElectronApp} has no helper at ${helperExecutable}.`
    );
  }
  const canRunRealHelper =
    process.platform === "darwin" && existsSync(helperExecutable);
  const runningHelpers = new Set<RealHelperHarness>();

  afterEach(async () => {
    await Promise.all([...runningHelpers].map((helper) => helper.forceClose()));
  });

  describe("the menu-bar helper (CommaMenuBarHost)", () => {
    it.skipIf(!canRunRealHelper)(
      "ships a signed headless helper for the supported macOS minimum",
      () => {
        const infoPlist = resolve(helperExecutable, "../../Info.plist");
        const plist = spawnSync(
          "plutil",
          ["-extract", "LSMinimumSystemVersion", "raw", "-o", "-", infoPlist],
          { encoding: "utf8" }
        );
        expect(plist.status, plist.stderr).toBe(0);
        expect(plist.stdout.trim()).toBe("14.0");

        const buildVersion = spawnSync(
          "xcrun",
          ["vtool", "-show-build", helperExecutable],
          {
            encoding: "utf8",
          }
        );
        expect(buildVersion.status, buildVersion.stderr).toBe(0);
        expect(buildVersion.stdout).toMatch(/platform MACOS[\s\S]*minos 14\.0/);

        expect(existsSync(resolve(helperApp, "Contents/Resources/Assets.car"))).toBe(
          false
        );
        const linkedFrameworks = spawnSync("otool", ["-L", helperExecutable], {
          encoding: "utf8",
        });
        expect(linkedFrameworks.status, linkedFrameworks.stderr).toBe(0);
        expect(linkedFrameworks.stdout).not.toMatch(/DeveloperToolsSupport|SwiftUI/);

        if (packagedElectronApp) {
          const verify = spawnSync(
            "codesign",
            ["--verify", "--deep", "--strict", helperApp],
            {
              encoding: "utf8",
            }
          );
          expect(verify.status, verify.stderr).toBe(0);
          expect(helperApp).toContain("Contents/Resources/native/macos");
        }
      }
    );

    it.skipIf(!canRunRealHelper)(
      "shows and hides the menu-bar item that Main describes",
      async () => {
        const helper = new RealHelperHarness(helperExecutable, runningHelpers);
        await helper.waitForFrame((frame) => frame.kind === "status-menu.ready");

        helper.writeFrame({
          iconPath: resolve(appDir, "build/icons/tray/CommaTemplate.png"),
          kind: "status-menu.show",
          protocolVersion: chatProtocolVersion,
          requestId: "status-menu-show",
          rows: [
            {
              id: "open-comma",
              kind: "item",
              shortcut: "⌥ Space",
              title: "Open Comma",
            },
            { kind: "separator" },
            { kind: "header", title: "Tasks" },
            { id: "task:grp/cnv", kind: "item", title: "Draft the Q3 plan and budget" },
          ],
          toolTip: "Comma is running",
          width: 260,
        });
        await expect(helper.waitForResult("status-menu-show")).resolves.toMatchObject({
          ok: true,
        });

        helper.writeFrame({
          kind: "status-menu.hide",
          protocolVersion: chatProtocolVersion,
          requestId: "status-menu-hide",
        });
        await expect(helper.waitForResult("status-menu-hide")).resolves.toMatchObject({
          ok: true,
        });
        await expect(helper.close()).resolves.toEqual({ code: 0, signal: null });
      }
    );

    it.skipIf(!canRunRealHelper)(
      "refuses a frame of another protocol version and answers nothing for it",
      async () => {
        const helper = new RealHelperHarness(helperExecutable, runningHelpers);
        await helper.waitForFrame((frame) => frame.kind === "status-menu.ready");

        helper.writeRawFrame({
          kind: "status-menu.hide",
          protocolVersion: chatProtocolVersion + 1,
          requestId: "wrong-version",
        });
        await expect(
          helper.waitForFrame((frame) => frame.kind === "status-menu.protocol-error")
        ).resolves.toMatchObject({
          expectedProtocolVersion: chatProtocolVersion,
          frameKind: "status-menu.hide",
          receivedProtocolVersion: chatProtocolVersion + 1,
        });

        // The helper answers each frame before it reads the next.
        helper.writeFrame({
          kind: "status-menu.hide",
          protocolVersion: chatProtocolVersion,
          requestId: "probe",
        });
        await helper.waitForResult("probe");
        expect(helper.observedFrames()).not.toContainEqual(
          expect.objectContaining({
            kind: "status-menu.result",
            requestId: "wrong-version",
          })
        );
        await expect(helper.close()).resolves.toEqual({ code: 0, signal: null });
      }
    );

    it.skipIf(!canRunRealHelper)("exits when Electron closes its stdin", async () => {
      const helper = new RealHelperHarness(helperExecutable, runningHelpers);
      await expect(helper.close()).resolves.toEqual({ code: 0, signal: null });
    });
  });

  describe("the packaged menu-bar helper's discovery", () => {
    it("finds the Electron bundle by its nested helper instead of its product name", () => {
      const root = mkdtempSync(resolve(tmpdir(), "comma-menu-bar-package-"));
      const electronApp = resolve(root, "Renamed Product.app");
      const nestedHelperExecutable = resolve(
        packagedMenuBarHostAppPath(electronApp),
        "Contents/MacOS",
        menuBarAppName
      );

      try {
        mkdirSync(resolve(root, "Comma.app"));
        mkdirSync(resolve(nestedHelperExecutable, ".."), { recursive: true });
        writeFileSync(nestedHelperExecutable, "");

        expect(findPackagedElectronApp(root)).toBe(electronApp);
      } finally {
        rmSync(root, { force: true, recursive: true });
      }
    });
  });
}

function findPackagedElectronApp(root: string): string | undefined {
  if (!existsSync(root)) return undefined;
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const path = resolve(root, entry.name);
    if (entry.name.endsWith(".app")) {
      const nestedHelper = packagedMenuBarHostAppPath(path);
      if (existsSync(resolve(nestedHelper, "Contents/MacOS", menuBarAppName))) {
        return path;
      }
      continue;
    }
    const nested = findPackagedElectronApp(path);
    if (nested) return nested;
  }
  return undefined;
}

type ExitResult = {
  code: number | null;
  signal: NodeJS.Signals | null;
};

type FrameWaiter = {
  predicate: (frame: StatusMenuClientFrame) => boolean;
  reject(error: Error): void;
  resolve(frame: StatusMenuClientFrame): void;
};

class RealHelperHarness {
  // The helper this harness runs.
  readonly #executable: string;
  readonly #running: Set<RealHelperHarness>;
  readonly #exitPromise: Promise<ExitResult>;
  readonly #frames: StatusMenuClientFrame[] = [];
  readonly #host: ChildProcessWithoutNullStreams;
  readonly #observed: StatusMenuClientFrame[] = [];
  readonly #waiters = new Set<FrameWaiter>();
  #closed = false;
  #fatalError: Error | undefined;
  #stderr = "";
  #stdoutBuffer = "";

  constructor(executable: string, running: Set<RealHelperHarness>) {
    this.#executable = executable;
    this.#running = running;
    this.#host = spawn(executable, [], {
      env: cleanHelperEnvironment(process.env),
      stdio: ["pipe", "pipe", "pipe"],
    });
    running.add(this);
    this.#host.stdout.on("data", (chunk) => this.#acceptStdout(chunk.toString()));
    this.#host.stderr.on("data", (chunk) => {
      this.#stderr += chunk.toString();
    });
    this.#host.once("error", (error) => this.#fail(error));
    this.#exitPromise = new Promise((resolveExit) => {
      this.#host.once("exit", (code, signal) => {
        this.#running.delete(this);
        resolveExit({ code, signal });
      });
    });
    // Once its output has ended, no frame still awaited can come.
    this.#host.once("close", () => {
      this.#closed = true;
      for (const waiter of this.#waiters) waiter.reject(this.#closedError());
      this.#waiters.clear();
    });
  }

  observedFrames() {
    return [...this.#observed];
  }

  writeFrame(frame: StatusMenuHostFrame) {
    this.writeRawFrame(statusMenuHostFrameSchema.parse(frame));
  }

  writeRawFrame(frame: unknown) {
    this.#host.stdin.write(`${JSON.stringify(frame)}\n`);
  }

  waitForResult(requestId: string) {
    return this.waitForFrame(
      (frame) => frame.kind === "status-menu.result" && frame.requestId === requestId
    );
  }

  waitForFrame(predicate: (frame: StatusMenuClientFrame) => boolean) {
    const queuedIndex = this.#frames.findIndex(predicate);
    if (queuedIndex >= 0)
      return Promise.resolve(this.#frames.splice(queuedIndex, 1)[0]!);
    if (this.#fatalError) return Promise.reject(this.#fatalError);
    if (this.#closed) return Promise.reject(this.#closedError());

    return new Promise<StatusMenuClientFrame>((resolveFrame, rejectFrame) => {
      this.#waiters.add({ predicate, reject: rejectFrame, resolve: resolveFrame });
    });
  }

  async close(): Promise<ExitResult> {
    if (!this.#host.stdin.destroyed) this.#host.stdin.end();
    return this.#awaitExit();
  }

  async forceClose() {
    if (!this.#host.killed) this.#host.kill();
    await this.#awaitExit().catch(() => undefined);
  }

  #acceptStdout(chunk: string) {
    this.#stdoutBuffer += chunk;
    let boundary = this.#stdoutBuffer.indexOf("\n");
    while (boundary >= 0) {
      const line = this.#stdoutBuffer.slice(0, boundary).trim();
      this.#stdoutBuffer = this.#stdoutBuffer.slice(boundary + 1);
      boundary = this.#stdoutBuffer.indexOf("\n");
      if (!line.startsWith("{")) continue;

      const parsed = statusMenuClientFrameSchema.safeParse(JSON.parse(line) as unknown);
      if (!parsed.success) {
        this.#fail(
          new Error(
            `CommaMenuBarHost emitted non-canonical JSON: ${parsed.error.message}`
          )
        );
        continue;
      }
      this.#acceptFrame(parsed.data);
    }
  }

  #acceptFrame(frame: StatusMenuClientFrame) {
    this.#observed.push(frame);
    const waiter = [...this.#waiters].find(({ predicate }) => predicate(frame));
    if (!waiter) {
      this.#frames.push(frame);
      return;
    }
    this.#waiters.delete(waiter);
    waiter.resolve(frame);
  }

  #fail(error: Error) {
    this.#fatalError ??= error;
    for (const waiter of this.#waiters) waiter.reject(this.#fatalError);
    this.#waiters.clear();
  }

  #closedError() {
    return new Error(
      `${this.#executable} exited before the frame came. Seen: ${JSON.stringify(this.#observed)}.${this.#stderr ? ` stderr: ${this.#stderr.trim()}` : ""}`
    );
  }

  async #awaitExit() {
    const result = await this.#exitPromise;
    if (this.#fatalError) throw this.#fatalError;
    return result;
  }
}

function cleanHelperEnvironment(source: NodeJS.ProcessEnv) {
  const environment: NodeJS.ProcessEnv = {};
  for (const key of ["LANG", "LC_ALL", "LC_CTYPE", "PATH"] as const) {
    if (source[key] !== undefined) environment[key] = source[key];
  }
  return environment;
}
